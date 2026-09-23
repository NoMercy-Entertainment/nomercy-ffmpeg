/*
 * Runtime selection between the ggml CPU backend variants linked into this
 * binary.
 *
 * Why this file exists: ggml is compiled at a fixed instruction-set level, and
 * cross-compiling turns every level off (see the design doc). Raising the level
 * would break Raspberry Pi 4, Ivy Bridge Macs and pre-AVX Atom boxes, so
 * instead the binary carries several variants and chooses at startup, the way
 * FFmpeg's own --enable-runtime-cpudetect already does.
 *
 * How it hooks in: ggml-base registers a CPU backend by calling
 * ggml_backend_cpu_reg(), and the filters call ggml_backend_cpu_init() and
 * ggml_backend_cpu_set_n_threads(). Each packed variant has those symbols under
 * its own prefix, so this file defines the unprefixed names and forwards them.
 * Nothing else in the build needs to know variants exist.
 *
 * NOMERCY_GGML_CPU=<name> forces a variant; an unknown or unsupported name is
 * ignored with the automatic choice kept, so the variable can never make a
 * machine unbootable.
 *
 * Fixed-level mode: the two darwin platforms know their hardware floor exactly
 * and compile ggml at a single fixed level instead of carrying variants; their
 * stock libggml-cpu.a already defines the forwarding functions below, so
 * defining them again would be a duplicate-symbol error. Build this file with
 * -DNM_GGML_CPU_FIXED='"<name>"' on those platforms: it then defines only
 * nm_ggml_cpu_variant_name() (returning that fixed name) and none of the
 * dispatch machinery, and does not require nm_ggml_cpu_variants.h to exist.
 *
 * Backend selection (nm_ggml_backend_init and friends) lives at the BOTTOM of
 * this file, outside the fixed-level split: it is identical on every platform,
 * fixed-level darwin included, because both filters call it unconditionally.
 */
#include "nm_ggml_cpu.h"

/* ggml_backend_cpu_init(), ggml_backend_is_cpu() and
 * ggml_backend_cpu_set_n_threads() are declared here, not in ggml-backend.h.
 * In variant mode this file defines them further down, but in
 * NM_GGML_CPU_FIXED mode it only CALLS them - and without this include that
 * call compiles as an implicit int-returning function, i.e. a truncated
 * pointer. Verified: gcc warns "returning int from a function with return type
 * ggml_backend_t" the moment the include is missing. */
#include <ggml-cpu.h>

#include <stdlib.h>
#include <string.h>

#ifdef NM_GGML_CPU_FIXED

const char *nm_ggml_cpu_variant_name(void)
{
    return NM_GGML_CPU_FIXED;
}

#else /* !NM_GGML_CPU_FIXED */

#include "nm_ggml_cpu_variants.h"

#if defined(_WIN32)
#include <windows.h>
/* PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE was only added to mingw-w64's
 * winnt.h relatively recently; llvm-mingw builds older than that omit it,
 * which would otherwise fail this whole file to compile on windows-aarch64.
 * The value (43) is Microsoft's own documented, stable PROCESSOR_FEATURE_ID
 * for this feature (see winnt.h upstream / learn.microsoft.com
 * IsProcessorFeaturePresent), not something this project invented, so
 * defining it ourselves when the header lacks it is safe on any toolchain. */
#ifndef PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE
#define PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE 43
#endif
#elif defined(__linux__) && defined(__aarch64__)
#include <sys/auxv.h>
#include <asm/hwcap.h>
#elif defined(__APPLE__)
#include <sys/sysctl.h>
#endif

enum nm_cpu_feat {
    NM_CPU_FEAT_BASELINE = 0,
    NM_CPU_FEAT_SSE42,
    NM_CPU_FEAT_AVX_F16C,
    NM_CPU_FEAT_AVX2_FMA,
    NM_CPU_FEAT_ARM_BASE,
    NM_CPU_FEAT_ARM_DOTPROD_FP16,
    NM_CPU_FEAT_ARM_I8MM,
};

