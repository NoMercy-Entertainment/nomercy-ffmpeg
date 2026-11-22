# Known vulnerabilities without an upstream fix

The CVEs below cover a version this repository builds, and no release of
the project that owns the code fixes them yet. Everything that has a fixed
release is on it (see UPDATE.md). Checked on 2026-11-12 against the CVE
records (cve.org), OSV, the Debian security tracker and NVD; rechecked
before every release, last on 2026-11-17 (NVD records published since
2026-11-10, and every bundled version against the Debian tracker's fixed
versions). The FFmpeg section was redone on 2026-11-21 for FFmpeg 9.1.

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
| OpenSSL 4.0.3 | CVE-2026-88822, CVE-2026-88823, CVE-2026-95691, CVE-2026-95692, CVE-2026-107496, CVE-2026-35190, CVE-2026-107493, CVE-2026-124709 | advisories of 2026-11-10 and 2026-11-17 (the last three Low); fixed in 4.0.4 / 4.1.1, which are not tagged yet on 2026-11-17 |
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
| libstdc++ (GCC) | CVE-2026-125709 | a failed byte-wise `putc()` on a file stream; no GCC release has the fix yet. Linked statically where the toolchain is GCC |

## Not counted here

- whisper.cpp CVE-2026-17512 and CVE-2026-17513 name a development snapshot,
  so whether 1.9.1 is in range cannot be told from the records.
- Rust crates in the librsvg 2.61.5 and rav1e 0.8.1 lock files, checked
  against OSV with `cargo tree` on 2026-11-17. The two with a fixed release
  that reach a static library are moved to it in scripts/21-librav1e.sh
  (crossbeam-epoch 0.9.20, anyhow 1.0.103). Not in any shipped library:
  bytes and rand in librsvg (rand only at compile time, in a proc-macro),
  tracing-subscriber, rustix, git2 and libz-sys in rav1e (the command-line
  tool or the build script). Left: crates marked unmaintained (chrono,
  fxhash, paste, pin-utils, core2) and rand's "unsound with a custom
  logger" note, none of which is a vulnerability.
