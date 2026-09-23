# ggml CPU Hardware Acceleration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make whisper and stemsplit run at the speed each host CPU allows, on all seven shipped platforms, without raising the hardware floor and without giving up fully static binaries.

**Architecture:** ggml's CPU backend is built several times per platform at different instruction-set levels. Each build is partially linked into one object whose symbols are made unique, and all of them go into the same static binary. A small dispatcher defines the unprefixed ggml CPU API (`ggml_backend_cpu_reg` and friends) and forwards it to the best variant the running CPU supports, so ggml-base's own registration picks up exactly one backend and no other code changes shape.

**Tech Stack:** bash build scripts, CMake (whisper.cpp v1.9.1 / ggml 0.15.1), GNU binutils `ld -r` + `objcopy`, llvm-mingw binutils for windows-aarch64, C (dispatcher), Docker for local verification.

**Spec:** `docs/superpowers/specs/2026-09-23-ggml-cpu-hardware-acceleration-design.md`

## Global Constraints

- **No machine that runs v1.0.42 may fail to run the result.** Floors that must hold: ARMv8.0 (Raspberry Pi 4) on linux-aarch64; Ivy Bridge (no AVX2/FMA) on darwin-x86_64; no-AVX Goldmont/Gemini Lake on the x86 targets; ARMv8.0 on windows-aarch64.
- **Binaries stay fully static.** No new file in any archive, no new runtime dependency, no glibc floor. A dynamically linked ffmpeg is out of bounds.
- **No patch to ggml or whisper.cpp sources.** Everything is build-system plus one new source file of our own.
- **i8mm must not be used on windows-aarch64** — Windows has no feature flag for it and inferring it from the SVE flag is wrong on Oryon.
- Variant matrix per platform is fixed by the spec §7.5. x86 targets: `x64`, `sse42`, `ivybridge`, `haswell`. linux-aarch64: ARMv8.0, ARMv8.2+dotprod+fp16, +i8mm. windows-aarch64: ARMv8.0, ARMv8.2+dotprod+fp16. darwin-x86_64: `ivybridge` fixed. darwin-arm64: ARMv8.4+dotprod+fp16 fixed.
- **Verification compares with a tolerance, never md5.** FMA changes rounding; measured at 1 LSB / −103.6 dB on stemsplit.
- Override name: `NOMERCY_GGML_CPU`. Metadata keys: `lavfi.whisper.cpu_variant`, `lavfi.stemsplit.cpu_variant`.
- Commit messages: Conventional Commits. Commit locally; push only when the owner asks.
- Budget: ~1 MB per variant, ~4 MB per binary. Record actual archive sizes before and after.

---

### Task 1: Variant packing helper, with a self-test on ELF and COFF

The packing recipes are proven but currently live in throwaway scripts. This task makes them a maintained part of the build with a test that fails loudly if a toolchain or a whisper bump breaks them.

**Files:**
- Create: `scripts/includes/ggml_cpu_pack.sh`
- Create: `tools/ggml-variants/selftest.sh`
- Create: `tools/ggml-variants/selftest.c`

**Interfaces:**
- Produces: `nm_pack_variant <object-format> <input-archive> <prefix> <output-object>` where `<object-format>` is `elf` or `coff`, and the tool prefix comes from the environment (`NM_NM`, `NM_OBJCOPY`, `NM_LD`, defaulting to `nm`, `objcopy`, `ld`). On success the output object defines exactly the ggml CPU API symbols, each carrying `<prefix>`, and nothing else global that can clash with another variant.

- [ ] **Step 1: Write the failing self-test**

`tools/ggml-variants/selftest.c` — links two variants of ggml's CPU backend into one binary, runs an F16 matmul through each, and asserts they coexist, agree numerically, and differ in speed:

```c
/* Self-test: two packed ggml CPU variants in one static binary. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>

extern ggml_backend_reg_t lo_ggml_backend_cpu_reg(void);
extern ggml_backend_reg_t hi_ggml_backend_cpu_reg(void);
extern void lo_ggml_backend_cpu_set_n_threads(ggml_backend_t, int);
extern void hi_ggml_backend_cpu_set_n_threads(ggml_backend_t, int);

#define M 1024
#define K 1024
#define N 256

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static float *run(ggml_backend_reg_t reg, void (*setth)(ggml_backend_t, int),
                  const char *label, float *a_src, float *b_src, double *ms)
{
    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, 0);
    ggml_backend_t be = ggml_backend_dev_init(dev, NULL);
    if (!be) { printf("FAIL: %s backend init\n", label); return NULL; }
    setth(be, 4);

    struct ggml_init_params ip = { ggml_tensor_overhead() * 8 + ggml_graph_overhead(), NULL, true };
    struct ggml_context *ctx = ggml_init(ip);
    struct ggml_tensor *a = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, K, M);
    struct ggml_tensor *b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
    struct ggml_tensor *c = ggml_mul_mat(ctx, a, b);
    struct ggml_cgraph *gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, c);

    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(ctx, be);
    if (!buf) { printf("FAIL: %s alloc\n", label); return NULL; }
    ggml_fp32_to_fp16_row(a_src, (ggml_fp16_t *) a->data, (size_t) M * K);
    ggml_backend_tensor_set(b, b_src, 0, ggml_nbytes(b));

    ggml_backend_graph_compute(be, gf);
    double t0 = now();
    for (int i = 0; i < 5; i++)
        ggml_backend_graph_compute(be, gf);
    *ms = (now() - t0) * 1000.0 / 5.0;

    float *out = malloc(ggml_nbytes(c));
    ggml_backend_tensor_get(c, out, 0, ggml_nbytes(c));
    printf("  %-3s %8.2f ms/matmul\n", label, *ms);
    ggml_free(ctx);
    ggml_backend_buffer_free(buf);
    ggml_backend_free(be);
    return out;
}

int main(void)
{
    float *a = malloc(sizeof(float) * M * K), *b = malloc(sizeof(float) * K * N);
    srand(1234);
    for (size_t i = 0; i < (size_t) M * K; i++) a[i] = (rand() / (float) RAND_MAX) - 0.5f;
    for (size_t i = 0; i < (size_t) K * N; i++) b[i] = (rand() / (float) RAND_MAX) - 0.5f;

    double lo_ms = 0, hi_ms = 0;
    float *lo = run(lo_ggml_backend_cpu_reg(), lo_ggml_backend_cpu_set_n_threads, "lo", a, b, &lo_ms);
    float *hi = run(hi_ggml_backend_cpu_reg(), hi_ggml_backend_cpu_set_n_threads, "hi", a, b, &hi_ms);
    if (!lo || !hi) return 1;

    double maxdiff = 0, sum = 0;
    size_t n = (size_t) M * N;
    for (size_t i = 0; i < n; i++) {
        double d = fabs(lo[i] - hi[i]);
        if (d > maxdiff) maxdiff = d;
        sum += fabs(lo[i]);
    }
    double rel = maxdiff / (sum / n);
    printf("  relative difference %.2g, speedup %.2fx\n", rel, lo_ms / hi_ms);

    if (rel > 1e-2)   { printf("FAIL: variants disagree numerically\n"); return 1; }
    if (hi_ms >= lo_ms) { printf("FAIL: high variant is not faster - variants were merged\n"); return 1; }
    printf("PASS\n");
    return 0;
}
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
docker run --rm -v "$PWD:/repo" ubuntu:24.04 bash /repo/tools/ggml-variants/selftest.sh elf
```

