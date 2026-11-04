# Static HAP and APV alpha encoding (#121)

Add Snappy 1.3.1 and OpenAPV 1.1.3.0 to every platform build. Their numbered
scripts follow the JPEG XL download/build pattern, with pinned tags and checked
configure/build/install pipelines. Keeping downloads in these scripts avoids
invalidating the large shared base image. Separate scripts preserve the existing
component failure reporting and the issue's reserved numbers 63 and 64.

Snappy builds only a static library, with tests/benchmarks and the options that
require AVX/AVX2 disabled. FFmpeg's C API check hard-codes libstdc++; replace only
that checked configure line with libc++ on Darwin. FreeBSD already supplies its
libstdc++ compatibility linker script; llvm-mingw supplies its libc++ alias.

OpenAPV uses its own OAPV_BUILD_STATIC_LIB / OAPV_BUILD_SHARED_LIB switches.
Disable shared output and apps explicitly. Retain upstream's per-source SIMD
flags and runtime dispatch, without raising global CPU requirements. Require
liboapv.a, the header and oapv.pc with its public OAPV_STATIC_DEFINE before
enabling FFmpeg. The native FFmpeg decoders do the decoding in both tests.

The pinned FFmpeg 9.0 tarball predates OpenAPV's API-set 1 metadata constructor.
Backport the descriptor initialization and version guard from FFmpeg's
[release/9.0 wrapper](https://github.com/FFmpeg/FFmpeg/blob/release/9.0/libavcodec/liboapvenc.c).
Apply the patch with zero fuzz and checked status; skip it when the updated
constructor is already present. The zero-initialized descriptor selects the
library's default allocator. No unrelated FFmpeg upgrade is needed.

Generate three small frames with a horizontal alpha gradient. HAP uses
`-format hap_alpha` in MOV; APV uses `yuva444p10le` in Matroska. Decode with
`hap` / `apv`, extract alpha and inspect signalstats for every frame. Require
three numeric YMIN, YMAX and YAVG values, with the dark/light ends and midpoint
present. APV's bounds are four times the 8-bit bounds. These lossy formats do not
promise byte equality; a range test also rejects a flat half-transparent plane
that would pass a mean-only check.

Share these checks between Bash/PowerShell manual and CI smoke suites. Preserve
Bash 3.2 and PowerShell 5.1 compatibility. Extend the smoke regression fixtures
to prove missing encoders, opaque alpha, flattened alpha and missing metadata
cannot pass. No downloaded media or optional models are needed.

Validate with seven focused compiler/sysroot probes and a full Linux package,
native Windows AVX2 runs, ARMv8 emulation and explicit foreign-header/import
checks. Reuse the verified JPEG XL dependency/toolchain build state where
possible. Record the exact build and runtime scope; cross-linking does not prove
execution on unavailable macOS, FreeBSD or Windows ARM hardware. Commit locally;
no push or standalone release for this feature.