/* Declare each variant's prefixed entry points.
 *
 * ggml_backend_cpu_buffer_type() is deliberately NOT forwarded here: it is
 * defined once inside ggml-base.a itself (verified: byte-identical between
 * the sse42 and avx2 builds, i.e. it does not vary per CPU variant, and a
 * whole-archive relink of libwhisper.a + libggml-base.a + libggml.a +
 * libparakeet.a alone resolves it with no help from ggml-cpu.a). Defining it
 * again here would collide with ggml-base's own definition at the real link.
 */
#define X(prefix, name, feat)                                        \
    extern ggml_backend_reg_t prefix##ggml_backend_cpu_reg(void);    \
    extern ggml_backend_t     prefix##ggml_backend_cpu_init(void);   \
    extern void               prefix##ggml_backend_cpu_set_n_threads(ggml_backend_t, int); \
    extern bool               prefix##ggml_backend_is_cpu(ggml_backend_t);
NM_GGML_CPU_VARIANTS
#undef X

struct nm_variant {
    const char *name;
    enum nm_cpu_feat feat;
    ggml_backend_reg_t (*reg)(void);
    ggml_backend_t (*init)(void);
    void (*set_n_threads)(ggml_backend_t, int);
    bool (*is_cpu)(ggml_backend_t);
};

/* Listed cheapest first; selection walks backwards and takes the first fit. */
static const struct nm_variant nm_variants[] = {
#define X(prefix, name, feat) { name, feat,                          \
        prefix##ggml_backend_cpu_reg, prefix##ggml_backend_cpu_init, \
        prefix##ggml_backend_cpu_set_n_threads, prefix##ggml_backend_is_cpu },
    NM_GGML_CPU_VARIANTS
#undef X
};

#define NM_NB_VARIANTS ((int) (sizeof(nm_variants) / sizeof(nm_variants[0])))

/* nm_select()'s last-resort fallback below is `nm_variants[0]`, which is
 * safe only because the build script (48-whisper.sh's nm_variant_matrix)
 * happens to emit the baseline row first and nm_cpu_supports() returns 1
 * for its feature unconditionally. Nothing else ties those two facts
 * together, so a future edit to the matrix -- reordering it, or dropping
 * the plain x64/armv8.0 row in favour of a higher floor -- would silently
 * turn "the binary always starts" into a SIGILL on exactly the old
 * hardware this design exists to protect. Pull the first row's feature out
 * of NM_GGML_CPU_VARIANTS at compile time and assert it against the one
 * feature test that always returns true for this architecture.
 *
 * The X-macro list is not comma separated at the top level (it is a run of
 * "X(...) X(...) ..." calls), so a plain head-macro can't split it -- its
 * own argument scan happens on the unexpanded "NM_GGML_CPU_VARIANTS" token,
 * before that name is expanded into anything with commas in it. Routing
 * through a variadic NM_HEAD_FEAT(...) first forces NM_GGML_CPU_VARIANTS
 * (with X redefined here to emit real commas) to expand while it is still
 * just __VA_ARGS__ being substituted into NM_HEAD_FEAT_'s call -- only then
 * does the preprocessor rescan and see actual top-level commas to split on. */
#define X(prefix, name, feat) prefix, name, feat,
#define NM_HEAD_FEAT_(p0, n0, f0, ...) f0
#define NM_HEAD_FEAT(...) NM_HEAD_FEAT_(__VA_ARGS__)
#if defined(__x86_64__) || defined(_M_X64)
_Static_assert(NM_HEAD_FEAT(NM_GGML_CPU_VARIANTS) == NM_CPU_FEAT_BASELINE,
    "nm_variants[0] must be the unconditional x86-64 baseline: nm_select() "
    "falls back to it when nothing else matches, and NM_CPU_FEAT_BASELINE "
    "is the only feature test that always returns true");