Expected: FAIL — `scripts/includes/ggml_cpu_pack.sh: No such file or directory`.

- [ ] **Step 3: Write the packing helper**

`scripts/includes/ggml_cpu_pack.sh`:

```bash
#!/bin/bash
# Pack one ggml CPU backend build into a single object whose symbols cannot
# clash with another variant of the same backend in the same binary.
#
# The two recipes differ because the object formats do:
#
#   ELF  - prefix EVERY symbol, which keeps COMDAT groups internally
#          consistent, then restore the names of the undefined references so
#          libc, libstdc++ and ggml-base still resolve.
#   COFF - rename only DEFINED symbols. Prefixing everything also renames the
#          COMDAT section symbols, which corrupts the section names and makes
#          the link produce an empty binary with no error.
#
# Tools are taken from NM_NM / NM_OBJCOPY / NM_LD so the same code serves the
# cross toolchains (mingw, llvm-mingw, aarch64-linux-gnu).

nm_pack_variant() {
    local format="$1" archive="$2" prefix="$3" output="$4"
    local nm="${NM_NM:-nm}" objcopy="${NM_OBJCOPY:-objcopy}" ld="${NM_LD:-ld}"
    local tmp="${output%.o}.whole.o"

    if [[ ! -f ${archive} ]]; then
        echo "nm_pack_variant: no such archive: ${archive}" >&2
        return 1
    fi

    "${ld}" -r --whole-archive "${archive}" -o "${tmp}" || return 1

    case "${format}" in
    elf)
        "${nm}" -u "${tmp}" | awk '{ print $NF }' | sort -u > "${tmp}.undef"
        "${objcopy}" --prefix-symbols="${prefix}" "${tmp}" "${tmp}.pre" || return 1
        awk -v p="${prefix}" '{ print p $1 " " $1 }' "${tmp}.undef" > "${tmp}.restore"
        "${objcopy}" --redefine-syms="${tmp}.restore" "${tmp}.pre" "${output}" || return 1
        ;;
    coff)
        "${nm}" --defined-only "${tmp}" \
            | awk -v p="${prefix}" '$2 ~ /^[TDBRWV]$/ { print $3 " " p $3 }' > "${tmp}.redef"
        "${objcopy}" --redefine-syms="${tmp}.redef" "${tmp}" "${output}" || return 1
        ;;
    *)
        echo "nm_pack_variant: unknown object format: ${format}" >&2
        return 1
        ;;
    esac

    # The entry point must exist under the prefix, or the dispatcher will not link.
    if ! "${nm}" --defined-only "${output}" | grep -q "${prefix}ggml_backend_cpu_reg"; then
        echo "nm_pack_variant: ${prefix}ggml_backend_cpu_reg missing from ${output}" >&2
        return 1
    fi
    rm -f "${tmp}" "${tmp}".*
}
```

- [ ] **Step 4: Write the self-test driver**

`tools/ggml-variants/selftest.sh` — builds two ggml CPU variants and packs them with the helper. Takes `elf` or `coff`:

```bash
#!/bin/bash
# Build two ggml CPU variants, pack them, link both into one static binary and
# assert they coexist. Usage: selftest.sh elf|coff
set -eu
FORMAT="${1:-elf}"
REPO="${REPO:-/repo}"
WORK="${WORK:-/tmp/nm-selftest}"
WHISPER_VERSION=1.9.1

apt-get update -qq >/dev/null
PKGS="cmake ninja-build git gcc g++ binutils ca-certificates"
[[ ${FORMAT} == coff ]] && PKGS="${PKGS} mingw-w64"
apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null

mkdir -p "${WORK}" && cd "${WORK}"
[[ -d whisper.cpp ]] || git clone -q --depth 1 --branch "v${WHISPER_VERSION}" \
    https://github.com/ggml-org/whisper.cpp.git

if [[ ${FORMAT} == coff ]]; then
    export NM_NM=x86_64-w64-mingw32-nm NM_OBJCOPY=x86_64-w64-mingw32-objcopy NM_LD=x86_64-w64-mingw32-ld
    CC=x86_64-w64-mingw32-gcc
    CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++"
    EXTRA_LINK="-fstack-protector-strong -lws2_32"
    # mingw headers lack THREAD_POWER_THROTTLING_STATE, same guard the real build flips
    sed -i 's|#if _WIN32_WINNT >= 0x0602|#if 0|' whisper.cpp/ggml/src/ggml-cpu/ggml-cpu.c
else
    unset NM_NM NM_OBJCOPY NM_LD || true
    CC=gcc
    CROSS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++"
    EXTRA_LINK=""
fi

build() { # tag  instruction-flags...
    local tag="$1"; shift
    [[ -f ${WORK}/inst-${tag}/lib/libggml-cpu.a ]] && return 0
    cmake -S "${WORK}/whisper.cpp" -B "${WORK}/b-${tag}" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="${WORK}/inst-${tag}" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
        -DWHISPER_BUILD_TOOLS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF ${CROSS} "$@" >"${WORK}/log-${tag}.txt" 2>&1
    ninja -j"$(nproc)" -C "${WORK}/b-${tag}" >>"${WORK}/log-${tag}.txt" 2>&1
    ninja -C "${WORK}/b-${tag}" install >>"${WORK}/log-${tag}.txt" 2>&1
    # the windows build installs unprefixed archive names
    [[ -f ${WORK}/inst-${tag}/lib/ggml-cpu.a ]] && \
        mv "${WORK}/inst-${tag}/lib/ggml-cpu.a" "${WORK}/inst-${tag}/lib/libggml-cpu.a"
    [[ -f ${WORK}/inst-${tag}/lib/ggml-base.a ]] && \
        mv "${WORK}/inst-${tag}/lib/ggml-base.a" "${WORK}/inst-${tag}/lib/libggml-base.a"
    return 0
}

build lo -DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF
build hi -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON

source "${REPO}/scripts/includes/ggml_cpu_pack.sh"
nm_pack_variant "${FORMAT}" "${WORK}/inst-lo/lib/libggml-cpu.a" lo_ "${WORK}/lo.o"
nm_pack_variant "${FORMAT}" "${WORK}/inst-hi/lib/libggml-cpu.a" hi_ "${WORK}/hi.o"

${CC} -O2 -I"${WORK}/inst-lo/include" "${REPO}/tools/ggml-variants/selftest.c" -static \
    "${WORK}/lo.o" "${WORK}/hi.o" "${WORK}/inst-lo/lib/libggml-base.a" \
    -lstdc++ -lm -lpthread ${EXTRA_LINK} -o "${WORK}/selftest${FORMAT/coff/.exe}"
echo "built ${WORK}/selftest${FORMAT/coff/.exe}"
[[ ${FORMAT} == elf ]] && "${WORK}/selftest"
exit 0
```

- [ ] **Step 5: Run the ELF self-test and verify it passes**

```bash
docker run --rm -v "$PWD:/repo" ubuntu:24.04 bash /repo/tools/ggml-variants/selftest.sh elf
```

