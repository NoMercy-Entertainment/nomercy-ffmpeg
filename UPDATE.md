# NoMercy FFmpeg - Release Updates

## Version History

### Unreleased

- **Security: every bundled library with a known CVE that upstream has fixed
  is on the fixed release.** Checked 2026-11-12 against the CVE records, OSV,
  the Debian tracker and NVD, for every library linked into the binaries.
  - FFmpeg 9.0 → **9.0.2** (the archives keep the `ffmpeg-9.0-` name, so no
    download URL changes; `ffmpeg -version` says 9.0.2)
  - OpenSSL 4.0.0 → **4.0.3**; libsrt 1.5.5 → **1.5.7**; libass 0.17.4 →
    **0.17.5**; libaom 3.13.3 → **3.15.3**; libvpx 1.16.0 → **1.17.0**
  - libjxl 0.12.0 → **0.13.0** (brotli 1.2.1 inside); zlib 1.3.2 → **1.4**;
    freetype 2.14.3 → **2.15.0**; harfbuzz 14.2.0 → **15.1.0**; libpng 1.6.47
    → **1.6.59**; libtiff 4.7.0 → **4.7.2**; giflib 5.2.2 → **6.1.3**
  - librsvg 2.61.3 → **2.61.5**; glib → **2.88.4**; gdk-pixbuf → **2.44.8**;
    pcre2 10.44 → **10.49**; expat 2.6.4 → **2.10.0**
  - libdvdnav 6.1.1 → **7.0.0**; zvbi 0.2.44 → **0.2.46**; tesseract 5.5.2 →
    **5.5.4**; libX11 1.8.13 → **1.8.14**, libXi 1.8.2 → **1.8.4**, libXrender
    0.9.12 → **0.9.13**
  - whisper.cpp stays **1.9.1** with three security fixes of 1.9.5 applied
    (CVE-2026-110810 among them, `scripts/includes/whisper-security-backports.patch`):
    1.9.5 also moves ggml by 773 commits, and ggml is what whisper, stemsplit
    and lyricsalign were measured on.
  - Found while checking: on Windows x64 and Linux x64 glib was built with
    `--wrap-mode=forcefallback`, which compiled glib's own zlib 1.3.1 and
    pcre2 10.44 into the binaries whatever the pins said. glib now takes both
    from the build, and the step fails if it falls back to a wrap.
  - The HLS muxer sources this build ships (`scripts/includes/hlsenc.c`,
    `codecstring.c`, `hlsplaylist.c/.h`, the #12 master-playlist work) are
    whole-file copies. They are now FFmpeg 9.0.2's files plus our changes,
    by a three-way merge: a 9.0-based copy would have reverted 9.0.2's fix
    of two buffer overruns in hlsenc.c's playlist parser (`URI="..."` and
    `IV=0x...` of an existing playlist). The build now checks the SHA-256
    of the upstream file each copy is based on, also for `af_whisper.c`, and
    stops when FFmpeg's file is a different one.
  - glib 2.88 takes three WinRT headers from the toolchain that the
    windows-x86_64 mingw-w64 (11.0.1) lacks. On that toolchain one upstream
    commit, the one that dropped glib's own definitions of them, is reverted
    (`scripts/includes/glib-win32-own-winrt-definitions.patch`); the rest of
    glib is 2.88.4, which no 2.86 release matches for CVE-2026-15588 and
    CVE-2026-16118.
  - **Known CVEs without an upstream fix yet** are listed in
    `docs/security/known-unfixed.md`: 125 in FFmpeg 9.0.2 (every record says
    "through 9.0.2" and no newer FFmpeg release exists; 12 of them are in code
    these builds do not compile), 5 in OpenSSL 4.0.3 (fixed in 4.0.4, not
    tagged yet), and 15 in other libraries whose newest release still has
    them.