#elif defined(__aarch64__) || defined(_M_ARM64)
_Static_assert(NM_HEAD_FEAT(NM_GGML_CPU_VARIANTS) == NM_CPU_FEAT_ARM_BASE,
    "nm_variants[0] must be the unconditional ARMv8.0 baseline: nm_select() "
    "falls back to it when nothing else matches, and NM_CPU_FEAT_ARM_BASE "
    "is the only feature test that always returns true");
#endif
#undef NM_HEAD_FEAT
#undef NM_HEAD_FEAT_
#undef X

static int nm_cpu_supports(enum nm_cpu_feat feat)
{
    switch (feat) {
    case NM_CPU_FEAT_BASELINE:
    case NM_CPU_FEAT_ARM_BASE:
        return 1;
#if defined(__x86_64__) || defined(_M_X64)
    case NM_CPU_FEAT_SSE42:
        return __builtin_cpu_supports("sse4.2");
    case NM_CPU_FEAT_AVX_F16C:
        /* F16C is the cliff: the models are F16 and without it every weight is
         * converted in scalar code. */
        return __builtin_cpu_supports("avx") && __builtin_cpu_supports("f16c");
    case NM_CPU_FEAT_AVX2_FMA:
        return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma")
            && __builtin_cpu_supports("bmi2");
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
    case NM_CPU_FEAT_ARM_DOTPROD_FP16:
#if defined(_WIN32)
        return IsProcessorFeaturePresent(PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE);
#elif defined(__linux__)
        return (getauxval(AT_HWCAP) & HWCAP_ASIMDDP) && (getauxval(AT_HWCAP) & HWCAP_ASIMDHP);
#elif defined(__APPLE__)
        return 1;   /* every Apple Silicon chip has both */
#else
        return 0;
#endif
    case NM_CPU_FEAT_ARM_I8MM:
        /* Deliberately never selected on Windows: there is no feature flag for
         * i8mm there, and inferring it from the SVE flag is wrong on Oryon.
         * This variant is built armv8.2-a+dotprod+fp16+i8mm, so, like every
         * other row, the test checks every feature it was compiled for, not
         * just the newest one. */
#if defined(__linux__)
        return (getauxval(AT_HWCAP) & HWCAP_ASIMDDP) && (getauxval(AT_HWCAP) & HWCAP_ASIMDHP)
            && (getauxval(AT_HWCAP2) & HWCAP2_I8MM);
#else
        return 0;
#endif
#endif
    default:
        return 0;
    }
}

static const struct nm_variant *nm_select(void)
{
    static const struct nm_variant *chosen;
    if (chosen)
        return chosen;

    const char *forced = getenv("NOMERCY_GGML_CPU");
    if (forced && *forced) {
        for (int i = 0; i < NM_NB_VARIANTS; i++)
            if (!strcmp(nm_variants[i].name, forced) && nm_cpu_supports(nm_variants[i].feat)) {
                chosen = &nm_variants[i];
                return chosen;
            }
        /* Unknown or unsupported: ignore it rather than fail to start. */
    }

    for (int i = NM_NB_VARIANTS - 1; i >= 0; i--)
        if (nm_cpu_supports(nm_variants[i].feat)) {
            chosen = &nm_variants[i];
            return chosen;
        }

    chosen = &nm_variants[0];   /* the baseline variant always runs */
    return chosen;
}

const char *nm_ggml_cpu_variant_name(void)
{
    return nm_select()->name;
}

/* The unprefixed ggml CPU API, forwarded to the selected variant. */
ggml_backend_reg_t ggml_backend_cpu_reg(void)
{
    return nm_select()->reg();
}

ggml_backend_t ggml_backend_cpu_init(void)
{
    return nm_select()->init();
}

void ggml_backend_cpu_set_n_threads(ggml_backend_t backend, int n_threads)
{
    nm_select()->set_n_threads(backend, n_threads);
}

bool ggml_backend_is_cpu(ggml_backend_t backend)
{
    return nm_select()->is_cpu(backend);
}

#endif /* NM_GGML_CPU_FIXED */
/* ===================================================================== */
/* Backend selection: which device should a filter run on?               */
/* ===================================================================== */

