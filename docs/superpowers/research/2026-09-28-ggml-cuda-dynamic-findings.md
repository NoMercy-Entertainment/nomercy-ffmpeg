# ggml CUDA backend on a dynamically-linked ffmpeg — findings

Date: 2026-09-28. Research only, nothing committed to the repo besides this file. Builds
ran in throwaway Docker containers using the project's own `nomercyentertainment/ffmpeg-base:latest`
(`nvidia/cuda:12.9.1-devel-ubuntu24.04`) and the plain `nvidia/cuda:12.9.1-devel-ubuntu24.04` image,
on the host RTX 3070 (driver 617.14) reachable from WSL2 / Docker Desktop with `--gpus all`.

**Scope note, stated up front.** The owner has ruled: CUDA ships, and dropping full static
linking is acceptable to get it. This document is about *how*, not *whether*. Two of the four
questions below were answered decisively with real measurements before the session's time
budget ran out. The other two — the size table for a full multi-arch build, and an actual
filter run inside a dynamically-linked binary — were **in progress when this document was
written** and did not finish; that is stated plainly in each section rather than guessed at.
Everything below is labelled **[measured]**, **[reasoned]**, or **[unresolved]**.

---

## 1. Size — the fixed cost dominates, and it is much bigger than "which archs" implies