- **Breaking, stemsplit 2.0.0:** `use_gpu` defaults to `auto` (it was `0`).
  Spleeter is unchanged: `auto` never takes a GPU for it, same bytes, same
  log lines. A RoFormer run that names no `use_gpu` now takes a GPU that
  passes the filter's checks; on a machine without one it is the CPU run,
  byte for byte, with a few device lines more in the log. `use_gpu=0` gives
  the behaviour of 1.x. Also in 2.0.0: `auto` takes cards with a
  half-precision path (an RTX 3070), because the filter now sets
  `GGML_VK_DISABLE_COOPMAT=1` and `GGML_VK_DISABLE_F16=1` for its process
  itself (process-wide: a `whisper` filter on a GPU in the same ffmpeg
  process is about 3.5 times slower, so run it in another process);
  `cpu_fallback=0` refuses a RoFormer run that would compute on the CPU;
  `cpu_assist` (on by default) lets the CPU compute chunks beside a GPU.
  This release ships stemsplit 2.0.1, which is 2.0.0 with two of its own
  suite checks fixed for machines with a usable GPU; the filter computes as
  2.0.0 and `lavfi.stemsplit.version` says `2.0.1`. The smoke gates run the
  2.0.1 suite, hold a default run and a `use_gpu=auto` run that land on the CPU to
  `use_gpu=0`'s bytes, and compare Spleeter with the v1.0.46 release.
- stemsplit 1.2.1: `use_gpu=auto` runs the RoFormer models on a Vulkan GPU
  when the build enables the backend, the device is a real GPU, it beats the
  CPU in a calibration and passes a self-check against the CPU's output;
  otherwise the CPU, byte for byte. The default `use_gpu=0`, every Spleeter
  output and every option's place are unchanged. The support statement ends
  `Backends enabled for use_gpu=auto: vulkan.` on Linux x86_64,
  Linux ARM64, Windows and FreeBSD and `none.` on macOS;
  the Vulkan builds define `GGML_USE_VULKAN` in whisper's Cflags, which is how
  the filter learns ggml-vulkan is linked in. New frame metadata
  `lavfi.stemsplit.device`. The smoke gates run the 1.2.1 suite, twenty clean
  exits under `use_gpu=auto` held to `use_gpu=0`'s bytes, and the suite's
  devices block on lavapipe on the Linux x86_64 job.
- keydetect 1.6.0: new `minor_profile` option, default `edma`, for the minor
  row of the key correlation; `minor_profile=shaath` restores 1.5.0's key
  decision exactly. Chords, every field and every other option are unchanged.
  beatdetect stays at 1.4.0.
