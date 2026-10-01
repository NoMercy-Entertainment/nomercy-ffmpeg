# CUDA vs Vulkan for the whisper and stemsplit ggml backends

**Date:** 2026-09-26
**Issue:** #69 (phase 2, CUDA); related #42 (static CUDA under WSL2)
**Spec this answers:** `docs/superpowers/specs/2026-09-23-ggml-gpu-backends-design.md` §8 —
"If Vulkan turns out to be within a reasonable margin of CUDA on the RTX 3070, phase 2
may be worth dropping entirely — that measurement is the first thing its spec should
contain."

**Recommendation up front: do not build the CUDA backend.** It is not faster here — it
is 8-12x *slower* on the stemsplit graph and 2-3x slower on the whisper encoder — it
costs +820 MB, it cannot be linked into a static executable at all, and it buys nothing
for AMD, Intel or Apple users. Reasoning and evidence below; §7 states what would have
to change for this answer to flip.

---

## 1. What was measured, and where

Everything in §2-§6 is measured on this desktop unless a line says "reasoned".

| | |
|---|---|
| CPU | Intel i7-10700K, 8 cores / 16 threads |
| GPU | NVIDIA GeForce RTX 3070, 8 GB, driver 617.14 (CUDA UMD 13.4) |
| Host OS | Windows 10 Pro 19045; `vulkan-1.dll` present, no Vulkan SDK |
| Second environment | WSL2 Ubuntu-24.04 (NVIDIA WSL driver) and Docker Desktop containers on the same WSL2 kernel |

**Source pin, confirmed not assumed.** `scripts/48-whisper.sh` pins
`whisper_version=1.9.1`. Every binary below is built from
`https://github.com/ggml-org/whisper.cpp` tag `v1.9.1`, commit
`f049fff95a089aa9969deb009cdd4892b3e74916`, whose CMake reports `ggml version: 0.15.1`
— the pin the brief named. The one exception is the *upstream prebuilt* Windows CUDA
binary, which is the official `whisper-cublas-12.4.0-bin-x64.zip` asset of that same
`v1.9.1` release, i.e. the same sources.

**Harness.** `whisper-cli` from that tree, `ggml-base.en.bin` (147.4 MB, the same model
the repo already keeps in `output/ffmpeg-9.0-windows-x86_64/`), `samples/jfk.wav` from
the pinned tag, `-t 8 -nt`, mean of 10 runs after a warm-up run, reading whisper's own
`total time` and `encode time`. A full ffmpeg was deliberately not built.

**Why the comparison is not done inside one ffmpeg.** The Vulkan reference figures in the
brief (stemsplit 830 ms, whisper 1464 ms) come from the project's `ffmpeg` with the real
filters. Reproducing that with CUDA would mean a full CUDA ffmpeg build, and the answer
did not need one. Instead both backends were measured against each other in *one*
harness on *one* machine, and the ratio is the result. The absolute numbers below are
therefore **not** directly comparable to 830/1464 ms — they measure less work (no mp3
decode, no STFT, no overlap-add, no model load in the per-run figure) — but they are
comparable *to each other*, which is what the decision needs.

---

## 2. whisper: measured

`whisper-cli`, `ggml-base.en`, `jfk.wav`, 8 threads, mean of 10 warm runs.
All three backends produced the **identical transcript**.

| build | environment | whisper `total time` | `encode time` |
|---|---|---|---|
| **Vulkan** (mingw cross-build, static, my build) | Windows host | **431 ms** | **32 ms** |
| **CUDA** (upstream v1.9.1 cuBLAS prebuilt, 8 archs) | Windows host | **599 ms** | **74 ms** |
| CPU (upstream v1.9.1 prebuilt, per-arch DLLs) | Windows host | 1111 ms | 549 ms |
| CUDA sm_86, dynamic CUDA libs (my build) | WSL2 Ubuntu | 466 ms | 95 ms |
| CUDA sm_86, static CUDA libs (my build) | WSL2 Ubuntu | 418 ms | 79 ms |
| CPU, generic x86-64 (my mingw build, `GGML_NATIVE=OFF`) | Windows host | 7605 ms | 6015 ms |

Reading it:

- **Vulkan's encoder is 2.3-3x faster than CUDA's** on this GPU (32 ms vs 74-95 ms),
  measured three ways: against upstream's own MSVC CUDA build on Windows, and against
  two CUDA builds of my own under WSL2. The prebuilt is not handicapped.
- End to end the gap narrows (431 vs 599 ms) because most of the remaining time is
  CPU-side sampling and decoding, which no GPU backend touches.
- The last row is my own CPU build and is **not** a CPU baseline for the product — it has
  no AVX2/FMA because I built with `GGML_NATIVE=OFF` and no CPU-variant dispatcher. It is
  in the table only so nobody mistakes it for one. Upstream's per-arch CPU build (1111 ms)
  is the honest CPU reference.
