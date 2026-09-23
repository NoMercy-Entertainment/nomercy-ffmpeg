# Design: automatic CPU hardware acceleration for ggml (whisper + stemsplit) on all seven platforms

**Date:** 2026-09-23
**Branch:** `fix/openblas-commit-and-thread-default` (carries the two related fixes); implementation gets its own branch
**Status:** Design, pending implementation plan
**Issues:** new (this document); related: #67, #69, #70

---

## 1. Summary

Every binary this repo ships runs ggml — the engine behind the `whisper` and
`stemsplit` filters — compiled for the **plain x86-64 / ARMv8.0 baseline**, with
no AVX, F16C, FMA, dotprod or fp16 code paths. On an 8-core desktop that costs a
measured **8-14x** on whisper and **2.4x** on stemsplit.

The cause is one line of ggml's CMake logic combined with the fact that every
platform here builds through a cross-compile toolchain. Nothing in this repo ever
asked for the slow build; it is the silent default.

This design enables the fast code paths **without raising the hardware floor on
any platform**. Each binary carries several instruction-set variants of ggml's CPU
backend and picks the best one for the machine it is started on, the same way
FFmpeg itself already does with `--enable-runtime-cpudetect`. The binaries stay
fully static and self-contained: no new files in the archive, no new runtime
dependency, no glibc floor.

The mechanism is build-system only. **No patch to ggml or whisper.cpp sources is
required** — this was the main open question and it has been settled by
experiment on both ELF and COFF.

---

## 2. Goals

- Whisper and stemsplit run at the speed the host CPU allows, automatically, on
  all seven targets: linux x86_64/aarch64, windows x86_64/aarch64, darwin
  x86_64/arm64, freebsd x86_64.
- **No machine that runs v1.0.42 today may fail to run the next release.** That
  includes Raspberry Pi 4 (ARMv8.0), Ivy Bridge Macs on Catalina, and
  Goldmont-class Atom/Celeron NAS boxes without AVX.
- No change to how the artifacts are shipped: one static binary per platform,
  same archive contents.
- The selected variant is observable (log line + frame metadata) and overridable.
- Every platform is verified before release; no platform ships unverified.

## 3. Non-goals

- **GPU backends (Vulkan, CUDA, Metal).** That is issue #69 and follows as a
  separate phase on top of this work. Note the finding in §9.4: a fully static
  binary cannot host ggml's dynamic backend modules, so #69 needs its own
  distribution decision, which this design deliberately does not pre-empt.
- Removing OpenBLAS from windows-x86_64. Section §10.2 explains why that becomes
  attractive only *after* this work, and why doing it today would be a 3.5x
  regression.
- Changing which whisper.cpp version is pinned.
- KleidiAI, AMX, or AVX-512-specific tuning beyond selecting an existing ggml
  variant.

---

## 4. Evidence

All numbers below were measured on 2026-09-22/23. Two machines:

- **Desktop:** i7-10700K, 8 physical cores / 16 threads, Windows 10, Comet Lake
  (AVX2/FMA/F16C, no AVX-512).
- **Beast-Unit:** 2 x Xeon E5-2680 v4, 28 physical cores / 56 threads, Windows
  Server, one processor group.

### 4.1 Root cause

`ggml/CMakeLists.txt` (whisper.cpp v1.9.1, ggml 0.15.1):

```cmake
if (CMAKE_CROSSCOMPILING ...)
    set(GGML_NATIVE_DEFAULT OFF)
...
if (GGML_NATIVE OR NOT GGML_NATIVE_DEFAULT)
    set(INS_ENB OFF)
else()
    set(INS_ENB ON)
...
option(GGML_SSE42 "..." ${INS_ENB})
option(GGML_AVX   "..." ${INS_ENB})
option(GGML_AVX2  "..." ${INS_ENB})
option(GGML_FMA   "..." ${INS_ENB})
option(GGML_F16C  "..." ${INS_ENB})
```

