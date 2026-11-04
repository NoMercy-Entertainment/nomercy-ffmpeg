# Linux x86_64 runtime implementation and verification

Design: [Linux CPU and hardware runtime variants](../specs/2026-11-04-linux-gpu-runtime-design.md).

The user approved retaining `linux-x86_64` as the fully static CPU artifact
for older Linux hosts and adding `linux-x86_64-hardware` using system glibc
2.39 or newer. Codec, C++ and OpenMP libraries must remain static in both;
neither package ships `.so` files. Work and measurements below are local to
2026-11-04. Linux ARM64 and FreeBSD are outside this change.

**Both full production packages are verified locally.** Final ELF/package
gates, smoke/manual suites, RTX NVENC/CUDA and whisper Vulkan inference, and
the four-host static CPU inference matrix pass. FFmpeg's tested Dozen Vulkan
video path remains unsupported and fails cleanly; physical native Linux GPU
execution and unavailable AMD/Intel hardware remain unverified.

## Implementation

1. Keep the canonical Linux x86_64 Docker/Compose/package identity and make
   its GPU dependencies/backends explicitly disabled. Preserve CPU codecs,
   filters and instruction dispatch while removing GPU-processing driver loads.
2. Add the `linux-x86_64-hardware` build and archive identity. Keep the GPU
   dependency stack and hardware components; select system base libraries
   through a checked final-link helper while codecs/C++/OpenMP stay static.
3. Check all executable ELF files before installation. Require no interpreter
   or startup DSOs for CPU; require the system loader, allowed base libraries
   and glibc symbol floor at most 2.39 for hardware. Reject unexpected shared
   dependencies, especially libgomp, and inspect the archives for `.so` files.
4. Extend platform lists, change detection, smoke tests and release/fleet
   expectations for the extra variant. Shared filter helpers must distinguish
   a CPU-only artifact from a hardware build with an unavailable driver.
   Preserve the canonical artifact selection for existing clients.
5. Build/package both production variants. Recheck CPU behavior on glibc
   2.35/2.36 hosts and hardware encode/decode on the RTX, then record the final
   ELF closure, archives, hashes, test results and remaining hardware limits.

These steps are complete. The CPU build also explicitly disables ffnvcodec:
leaving its headers discoverable could re-enable CUDA even with other GPU
options disabled. CPU component gates caught that intermediate configuration;
the corrected full build passes them.

## Investigation evidence

Local logs and investigation fixtures are under `output/linux-gpu-runtime/`;
the earlier GPU control lab is under `output/freebsd-vulkan/gpu/`. These files
are ignored local evidence, not distributed dependencies.

| Check | Result | Evidence |
| --- | --- | --- |
| Existing full static artifact, NVENC | SIGSEGV; shell 139 / subprocess -11 | `wsl-direct-2.log`, earlier `gpu/lab-final/report.json` |
| Existing full static artifact, Vulkan | SIGSEGV, subprocess -11 | Earlier `gpu/lab-final/report.json`, `gdb-static-vulkan.log` |
| Dynamic small FFmpeg control, H.264 NVENC | Three-frame encode passes | Earlier `gpu/lab-final/report.json` |
| Minimal CUDA, dynamic executable | All five main/worker/close modes initialize and find one device, exit 0 | `probes.log`, `probes/` |
| Minimal CUDA, static/static-export/static-PIE | All five modes return CUDA 304, exit 3 | `probes.log`, `probes/` |
| Minimal CUDA, exported static PIE | All five modes SIGSEGV, exit 139 | `probes.log`, `probes/` |
| CUDA and old FFmpeg outside Docker | Static probe fails, dynamic passes; old full FFmpeg SIGSEGV | `wsl-direct-2.log` |
| No-GPU pthread-key reproducer | Four static variants collide at key 0, overwrite storage and invoke wrong destructor; dynamic control uses keys 0/1 correctly | `review/README.md`, executable/plugin sources and logs |
| No-GPU reproducer outside Docker | Same results for all five binaries in Ubuntu 24.04 WSL | `review/outside-docker-*` |
| FFmpeg debugger, NVENC | Worker thread SIGSEGV during teardown after CUDA operating-system error; symbols mostly unresolved | `gdb-static-nvenc.log` |
| First full system-runtime candidate, H.264 NVENC | Encode exit 0; software decode confirms three frames | `hardware.log` |
| First full system-runtime candidate, HEVC NVENC | Encode exit 0; software decode confirms three frames | `hardware.log` |
| First full system-runtime candidate, CUDA decode | Exit 0; NV12 download yields 1,036,800 bytes | `hardware.log` |
| First full system-runtime candidate, whisper Vulkan compute | Real base.en model, two-second JFK sample, RTX 3070 Vulkan backend; exits 0 and matches CPU transcription JSON | `candidate-whisper-gpu.log`, `candidate-whisper.log` |
| First candidate startup dependencies | Shared libgomp still present; fails intended final dependency contract | Candidate ELF inspection; not a release artifact |
| Corrected static-OpenMP probe | Two real OpenMP threads; only libc in startup dependencies | `omp-static.log` |
| First candidate FFmpeg Vulkan video under Dozen | RTX enumerated; upload/scale/download work fails cleanly with exit 218, matching dynamic control | `gpu-system-runtime/report.json` |
| GPU probe result-contract regression | 16 tests pass; cleanup crashes cannot pass on success output | Commit `bd4719d`, `tools/gpu-container/test_probe_contract.py` |

