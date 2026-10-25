# DeChaffKit

The processing side of DeChaff, as a Swift package with no UI. The macOS app and the MCP server both build on it.

| Product | What it is |
|---|---|
| `DeChaffCore` | Library: the audio pipeline (voice isolation, compression, levelling, loudness, silence shortening, MP3 encoding, ID3 tags and chapters), on-device transcription, cut-point refinement, and the yt-dlp client |
| `dechaff-mcp` | A [Model Context Protocol](https://modelcontextprotocol.io) server that gives AI assistants such as Claude Desktop or Claude Code access to DeChaff |

```
DeChaff.app (SwiftUI) ─┐
                       ├─► DeChaffCore ─► AVFoundation, AudioToolbox, Speech, SoundAnalysis
dechaff-mcp ───────────┘        ▲
     └─► MCPServer (JSON-RPC over stdio, Foundation only)
```

## MCP server

With the server connected, you can ask an assistant to *"prepare this week's sermon"*. It finds the newest video on the channel and downloads it. It then transcribes the audio and works out where the sermon starts and ends, and where the chapters go. Once you confirm the plan, it produces the finished MP3.

### Build and connect

Building needs Xcode 26 on macOS 26 (Apple Silicon is required for on-device transcription).

```bash
cd DeChaffKit
swift build -c release
# binary: DeChaffKit/.build/release/dechaff-mcp
```

**Claude Code**

```bash
claude mcp add dechaff -- "$PWD/.build/release/dechaff-mcp"
```

**Claude Desktop**: add this to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart the app:

```json
{
  "mcpServers": {
    "dechaff": {
      "command": "/path/to/DeChaff/DeChaffKit/.build/release/dechaff-mcp"
    }
  }
}
```

The server uses the DeChaff app's settings: YouTube channel, title and filename templates, compressor settings and default artwork. It also reuses the yt-dlp copy the app installs, so open DeChaff once before using the server. MP3 encoding uses the LAME binary bundled in `/Applications/DeChaff.app`. To use a different copy, set `DECHAFF_LAME` or install LAME with Homebrew (`brew install lame`).

### Tools

| Tool | Purpose |
|---|---|
| `get_settings` | The app's saved settings and where LAME, yt-dlp and ffmpeg were found |
| `list_channel_videos` | Recent videos on the channel, with titles parsed into sermon fields |
| `download_audio` | Downloads a video's audio and returns the file path |
| `analyze_audio` | Duration, loudness (LUFS), music segments and long silences |
| `transcribe` | On-device transcription with word timings (cached) |
| `get_transcript` | The transcript as `[time] #word_index sentence` lines, or word by word for a time window |
| `search_transcript` | Finds a phrase such as "let's pray" and returns its time and word index |
| `refine_cuts` | Previews where trim and chapter points will land after they are moved into silence |
| `process_sermon` | Trims, cleans, encodes, tags and adds chapters, producing the episode |
| `read_tags` / `write_tags` | Checks or fixes a finished MP3's tags and chapters without re-encoding |
| `get_job` / `cancel_job` | Waits for or stops a long-running job |

The server also provides a `prepare_sermon` prompt that walks the assistant through the whole workflow, and a `dechaff://settings` resource.

Downloading, analysis, transcription and processing take minutes, not seconds. These tools wait up to `wait_seconds` (40 by default). If the work isn't done by then, they return a `job_id`, and the assistant calls `get_job` to keep waiting. This keeps calls inside MCP clients' request timeouts.

All trim and chapter points are on the source recording's timeline. `process_sermon` shifts chapter times to account for the trim and for shortened silences.

## Clean cut points

Speech recognisers time words from the voiced part of each word. In practice they start words late and end them early. A breathy or plosive onset, a final "s" or "t", or room decay can all fall outside the word's timestamps. Cutting exactly at a transcript timestamp can therefore clip the start or end of a word.

`CutPointRefiner` treats the transcript time as a hint and checks it against the audio:

1. It measures a 10 ms energy envelope around the cut and sets a silence threshold from the local noise floor. The threshold is the floor plus 35% of the floor-to-speech range, clamped to between 6 and 15 dB above the floor.
2. **Start cuts** search backwards from the word's transcript start to where the audio actually goes quiet. **End cuts** search forwards from the word's transcript end until the sound has died away.
3. A pause only counts as the boundary if it lasts at least 100 ms. That is longer than the closure before the release of a "t" or "k", so the silence inside "that" isn't mistaken for the end of the word. If words run closer together than that, the refiner accepts a 40 ms gap instead.
4. The cut goes inside that silence, about 150 ms before speech starts or 300 ms after it ends. When the gap is too short for that, the cut goes in the middle of the gap.

Each cut is reported as `clean`, `tight` (short gap, cut placed mid-gap) or `forced` (no silence found; cut at the quietest point, so check it by ear). Refining an already refined cut leaves it where it is.

The app uses the same refiner: picking words on the Trim step's **Transcript** tab now produces refined cuts, and a note appears when an edge couldn't land in clean silence.

## Tests

```bash
cd DeChaffKit
swift test
```

The cut-point refiner, ID3 reading and writing, filename and title templates, chapter remapping and the MCP protocol layer have unit tests. These parts are Foundation-only.