/*
 * GPU first when the caller allows it, then the best CPU instruction-set
 * variant. Three rules here are measured requirements rather than preferences:
 *
 *   - Only ggml's REGISTRY path may be used. The legacy Vulkan entry points
 *     (ggml_backend_vk_init, ggml_backend_vk_get_device_count) do not catch
 *     Vulkan's exceptions, so on the very ordinary "loader present, no usable
 *     driver" they terminate the process (measured: exit 134).
 *
 *   - Enumerating Vulkan can kill the process outright. On a Linux host with
 *     Mesa installed, a fully static binary dies with SIGSEGV inside the
 *     loader's own ICD probing - before any of our code runs, and therefore
 *     before there is a device list to filter. Measured per driver in a
 *     mesa-vulkan-drivers container, with this binary:
 *
 *         asahi     ok      gfxstream  SIGSEGV (139)
 *         intel     ok      lvp        SIGSEGV (139)
 *         nouveau   ok      radeon     SIGSEGV (139)
 *         virtio    ok
 *
 *     Note what that table does NOT say: it is not the software rasteriser
 *     (lvp) alone. radeon and gfxstream are hardware drivers and they crash
 *     too, so "skip the software ICDs" - the rule this task started with -
 *     would not have saved the machine. The common factor is dlopen()ing a
 *     third-party driver from a statically linked executable, which is not a
 *     property we can read off a manifest. So the guard does not guess: it
 *     forks and finds out. See nm_vk_probe() below.
 *
 *   - Software rasterisers are refused even when they survive. whisper.cpp
 *     would happily select one, and llvmpipe is slower than the CPU backend
 *     it would be displacing.
 *
 * Anything unexpected falls back to the CPU. A machine without a usable GPU
 * must behave exactly as it did before this code existed.
 */

#include <ctype.h>
#include <stdio.h>

#if !defined(_WIN32) && !defined(__APPLE__)
#define NM_VK_ICD_GUARD 1
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif

/* Catches a software device that survived enumeration. ggml's Vulkan backend
 * names its devices "Vulkan0", "Vulkan1", ..., so the description - the
 * VkPhysicalDeviceProperties device name, e.g. "llvmpipe (LLVM 17.0.6, 256
 * bits)" - is the field that actually carries the evidence; both are checked
 * anyway, case-insensitively, because another registry may name them
 * differently. */
static int nm_str_contains_ci(const char *hay, const char *needle)
{
    size_t nlen = needle ? strlen(needle) : 0;
    size_t i, j;

    if (!hay || !nlen)
        return 0;
    for (i = 0; hay[i]; i++) {
        for (j = 0; j < nlen; j++) {
            unsigned char a = (unsigned char) hay[i + j];
            unsigned char b = (unsigned char) needle[j];

            if (!a || tolower(a) != tolower(b))
                break;
        }
        if (j == nlen)
            return 1;
    }
    return 0;
}

static int nm_device_is_software(ggml_backend_dev_t dev)
{
    static const char *const markers[] = {
        "llvmpipe", "swiftshader", "lavapipe", "software", NULL,
    };
    const char *name = ggml_backend_dev_name(dev);
    const char *desc = ggml_backend_dev_description(dev);
    int i;

    for (i = 0; markers[i]; i++)
        if (nm_str_contains_ci(name, markers[i]) || nm_str_contains_ci(desc, markers[i]))
            return 1;

    return 0;
}

/* What a full enumeration found. Also the child process's exit code, so the
 * values are small and stable on purpose. */
#define NM_VK_OK_GPU    0   /* survived; a hardware GPU is usable      */
#define NM_VK_NO_GPU    1   /* survived; nothing usable, nothing scary */
#define NM_VK_SOFTWARE  2   /* survived; a software device is present  */
#define NM_VK_UNSAFE    3   /* did not survive, or could not be tested */

/* Enumerate, and open the first usable device. This is the work that can
 * crash, which is exactly why it is also what the child process runs: the
 * check and the thing being checked are the same code. `out` receives the
 * chosen device (parent only; the child has no use for it). */
