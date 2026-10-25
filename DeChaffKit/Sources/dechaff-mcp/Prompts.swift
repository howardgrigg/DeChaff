import MCPServer

/// The whole "this week's sermon" workflow, as a prompt clients can offer as a one-click action.
let prepareSermonPrompt = MCPPrompt(
    name: "prepare_sermon",
    title: "Prepare this week's sermon",
    description: "Find the sermon in a service recording, trim it, add chapters and produce the podcast episode.",
    arguments: [
        .init(name: "source", description: "A video URL or audio file path. Defaults to the newest video on the channel."),
        .init(name: "notes", description: "Anything else to know — preacher, series, where the sermon starts…"),
    ]
) { args in
    let source = args["source"].flatMap { $0.isEmpty ? nil : $0 }
    let notes = args["notes"].flatMap { $0.isEmpty ? nil : $0 }
    return """
    Prepare this week's sermon podcast episode with the DeChaff tools, working through the app's five \
    steps in order — Load → Trim → Info → Chapters → Output. Tell me briefly as each step is done.

    1. Load: \(source.map { "use \($0) — download it with download_audio if it's a URL." }
                ?? "call list_channel_videos, pick the newest service or sermon video, and download it with download_audio.")
       Keep the parsed title fields for Info.
    2. Trim: run transcribe and analyze_audio on the file (side by side; poll with get_job if needed). Use \
    search_transcript for phrases that open and close the sermon (the reading being announced, "let's pray", \
    "amen") and get_transcript windows around them to choose the first and last words of the sermon; the music \
    segments show the worship either side. Check both with refine_cuts — if a cut is "forced", look at the words \
    nearby with get_transcript format "words" and pick a sentence boundary instead.
    3. Info: settle title, Bible reading, preacher, series and date from the parsed title, get_settings and the \
    transcript. Artwork defaults to the app's.
    4. Chapters: choose 3–6 chapters at clear structural turns, the first at the trim start (e.g. "Introduction"), \
    and check them with refine_cuts.
    5. Output: show me the plan — trim start and end (times and the words there), the tags, and chapter titles \
    and times — and wait for my go-ahead or corrections. Then run process_sermon, check the result with \
    read_tags, and finish with the output path, a 2–3 sentence episode description and the key themes, written \
    from the transcript.
    \(notes.map { "\nNotes from me: \($0)" } ?? "")
    """
}
