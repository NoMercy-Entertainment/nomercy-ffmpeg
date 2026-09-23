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
 */
#include "nm_ggml_cpu.h"

#ifdef NM_GGML_CPU_FIXED

const char *nm_ggml_cpu_variant_name(void)
{
    return NM_GGML_CPU_FIXED;
}

#else /* !NM_GGML_CPU_FIXED */

#include <stdlib.h>
#include <string.h>

#include <ggml-backend.h>
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
