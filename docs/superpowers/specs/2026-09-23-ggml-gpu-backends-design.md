# Design: GPU acceleration for the whisper and stemsplit filters

**Date:** 2026-09-23
**Depends on:** `feat/ggml-cpu-variants` (the CPU instruction-set dispatcher; this design extends its backend selection)
**Status:** Design, pending implementation plan
**Issues:** #69; related: #42 (static CUDA under WSL2), #67

---

## 1. Summary

`whisper` and `stemsplit` run on the CPU only. Issue #69 wants GPU support because a
lyrics plugin will transcribe every track in a library, which is weeks of CPU time.

Issue #69 assumed GPU support requires shipping ggml's dynamic backend modules next
to `ffmpeg`, and that assumption was the reason it stalled: we have since proven a
fully static executable **cannot** export its symbols to a `dlopen`ed module, so that
route is closed on linux and freebsd.

The assumption turns out to be unnecessary. ggml's Vulkan backend routes every call
through a dynamic dispatcher and needs exactly **three** symbols from the Vulkan
loader. Supplying those three from a small shim of our own — which opens the system
loader at first use, the same way FFmpeg's own Vulkan code already does inside these
static binaries — lets ggml-vulkan be linked **statically** with no change whatsoever
to how anything is shipped.

Proven end to end before this document was written: a static `ffmpeg.exe` with no
import of `vulkan-1.dll` found an NVIDIA RTX 3070, ran a matmul on it, and produced
the same result as the CPU backend.

The work is phased:

- **Phase 1 — Vulkan**, on the six platforms that can have it. One backend covers
  NVIDIA, AMD and Intel.
- **Phase 2 — CUDA**, the faster NVIDIA-only path, as its own spec.
- **Phase 3 — Metal**, so macOS gets hardware acceleration too.

---

## 2. Goals

- `whisper` and `stemsplit` use a GPU when one is usable, automatically.
- **A machine without a GPU, without a driver, or with a broken driver must be
  completely unaffected** — same behaviour as today, no crash, no slowdown, no
  failure to start.
- No change to how artifacts are shipped: one static binary per platform, no new
  files in any archive, no new runtime dependency.
- The backend actually used is observable in the log and in frame metadata.
- macOS is not left behind: phase 3 gives it Metal.

## 3. Non-goals

- Changing the distribution model. If a GPU backend cannot be made to work inside a
  static binary, it does not ship — that trade was already decided.
- Training, quantisation, or any ggml feature beyond running the two existing graphs.
- GPU support for any other filter in this repo.
- Making GPU output bit-identical to CPU output. It will not be, and §7.3 says what
  is guaranteed instead.

---

## 4. Evidence

A throwaway spike ran on 2026-09-23. Everything below is measured, not predicted.

### 4.1 The loader symbols

`libggml-vulkan.a`, built for both linux and mingw, has exactly three undefined
Vulkan symbols, confirmed with `nm --undefined-only` rather than by reading source:

```
vkGetInstanceProcAddr
vkCmdCopyBuffer
vkGetPhysicalDeviceFeatures2
```

Everything else goes through `VULKAN_HPP_DISPATCH_LOADER_DYNAMIC`.

### 4.2 The shim works, and the binary stays static

Linking ggml-vulkan against a ~120-line shim instead of the real loader produces a
binary that `file` reports as "statically linked", `ldd` reports as "not a dynamic
executable", and whose Windows build imports only `ADVAPI32`, `KERNEL32` and
`msvcrt.dll` — **no `vulkan-1.dll` import**.

### 4.3 It really uses the GPU

Cross-built with the project's own mingw-w64 toolchain and run natively on the
Windows host: `vulkaninfo` reported an NVIDIA GeForce RTX 3070 (driver 616.92), and
the static binary found that device through the shim, ran a matmul on it, and matched
the CPU backend's result exactly.

### 4.4 Two failure modes that must shape the design

Both were reproduced, not theorised:

