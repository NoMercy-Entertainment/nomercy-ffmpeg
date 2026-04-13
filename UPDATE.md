# NoMercy FFmpeg - Release Updates

## Version History

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