The tested workstation has an RTX 3070, NVIDIA driver 621.01 and WSL2 kernel
`6.6.87.2-microsoft-standard-WSL2`. Running outside Docker removes Docker as a
necessary condition here, while retaining the WSL kernel and Windows-exposed
driver. It does not prove that native Linux has identical CUDA errors.

The pthread-key test uses matching glibc 2.39 runtimes, no GPU APIs, no foreign
deallocation and no `dlclose`. Static and shared allocators independently
issue the same key and access the same thread-local storage. This establishes
a general static/shared runtime hazard even on a matching glibc version. It
does not identify an exact symbol in the stripped FFmpeg crash or prove that
every Vulkan/CUDA failure has precisely that cause.

The first candidate imports `GLIBC_2.39` through libmvec, motivating the
documented hardware minimum. Its libgomp dependency is a separate packaging
defect. The corrected experimental helper removes compiler-added `-fopenmp`
from final linkage and supplies static `-lgomp`; the small OpenMP test verifies
actual two-thread work. The production helper and all final executable
dependency gates now pass, and the hardware tests were repeated successfully
on the final package after that correction.

Dozen is a Vulkan-to-D3D12 translation layer and reports Vulkan 1.2.305. It
enumerates the RTX as discrete hardware, but lacks the format-query path used
by the tested FFmpeg Vulkan workload. The overall GPU lab report therefore
remains failed despite successful NVENC. Separately, real whisper inference
through ggml Vulkan succeeds on both the first candidate and final package,
logging the named RTX 3070 backend. Its transcript JSON matches the CPU run exactly for the
two-second sample (`And so my fellow America!`). That compute result does not
establish the separate Vulkan video path, native Linux operation or stemsplit
GPU inference. The initial recorded 12.4-second GPU run includes startup and
translation; no performance improvement is claimed.

## Final production verification

