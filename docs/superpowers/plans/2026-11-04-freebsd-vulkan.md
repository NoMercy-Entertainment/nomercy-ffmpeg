# FreeBSD Vulkan implementation and verification (#125)

Design: [FreeBSD Vulkan with system runtime libraries](../specs/2026-11-04-freebsd-vulkan-design.md).
Issue: <https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/125>.

The user approved one FreeBSD build that uses its preinstalled base runtime
dynamically, keeps codec/C++ libraries static, and ships no `.so` files.
This supersedes the earlier decision to skip Vulkan. Work and measurements
below were performed locally on 2026-11-04.

**Full production package verified locally.** The complete FreeBSD build,
final binary link gates, archive checks and actual FreeBSD 14.3 guest runtime
checks pass. Physical FreeBSD GPU execution remains unverified.

## Implementation

1. Restore the Vulkan dependency step on FreeBSD and enable ggml Vulkan in
   the whisper build. The existing fork-and-probe guard now runs on FreeBSD;
   Darwin still uses no Vulkan. Native FFmpeg Vulkan and libplacebo are also
   enabled, with `/usr/bin/glslangValidator` selected as the build-host shader
   compiler.
2. Route FreeBSD's final FFmpeg links through `freebsd_link.sh`. Individual
   `-l` arguments use linker push/pop scopes: codec/C++/unwind archives remain
   static; C, math and thread libraries use the dynamic base runtime. Replace
   compiler-added default libraries explicitly and reject `-static`.
3. Check the unstripped `ffmpeg`, `ffprobe` and optional `ffplay` ELF files
   before installation. Require `/libexec/ld-elf.so.1` and dynamic libc; allow
   only `libc.so.7`, `libm.so.5` and `libthr.so.3` in `DT_NEEDED`. Check the
   package listing for shared-library files as well. No codec/runtime DSO is
   allowed into the distribution.
4. Require the production configure results to contain Vulkan, Vulkan 1.4,
   libplacebo and whisper, plus the Vulkan/libplacebo/whisper/stemsplit filters
   and the selected Vulkan decoder/encoder components. All 13 required
   production configuration macros are enabled in the completed full build.
5. Update both shared smoke-helper implementations to expect the FreeBSD
   backend and guard. Startup checks require late model-open evidence;
   preceding fatal errors, signals, timeouts and early option rejection cannot
   be accepted as that evidence. A fatal lavfi failure cannot pass through an
   unrelated WAV fallback.

The supported baseline is the project's FreeBSD 14.3 sysroot. The host must
provide its normal base libraries, and GPU use additionally needs a compatible
Vulkan loader and ICD/driver. No new Linux or Windows linkage policy is
introduced. A Vulkan-enabled build does not establish support for every vendor
API or prove every GPU operates correctly.

## Verified FreeBSD results

Local logs, focused artifacts and disposable VM data are under
`output/freebsd-vulkan/`.

