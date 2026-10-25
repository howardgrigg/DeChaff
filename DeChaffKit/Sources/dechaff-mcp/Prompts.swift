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
    Prepare this week's sermon podcast episode with the DeChaff tools.

    1. Source: \(source.map { "use \($0)." } ?? "call list_channel_videos and pick the newest service or sermon video.")
       Download it with download_audio if it's a URL. Note the parsed title fields.
    2. Call analyze_audio and transcribe on the file (they can run side by side; poll with get_job if needed).
    3. Find the sermon. Use search_transcript for phrases that typically open and close it (the reading being \
    announced, "let's pray", "amen") and get_transcript windows around those to decide:
       - trim_start: the first word of the sermon proper (usually after the Bible reading),
       - trim_end: the last word (usually the "Amen" of the closing prayer),
       - 3–6 chapters at clear structural turns, the first at trim_start (e.g. "Introduction").
       analyze_audio's music segments help locate the worship before and after.
    4. Call refine_cuts with those word indexes. If any cut comes back "forced", look at the words around it \
    with get_transcript format "words" and pick a nearby sentence boundary instead.
    5. Show the user the plan: trim start/end (times and the words there), chapter titles and times, and tags \
    (title, reading, preacher, series, date). Wait for their go-ahead or corrections.
    6. Run process_sermon with the confirmed points and tags, then read_tags on the output to check it.
    7. Finish with the output path and a short episode description (2–3 sentences) and key themes, written from \
    the transcript.
    \(notes.map { "\nNotes from the user: \($0)" } ?? "")
    """
}