Expected: `PASS`, with the high variant several times faster than the low one. If it prints `FAIL: high variant is not faster`, the two variants were merged by the linker and the recipe is broken — stop and fix before continuing.

- [ ] **Step 6: Build the COFF self-test and run it on Windows**

```bash
docker run --rm -v "$PWD:/repo" -v "$TMP/nm:/tmp/nm-selftest" ubuntu:24.04 \
    bash /repo/tools/ggml-variants/selftest.sh coff
"$TMP/nm/selftest.exe"
```

Expected: `PASS`. (The Docker step only builds; the binary is run on the Windows host.)

- [ ] **Step 7: Commit**

```bash
git add scripts/includes/ggml_cpu_pack.sh tools/ggml-variants/
git commit -m "build(ggml): add CPU backend variant packing helper with self-test"
```

---

### Task 2: The dispatcher

The dispatcher defines the unprefixed ggml CPU API that ggml-base and the filters already reference, and forwards each call to the best variant for the running CPU. Nothing else in the build has to know variants exist.

**Files:**
- Create: `scripts/includes/ggml_cpu_dispatch.c`
- Create: `scripts/includes/nm_ggml_cpu.h`
- Create: `tools/ggml-variants/dispatch-test.sh`

**Interfaces:**
- Consumes: packed variant objects from Task 1, each exposing `<prefix>ggml_backend_cpu_reg`, `<prefix>ggml_backend_cpu_init`, `<prefix>ggml_backend_cpu_set_n_threads`, `<prefix>ggml_backend_is_cpu`.
- Consumes: a generated header `nm_ggml_cpu_variants.h` (written by Task 3's build script) of the form:

```c
/* generated - do not edit */
#define NM_GGML_CPU_VARIANTS \
    X(nm_v0_, "x64",       NM_CPU_FEAT_BASELINE) \
    X(nm_v1_, "sse42",     NM_CPU_FEAT_SSE42)    \
    X(nm_v2_, "ivybridge", NM_CPU_FEAT_AVX_F16C) \
    X(nm_v3_, "haswell",   NM_CPU_FEAT_AVX2_FMA)
```

- Produces: `const char *nm_ggml_cpu_variant_name(void)` — the selected variant's name, for logging and frame metadata. Declared in `nm_ggml_cpu.h`, which the build installs to `${PREFIX}/include/`.

- [ ] **Step 1: Write the failing test**

`tools/ggml-variants/dispatch-test.sh` asserts three behaviours: the dispatcher picks the best supported variant, `NOMERCY_GGML_CPU` forces one, and an unsupported request falls back instead of crashing.

```bash
#!/bin/bash
# Assert the dispatcher's selection behaviour. Reuses the two variants built by
# selftest.sh (lo = sse42, hi = avx2+fma+f16c).
set -eu
REPO="${REPO:-/repo}"
WORK="${WORK:-/tmp/nm-selftest}"

cat > "${WORK}/dispatch_main.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "nm_ggml_cpu.h"
int main(void)
{
    const char *v = nm_ggml_cpu_variant_name();
    printf("%s\n", v ? v : "(null)");
    return v ? 0 : 1;
}
EOF

gcc -O2 -I"${WORK}/inst-lo/include" -I"${REPO}/scripts/includes" -I"${WORK}" \
    "${WORK}/dispatch_main.c" "${REPO}/scripts/includes/ggml_cpu_dispatch.c" -static \
    "${WORK}/lo.o" "${WORK}/hi.o" "${WORK}/inst-lo/lib/libggml-base.a" \
    -lstdc++ -lm -lpthread -o "${WORK}/dispatch_test"

fail=0
check() { # description expected actual
    if [[ "$3" == "$2" ]]; then echo "  ok: $1 -> $3"; else echo "  FAIL: $1 -> got '$3', want '$2'"; fail=1; fi
}
check "auto-select on an AVX2 host" "haswell"  "$("${WORK}/dispatch_test")"
check "override to baseline"        "sse42"    "$(NOMERCY_GGML_CPU=sse42 "${WORK}/dispatch_test")"
check "unknown override falls back" "haswell"  "$(NOMERCY_GGML_CPU=nonsense "${WORK}/dispatch_test")"
[[ ${fail} -eq 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
docker run --rm -v "$PWD:/repo" -v "$TMP/nm:/tmp/nm-selftest" ubuntu:24.04 \
    bash -c "apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gcc g++ >/dev/null && bash /repo/tools/ggml-variants/dispatch-test.sh"
```

Expected: FAIL — `ggml_cpu_dispatch.c: No such file or directory`.

- [ ] **Step 3: Write the header**

`scripts/includes/nm_ggml_cpu.h`:

```c
/*
 * Which ggml CPU backend variant this process selected.
 *
 * The binary carries several instruction-set variants of ggml's CPU backend;
 * ggml_cpu_dispatch.c picks one the first time ggml asks for a CPU backend.
 * Returns a stable string such as "x64", "sse42", "ivybridge", "haswell",
 * or an ARM level such as "armv8.2+dotprod+fp16".
 */
#ifndef NM_GGML_CPU_H
#define NM_GGML_CPU_H

#ifdef __cplusplus
extern "C" {
#endif

const char *nm_ggml_cpu_variant_name(void);

#ifdef __cplusplus
}
#endif

#endif /* NM_GGML_CPU_H */
```

- [ ] **Step 4: Write the dispatcher**

`scripts/includes/ggml_cpu_dispatch.c`:

```c
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
 */
#include <stdlib.h>
#include <string.h>

#include <ggml-backend.h>
#include "nm_ggml_cpu.h"
#include "nm_ggml_cpu_variants.h"

#if defined(_WIN32)
#include <windows.h>
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

/* Declare each variant's prefixed entry points. */
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
         * i8mm there, and inferring it from the SVE flag is wrong on Oryon. */
#if defined(__linux__)
        return getauxval(AT_HWCAP2) & HWCAP2_I8MM;
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
```

- [ ] **Step 5: Generate the variants header for the test and run the test**

```bash
docker run --rm -v "$PWD:/repo" -v "$TMP/nm:/tmp/nm-selftest" ubuntu:24.04 bash -c '
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gcc g++ >/dev/null
cat > /tmp/nm-selftest/nm_ggml_cpu_variants.h <<EOF
#define NM_GGML_CPU_VARIANTS \
    X(lo_, "sse42",   NM_CPU_FEAT_SSE42) \
    X(hi_, "haswell", NM_CPU_FEAT_AVX2_FMA)
EOF
bash /repo/tools/ggml-variants/dispatch-test.sh'
```

Expected: PASS, three `ok:` lines.

- [ ] **Step 6: Verify the ggml API surface is complete**

The dispatcher must define every unprefixed ggml CPU symbol the rest of the build references, or the real link in Task 3 fails. Check what whisper and the filters actually use:

```bash
docker run --rm -v "$TMP/nm:/w" ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends binutils >/dev/null
   nm -u /w/inst-lo/lib/libwhisper.a /w/inst-lo/lib/libggml-base.a 2>/dev/null \
     | awk "{print \$NF}" | grep "^ggml_backend_cpu\|^ggml_backend_is_cpu" | sort -u'
```

Expected: every symbol printed is defined in `ggml_cpu_dispatch.c`. If one is missing (for example `ggml_backend_cpu_buffer_type`), add a forwarding definition for it in the same style and re-run Step 5.

- [ ] **Step 7: Commit**

```bash
git add scripts/includes/ggml_cpu_dispatch.c scripts/includes/nm_ggml_cpu.h tools/ggml-variants/dispatch-test.sh
git commit -m "feat(ggml): add runtime CPU variant dispatcher"
```

---

### Task 3: Build the variants in 48-whisper.sh for linux-x86_64

First real platform. The build script gains a variant loop, the packing call, the generated header, and an archive that replaces `libggml-cpu.a` in the pkg-config file.

**Files:**
- Modify: `scripts/48-whisper.sh`
- Create: `tools/ggml-variants/build-common.sh` (runs the *real* build script in the base image, so the harness never drifts from what CI does)
- Create: `tools/ggml-variants/build-linux-x86_64.sh` (measures the result)

**Interfaces:**
- Consumes: `nm_pack_variant` (Task 1), `ggml_cpu_dispatch.c` + `nm_ggml_cpu.h` (Task 2).
- Produces: `${PREFIX}/lib/libggml-cpu-variants.a` containing the packed variant objects plus the compiled dispatcher; `${PREFIX}/include/nm_ggml_cpu.h`; a `whisper.pc` whose `Libs` names `-lggml-cpu-variants` in place of `-lggml-cpu`.

- [ ] **Step 1: Write the shared harness driver**

`tools/ggml-variants/build-common.sh` — takes the environment from the platform's dockerfile and runs the repo's own `48-whisper.sh` inside the base image, then builds a minimal ffmpeg against the result. One source of truth: the harness exercises the same script CI does, so it cannot drift.

```bash
#!/bin/bash
# Usage: build-common.sh <target-os> <arch> <workdir>
# Runs the repo's real 48-whisper.sh in the base image with the platform's own
# environment, then builds a minimal ffmpeg against it. Minutes, not hours.
set -eu
TARGET_OS="$1"; ARCH="$2"; WORK="$3"
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
DOCKERFILE="${REPO}/ffmpeg-${TARGET_OS}-${ARCH}.dockerfile"
IMAGE="${BASE_IMAGE:-nomercyentertainment/ffmpeg-base:latest}"

# Lift every ENV line out of the platform dockerfile so the container sees the
# same PREFIX, CC, CROSS_PREFIX, CMAKE_COMMON_ARG, CFLAGS... that CI uses.
env_args=()
while IFS= read -r line; do
    line="${line#ENV }"
    [[ ${line} == *=* ]] || continue
    env_args+=(-e "${line%%=*}=$(eval echo "${line#*=}")")
done < <(grep -E '^ENV [A-Z_]+=' "${DOCKERFILE}")

mkdir -p "${WORK}"
docker run --rm \
    -v "${REPO}/scripts:/scripts:ro" \
    -v "${WORK}:/out" \
    "${env_args[@]}" -e TARGET_OS="${TARGET_OS}" -e ARCH="${ARCH}" \
    "${IMAGE}" bash -c '
set -eu
mkdir -p /build && cd /build
log() { cat >> /ffmpeg_build.log; }
bash /scripts/48-whisper.sh
bash /scripts/60-stemsplit.sh
cd /build/ffmpeg
PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig ./configure --disable-everything --disable-autodetect \
    --disable-doc --disable-ffplay --disable-ffprobe --enable-whisper --enable-swresample \
    --enable-filter=stemsplit,whisper,aresample,aformat,anull,ametadata \
    --enable-demuxer=mp3,wav --enable-parser=mpegaudio --enable-decoder=mp3,mp3float,pcm_s16le \
    --enable-encoder=pcm_s16le --enable-muxer=wav,null --enable-protocol=file,pipe \
    --enable-runtime-cpudetect --pkg-config-flags=--static \
    ${CROSS_PREFIX:+--cross-prefix=${CROSS_PREFIX} --arch=${ARCH} --target-os=mingw32} \
    --extra-libs="-lstdc++ -lm -lpthread"
make -j"$(nproc)"
cp ffmpeg* /out/
'
echo "built into ${WORK}"
```

- [ ] **Step 2: Write the failing verification harness**

`tools/ggml-variants/build-linux-x86_64.sh` builds through `build-common.sh` and asserts speed and correctness:

```bash
#!/bin/bash
# Build a minimal linux-x86_64 ffmpeg against the variant-enabled whisper and
# check that stemsplit is fast by default and slow when forced to baseline.
set -eu
REPO="${REPO:-/repo}"
WORK="${WORK:-/vol}"
MODEL="${WORK}/spleeter-2stems-f16.gguf"
INPUT="${WORK}/input.mp3"

bash "$(dirname "$0")/build-common.sh" linux x86_64 "${WORK}"

run_stemsplit() { # env-prefix -> milliseconds
    local start=$(date +%s%N)
    env "$@" "${WORK}/ffmpeg" -hide_banner -loglevel error -nostats -y -t 30 -i "${INPUT}" -vn \
        -af "stemsplit=model=${MODEL}:stem=accompaniment" -f wav "${WORK}/out-$1.wav"
    echo $(( ($(date +%s%N) - start) / 1000000 ))
}

auto_ms=$(run_stemsplit NOMERCY_GGML_CPU=)
base_ms=$(run_stemsplit NOMERCY_GGML_CPU=x64)
echo "  auto: ${auto_ms} ms, forced baseline: ${base_ms} ms"

variant=$("${WORK}/ffmpeg" -hide_banner -v verbose -nostats -t 12 -i "${INPUT}" -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment" -f wav /dev/null 2>&1 \
    | grep -oE "cpu variant '[a-z0-9.+_]+'" | head -1)
echo "  logged: ${variant}"

fail=0
[[ ${auto_ms} -lt $(( base_ms * 2 / 3 )) ]] || { echo "  FAIL: automatic choice is not faster than baseline"; fail=1; }
[[ -n ${variant} ]] || { echo "  FAIL: no variant logged"; fail=1; }
python3 - "${WORK}/out-NOMERCY_GGML_CPU=.wav" "${WORK}/out-NOMERCY_GGML_CPU=x64.wav" <<'PY' || fail=1
import sys, wave, numpy as np
def rd(p):
    w = wave.open(p, 'rb')
    return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
a, b = rd(sys.argv[1]), rd(sys.argv[2])
n = min(len(a), len(b)); a, b = a[:n], b[:n]
rms_sig = np.sqrt((a ** 2).mean()); rms_diff = np.sqrt(((a - b) ** 2).mean())
db = 20 * np.log10(rms_diff / rms_sig) if rms_diff else -999
print(f"  variant difference: {db:.1f} dB relative")
sys.exit(0 if db < -80 else 1)
PY
[[ ${fail} -eq 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
```

- [ ] **Step 3: Run it to verify it fails**

Run the harness against a build made from the current `48-whisper.sh`.
Expected: FAIL — the automatic run is no faster than the forced baseline, and no variant is logged, because variants do not exist yet.

- [ ] **Step 4: Add the variant matrix and build loop to `scripts/48-whisper.sh`**

Insert after the existing platform-specific flag blocks, before the `cmake` invocation. This replaces the single ggml-cpu build for every platform except the two darwin targets, which take a fixed level (see Task 6):

```bash
# --- CPU backend variants -------------------------------------------------
#
# ggml compiles for one instruction-set level, and cross-compiling makes that
# level the bare x86-64 / ARMv8.0 baseline: measured 8-14x slower on whisper
# and 2.4x on stemsplit. Raising the level instead would break Raspberry Pi 4,
# Ivy Bridge Macs and pre-AVX Atom boxes. So build the backend several times
# and let ggml_cpu_dispatch.c pick one at runtime.
#
# Format: <tag>|<dispatcher feature>|<cmake flags>
nm_variant_matrix() {
    if [[ ${ARCH} == x86_64 ]]; then
        cat <<'MATRIX'
x64|NM_CPU_FEAT_BASELINE|-DGGML_SSE42=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF
sse42|NM_CPU_FEAT_SSE42|-DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF
ivybridge|NM_CPU_FEAT_AVX_F16C|-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=ON -DGGML_BMI2=OFF
haswell|NM_CPU_FEAT_AVX2_FMA|-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON
MATRIX
    else
        cat <<'MATRIX'
armv8.0|NM_CPU_FEAT_ARM_BASE|-DGGML_CPU_ARM_ARCH=armv8-a
armv8.2+dotprod+fp16|NM_CPU_FEAT_ARM_DOTPROD_FP16|-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
MATRIX
        # i8mm is not reliably detectable on Windows-on-ARM, so it is a
        # linux-aarch64 variant only.
        if [[ ${TARGET_OS} == linux ]]; then
            echo 'armv8.2+dotprod+fp16+i8mm|NM_CPU_FEAT_ARM_I8MM|-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16+i8mm'
        fi
    fi
}
```

- [ ] **Step 5: Add the per-variant build, packing and archive step**

Still in `scripts/48-whisper.sh`, after the main whisper build and install, before the `whisper.pc` is written:

```bash
source /scripts/includes/ggml_cpu_pack.sh

NM_OBJ_FORMAT=elf
[[ ${TARGET_OS} == windows ]] && NM_OBJ_FORMAT=coff
export NM_NM="${NM}" NM_OBJCOPY="${CROSS_PREFIX}objcopy" NM_LD="${LD}"

nm_variant_dir=/build/whisper-variants
rm -rf ${nm_variant_dir} && mkdir -p ${nm_variant_dir}
nm_header=${nm_variant_dir}/nm_ggml_cpu_variants.h
echo "/* generated by 48-whisper.sh - do not edit */" > ${nm_header}
echo "#define NM_GGML_CPU_VARIANTS \\" >> ${nm_header}

nm_index=0
nm_objects=""
while IFS='|' read -r nm_tag nm_feat nm_flags; do
    [[ -z ${nm_tag} ]] && continue
    log "Building ggml CPU variant ${nm_tag}"
    cmake -G Ninja -B ${nm_variant_dir}/build-${nm_tag} -S /build/whisper \
        ${WHISPER_CMAKE_COMMON_ARG} ${nm_flags} \
        -DCMAKE_INSTALL_PREFIX=${nm_variant_dir}/inst-${nm_tag} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=OFF -DWHISPER_STATIC=ON \
        -DWHISPER_BUILD_TOOLS=OFF -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: variant ${nm_tag} configure failed"; exit 1; fi
    ninja -j${NPROC} -C ${nm_variant_dir}/build-${nm_tag} ggml-cpu 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: variant ${nm_tag} build failed"; exit 1; fi

    nm_archive=$(find ${nm_variant_dir}/build-${nm_tag} -name 'libggml-cpu.a' -o -name 'ggml-cpu.a' | head -1)
    nm_pack_variant ${NM_OBJ_FORMAT} "${nm_archive}" "nm_v${nm_index}_" \
        ${nm_variant_dir}/variant-${nm_tag}.o || { log "Error: packing ${nm_tag} failed"; exit 1; }
    nm_objects="${nm_objects} ${nm_variant_dir}/variant-${nm_tag}.o"
    printf '    X(nm_v%s_, "%s", %s) \\\n' "${nm_index}" "${nm_tag}" "${nm_feat}" >> ${nm_header}
    nm_index=$((nm_index + 1))
done < <(nm_variant_matrix)
echo "" >> ${nm_header}

log "Built ${nm_index} ggml CPU variants"

${CC} ${CFLAGS} -I${nm_variant_dir} -I/scripts/includes -I${PREFIX}/include \
    -c /scripts/includes/ggml_cpu_dispatch.c -o ${nm_variant_dir}/dispatch.o 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: dispatcher build failed"; exit 1; fi

rm -f ${PREFIX}/lib/libggml-cpu-variants.a
${AR} rcs ${PREFIX}/lib/libggml-cpu-variants.a ${nm_variant_dir}/dispatch.o ${nm_objects}
cp /scripts/includes/nm_ggml_cpu.h ${PREFIX}/include/nm_ggml_cpu.h
rm -f ${PREFIX}/lib/libggml-cpu.a ${PREFIX}/lib/ggml-cpu.a
```

- [ ] **Step 6: Point `whisper.pc` at the variants archive**

In the same script, in the block that writes `whisper.pc`, replace every `-lggml-cpu` with `-lggml-cpu-variants`. There is one occurrence in `lib_flags` and, on windows, the archive rename block at the end must no longer try to rename `ggml-cpu.a`:

```bash
lib_flags="Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -lggml-cpu-variants"
```

- [ ] **Step 7: Run the harness and verify it passes**

```bash
docker run --rm -v "$PWD:/repo" -v ffblas-vol:/vol ubuntu:24.04 bash /repo/tools/ggml-variants/build-linux-x86_64.sh
```

Expected: PASS. The automatic run should be roughly 3x faster than `NOMERCY_GGML_CPU=x64`, the logged variant should be `haswell` on any modern build host, and the two outputs should differ by well under −80 dB.

- [ ] **Step 8: Verify exactly one CPU backend is registered**

A second registration would mean ggml-base found both the dispatcher's symbol and a leftover `libggml-cpu.a`:

```bash
docker run --rm -v ffblas-vol:/vol ubuntu:24.04 /vol/ffmpeg -hide_banner -v verbose \
  -f lavfi -i "anullsrc=r=16000:cl=mono" -t 1 -af "whisper=model=/vol/ggml-base.en.bin" -f null - 2>&1 \
  | grep -c "ggml_backend_registry: registered backend CPU"
```

Expected: `1`.

- [ ] **Step 9: Commit**

```bash
git add scripts/48-whisper.sh tools/ggml-variants/build-linux-x86_64.sh
git commit -m "build(ggml): build and pack CPU variants for linux-x86_64"
```

---

### Task 4: Report the selected variant from both filters

**Files:**
- Modify: `scripts/includes/af_stemsplit.c` (backend init around line 878, metadata with the other `av_dict_set` calls)
- Modify: `scripts/includes/af_whisper.c`
- Modify: `scripts/48-whisper.sh` (already copies `af_whisper.c`; no change needed if `nm_ggml_cpu.h` is on the include path)

**Interfaces:**
- Consumes: `nm_ggml_cpu_variant_name()` from `nm_ggml_cpu.h` (Task 2).
- Produces: log line `... cpu variant '<name>'` at `AV_LOG_INFO` from both filters; frame metadata `lavfi.whisper.cpu_variant` and `lavfi.stemsplit.cpu_variant`.

- [ ] **Step 1: Write the failing test**

Extend `tools/ggml-variants/build-linux-x86_64.sh` with a metadata assertion, right before the final `fail` check:

```bash
meta=$("${WORK}/ffmpeg" -hide_banner -loglevel error -nostats -t 12 -i "${INPUT}" -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.cpu_variant" \
    -f null - 2>&1 | grep -oE "lavfi.stemsplit.cpu_variant=[a-z0-9.+_]+" | head -1)
echo "  metadata: ${meta:-<none>}"
[[ -n ${meta} ]] || { echo "  FAIL: no cpu_variant metadata"; fail=1; }
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `FAIL: no cpu_variant metadata`.

- [ ] **Step 3: Add the log line and metadata to `af_stemsplit.c`**

Include the header next to the other ggml includes:

```c
#include <gguf.h>
#include "nm_ggml_cpu.h"
```

At the backend init, replace:

```c
    /* ---- backend: CPU only (design non-goal: no GPU backends) ---- */
    s->backend = ggml_backend_cpu_init();
```

with:

```c
    /* ---- backend: CPU only (design non-goal: no GPU backends) ----
     * ggml_backend_cpu_init() resolves to the instruction-set variant that
     * ggml_cpu_dispatch.c selected for this machine. */
    s->backend = ggml_backend_cpu_init();
    av_log(ctx, AV_LOG_INFO, "stemsplit: ggml cpu variant '%s'.\n",
           nm_ggml_cpu_variant_name());
```

In `ss_filter_frame`, where the filter already sets frame metadata, add:

```c
    av_dict_set(&out->metadata, "lavfi.stemsplit.cpu_variant",
                nm_ggml_cpu_variant_name(), 0);
```

- [ ] **Step 4: Add the same to `af_whisper.c`**

Include the header with the others, log once in `init()` after the context is created:

```c
    av_log(ctx, AV_LOG_INFO, "whisper: ggml cpu variant '%s'.\n",
           nm_ggml_cpu_variant_name());
```

and set the metadata next to the existing `lavfi.whisper.language` entry:

```c
    av_dict_set(&frame->metadata, "lavfi.whisper.cpu_variant",
                nm_ggml_cpu_variant_name(), 0);
```

- [ ] **Step 5: Rebuild and run the harness**

Expected: PASS, with a `metadata: lavfi.stemsplit.cpu_variant=haswell` line.

- [ ] **Step 6: Verify the whisper metadata too**

```bash
docker run --rm -v ffblas-vol:/vol ubuntu:24.04 /vol/ffmpeg -hide_banner -loglevel error -nostats \
  -i /vol/jfk.wav -af "whisper=model=/vol/ggml-base.en.bin:language=en,ametadata=mode=print:key=lavfi.whisper.cpu_variant" \
  -f null - 2>&1 | grep lavfi.whisper.cpu_variant
```

Expected: one line naming the variant.

- [ ] **Step 7: Commit**

```bash
git add scripts/includes/af_stemsplit.c scripts/includes/af_whisper.c tools/ggml-variants/build-linux-x86_64.sh
git commit -m "feat(filters): report the selected ggml cpu variant in logs and metadata"
```

---

### Task 5: windows-x86_64

**Files:**
- Modify: `scripts/48-whisper.sh` (only if the COFF path needs adjusting; the matrix and loop from Task 3 already cover it)
- Create: `tools/ggml-variants/build-windows-x86_64.sh`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: a windows-x86_64 `ffmpeg.exe` whose dispatcher selects a variant, verified on a real Windows machine.

- [ ] **Step 1: Write the failing harness**

`tools/ggml-variants/build-windows-x86_64.sh` — cross-builds and leaves the binary plus a runner script for the Windows host, since the container cannot execute it:

```bash
#!/bin/bash
# Cross-build a minimal windows-x86_64 ffmpeg against the variant-enabled
# whisper. The container only builds; run check-windows.ps1 on the Windows host.
set -eu
REPO="${REPO:-/repo}"
WORK="${WORK:-/vol/win}"
mkdir -p "${WORK}"

export NM_NM=x86_64-w64-mingw32-nm
export NM_OBJCOPY=x86_64-w64-mingw32-objcopy
export NM_LD=x86_64-w64-mingw32-ld

# Build whisper + variants exactly as scripts/48-whisper.sh does for windows,
# then a minimal ffmpeg against it. (The platform dockerfile is the real path;
# this harness exists to iterate in minutes instead of hours.)
bash "${REPO}/tools/ggml-variants/build-common.sh" windows x86_64 "${WORK}"

cat > "${WORK}/check-windows.ps1" <<'PS'
param([string]$Dir = $PSScriptRoot)
$ff = Join-Path $Dir 'ffmpeg.exe'
$model = Join-Path $Dir 'spleeter-2stems-f16.gguf'
$input = Join-Path $Dir 'input.mp3'
if ((Get-Item $ff).Length -eq 0) { Write-Host 'FAIL: ffmpeg.exe is empty - COFF packing renamed section symbols'; exit 1 }

function Run-Split([string]$variant, [string]$out) {
    $env:NOMERCY_GGML_CPU = $variant
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $ff -hide_banner -loglevel error -nostats -y -t 30 -i $input -vn `
        -af "stemsplit=model=$model:stem=accompaniment" -f wav $out | Out-Null
    $sw.ElapsedMilliseconds
}
$auto = Run-Split '' (Join-Path $Dir 'auto.wav')
$base = Run-Split 'x64' (Join-Path $Dir 'base.wav')
$env:NOMERCY_GGML_CPU = ''
$logged = (& $ff -hide_banner -v verbose -nostats -t 12 -i $input -vn `
    -af "stemsplit=model=$model:stem=accompaniment" -f wav NUL 2>&1 |
    Select-String -Pattern "cpu variant '([a-z0-9.+_]+)'" | Select-Object -First 1).Matches.Value
"  auto: $auto ms, forced baseline: $base ms"
"  logged: $logged"

$fail = 0
if ($auto -ge ($base * 2 / 3)) { Write-Host '  FAIL: automatic choice is not faster than baseline'; $fail = 1 }
if (-not $logged)              { Write-Host '  FAIL: no variant logged'; $fail = 1 }
if ($fail -eq 0) { Write-Host 'PASS' } else { exit 1 }
PS
echo "built ${WORK}/ffmpeg.exe - now run check-windows.ps1 on the Windows host"
```

Assertions are the same three as the linux harness: automatic beats forced baseline, a variant is logged, and the two outputs agree within −80 dB (compare `auto.wav` and `base.wav` with the same Python snippet used in Task 3, Step 1).

- [ ] **Step 2: Run it and watch the COFF packing**

Expected failure mode to watch for: an `ffmpeg.exe` of zero bytes. That means section symbols were renamed — the COFF branch of `nm_pack_variant` must rename defined symbols only.

- [ ] **Step 3: Confirm OpenBLAS still links**

windows-x86_64 links OpenBLAS through `ggml-blas`. The variants archive replaced `libggml-cpu.a`, and `ggml-blas` is unrelated, but the link order changed:

```bash
grep -n "ggml-blas\|ggml-cpu-variants" scripts/48-whisper.sh
```

Verify `-lggml-blas` still appears in `lib_flags` for windows-x86_64 and that `-lggml-cpu-variants` follows it.

- [ ] **Step 4: Run the binary on Windows**

```powershell
$env:NOMERCY_GGML_CPU=""; .\ffmpeg.exe -hide_banner -v verbose -t 12 -i input.mp3 -vn `
  -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f wav NUL 2>&1 | Select-String "cpu variant"
```

Expected: one line naming `haswell` on a modern CPU.

- [ ] **Step 5: Run the #64 exit-hang reproduction**

The packing changes how ggml is linked, so re-run the regression that PR #64 fixed: 20 stemsplit runs, each must exit within seconds.

```powershell
1..20 | ForEach-Object {
  $sw=[Diagnostics.Stopwatch]::StartNew()
  .\ffmpeg.exe -hide_banner -loglevel error -nostats -y -t 30 -i input.mp3 -vn `
    -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f wav out.wav
  "run $_ exit=$LASTEXITCODE ms=$($sw.ElapsedMilliseconds)"
}
```

Expected: 20 runs, all exit 0, none over ~30 s.

- [ ] **Step 6: Commit**

```bash
git add tools/ggml-variants/build-windows-x86_64.sh scripts/48-whisper.sh
git commit -m "build(ggml): enable CPU variants on windows-x86_64"
```

---

### Task 6: freebsd-x86_64 and the two darwin targets

freebsd uses the same ELF path as linux. darwin takes a fixed level instead of dispatch, because its oldest supported machine is known exactly (spec §7.5).

**Files:**
- Modify: `scripts/48-whisper.sh` (darwin branch)

**Interfaces:**
- Produces: freebsd binaries carrying four x86 variants; darwin binaries built at one fixed level with no dispatcher.

- [ ] **Step 1: Add the darwin fixed-level branch**

In `scripts/48-whisper.sh`, in the darwin block that already sets `-DGGML_METAL=OFF -DGGML_ACCELERATE=OFF`, add the instruction level and skip the variant loop:

```bash
    if [[ ${TARGET_OS} == "darwin" ]]; then
        # Fixed instruction level, not runtime dispatch: Apple controls the
        # hardware population, so the floor is known exactly. The oldest Mac
        # that runs our 10.15 deployment target is Ivy Bridge (AVX + F16C, no
        # AVX2/FMA); every Apple Silicon chip has dotprod and fp16.
        WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF"
        if [[ ${ARCH} == "x86_64" ]]; then
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_F16C=ON -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_BMI2=OFF"
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15.0"
        else
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod+fp16"
        fi
        NM_SKIP_VARIANTS=1
    fi