| Check | Result | Evidence |
| --- | --- | --- |
| Canonical static CPU full build/package | Passed; all three programs start | `cpu-production-build-2.log`, `cpu-package/runtime.log` |
| Hardware full build/package with static OpenMP | Passed; all three programs start, four CPU variants retained | `hardware-production-build.log`, `hardware-package/runtime.log` |
| CPU ELF startup policy | All three have no interpreter and no `DT_NEEDED` libraries | `cpu-package/*-elf.log`, `runtime.log` |
| Hardware ELF startup policy | Interpreter `/lib64/ld-linux-x86-64.so.2`; exactly libc, libm, libmvec and ld-linux DSOs; maximum glibc import 2.39 | `hardware-package/*-elf.log`, `*-ldd.log`, full build link gates |
| Both archive contents | Expected executables/resources, no `.so` files | Both packages' `archive-files.log`, `archive-policy.log` |
| CPU GPU-processing exclusions | No GPU accelerators or Vulkan backend/guard; explicit NVENC/Vulkan requests fail normally, exits 8/244 on the RTX machine | `cpu-package/hwaccels.log`, `runtime.log`, `negative-gpu.json` |
| Actual packaged smoke suites | Both pass | Both packages' `smoke.log`/`smoke.status` |
| CPU full manual suite | 30 passed, 15 skipped, zero failed | `cpu-package/report.json`, `full-suite.log` |
| Hardware full manual suite | 31 passed, 14 skipped, zero failed | `hardware-package/report.json`, `full-suite.log` |
| Final RTX H.264/HEVC NVENC | Both encode exit 0 and software-decode to three frames | `final-hardware/*-nvenc.log`, `*-frames.txt` |
| Final RTX CUDA hardware decode/download | Exit 0; 1,036,800 NV12 bytes | `final-hardware/cuda-decode.log`, `cuda-decoded.nv12` |
| Final whisper Vulkan inference | Real base.en model, two-second JFK audio; named RTX backend; exact CPU/GPU JSON match | `final-whisper/gpu-0.*`, `gpu-1.*`, `hardware-package/whisper.status` |
| Final static CPU foreign-host inference | All 20 cases pass across four glibc hosts | `cpu-foreign-glibc.log` |
| Hardware newer-host startup/CPU fallback | All three programs start on glibc 2.43; both GPU-option settings run real CPU fallback with loader/no ICD | `hardware-newer-host.log`, `hardware-newer-host/` |
| Hardware older-host rejection | Debian 12 reports missing GLIBC_2.38/2.39 versions as expected, requiring the static CPU artifact | `hardware-debian12-startup.log` |
| Final GPU lab | CUDA initialization, NVENC and discrete RTX enumeration pass; Vulkan video exit 218 keeps the overall report failed | `lab-final/report.json`, `lab-final-run.log` |
| Production-link C++/pthread plugin diagnostic | Exact positive and negative signatures pass in Docker and directly under WSL | `tools/linux-runtime/test-dlopen.sh`, its README and local diagnostic evidence |

The four CPU hosts are Ubuntu 26.04/glibc 2.43, Ubuntu 22.04/2.35,
Debian 12/2.36 and Ubuntu 24.04/2.39 with eight Mesa ICDs installed. Each runs
three whisper modes and two stemsplit modes using real pinned models/audio,
including explicit GPU requests and GPU-off behavior. All remain on the CPU.
The whisper model/VAD/JFK inputs were verified against the CI-pinned hashes;
the Spleeter model uses the verified pinned source. These dedicated real-model
runs supplement the generic manual suites, whose asset-dependent tests skip
when those assets are not installed in their suite workspace.

Unavailable AMD/Intel accelerators and platform-specific/asset-dependent cases
are recorded as skips in the manual suite reports. They are not hardware
passes. JPEG XL still/animation/defaults and HAP/APV alpha regressions pass in
both suites.

Regression checks also pass: 269 unit checks, 45 smoke-harness checks, 16 GPU
probe-contract cases, eight-platform Bash/PowerShell parity on PowerShell 5.1
and 7, Node checklist checks and actionlint for all four changed workflows.
The independent review reported no P1/P2 findings.

The produced archives are:

- `cpu-package/ffmpeg-9.0-linux-x86_64.tar.gz`, SHA-256
  `ce1a630f1f160c3c398e30f6ecc73588d3bb8d64c08e88c33fc45fe4723859d4`.
- `hardware-package/ffmpeg-9.0-linux-x86_64-hardware.tar.gz`, SHA-256
  `a1ef20f1e96a242c86df75c0dbd836117b2e54b3478f17e085f16956ecf97224`.

Remaining hardware limits: physical native Linux GPU execution, AMD/Intel
vendor paths and stemsplit GPU inference were not established by these RTX/WSL
runs. FFmpeg's tested Dozen Vulkan video workload remains a clean unsupported
error even though ggml Vulkan whisper compute succeeds. No FreeBSD GPU result
or Linux ARM64 behavior is inferred from this work.

Older glibc compatibility belongs to the separate static CPU artifact. A GPU
flag cannot recover a hardware executable rejected by the system loader
before `main`. Existing consumers retain the canonical artifact name; GPU
consumers must opt into the additional hardware archive explicitly.
