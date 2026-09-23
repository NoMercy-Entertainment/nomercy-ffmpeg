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

#include <stdarg.h>
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

/*
 * The guard is compiled in unless the build says Vulkan is not linked.
 *
 * The polarity matters and is deliberate: a build that FORGETS to say anything
 * gets the guard, i.e. one wasted fork. A build that forgets the other way
 * round would get a segfault on a Mesa machine. 48-whisper.sh defines
 * NM_NO_VULKAN on exactly the platforms where it sets NM_VULKAN=0 (darwin,
 * freebsd), so those stop forking for a Vulkan they do not carry.
 */
#if !defined(_WIN32) && !defined(__APPLE__) && !defined(NM_NO_VULKAN)
#define NM_VK_ICD_GUARD 1
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
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
    /* Driver names, plus the two full phrases a driver actually uses to
     * describe itself. A bare "software" marker was here first and was too
     * broad: it would reject a legitimate device whose description merely
     * contains the word (a "Software Defined ..." product name, say). */
    static const char *const markers[] = {
        "llvmpipe", "swiftshader", "lavapipe", "softpipe",
        "software rasterizer", "software rasteriser", NULL,
    };
    const char *name = ggml_backend_dev_name(dev);
    const char *desc = ggml_backend_dev_description(dev);
    int i;

    for (i = 0; markers[i]; i++)
        if (nm_str_contains_ci(name, markers[i]) || nm_str_contains_ci(desc, markers[i]))
            return 1;

    return 0;
}

/* What a full enumeration found. Also the byte the child process sends back,
 * so the values are small and stable on purpose.
 *
 * CRASHED and UNKNOWN are deliberately different answers and the difference is
 * load bearing. CRASHED means we PROVED Vulkan is dangerous here, which is the
 * only thing that justifies rewriting the process's loader configuration.
 * UNKNOWN means we could not find out - and "could not find out" must never
 * turn a healthy machine into one whose Vulkan we have switched off. */
#define NM_VK_OK_GPU    0   /* survived; a hardware GPU is usable      */
#define NM_VK_NO_GPU    1   /* survived; nothing usable, nothing scary */
#define NM_VK_SOFTWARE  2   /* survived; a software device is present  */
#define NM_VK_CRASHED   3   /* died or hung inside Vulkan: dangerous   */
#define NM_VK_UNKNOWN   4   /* could not be tested: change nothing     */

/* At most this many GPU/IGPU devices are tracked by index. Machines with more
 * than sixteen are not a case this project has; the seventeenth simply reports
 * as "no GPU at that index", which is the same honest answer an out-of-range
 * gpu_device already gets. */
#define NM_MAX_GPUS 16

/* Enumerate, and (when `verify` is set) open the first usable device. This is
 * the work that can crash, which is exactly why it is also what the child
 * process runs: the check and the thing being checked are the same code.
 * `out`/`out_n` receive the GPU/IGPU devices IN ENUMERATION ORDER, which is
 * whisper.cpp's own gpu_device ordering; the child passes NULL for both.
 *
 * `verify` exists because opening a Vulkan device is the expensive part of all
 * this (ggml_vk_init builds pipelines). The child always verifies - that is
 * its whole job. The parent skips it when a child already proved this exact
 * configuration opens. Only the first device is opened: the safety property
 * this whole guard is about (no software rasteriser anywhere in the list) is
 * index-independent, and opening every device on a multi-GPU box to prove a
 * point would cost half a second each. An index whose device turns out not to
 * open still falls back to the CPU, in nm_ggml_backend_init(). */
static int nm_vk_scan(ggml_backend_dev_t *out, int *out_n, int verify)
{
    ggml_backend_dev_t first = NULL;
    int found = 0;
    size_t i, n;

    if (out_n)
        *out_n = 0;

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
         * gpu_device index is "none of them are software". */
        if (nm_device_is_software(dev))
            return NM_VK_SOFTWARE;

        if (!first) {
            if (!verify) {
                first = dev;
            } else {
                /* Prove it really opens. A device that enumerates but cannot
                 * be initialised is the last cheap failure we can still turn
                 * into a clean CPU fallback - and opening it is also where a
                 * driver that enumerates happily still has time to die. */
                ggml_backend_t probe = ggml_backend_dev_init(dev, NULL);

                if (probe) {
                    ggml_backend_free(probe);
                    first = dev;
                } else {
                    /* Device 0 does not open. Nothing here is usable, because
                     * a caller asking for index 1 would be counting from a
                     * list whose index 0 we just rejected. */
                    return NM_VK_NO_GPU;
                }
            }
        }

        if (out && found < NM_MAX_GPUS)
            out[found] = dev;
        if (found < NM_MAX_GPUS)
            found++;
    }

    if (out_n)
        *out_n = found;
    return first ? NM_VK_OK_GPU : NM_VK_NO_GPU;
}