```

and guard the variant loop with `if [[ -z ${NM_SKIP_VARIANTS:-} ]]; then ... fi`, keeping the stock `libggml-cpu.a` and `-lggml-cpu` in `whisper.pc` on darwin.

- [ ] **Step 2: Build freebsd and verify**

Run the platform build and check the binary reports a variant:

```bash
docker build -f ffmpeg-freebsd-x86_64.dockerfile -t nm-freebsd-test . 2>&1 | tail -5
```

Expected: build succeeds; the FreeBSD binary cannot run in CI, so verification is the fleet's freebsd verifier in Task 10.

- [ ] **Step 3: Build both darwin targets and check the instruction level took effect**

```bash
docker build -f ffmpeg-darwin-x86_64.dockerfile -t nm-darwin-x64-test . 2>&1 | tail -5
docker run --rm nm-darwin-x64-test bash -c 'grep -m1 "GGML_F16C\|INS_ENB" /ffmpeg_build.log'
```

Expected: the build log shows F16C enabled. A darwin binary cannot be run in CI either; §9.2 of the spec covers it on real hardware.

- [ ] **Step 4: Commit**

```bash
git add scripts/48-whisper.sh
git commit -m "build(ggml): fixed instruction level on darwin, variants on freebsd"
```

---

### Task 7: linux-aarch64 and windows-aarch64

Open question 2 from the spec lands here: whether llvm-mingw's binutils accept the COFF recipe.

**Files:**
- Modify: `scripts/48-whisper.sh` if the llvm tools need different flags
- Create: `tools/ggml-variants/build-aarch64.sh`

**Interfaces:**
- Produces: aarch64 binaries carrying the ARM variant set, with measurements from real ARM hardware.

- [ ] **Step 1: Verify llvm-mingw's tools accept the recipe**

```bash
docker run --rm -v "$PWD:/repo" nomercyentertainment/ffmpeg-base:latest bash -c \
  'llvm-nm --version | head -1; llvm-objcopy --help | grep -c redefine-syms'