Every platform dockerfile passes `-DCMAKE_SYSTEM_NAME=...` in
`CMAKE_COMMON_ARG`, which makes CMake treat the build as a cross-compile —
including `linux-x86_64`, which is otherwise a native build. So
`GGML_NATIVE_DEFAULT` is OFF, `INS_ENB` is OFF, and every instruction-set option
defaults to OFF.

Confirmed directly by configuring whisper with this repo's exact
`CMAKE_COMMON_ARG` for linux-x86_64 and reading CMake's own debug output:

```
-- GGML_NATIVE         : OFF
-- GGML_NATIVE_DEFAULT : OFF
-- INS_ENB             : OFF
```

and by `whisper_print_system_info()` from a binary built with this repo's
windows-x86_64 arguments, which prints

```
system_info: ... CPU : REPACK = 1 |
```

where an upstream Windows build prints `SSE3 = 1 | SSSE3 = 1 | AVX = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | REPACK = 1`.

### 4.2 What it costs — whisper

`whisper-cli`, `ggml-base.en`, 60 s of vocal audio, `-t 8`, desktop. Transcript
md5 identical in every row.

| build | encode (2 runs) | total (2 runs) |
|---|---|---|
| as shipped (OpenBLAS, no SIMD) | 6516 / 6433 ms | 18.7 / 18.9 s |
| OpenBLAS removed, still no SIMD | 23374 / 22709 ms | 33.3 / 32.0 s |
| AVX + F16C, no BLAS | 2128 / 2278 ms | 4.1 / 4.7 s |
| **AVX2 + FMA, no BLAS** | **1807 / 1931 ms** | **3.7 / 4.1 s** |
| AVX2 + FMA + OpenBLAS | 1392 / 1539 ms | 5.9 / 6.7 s |

### 4.3 What it costs — per instruction level

Same binary, same model, only the loaded CPU backend module differs (ggml
`GGML_CPU_ALL_VARIANTS` build, desktop, 8 threads). This isolates the ISA effect
from everything else:

(No BLAS in any row, so this is ggml's own code only; the windows-x86_64 release
additionally links OpenBLAS, which is why §4.2's first row is faster than `x64`
here.)

| variant | encode | total | vs baseline |
|---|---|---|---|
| `x64` (the level ggml is compiled at today) | 21475 ms | 30.3 s | — |
| `sse42` | 15706 ms | 23.3 s | 1.3x |
| `sandybridge` (AVX) | 15559 ms | 22.9 s | 1.3x |
| **`ivybridge` (AVX + F16C)** | **1906 ms** | **3.8 s** | **8x** |
| `haswell` (AVX2 + FMA + BMI2) | 1556 ms | 3.4 s | 9x |

**The cliff is F16C, not AVX2.** The models are F16; without F16C every weight is
converted in scalar code. This is why a conservative fixed baseline (SSE4.2) is
not a useful answer: it buys 1.3x, while the machines that matter can have 9x.

### 4.4 What it costs — stemsplit

30 s accompaniment split of a real mp3.

| build | desktop | Beast-Unit |
|---|---|---|
| v1.0.42 as released | — | 5584 / 5650 ms |
| rebuilt at baseline (control) | 6559 / 6437 ms | 5764 / 5842 ms |
| AVX2 build | 3071 / 2706 ms | 2590 / 2352 ms |

The released binary and the rebuilt baseline being equal at the same thread count
is what proves the *shipped* artifact has no SIMD — not just my reproduction of
its build.

### 4.5 Linux is affected too

Built with this repo's exact linux-x86_64 CMake arguments versus the same tree
with the instruction options forced on, stemsplit 30 s, same container:

| binary | time | md5 |
|---|---|---|
| shipped `ffmpeg-9.0-linux-x86_64` | 5903 ms | `b8a285de64f2` |
| rebuilt with repo arguments | 5859 ms | `6f12ef45c907` |
| rebuilt with SIMD enabled | **1919 ms** | `273099b66606` |

(The md5 differs between the shipped binary and the rebuild because the rebuild
is a minimal configure, not because of ggml. The *timing* is the comparison that
matters, and it is identical.)