1. **A shim that returns NULL crashes.** `vulkan.hpp`'s dispatcher calls the pointer
   it is given; a NULL is a null-pointer call inside the dispatcher, not a catchable
   error. The shim must return valid stub functions that report
   `VK_ERROR_INCOMPATIBLE_DRIVER`, so absence surfaces as an ordinary `vk::SystemError`.
2. **ggml's legacy Vulkan API crashes on a perfectly ordinary condition.**
   `ggml_backend_vk_init()` and `ggml_backend_vk_get_device_count()` do not catch
   Vulkan's exceptions: with a loader present but no usable driver they terminate the
   process (exit 134). Only the registry path — `ggml_backend_vk_reg()` reached via
   `ggml_backend_dev_by_type()` — wraps initialisation in try/catch and returns
   cleanly (exit 0). The same shim, the same machine, opposite outcomes.

### 4.5 Software Vulkan crashes, and that is a real user scenario

Mesa's llvmpipe (software Vulkan) segfaults inside a static binary regardless of shim
or API choice — a glibc static-linking limitation around its nested `dlopen` of LLVM
with heavy thread-local storage. It did not reproduce on Windows and does not affect
real GPU drivers.

This matters because a headless Linux server with Mesa installed advertises exactly
such a device. **The design must keep the loader away from software ICDs rather than
discover this at a user's site.**

**Amended 2026-09-23, during implementation Task 1.** The crash is worse than first
measured: it is not that ggml picks a bad device, it is that the process dies at exit
139 *inside the Vulkan loader's own ICD probing*, before any of our code runs. So
filtering devices after enumeration — what §6.3 originally said — is too late, because
the enumerating call is the one that crashes. The guard has to run before Vulkan is
touched at all: read the ICD manifests ourselves, keep only hardware ones, and point
the loader at those (or at a nonexistent path when there are none, which Task 1 proved
is handled gracefully). Only then may ggml's registry be reached.

### 4.6 Cost

| | measured |
|---|---|
| binary growth | 2.67 MB → 65.75 MB stripped, i.e. **~63 MB** |
| build time | +3-5 minutes per platform |

The whole shader archive is linked because `ggml-vulkan.cpp.o` references every
shader-variant object directly; there is no cheap subset.

---

## 5. Constraints

1. **Nothing may regress for a user without a GPU.** This outranks every performance
   goal in this document.
2. Binaries stay fully static and self-contained.
3. No patch to ggml or whisper.cpp sources — build system, our own shim, and the two
   filter sources we already maintain.
4. Selection must compose with the CPU instruction-set dispatcher from
   `feat/ggml-cpu-variants`: when no GPU is used, the best CPU variant must still be
   chosen exactly as it is today.

---

## 6. Phase 1 — Vulkan

### 6.1 The loader shim

A new `scripts/includes/vk_loader_shim.c` defines the three symbols from §4.1. On
first call it opens `libvulkan.so.1` (`vulkan-1.dll` on Windows) with
`dlopen`/`LoadLibraryA` and resolves the real entry points; if the library is missing,
or the symbol is absent, it returns a stub that reports
`VK_ERROR_INCOMPATIBLE_DRIVER` — never NULL (§4.4).

Opening a shared library from a static executable is the direction that works. The
direction that does not — a loaded module calling back into the executable — is not
used anywhere here.

### 6.2 Build integration

`scripts/48-whisper.sh` gains a Vulkan step for the six platforms in §6.5:
build ggml with `-DGGML_VULKAN=ON`, compile the shim, and link both into the same
archive the CPU variants already go into. `find_package(Vulkan)` must be satisfied at
configure time without a real loader being present; the spike recorded how.

The Vulkan build needs `glslc` for shader compilation at build time. The base image
already carries shaderc (`scripts/45-vulkan.sh`, `ffmpeg-base.dockerfile`), and the
implementation must confirm `glslc` is on PATH rather than assume it.

### 6.3 Backend selection

One decision point, in `scripts/includes/ggml_cpu_dispatch.c` (which becomes the
single place that answers "what should this filter run on"):

