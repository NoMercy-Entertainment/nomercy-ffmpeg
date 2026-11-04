# Linux x86_64 CPU and hardware runtime variants

The user selected two Linux x86_64 artifacts: retain the canonical fully static
CPU build for older Linux hosts, and add a hardware build using the installed
system runtime. Both must keep codecs built into the executables and ship no
`.so` files. This changes x86_64 Linux only; Linux ARM64 and the completed
FreeBSD Vulkan implementation retain their existing policies.

> Later the same day the hardware variant's glibc floor was lowered from
> 2.39 to 2.35 by compiling and linking it against an Ubuntu 22.04 sysroot;
> see [2026-11-04-linux-hardware-glibc235-design.md](2026-11-04-linux-hardware-glibc235-design.md).
> The 2.39 figures below describe the first candidate and are kept as its record.

## Problem and evidence

The existing full static Linux artifact crashes during NVENC and Vulkan
execution on an RTX 3070 exposed through WSL2. A dynamic small FFmpeg control
successfully encodes with NVENC on the same machine. Minimal CUDA probes using
dynamic executables initialize successfully, including worker-thread and
library-close cases. Static variants return CUDA error 304 or crash. The
static/dynamic difference also reproduces directly in Ubuntu 24.04 WSL outside
Docker, so Docker is not a necessary condition on this workstation. Native
Linux behavior remains a separate verification target.

An independent executable/plugin test uses no GPU library. Static and shared
glibc 2.39 each allocate pthread key 0, overwrite the same thread-local slot,
and dispatch a destructor with the other module's value. The dynamic control
uses distinct keys and correct destructors. This demonstrates a general
runtime conflict despite matching glibc versions. It is consistent with the
observed FFmpeg thread-exit crash; stripped backtraces do not prove the exact
function or mechanism causing every CUDA/Vulkan failure.

## Artifact and runtime contract

| Artifact | Runtime | GPU support |
| --- | --- | --- |
| `linux-x86_64` | Fully static executable, preserving older-host CPU use | FFmpeg hardware processing and whisper/stemsplit Vulkan disabled |
| `linux-x86_64-hardware` | Host glibc **2.39 or newer** and normal system loader/base libraries | Compiled hardware paths use installed drivers/loaders |

The canonical archive remains `ffmpeg-${ffmpeg_version}-linux-x86_64.tar.gz`.
The additional archive is
`ffmpeg-${ffmpeg_version}-linux-x86_64-hardware.tar.gz`. Both contain ffmpeg,
ffprobe and ffplay where built, plus the existing non-DSO package resources.
Keep the artifact identity consistent across Docker Compose, build change
detection, packaging, smoke tests, manifests and release verification. Existing
consumers selecting the canonical platform continue to receive CPU operation;
hardware use requires an explicit variant selection.

The CPU variant disables GPU dependencies, native FFmpeg hardware paths and
ggml GPU backends at build time. CPU whisper/stemsplit and CPU instruction
dispatch remain available. A runtime GPU-off flag alone is insufficient to
establish that FFmpeg's processing backends never load a GPU driver. This
contract does not cover unrelated SDL presentation or optional BD-J plugins.

The hardware variant links codec/dependency archives, libstdc++, GCC support
and OpenMP statically. It links only an explicit allowlist of system base
libraries dynamically, using a final-link wrapper and verifying the resulting
ELF. Prevent compiler options such as `-fopenmp` from silently adding shared
libgomp; supply static OpenMP explicitly. Shared codec, C++, OpenMP or GCC
support libraries must fail the startup-dependency gate. Neither archive may
contain shared-library files.

The final x86_64 hardware ELF interpreter is `/lib64/ld-linux-x86-64.so.2`.
The measured direct startup dependencies are exactly `libc.so.6`, `libm.so.6`,
`libmvec.so.1` and `ld-linux-x86-64.so.2`. Other DSOs are rejected by the gate;
graphics drivers/loaders may still be loaded on demand from the host.

glibc 2.39 is an intentional minimum for the hardware variant: the final
executables' maximum imported version is `GLIBC_2.39`. Verify versioned
imports from every final executable and reject accidental increases above
the documented floor. CPU operation on older glibc uses the separate static
artifact. A GPU-off flag cannot help when the system loader rejects a missing
symbol before the hardware executable reaches `main`.

## Hardware and fallback behavior

Keep the existing native FFmpeg acceleration paths and Vulkan/libplacebo/ggml
Vulkan in the hardware variant. Drivers and the Vulkan loader/ICD come from
the installed host; no driver files or runtime DSOs ship with FFmpeg. The
system C runtime is already the runtime used by the executable, avoiding the
second static/shared glibc combination exposed by the reproducer.

Retain the Vulkan fork-and-probe guard and CPU fallback for unavailable,
crashing, hanging or software-only drivers. System-runtime linkage does not
make a missing driver or unsupported GPU API work. Explicit hardware requests
must report ordinary errors when unavailable. Existing Linux static-runtime
version checks must not incorrectly reject a hardware variant using the host
runtime. The static CPU variant must not attempt the loader path at all.

Both final production archives pass the ELF/package gates with no supplied
shared objects. The hardware archive passes H.264 and HEVC NVENC,
CUDA decode/download and real whisper inference through ggml Vulkan on the
workstation's RTX 3070. The GPU and CPU transcripts match for the tested
two-second JFK sample. An initial shared libgomp leak was corrected and the
hardware checks repeated on the final static-OpenMP package. WSL Dozen fails
FFmpeg's tested Vulkan
upload/scale/download video workload with an ordinary exit 218, as does the
dynamic control. That video limitation is separate from the successful ggml
Vulkan compute path. Physical native Linux GPU execution remains unverified.

The final static CPU archive passes 20 real inference cases across Ubuntu
22.04 (glibc 2.35), Debian 12 (2.36), Ubuntu 24.04 (2.39, eight Mesa ICDs) and
Ubuntu 26.04 (2.43), including explicit GPU requests remaining on the CPU.
Hardware-program startup and real CPU fallback also pass on glibc 2.43;
Debian 12 rejects the hardware executable's newer glibc imports as expected.

## Acceptance criteria

1. Build both full production variants, assert the intended enabled/disabled
   components and preserve the existing CPU backend variants.
2. Require the CPU executables to have no ELF interpreter or startup DSOs.
   Verify hardware interpreter, exact permitted base-library closure and
   versioned glibc imports, rejecting shared libgomp/libstdc++/codec libraries.
   Inspect both archives for zero shipped shared objects.
3. Execute CPU startup, representative codec/alpha/JPEG XL and filter/dispatch
   checks on the build host and older glibc hosts, including 2.35 and 2.36.
   Demonstrate that FFmpeg hardware processing and whisper/stemsplit do not
   load GPU drivers even when host loaders are available or hostile.
4. Execute final hardware NVENC encode/decode and CUDA decode/download on the
   RTX, requiring successful process completion and validated output. Exercise
   CPU fallback/no-driver behavior on a compatible system runtime.
5. Cover both variant identities in automated tests/workflows. A success
   message followed by a cleanup crash or timeout must fail a GPU probe.
6. Record WSL, native Linux, Vulkan and vendor-specific results separately.
   Do not infer AMD, Intel or physical native Linux support from RTX/WSL tests.

The implementation plan records completed checks and remaining hardware limits.