static int nm_vk_scan(ggml_backend_dev_t *out)
{
    ggml_backend_dev_t first = NULL;
    size_t i, n;

    if (out)
        *out = NULL;

    n = ggml_backend_dev_count();
    for (i = 0; i < n; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        enum ggml_backend_dev_type type;

        if (!dev)
            continue;
        type = ggml_backend_dev_type(dev);
        /* IGPU is a separate enumerator in ggml 0.15.1, and ggml-vulkan reports
         * every integrated adapter as one (ggml-vulkan.cpp: is_integrated_gpu
         * ? ..._IGPU : ..._GPU). whisper.cpp accepts both, so checking only
         * ..._GPU would make this disagree with the library it is deciding
         * for, on the very common laptop/APU case. */
        if (type != GGML_BACKEND_DEVICE_TYPE_GPU && type != GGML_BACKEND_DEVICE_TYPE_IGPU)
            continue;

        /* One software device anywhere in the list disqualifies the GPU path
         * entirely, rather than merely being skipped over.
         *
         * whisper.cpp does not let us be choosier: whisper_backend_init_gpu()
         * walks this same list and takes the params.gpu_device'th GPU/IGPU
         * device with no software check of its own. If we answered "yes, a GPU
         * is usable" because device 1 is real, whisper would still be free to
         * take software device 0. The only answer that stays true for every
         * gpu_device index is "none of them are software" - and when a real
         * GPU is hiding behind a software one, the ICD bisect below is what
         * gets it back, by removing the software driver from the process
         * rather than by tolerating it here. */
        if (nm_device_is_software(dev))
            return NM_VK_SOFTWARE;

        if (!first) {
            /* Prove it really opens. A device that enumerates but cannot be
             * initialised is the last cheap failure we can still turn into a
             * clean CPU fallback - and opening it is also where a driver that
             * enumerates happily still has time to die. */
            ggml_backend_t probe = ggml_backend_dev_init(dev, NULL);

            if (probe) {
                ggml_backend_free(probe);
                first = dev;
            }
        }
    }

    if (out)
        *out = first;
    return first ? NM_VK_OK_GPU : NM_VK_NO_GPU;
}

#ifdef NM_VK_ICD_GUARD

/*
 * Find out whether Vulkan can be touched at all, by touching it somewhere the
 * answer cannot hurt: a forked child.
 *
 * This replaces the manifest-name heuristic this task was originally specified
 * with. That heuristic was measurably wrong - see the driver table at the top
 * of this section: Mesa's radeon and gfxstream ICDs crash a static binary just
 * as lvp does, and no string in their manifests says so. A fork costs a few
 * hundred milliseconds once per process and answers the question with
 * evidence instead.
 *
 * `icd` restricts the child to one manifest (the bisect below), or is NULL to
 * test the loader's own search path unchanged.
 *
 * Returns NM_VK_UNSAFE if the child died, hung, or could not be created.
 * "Could not be created" counts as unsafe on purpose: an unverifiable Vulkan
 * is not a Vulkan we are willing to enumerate in this process.
 */
static int nm_vk_probe(const char *icd)
{
    int status = 0;
    int waited_ms = 0;
    pid_t pid;

    pid = fork();
    if (pid < 0)
        return NM_VK_UNSAFE;

    if (pid == 0) {
        /* ggml and the Vulkan loader both write to stderr while enumerating;
         * the parent is about to do the same enumeration for real, so let its
         * output be the one the user sees. */
        int fd = open("/dev/null", O_WRONLY);

        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            if (fd > STDERR_FILENO)
                close(fd);
        }
        if (icd) {
            setenv("VK_ICD_FILENAMES", icd, 1);
            setenv("VK_DRIVER_FILES", icd, 1);
        }
        /* _exit, not exit: no atexit handler of the parent's should run here. */
        _exit(nm_vk_scan(NULL));
    }

    /* fork() from a process that already has threads can, in principle, hand
     * the child a lock another thread was holding. It has never been observed
     * here, but "never observed" is not a guarantee, and a child that never
     * exits would hang FFmpeg's startup. Bound it, and treat the timeout the
     * same as a crash. */
    for (;;) {
        pid_t r = waitpid(pid, &status, WNOHANG);

        if (r == pid)
            break;
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return NM_VK_UNSAFE;
        }
        if (waited_ms >= 30000) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            return NM_VK_UNSAFE;
        }
        {
            struct timespec ts = { 0, 5 * 1000 * 1000 };
            nanosleep(&ts, NULL);
            waited_ms += 5;
        }
    }

    if (!WIFEXITED(status))
        return NM_VK_UNSAFE;
    {
        int code = WEXITSTATUS(status);

        return code <= NM_VK_SOFTWARE ? code : NM_VK_UNSAFE;
    }
}