1. If the filter's `use_gpu` option is 0 → CPU.
2. Otherwise call `ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU)`.
   **Only the registry path** (§4.4).
3. **Before any of the above touches Vulkan**, neutralise software ICDs (§4.5): read
   the Vulkan ICD manifests (`/usr/share/vulkan/icd.d/*.json` and whatever
   `VK_ICD_FILENAMES` / `VK_DRIVER_FILES` name), classify each by its `library_path`,
   and set `VK_ICD_FILENAMES` to the hardware ones only — or to a nonexistent path
   when none are hardware. Filtering after enumeration is too late: the enumerating
   call is the one that crashes.
   Then, among the devices that remain, still skip anything reporting itself as a
   software rasteriser — belt and braces, and it costs nothing.
4. If a usable GPU device remains → use it. Otherwise → the best CPU variant, exactly
   as today.
5. Any failure at any step → CPU. Never an error, never a refusal to start.

### 6.4 What the user sees

- Log at `AV_LOG_INFO`: the backend and device, e.g.
  `whisper: ggml backend 'vulkan' (NVIDIA GeForce RTX 3070)`, or the existing CPU
  variant line when running on CPU.
- Frame metadata `lavfi.whisper.backend` and `lavfi.stemsplit.backend`, alongside the
  `cpu_variant` keys that already exist. Issue #69 asks for exactly this so the media
  server can report what ran without scraping logs.
- `use_gpu=0` forces CPU. `NOMERCY_GGML_CPU` continues to select among CPU variants
  and is unaffected.

### 6.5 Per-platform matrix

| platform | Vulkan | why |
|---|---|---|
| linux-x86_64 | yes | primary target |
| windows-x86_64 | yes | primary target |
| linux-aarch64 | yes | owner chose full coverage; ARM GPU drivers unverified |
| windows-aarch64 | yes | same |
| freebsd-x86_64 | yes, **gated on the §7.1 cases passing there** | different toolchain, static + dlopen unproven |
| darwin-x86_64 | no | `45-vulkan.sh` already skips Vulkan on darwin; Metal is phase 3 |
| darwin-arm64 | no | same |

---

## 7. Verification

### 7.1 Per platform, before release

1. **No GPU at all** (a plain container): starts, reports CPU, output unchanged.
2. **Loader present, no usable driver** (`VK_ICD_FILENAMES` pointing at a nonexistent
   file): starts, reports CPU, does not crash. This is §4.4's crash case.
3. **Software rasteriser present**: skipped, CPU used, no crash. This is §4.5's case
   and must be tested on Linux specifically, where it reproduces.
4. **A real GPU**: the log and metadata name the device, and a transcription or stem
   split completes.

### 7.2 Hardware available for the real-GPU case

NVIDIA RTX 3070 (this desktop, Vulkan loader present), the RTX 2080 SUPER from #42,
an Intel or AMD GPU for the vendor-independence claim, and an Apple Silicon Mac for
phase 3. Beast-Unit covers the no-GPU case.

### 7.3 Correctness