| Check | Result | Evidence |
| --- | --- | --- |
| Full production dependency and FFmpeg build | Passed, exit 0 | `full-refresh-build-5.log` |
| Full production feature/component assertions | All 13 required macros equal 1, including H.264/HEVC/AV1/VP9 Vulkan decoding and AV1 Vulkan encoding | `full-config-components.log` |
| Full ffmpeg/ffprobe/ffplay startup dependencies | Each uses exactly the three allowed base DSOs and the FreeBSD runtime linker | Full build link gates; `vm/full-native-evidence.tar.gz` |
| Full production ggml CPU link gate | All four variants present | `full-refresh-build-5.log` |
| Full package content | Three executables and two libbluray JARs; no `.so` files | `full-package/ffmpeg-9.0-freebsd-x86_64.tar.gz` |
| Full production executable startup | ffmpeg, ffprobe and ffplay all start on FreeBSD 14.3 | `vm/full-package-native.log` |
| Full package backend/guard and startup gates | Passed without a loader and with the real loader/no ICD | `vm/full-package-native.log` |
| Full package JPEG XL/HAP/APV regressions | Still/animated lossless RGBA, default JPEG XL encode/decode and both three-frame alpha gradients pass | `vm/full-package-native.log` |
| Full package module/TLS/allocator and hostile-loader gates | Passed, including GPU-off and destructive controls | `vm/full-package-runtime.log` |
| Full package real-loader/no-ICD paths | Whisper reaches ordinary model-open failure; explicit Vulkan device request fails cleanly | `vm/full-package-real-loader.log` |
| Full artifact Bash cross-exec smoke | Passed presence, backend/guard markers and FreeBSD ELF header validation on the Linux runner | `full-package/smoke-bash.log` |
| Focused FreeBSD FFmpeg/ffprobe cross-build | Passed | `focused/config.h`, `config_components.h`, `runtime.log`, `cpu-link.log` |
| Focused startup dependencies | Only `libm.so.5`, `libthr.so.3`, `libc.so.7`; FreeBSD runtime linker present | `focused/runtime.log`, `ffmpeg-elf.txt` |
| ggml CPU variants survived linking | All four variants present | `focused/cpu-link.log` |
| Actual FreeBSD OS runtime | Kernel, running kernel and userland all `14.3-RELEASE` | `vm/guest-version.txt` |
| Static Snappy/C++ thread plus system dlopen | Passed; the fully static control fails with `Service unavailable` as expected | `vm/native-link-probes.log`, `native-link-probes-restart.log` |
| Late-loaded module constructor, fresh-thread TLS and cross-module allocations | Passed using the actual selective-link helper | `vm/native-runtime-2.log` |
| Hostile loader abort/hang isolation | Guard protects the parent; it reaches the ordinary missing-model failure | `vm/native-runtime-2.log` |
| Hostile fixture controls | GPU-off never opens it; unguarded abort/timeout controls reproduce the failures | `vm/native-runtime-2.log` |
| Real Vulkan loader, no ICD | API 1.4.353 loads and returns `VK_ERROR_INCOMPATIBLE_DRIVER` cleanly | `vm-loader/native-loader-probe-final.log` |
| Real loader through whisper startup | Real-loader diagnostics followed by expected missing-model context failure, exit 251 | `vm-loader/native-tracked-real-loader.log`, `vm/real-loader-tracked/` |
| Explicit FFmpeg Vulkan device request without an ICD | Structured device-creation error, ordinary FFmpeg exit 187; no signal/hang | Same real-loader logs |
| Actual shared Bash helper gates/startup cases | Passed both without a loader and with the real loader/no ICD | `vm/native-shared-helper.log` |

The focused build verified the Vulkan/ggml/libplacebo link and startup path
before the full package was available. The completed production build also
verifies `CONFIG_VULKAN`, `CONFIG_VULKAN_1_4`, `CONFIG_LIBPLACEBO` and
`CONFIG_WHISPER`; scale_vulkan/libplacebo/whisper/stemsplit filters; Vulkan
H.264, HEVC, AV1 and VP9 hardware decoders; and the AV1 Vulkan encoder. These
configuration assertions prove the components are built, while physical GPU
execution remains a separate hardware check.

The Linux-host Bash smoke uses its cross-exec branch for FreeBSD, so its pass
establishes artifact structure and linked feature markers. Actual OS execution
was checked separately using the exported production binaries in the FreeBSD
guest. PowerShell's smoke runner is Windows-only and was not applied to these
FreeBSD executables; its classifier and platform predicates were tested on
PowerShell 5.1 and 7 as recorded below.

The VM boots a real FreeBSD kernel inside QEMU TCG in a Linux container.
It uses two baseline `qemu64` CPUs and 2 GiB of guest RAM, with no KVM or
physical GPU passthrough. The container has a 3 GiB memory limit, two CPU limit,
all capabilities dropped, no new privileges and no published ports. Its
generated SSH client key stays inside the container. A stop/start test passed
with a fresh guest overlay, the same container-only client key and reset guest
host-key state. The verified base image remains unchanged and cached.

The official FreeBSD 14.3 BASIC-CLOUDINIT image is pinned to SHA-256
`002e4ba15a5af021f9765f85c19e03edae396ea83306671a7484659d5fd9da69`.
Guest firstboot updates are disabled to retain the baseline. The current pkg
repository rejected this guest's OS version; no ABI override or package/base
upgrade was forced. A test-only Bash 5.2.37 was built and verified against GNU
checksums/signatures to execute the shared Bash helpers in the guest.

The real loader fixture is official Khronos Vulkan-Loader `v1.4.353`, commit
`1025d2a5a05018b6dbb41440718af7a7f1153a94`, built against the same 14.3
toolchain and Vulkan-Headers 1.4.353. Window-system integrations, tests and
registry code generation are disabled. It is stored only under test-output
directories and the guest's `/tmp`; it is not installed in the release prefix.
The constructor/TLS/hostile-loader DSOs are likewise test fixtures only.

These checks establish startup, dynamic loading and defensive fallback on the
actual FreeBSD OS runtime under emulation. Missing-model tests deliberately
stop before inference. They do not establish inference parity or physical
FreeBSD GPU execution.

