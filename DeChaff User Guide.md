# DeChaff User Guide

DeChaff prepares sermon recordings for podcast distribution. Work through five steps — Load, Trim, Info, Chapters, Output — then click **Process**. The app cleans the audio, normalises loudness, encodes to MP3, and adds chapter markers with ID3 tags automatically.

---

## The five steps

### Step 1 — Load

There are two ways to load audio:

**From a local file**

Drop an audio file onto the drop zone, or click **Choose File…**

Supported formats: WAV, MP3, M4A, AIFF, FLAC, CAF.

**From YouTube**

The YouTube browser below the drop zone lists recent videos and live streams from your configured channel. Tap a video to download its audio — a progress bar shows download status, and a **Cancel** button lets you abort at any time. Once downloaded, the audio loads automatically and the app advances to Step 2.

While the audio downloads, DeChaff uses on-device Apple Intelligence to parse the YouTube video title into sermon title, Bible reading, preacher, and series fields. If Apple Intelligence isn't available, it falls back to the Claude API (if you have a key configured) and then to built-in text parsing. The tag date is also set automatically from the YouTube upload date. By the time you reach the Info step, these fields are already filled in — just review and adjust if needed.

To configure the channel, open **Settings** (⌘,) and enter a YouTube channel URL or handle (e.g. `@YourChurch`). You can also change how many recent videos are shown (5, 10, or 20). yt-dlp — the download tool — is installed automatically on first launch and kept up to date.

Once a file loads, DeChaff reads the waveform and shows the duration. Click **Next** to continue. You can also drop a file directly onto any step — the app will load it and take you to Step 2.

---

### Step 2 — Trim

The waveform shows the full recording. Two orange handles mark the **trim-in** (start) and **trim-out** (end) — only audio between them is processed. Use this to cut mic noise before the service starts and dead air at the end.

**Setting trim points**
- Drag the orange handles directly on the waveform.
- Or move the playhead and press **I** to set the in point, **O** to set the out point.
- Or click **Set In** / **Set Out** in the toolbar to snap to the current playhead position.
- Trim moves support **undo** — press ⌘Z to step back.

**Playback**
- Click anywhere on the waveform to jump to that position.
- Press **Space** or **K** to play/pause.
- Press **J** or **←** to scrub back 5 seconds; **L** or **→** to scrub forward 5 seconds.

**Zooming and panning**
- **Scroll vertically** on the trackpad to zoom in and out — the zoom anchors on your cursor position so the area under the pointer stays in view. The waveform shows higher detail as you zoom thanks to multi-resolution peak rendering.
- **Scroll horizontally** on the trackpad, or use a mouse's horizontal scroll, to pan left and right when zoomed in.
- **Drag** on an empty area of the waveform to pan when zoomed in.
- **Double-tap** on the waveform to reset zoom to fit the full recording.

---

### Step 3 — Info

These fields are embedded in the MP3 as ID3 tags and used to build the output filename. When loading from YouTube, fields are pre-filled automatically by AI metadata extraction — just review and adjust.

| Field | Notes |
|-------|-------|
| **Sermon Title** | e.g. *The Saving Power of Jesus* |
| **Bible Reading** | e.g. *Romans 1:16–17* |
| **Preacher** | Speaker name — remembered between sessions |
| **Series** | Sermon series title — remembered between sessions |
| **Date** | Defaults to today. The year is embedded in the ID3 tag; the full date prefixes the filename. |
| **Artwork** | Drag an image onto the square, or click to choose a file. Remembered between sessions. |

**Output filename** is built from the tag fields using a customisable template. The default format is:
```
YYYY-MM-DD Sermon Title, Bible Reading | Preacher | Series.mp3
```
You can change the format in **Settings → Templates**. If no tags are filled in, the file is named `<original>_dechaff.mp3`.

The file is saved to the same folder as the original, or to `~/Downloads` when the source was downloaded from YouTube.

---

### Step 4 — Chapters

Chapters appear as markers on the waveform and as a navigable chapter list in podcast apps. When you enter this step, the waveform automatically scrolls to the trim-in point so you're looking at the start of the recording.

**Adding chapters**
- Play or scrub to the moment you want to mark, then click **+ Add Chapter** or press **M**.
- The first chapter is placed at the very start of the trimmed recording and pre-labelled *Bible Reading* (using the text from the Info field if filled in).
- The second chapter defaults to 2 minutes in and is pre-labelled *Sermon*.
- Further chapters are placed at the current playhead position.

**Editing chapters**
- **Drag a chapter marker** on the waveform to reposition it.
- **Click the time field** in the list and type a time directly (`m:ss` or `h:mm:ss`).
- Click the title field to rename a chapter.
- Click the **−** button to delete a chapter.
- Chapter add, remove, and drag all support **undo** — press ⌘Z to step back.

Chapter times are in *output time* — relative to the trim-in point. A chapter at `0:00` plays at the very start of the trimmed recording regardless of where the trim-in handle sits on the original file.

---

### Step 5 — Output