**[measured]**, directly from the pinned CUDA 12.9.1 devel image
(`nvidia/cuda:12.9.1-devel-ubuntu24.04`, the project's own base):

| file | static (.a) | shared (.so) |
|---|---|---|
| `libcudart` | 1.4 MB | 724 KB |
| `libcublas` | 159 MB | 101 MB |
| `libcublasLt` | **1.10 GB** | **715 MB** |
| `libnvJitLink` | 128 MB | (not measured) |
| `libnvrtc` | 117 MB | (not measured) |

**[measured, from source]** `ggml/src/ggml-cuda/CMakeLists.txt` (whisper.cpp v1.9.1 / ggml
0.15.1, read directly, not assumed) links `CUDA::cudart_static + CUDA::cublas_static +
CUDA::cublasLt_static` unconditionally whenever `GGML_STATIC=ON`, and `CUDA::cudart +
CUDA::cublas` (dynamic) otherwise — in both cases **unconditionally**, not gated by any ggml
option. `GGML_CUDA_FORCE_MMQ` only changes which kernel path runs at *runtime*; cuBLAS is
linked either way. There is no supported way to build ggml's CUDA backend without cuBLAS(Lt)
short of patching ggml source, which is out of scope (design doc, "no patch to ggml/whisper.cpp
sources").

**This reframes the question.** `CMAKE_CUDA_ARCHITECTURES` / `--generate-code` pruning only
controls how many variants of **our own** handful of `.cu` files (`ggml-cuda.cu`, the
`fattn`/`mmq`/`mmf` template instances) get compiled — a small fraction of the total. It has
**no effect** on cuBLASLt's size: that archive is NVIDIA's own prebuilt fat binary, built once
per CUDA Toolkit release with every architecture NVIDIA supports already baked in, and it is
the same 1.1 GB (static) / 715 MB (shared) file regardless of what we ask nvcc to target.
`CUDA_USE_STATIC_CUDA_RUNTIME` / `-cudart static` only touches the 1.4 MB `cudart` piece — noise
against cuBLASLt.

**[measured, from prior session, cross-checked here]** the 2026-09-26 cuda-vs-vulkan research
already measured the two end states this logic predicts: a **static**, single-arch (`sm_86`)
`whisper-cli` at **823.40 MB** stripped, and a **dynamic**-CUDA-libs build (cudart+cublas as
`NEEDED` .so, cuBLASLt **not bundled**, relying on the host's own CUDA install) at **60.03 MB**.
The gap between 823 MB and the raw ~1.26 GB of input archives is ordinary link-time
dead-stripping (only referenced `.o` members of each `.a` are pulled in) — consistent, not a
contradiction.

**Targeted multi-arch build, size table (requested list: sm_75 Turing, sm_86 Ampere consumer,
sm_89 Ada, sm_90 Hopper — chosen because together they cover the GPUs a self-hoster or small
shop plausibly owns from 2018 onward, and matches the owner's RTX 3070 at sm_86):**

| configuration | stripped size | status |
|---|---|---|
| CPU only (today) | 2.87 MB | [measured, prior session] |
| Vulkan (today) | 64.54 MB | [measured, prior session] |
| CUDA, static, sm_86 only | 823.40 MB | [measured, prior session] |
| CUDA, static, sm_75+86+89+90 | — | **[unresolved]** — build did not finish in-session (see below) |
| CUDA, dynamic cudart+cublas+cublasLt, sm_86 only | 60.03 MB binary **+ 715 MB cuBLASLt.so if bundled, or a new host dependency if not** | [measured for the binary; the trade is reasoned above] |
| CUDA, dynamic, sm_75+86+89+90 | — | **[unresolved]**, same build |

**[reasoned, from the measured fixed-cost analysis above, not itself measured]:** the static
multi-arch number will land close to the single-arch 823 MB, not far above it — the ~820 MB is
almost entirely NVIDIA's fixed cuBLASLt/cuBLAS archives, which do not grow with our arch list;
only our own kernel `.o`s (plausibly tens of MB, not hundreds) scale with the arch count. This
is a real prediction, but it is not the measurement the brief asked for, and the build that
would have confirmed it (`static-multi`, in `/work/build-static-multi` inside container
`cuda-size-build`) was still compiling when this document was written. **Re-run
`cuda-size/build.sh all` (left in the repo's scratch area / reproducible from this doc) to get
the real number before this is treated as settled.**

**The real finding is the shape of the trade, and it does not change with more measurement:**
bundling cuBLASLt in any form (static archive or a shipped `.so`) costs 700 MB-1.1 GB no matter
how the arch list is pruned. The only way to get near the 60 MB number is to **not ship
cuBLASLt at all** and instead require it already present on the host — which is a materially
larger ask than the NVENC design's "the driver's libcuda.so shim is present": cuBLAS/cuBLASLt
are CUDA Toolkit runtime packages, not part of the GPU driver, and most self-hosted WSL2/Docker
Desktop machines that have `nvidia-smi` working (driver only) do **not** have them. This is a
distribution-model decision, not a build flag, and belongs back with the owner: ship ~800
MB-plus, or add a real new host-side runtime dependency beyond "has an NVIDIA driver".

---

## 2. Backend selection with both Vulkan and CUDA compiled in

**[measured, from source]** `ggml-backend-reg.cpp` (pinned tag, read directly):
`ggml_backend_registry()`'s constructor registers backends in exactly this order:
`CUDA → Metal → SYCL → Vulkan → WebGPU → ... → CPU` (line 116-165). Each backend's devices are
appended to one flat `devices` vector in registration order
(`register_backend()` → `register_device()` for each of the backend's own devices, in the
order the backend reports them). `ggml_backend_dev_count()` / `ggml_backend_dev_get(i)` walk
that one vector.

**[measured, from this repo's code]** `scripts/includes/ggml_cpu_dispatch.c`'s `nm_vk_scan()`
and `nm_gpu_at()` (used by both `af_whisper.c` and `af_stemsplit.c` via `gpu_device`, an
integer option with no backend-type awareness) walk `ggml_backend_dev_count()` in that same
raw order and take the **first** device of type `GGML_BACKEND_DEVICE_TYPE_GPU` /
`_IGPU`. `gpu_device=0` (the default for both filters) is "whatever backend registered first
and has a device" — nothing in this file, or in `nm_ggml_backend_init()`, filters or sorts by
backend name.

**What this means today, concretely:** the moment CUDA is compiled in alongside Vulkan, on a
machine with both a working NVIDIA driver and a Vulkan loader (the owner's own desktop),
`ggml_backend_dev_get(0)` returns a **CUDA** device, not the Vulkan device the current
Vulkan-only build defaults to — because CUDA registers first and nothing in this project's
dispatch code reorders that. Given the 2026-09-26 measurement that Vulkan is 2.3-3x faster on
the whisper encoder and 8.3-12.3x faster on the stemsplit graph on this exact RTX 3070, turning
on CUDA with no other change is a **silent regression** for every existing user who has both a
GPU and does nothing differently — device 0 changes out from under `gpu_device=0`'s existing
meaning.

**This needs a real code change, not just a build flag**, and it does not exist on any branch
today (checked `dev`, `feat/nvenc-wsl2-dynamic`, `research/cuda-vs-vulkan`). Concretely:
`nm_backend_discover()` / `nm_gpu_at()` need to prefer devices by **backend name**, not raw
enumeration index — e.g. walk the device list once, bucket by `ggml_backend_dev_backend_reg()`
→ `ggml_backend_reg_name()`, and default to `vulkan` when both are present, with an explicit
opt-in (an env var or a new filter option, since `gpu_device` is already spoken for as a
same-backend index) to prefer `cuda`. This is a design gap, not an implementation bug: §6.3 of
the existing GPU-backends design doc assumed only one GPU backend would ever be compiled in at
once, and that assumption breaks the moment phase 2 exists alongside phase 1.

---

## 3. Does the real ggml CUDA backend work inside a dynamically-linked build on this RTX 3070?

**[unresolved for this session — build in progress, did not complete.]** A `whisper-cli` built
`GGML_STATIC=OFF` (dynamic `cudart`+`cublas`+`cublasLt`, per §1), `-no-pie` (matching the
`feat/nvenc-wsl2-dynamic` plan's flag), was compiling in container `cuda-run-test` under
`docker run --gpus all` when this document was written, with a scripted run against
`ggml-base.en.bin` / `jfk.wav` on the GPU and a `-ng` (CPU) run for a transcript diff, plus
`file` / `ldd` / `readelf -l | grep INTERP` to confirm the ELF shape.

What is already settled and does not need re-proving: the 2026-09-26 cuda-vs-vulkan research
[measured] that a plain dynamic-executable CUDA probe (`cudaRuntimeGetVersion` →
`cudaDriverGetVersion`) succeeds on this exact host/RTX 3070/WSL2-Docker-Desktop combination,
and that linking `libcudart_static.a` into a **dynamic** executable is fine — only the fully
static, non-PIE case segfaults at the first driver touch. What that research did **not** run is
the real ggml CUDA backend — cuBLAS-based matmuls, the actual code path
`nm_ggml_backend_init()` calls — inside a dynamically-linked binary, with output correctness
checked against CPU. That is what this task asked for and what was left running.

**Also worth noting for whoever finishes this:** `feat/nvenc-wsl2-dynamic` is design-and-plan
only. `scripts/includes/nmcompat.c` (the compat object that lets the dynamic linkage keep the
2.34 glibc floor) has **not been committed anywhere** — checked `git ls-tree` on that branch. So
there is no buildable "real ffmpeg, linked the way the plan describes" to test against yet; the
closest faithful proxy without a multi-hour 67-component build is the dynamic-CUDA `whisper-cli`
this task built, which exercises the same `ggml_backend_dev_init()` → cuBLAS path `af_whisper.c`
calls, dynamically linked, `-no-pie`. **Re-run `cuda-size/run-test.sh` (left running in
container `cuda-run-test`) and read its `runtest.gpu.out` / `runtest.cpu.out` transcript diff
before treating GPU correctness as settled.**

---

## 4. Does CUDA move the glibc floor above 2.34?

**[unresolved for this session]** — the `objdump -T | grep GLIBC_` step is wired into both
background builds' `report()` function but neither had produced a stripped, linked binary by
the time this document was written.

**[measured, partial, and it rules out one easy shortcut]:** `objdump -t` against the raw
`.a` files (`libcudart_static.a`, `libcublas_static.a`, `libcublasLt_static.a`) shows **no**
`GLIBC_x.y` version strings at all. This is expected and not informative on its own: archive
members carry only unversioned undefined symbol references (`U memcpy`, not
`memcpy@GLIBC_2.34`) — the version gets attached at final link time against the build image's
real `libc.so.6`, exactly the mechanism the NVENC research already documented for the other
~60 static libraries. So the floor question can only be answered on the **linked, stripped
binary**, which is what the still-running builds were going to produce.

**[reasoned, not measured, low confidence]:** NVIDIA builds its CUDA Toolkit libraries against
comparatively old glibc baselines for broad distro compatibility (their own docs target
RHEL7/CentOS7-class systems for the toolkit), so it is plausible cuBLAS/cuBLASLt do not push
the floor past what the ~38 other archives already require (`__isoc23_*` at 2.38, per the
NVENC research). This is a guess pending the actual `objdump -T`, not a finding — do not build
on it.

---

## What actually blocks shipping this

1. **§1's real number is still open**: whether targeted multi-arch static lands at ~830 MB or
   meaningfully higher needs the finished build, though the fixed-cost analysis makes a large
   jump unlikely.
2. **§2 is a real, unimplemented gap**: shipping CUDA next to Vulkan with no backend-preference
   change regresses every dual-backend machine's default. This has to be designed and built
   before CUDA ships, not discovered after.
3. **§3 and §4 are unresolved, not negative** — nothing found here contradicts the plan working;
   the runs that would confirm or deny it did not finish inside this session's time budget.
   Both containers (`cuda-size-build`, `cuda-run-test`, Docker volumes `cuda-size-work`,
   `cuda-runtest-work`) and the scripts that drive them were left in place for a follow-up pass
   to pick up rather than re-derive.
4. **No native (non-WSL2) Linux machine with an NVIDIA GPU was available**, matching the
   constraint stated up front — WSL2/Docker Desktop was the only environment exercised, which is
   the audience issue #42 is about but is still one environment, not bare metal.