```

Expected: both tools present and `--redefine-syms` supported. If `llvm-objcopy` mangles COFF the way GNU objcopy did with `--prefix-symbols`, use the `coff` branch (defined symbols only) — which is what the matrix already selects for `TARGET_OS=windows`.

- [ ] **Step 2: Build linux-aarch64 and check the variants were produced**

```bash
docker build -f ffmpeg-linux-aarch64.dockerfile -t nm-arm64-test . 2>&1 | tail -5
docker run --rm nm-arm64-test bash -c 'grep "ggml CPU variant" /ffmpeg_build.log'
```

Expected: three lines — `armv8.0`, `armv8.2+dotprod+fp16`, `armv8.2+dotprod+fp16+i8mm`.

- [ ] **Step 3: Run the binary under emulation as a smoke check only**

```bash
docker run --rm --platform linux/arm64 -v "$PWD/output:/o" ubuntu:24.04 \
  /o/ffmpeg -hide_banner -v verbose -f lavfi -i "anullsrc=r=44100:cl=stereo" -t 12 \
  -af "stemsplit=model=/o/spleeter-2stems-f16.gguf:stem=accompaniment" -f null - 2>&1 | grep "cpu variant"
```

Expected: a variant is logged and the run completes. **Do not record timings from this step** — emulation makes them meaningless.

- [ ] **Step 4: Measure on real ARM hardware**

Required before the ARM matrix is final (spec §11.1). On the fleet's linux-aarch64 verifier:

```bash
for v in armv8.0 "armv8.2+dotprod+fp16" "armv8.2+dotprod+fp16+i8mm" ""; do
  s=$(date +%s%N)
  NOMERCY_GGML_CPU=$v ./ffmpeg -hide_banner -loglevel error -nostats -y -t 30 -i input.mp3 -vn \
     -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f wav out.wav
  echo "${v:-auto}: $(( ($(date +%s%N)-s)/1000000 )) ms"