/* The loader's own search path. More directories than strictly observed, on
 * purpose: an ICD we fail to SEE is one the bisect cannot rescue, and the cost
 * of looking in a directory that does not exist is one stat() call. */
static const char *const nm_vk_icd_dirs[] = {
    "/etc/vulkan/icd.d",
    "/usr/local/etc/vulkan/icd.d",
    "/usr/local/share/vulkan/icd.d",
    "/usr/share/vulkan/icd.d",
    NULL,
};

#define NM_VK_MAX_ICDS 64

static int nm_vk_cmp_str(const void *a, const void *b)
{
    return strcmp(*(const char *const *) a, *(const char *const *) b);
}

/* Appends one candidate manifest path; a directory contributes its *.json. */
static void nm_vk_add_candidate(char **list, int *n, const char *path)
{
    struct stat st;

    if (*n >= NM_VK_MAX_ICDS || !path || !*path)
        return;
    if (stat(path, &st) != 0)
        return;

    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        struct dirent *e;
        int first = *n;

        if (!d)
            return;
        while ((e = readdir(d)) && *n < NM_VK_MAX_ICDS) {
            size_t len = strlen(e->d_name);
            char full[1024];
            char *dup;

            if (len < 6 || strcmp(e->d_name + len - 5, ".json"))
                continue;
            if (snprintf(full, sizeof(full), "%s/%s", path, e->d_name) >= (int) sizeof(full))
                continue;
            dup = strdup(full);
            if (dup)
                list[(*n)++] = dup;
        }
        closedir(d);
        /* readdir order is filesystem-dependent; sort so the loader sees the
         * same order on every run. */
        if (*n > first + 1)
            qsort(list + first, (size_t) (*n - first), sizeof(*list), nm_vk_cmp_str);
        return;
    }

    {
        char *dup = strdup(path);

        if (dup)
            list[(*n)++] = dup;
    }
}

/* Every ICD manifest the loader would consider, in the loader's own
 * precedence: VK_DRIVER_FILES (newer name) beats VK_ICD_FILENAMES (older), and
 * either REPLACES the system search path rather than adding to it. Taking the
 * union instead - as this task's brief sketched - would resurrect system ICDs
 * a user deliberately excluded, and would quietly turn the
 * "VK_ICD_FILENAMES=/nonexistent.json" verification case into a test of
 * something else entirely. */
static int nm_vk_collect_icds(char **cand)
{
    int nc = 0, i;
    const char *ov = getenv("VK_DRIVER_FILES");

    if (!ov || !*ov)
        ov = getenv("VK_ICD_FILENAMES");

    if (ov && *ov) {
        const char *s = ov;

        while (*s && nc < NM_VK_MAX_ICDS) {
            const char *e = strchr(s, ':');
            char one[1024];
            size_t len = e ? (size_t) (e - s) : strlen(s);

            if (len && len < sizeof(one)) {
                memcpy(one, s, len);
                one[len] = 0;
                nm_vk_add_candidate(cand, &nc, one);
            }
            if (!e)
                break;
            s = e + 1;
        }
        return nc;
    }

    for (i = 0; nm_vk_icd_dirs[i]; i++)
        nm_vk_add_candidate(cand, &nc, nm_vk_icd_dirs[i]);

    /* The per-user directory the loader also reads. */
    {
        const char *xdg = getenv("XDG_DATA_HOME");
        const char *home = getenv("HOME");
        char full[1024];

        full[0] = 0;
        if (xdg && *xdg)
            snprintf(full, sizeof(full), "%s/vulkan/icd.d", xdg);
        else if (home && *home)
            snprintf(full, sizeof(full), "%s/.local/share/vulkan/icd.d", home);
        if (full[0])
            nm_vk_add_candidate(cand, &nc, full);
    }

    return nc;
}