### 4.6 Numeric effect

Enabling FMA changes rounding. Measured on stemsplit output, 30 s, 44.1 kHz
stereo, baseline vs AVX2 build:

- 123 of 2 646 000 samples differ
- maximum difference: **1 LSB at 16-bit**
- difference RMS is **-103.6 dB** relative to the signal

Well inside the `rtol=1e-3` tolerance at which the stemsplit network is verified
against the Python reference. Inaudible. But see §8.2: it ends bit-identical
output across machines.

---

## 5. Constraints

### 5.1 The hardware floor may not rise

Researched per target (sources recorded in the research notes accompanying this
design). The decisive rows:

| target | oldest machine that must keep working | what it lacks |
|---|---|---|
| linux-aarch64 | Raspberry Pi 4 / Jetson Nano (Cortex-A72/A57) | ARMv8.0: no dotprod, no fp16 arithmetic |
| darwin-x86_64 | 2012 MacBook/iMac, 2013 Mac Pro (Ivy Bridge) — the machines actually still on Catalina | no AVX2, no FMA, no BMI2 |
| linux/windows/freebsd-x86_64 | Goldmont/Gemini Lake NAS boxes (J4125, N5105 class) | no AVX, no F16C |
| windows-aarch64 | Windows 11 ARM devices (Cortex-A76 and newer) | i8mm not reliably detectable on Windows |
| darwin-arm64 | M1 | i8mm (M2+), SME (M4+) |

Two consequences. First, **a fixed compile-time level is unacceptable on every
target except darwin**, where Apple controls the population. Second, on Windows
ARM, i8mm must not be used even when present: Windows has no processor-feature
flag for it, and inferring it from the SVE flag is wrong on Oryon.

### 5.2 The binaries must stay static

Proven by experiment, in the order the alternatives were eliminated:

- A fully static glibc binary **can** `dlopen` a module.
- A fully static binary **cannot export its own symbols** to that module — with
  `-static`, with `-static -rdynamic`, both fail with `undefined symbol`; only a
  dynamic executable works. This kills the "static ffmpeg + modules that call
  back into it" shape that #69 proposes as its option (a).
- Therefore ggml's own module mechanism (`GGML_BACKEND_DL`) requires a shared
  `libggml-base`, which requires a dynamically linked ffmpeg.
- A dynamically linked build made on the current base image (Ubuntu 24.04,
  glibc 2.39) **fails to start on Debian 11 and Ubuntu 22.04**:
  `/lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.38' not found`, while the
  shipped static binary runs on both.

Going dynamic would therefore break existing users on older distributions —
exactly what the project's first rule forbids.

### 5.3 Size and startup budget

Archives are currently 145-244 MB. A ggml CPU variant is 0.85-1.36 MB (measured
across the 14 modules of an x86 `GGML_CPU_ALL_VARIANTS` build: 14.3 MB total).
Four variants therefore add roughly 4 MB per binary, under 3% of the smallest
archive. Selection happens once per filter instance, not per frame.

---

## 6. Approaches considered

| approach | outcome | why not chosen |
|---|---|---|
| **A. Fixed compile-time level per platform** | 1.3x at a safe level, or 9x while breaking Pi 4 / Ivy Bridge Macs / Atom NAS boxes | Fails §5.1 at any useful level |
| **B. ggml's own `GGML_BACKEND_DL` modules** | Works; auto-selected `libggml-cpu-haswell.so` correctly on the test machine | Fails §5.2 on linux/freebsd: forces a dynamic ffmpeg and a glibc floor |
| **C. Several static variants in one binary, chosen at runtime** | **Chosen.** Proven on ELF and COFF | — |

Approach C was validated end to end before this design was written (§7.2).

---

## 7. Architecture

### 7.1 Variant builds

`scripts/48-whisper.sh` builds ggml's CPU backend **once per variant** instead of
once, each into its own prefix, differing only in instruction-set options. The
rest of the whisper build (ggml-base, libwhisper) is built once and shared.