done
```

Record the numbers in the spec's §11.1 and in the PR. If the i8mm variant is not faster than the dotprod one on available hardware, drop it from the matrix and save ~1 MB.

- [ ] **Step 5: Commit**

```bash
git add scripts/48-whisper.sh tools/ggml-variants/build-aarch64.sh docs/superpowers/specs/2026-09-23-ggml-cpu-hardware-acceleration-design.md
git commit -m "build(ggml): enable CPU variants on both aarch64 targets"
```

---

### Task 8: CI verification

**Files:**
- Modify: `tests/tests.sh` (the stemsplit test is at line 330)
- Modify: `tests/tests.ps1`
- Create: `tests/lib/cpu-variant.sh`

**Interfaces:**
- Produces: a per-platform CI assertion that a variant is selected, that the override works, and that forced-baseline and automatic output agree within tolerance.

- [ ] **Step 1: Write the failing test**

`tests/lib/cpu-variant.sh`:

```bash
#!/bin/bash
# Assert the ggml CPU variant dispatcher works in the built binary.
# Sourced by tests.sh; expects $FFMPEG to point at the binary under test.
test_cpu_variant() {
    local variant baseline
    case "$(uname -m)" in
    aarch64|arm64) baseline="armv8.0" ;;
    *)             baseline="x64" ;;
    esac

    variant=$("${FFMPEG}" -hide_banner -v verbose -nostats -t 12 -i "${TEST_MP3}" -vn \
        -af "stemsplit=model=${TEST_MODEL}:stem=accompaniment" -f null - 2>&1 \
        | grep -oE "cpu variant '[a-z0-9.+_]+'" | head -1)
    [[ -n ${variant} ]] || { echo "no cpu variant reported"; return 1; }
    echo "selected ${variant}"

    # The baseline variant must always be selectable - this is the guarantee
    # that no machine is left behind.
    NOMERCY_GGML_CPU=${baseline} "${FFMPEG}" -hide_banner -loglevel error -nostats -t 5 \
        -i "${TEST_MP3}" -vn -af "stemsplit=model=${TEST_MODEL}:stem=accompaniment" \
        -f null - || { echo "forced baseline ${baseline} failed to run"; return 1; }
    return 0
}
```

The darwin binaries carry no dispatcher (fixed level, Task 6), so this test is
skipped there: guard the call with the same `TARGET_OS` check `tests.sh` already
uses for platform-specific cases.

- [ ] **Step 2: Run the test suite to verify the new test fails**

```bash
bash tests/tests.sh
```

Expected: FAIL on `cpu_variant` until the binary under test is a variant build.

- [ ] **Step 3: Wire it into `tests/tests.sh` and `tests/tests.ps1`**

Add next to the existing `run_test "stemsplit" ...` line:

```bash
run_test "cpu_variant" "test_cpu_variant" "selected"
```

- [ ] **Step 4: Run and verify it passes against a variant build**

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: assert ggml cpu variant selection and baseline override"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md` (the whisper and stemsplit sections, and the capability table around line 82)

