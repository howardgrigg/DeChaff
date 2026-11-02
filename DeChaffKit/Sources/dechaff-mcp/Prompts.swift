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
    let settings = AppSettings()
    return """
    Prepare this week's sermon podcast episode with the DeChaff tools, working through the app's five \
    steps in order — Load → Trim → Info → Chapters → Output. Tell me briefly as each step is done.

    1. Load: \(source.map { "use \($0) — download it with download_audio if it's a URL." }
                ?? "call list_channel_videos, pick the newest service or sermon video, and download it with download_audio by video_id.")
       Keep the parsed title fields for Info, and double-check any it lists under "check".
    2. Trim: run transcribe and analyze_audio (side by side; poll with get_job if needed), then suggest_trim. \
    Check each suggested point that isn't high confidence with a get_transcript window, then check the cuts with \
    refine_cuts — if one is "forced", look at the words nearby with get_transcript format "words" and pick a \
    sentence boundary instead.
    3. Info: settle title, Bible reading, preacher, series and date from the parsed title, get_settings and the \
    transcript. For artwork, follow the house style below.
    4. Chapters: follow the house style below (suggest_trim places the reading and sermon chapters), and check \
    them with refine_cuts.
    If I want to adjust anything myself, open it in DeChaff with open_in_dechaff, and when I'm done read my \
    changes back with get_dechaff_plan and process with from_plan: true.
    5. Output: show me the plan — trim start and end (times and the words there), the tags, and chapter titles \
    and times — and wait for my go-ahead or corrections. Then run process_sermon, check the result with \
    read_tags, and finish with the output path. If process_sermon returns website_copy, follow its prompt with \
    the episode's transcript (get_transcript format "text") and give me the result as its own block; otherwise \
    write a 2–3 sentence episode description and the key themes from the transcript.

    House style:
    \(settings.houseStyle.guidance)
    \(notes.map { "\nNotes from me: \($0)" } ?? "")
    """ + churchInstructions(settings.assistantInstructions)
}