/* What the guard did, for a human. NULL when it did nothing worth saying,
 * which is the case on every machine where nothing was wrong. Both filters
 * print it once; see nm_ggml_backend_notice(). */
static char nm_vk_notice[512];

#ifdef NM_VK_ICD_GUARD

static void nm_vk_say(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(nm_vk_notice, sizeof(nm_vk_notice), fmt, ap);
    va_end(ap);
}

/* Budgets.
 *
 * The first version of this had only a 30 s per-probe timeout, and that is not
 * the number that matters: nm_vk_make_safe() probes once for the whole set,
 * once per manifest and once to confirm, so anything that hangs the CHILD -
 * a wedged driver, a driver .so on a stalled mount, a lock inherited across
 * fork - hangs every one of them. Measured with three ICDs whose
 * vk_icdNegotiateLoaderICDInterfaceVersion sleeps forever: 124 seconds of dead
 * air before the first frame, with an analytic bound of 30 x 66 = 33 minutes at
 * NM_VK_MAX_ICDS = 64.
 *
 * So the whole guard gets ONE wall-clock budget, checked before every probe,
 * and the per-probe cap is the smaller of its own limit and what is left. For
 * scale: the clean path measures 8 ms, the Mesa bisect 410 ms, and a real
 * device open a few hundred ms. Both are overridable for a machine with a
 * pathologically slow driver, because the failure mode of too small a budget
 * is only "no GPU". */
#define NM_VK_BUDGET_MS_DEFAULT 8000
#define NM_VK_PROBE_MS_DEFAULT  5000

static long nm_vk_env_ms(const char *name, long dflt)
{
    const char *v = getenv(name);
    char *end = NULL;
    long n;

    if (!v || !*v)
        return dflt;
    n = strtol(v, &end, 10);
    if (!end || *end || n <= 0)
        return dflt;
    return n;
}