- [ ] **Step 1: Document the dispatch behaviour**

Add to the README, in the section covering the whisper and stemsplit filters:

```markdown
### CPU instruction sets

Both `whisper` and `stemsplit` run on ggml, which is compiled for a fixed
instruction-set level. These builds carry several levels and pick one at
startup, so an old CPU keeps working while a modern one runs several times
faster. The selection is logged at `-v info` and published as frame metadata
(`lavfi.whisper.cpu_variant`, `lavfi.stemsplit.cpu_variant`).

`NOMERCY_GGML_CPU=<name>` forces a level — useful for support cases and for
A/B measurement. An unknown or unsupported name is ignored rather than fatal.

| platform | levels carried |
|---|---|
| linux / windows / freebsd x86_64 | `x64`, `sse42`, `ivybridge` (AVX+F16C), `haswell` (AVX2+FMA) |
| linux-aarch64 | `armv8.0`, `armv8.2+dotprod+fp16`, `+i8mm` |
| windows-aarch64 | `armv8.0`, `armv8.2+dotprod+fp16` |
| darwin-x86_64 | fixed at AVX+F16C (oldest Catalina Mac is Ivy Bridge) |
| darwin-arm64 | fixed at ARMv8.4+dotprod+fp16 |

Output is numerically equivalent across levels but not bit-identical: FMA
rounds differently. Measured on stemsplit, the difference is at most 1 LSB at
16-bit, 103 dB below the signal.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document ggml cpu instruction-set dispatch"
```

