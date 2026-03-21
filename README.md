# DeChaff

<img src="DeChaff-iOS-Default-1024x1024@1x.png" alt="DeChaff icon" width="96" align="right" />

A macOS app that prepares sermon recordings for podcast distribution. Work through a simple five-step wizard — load, trim, tag, chapter, configure — then hit Process. DeChaff cleans the audio, normalises loudness, encodes to MP3, and embeds ID3 tags with chapter markers automatically.

Built for the AV team at [City On a Hill](https://www.cityonahill.co.nz).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange)

![DeChaff interface screenshot](DeChaff%20Sermon%20Editing%20Interface.png)

---

## Features

- **Voice isolation** — Apple's built-in `AUSoundIsolation` engine removes background noise, room reverb, and crowd sounds
- **Dynamic compression** — evens out volume differences between quiet and loud passages
- **Loudness normalisation** — targets a configurable LUFS level (default −16 LUFS, EBU R128) with peak limiting to prevent clipping
- **Silence shortening** — trims long pauses to a configurable maximum duration
- **Mono mixdown** — reduces file size without quality loss for speech
- **MP3 encoding** — via bundled LAME, configurable bitrate (64–256 kbps)
- **ID3 tagging** — embeds title, artist, album, year, and cover artwork
- **Chapter markers** — CTOC/CHAP ID3 frames, compatible with podcast apps
- **On-device transcription** — generates a text transcript using macOS speech recognition (macOS 26+)
- **Waveform editor** — trim with drag handles or I/O keys, zoom, scroll, draggable chapter markers

## Quick start

1. **Load** — drop an audio file onto the drop zone (WAV, MP3, M4A, AIFF, FLAC, CAF)
2. **Trim** — drag the orange handles or use the I / O keys to set start and end points
3. **Info** — fill in sermon title, preacher, bible reading, series, date, and artwork
4. **Chapters** — add chapter markers at key moments; first chapter defaults to the start, second to 2 minutes
5. **Output** — review processing options, then click **Process**

## Output filename

Named automatically from the tag fields and saved next to the original:

```
YYYY-MM-DD Sermon Title, Bible Reading | Preacher | Series.mp3
```

## Requirements

- macOS 13.0 or later
- Xcode 15+ to build
- macOS 26+ for on-device transcription

## Building

Clone the repo and open `DeChaff.xcodeproj` in Xcode. No external dependencies — LAME is bundled and re-signed at build time.

```bash
git clone git@github.com:howardgrigg/DeChaff.git
cd DeChaff
open DeChaff.xcodeproj
```

## How it works

Processing runs through up to five passes:

1. **Voice isolation** — renders audio through `AUSoundIsolation` (Apple Audio Unit, subtype `'vois'`)
2. **Dynamic compression** — Apple `kAudioUnitSubType_DynamicsProcessor`, threshold −28 dB, wide soft knee
3. **Loudness measurement** — integrated loudness via K-weighted biquad filter cascade (ITU-R BS.1770 / EBU R128)
4. **Gain normalisation** — single gain stage to hit target LUFS; peak limiter caps output at −1 dBFS to prevent clipping
5. **Silence shortening** — detects runs below −40 dBFS and rewrites audio trimming them to the configured maximum
6. **MP3 encoding** — LAME CBR at the selected bitrate

ID3 tags (including CTOC/CHAP chapter frames) are written directly as binary after encoding.

## License

MIT