- Against the brief's Vulkan reference of 1464 ms: different harness, not comparable.
  What *is* comparable is that Vulkan beat CUDA in the same harness.

**One-off cost worth knowing.** The very first execution of a freshly built Vulkan binary
on this machine took **14.1 s** (encode 2794 ms) while ggml-vulkan compiled its pipelines;
every later process took 431 ms, so the driver's pipeline cache persists across processes.
CUDA's first run cost 1036 ms with no comparable spike. This is a Vulkan cost, not a CUDA
argument — it is paid once per machine, not once per invocation — but a phase-3/Metal-style
"first use compiles shaders" note belongs in the Vulkan docs too.

---

## 3. stemsplit: measured on a shape-faithful proxy, not on the filter

The stemsplit half could not be run as the filter without a full CUDA ffmpeg. Rather than
report nothing, I built a **proxy**: a 145-line ggml program that constructs the same
graph `scripts/includes/af_stemsplit.c` builds — 6 encoder blocks
(`pad(1,2)` → `conv_2d_direct` 5x5 stride 2 → bias → per-channel affine → LeakyReLU 0.2),
6 decoder blocks (`conv_transpose_2d_p0` stride 2 → asymmetric crop → bias → ReLU →
affine → skip `concat`), then the dilated 4x4 output conv, sigmoid and mask multiply, on a
`[1024, 512, 2]` input. 132 graph nodes, the same channel tables (`ss_conv_io` /
`ss_up_io`), F16 weights cast to F32 in-graph exactly as the filter does. Random weights;
only `ggml_backend_graph_compute` is timed.

**It is a proxy, and here is exactly what it is not:** not the real spleeter weights, no
STFT, no overlap-add, no model load, no ffmpeg. It measures the arithmetic the GPU
backend does for stemsplit and nothing else.

Mean of 20 runs, one run = one U-Net pass over an 1024x512x2 spectrogram (~11.9 s of audio):

| backend | build | per inference | output checksum (n=1048576) |
|---|---|---|---|
| **Vulkan**, default (KHR_coopmat) | mingw static, Windows | **7.4 ms** | sum 66934.5102 |
| **Vulkan**, `GGML_VK_DISABLE_COOPMAT=1` | mingw static, Windows | **11.0 ms** | sum 66857.6852 |
| **CUDA** | upstream prebuilt DLL, Windows | **91.3 ms** | sum 66857.6852 |
| **CUDA** | my own sm_86 build, Linux container | **90.5 ms** | sum 66857.6852 |
| CPU | upstream `ggml-cpu-haswell.dll`, Windows | 287 ms | sum 66857.5133 |

Reading it:

- **Vulkan is 8.3x faster than CUDA on this graph** in the configuration where the two are
  *numerically identical* — with coopmat disabled, Vulkan's output sum matches CUDA's to
  every printed digit (66857.6852). 12.3x with the default coopmat path.
- The correctness column is the point: a backend that skipped work could not match another
  backend's sum. Vulkan's default path differs by 0.11%, which is the known FP16
  accumulator in ggml-vulkan's coopmat conv2d shader that the design doc already documents
  as the reason `stemsplit`'s `use_gpu` defaults to 0 — reproduced here independently.
- Two independent CUDA builds (upstream MSVC prebuilt on Windows; my own CUDA 12.9 sm_86
  build in a Linux container) agree to within 1%, so this is ggml's CUDA conv2d
  implementation, not a bad binary.
- **Reasoned, not measured:** the cause is that ggml-vulkan has a cooperative-matrix
  conv2d shader while ggml-cuda uses a general kernel with no cuDNN. I did not read both
  kernels; the measurement stands on its own either way.

---

## 4. Size: measured

Same source, same flags, only the backend differing. Stripped.

**Linux x86_64, `whisper-cli`:**

| build | stripped size | delta vs its own CPU baseline | can this ship in a static binary? |
|---|---|---|---|
| CPU only (`GGML_STATIC=ON`) | 2.87 MB | — | yes (this is today) |
| **Vulkan** | 64.54 MB | **+61.9 MB** | yes — the shim keeps it static |
| **CUDA sm_86, CUDA libs dynamic** | 60.03 MB | +57.2 MB | **no** — see NEEDED below |
| **CUDA sm_86, `GGML_STATIC=ON`** (cudart_static + cublas_static) | **823.40 MB** | **+820.5 MB** | **no** — see §5 |

The Vulkan number independently reproduces the project's own +59 MB / ~63 MB figure
(Windows: CPU 5.62 MB → Vulkan 68.51 MB, **+62.9 MB**, importing only `ADVAPI32`,
`KERNEL32` and `msvcrt.dll` — no `vulkan-1.dll`, the shim working exactly as §4.2 of the
design says).