static void nm_vk_pin(const char *value)
{
    /* Set BOTH names. A loader new enough to prefer VK_DRIVER_FILES ignores
     * VK_ICD_FILENAMES entirely, so writing only the old name would leave a
     * user-set VK_DRIVER_FILES in force. */
    setenv("VK_ICD_FILENAMES", value, 1);
    setenv("VK_DRIVER_FILES", value, 1);
}

/*
 * Leave this process able to enumerate Vulkan without dying.
 *
 * Fast path, and the one every ordinary machine takes: probe the loader's own
 * configuration once. If the child came back clean with a hardware GPU, or
 * clean with nothing at all, the environment is left exactly as the user set
 * it - which matters, because VK_ICD_FILENAMES is process-global and FFmpeg's
 * own Vulkan code (libplacebo, the vulkan hwaccel) reads it too.
 *
 * Slow path: something was wrong - a crash, a hang, or a software rasteriser
 * in the list. Probe each manifest on its own and keep only the ones that come
 * back clean AND hardware. This is what saves the ordinary Linux desktop with
 * an NVIDIA card AND Mesa installed: dropping the whole list on the first
 * crash would cost that machine its GPU. When nothing survives we pin the
 * loader to a path that does not exist, which Task 1 proved it reports cleanly
 * as "no device".
 */
static void nm_vk_make_safe(void)
{
    char *cand[NM_VK_MAX_ICDS];
    char joined[8192];
    size_t off = 0;
    int nc, i, kept = 0;
    const char *guard = getenv("NOMERCY_VK_ICD_GUARD");
    int verdict;

    /* The escape hatch, and the harness's way of reproducing the pre-guard
     * crash without a second binary. */
    if (guard && !strcmp(guard, "0"))
        return;

    verdict = nm_vk_probe(NULL);
    if (verdict == NM_VK_OK_GPU || verdict == NM_VK_NO_GPU)
        return;

    nc = nm_vk_collect_icds(cand);

    joined[0] = 0;
    for (i = 0; i < nc; i++) {
        if (nm_vk_probe(cand[i]) == NM_VK_OK_GPU) {
            size_t len = strlen(cand[i]);

            if (off + len + 2 < sizeof(joined)) {
                if (kept)
                    joined[off++] = ':';
                memcpy(joined + off, cand[i], len);
                off += len;
                joined[off] = 0;
                kept++;
            }
        }
        free(cand[i]);
    }

    if (!kept) {
        nm_vk_pin("/nonexistent.json");
        return;
    }

    nm_vk_pin(joined);

    /* Each survivor was proven on its own; the union was not. One more fork
     * settles it, and only when there is more than one to combine. */
    if (kept > 1 && nm_vk_probe(NULL) == NM_VK_UNSAFE)
        nm_vk_pin("/nonexistent.json");
}

#else  /* !NM_VK_ICD_GUARD */

/* Windows and darwin. Windows' loader did not reproduce the crash (Task 1,
 * on this project's own RTX 3070 host) and has no manifest directory of this
 * shape; darwin builds carry no Vulkan at all. */
static void nm_vk_make_safe(void) { }

#endif /* NM_VK_ICD_GUARD */

static ggml_backend_dev_t nm_gpu_dev;
static char nm_gpu_backend_name[32];
static const char *nm_gpu_device_desc;

