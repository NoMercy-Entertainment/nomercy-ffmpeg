# Known vulnerabilities without an upstream fix

The CVEs below cover a version this repository builds, and no release of
the project that owns the code fixes them yet. Everything that has a fixed
release is on it (see UPDATE.md). Checked on 2026-11-12 against the CVE
records (cve.org), OSV, the Debian security tracker and NVD; rechecked
before every release, last on 2026-11-22 (NVD records published since
2026-11-17, every bundled version against the Debian tracker's fixed
versions, and the Rust lock files against OSV). The FFmpeg section was
redone on 2026-11-21 for FFmpeg 9.1; no FFmpeg record was published since.

"Not in this build" means the code is not compiled into the binaries: the
library or the FFmpeg component is not enabled on any platform.

## FFmpeg 9.1 (1 CVE)

FFmpeg 9.1 (2026-11-20) fixes 121 of the 125 CVEs that were listed here
against 9.0.2, and CVE-2026-133519 (dvdvideo demuxer, published 2026-11-20).
Checked on 2026-11-21, per fix commit and not per version range: the commit
is an ancestor of the tag `n9.1`, or its cherry-pick on `release/9.1` before
the tag has the same patch-id. The release tarball this build uses is
byte-identical to that tag.

Three of the other four have a fix on FFmpeg's master that 9.1 does not
carry. This build applies those fixes (scripts/69-ffmpeg-security-backports.sh):

| CVE | fix | where |
|---|---|---|
| CVE-2026-125243 | 60bc31fcf654 | uninitialized memory disclosure in ff_jpegls_decode_picture() in libavcodec/jpeglsdec.c |
| CVE-2026-125208, CVE-2026-125270 | b8f159858e2f | out-of-bounds write and read in v4l2_buffer_swframe_to_buf() in libavcodec/v4l2_buffers.c |

One has no fix anywhere yet:

| CVE | published | where |
|---|---|---|
| CVE-2026-120210 | 2026-10-31 | path traversal vulnerability in the IMF demuxer; the fix is an open pull request (FFmpeg PR 25341), not merged on master |

The CVE records still say "through 9.0.2" for all 125 (newest record update
2026-11-14), so a scanner that reads the version range reports none of them
on 9.1, the one above included.

## Other libraries

| library (version built) | CVEs | note |
|---|---|---|
| OpenSSL 4.0.3 | CVE-2026-88822, CVE-2026-88823, CVE-2026-95691, CVE-2026-95692, CVE-2026-107496, CVE-2026-35190, CVE-2026-107493, CVE-2026-124709, CVE-2026-107494, CVE-2026-121481, CVE-2026-121482, CVE-2026-84786, CVE-2026-95690 | advisories of 2026-11-10 and 2026-11-17 and records of 2026-11-18 (the last five; four of them Low, one not rated); fixed in 4.0.4 / 4.1.1, which are not tagged yet on 2026-11-22 |
| openjpeg 2.5.4 | CVE-2026-6192, CVE-2026-107080 | encoder side; 2.5.4 is the newest release |
| libbluray 1.4.1 | CVE-2026-112282, CVE-2026-112283 | "through 1.5.1", the newest release |
| libdvdnav 7.0.0 | CVE-2026-112058 | "through 7.0.0", the newest release |
| gdk-pixbuf 2.44.8 | CVE-2026-81893, CVE-2026-16768, CVE-2026-18090 | the fix commit of the first is in no release; FFmpeg's librsvg decoder does not call the pixbuf loaders |
| expat 2.10.0 | CVE-2026-124317 | "through 2.10.0", the newest release; Windows x64 only, probably not linked |
| giflib 6.1.3 | CVE-2026-26740 | fixed only in the repository head; giflib is not linked into the ffmpeg binary |
| glib 2.88.4 | CVE-2026-86469 | no fixed release |
| libass 0.17.5 | CVE-2026-95127 | reported against 0.17.5, the newest release |
| cairo 1.18.4 | CVE-2025-50422 | "through 1.18.4"; the 1.18.6 notes do not mention it |
| libtiff 4.7.2 | CVE-2026-52492 | in the rgb2ycbcr tool, which is not shipped |
| libstdc++ (GCC 13.3.0, Ubuntu 24.04's `gcc-13`) | CVE-2026-125709, CVE-2026-102010, CVE-2026-114690, CVE-2026-114691, CVE-2026-115455, CVE-2026-115456 | linked statically where the toolchain is GCC. The first: a failed byte-wise `putc()` on a file stream, fixed in no GCC release. The other five (the pb_ds priority queue, parallel-mode search, `vector<bool>` with a huge count, `bitset` from a wide stream, `std::from_chars`): Ubuntu 24.04 has no fixed `gcc-13` package, and that is the compiler of the base image. Of the interfaces they are in, the sources in the base image use only `std::from_chars`, in one file of libplacebo |
| glibc 2.39 inside the linux-aarch64 binaries | 22 CVEs that Ubuntu fixed in its native package after 2.39-0ubuntu8 (CVE-2024-2961, CVE-2025-0395, CVE-2025-8058, CVE-2025-15281, CVE-2026-0861, CVE-2026-0915, CVE-2026-4046, CVE-2026-4437, CVE-2026-4438, CVE-2026-5435, CVE-2026-5450, CVE-2026-5928, CVE-2026-6238, CVE-2026-6368, CVE-2026-6791, CVE-2026-8674, CVE-2026-18374, CVE-2026-19499, CVE-2026-19542, CVE-2026-77117, CVE-2026-80489, CVE-2026-84243), and 6 that have no Ubuntu fix yet (CVE-2026-100290, CVE-2026-115819, CVE-2026-121757, CVE-2026-121758, CVE-2026-124024, CVE-2026-126765) | linux-aarch64 is the one build that links glibc statically, from Ubuntu's cross package `libc6-dev-arm64-cross` 2.39-0ubuntu8cross1. That package is built from glibc 2.39-0ubuntu8 and has no newer version, while the native package is at 2.39-0ubuntu8.12. There is no version to move to: the way out is a patched sysroot, or linking glibc dynamically as linux-x86_64 does. Which of these functions ffmpeg reaches was not worked out. Found on 2026-11-22; every earlier linux-aarch64 release has the same library |

## Not counted here

- whisper.cpp CVE-2026-17512 and CVE-2026-17513 name a development snapshot,
  so whether 1.9.1 is in range cannot be told from the records.
- Rust crates in the librsvg 2.61.5 and rav1e 0.8.1 lock files, checked
  against OSV with `cargo tree` on 2026-11-22. The three with a fixed
  release that reach a static library are moved to it: crossbeam-epoch
  0.9.20 and anyhow 1.0.103 in scripts/21-librav1e.sh, url 2.5.9
  (RUSTSEC-2026-0592) in the two librsvg scripts. Not in any shipped library:
  bytes and rand in librsvg (rand only at compile time, in a proc-macro),
  tracing-subscriber, rustix, git2 and libz-sys in rav1e (the command-line
  tool or the build script). Left: crates marked unmaintained (chrono,
  fxhash, paste, pin-utils, core2) and rand's "unsound with a custom
  logger" note, none of which is a vulnerability.