static long nm_now_ms(void)
{
    struct timespec ts;

#if defined(CLOCK_MONOTONIC)
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
        return (long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
    return (long) time(NULL) * 1000;
}

/*
 * Find out whether Vulkan can be touched at all, by touching it somewhere the
 * answer cannot hurt: a forked child.
 *
 * This replaces the manifest-name heuristic this task was originally specified
 * with. That heuristic was measurably wrong - see the driver table at the top
 * of this section: Mesa's radeon and gfxstream ICDs crash a static binary just
 * as lvp does, and no string in their manifests says so.
 *
 * The verdict comes back over a PIPE, not from the exit status, and that is
 * not a style choice. waitpid() fails with ECHILD whenever the host has
 * SIGCHLD set to SIG_IGN or SA_NOCLDWAIT, or when another thread reaps with
 * waitpid(-1, ...) first - both ordinary in a daemon, and this code ships into
 * a long-lived media server. Deriving the verdict from waitpid meant a
 * perfectly healthy machine read as "unsafe" on every probe and had its Vulkan
 * switched off process-wide, FFmpeg's own -init_hw_device vulkan and
 * libplacebo included. A byte on a pipe is immune to every SIGCHLD policy, to
 * a racing reaper, and to ECHILD; waitpid is kept purely to reap, and its
 * result is ignored.
 *
 * `icd` restricts the child to one manifest (the bisect below), or is NULL to
 * test the loader's own search path unchanged.
 *
 * Returns NM_VK_CRASHED when the child died or hung - proof that Vulkan is
 * dangerous here - and NM_VK_UNKNOWN when we could not even run the test.
 */
static int nm_vk_probe(const char *icd, long deadline_ms)
{
    int fds[2];
    pid_t pid;
    unsigned char verdict = 0;
    int got = 0;
    long budget = deadline_ms - nm_now_ms();
    long cap = nm_vk_env_ms("NOMERCY_VK_PROBE_MS", NM_VK_PROBE_MS_DEFAULT);

    if (budget <= 0)
        return NM_VK_UNKNOWN;
    if (budget < cap)
        cap = budget;

    /* pipe() + FD_CLOEXEC rather than pipe2(): pipe2 needs _GNU_SOURCE, which
     * this file is not compiled with on every platform, and the race the
     * atomic version closes (another thread exec-ing between the two calls)
     * does not exist here - nothing in FFmpeg execs. */
    if (pipe(fds) != 0)
        return NM_VK_UNKNOWN;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);

    pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return NM_VK_UNKNOWN;
    }

    if (pid == 0) {
        /* No core files. A crashing probe is EXPECTED here - the Mesa bisect
         * crashes three children per process start - and this binary is ~66 MB
         * static plus Vulkan's mappings. On a host with systemd-coredump or
         * apport that is megabytes of garbage and a pile of log noise for
         * every ffmpeg invocation, and the media server invokes ffmpeg per
         * file. */
        {
            struct rlimit rl = { 0, 0 };

            setrlimit(RLIMIT_CORE, &rl);
        }
#if defined(__linux__) && defined(PR_SET_DUMPABLE)
        prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
#endif
        close(fds[0]);

        /* ggml and the Vulkan loader both write to stderr while enumerating;
         * the parent is about to do the same enumeration for real, so let its
         * output be the one the user sees. */
        {
            int fd = open("/dev/null", O_WRONLY);

            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                if (fd > STDERR_FILENO)
                    close(fd);
            }
        }
        if (icd) {
            setenv("VK_ICD_FILENAMES", icd, 1);
            setenv("VK_DRIVER_FILES", icd, 1);
        }

        verdict = (unsigned char) nm_vk_scan(NULL, NULL, 1);
        /* The byte is the whole result. Write it before _exit so that no
         * atexit handler of the parent's, and no exit-status policy of the
         * host's, can come between the answer and the reader. */
        {
            ssize_t ignored = write(fds[1], &verdict, 1);

            (void) ignored;
        }
        _exit(verdict);
    }

    close(fds[1]);

    /* Wait on the pipe with a real monotonic deadline. The previous version
     * busy-polled 200 times a second and counted loop iterations as
     * milliseconds, which made the timeout both imprecise and dependent on
     * signal delivery. */
    {
        long probe_deadline = nm_now_ms() + cap;

        for (;;) {
            struct pollfd pfd;
            long left = probe_deadline - nm_now_ms();
            int r;

            if (left <= 0)
                break;
            pfd.fd = fds[0];
            pfd.events = POLLIN;
            pfd.revents = 0;
            r = poll(&pfd, 1, (int) (left > 1000 ? 1000 : left));
            if (r < 0) {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (r == 0)
                continue;
            r = (int) read(fds[0], &verdict, 1);
            if (r == 1) {
                got = 1;
                break;
            }
            /* read() == 0 is EOF: the child closed the pipe without writing,
             * i.e. it died before it could answer. */
            if (r == 0)
                break;
            if (errno == EINTR)
                continue;
            break;
        }
    }

    close(fds[0]);

    /* Reap, and do not care what it says. On a host that ignores SIGCHLD there
     * may be nothing left to reap at all; that is fine, the answer is already
     * in hand. */
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR)
        ;

    if (!got)
        return NM_VK_CRASHED;
    return verdict <= NM_VK_SOFTWARE ? (int) verdict : NM_VK_CRASHED;
}

