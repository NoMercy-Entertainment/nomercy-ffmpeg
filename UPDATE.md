# NoMercy FFmpeg - Release Updates

## Version History

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
