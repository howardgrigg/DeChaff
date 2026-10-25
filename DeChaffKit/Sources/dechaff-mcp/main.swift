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
DeChaff turns a church service recording into a podcast episode: trimmed to the sermon, \
cleaned up (voice isolation, compression, levelling, −16 LUFS), encoded to MP3 and tagged with chapters.

Typical flow: list_channel_videos → download_audio → analyze_audio + transcribe → read the transcript \
(get_transcript / search_transcript) to find where the sermon starts and ends and where chapters go → \
refine_cuts to check the cuts → confirm with the user → process_sermon → read_tags to verify.

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
