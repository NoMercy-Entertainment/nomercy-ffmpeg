# Static JPEG XL support (#109)

## Scope

Add libjxl 0.12.0 to all seven platform builds, enabling FFmpeg 9.0's
`libjxl` and `libjxl_anim` encoders and decoders. Retain runtime CPU dispatch,
static linking and the existing licensing configuration. No release or version
bump for this change alone; carry the release note into the next content release.

## Build

Use `scripts/62-libjxl.sh`, picked up by the existing numbered-script runner.
Download the release tag and only its Highway, Brotli and skcms submodules.
A script-local download avoids changing the large shared base image. Separate
dependency scripts would add maintenance without another consumer of these libs.

Build static libraries with the platform's CMake toolchain, disabling tools,
tests, viewers, plugins and optional dependencies. `BUILD_SHARED_LIBS=OFF`
controls the library type; `JPEGXL_STATIC=OFF` avoids upstream's tool-link flags.
Use an argument array for the MinGW x86_64 assembler workaround, preserving
spaces in CFLAGS/CXXFLAGS without increasing the CPU baseline.

Make static export defines public in all three pkg-config files. Add the C++
runtime to libjxl and libjxl_threads: libc++ on Darwin/FreeBSD, libstdc++ on Linux
and Windows (including llvm-mingw's compatibility alias), plus advapi32 on Windows.
Require the installed archives and the full Highway/Brotli/CMS static dependency
closure before enabling FFmpeg's `--enable-libjxl`. Every build/install failure
must abort. Remove the downloaded source only after success.

## Verification

Bash and PowerShell helpers generate a small RGB pattern with varying alpha.
Encode a still and a three-frame animation losslessly, at default effort; force
the corresponding libjxl decoder and compare decoded RGBA with the source.
Comparing the complete raw output detects lost alpha, changed pixels and missing
or duplicated frames. No downloaded samples or optional assets are required.
An additional encode/decode check uses the default distance and effort to
exercise the default lossy path, including the Win64 stack-alignment workaround.

Run these checks from both manual suites and CI smoke gates after the existing
cross-execution guards. Unsupported host/target combinations retain their header
validation; they cannot establish runtime correctness. Build targets sequentially
and record actual build and execution results in the implementation plan.