/* Runs exactly once, before anything else in this process touches ggml's
 * backend registry.
 *
 * The ordering is not decorative. ggml's registry is a function-local static
 * (ggml-backend-reg.cpp: "static ggml_backend_registry reg;" inside get_reg()),
 * so it is constructed lazily on the first registry call - and its constructor
 * calls ggml_backend_vk_reg(), which calls ggml_vk_instance_init(), which
 * creates a VkInstance. THAT is the call that segfaults on a Mesa machine.
 * Everything able to reach the registry therefore has to funnel through here
 * first, af_whisper.c's ggml_backend_load_all() included - which is why
 * af_whisper.c asks nm_ggml_gpu_usable() before, not after, that call.
 */
static void nm_backend_discover(void)
{
    ggml_backend_dev_t dev = NULL;
    ggml_backend_reg_t reg;
    const char *reg_name;

    nm_vk_make_safe();

    /* NOMERCY_GGML_GPU=0 is a process-wide off switch, a sibling of
     * NOMERCY_GGML_CPU above: a user who hits a driver bug can put every
     * filter back on the CPU without editing filtergraphs. Checked after
     * nm_vk_make_safe() on purpose - the process may still enumerate Vulkan
     * for FFmpeg's own reasons, and leaving it unguarded would be a crash this
     * variable appeared to have prevented. */
    {
        const char *off = getenv("NOMERCY_GGML_GPU");

        if (off && !strcmp(off, "0"))
            return;
    }

    if (nm_vk_scan(&dev) != NM_VK_OK_GPU || !dev)
        return;

    reg = ggml_backend_dev_backend_reg(dev);
    reg_name = reg ? ggml_backend_reg_name(reg) : NULL;
    /* ggml spells it "Vulkan" (GGML_VK_NAME in ggml-vulkan.h); this project's
     * metadata contract is lower case, so fold it rather than pass the
     * registry's own spelling straight through. */
    if (reg_name && *reg_name) {
        size_t j;

        for (j = 0; reg_name[j] && j < sizeof(nm_gpu_backend_name) - 1; j++)
            nm_gpu_backend_name[j] = (char) tolower((unsigned char) reg_name[j]);
        nm_gpu_backend_name[j] = 0;
    } else {
        snprintf(nm_gpu_backend_name, sizeof(nm_gpu_backend_name), "gpu");
    }

    /* Stable for the process: ggml-vulkan's device contexts are heap allocated
     * once by ggml_backend_vk_reg_get_device() and never freed. */
    nm_gpu_device_desc = ggml_backend_dev_description(dev);
    nm_gpu_dev = dev;
}

#if defined(_WIN32)
static BOOL CALLBACK nm_backend_once_cb(PINIT_ONCE io, PVOID param, PVOID *context)
{
    (void) io; (void) param; (void) context;
    nm_backend_discover();
    return TRUE;
}
#endif

static void nm_backend_once(void)
{
#if defined(_WIN32)
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    InitOnceExecuteOnce(&once, nm_backend_once_cb, NULL, NULL);
#else
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, nm_backend_discover);
#endif
}

int nm_ggml_gpu_usable(void)
{
    nm_backend_once();
    return nm_gpu_dev != NULL;
}

const char *nm_ggml_backend_name(void)
{
    nm_backend_once();
    return nm_gpu_dev ? nm_gpu_backend_name : "cpu";
}

const char *nm_ggml_backend_device(void)
{
    nm_backend_once();
    return nm_gpu_dev ? nm_gpu_device_desc : nm_ggml_cpu_variant_name();
}

ggml_backend_t nm_ggml_backend_init(int use_gpu)
{
    nm_backend_once();

    if (use_gpu && nm_gpu_dev) {
        ggml_backend_t be = ggml_backend_dev_init(nm_gpu_dev, NULL);

        if (be)
            return be;
        /* It opened during discovery and will not now. Give up on the GPU for
         * the rest of the process so the reporting functions stop claiming it.
         * The write only ever goes device -> NULL, never back, and a
         * pointer-sized aligned store cannot tear on any target this project
         * builds for, so a concurrent reader sees either the old device or
         * NULL - both safe answers. */
        nm_gpu_dev = NULL;
    }

    return ggml_backend_cpu_init();
}
