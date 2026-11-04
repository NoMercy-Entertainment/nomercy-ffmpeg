# FreeBSD: skip Vulkan (#125)

The user chose to retain the fully static FreeBSD build and omit Vulkan.
Do not add a dynamically linked variant. FreeBSD's static libc cannot open
the Vulkan loader or its drivers through dlopen.

Skip `45-vulkan.sh` on FreeBSD using the existing exit-255 convention. This
also skips shaderc, SPIRV-Cross and the Vulkan-enabled libplacebo build in
that script. Explicitly disable Vulkan and libplacebo in FreeBSD's FFmpeg
configure command to prevent autodetection from enabling them. The existing
whisper/stemsplit CPU backend and ggml Vulkan exclusions already match this
decision. Shared base-image sources remain available for the other platforms.

## Verification

Completed locally on 2026-11-04; logs and probes are in
`output/freebsd-no-vulkan/`.

- All seven target combinations checked under Bash 3.2: FreeBSD and both
  Darwin targets exit 255 before any build work; both Linux and both Windows
  targets still reach the first build operation.
- The actual component runner reports Vulkan skipped successfully on FreeBSD;
  no Vulkan pkg-config file is installed.
- A focused FreeBSD 14.3 cross-build passes using the production compiler,
  sysroot and hardening flags. Vulkan headers are deliberately visible and
  autodetection remains enabled. Both disable flags are taken from the
  production Dockerfile. Generated config.h confirms CONFIG_VULKAN=0 and
  CONFIG_LIBPLACEBO=0. HAP/APV encoders and native decoders still compile/link.
- The resulting executable has the FreeBSD x86_64 ELF header, no dynamic
  interpreter, and both disable flags in its configuration string.
- Existing unit suite: all 169 checks pass. Smoke regression harness:
  26 passed, 0 failed. Bash syntax and staged whitespace checks pass.
- ShellCheck reports existing SC2046/SC2129/SC2181 warnings in the unchanged
  build body, with exclusions for the existing flag expansion, export and cd
  style. It reports no diagnostics in the changed platform guard. No unrelated
  build-script cleanup is included.

This is a focused cross-build, not a full FreeBSD package build or a run on
FreeBSD hardware. No release checklist is ticked. Commit locally; no push or
standalone release.