- lyricsalign (#126): new audio filter for time-synced lyrics by CTC forced
  alignment, a wav2vec2 phoneme model on ggml with espeak-ng phonemes, JSON
  Lines output; espeak-ng 1.52.0 is linked statically and its `espeak-ng-data`
  ships in every platform archive. The model lives in
  nomercy-lyricsalign-models and is pinned by the test suites.
- lyricsalign 1.1.0, line starts (#130): two refinements of the onset
  walk-back, both on by default, both only ever moving a written start
  earlier. `soft_walkback` (float, default `0.1`): a line that follows
  another without a pause and begins on a vowel or a sonorant walks back to
  the onset, at most that many seconds; a line that begins on a plosive, a
  fricative or an h stays on its first phone. `unheard_island` (int, default
  `1`): a line whose first word scores below 0.01 starts on the stretch of
  sound no word claims in front of it (0.3 s or longer, after 0.3 s of
  quiet, within 2 s). `lead_in` covers both, so the JSON has no new field.
  `soft_walkback=0:unheard_island=0` writes every line as v1.0.46 did.
- lyricsalign 1.1.0, words (#131): `words[]` keeps its texts when espeak-ng
  writes two tokens as one word ("of the" is `ʌvðə` in en-us), which made
  every word of one English line in eight `text: null`. A joined word that is
  the tokens' own phones is cut into one entry per token; one that sounds
  different joined ("to be") is one entry with `"text":"to be"`; `null` is
  left for a word no token accounts for, and only for that word. Line
  `start`, `end`, `score` and `reason` are unchanged, and a line whose words
  tied before is written byte for byte as before.
- CI: the windows-aarch64 release gate runs on GitHub's hosted windows-11-arm
  runner (#76); verify-rc leaves no files behind in the Lima and FreeBSD
  guests, and fleet-health probes the Lima guest.
- **Breaking, Linux x86_64:** the `linux-x86_64` archive now uses the host's
  glibc and needs glibc 2.35 or newer (Ubuntu 22.04, Debian 12 and newer); it
  is no longer a fully static executable. It is still one archive: hardware
  acceleration (NVENC/CUDA, VAAPI, QuickSync, AMF, Vulkan) is compiled in, is
  detected at run time and is not used on a machine without it. On an older
  system the loader refuses the binary before FFmpeg starts. It is compiled
  and linked against a glibc 2.35 sysroot from Ubuntu
  22.04 instead of the 24.04 base image's 2.39, and the build rejects any
  import above GLIBC_2.35. Codecs, C++ and OpenMP stay
  static; the archive ships no `.so` files. The reason for the change: a GPU
  driver loaded into a static glibc executable gives the process two C
  runtimes, and matching the host's glibc version does not make that
  combination safe. The archive passes ELF, package and smoke gates.
  Whisper/stemsplit CPU inference passes on glibc 2.35/2.36/2.39/2.43 hosts
  (it starts and infers on Ubuntu 22.04 and Debian 12, checked by
  the new `tests/lib/glibc-hosts.sh` in CI); H.264/HEVC NVENC,
  CUDA decode and whisper Vulkan inference pass on an RTX 3070 under WSL2. FFmpeg's
  tested Vulkan upload/scale/download video path fails cleanly through Dozen;
  Linux ARM64 and FreeBSD are unchanged.
- Windows x86_64: D3D12VA is now in the build (hardware decoding for H.264,
  HEVC, AV1, VP9, MPEG-2 and VC-1, the H.264/HEVC/AV1 encoders and the
  scale/deinterlace/mestimate filters). It was silently missing: the x86_64
  toolchain's mingw-w64 11.0.1 has no `d3d12video.h`, so FFmpeg's configure
  left it out. `scripts/47-dxva.sh` now hands FFmpeg the Direct3D 12 headers
  of mingw-w64 14.0.0, pinned by digest, and enables it explicitly on both
  Windows builds. Windows ARM64 already had it.
- FreeBSD: enable Vulkan/libplacebo and ggml Vulkan for whisper/stemsplit by
  linking the FreeBSD base runtime dynamically. Codec libraries remain static,
  and no `.so` files are shipped with FFmpeg. FreeBSD 14.3 is the supported
  baseline; GPU use requires the host's Vulkan loader and driver. Enable the
  fork-and-probe guard and retain CPU fallback. Native FreeBSD GPU verification
  is still required (#125).
- HAP/APV alpha: statically link Snappy 1.3.1 and OpenAPV 1.1.3.0 across all
  platforms (`--enable-libsnappy`, `--enable-liboapv`). Backport FFmpeg's OpenAPV
  API-set 1 metadata descriptor support. Both manual suites and executable CI
  smoke jobs check three-frame alpha gradients through the native decoders.
  Ships with the next content release; no standalone release or version bump
  (#121).
- JPEG XL: statically link libjxl 0.12.0 for still and animated encoding and
  decoding (`--enable-libjxl`), including alpha. Both manual test suites and
  executable CI smoke jobs verify lossless RGBA round-trips and default encoder
  settings. Ships with the next content release; no standalone release or version
  bump (#109).

### v1.0.35 - May 22, 2026

#### ⬆️ FFmpeg 8.0 → 8.1.1 Upgrade

Bumped the upstream FFmpeg source from 8.0 (released 2026-04-01) to 8.1.1 (released 2026-05-04). Every custom muxer, encoder, filter, and source-tree patch continues to work unchanged on 8.1.1.

#### What Changed
- **Upstream FFmpeg**: 8.0 → 8.1.1 (`ffmpeg_version` env in `ffmpeg-base.dockerfile`)
- **Artifact filenames**: every `ffmpeg-8.0-*.tar.gz`/`ffmpeg-8.0-*.zip` path is now parameterized — the FFmpeg version is referenced via the `ffmpeg_version` env var (inherited from the base image) in `scripts/init/package.sh`, via a `FFMPEG_VERSION` build ARG in each platform dockerfile's final stage, and via a workflow-level `env.FFMPEG_VERSION` in `.github/workflows/{main,tests,release}.yml`. Future version bumps only require updating `ffmpeg_version` in `ffmpeg-base.dockerfile` plus the matching defaults in the platform dockerfiles and workflows.

#### Compatibility Verification
- **Patch anchors**: every `sed`/`awk` anchor used by `scripts/49-beatdetect.sh`, `scripts/51-vobsub-muxer.sh`, `scripts/52-ocr-subtitle-encoder.sh`, `scripts/53-sprite-sheet-muxer.sh`, `scripts/54-chapter-vtt-muxer.sh`, and `scripts/55-auto-create-dirs.sh` was verified against the actual 8.1.1 source tree. All patches were dry-run against the real 8.1.1 files and confirmed to insert the expected lines. No patch script required re-anchoring.
- **Custom C sources**: every FFmpeg API symbol used by `af_beatdetect.c`, `vobsubenc.c`, `ocr_subtitle_enc.c`, `spritevttenc.c`, and `chaptervttenc.c` was verified against 8.1.1's headers. The `FFOutputFormat`, `FFCodec`, `FFFilter`, `AVSubtitle`, and `AVSubtitleRect` structs are unchanged in the fields we use. `FFCodec` gained a new `alpha_modes:2` bitfield in 8.1, but our designated initializers are unaffected. `FFInputFormat` removed `read_play`/`read_pause` in 8.1, but we never initialize those fields. No C source change was required.
- **Pinned dependencies**: every minimum-version requirement introduced by 8.1.1's configure is already satisfied by the pinned versions in `ffmpeg-base.dockerfile` (libplacebo 7.349.0 ≥ 4.157.0; libvmaf 3.0.0 ≥ 1.5.2; libass 0.17.3 ≥ 0.13.0; libsvtav1 2.3.0 ≥ 0.8.4; libdav1d 1.5.0 ≥ 0.5.0; etc.). No dependency bump was required.
- **Tarball URL**: `https://ffmpeg.org/releases/ffmpeg-8.1.1.tar.bz2` was verified to download and extract correctly to a `ffmpeg-8.1.1/` directory matching what the base dockerfile expects.

#### Notable Upstream 8.1 Changes (Reference)
The agent's release-notes audit flagged these 8.1 deltas as potentially affecting our patches; all were checked and none required action:
- New `alpha_modes:2` bitfield in `FFCodec` (no effect — we don't initialize it).
- `FFInputFormat` swapped out `read_play`/`read_pause` for `read_set_state`/`handle_command` (no effect — we never initialize either).
- Default C++ standard bumped to C++17 (already supported by the ubuntu 24.04 + GCC 13 base image).
- New optional `--enable-cairo`, `--enable-libmpeghdec`, `--enable-libsvtjpegxs`, `--enable-libopencolorio` flags (not enabled by this build).
- Old HLS protocol handler removed (we don't reference it).
- `AVCodec.pix_fmts` formally deprecated but still present and usable (used by `spritevttenc.c` — compiles cleanly without `-Werror=deprecated-declarations`).

#### Files Touched
- `ffmpeg-base.dockerfile`: `ffmpeg_version=8.0` → `ffmpeg_version=8.1.1`
- `ffmpeg-linux-x86_64.dockerfile`, `ffmpeg-linux-aarch64.dockerfile`, `ffmpeg-windows-x86_64.dockerfile`, `ffmpeg-windows-arm64.dockerfile`, `ffmpeg-darwin-x86_64.dockerfile`, `ffmpeg-darwin-arm64.dockerfile`: final stage replaced hardcoded `ffmpeg-8.0-…` strings with `ARG FFMPEG_VERSION=8.1.1` + `ENV FFMPEG_VERSION` + `${FFMPEG_VERSION}` interpolation in `COPY` and `CMD`.
- `scripts/init/package.sh`: hardcoded `8.0` replaced with `${ffmpeg_version}` (inherited from base image env), with a guard that fails fast if the env var is unset.
- `.github/workflows/main.yml`, `.github/workflows/tests.yml`, `.github/workflows/release.yml`: added workflow-level `env.FFMPEG_VERSION: "8.1.1"`; replaced every `ffmpeg-8.0-…` literal with the env var (via `$FFMPEG_VERSION` in bash blocks and `${{ env.FFMPEG_VERSION }}` / `format()` in GHA expressions).

---

### v1.0.34 - April 13, 2026

#### 🖼️ Added Sprite Sheet Muxer with WebVTT Timeline

**New Feature: Sprite Sheet + WebVTT Muxer (`spritevtt`)**

Added a custom FFmpeg muxer that generates tiled sprite sheet images (PNG or WebP) with companion WebVTT files mapping timestamps to sprite regions using the W3C Media Fragments `#xywh=` standard. This replaces the C# sprite generation pipeline with a single FFmpeg command.

#### What's New
- **Sprite Sheet Generation**: Assembles video thumbnails into a single tiled grid image
- **WebVTT Companion**: Automatically generates a `.vtt` file with `#xywh=` fragment identifiers for each thumbnail region
- **Auto Square Grid**: When `sprite_columns` is 0 (default), calculates the optimal square grid layout via `ceil(sqrt(n))`
- **Dimension Validation**: Validates sprite sheet dimensions against WebP maximum (16383x16383), with clear error messages suggesting alternatives
- **PNG & WebP Support**: Output format determined by file extension — `.png` for PNG, `.webp` for WebP
- **Pixel Format Conversion**: Automatic conversion via swscale when input pixel format doesn't match encoder requirements

#### Technical Details
- Implementation: `scripts/includes/spritevttenc.c`
- Build script: `scripts/53-sprite-sheet-muxer.sh`
- Output: Single sprite sheet image + companion `.vtt` file with W3C Media Fragments `#xywh=` cue payloads
- Frame buffering: All frames held in memory until `write_trailer`, where the grid is assembled and encoded
- Cross-format: Handles planar (YUV420P) and packed (RGB24) pixel formats correctly via `av_pix_fmt_desc_get()`

#### Use Case
This feature enables the NoMercy MediaServer to generate video player seek preview thumbnails (timeline hover previews) entirely within FFmpeg, replacing the previous multi-step C# pipeline. The VTT file is directly consumable by HTML5 video players and the NoMercy video player.

#### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `sprite_columns` | int | 0 (auto) | Number of columns in the sprite grid. 0 = auto square grid |
| `vtt_filename` | string | null | Override the companion VTT filename |
| `relative_path` | bool | true | Use relative filename in VTT cues |

#### Usage Examples
```bash
# Generate sprite sheet from video (one thumbnail every 5 seconds, 160x90)
ffmpeg -i input.mp4 -vf "fps=1/5,scale=160:90" -f spritevtt out.webp
# Produces: out.webp + out.vtt

# PNG output with custom column count
ffmpeg -i input.mp4 -vf "fps=1/10,scale=160:90" -f spritevtt -sprite_columns 10 out.png

# Custom VTT filename
ffmpeg -i input.mp4 -vf "fps=1/5,scale=160:90" -f spritevtt -vtt_filename thumbnails.vtt out.webp
```

#### Example VTT Output
```
WEBVTT

00:00:00.000 --> 00:00:05.000
out.webp#xywh=0,0,160,90

00:00:05.000 --> 00:00:10.000
out.webp#xywh=160,0,160,90

00:00:10.000 --> 00:00:15.000
out.webp#xywh=320,0,160,90

---

### v1.0.31 - April 13, 2026

#### 🔤 Added OCR Subtitle Encoder

**New Feature: Bitmap-to-Text Subtitle Conversion via Tesseract OCR**

Added a custom `ocr_subtitle` encoder that converts bitmap subtitles (DVD/Blu-ray) to text subtitles (WebVTT, SRT) entirely within FFmpeg, eliminating the need for external OCR processing pipelines.

#### What's New
- **OCR Subtitle Encoder**: Converts `dvd_subtitle` and `hdmv_pgs_subtitle` bitmap streams to text using Tesseract OCR
- **Luminance-Weighted Conversion**: Smart grayscale preprocessing that separates bright text from dark outlines for optimal OCR accuracy
- **3x Upscaling**: Nearest-neighbor upscale before OCR for better character and line detection (configurable via `-ocr_scale`)
- **Music Note Fixups**: Optional post-processing (`-ocr_fixups 1`) that corrects common Tesseract misreads of ♪ symbols
- **Language Support**: Auto-detects language from input stream metadata, falls back to English, overridable via `-ocr_language`
- **Cross-Platform**: Available on all supported platforms (Linux x86_64/aarch64, Windows x86_64, macOS x86_64/ARM64)

#### Technical Details
- Encoder implementation: `libavcodec/ocr_subtitle_enc.c`
- Build script: `scripts/52-ocr-subtitle-encoder.sh`
- Codec ID: `AV_CODEC_ID_WEBVTT` (compatible with WebVTT and SRT muxers)
- Dependency: libtesseract (already in build via `--enable-libtesseract`)
- Patched `ffmpeg_mux_init.c` to allow bitmap→text subtitle transcoding

#### Use Case
This feature enables the NoMercy MediaServer to:
- Convert DVD/Blu-ray bitmap subtitles to searchable text formats
- Replace the fragile C# OCR parsing pipeline with a single FFmpeg command
- Support any Tesseract language for international subtitle conversion
- Produce WebVTT files directly consumable by the web video player

#### Usage Example
```bash
# DVD subtitle → WebVTT (explicit encoder)
ffmpeg -i movie.mkv -map 0:s:0 -c:s ocr_subtitle output.vtt

# With French language
ffmpeg -i movie.mkv -map 0:s:0 -c:s ocr_subtitle -ocr_language fra output.vtt

# With music note fixups enabled
ffmpeg -i movie.mkv -map 0:s:0 -c:s ocr_subtitle -ocr_fixups 1 output.vtt

# Custom tessdata path and scale factor
ffmpeg -i movie.mkv -map 0:s:0 -c:s ocr_subtitle -datapath /path/to/tessdata -ocr_scale 4 output.vtt
```

#### Encoder Options
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ocr_language` | string | `eng` | Tesseract OCR language |
| `datapath` | string | *(env)* | Path to tessdata directory (falls back to `TESSDATA_PREFIX`) |
| `ocr_fixups` | bool | `false` | Fix common OCR misreads (♪ music notes) |
| `ocr_scale` | int | `3` | Upscale factor for bitmap before OCR (1-8) |

---

### v1.0.30 - April 12, 2026

#### 📀 Added VOBsub Muxer

**New Feature: DVD Subtitle Extraction to .sub + .idx Pairs**

Added a custom VOBsub muxer that enables FFmpeg to write proper VobSub (.sub + .idx) file pairs when extracting DVD bitmap subtitles, preserving the original bitmap data without re-encoding.

#### What's New
- **VOBsub Muxer**: Writes MPEG-2 PS packets to `.sub` and a VobSub v7 text index to `.idx`
- **Palette Preservation**: Extracts and writes the DVD subtitle color palette to the index file
- **Language Support**: Carries language metadata from the source stream to the index file
- **Normalized Timestamps**: Proper timestamp handling for accurate subtitle timing
- **Cross-Platform**: Available on all supported platforms (Linux x86_64/aarch64, Windows x86_64, macOS x86_64/ARM64)

#### Technical Details
- Muxer implementation: `libavformat/vobsubenc.c`
- Build script: `scripts/51-vobsub-muxer.sh`
- Output: paired `.idx` (text index) + `.sub` (MPEG-2 PS bitmap data)
- Copy codec support: no re-encoding needed, preserves original bitmap data

#### Use Case
This feature enables the NoMercy MediaServer to:
- Extract DVD subtitle streams as standalone VobSub files
- Preserve original bitmap subtitle quality without transcoding
- Support downstream OCR or subtitle editing workflows
- Maintain compatibility with media players that expect VobSub format

#### Usage Example
```bash
# Extract DVD subtitles to VobSub pair
ffmpeg -i movie.mkv -map 0:s:0 -c:s copy output.idx
# produces output.idx (text index) + output.sub (bitmap data)

---

### v1.0.32 - April 13, 2026

#### 📑 Added Chapter VTT Muxer

**New Feature: Direct Chapter-to-WebVTT Output**

Added a custom `chapters_vtt` muxer that reads chapter metadata from input containers (MKV, MP4, etc.) and writes a standard WebVTT chapter file. This eliminates the need for ffprobe JSON parsing when extracting chapter information.

#### What's New
- **Chapter Extraction**: Reads chapter metadata directly from any container format FFmpeg supports
- **WebVTT Output**: Produces spec-compliant WebVTT chapter files with proper timestamp formatting
- **No Stream Mapping**: Works with `-f chapters_vtt` alone — no `-map` flags needed (AVFMT_NOSTREAMS)
- **Graceful Fallback**: Uses "Chapter N" titles when chapters have no title metadata
- **Cross-Platform**: Available on all supported platforms (Linux x86_64/aarch64, Windows x86_64/arm64, macOS x86_64/ARM64)

#### Technical Details
- Implementation: `libavformat/chaptervttenc.c`
- Build script: `scripts/54-chapter-vtt-muxer.sh`
- FFmpeg flags: `AVFMT_NOSTREAMS | AVFMT_NOTIMESTAMPS`
- Symbol: `ff_chapters_vtt_muxer`
- Registration: injected into `allformats.c` and `Makefile` at build time

#### Use Case
This feature enhances the NoMercy MediaServer's ability to:
- Extract chapter markers from MKV and MP4 files into WebVTT for the video player
- Provide chapter navigation in the web and native clients
- Replace multi-step ffprobe JSON pipelines with a single FFmpeg command

#### Usage Examples
```bash
# Extract chapters from an MKV to a WebVTT file
ffmpeg -i input.mkv -f chapters_vtt chapters.vtt

# Pipe chapter output to stdout
ffmpeg -i input.mp4 -f chapters_vtt pipe:1

# Verify the muxer is available
ffmpeg -hide_banner -muxers | grep chapters_vtt
```

#### Example Output
```
WEBVTT

00:00:00.000 --> 00:05:23.456
Introduction

00:05:23.456 --> 00:15:47.890
Act One

00:15:47.890 --> 00:45:12.345
Act Two

---

### v1.0.33 - April 13, 2026

#### 📁 Added Auto-Create Output Directories

**Problem**: When writing output files to paths with subdirectories that don't exist yet, FFmpeg fails with "No such file or directory". Users had to manually run `mkdir -p` before every FFmpeg command targeting nested output paths.

#### What's New
- **Automatic Directory Creation**: FFmpeg now creates parent directories automatically when writing output files
- **Cross-Platform**: Works on Linux, Windows (MinGW), and macOS with proper path separator handling
- **Protocol-Aware**: Skips URL-based paths (http://, rtmp://, etc.) — only creates directories for local file paths
- **Write-Only**: Only triggers for output files (AVIO_FLAG_WRITE), never for input paths
- **Silent Fallback**: If directory creation fails (permissions, etc.), the original FFmpeg error is preserved

#### Technical Details
- Patched file: `libavformat/aviobuf.c` (avio_open2 function)
- Build script: `scripts/55-auto-create-dirs.sh`
- Uses FFmpeg memory allocators (av_strndup/av_free)
- Handles both `/` and `\` path separators

#### Use Case
This feature is essential for the NoMercy MediaServer's encoding pipeline:
- HLS output with segment subdirectories (`output/stream_0/segment_%03d.ts`)
- Organized transcoding output trees (`output/1080p/video.mp4`)
- Batch processing with structured output paths
- Any workflow where output paths include directories that may not exist yet

#### Usage Examples
```bash
# Before: required manual mkdir
mkdir -p /output/hls/stream_0
ffmpeg -i input.mp4 -c copy /output/hls/stream_0/segment_%03d.ts

# After: just works
ffmpeg -i input.mp4 -c copy /output/hls/stream_0/segment_%03d.ts

# Nested output paths work automatically
ffmpeg -i input.mp4 -c:v libx264 /videos/2026/04/encoded/output.mp4

# Network URLs are unaffected
ffmpeg -i input.mp4 -f flv rtmp://server/live/stream
```

---

### v1.0.29 - December 27, 2025

#### 📺 Added Teletext & Closed Caption Support

**New Library: libzvbi v0.2.44**

Added libzvbi (Vertical Blanking Interval) library support to FFmpeg, enabling comprehensive teletext and closed caption decoding capabilities.

#### What's New
- **VBI Decoding**: Full support for VBI data capture and decoding
- **Teletext Support**: Decode teletext subtitles and data from broadcast streams
- **Closed Caption**: Enhanced closed caption extraction and processing
- **Cross-Platform**: Available on all supported platforms (Linux x86_64/aarch64, Windows x86_64, macOS x86_64/ARM64)

#### Technical Details
- Library version: zvbi 0.2.44
- Build script: `scripts/49-libzvbi.sh`
- Source: https://github.com/zapping-vbi/zvbi
- Static linking for optimal performance
- Integrated with FFmpeg's subtitle and data stream handling

#### Use Case
This feature enhances the NoMercy MediaServer's ability to:
- Extract teletext subtitles from broadcast recordings
- Process closed captions from various video sources
- Support legacy broadcast content with embedded VBI data
- Enable accessibility features through subtitle extraction
- Decode ancillary data from video streams

#### Usage Example
```bash
# Extract teletext subtitles
ffmpeg -i input.ts -map 0:v -map 0:d:0 -c:s dvb_teletext output.mkv

# Decode VBI data to subtitles
ffmpeg -i broadcast.mpg -filter_complex "readeia608" -map 0:s output.srt
```

#### Benefits
- **Accessibility**: Better support for subtitles and closed captions
- **Archival**: Preserve teletext data from broadcast recordings
- **Compatibility**: Handle legacy video formats with embedded VBI data
- **Metadata**: Extract additional program information from teletext streams

---

### v1.0.28 - November 4, 2025

#### 🎵 Added BPM Detection & Calculator

**New Feature: Beat Detection Audio Filter**

Added a custom `beatdetect` audio filter to FFmpeg that provides real-time BPM (Beats Per Minute) detection and calculation for audio streams.

#### What's New
- **Custom Audio Filter**: Integrated `af_beatdetect` filter for beat/tempo detection
- **Cross-Platform Support**: Available on all supported platforms (Linux x86_64/aarch64, Windows x86_64, macOS x86_64/ARM64)
- **Real-Time Analysis**: Analyzes audio streams to detect beats and calculate BPM
- **Seamless Integration**: Built directly into FFmpeg's filter chain

#### Technical Details
- Filter implementation: `libavfilter/af_beatdetect.c`
- Build script: `scripts/49-beatdetect.sh`
- Automatic registration in FFmpeg's filter system
- Compatible with all audio codecs and formats

#### Use Case
This feature is designed to enhance the NoMercy MediaServer's ability to:
- Analyze music tracks for tempo information
- Support music library organization by BPM
- Enable beat-synchronized media processing
- Provide metadata enrichment for audio content

#### Usage Example
```bash
# Basic usage - analyze BPM
ffmpeg -i input.mp3 -af beatdetect -f null -

# Capture BPM output from stderr
ffmpeg -i input.mp3 -af beatdetect -f null - 2>&1 | grep "lavfi.beatdetect.bpm"
```

#### Example Output
```
lavfi.beatdetect.bpm=128.50
```

The filter outputs the detected BPM in the format `lavfi.beatdetect.bpm=XXX.XX` which can be easily parsed from the stderr stream. The BPM value is calculated using onset detection, autocorrelation analysis, and comb filtering for accurate tempo detection across a wide range of music genres.

---

## Previous Releases

<!-- Add older version updates below -->

---

## Build Information

**Build System**: Docker-based modular compilation  
**CI/CD**: GitHub Actions with automated testing  
**Quality Assurance**: Security scanning and cross-platform validation  

For complete build documentation, see [README.md](README.md)
