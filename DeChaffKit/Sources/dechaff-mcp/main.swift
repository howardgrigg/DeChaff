import Foundation
import MCPServer
import DeChaffCore

let version = "1.0.0"

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--version") {
    print("dechaff-mcp \(version)")
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    dechaff-mcp \(version) — a Model Context Protocol server for DeChaff.

    Speaks MCP over stdin/stdout; launch it from an MCP client such as Claude Desktop or
    Claude Code rather than by hand. It uses DeChaff.app's settings, its bundled LAME
    encoder and the yt-dlp copy the app installs.

    Environment:
      DECHAFF_LAME   path to a LAME binary (default: DeChaff.app's bundled copy, then Homebrew)
    """)
    exit(0)
}

let instructions = """
DeChaff turns a church service recording into a podcast episode: trimmed to the sermon, cleaned up \
(voice isolation, compression, levelling, −16 LUFS), encoded to MP3 and tagged with chapters.

In the app this is a five-step wizard the user works through from start to end — Load → Trim → \
Info → Chapters → Output — and each step builds on the one before. Follow the same steps, in order, \
and report progress in those terms ("Trim is done — next, Info") so it matches what the user knows:

1. Load — get the recording. list_channel_videos finds this week's video; download_audio fetches it \
(or use a local audio file). Note the title fields it parses; they seed the Info step.
2. Trim — choose where the sermon starts and ends. Run transcribe (and analyze_audio — its music \
segments show the worship around the sermon), find the boundaries with search_transcript and \
get_transcript, then check them with refine_cuts. Usually: start after the Bible reading, end on \
the closing prayer's "Amen".
3. Info — the tags: title, Bible reading, preacher, series, date, artwork. Start from the parsed video \
title and get_settings (last preacher/series); fill gaps from the transcript. The app keeps the last \
episode's artwork and the user only changes it when a new series starts: if the series differs from \
last_series, look at the saved artwork with get_artwork and ask the user for the new series' artwork \
(tags.artwork_path). A processed episode's preacher, series and artwork become the new defaults.
4. Chapters — 3–6 markers at clear turns in the sermon, the first at the trim start (e.g. \
"Introduction"), given as word indexes and checked with refine_cuts.
5. Output — confirm the plan with the user (trim, tags, chapters, any non-default options), then run \
process_sermon and verify the finished MP3 with read_tags. A short episode description written \
from the transcript is a welcome finish.

Only Output writes a file; steps 1–4 just gather decisions, so it's fine to revisit an earlier step \
before processing. Don't run process_sermon until the user has confirmed.

All trim and chapter points are on the source recording's timeline. Prefer transcript word indexes \
over times: the server refines every cut into the surrounding silence so no word is clipped. \
Long-running tools return a job_id if they run past wait_seconds; call get_job to keep waiting.
"""

let tools = DeChaffTools()
let server = MCPServer(
    name: "dechaff", version: version, instructions: instructions,
    tools: tools.all,
    prompts: [prepareSermonPrompt],
    resources: [
        MCPResource(uri: "dechaff://settings", name: "DeChaff settings",
                    description: "The DeChaff app's saved settings and tool locations.") {
            AppSettings().json.prettyPrinted()
        },
    ]
)
await server.run()