### 7.2 Making the variants coexist — the packing step

Each variant's `libggml-cpu.a` is partially linked into a single object whose
symbols are then made unique. The recipe differs per object format; both were
proven by building a test program that runs an F16 x F32 matmul through **both**
variants in one binary and compares results.

**ELF (linux x2, freebsd):**

```sh
ld -r --whole-archive libggml-cpu.a -o variant.o
nm -u variant.o | awk '{print $NF}' | sort -u > undefined.txt   # external refs
objcopy --prefix-symbols=v2_ variant.o variant_pre.o            # rename everything
awk '{print "v2_" $1 " " $1}' undefined.txt > restore.txt       # ...then restore
objcopy --redefine-syms=restore.txt variant_pre.o variant_fin.o #    the refs
```

Prefixing *everything* is what keeps COMDAT groups internally consistent;
restoring the undefined references is what keeps libc, libstdc++ and ggml-base
resolvable. Result on x86_64: `lo` 39.29 ms/matmul, `hi` 4.47 ms/matmul,
**8.80x**, `max |lo-hi| = 0`.

**COFF (windows x2):**

```sh
x86_64-w64-mingw32-ld -r --whole-archive libggml-cpu.a -o variant.o
x86_64-w64-mingw32-nm --defined-only variant.o \
  | awk '$2 ~ /^[TDBRWV]$/ { print $3 " v2_" $3 }' > redefine.txt
x86_64-w64-mingw32-objcopy --redefine-syms=redefine.txt variant.o variant_fin.o
```

On COFF only *defined* symbols are renamed and section symbols are left alone —
blanket-prefixing corrupts COMDAT section names and the link silently produces an
empty binary. Result, run on real Windows: `lo` 65.90 ms/matmul, `hi` 4.44
ms/matmul, **14.86x**, relative difference 8.9e-07.

**Amended 2026-09-23, during Task 1 — that COFF recipe is necessary but not
sufficient.** It holds when one variant is left untouched, which is how it was
first measured, but not when *both* are packed, which is what the real build does.
PE/COFF puts every vague-linkage definition — C++ vtables, libstdc++ template
instantiations, and the `.refptr.<sym>` indirection cells gcc emits for cross-TU
globals — in a COMDAT section named `<kind>$<symbol>`, and the linker folds COMDAT
groups by matching **section names, not symbol names**. Two packed variants still
carry identically named sections, so the linker keeps one and the other variant's
correctly renamed symbols vanish: ~30 `undefined reference to 'hi_...'` errors at
the application link. The fix is narrow — for each symbol already being renamed,
also rename its matching `<kind>$<symbol>` section with `objcopy
--rename-section`, across the kinds mingw emits (`text`, `data`, `rdata`, `bss`,
`pdata`, `xdata`). `objcopy` no-ops a rename whose old section does not exist, so
the base `.text`/`.data`/`.rdata` segments are never touched. Verified on real
Windows with both variants packed: `lo` 65.63 ms/matmul, `hi` 4.58 ms/matmul,
**14.32x**.

**aarch64 ELF:** same recipe as ELF, verified under qemu — both variants coexist
and compute correctly (relative difference 0.004, consistent with fp16
arithmetic). Speed on ARM is **not** measured yet; emulation makes local timing
meaningless. See §11.1.

**Mach-O (darwin x2):** not needed. Darwin uses fixed levels (§7.5) because its
floor is known. `llvm-objcopy` does carry the required flags, so darwin can adopt
dispatch later without redesign.

### 7.3 Selection

A new source file, `scripts/includes/ggml_cpu_dispatch.c`, compiled into
libavfilter alongside the existing patched filter sources:

- Declares each packed variant's prefixed entry point.
- Queries each variant's own suitability. ggml compiles a `ggml_backend_score()`
  per variant when built with its DL semantics; the implementation plan must
  confirm this symbol is available in the static build and, if it is not, fall
  back to explicit feature detection (`__builtin_cpu_supports` on x86;
  `getauxval(AT_HWCAP)` on linux-aarch64; `IsProcessorFeaturePresent` on
  windows-aarch64; `sysctlbyname` on darwin).
