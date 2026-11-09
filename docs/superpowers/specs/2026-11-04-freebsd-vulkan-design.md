# FreeBSD Vulkan with system runtime libraries (#125)

The user approved using FreeBSD's preinstalled base runtime dynamically to
enable Vulkan, while keeping codec libraries built into FFmpeg and shipping
no `.so` files. This replaces the earlier decision to skip Vulkan on FreeBSD.
There is one FreeBSD build rather than a separate optional variant.

## Link and runtime contract

FreeBSD's static libc provides a
[dlopen stub](https://github.com/freebsd/freebsd-src/blob/releng/14.3/lib/libc/gen/dlfcn.c)
that always fails. Its dynamic runtime linker, `/libexec/ld-elf.so.1`, provides
the working implementation.
Link the base C, math and thread libraries dynamically so the host's loader
and GPU ICD can be opened in the normal FreeBSD process environment. Keep
codec libraries and the C++ support libraries static. Inspect the resulting
ELF interpreter and dependencies; only an explicit set of FreeBSD base
libraries may be required at startup. Do not package shared libraries.

The expected direct dependency allowlist is `libc.so.7`, `libm.so.5` and
`libthr.so.3`. The FFmpeg linker wrapper scopes each codec library to static
archive lookup and the C/math/thread names to dynamic lookup. It supplies
static C++ and unwind libraries explicitly instead of the compiler driver's
shared defaults. Verify the resulting ELF rather than relying on flag names.

The build uses the FreeBSD 14.3 sysroot and supports 14.3 as its baseline.
Compatibility with other host releases must be established by execution,
rather than inferred solely from a successful cross-link.

## GPU and fallback behavior

Build the existing Vulkan/libplacebo dependency stack, including shaderc and
SPIRV-Cross. Enable the ggml Vulkan backend used by whisper and stemsplit.
Use the existing loader shim to open the host's Vulkan loader on demand, and
enable the fork-and-probe driver guard on FreeBSD. The Linux static-glibc
version comparison is specific to Linux and remains unchanged.

GPU use requires a compatible device, the host's Vulkan loader and its ICD.
whisper/stemsplit retain CPU operation when Vulkan is unavailable or rejected
by the guard. Explicitly requested FFmpeg Vulkan hardware operations still
need a working Vulkan installation. Enabling this path does not establish
support for unrelated vendor APIs or prove any particular GPU works.

## Verification boundary

Require checks for dynamic base-library selection, static codec linkage,
Vulkan backend and guard presence, and CPU fallback without a usable loader.
Keep the Bash and PowerShell platform expectations consistent. Build and
cross-link results establish only the artifact's structure and linkability.

Native FreeBSD execution, no-driver fallback and a real GPU run are separate
verification steps. Record their actual results in the implementation plan.
Do not mark hardware release checklist entries or claim GPU acceleration
works until those checks run on suitable FreeBSD hardware.