## Regression checks

- Bash smoke harness: **40 passed, 0 failed** under Bash 3.2. Coverage includes
  FreeBSD cross-ELF backend/guard/vocabulary gates, late model-open evidence,
  early option rejection, SIGBUS (138), fatal/timeout evidence preceding a
  model message, and failure to bypass a fatal lavfi result via WAV input.
- Unit checks: **169** existing C word-timestamp checks plus **40** FreeBSD
  link/runtime checks pass. The latter exercise static library selection,
  dynamic base selection and rejection of invalid runtime dependencies.
- PowerShell 5.1 and 7: each passes **14** platform predicates and **8** startup
  classifier cases, with parsing checks for the modified scripts.
- GPU lab tooling: **6** Python checks pass for adapter/result handling; these
  unit checks do not turn the hardware execution failures below into passes.
- Relevant Bash syntax/ShellCheck checks pass after the final lint cleanup.
  VM and real-loader helpers pass those checks as well. The real-loader C
  probe builds with `-Wall -Wextra -Werror`. The FreeBSD-specific core-limit
  command has a targeted ShellCheck annotation.

## Separate RTX 3070 Docker lab

This lab uses a Linux container on Docker Desktop/WSL2. It cannot validate a
FreeBSD binary, kernel or NVIDIA driver. Results are retained separately under
`output/freebsd-vulkan/gpu/lab-final/`; its `report.json` has `passed: false`.

| Measurement | Actual result |
| --- | --- |
| Host GPU exposure | RTX 3070 visible; CUDA initialization succeeds and reports one device |
| Requested existing static Linux NoMercy artifact: NVENC | Fails with SIGSEGV (`subprocess` exit -11) |
| Requested existing static Linux NoMercy artifact: Vulkan work | Fails with SIGSEGV (`subprocess` exit -11) |
| Separate dynamically linked FFmpeg control: H.264 NVENC | Three-frame execution passes |
| Mesa Dozen device enumeration | Names `Microsoft Direct3D12 (NVIDIA GeForce RTX 3070)` as a discrete hardware device |
| Separate control: Vulkan upload/filter/download execution | Fails, exit 218 (`-ENOSYS`); no successful frame output |

The requested artifact is the previously built static Linux executable at
`output/hap-apv/full-linux/ffmpeg`, not the new FreeBSD build. The small dynamic
control is labelled separately; its NVENC success cannot turn the requested
artifact's failure into a pass. The existing static Linux/WSL failures remain
unresolved observations outside the FreeBSD link change.

Dozen provides a translated Vulkan-over-D3D12 path and enumerates the actual
RTX adapter. It exposes Vulkan 1.2 and lacks the format-query behavior used by
this FFmpeg Vulkan path. Successful enumeration therefore does not establish
successful Vulkan execution. A CPU renderer, version override or mocked
adapter is not counted as hardware success. Native FreeBSD GPU verification
still requires a FreeBSD host and compatible physical device/driver.

## Production archive and remaining hardware verification

The full production build completed with exit 0 in
`output/freebsd-vulkan/full-refresh-build-5.log`. It used the frozen dependency
context with the final link/runtime helper overlay refreshed after lint.
The exported local archive is
`output/freebsd-vulkan/full-package/ffmpeg-9.0-freebsd-x86_64.tar.gz`
(259,668,793 bytes), SHA-256:

```text
9ecd3419185c2a0dcd5c202737e89503c08b85727f34d4c7fa3b0ca3e161741d
```

All three production executables require only `libm.so.5`, `libthr.so.3` and
`libc.so.7`; their startup and codec/loader/guard checks pass in the actual
FreeBSD 14.3 guest. The archive contains those three executables and two
libbluray JARs, with no `.so` files. Combined native evidence is retained in
`output/freebsd-vulkan/vm/full-native-evidence.tar.gz`.

Native production codec regressions include exact RGBA equality for a JPEG XL
still frame and three animation frames, default JPEG XL encoding/decoding,
and three-frame HAP/APV alpha gradients. These are targeted native regression
checks, rather than a claim that every optional model, GPU or external-media
test in the full manual suite ran.

Physical FreeBSD GPU execution remains unverified. Model inference parity and
unavailable hardware/model checks are not inferred from clean no-driver
startup, missing-model errors or the separate Linux GPU lab.

No real-hardware release checklist is satisfied by these emulation or Linux
GPU lab results. Commit locally after verification; no push or standalone
release is authorized by this work.
