# NoMercy FFmpeg

<div align="center">

[![CI/CD Pipeline](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/actions/workflows/main.yml/badge.svg)](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/actions/workflows/main.yml)
[![npm](https://img.shields.io/npm/v/%40nomercy-entertainment%2Fffmpeg-static?label=ffmpeg-static)](https://www.npmjs.com/package/@nomercy-entertainment/ffmpeg-static)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

</div>

NoMercy FFmpeg is a custom build of FFmpeg 9.0, built from the 9.0.2 point release. It is tuned for the MediaServer, not for general use. For standard FFmpeg binaries, see [ffmpeg.org](https://ffmpeg.org/). The licence terms are on the [License](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/License) page.

It is not stock FFmpeg. It adds filters, muxers, input protocols and patches that the official build does not have. It ships as one self-contained archive per platform, with the codec libraries built in.

The full documentation is in the [Wiki](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Home). This page is the overview.

## Download

Get the archive for your platform from the [Releases page](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/releases). See [Installation](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Installation) for details.

Quick start:

```bash
tar -xzf ffmpeg-9.0-linux-x86_64-v*.tar.gz   # the name ends in the release tag
./ffmpeg -version
```

From Node.js, run `npm install @nomercy-entertainment/ffmpeg-static`. See [npm-Package](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/npm-Package).

## Platforms

Seven platforms: Linux (x86_64, aarch64), Windows (x86_64, ARM64), macOS (x86_64, Apple Silicon) and FreeBSD (x86_64). Linux x86_64 needs glibc 2.35 or newer. See [Platforms](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Platforms).

## Components

Every NoMercy-only component has its own Wiki page.

### Filters

- **stemsplit** — splits a music track into vocals and accompaniment, with Spleeter or RoFormer engines. [Filter-stemsplit](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-stemsplit) ([Spleeter](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-stemsplit-Spleeter), [RoFormer](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-stemsplit-RoFormer))
- **lyricsalign** — places known lyric text on a vocal stem by forced alignment. [Filter-lyricsalign](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-lyricsalign)
- **trailingsilence** — reports where the audible content of a stream ends. [Filter-trailingsilence](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-trailingsilence)
- **keydetect** — detects the musical key and chord progression of a track. [Filter-keydetect](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-keydetect)
- **beatdetect** — reports tempo in BPM, beat positions and a confidence value. [Filter-beatdetect](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Filter-beatdetect)

### Muxers

- **spritevtt** — writes thumbnails as one tiled sprite sheet plus a WebVTT map for scrubbing previews. [Muxer-Sprite-Sheet](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Muxer-Sprite-Sheet)
- **chapters_vtt** — writes the chapters of a file as a WebVTT file. [Muxer-Chapter-VTT](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Muxer-Chapter-VTT)
- **vobsub** — writes DVD bitmap subtitles as an `.idx` and `.sub` pair. [Muxer-VOBsub](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Muxer-VOBsub)

### Protocols

- **dvdread:** — reads a DVD title as one byte stream through libdvdread. [Protocol-dvdread](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Protocol-dvdread)
- **omnidrive:** — reads a disc sector by sector from an OmniDrive optical drive. [Protocol-OmniDrive](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Protocol-OmniDrive)

### Other patches

- **Whisper language detection** — the `whisper` filter reports the detected language in metadata and JSON output. [Whisper-Language-Detection](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Whisper-Language-Detection)
- **Whisper word timestamps** — word-level timestamps, prompt and beam search for `whisper`. [Whisper-Word-Timestamps](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Whisper-Word-Timestamps)
- **Auto-create directories** — every local file opened for writing through the file protocol gets its missing parent directories: the main output, segment, HLS, image2 and tee outputs, and muxer side files; `pipe:` and network protocols are untouched. Files ffmpeg writes outside the file protocol get their folders too: the two-pass log (`-passlogfile`, also with libx264), `-report`, `-vstats_file`, filter stats files such as psnr, ssim or loudnorm, the stats, csv and dump files libx264 and libx265 write themselves, and the libvmaf log. Files opened only for reading never create a folder. [Auto-Create-Directories](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Auto-Create-Directories)
- **AACS and BD+** — reads encrypted Blu-ray discs through `bluray:` with a built-in key database. [AACS-and-BDplus](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/AACS-and-BDplus)
- **HLS master playlist** — the `hls` muxer writes a master playlist that meets Apple's HLS rules. [HLS-Master-Playlist](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/HLS-Master-Playlist)
- **Subtitle OCR** — `ocr_subtitle` converts DVD and Blu-ray bitmap subtitles to WebVTT with Tesseract. [Subtitles-OCR](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Subtitles-OCR)
- **HEVC alpha** — `ffprobe` reports `yuva420p` for HEVC video with a transparent layer. [HEVC-Alpha](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/HEVC-Alpha)

### Acceleration

- **GPU acceleration** — `whisper`, `stemsplit` and `lyricsalign` can run on a GPU through Vulkan: `whisper` by default, `stemsplit` RoFormer when the GPU computes like the CPU, `lyricsalign` only with `use_gpu=1`. macOS uses Metal. [GPU-Acceleration](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/GPU-Acceleration)
- **Metal** — the GPU path on Apple Silicon. [Metal](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Metal)
- **CPU instruction sets** — ggml is built per instruction-set level and on most platforms picks one at run time. [CPU-Instruction-Sets](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/CPU-Instruction-Sets)

### Bundled libraries

x264, x265, SVT-AV1, libvpx, libopus, libass, libbluray, whisper.cpp, Tesseract and more. See [Codecs-and-Libraries](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Codecs-and-Libraries).

## Contributing

Open an issue first. A pull request comes after the proposal is agreed: fork, then open the PR into `dev`. Fork PRs get no build or test run. Maintainers build and test them. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Contributing](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Contributing) page. The build is explained in [Architecture](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Architecture), [Building-Locally](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Building-Locally), [Adding-or-Updating-a-Library](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Adding-or-Updating-a-Library), [Testing](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Testing) and [CI-and-Releases](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/CI-and-Releases).

## Security

Report a vulnerability privately, as described in [SECURITY.md](SECURITY.md). More on the [Security](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Security) page. Known unfixed findings are listed in [docs/security/known-unfixed.md](docs/security/known-unfixed.md).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file and the [License](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/License) page for details. Note that the compiled FFmpeg binaries themselves are built with `--enable-gpl --enable-nonfree` and are intended for internal use.

## About

**NoMercy Entertainment** builds media streaming and processing software.

- Website: [nomercy.tv](https://nomercy.tv)
- Contact: support@nomercy.tv
- GitHub: [NoMercy-Entertainment](https://github.com/NoMercy-Entertainment)