`NEEDED` of the CUDA builds:

```
CUDA, dynamic CUDA libs:  libgomp.so.1  libcudart.so.12  libcublas.so.12
                          libcuda.so.1  libnccl.so.2  libstdc++.so.6 libm libgcc_s libc
CUDA, GGML_STATIC=ON:     libcuda.so.1  libnccl.so.2  libstdc++.so.6 libm libgcc_s libc
                          ld-linux-x86-64.so.2
```

`GGML_STATIC=ON` statically links *CUDA's* libraries — that is where the 820 MB comes
from — but the executable is still dynamically linked. It is not the one-file artifact this
project ships.

**And 823 MB is the floor, not the estimate.** It covers **one** GPU architecture (sm_86,
this desktop's card). A shipping build needs several. The measured reference for what that
multiplication costs is upstream's own release: `whisper-cublas-12.4.0-bin-x64.zip` builds
`ARCHS = 500,610,700,750,800,860,890,900` and its `ggml-cuda.dll` alone is **564 MB**,
inside a 1154 MB unpacked directory (`cublasLt64_12.dll` 474 MB, `cublas64_12.dll` 100 MB,
`nvrtc64_120_0.dll` 45 MB). Vulkan's +62 MB covers every vendor and every architecture,
present and future, in one archive.

---

## 5. Can CUDA be linked statically here? No — confirmed, and the brief's earlier result reproduced exactly

A 20-line CUDA probe that prints after each step, built three ways with CUDA 12.9.1:

| binary | ELF type | NEEDED | WSL2 Ubuntu-24.04 | Docker container (same WSL2 kernel) |
|---|---|---|---|---|
| dynamic | PIE | 2 | all 5 steps pass | all 5 steps pass |
| `-cudart static`, dynamic exe | PIE | 2 | all 5 steps pass | all 5 steps pass |
| **fully static, non-PIE** (`-static -static-libgcc -no-pie`) | EXEC | **0** | **STEP1 ok, SIGSEGV at STEP2, exit 139** | **same, exit 139** |
| **fully static, PIE** (Ubuntu's default with `-static`) | DYN | 0 | **SIGSEGV before `main`** | **same, exit 139** |

The non-PIE static case is the brief's earlier result, reproduced precisely:

```
STEP1 cudaRuntimeGetVersion=12090 err=0
Segmentation fault (core dumped)   <- STEP2 cudaDriverGetVersion, the first driver touch
exit=139
```

`cudaRuntimeGetVersion` is answered by `libcudart_static.a` itself and works. The next
call is the first one that needs the *driver*, and that is where the process dies — the
same shape as #42.

Two further facts, both measured:

- **The linker says so out loud.** Linking `libcudart_static.a` with `-static` warns that
  it uses `dlopen` *and* `dlmopen`, "requires at runtime the shared libraries from the
  glibc version used for linking". The static binary has no dynamic loader to complete
  that second-stage load. This is glibc's static-`dlopen` limitation, not something
  specific to NVIDIA.
- **Static PIE fails even earlier.** `strace` shows the crash arrives immediately after
  `mprotect(..., PROT_READ)` with `SEGV_ACCERR` on an address inside the page just made
  read-only — during static-PIE self-relocation / RELRO, before `main`. So it is not even
  "CUDA fails at first use"; with Ubuntu's default PIE it fails at startup.
- Merely linking `cudart` statically into a **dynamic** executable is fine. That is not
  what this project ships.

**Limitation, stated plainly:** both environments available to me sit on the same WSL2
kernel (WSL2 Ubuntu, and Docker Desktop containers which run on it). I could not test
bare-metal Linux from this host, so I cannot separate "static CUDA is broken generally"
from "static CUDA is broken under WSL2's libcuda shim". It does not change the
recommendation — WSL2 is exactly the audience #42 is about, and the glibc warning above is
not WSL-specific — but the distinction is unproven here.

---

## 6. Platform reach: who gains what

Measured unless marked.

| audience | Vulkan (shipped) | CUDA (proposed) |
|---|---|---|
| NVIDIA on Windows | **works** (RTX 3070 found through the shim, static exe) | would work, +820 MB, and only as a non-static binary |
| AMD / Intel on Windows or Linux | **works** (one backend, all vendors) | **nothing** |
| NVIDIA on native Linux | works (*reasoned*: the proprietary driver installs `nvidia_icd.json`; not testable here) | cannot be static (§5) |
| **NVIDIA under WSL2** | **nothing — measured** (see below) | **nothing** — static segfaults, and only a dynamic build works |
| NVIDIA in Docker Desktop containers on this host | **nothing — measured** (no NVIDIA ICD in the container) | works only dynamically |
| macOS / FreeBSD | not shipped (Metal is phase 3) | nothing |

**The WSL2 row is a new finding and it cuts both ways.** NVIDIA's WSL driver exposes CUDA
into the distro (`/usr/lib/wsl/lib/libcuda.so.1`) but **no Linux Vulkan ICD**: the only
NVIDIA Vulkan manifest present, `/usr/lib/wsl/drivers/nvmdi.inf_*/nv-vk64.json`, names
`.\nvoglv64.dll` — a Windows DLL a Linux loader cannot load. Measured with the real
binary:

```
ggml_vulkan: No devices found.
whisper_backend_init_gpu: no GPU found     -> CPU, exit 0, correct transcript
```

So a WSL2 user of the **Linux** binary gets no GPU acceleration from phase 1 — and, per
§5, could not get it from a static CUDA build either. Their GPU path is the **Windows**
binary, where Vulkan does work. That is worth saying in the #69 release notes; it is not
an argument for CUDA, because the only CUDA build that works under WSL2 is a dynamic one
this project does not ship.

The fallback behaviour is correct in every negative case tested: no device → CPU, exit 0,
identical transcript. No crash.

---

## 7. Recommendation

**Do not build phase 2 (CUDA). Close it as measured-and-declined, and put the
measurements in the issue so it is not reopened on the assumption that CUDA is faster.**

The design doc's condition was "if Vulkan turns out to be within a reasonable margin of
CUDA". It is not within a margin — it is ahead:

- stemsplit's graph: Vulkan **8.3x faster** at identical numerics (11.0 ms vs 91 ms), 12.3x
  on its default path.
- whisper's encoder: Vulkan **2.3-3x faster** (32 ms vs 74-95 ms), 431 ms vs 599 ms end to
  end.
- Size: Vulkan +62 MB for every vendor and architecture; CUDA +820 MB for one
  architecture, NVIDIA only.
- Distribution: CUDA **cannot** be put in a static executable here (exit 139), so phase 2
  would breach §3 of the design ("if a GPU backend cannot be made to work inside a static
  binary, it does not ship") on its own terms — before any performance argument is needed.

Any one of those three is enough. Together they make CUDA a large regression in artifact
size and distribution model in exchange for negative performance.

**What I would do with the time instead**, in order:

1. Fix the double-instantiation defect in §10 of the design (both filters initialise
   twice, doubling VRAM). That is a real GPU cost today and it is cheap.
2. Phase 3, Metal — it is the only remaining platform with no GPU path at all, and §9 of
   the design says the expected blocker is not there.
3. Document the two reach gaps this spike found: Vulkan is unavailable inside WSL2 and
   inside Docker Desktop containers on a WSL2 host. Users there should run the Windows
   binary. Cheap to write, and it prevents "GPU support doesn't work" reports.

**What would flip this answer** (so the decision can be revisited on evidence, not
mood): ggml gaining a cuDNN or tensor-core conv2d path that beats its Vulkan coopmat
shader; NVIDIA shipping a statically linkable driver stub; or a customer workload that is
pure `mul_mat` in a shape where cuBLAS wins by enough to justify 820 MB. None of those is
true today.

---

## 8. Reproducing this

Nothing here was committed to the repo besides this file. The throwaway harness, for
whoever revisits it:

- CUDA builds and the static probes: `nvidia/cuda:12.9.1-devel-ubuntu24.04`, whisper.cpp
  `v1.9.1`, `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86`, plus `-DGGML_STATIC=ON` for the
  static-CUDA-libs flavour. The probe is 20 lines of `cuda_runtime.h` calls printing after
  each step; build it three ways as in §5. `nvcc ... -Xlinker -static` needs
  `-Xcompiler -static-libgcc` or it fails on `-lgcc_s` before it gets anywhere.
- Windows Vulkan build: `ubuntu:24.04` + `mingw-w64` + `glslc` + `spirv-headers`, the same
  recipe `scripts/48-whisper.sh` uses (`Vulkan_INCLUDE_DIR` at staged headers,
  `Vulkan_LIBRARY` at a stub archive, `Vulkan_GLSLC_EXECUTABLE` at a *runnable* glslc),
  except that the stub archive **is** `scripts/includes/vk_loader_shim.c` compiled with
  mingw, so ggml-vulkan's three undefined symbols pull the shim in at link time. Ubuntu
  24.04's mingw headers predate `THREAD_POWER_THROTTLING_STATE`, which `ggml-cpu.c` uses:
  a forced-include compat header fixes it. The project's own Windows image has a newer
  mingw and does not need that.
- The U-Net proxy is a single C file against ggml's public API only; it links either
  against the static mingw ggml+Vulkan archives or straight against the prebuilt
  `ggml.dll` / `ggml-base.dll` from upstream's cuBLAS zip (mingw links against a DLL
  directly), and it calls `ggml_backend_load_all()` so the DLL flavour finds its backends.
  It prints an output checksum precisely so a "fast" backend cannot be a backend that did
  nothing.