---

### Task 10: Full seven-platform run and release verification

**Files:** none changed; this task produces evidence.

- [ ] **Step 1: Record archive sizes before**

```bash
ls -la --block-size=M output/*.tar.gz output/*.zip | awk '{print $5, $9}'
```

- [ ] **Step 2: Start the full build**

Dev-branch builds need a manual dispatch:

```bash
gh workflow run main.yml --ref <branch> -f force_rebuild=true
```

Do not start this while anyone is running ffmpeg on Beast-Unit — a cold seven-platform build plus host-side runs exhausts host memory and the runner VM gets torn down.

- [ ] **Step 3: Watch it**

```bash
gh run list --limit 3
gh run watch <run-id>
```

Expected: 7/7 platforms, 7/7 smoke tests, including the new `cpu_variant` test.

- [ ] **Step 4: Record archive sizes after, compute the delta, and settle the variant count**

Expected: roughly +4 MB per x86 binary, +3 MB per aarch64 binary, darwin unchanged.

This answers the spec's open question 3. `sse42` buys only 1.3x over `x64`, so it
earns its ~1 MB only if the no-AVX machines in Step 5 are a population worth
serving at that speed. Decide with the measured delta and the Step 5 result in
hand, and record the decision in the PR either way. Dropping it is a one-line
change to `nm_variant_matrix`.

- [ ] **Step 5: The old-hardware guard**

This is the test that proves the floor did not rise, and it cannot be skipped:

- one x86 machine **without AVX** (Goldmont/Gemini Lake class) runs `ffmpeg -version`, a whisper transcription and a stemsplit run
- one **ARMv8.0** board (Raspberry Pi 4) does the same

Expected on both: it runs, and the logged variant is the baseline one.

- [ ] **Step 6: Speed evidence for the PR**

On the desktop and on Beast-Unit, record whisper and stemsplit timings before and after, plus the selected variant on each machine.

- [ ] **Step 7: Open the PR**

Target `dev`. Body carries: the measurement tables, the archive-size delta, the old-hardware guard result, the #64 hang-test result, and the three answered open questions from the spec.

---

## How this plan answers the spec's open questions

1. **Is `ggml_backend_score()` available in a static build?** The plan does not
   depend on it. `ggml_cpu_dispatch.c` does its own feature detection
   (`__builtin_cpu_supports` on x86, `getauxval` on linux-aarch64,
   `IsProcessorFeaturePresent` on windows-aarch64), which is the fallback the
   spec named and which is also the only way to honour the i8mm restriction on
   Windows. If ggml's score function turns out to be available, it changes
   nothing and is not worth adopting.
2. **Does llvm-mingw's toolchain accept the COFF recipe?** Task 7, Step 1.
3. **Three x86 variants or four?** Task 10, Step 4, decided with the size delta
   and the old-hardware result in hand.

## Notes for whoever executes this

- **The self-tests in Tasks 1 and 2 are the safety net for whisper upgrades.** The packing is generated from `nm` output at build time, so a version bump adapts automatically — but if ggml reorganises its symbols, the self-test fails loudly instead of silently producing a binary where both variants run the same slow code.
- **If a link fails with `multiple definition of ...`**, the packing prefix did not cover a symbol: check whether the object format branch is right for the target.
- **If a binary is zero bytes on Windows**, section symbols were renamed. That is the COFF failure mode and it produces no error message.
- **Never quote an ARM timing measured under qemu.** Only the fleet's real ARM hardware counts.
