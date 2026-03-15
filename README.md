# DeChaff

A macOS app that prepares sermon recordings for podcast distribution. Drop in a raw audio file and it cleans the audio, normalises loudness, encodes to MP3, and embeds ID3 tags with chapter markers — all in one step.

Built for the AV team at [City On a Hill](https://www.cityonahill.co.nz).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange)

---

## Features

- **Voice isolation** — Apple's built-in `AUSoundIsolation` engine removes background noise, room reverb, and crowd sounds
- **Dynamic compression** — evens out volume differences between quiet and loud passages
- **Loudness normalisation** — targets a configurable LUFS level (default −16 LUFS, EBU R128)
- **Silence shortening** — trims long pauses to a configurable maximum duration
- **Mono mixdown** — reduces file size without quality loss for speech
- **MP3 encoding** — via bundled LAME, configurable bitrate (64–256 kbps)
- **ID3 tagging** — embeds title, artist, album, year, and cover artwork
- **Chapter markers** — CTOC/CHAP ID3 frames, compatible with podcast apps
- **Waveform editor** — trim start/end, zoom and scroll, draggable chapter markers, playback with spacebar

## Output filename

The output file is named automatically from the tag fields and saved next to the original:

```
YYYY-MM-DD Sermon Title, Bible Reading | Preacher | Series.mp3
```

## Requirements

- macOS 13.0 or later
- Xcode 15+ to build

## Building

Clone the repo and open `DeChaff.xcodeproj` in Xcode. No external dependencies — LAME is bundled and re-signed at build time.

```bash
git clone https://github.com/howardgrigg/DeChaff.git
cd DeChaff
open DeChaff.xcodeproj
```

## Usage

See [DeChaff User Guide.md](DeChaff%20User%20Guide.md) for full documentation.

**Quick start:**
1. Drop an audio file onto the drop zone (WAV, MP3, M4A, AIFF, FLAC, CAF)
2. Set trim in/out points on the waveform if needed
3. Fill in the Info tags on the right panel
4. Add chapter markers in the Chapters tab
5. Click **Process →**

## How it works

Processing runs through up to five passes:

1. **Voice isolation** — renders the audio through `AUSoundIsolation` (Apple's voice isolation Audio Unit, subtype `'vois'`)
2. **Loudness measurement** — measures integrated loudness using a K-weighted biquad filter cascade (EBU R128)
3. **Gain normalisation** — applies a single gain stage to hit the target LUFS
4. **Silence detection** — identifies runs of silence below −50 dBFS
5. **Silence shortening** — rewrites the audio, trimming detected silences to the configured maximum

ID3 tags (including CTOC/CHAP chapter frames) are written directly as binary after encoding.

## License

MIT