- Picks the highest-scoring variant that the running CPU supports and registers
  exactly that one, so whisper and stemsplit see a single CPU backend and need no
  selection logic of their own.
- Falls back to the baseline variant, which is always present and always runs.

`af_stemsplit.c` currently calls `ggml_backend_cpu_init()` directly; it changes to
initialise from the selected device. `af_whisper.c` needs no change beyond the
dispatcher being registered before whisper initialises.

### 7.4 Interaction with the thread-count fix

The physical-core default committed on `fix/openblas-commit-and-thread-default`
stays as is. The two are independent: one decides *how many* threads, the other
decides *which code* those threads run.

### 7.5 Per-platform variant matrix

| platform | variants built | selection | floor unchanged at |
|---|---|---|---|
| linux-x86_64 | `x64`, `sse42`, `ivybridge`, `haswell` | runtime | any x86-64 |
| windows-x86_64 | `x64`, `sse42`, `ivybridge`, `haswell` | runtime | any x86-64 |
| freebsd-x86_64 | `x64`, `sse42`, `ivybridge`, `haswell` | runtime | any x86-64 |
| darwin-x86_64 | `ivybridge` only | fixed | Ivy Bridge (Catalina floor) |
| linux-aarch64 | ARMv8.0, ARMv8.2+dotprod+fp16, ARMv8.2+dotprod+fp16+i8mm | runtime | ARMv8.0 (Pi 4) |
| windows-aarch64 | ARMv8.0, ARMv8.2+dotprod+fp16 | runtime | ARMv8.0 |
| darwin-arm64 | ARMv8.4+dotprod+fp16 only | fixed | all Apple Silicon |

Rationale for the two fixed rows: on darwin the oldest supported machine is known
exactly, so a fixed level is provably safe and costs no mechanism. darwin-x86_64
at `ivybridge` captures 8 of the available 9x; darwin-arm64 at ARMv8.4 captures
everything except i8mm on M2+.

`skylakex` / `zen4` / `alderlake` are deliberately omitted from the initial set:
the measured step from `ivybridge` to `haswell` is already only 1.2x, and each
further variant costs ~1 MB for less. They can be added later without design
change.

---

## 8. Observability, overrides and consequences

### 8.1 Observable

- `AV_LOG_INFO` line at filter init naming the selected variant, e.g.
  `stemsplit: ggml cpu variant 'haswell' (AVX2 FMA F16C)`.
- Frame metadata `lavfi.whisper.cpu_variant` and `lavfi.stemsplit.cpu_variant`,
  so the media server can report what actually ran without scraping logs. This
  matches what #69 asks for with `lavfi.whisper.backend` and should use the same
  naming when #69 lands.
- Environment override `NOMERCY_GGML_CPU=<variant|baseline>` forces a variant, for
  support cases and for A/B measurement on one machine.

### 8.2 Consequence: output is no longer bit-identical across machines

With dispatch, two machines with different CPUs produce numerically equivalent but
not byte-identical stem and transcript output (§4.6). Anything that assumes
reproducible hashes — media-server caching, deduplication, or a CI test comparing
md5 — must be checked. The current `tests/tests.sh` only asserts that the filters
are listed, so CI is not affected today, but the verification added by this work
must compare with a tolerance, never with md5.

---

## 9. Verification plan

### 9.1 Per-platform, in CI

For each of the seven binaries:

1. `ffmpeg -version` starts (catches an illegal-instruction variant chosen at
   startup).
2. The dispatcher logs a variant, and `NOMERCY_GGML_CPU=baseline` selects the
   baseline one.
3. A short whisper transcription and a short stemsplit run complete, and their
   output matches a reference within tolerance (transcript text equal; audio
   within -80 dB RMS difference — far looser than the -103.6 dB measured, tight
   enough to catch a wrong variant).