Review the processing options and click **Process** (or press **⌘↩**) when ready.

**Audio Processing**

| Option | Default | What it does |
|--------|---------|-------------|
| **Voice Isolation** | On | Apple's voice isolation engine removes background noise, room reverb, and crowd sounds. |
| **Dynamic Compression** | On | Evens out volume differences — quieter passages are brought up, peaks are controlled. |
| **Long-Term Levelling** | On | A slow automatic gain control that smooths volume differences across the recording with a ~3-second time constant (±6 dB range). Applied between voice isolation and loudness normalisation. |
| **Loudness Normalisation** | On | Adjusts overall level to a target LUFS. Default −16 LUFS suits most podcast platforms. A fast-attack/slow-release soft limiter prevents clipping without dulling transients. |
| **Mono Output** | On | Mixes down to a single channel. Recommended — speech recorded in stereo wastes file size without benefit. |
| **Shorten Long Silences** | On | Finds pauses longer than the threshold and trims them. Default maximum is 1.0 s. |

**Output Format**

| Option | Default | Notes |
|--------|---------|-------|
| **Format** | MP3 | WAV produces a larger uncompressed file. |
| **Bitrate** | 64 kbps | 64 kbps is fine for speech; use 128 kbps+ if music quality matters. |

**Extras**

| Option | Default | Notes |
|--------|---------|-------|
| **Transcribe Audio** | On | Generates a text transcript using on-device speech recognition. Requires macOS 26+. The transcript appears on the done screen and can be copied to the clipboard. |

---

## After processing

When processing finishes, the done screen shows:

- The output filename with a **Reveal in Finder** button
- The transcript (if transcription was enabled), with a **Copy** button
- The **AI Assistant** response (if enabled in Settings → AI Assistant), with **Retry** and **Copy** buttons — this is sent to the Claude API after transcription completes and can include a suggested podcast title, episode description, and key themes

To process another file, click **Process Another** or drop a new file onto the window.

---

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| **Space** or **K** | Play / pause |
| **J** or **←** | Scrub back 5 seconds |
| **L** or **→** | Scrub forward 5 seconds |
| **I** | Set trim in point (Trim step) |
| **O** | Set trim out point (Trim step) |
| **M** | Add chapter marker (Chapters step) |
| **⌘1 – ⌘5** | Navigate to Load / Trim / Info / Chapters / Output |
| **⌘↩** | Start processing |
| **⌘Z / ⌘⇧Z** | Undo / redo |
| **⌘,** | Open Settings |

---

## Settings

Open Settings with **⌘,** or from the DeChaff menu.

### General

- **YouTube channel** — enter a channel URL or `@handle` to populate the YouTube browser
- **Videos to show** — number of recent videos to display (5, 10, or 20)
- **Apple Intelligence** — shows whether on-device AI is available on this Mac; includes a shortcut to enable it in System Settings if it's turned off
- **yt-dlp** — shows install status; tap **Check for Updates** to update the download tool

### AI Assistant

- **Enable AI Assistant** — when on, sends the completed transcript to the Claude API after processing; the response appears on the done screen
- **Claude API key** — stored securely in the macOS Keychain; get a key at [console.anthropic.com](https://console.anthropic.com/settings/keys)
- **Claude model** — choose from a list of known Claude models, or select **Custom…** to enter any model ID; defaults to Claude Sonnet 4.6
- **Prompt template** — customise the instructions sent to Claude; use `{title}`, `{preacher}`, `{series}`, and `{reading}` as placeholders for the sermon's metadata

### Templates

- **YouTube Title Format** — tells DeChaff the naming convention your church uses for YouTube titles; this is injected into the AI system prompt so metadata extraction works correctly for your format. Use placeholders: `{title}`, `{reading}`, `{preacher}`, `{series}`, `{date}`. Default: `{title}, {reading} | {preacher} | {series} | {date}`
- **Output Filename** — controls how the exported file is named. Same placeholders available. A live preview updates as you type so you can see the result before processing. Default: `{date} {title}, {reading} | {preacher} | {series}`

Tap any placeholder chip to append it to the template field.

---

## Tips

- **Trim precisely** — zoom into the waveform at the start and end to place handles exactly, or use I/O keys while playing back. Press ⌘Z to undo if you overshoot.
- **Shorten silences** — the default 1.0 s works well for most sermons. Too short and the delivery can feel rushed; too long and pauses drag.
- **Chapter timing** — if you're unsure where a section starts, play the recording and press **M** at the right moment. You can always drag the marker afterwards to fine-tune it.
- **Preacher and Series** are remembered between sessions — you only need to update them when they change.
- **Artwork** is also remembered between sessions. Set it once and it will be embedded in every recording until you change it.
- **Title format** — if your church's YouTube titles follow a different convention (e.g. `{date} | {preacher} | {title}`), set it once in Settings → Templates and AI extraction will work correctly every time.
- **Keyboard shortcuts** make the workflow fast — load a file, press Space to listen, I/O to trim, M for chapters, ⌘↩ to process, all without reaching for the mouse.