GPU and CPU results are numerically equivalent, not bit-identical — different
hardware, different rounding, exactly as the CPU design
(`2026-09-23-ggml-cpu-hardware-acceleration-design.md`, §4.6) already established for FMA. Comparison uses a tolerance: for whisper, the same words with timestamps
within 20 ms (issue #69's own acceptance criterion); for stemsplit, an RMS difference
at least 60 dB below the signal.

### 7.4 Regressions that must be re-checked

- The windows-x86_64 exit hang from #64: 20 runs, all must exit.
- The CPU variant dispatcher still selects correctly when no GPU is present.
- Archive sizes recorded before and after.

---

## 8. Phase 2 — CUDA (sketch, own spec later)

CUDA is the faster NVIDIA path. It differs from Vulkan in three ways that need their
own decisions: `cudart_static` plus `cublas_static` add hundreds of MB; the driver
library is loaded at runtime, which #42 shows failing under WSL2 specifically because
the shim's second-stage load cannot complete in a static binary; and it is NVIDIA
only, so it buys nothing for the AMD and Intel users Vulkan already serves.

Phase 2 starts only after phase 1 ships and is measured. If Vulkan turns out to be
within a reasonable margin of CUDA on the RTX 3070, phase 2 may be worth dropping
entirely — that measurement is the first thing its spec should contain.

---

## 9. Phase 3 — Metal, so macOS is not left behind

### 9.1 The blocker everyone expects is not there

Metal shaders normally need Apple's `metal` compiler, which osxcross does not ship.
But ggml supports `GGML_METAL_EMBED_LIBRARY`, which embeds the **shader source** into
the binary as a data section and compiles it on the user's machine at first use via
`newLibraryWithSource:`. The embedding step uses only `sed`, `echo` and the
assembler — checked in `ggml/src/ggml-metal/CMakeLists.txt` of the pinned whisper.
No Apple shader compiler is needed at build time.

What is needed: an Objective-C capable compiler (osxcross clang handles `.m`), and the
`Foundation`, `Metal` and `MetalKit` frameworks from the macOS SDK the darwin
dockerfiles already use. The darwin `LDFLAGS` currently name CoreFoundation,
CoreVideo, IOSurface, VideoToolbox, OpenCL, Accelerate, DiskArbitration and IOKit —
Metal and MetalKit must be added.

### 9.2 Scope recommendation: darwin-arm64 first

Every Apple Silicon Mac has a Metal 3 capable GPU and runs macOS 11 or newer, so
enabling Metal there raises no floor. darwin-x86_64 is riskier: its deployment target
is 10.15, and if ggml-metal needs newer APIs, enabling it would raise that floor and
break exactly the old Intel Macs the CPU design went out of its way to protect. Phase
3 therefore starts with darwin-arm64, and darwin-x86_64 only follows if it can be
done without moving the deployment target.

### 9.3 Cost to check first

Runtime shader compilation happens on first use and takes a few seconds, which ggml
logs. For a media server transcribing a library that is negligible; for a one-shot
invocation it is not nothing, and the phase-3 spec should measure it. There is no
`.metallib` to ship, so the binary grows only by the embedded shader source.

### 9.4 Verification

The owner has an Apple Silicon Mac, so phase 3 is verifiable on real hardware — the
same four cases as §7.1, with "no GPU" replaced by "Metal unavailable", plus the
first-use compilation time.

---

## 10. Risks

| risk | mitigation |
|---|---|
| A GPU path crashes a user's transcode | Every failure falls back to CPU; the two known crash modes (§4.4, §4.5) are designed out and are explicit test cases |
| Software rasteriser selected on a headless server | Software devices are filtered out (§6.3); tested on Linux |
| freebsd cannot do static + dlopen safely | Gated: if §7.1's cases do not pass there, freebsd ships without Vulkan and that is reported rather than forced |
| ARM GPU drivers behave differently | Same test matrix; ARM is not a primary target and may be dropped if it cannot be verified |
| +63 MB per binary on five platforms | Owner's explicit decision; sizes recorded in the PR |
| GPU memory doubled by the filter being instantiated twice | Known pre-existing defect (both filters init twice per invocation). On CPU it wastes RAM; on a GPU it wastes far scarcer VRAM. **Should be fixed before or with phase 1** |

---

## 11. Open questions for implementation

1. How exactly does ggml report a software device — `GGML_BACKEND_DEVICE_TYPE`, the
   device name, or neither reliably? §6.3's filter depends on the answer; if ggml does
   not distinguish, the filter must match on driver/device name and that list needs
   care.
2. Does `find_package(Vulkan)` need a stub loader present at configure time, or do
   headers suffice? The spike recorded a working recipe; confirm it survives the real
   build scripts.
3. Is `glslc` actually on PATH in every platform image, or only where
   `45-vulkan.sh` ran?
4. Does whisper's own GPU path (`whisper_init_from_file_with_params` honouring
   `use_gpu`) interact with our selection, or does it need the same registry treatment
   the filters get?