### 9.2 On real hardware, before release

- **Old-hardware guard.** At least one x86 machine without AVX (Goldmont-class)
  and one ARMv8.0 board (Pi 4) must run the new binary successfully. This is the
  test that proves the floor did not rise; it cannot be skipped or emulated away.
- **Speed confirmation** on the fleet's linux-aarch64 verifier, since ARM speed is
  unmeasured so far (§11.1).
- The existing `verify-rc` matrix covers six platforms; windows-aarch64 stays a
  manual tick as it is today.

### 9.3 Regression guards

- The windows-x64 stemsplit exit-hang reproduction from #64 (20 runs, all must
  exit) — the packing step touches how ggml is linked.
- Archive size recorded before and after.

### 9.4 Note for #69

The finding in §5.2 — that a static executable cannot export symbols to a
dlopened module — constrains #69 directly. Its proposed option (a) is not
available on linux/freebsd. GPU support there will need either a separate
dynamically linked artifact or a per-backend `dlopen` shim that does not depend on
ggml-base symbols crossing the boundary.

---

## 10. Follow-ups this unlocks

### 10.1 Thread defaults revisited

With SIMD enabled the compute/memory balance shifts; the physical-core default
should be re-measured once, on both machines, after this lands.

### 10.2 OpenBLAS on windows-x86_64

Once ggml has SIMD, OpenBLAS becomes a liability rather than a help: measured
AVX2+BLAS total 5.9/6.7 s versus AVX2 alone 3.7/4.1 s. Removing it would drop the
remaining 487 MB of startup commit (#70) and ~60 MB of binary. **Only after this
work** — removing it today is a 3.5x regression, because BLAS is currently the
only vectorised matmul in the build.

---

## 11. Risks

| risk | mitigation |
|---|---|
| A variant is selected that the CPU cannot run → SIGILL at startup | Baseline variant always present; selection gated on feature detection; §9.2 old-hardware guard is mandatory before release |
| ggml's per-variant score symbol is unavailable in a static build | Implementation step 1 confirms it; explicit per-OS feature detection is the documented fallback (§7.3) |
| A whisper.cpp upgrade changes symbol layout | The packing is generated from `nm` output at build time, not from a checked-in list, so it adapts automatically; the build fails loudly on a link error rather than silently mis-selecting |
| Two variants' weak/COMDAT code merged silently, so the fast variant runs slow code | The packing recipes were chosen specifically to avoid this; verification asserts a per-variant speed difference, not just correctness |
| A cmake invocation sets `CMAKE_SYSTEM_NAME` without `CMAKE_SYSTEM_PROCESSOR`, so `ggml_get_system_arch()` returns `UNKNOWN` and **every** variant silently builds the generic backend regardless of its instruction flags | Found during Task 1, in the plan's own harness. All seven platform dockerfiles are safe (five set `CMAKE_SYSTEM_PROCESSOR`, the two darwin ones set `CMAKE_OSX_ARCHITECTURES`, which ggml checks first), but any new cmake invocation must set one of the two. The speed assertion in the self-test is what catches it — a link check never would |
| Archive/binary growth | ~4 MB per binary measured against 145-244 MB archives; recorded per §9.3 |

### 11.1 Known unmeasured

ARM speed. The mechanism is verified on aarch64, but every ARM timing in this
document is either absent or from qemu emulation and must not be quoted. The
implementation plan must measure dotprod/fp16 gain on real ARM hardware before
the variant matrix for ARM is considered final.

---

## 12. Open questions for implementation

1. Is `ggml_backend_score()` emitted for a statically built variant, or must the
   dispatcher do its own feature detection? (§7.3)
2. Does `windows-aarch64`'s llvm-mingw toolchain (llvm-nm/llvm-objcopy) accept the
   COFF recipe, or does it need the ELF one? Not yet tested.
3. Should the four x86 variants be trimmed to three (`x64`, `ivybridge`,
   `haswell`) given `sse42` buys 1.3x over `x64`? Decide with the size measurement
   in hand.
