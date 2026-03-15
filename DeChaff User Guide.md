# DeChaff User Guide

DeChaff prepares sermon recordings for podcast distribution. Drop in a raw audio file and it cleans the audio, normalises loudness, encodes to MP3, and adds chapter markers with ID3 tags — all in one step.

---

## Basic workflow

1. **Drop a file** onto the drop zone (or click **Choose File…**). Supported formats: WAV, MP3, M4A, AIFF, FLAC, CAF.
2. The waveform appears at the bottom of the window. Trim the recording if needed (see below).
3. Fill in the **Info** tags on the right if you want them embedded in the MP3.
4. Add **Chapter** markers if needed.
5. Click **Process →** to run. The output file is saved next to the original.

---

## Waveform & trimming

The waveform panel at the bottom shows the full recording. Two orange handles mark the **trim-in** (start) and **trim-out** (end) — only audio between them is processed. This is useful for cutting mic noise before the service starts and dead air at the end.

**Setting trim points**
- Drag the orange handles directly on the waveform.
- Or click to position the playhead, then click **Set In** or **Set Out** to snap the nearest handle to the playhead.

**Playback**
- Click anywhere on the waveform to jump to that position.
- Press **Space** to play/pause (works unless a text field is focused).
- The golden playhead line shows the current position.

**Zooming in for precision**
- **Pinch** on the trackpad to zoom in — the waveform shows higher detail as you zoom.
- The scrollbar below the waveform appears when zoomed; drag it to pan, or use the trackpad scroll wheel.
- **Double-click** the waveform to zoom back out to full view.

---

## Processing options

| Option | What it does |
|--------|-------------|
| **Voice Isolation** | Runs Apple's built-in voice isolation engine to remove background noise, room reverb, and crowd sounds. |
| **Dynamic Compression** | Evens out volume differences — quieter passages are brought up, peaks are controlled. Helps with preachers who vary a lot in volume. |
| **Loudness Normalisation** | Adjusts the overall level to a target measured in LUFS (the broadcast standard). Default −16 LUFS suits most podcast platforms; use the slider to adjust. |
| **Mono output** | Mixes down to a single channel. Recommended — sermons recorded in stereo waste file size without benefit. |
| **Shorten long silences** | Finds pauses longer than the threshold and trims them. Useful for tightening recordings with long gaps between thoughts. The slider sets the maximum silence length to keep. |
| **MP3 bitrate** | Quality/size trade-off for the MP3 output. 64 kbps is fine for speech; use 128 kbps+ if music quality matters. |

---

## Info tags (right panel → Info tab)

These fields are embedded in the MP3 as ID3 tags and are used to build the output filename automatically.

| Field | Notes |
|-------|-------|
| **Sermon Title** | e.g. *The Saving Power of Jesus* |
| **Bible Reading** | e.g. *Romans 1:16–17* |
| **Preacher** | Speaker name |
| **Series** | Sermon series title — remembered between sessions |
| **Date** | Date picker — defaults to today. The year is embedded in the ID3 tag; the full date prefixes the filename. |
| **Artwork** | Drag an image onto the artwork square, or click it to choose a file. Remembered between sessions. |

**Output filename** is built automatically from the tags:
```
YYYY-MM-DD Sermon Title, Bible Reading | Preacher | Series.mp3
```
If no tags are filled in, the file is named `<original>_dechaff.mp3`.

---

## Chapter markers (right panel → Chapters tab)

Chapters appear as purple lines on the waveform and as a navigable chapter list in podcast apps.

**Adding chapters**
- Click **+** in the Chapters tab. The first chapter is pre-labelled *Bible Reading* and the second *Sermon*, using the text from the Info fields if filled in.
- Chapter times default to 1-minute intervals — adjust them after adding.

**Editing chapters**
- **Drag a purple marker** on the waveform to reposition it. The playhead follows and the time updates in the table.
- **Click the time field** in the table and type a time directly (format: `m:ss` or `h:mm:ss`).
- Click the title field to rename a chapter.
- Click the **×** button to delete a chapter.

Chapters are stored in *output time* — that is, relative to the trim-in point. A chapter at `0:00` plays at the very start of the trimmed recording, regardless of where the trim-in handle sits on the original file.

---

## Output file

The processed file is saved in the **same folder as the original**. When processing finishes, a green bar shows the filename with a **Reveal in Finder** button.

To process another file, simply drop it onto the drop zone or the waveform area — the window resets automatically.

---

## Tips

- **Long recordings**: Zoom into the waveform at the start and end to place trim handles precisely rather than guessing.
- **Shorten silences**: Start with 1.0 s and listen to the result — too short can make the delivery feel rushed.
- **Series field**: This is the only field that persists between sessions, since series titles typically span many recordings. Fill in the others fresh each week.
- **Chapter timing**: If you're not sure where a section starts, play the recording and press **Set In** / **Set Out** to mark points on the fly, then convert those to chapter positions by dragging the markers.