/* The loader's own search path.
 *
 * This list used to be shorter than the loader's, which is the wrong direction:
 * an ICD we cannot SEE is one the bisect cannot rescue, and on NixOS, Flatpak,
 * Snap and Guix layouts the real driver lives in a directory reached only
 * through XDG_DATA_DIRS or XDG_CONFIG_DIRS. Measured: with Mesa's manifests
 * moved to a directory reachable only via XDG_DATA_DIRS, the bisect found zero
 * candidates and the machine lost Vulkan entirely. Now every prefix the loader
 * consults is walked, with the loader's documented defaults when the variables
 * are unset. */
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
        while ((e = readdir(d))) {
            size_t len = strlen(e->d_name);
            char full[1024];
            char *dup;

            if (len < 6 || strcmp(e->d_name + len - 5, ".json"))
                continue;
            if (*n >= NM_VK_MAX_ICDS) {
                nm_vk_say("more than %d vulkan driver manifests were found; "
                          "only the first %d were checked",
                          NM_VK_MAX_ICDS, NM_VK_MAX_ICDS);
                break;
            }
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

/* Every "<prefix>/vulkan/icd.d" named by a colon-separated variable, or by
 * `dflt` when that variable is unset - which is how the loader reads
 * XDG_DATA_DIRS and XDG_CONFIG_DIRS. */
static void nm_vk_add_xdg_list(char **cand, int *nc, const char *var, const char *dflt)
{
    const char *v = getenv(var);
    const char *s;

    if (!v || !*v)
        v = dflt;
    if (!v || !*v)
        return;

    s = v;
    while (*s && *nc < NM_VK_MAX_ICDS) {
        const char *e = strchr(s, ':');
        size_t len = e ? (size_t) (e - s) : strlen(s);
        char full[1024];

        if (len && len < sizeof(full) - 20) {
            memcpy(full, s, len);
            full[len] = 0;
            /* Trim a trailing slash so the join never produces "//". */
            while (len > 1 && full[len - 1] == '/')
                full[--len] = 0;
            snprintf(full + len, sizeof(full) - len, "/vulkan/icd.d");
            nm_vk_add_candidate(cand, nc, full);
        }
        if (!e)
            break;
        s = e + 1;
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
    int nc = 0;
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

    /* The per-user directories first, matching the loader's own precedence,
     * then the system ones. XDG_CONFIG_* and XDG_DATA_* are both consulted;
     * the defaults are the loader's documented ones. */
    {
        const char *home = getenv("HOME");
        const char *xch = getenv("XDG_CONFIG_HOME");
        const char *xdh = getenv("XDG_DATA_HOME");
        char full[1024];

        if (xch && *xch) {
            snprintf(full, sizeof(full), "%s/vulkan/icd.d", xch);
            nm_vk_add_candidate(cand, &nc, full);
        } else if (home && *home) {
            snprintf(full, sizeof(full), "%s/.config/vulkan/icd.d", home);
            nm_vk_add_candidate(cand, &nc, full);
        }
        if (xdh && *xdh) {
            snprintf(full, sizeof(full), "%s/vulkan/icd.d", xdh);
            nm_vk_add_candidate(cand, &nc, full);
        } else if (home && *home) {
            snprintf(full, sizeof(full), "%s/.local/share/vulkan/icd.d", home);
            nm_vk_add_candidate(cand, &nc, full);
        }
    }
    nm_vk_add_xdg_list(cand, &nc, "XDG_CONFIG_DIRS", "/etc/xdg");
    nm_vk_add_xdg_list(cand, &nc, "XDG_DATA_DIRS", "/usr/local/share:/usr/share");
    nm_vk_add_candidate(cand, &nc, "/etc/vulkan/icd.d");
    nm_vk_add_candidate(cand, &nc, "/usr/local/etc/vulkan/icd.d");
    nm_vk_add_candidate(cand, &nc, "/usr/local/share/vulkan/icd.d");
    nm_vk_add_candidate(cand, &nc, "/usr/share/vulkan/icd.d");

    return nc;
}

static void nm_vk_pin(const char *value)
{
    /* Set BOTH names. A loader new enough to prefer VK_DRIVER_FILES ignores
     * VK_ICD_FILENAMES entirely, so writing only the old name would leave a
     * user-set VK_DRIVER_FILES in force.
     *
     * This is a real, load-bearing side effect on the whole process, and it is
     * documented as such in nm_ggml_cpu.h: the Vulkan loader is global, so
     * FFmpeg's own vulkan hwaccel and libplacebo read what we write here. It
     * happens only when a probe PROVED Vulkan crashes this process, or when we
     * can hand the loader a strictly better (hardware-only) list. It never
     * happens because a probe was inconclusive. */
    setenv("VK_ICD_FILENAMES", value, 1);
    setenv("VK_DRIVER_FILES", value, 1);
}

/* Set when the guard could not determine anything. The parent must then not
 * enumerate either: we have neither proof that it is safe nor a pin that would
 * make it safe. */
static int nm_vk_inconclusive;

/*
 * Leave this process able to enumerate Vulkan without dying.
 *
 * Fast path, and the one every ordinary machine takes: probe the loader's own
 * configuration once. If the child came back clean - with a hardware GPU or
 * with nothing at all - the environment is left exactly as the user set it.
 *
 * Slow path: the probe crashed, hung, or reported a software rasteriser. Probe
 * each manifest on its own and keep the ones that come back clean AND
 * hardware. This is what saves the ordinary Linux desktop with an NVIDIA card
 * AND Mesa installed: dropping the whole list on the first crash would cost
 * that machine its GPU.
 *
 * What the guard does at the end depends on WHY it got here, and the
 * distinction is the difference between degrading and breaking:
 *
 *   crashed, survivors      -> pin the survivors
 *   crashed, no survivors   -> pin /nonexistent.json; Vulkan really does kill
 *                              this process and there is nothing else to do
 *   software, survivors     -> pin the survivors: strictly better than what
 *                              the loader had, hardware instead of llvmpipe
 *   software, no survivors  -> change NOTHING. Nothing crashed. ggml simply
 *                              will not use this device (nm_vk_scan already
 *                              refuses it), and FFmpeg's own filters, which
 *                              run happily on llvmpipe, keep it
 *   could not test          -> change NOTHING, and do not enumerate either
 */
static void nm_vk_make_safe(void)
{
    char *cand[NM_VK_MAX_ICDS];
    char joined[8192];
    size_t off = 0;
    int nc, i, kept = 0, dropped = 0, truncated = 0;
    const char *guard = getenv("NOMERCY_VK_ICD_GUARD");
    long deadline = nm_now_ms() + nm_vk_env_ms("NOMERCY_VK_GUARD_MS", NM_VK_BUDGET_MS_DEFAULT);
    int verdict;

    /* The escape hatch, and the harness's way of reproducing the pre-guard
     * crash without a second binary. */
    if (guard && !strcmp(guard, "0"))
        return;

    verdict = nm_vk_probe(NULL, deadline);
    if (verdict == NM_VK_OK_GPU || verdict == NM_VK_NO_GPU)
        return;
    if (verdict == NM_VK_UNKNOWN) {
        nm_vk_inconclusive = 1;
        nm_vk_say("could not test the vulkan drivers (fork or pipe failed); "
                  "running on the CPU and leaving the loader configuration alone");
        return;
    }

    nc = nm_vk_collect_icds(cand);

    joined[0] = 0;
    for (i = 0; i < nc; i++) {
        int pv = nm_vk_probe(cand[i], deadline);

        if (pv == NM_VK_UNKNOWN) {
            /* Out of budget, or we cannot fork any more. Either way the rest
             * of the list is unexamined; say so rather than pretending those
             * manifests were rejected on their merits. */
            truncated = nc - i;
            for (; i < nc; i++)
                free(cand[i]);
            break;
        }
        if (pv == NM_VK_OK_GPU) {
            size_t len = strlen(cand[i]);

            if (off + len + 2 < sizeof(joined)) {
                if (kept)
                    joined[off++] = ':';
                memcpy(joined + off, cand[i], len);
                off += len;
                joined[off] = 0;
                kept++;
            } else {
                truncated++;
            }
        } else {
            dropped++;
        }
        free(cand[i]);
    }

    if (kept) {
        nm_vk_pin(joined);
        /* Each survivor was proven on its own; the union was not. One more
         * fork settles it, and only when there is more than one to combine. */
        if (kept > 1 && nm_vk_probe(NULL, deadline) == NM_VK_CRASHED) {
            nm_vk_pin("/nonexistent.json");
            nm_vk_say("every combination of this machine's vulkan drivers "
                      "crashes a static binary; vulkan disabled for this process");
            return;
        }
        nm_vk_say("%d of %d vulkan driver%s could not be used safely and %s "
                  "disabled for this process%s",
                  dropped, dropped + kept, dropped == 1 ? "" : "s",
                  dropped == 1 ? "was" : "were",
                  truncated ? " (and some were not checked at all: the guard ran out of time)" : "");
        return;
    }

    if (verdict == NM_VK_CRASHED) {
        nm_vk_pin("/nonexistent.json");
        nm_vk_say("this machine's vulkan drivers crash a statically linked "
                  "binary; vulkan disabled for this process%s",
                  truncated ? " (the guard also ran out of time before checking them all)" : "");
        return;
    }

    /* Software only, and nothing crashed: leave the loader alone. */
    nm_vk_say("the only vulkan device here is a software rasteriser; "
              "running on the CPU (the loader configuration is unchanged)");
}

#else  /* !NM_VK_ICD_GUARD */

/* Windows, darwin, and any build that says Vulkan is not linked. Windows'
 * loader did not reproduce the crash (Task 1, on this project's own RTX 3070
 * host) and has no manifest directory of this shape. */
static int nm_vk_inconclusive;
static void nm_vk_make_safe(void) { }

#endif /* NM_VK_ICD_GUARD */

/* The GPU/IGPU devices, in ggml enumeration order, which is the order
 * whisper.cpp's gpu_device counts in. nm_gpu_n is 0 whenever the GPU path is
 * unusable for any reason, so every accessor below can key off it alone. */
static ggml_backend_dev_t nm_gpu_devs[NM_MAX_GPUS];
static const char *nm_gpu_descs[NM_MAX_GPUS];
static int nm_gpu_n;
static char nm_gpu_backend_name[32];

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
 * af_whisper.c calls nm_ggml_gpu_usable() unconditionally, on its own line,
 * before that call. It used to be the right-hand side of an && with the
 * filter's use_gpu option, which short-circuited the guard away on exactly the
 * option a user reaches for when a GPU is causing trouble.
 */
static void nm_backend_discover(void)
{
    ggml_backend_dev_t devs[NM_MAX_GPUS];
    ggml_backend_reg_t reg;
    const char *reg_name;
    int verified = 0;
    int n = 0, i;

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

    /* The guard could not test anything, so it also could not make anything
     * safe. Enumerating now would be exactly the unguarded call it exists to
     * prevent. */
    if (nm_vk_inconclusive)
        return;

#ifdef NM_VK_ICD_GUARD
    /* A child already opened the first device under this configuration, so the
     * parent does not need to open it again just to prove it can. */
    verified = 1;
#endif
    if (getenv("NOMERCY_VK_ICD_GUARD") && !strcmp(getenv("NOMERCY_VK_ICD_GUARD"), "0"))
        verified = 0;

    if (nm_vk_scan(devs, &n, !verified) != NM_VK_OK_GPU || n <= 0)
        return;

    reg = ggml_backend_dev_backend_reg(devs[0]);
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
     * once by ggml_backend_vk_reg_get_device() and never freed, so caching the
     * description pointers is sound. */
    for (i = 0; i < n; i++) {
        nm_gpu_devs[i] = devs[i];
        nm_gpu_descs[i] = ggml_backend_dev_description(devs[i]);
    }
    nm_gpu_n = n;
}

/* One device by index, or NULL when that index has nothing usable behind it -
 * which includes "the GPU path is off entirely", since nm_gpu_n stays 0 then. */
static ggml_backend_dev_t nm_gpu_at(int gpu_device)
{
    if (gpu_device < 0 || gpu_device >= nm_gpu_n)
        return NULL;
    return nm_gpu_devs[gpu_device];
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
    return nm_gpu_n > 0;
}

int nm_ggml_gpu_count(void)
{
    nm_backend_once();
    return nm_gpu_n;
}

const char *nm_ggml_backend_name(int gpu_device)
{
    nm_backend_once();
    return nm_gpu_at(gpu_device) ? nm_gpu_backend_name : "cpu";
}

const char *nm_ggml_backend_device(int gpu_device)
{
    nm_backend_once();
    return nm_gpu_at(gpu_device) ? nm_gpu_descs[gpu_device]
                                 : nm_ggml_cpu_variant_name();
}

const char *nm_ggml_backend_notice(void)
{
    nm_backend_once();
    return nm_vk_notice[0] ? nm_vk_notice : NULL;
}

ggml_backend_t nm_ggml_backend_init(int use_gpu, int gpu_device)
{
    ggml_backend_dev_t dev;

    nm_backend_once();

    dev = nm_gpu_at(gpu_device);
    if (use_gpu && dev) {
        ggml_backend_t be = ggml_backend_dev_init(dev, NULL);

        if (be)
            return be;
        /* It opened during discovery and will not now. Nothing is written back
         * to the shared state here: an earlier version cleared nm_gpu_dev,
         * which is a data race however benign the values are. Callers learn
         * what they actually got from the backend they are handed -
         * af_stemsplit.c asks ggml_backend_is_cpu() - which is both race free
         * and more truthful than a global flag could be. */
    }

    return ggml_backend_cpu_init();
}
