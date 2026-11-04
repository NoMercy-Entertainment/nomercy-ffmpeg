# HAP/APV alpha implementation and verification

Issue: <https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/121>.
Design: [static HAP/APV](../specs/2026-11-04-hap-apv-alpha-design.md).

1. Inspect the pinned upstream releases and platform-specific C/C++ linkage.
2. Implement static dependency scripts and fail-fast install checks.
3. Add generated-fixture alpha checks to manual and executable smoke suites.
4. Prove the failure cases, build all seven focused targets, and test a full
   Linux binary with both these libraries and the prior JPEG XL feature.
5. Review changes, record actual verification limits, and commit locally.

## Verification results

Completed locally on 2026-11-04. Local probe sources and logs:
`output/hap-apv/`.

The seven focused probes use the platform compiler, sysroot, CMake arguments
and hardening flags, followed by the production `63-libsnappy.sh` and
`64-liboapv.sh` and a small FFmpeg build enabling the encoders, native decoders
and generated alpha fixtures. Unrelated Java/Rust codecs, packaging and signing
are outside these probes.

The full Linux integration build reuses the verified JPEG XL dependency state,
builds both new libraries and applies the compatibility patch, then runs the
unchanged production FFmpeg configure, compile, linker verification and package
steps. It rebuilds the binaries with all existing dependencies, including JPEG
XL; it does not rebuild the unchanged shared base and dependency set.

| Target | Build/link | Runtime |
| --- | --- | --- |
| linux-x86_64 | Focused static FFmpeg and full production package passed | Both alpha checks passed; full smoke passed; codec suite 30 passed, 15 skipped, 0 failed |
| windows-x86_64 | Focused static FFmpeg passed; system DLL imports only | Both alpha checks passed on the AVX2 host in PowerShell 5.1/7 and Git Bash |
| linux-aarch64 | Focused static FFmpeg passed | Both alpha checks passed under QEMU Cortex-A53, without physical ARM hardware |
| windows-aarch64 | Focused FFmpeg passed; ARM64 PE header and system DLL imports verified | No Windows ARM64 host available |
| freebsd-x86_64 | Focused static FFmpeg passed; x86_64/FreeBSD ELF header verified | No FreeBSD host available |
| darwin-x86_64 | Focused FFmpeg passed; x86_64 Mach-O header verified; only libSystem/libc++ imports | No macOS host available |
| darwin-arm64 | Focused FFmpeg passed; ARM64 Mach-O header verified; only libSystem/libc++ imports | No macOS host available |

- Pinned source tags: Snappy `1.3.1`
  (`9c28114a38866f6deeaa826db918293bc28ae410`) and OpenAPV `v1.1.3.0`
  (`b4ff69856b4c3e8849df431ee3db54fd535f9bf3`). Static archives, C headers
  and OpenAPV's public static pkg-config define are checked before enabling
  either dependency in FFmpeg.
- The original FFmpeg 9.0 wrapper fails to compile against OpenAPV's API-set 1
  metadata constructor. The backport from FFmpeg release/9.0 fixes that call
  with a zero-initialized descriptor and preserves the older API guard. The
  final patch applies with zero fuzz and no offsets. Removing blank context
  lines during whitespace review was separately verified to produce
  byte-identical patched FFmpeg source to the patch used by the builds.
- Smoke regression harness: 26 passed, 0 failed, on both the Linux test image
  and Bash 3.2. Each encoder is independently tested for absence, decode
  failure, opaque alpha, flat alpha, truncated frames, empty metadata and
  malformed metadata. Existing JPEG XL/version/dispatcher cases still pass.
- PowerShell helper fixtures: 16 passed, 0 failed in each of PowerShell 5.1
  and 7, covering valid output and those seven faults for each codec.
- Both real alpha checks pass under Bash 3.2 with `set -eu` and BusyBox awk.
  Numeric conversion after stripping CR prevents string comparisons in awk.
- Injected clone, configure, build, install and incomplete-install failures
  abort without enabling FFmpeg for each library (10/10).
- All seven focused binaries carry both configure flags. ELF targets have
  no dynamic interpreter; Windows imports only system DLLs; Darwin imports
  only libSystem/libc++. Neither new codec library is imported dynamically.
- Full Linux smoke and manual suite both exit 0, including both alpha tests
  and all three prior JPEG XL checks. The 15 skips are four GPU/platform and
  eleven model/asset checks; reasons are in `full-linux/report.json`. The
  existing ggml startup checks run, and the production linker check confirms
  all four CPU variants survived the link. No model-based inference parity
  is claimed.
- ShellCheck passes for the build scripts, Bash helper and smoke harness
  (`-e SC2086` for the existing space-separated CMake toolchain arguments).
  Bash syntax and PowerShell 5.1/7 parsing pass. The staged diff review and
  `git diff --cached --check` pass.

Foreign binary headers and successful cross-linking do not establish runtime
correctness on those operating systems. No real-hardware release checklist is
ticked by these probes. This feature receives a local commit, with no push,
version bump or standalone release.
