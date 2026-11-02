import Foundation
import AVFoundation
import MCPServer
import DeChaffCore

/// The DeChaff tools: find and fetch a sermon, survey and transcribe it, choose clean
/// cut points, and produce the tagged, chaptered MP3.
struct DeChaffTools: Sendable {
    let jobs = JobStore()
    let transcripts = TranscriptStore()
    let current = CurrentEpisode()
    let analyses = AnalysisStore()

    var all: [MCPTool] {
        [getSettings, getArtwork, listChannelVideos, downloadAudio, analyzeAudio, transcribe, getTranscript,
         searchTranscript, suggestTrim, refineCuts, previewCut, openInDeChaff, getDeChaffPlan, processSermon, readTags,
         writeTags, listEpisodes, revealInFinder, updateSettings, updateYtDlp, getJob, cancelJob]
    }

    private static let readOnly: JSONValue = ["readOnlyHint": true, "openWorldHint": false]

    // MARK: - Settings

    var getSettings: MCPTool {
        MCPTool(name: "get_settings", title: "Get DeChaff settings",
                description: "Returns the DeChaff app's saved settings (YouTube channel, title and filename templates, "
                    + "compressor settings, last preacher/series) and where LAME, yt-dlp and ffmpeg were found.",
                inputSchema: Schema.object([:]), annotations: Self.readOnly) { _, _ in
            .json(AppSettings().json)
        }
    }

    var getArtwork: MCPTool {
        MCPTool(name: "get_artwork", title: "Show cover art",
                description: "Shows cover art as an image you can look at. With no path: the artwork saved in the "
                    + "DeChaff app, which it keeps using until it's changed for a new series — so check it matches "
                    + "the sermon's series (get_settings has last_series) and ask the user for new artwork if not. "
                    + "With path: an image file, or the artwork embedded in an MP3.",
                inputSchema: Schema.object([
                    "path": Schema.string("An image file or MP3. Omit for the app's saved artwork."),
                ]),
                annotations: Self.readOnly) { raw, _ in
            let settings = AppSettings()
            var info: [String: JSONValue] = [:]
            let data: Data
            if let path = Args(raw).string("path") {
                let url = expandPath(path)
                guard let fileData = try? Data(contentsOf: url) else { throw ToolError("No file at \(url.path).") }
                if url.pathExtension.lowercased() == "mp3" {
                    guard let art = ID3Tag.read(fileData)?.artwork, !art.isEmpty else {
                        return ToolResult(text: "\(url.lastPathComponent) has no embedded artwork.")
                    }
                    data = art
                    info["source"] = .string("Artwork embedded in \(url.lastPathComponent)")
                } else {
                    data = fileData
                    info["source"] = .string(url.path)
                }
            } else {
                guard let saved = settings.artwork else {
                    return ToolResult(text: "No artwork is saved in DeChaff. Pass tags.artwork_path to process_sermon.")
                }
                data = saved
                info["source"] = "Saved in DeChaff (used for every episode until changed)"
                info["last_series"] = .string(settings.lastSeries)
            }
            guard let size = imageSize(data), let preview = jpegImage(data, maxPixel: 512, quality: 0.8) else {
                throw ToolError("That isn't an image DeChaff can read.")
            }
            info["width"] = .number(Double(size.width))
            info["height"] = .number(Double(size.height))
            if size.width < 1400 || size.width != size.height {
                info["warning"] = "Podcast directories want square artwork of at least 1400×1400 pixels."
            }
            return ToolResult(text: JSONValue.object(info).prettyPrinted(), structured: .object(info),
                              images: [.init(data: preview, mimeType: "image/jpeg")])
        }
    }

    // MARK: - YouTube

    var listChannelVideos: MCPTool {
        MCPTool(name: "list_channel_videos", title: "List recent channel videos",
                description: "Lists the latest videos on the church's YouTube channel (from DeChaff's settings, or the "
                    + "channel given), newest first, from livestreams or uploads as DeChaff's settings say. Each title gets a quick "
                    + "parse into sermon fields (each with a confidence — check anything not \"high\" against the raw "
                    + "title). download_audio extracts the fields more carefully. Pass a video_id to download_audio.",
                inputSchema: Schema.object([
                    "channel": Schema.string("Channel URL or @handle. Defaults to the channel in DeChaff's settings."),
                    "limit": Schema.integer("How many videos (default: DeChaff's setting, usually 10)."),
                    "tab": Schema.string("Which part of the channel: live (livestreams), videos (ordinary uploads) or "
                        + "auto — livestreams if the channel has any. Default: DeChaff's setting (get_settings video_listing).",
                        enum: ["auto", "live", "videos"]),
                ]),
                annotations: ["readOnlyHint": true, "openWorldHint": true]) { raw, _ in
            let args = Args(raw)
            let settings = AppSettings()
            guard let client = YtDlpClient.installed else { throw Self.ytDlpMissing }
            var channel = args.string("channel") ?? settings.channelURL
            guard !channel.isEmpty else {
                throw ToolError("No YouTube channel is set in DeChaff. Ask the user for their church's channel and save it "
                    + "with update_settings youtube_channel_url — or download a video by URL.")
            }
            if channel.hasPrefix("@") { channel = "https://www.youtube.com/\(channel)" }
            let listing: ChannelListing
            switch args.string("tab") {
            case "auto": listing = .livestreamsFirst
            case "live": listing = .livestreams
            case "videos": listing = .uploads
            default: listing = settings.channelListing
            }
            let limit = min(max(try args.int("limit") ?? settings.videoLimit, 1), 50)
            let videos = try await client.fetchVideoList(channelURL: channel, limit: limit, listing: listing)
            return .json([
                "channel": .string(channel),
                "videos": .array(videos.map { v in
                    var o: [String: JSONValue] = [
                        "video_id": .string(v.id), "url": .string("https://youtu.be/\(v.id)"), "title": .string(v.title),
                        "upload_date": JSONValue(parseYouTubeUploadDate(v.uploadDate).map(isoDate)),
                        "parsed": titleFieldsJSON(v.title, format: settings.titleFormat, onDevice: nil),
                        "downloaded": .bool(DownloadCache.file(forVideoID: v.id) != nil),
                    ]
                    if let d = v.durationSeconds { o["duration"] = .string(formatTime(Double(d))) }
                    return .object(o)
                }),
            ])
        }
    }

    var downloadAudio: MCPTool {
        MCPTool(name: "download_audio", title: "Download audio",
                description: "Downloads the audio of a YouTube video (or any yt-dlp-supported URL) and makes it the "
                    + "current episode, so later tools need no path. YouTube downloads are kept by video ID: asking "
                    + "again returns the saved copy at once. Also returns the title's sermon fields, each with a "
                    + "confidence (on-device Apple Intelligence checked against the title's layout and the church's "
                    + "past series and preachers). Takes a minute or two for a long livestream; returns a job_id to "
                    + "poll with get_job if it runs past wait_seconds.",
                inputSchema: Schema.object([
                    "url": Schema.string("Video URL, e.g. https://youtu.be/abc123."),
                    "video_id": Schema.string("A YouTube video ID from list_channel_videos, instead of url."),
                    "force": Schema.boolean("Download again even if this video is already saved."),
                    "wait_seconds": Schema.waitSeconds,
                ]),
                annotations: ["openWorldHint": true]) { raw, context in
            let args = Args(raw)
            guard let given = args.string("url") ?? args.string("video_id") else {
                throw ToolError("Give url or video_id.")
            }
            let videoID = youTubeVideoID(from: given)
            let url = given.contains("/") ? given : "https://youtu.be/\(videoID ?? given)"
            let titleFormat = AppSettings().titleFormat
            let current = self.current

            if let id = videoID, try args.bool("force") != true, let saved = DownloadCache.file(forVideoID: id) {
                current.set(saved)
                var o = downloadJSON(saved, videoID: id, info: DownloadInfo.load(id))
                o["cached"] = true
                if let info = DownloadInfo.load(id) {
                    o["parsed"] = titleFieldsJSON(info.title, format: titleFormat, onDevice: nil)
                }
                return .json(.object(o))
            }

            guard let client = YtDlpClient.installed else { throw Self.ytDlpMissing }
            let summary = "Download \(videoID ?? url)"
            let job = jobs.running(kind: "download", summary: summary)
                ?? jobs.start(kind: "download", summary: summary) { job in
                    async let info = try? client.fetchInfo(url: url)
                    let downloaded = try await client.downloadAudio(
                        url: url,
                        onStart: { process in job.onCancel { process.terminate() } },
                        onLine: { line in
                            if let p = YtDlpClient.parseProgress(line) {
                                job.update(progress: p * 0.95, message: "Downloading")
                            } else if ["[ExtractAudio]", "[Merger]", "[FixupM3u8]", "[ffmpeg]", "[VideoConvertor]"]
                                        .contains(where: line.hasPrefix) {
                                // After 100%, yt-dlp converts the download — minutes for a long livestream.
                                job.update(progress: 0.96, message: "Converting the download to audio (yt-dlp "
                                           + "post-processing; a long livestream takes a minute or two)")
                            }
                        })
                    let entry = await info
                    let id = entry?.id ?? videoID
                    var file = downloaded
                    if let id, isYouTubeVideoID(id) {
                        file = try DownloadCache.store(downloaded, videoID: id)
                        if let entry { DownloadInfo(title: entry.title, uploadDate: entry.uploadDate).save(id) }
                    }
                    current.set(file)
                    var o = downloadJSON(file, videoID: id, info: entry.map { DownloadInfo(title: $0.title, uploadDate: $0.uploadDate) })
                    if let entry {
                        o["parsed"] = titleFieldsJSON(entry.title, format: titleFormat,
                            onDevice: await extractSermonMetadataOnDevice(from: entry.title, titleFormat: titleFormat,
                                                                    dateOrder: AppSettings().titleDateOrder))
                    }
                    o["next_step"] = "Run transcribe and analyze_audio (no path needed — this is now the current episode), then suggest_trim."
                    return .object(o)
                }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    // MARK: - Analysis

    var analyzeAudio: MCPTool {
        MCPTool(name: "analyze_audio", title: "Analyse audio",
                description: "Surveys a recording: duration, integrated loudness (LUFS), music segments (worship, "
                    + "intros — usually what gets trimmed; merged, and only those of 10 s or more) and long silences. "
                    + "Times are on the source timeline. suggest_trim reuses the result.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "detect_music": Schema.boolean("Classify music segments (default true; adds ~10–20 s)."),
                    "min_silence_seconds": Schema.number("Only report silences at least this long (default 2)."),
                    "wait_seconds": Schema.waitSeconds,
                ]),
                annotations: Self.readOnly) { raw, context in
            let args = Args(raw)
            let url = try current.resolve(args)
            let detectMusic = try args.bool("detect_music") ?? true
            let minSilence = try args.double("min_silence_seconds") ?? 2
            let job = jobs.start(kind: "analyze", summary: "Analyse \(url.lastPathComponent)") { job in
                let analyzer = AudioAnalyzer()
                job.onCancel { analyzer.cancel() }
                let analysis = await runBlocking({
                    analyzer.analyze(url: url, detectMusic: detectMusic, minSilence: minSilence,
                                     progress: { job.update(progress: $0) }, log: { job.appendLog($0) })
                }, onCancel: { analyzer.cancel() })
                guard let a = analysis else {
                    throw ToolError(job.log.last ?? "Could not read \(url.lastPathComponent).")
                }
                analyses.set(a, for: url)
                let span = { (s: Double, e: Double) -> JSONValue in
                    ["start": .string(formatTime(s)), "end": .string(formatTime(e)),
                     "start_seconds": rounded(s), "end_seconds": rounded(e), "duration_seconds": rounded(e - s, 1)]
                }
                return [
                    "duration": .string(formatTime(a.duration)),
                    "duration_seconds": rounded(a.duration),
                    "sample_rate": .number(a.sampleRate),
                    "channels": .number(Double(a.channels)),
                    "integrated_lufs": a.integratedLUFS.map { rounded($0, 1) } ?? .null,
                    "music_segments": .array(a.musicSegments.map { span($0.startSeconds, $0.endSeconds) }),
                    "silences": .array(a.silences.prefix(200).map { span($0.startSeconds, $0.endSeconds) }),
                ]
            }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    // MARK: - Transcript

    var transcribe: MCPTool {
        MCPTool(name: "transcribe", title: "Transcribe",
                description: "Transcribes a recording on-device with word-level timings (Apple Silicon, macOS 26+). "
                    + "Results are cached, so later calls are instant. Read the transcript with get_transcript or "
                    + "search_transcript; their word indexes are what refine_cuts and process_sermon take. An hour of "
                    + "audio takes a few minutes — returns a job_id to poll with get_job if it runs past wait_seconds.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "force": Schema.boolean("Transcribe again even if a cached transcript exists."),
                    "wait_seconds": Schema.waitSeconds,
                ]),
                annotations: Self.readOnly) { raw, context in
            let args = Args(raw)
            let url = try current.resolve(args)
            if try args.bool("force") != true, let words = await transcripts.words(for: url) {
                return .json(transcriptSummary(words, cached: true))
            }
            let summary = "Transcribe \(url.lastPathComponent)"
            let store = transcripts
            let job = jobs.running(kind: "transcribe", summary: summary)
                ?? jobs.start(kind: "transcribe", summary: summary) { job in
                    let words = try await transcribeWords(url: url, onProgress: { job.update(progress: $0 * 0.99) })
                    guard !words.isEmpty else { throw ToolError("No speech was recognised in \(url.lastPathComponent).") }
                    await store.save(words, for: url)
                    return transcriptSummary(words, cached: false)
                }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    var getTranscript: MCPTool {
        MCPTool(name: "get_transcript", title: "Read transcript",
                description: "Returns the transcript (run transcribe first) as lines of \"[time] #word_index text\", "
                    + "one sentence per line, on the source timeline. Use start/end to read a window; long ranges are "
                    + "truncated with a note saying where to continue. format \"words\" lists every word with its "
                    + "start–end time — use it on a short window to inspect a boundary. format \"text\" is plain "
                    + "paragraphs with no times or indexes — about half the size; use it to read the sermon for "
                    + "website copy or a description.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "start": ["type": ["number", "string"], "description": "Window start (seconds or \"mm:ss\")."],
                    "end": ["type": ["number", "string"], "description": "Window end (seconds or \"mm:ss\")."],
                    "format": Schema.string("\"sentences\" (default), \"words\" or \"text\".",
                                            enum: ["sentences", "words", "text"]),
                    "max_chars": Schema.integer("Truncate output after this many characters (default 40000)."),
                ]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let url = try current.resolve(args)
            let words = try await requireTranscript(url)
            let start = try args.double("start") ?? 0
            let end = try args.double("end") ?? .infinity
            let maxChars = max(try args.int("max_chars") ?? 40_000, 500)
            let indices = words.indices.filter { words[$0].endTime > start && words[$0].startTime < end }
            guard let first = indices.first, let last = indices.last else {
                return ToolResult(text: "No words between \(formatTime(start)) and \(end.isFinite ? formatTime(end) : "the end").")
            }

            var lines: [String] = []
            var chars = 0
            var truncatedAt: Double?
            if args.string("format") == "text" {
                // Paragraphs break at pauses of 2 s or more; no times or indexes.
                var paragraphStart = first
                for i in first...(last + 1) {
                    let ends = i > last || (i > first && words[i].startTime - words[i - 1].endTime >= 2)
                    guard ends, i > paragraphStart else { continue }
                    let line = words[paragraphStart..<i].map(\.text).joined(separator: " ")
                    if chars + line.count > maxChars { truncatedAt = words[paragraphStart].startTime; break }
                    lines.append(line); chars += line.count + 2
                    paragraphStart = i
                }
                lines = [lines.joined(separator: "\n\n")]
            } else if args.string("format") == "words" {
                for i in first...last {
                    let w = words[i]
                    let line = "#\(i) \(formatTime(w.startTime))–\(formatTime(w.endTime)) \(w.text)"
                    if chars + line.count > maxChars { truncatedAt = w.startTime; break }
                    lines.append(line); chars += line.count + 1
                }
            } else {
                for sentence in sentences(words, first...last) {
                    let w = words[sentence.lowerBound]
                    let text = sentence.map { words[$0].text }.joined(separator: " ")
                    let line = "[\(formatTime(w.startTime))] #\(sentence.lowerBound) \(text)"
                    if chars + line.count > maxChars { truncatedAt = w.startTime; break }
                    lines.append(line); chars += line.count + 1
                }
            }
            if let t = truncatedAt {
                lines.append("… truncated. Continue with start = \(Int(t.rounded(.down))).")
            }
            return ToolResult(text: lines.joined(separator: "\n"))
        }
    }

    var searchTranscript: MCPTool {
        MCPTool(name: "search_transcript", title: "Search transcript",
                description: "Finds a phrase in the transcript (case and punctuation ignored), e.g. \"let's pray\" or "
                    + "\"our reading today\". Returns each match's time and word_index with surrounding context.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "query": Schema.string("Words to find."),
                    "max_results": Schema.integer("Default 20."),
                ], required: ["query"]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let url = try current.resolve(args)
            let words = try await requireTranscript(url)
            let query = try args.requiredString("query").split(whereSeparator: \.isWhitespace).map { normalizeWord(String($0)) }
                .filter { !$0.isEmpty }
            guard !query.isEmpty else { throw ToolError("query has no words.") }
            let normalized = words.map { normalizeWord($0.text) }
            let maxResults = max(try args.int("max_results") ?? 20, 1)

            var matches: [JSONValue] = []
            var i = 0
            while i + query.count <= words.count && matches.count < maxResults {
                if Array(normalized[i..<i + query.count]) == query {
                    let lo = max(0, i - 10), hi = min(words.count - 1, i + query.count + 10)
                    matches.append([
                        "word_index": .number(Double(i)),
                        "time": .string(formatTime(words[i].startTime)),
                        "time_seconds": rounded(words[i].startTime),
                        "context": .string(words[lo...hi].map(\.text).joined(separator: " ")),
                    ])
                    i += query.count
                } else {
                    i += 1
                }
            }
            return .json(["query": .string(query.joined(separator: " ")), "matches": .array(matches)])
        }
    }

    // MARK: - Planning the trim

    var suggestTrim: MCPTool {
        MCPTool(name: "suggest_trim", title: "Suggest trim and chapters",
                description: "Proposes where the episode starts and ends, and where the Bible reading and sermon begin, "
                    + "following the church's house style (get_settings → house_style). It looks for spoken cues — "
                    + "the reader being handed over to (\"…come up and read\"), the reading's end (\"This is the word "
                    + "of the Lord\"), the preacher picking up (\"Thanks so much\"), prayers and their \"Amen\", the "
                    + "closing song being introduced (\"invite you to stand and sing\") — and at music from "
                    + "analyze_audio. Each point comes with a confidence and the words around it; read a get_transcript "
                    + "window around any that isn't high, then check the cuts with refine_cuts. Needs a transcript; runs "
                    + "music detection if analyze_audio hasn't.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "detect_music": Schema.boolean("Use music segments too (default true; analyses the audio if needed)."),
                    "wait_seconds": Schema.waitSeconds,
                ]),
                annotations: Self.readOnly) { raw, context in
            let args = Args(raw)
            let url = try current.resolve(args)
            let words = try await requireTranscript(url)
            let style = AppSettings().houseStyle
            if try args.bool("detect_music") == false {
                return .json(trimSuggestionJSON(words, analysis: nil, style: style))
            }
            if let analysis = analyses.get(url) {
                return .json(trimSuggestionJSON(words, analysis: analysis, style: style))
            }
            let analyses = self.analyses
            let job = jobs.start(kind: "suggest", summary: "Suggest a trim for \(url.lastPathComponent)") { job in
                let analyzer = AudioAnalyzer()
                job.onCancel { analyzer.cancel() }
                job.update(progress: 0, message: "Finding music to place the trim")
                let analysis = await runBlocking({
                    analyzer.analyze(url: url, progress: { job.update(progress: $0) }, log: { job.appendLog($0) })
                }, onCancel: { analyzer.cancel() })
                if let analysis { analyses.set(analysis, for: url) }
                return trimSuggestionJSON(words, analysis: analysis, style: style)
            }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    // MARK: - Cut points

    var refineCuts: MCPTool {
        MCPTool(name: "refine_cuts", title: "Refine cut points",
                description: "Turns rough trim and chapter points into clean cuts that never clip a word. Transcript "
                    + "word timings are only approximate — recognisers start words late and end them early — so each "
                    + "point is moved into the silence around the word using the audio itself: a start cut lands "
                    + "~150 ms before speech begins, an end cut ~300 ms after the last word's sound (trailing "
                    + "consonants, decay) has died away. Each result has a quality: clean, tight (short gap — placed "
                    + "mid-gap) or forced (words run together — listen to it). Use word indexes where possible; times "
                    + "work too (refined from the audio alone if there is no transcript). process_sermon applies the "
                    + "same refinement automatically; use this tool to preview and check the cuts first.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "trim_start": Schema.cutPoint("First word to keep."),
                    "trim_end": Schema.cutPoint("Last word to keep."),
                    "chapters": Schema.array(Schema.object([
                        "at": Schema.cutPoint("First word of the chapter."),
                        "title": Schema.string("Chapter title."),
                    ], required: ["at", "title"]), "Chapter starts to snap to the speech that begins them."),
                ]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let url = try current.resolve(args)
            let words = await transcripts.words(for: url) ?? []
            let refiner = CutPointRefiner()
            var o: [String: JSONValue] = ["transcript_available": .bool(!words.isEmpty)]
            var warnings: [JSONValue] = []

            var trimIn = 0.0
            if let spec = try CutPointSpec(args["trim_start"], name: "trim_start") {
                let r = try refiner.refine(edge: .start, spec, words: words, audioURL: url)
                trimIn = r.time
                o["trim_start"] = refinementJSON(r)
                if r.quality != .clean { warnings.append(.string("trim_start: " + r.notes.joined(separator: " "))) }
            }
            if let spec = try CutPointSpec(args["trim_end"], name: "trim_end") {
                let r = try refiner.refine(edge: .end, spec, words: words, audioURL: url)
                o["trim_end"] = refinementJSON(r)
                if r.quality != .clean { warnings.append(.string("trim_end: " + r.notes.joined(separator: " "))) }
            }
            if let chapters = try args.array("chapters") {
                o["chapters"] = .array(try chapters.enumerated().map { i, c in
                    let ch = Args(c)
                    guard let spec = try CutPointSpec(ch["at"], name: "chapters[\(i)].at") else {
                        throw ToolError("chapters[\(i)] needs \"at\".")
                    }
                    let r = try refiner.refine(edge: .start, spec, words: words, audioURL: url)
                    var j = refinementJSON(r).objectValue ?? [:]
                    j["title"] = .string(ch.string("title") ?? "Chapter \(i + 1)")
                    j["episode_time"] = timeJSON(max(0, r.time - trimIn))
                    if r.quality == .forced { warnings.append(.string("chapter \(i + 1): " + r.notes.joined(separator: " "))) }
                    return .object(j)
                })
            }
            if words.isEmpty {
                warnings.append("No transcript cached for this file, so cuts were refined from the audio alone. Run transcribe for word-accurate cuts.")
            }
            o["warnings"] = .array(warnings)
            return .json(.object(o))
        }
    }

    // MARK: - Processing

    var processSermon: MCPTool {
        MCPTool(name: "process_sermon", title: "Process sermon",
                description: "Produces the finished podcast episode: trims, then runs voice isolation, compression, "
                    + "levelling, loudness normalisation and silence shortening, encodes MP3 and writes ID3 tags and "
                    + "chapters. Trim and chapter points are on the source timeline and are refined into silence "
                    + "first (see refine_cuts) unless refine is false. Chapter times are shifted for the trim and for "
                    + "shortened silences automatically. Saves next to the source file (or ~/Downloads for YouTube "
                    + "downloads) named by DeChaff's filename template. Confirm trim points and tags with the user "
                    + "before running. Takes several minutes for an hour of audio — returns a job_id to poll with "
                    + "get_job if it runs past wait_seconds.",
                inputSchema: Schema.object(Self.episodeSchema.merging([
                    "from_plan": Schema.boolean("Process the episode exactly as it is in the DeChaff app (see "
                        + "get_dechaff_plan) — its recording, trim, cut sections, chapters, tags and artwork, with no "
                        + "refinement, since the user placed those points by hand. Episode arguments are then ignored."),
                    "options": Schema.object([
                        "voice_isolation": Schema.boolean("Default true."),
                        "preserve_music": Schema.boolean("Skip voice isolation where music is detected (default false)."),
                        "compression": Schema.boolean("Default true."),
                        "leveler": Schema.boolean("Slow levelling between speakers (default true)."),
                        "normalization": Schema.boolean("Default true."),
                        "target_lufs": Schema.number("Default -16."),
                        "shorten_silences": Schema.boolean("Default true."),
                        "max_silence_seconds": Schema.number("Longest pause kept (default 1.0)."),
                        "mono": Schema.boolean("Default true."),
                        "format": Schema.string("Default mp3.", enum: ["mp3", "wav"]),
                        "mp3_bitrate": Schema.integer("kbps: 64 (default), 96, 128, 192 or 256."),
                    ]),
                    "output_path": Schema.string("Where to save. Defaults to DeChaff's filename template."),
                    "if_exists": Schema.string("When the output exists: keep_both (default), replace or error.",
                                               enum: ["keep_both", "replace", "error"]),
                    "wait_seconds": Schema.waitSeconds,
                ]) { a, _ in a }),
                annotations: ["destructiveHint": false, "idempotentHint": false, "openWorldHint": false]) { raw, context in
            let args = Args(raw)
            let settings = AppSettings()
            let episode = try await parseEpisode(args, settings: settings)
            let url = episode.url, trimIn = episode.trimIn, trimOut = episode.trimOut
            let chapters = episode.chapters, tags = episode.tags, warnings = episode.warnings
            let cutReports = episode.cutReports

            // Options
            let opt = args.object("options") ?? Args(.object([:]))
            let format: OutputFormat = opt.string("format")?.lowercased() == "wav" ? .wav : .mp3
            let options = ProcessingOptions(
                voiceIsolation: try opt.bool("voice_isolation") ?? true,
                compression: try opt.bool("compression") ?? true,
                normalization: try opt.bool("normalization") ?? true,
                monoOutput: try opt.bool("mono") ?? true,
                targetLUFS: try opt.double("target_lufs") ?? -16,
                outputFormat: format,
                mp3Bitrate: try opt.int("mp3_bitrate") ?? 64,
                shortenSilences: try opt.bool("shorten_silences") ?? true,
                maxSilenceDuration: try opt.double("max_silence_seconds") ?? 1.0,
                slowLeveler: try opt.bool("leveler") ?? true,
                trimInSeconds: trimIn,
                trimOutSeconds: trimOut,
                excludedRanges: episode.excluded,
                skipIsolationOnMusic: try opt.bool("preserve_music") ?? false,
                compressorThreshold: Float(settings.compressorThreshold),
                compressorHeadRoom: Float(settings.compressorHeadRoom),
                compressorAttack: Float(settings.compressorAttack),
                compressorRelease: Float(settings.compressorRelease),
                compressorMakeupGain: Float(settings.compressorMakeupGain)
            )
            guard [64, 96, 128, 192, 256].contains(options.mp3Bitrate) else {
                throw ToolError("mp3_bitrate must be 64, 96, 128, 192 or 256.")
            }
            let lame = settings.lamePath
            if format == .mp3 && lame == nil {
                throw ToolError("LAME encoder not found. Install DeChaff in /Applications, set DECHAFF_LAME, or `brew install lame`.")
            }

            // Output
            var outputPath: String
            if let given = args.string("output_path") {
                outputPath = expandPath(given).path
            } else {
                let base = FilenameTemplate.resolve(settings.filenameTemplate, values: tags.templateValues)
                    ?? "\(url.deletingPathExtension().lastPathComponent)_dechaff"
                outputPath = defaultOutputDirectory(for: url).appendingPathComponent(base).path
            }
            if !outputPath.lowercased().hasSuffix(".\(format.fileExtension)") { outputPath += ".\(format.fileExtension)" }
            if outputPath == url.path {
                outputPath = uniqueOutputPath(for: outputPath)  // never write over the source
            } else if FileManager.default.fileExists(atPath: outputPath) {
                switch args.string("if_exists") ?? "keep_both" {
                case "replace": break
                case "error": throw ToolError("\(outputPath) already exists.")
                default: outputPath = uniqueOutputPath(for: outputPath)
                }
            }

            let request = EpisodeRequest(inputURL: url, outputURL: URL(fileURLWithPath: outputPath),
                                         options: options, metadata: tags.id3, chapters: chapters)
            let finalTags = tags, finalWarnings = warnings
            let trimReport: JSONValue = [
                "start": timeJSON(trimIn), "end": timeJSON(trimOut), "kept": .string(formatTime(keptDuration(keptRanges(trimIn: trimIn, trimOut: trimOut,
                                                                  excluding: episode.excluded)))),
                "refinements": .object(cutReports),
            ]
            let job = jobs.start(kind: "process", summary: "Process \(url.lastPathComponent)") { job in
                let processor = EpisodeProcessor(lamePath: lame)
                job.onCancel { processor.cancel() }
                let outcome = await runBlocking({
                    processor.run(request, progress: { job.update(progress: $0) }, log: { job.appendLog($0) })
                }, onCancel: { processor.cancel() })
                switch outcome {
                case .cancelled:
                    throw CancellationError()
                case .failed:
                    let failure = job.log.last { $0.hasPrefix("❌") } ?? job.log.last ?? "unknown error"
                    throw ToolError("Processing failed: \(failure)")
                case .finished(let result):
                    EpisodePlanFile.markProcessed(source: request.inputURL, output: result.outputURL)
                    // Like the app: the next episode starts from this one's preacher, series and artwork.
                    // Test renders (WAV, or no title) leave the saved defaults alone.
                    let remember = format == .mp3 && !finalTags.title.isEmpty
                    if remember {
                        AppSettings().rememberLastUsed(preacher: finalTags.preacher, series: finalTags.series,
                                                       artwork: finalTags.artwork)
                        EpisodeHistory.record(EpisodeRecord(
                            outputPath: result.outputURL.path, sourcePath: request.inputURL.path,
                            videoID: EpisodeHistory.videoID(fromSourcePath: request.inputURL.path),
                            title: finalTags.title, reading: finalTags.reading, preacher: finalTags.preacher,
                            series: finalTags.series, date: finalTags.date,
                            trimIn: options.trimInSeconds, trimOut: options.trimOutSeconds,
                            chapters: result.chapters.map { .init(title: $0.title, time: $0.timeSeconds) },
                            processedBy: "assistant"))
                    }
                    let size = (try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber)?
                        .doubleValue ?? 0
                    let removed = result.silenceSegments.reduce(0.0) {
                        $0 + max(0, ($1.endSeconds - $1.startSeconds) - $1.keptSeconds)
                    }
                    // Self-check: the output should be the kept audio minus removed silence.
                    // A shortfall means a pass dropped audio (as the slow leveler once did).
                    var outputWarnings = finalWarnings
                    let outputDuration = audioDuration(result.outputURL)
                    if let outputDuration {
                        let expected = keptDuration(keptRanges(trimIn: options.trimInSeconds, trimOut: options.trimOutSeconds,
                                                               excluding: options.excludedRanges)) - removed
                        if abs(outputDuration - expected) > 0.25 {
                            outputWarnings.append(.string(String(format:
                                "Output is %.2f s but should be %.2f s (kept audio minus removed silence) — audio may be missing; check the end.",
                                outputDuration, expected)))
                        }
                    }
                    var o: [String: JSONValue] = [
                        "output_path": .string(result.outputURL.path),
                        "size_mb": rounded(size / 1_048_576, 1),
                        "duration": JSONValue(outputDuration.map(formatTime)),
                        "trim": trimReport,
                        "silence_removed_seconds": rounded(removed, 1),
                        "chapters": .array(result.chapters.map {
                            ["title": .string($0.title), "time": .string(formatTime($0.timeSeconds))]
                        }),
                        "tags": [
                            "title": .string(finalTags.id3.title), "artist": .string(finalTags.preacher),
                            "album": .string(finalTags.series), "year": .string(finalTags.year),
                            "artwork": .bool(finalTags.artwork != nil),
                        ],
                        "warnings": .array(outputWarnings),
                        "remembered": remember
                            ? "Preacher, series and artwork are saved as DeChaff's defaults for the next episode."
                            : "Test render (WAV or no title) — DeChaff's saved defaults were left unchanged.",
                        "log": .array(job.log.suffix(15).map { .string($0) }),
                    ]
                    if let template = settings.aiAssistantPrompt {
                        o["website_copy"] = websiteCopyJSON(template: template, tags: finalTags,
                                                            trimIn: options.trimInSeconds, trimOut: options.trimOutSeconds,
                                                            outputSeconds: outputDuration)
                    }
                    return .object(o)
                }
            }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    // MARK: - Tags



    // MARK: - Episodes already made

    var listEpisodes: MCPTool {
        MCPTool(name: "list_episodes", title: "List past episodes",
                description: "Lists recent finished episodes, newest first, with title, reading, preacher, series, "
                    + "chapters and trim. Episodes processed since DeChaff started keeping a history (in the app or here) "
                    + "are found even after the MP3 is moved (moved files are tracked down by name); older ones are found by "
                    + "scanning a folder and its subfolders. Use it to match last week: the series' spelling, the "
                    + "chapter style, and whether the series (and so the artwork) has changed.",
                inputSchema: Schema.object([
                    "folder": Schema.string("Folder to scan for older episodes, subfolders included (default ~/Downloads)."),
                    "limit": Schema.integer("How many episodes (default 8)."),
                ]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let folder = expandPath(args.string("folder") ?? "~/Downloads")
            let limit = min(max(try args.int("limit") ?? 8, 1), 50)
            let saved = AppSettings().artwork
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            func artworkNote(_ path: String?) -> JSONValue {
                guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                      let tag = ID3Tag.read(data) else { return .null }
                return tag.artwork == nil ? "none"
                    : .string(tag.artwork == saved ? "same as DeChaff's saved artwork" : "different from the saved artwork")
            }

            var episodes: [(date: Date, json: JSONValue)] = []
            var listed = Set<String>()
            for record in EpisodeHistory.load().prefix(limit) {
                let found = locateEpisode(record.outputPath, near: folder)
                var o: [String: JSONValue] = [
                    "path": JSONValue(found),
                    "processed": .string(ISO8601DateFormatter().string(from: record.processedAt)),
                    "processed_by": .string(record.processedBy),
                    "title": .string(record.title), "reading": .string(record.reading),
                    "preacher": .string(record.preacher), "series": .string(record.series),
                    "date": .string(dateFormatter.string(from: record.date)),
                    "trim": ["start": .string(formatTime(record.trimIn)), "end": .string(formatTime(record.trimOut))],
                    "chapters": .array(record.chapters.map { ["title": .string($0.title), "start": .string(formatTime($0.time))] }),
                    "artwork": artworkNote(found),
                ]
                if let id = record.videoID { o["video_id"] = .string(id) }
                if found == nil { o["missing"] = .string("Not found — it was at \(record.outputPath)") }
                else if found != record.outputPath { o["moved_from"] = .string(record.outputPath) }
                listed.insert(record.outputPath); if let found { listed.insert(found) }
                episodes.append((record.processedAt, .object(o)))
            }

            // Older episodes from before the history: tagged MP3s in the folder and its subfolders.
            for (url, modified) in mp3Files(under: folder, maxDepth: 3) where !listed.contains(url.path) {
                guard episodes.count < limit * 2,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let tag = ID3Tag.read(data), let title = tag.text["TIT2"], !title.isEmpty else { continue }
                episodes.append((modified, [
                    "path": .string(url.path),
                    "modified": .string(ISO8601DateFormatter().string(from: modified)),
                    "title": .string(title),
                    "preacher": JSONValue(tag.text["TPE1"]),
                    "series": JSONValue(tag.text["TALB"]),
                    "year": JSONValue(tag.text["TYER"] ?? tag.text["TDRC"]),
                    "chapters": .array(tag.chapters.map {
                        ["title": .string($0.title), "start": .string(formatTime($0.startSeconds))]
                    }),
                    "artwork": tag.artwork == nil ? "none"
                        : .string(tag.artwork == saved ? "same as DeChaff's saved artwork" : "different from the saved artwork"),
                ]))
            }
            let newest = episodes.sorted { $0.date > $1.date }.prefix(limit).map(\.json)
            return .json(["scanned_folder": .string(folder.path), "episodes": .array(Array(newest))])
        }
    }

    // MARK: - Listening to a cut

    var previewCut: MCPTool {
        MCPTool(name: "preview_cut", title: "Preview a cut",
                description: "Renders a few seconds around a trim or chapter point, processed as it will sound in the "
                    + "episode (voice isolation, compression, loudness), and plays it in the user's default audio app "
                    + "so they can check it by ear — e.g. that the closing \"Amen\" isn't clipped. The point is refined "
                    + "into silence first, as process_sermon would, unless refine is false.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "video_id": Schema.videoID,
                    "at": Schema.cutPoint("The trim or chapter point to hear."),
                    "edge": Schema.string("start: hear the episode begin; end: hear it finish; chapter: hear "
                        + "either side of a chapter point (default chapter).", enum: ["start", "end", "chapter"]),
                    "seconds": Schema.number("Length of the preview (default 10)."),
                    "refine": Schema.boolean("Snap the point into silence first (default true)."),
                    "play": Schema.boolean("Open the preview in the default audio app (default true)."),
                ], required: ["at"]),
                annotations: ["destructiveHint": false, "openWorldHint": false]) { raw, _ in
            let args = Args(raw)
            let url = try current.resolve(args)
            let settings = AppSettings()
            let edge = args.string("edge") ?? "chapter"
            let seconds = min(max(try args.double("seconds") ?? 10, 2), 60)
            guard let spec = try CutPointSpec(args["at"], name: "at") else { throw ToolError("\"at\" is required.") }
            let words = await transcripts.words(for: url) ?? []
            let duration = audioDuration(url) ?? 0

            var t: Double
            var refinement: JSONValue = .null
            if try args.bool("refine") ?? true {
                let r = try CutPointRefiner().refine(edge: edge == "end" ? .end : .start, spec, words: words, audioURL: url)
                t = r.time
                refinement = refinementJSON(r)
            } else if case .time(let s) = spec {
                t = s
            } else if case .word(let i) = spec, words.indices.contains(i) {
                t = edge == "end" ? words[i].endTime : words[i].startTime
            } else {
                throw ToolError("at.word_index is out of range.")
            }
            t = max(0, min(t, duration))
            let window: (start: Double, end: Double)
            switch edge {
            case "start": window = (t, min(duration, t + seconds))
            case "end":   window = (max(0, t - seconds), t)
            default:      window = (max(0, t - seconds / 2), min(duration, t + seconds / 2))
            }
            guard window.end > window.start + 0.5 else { throw ToolError("That point is too close to the end of the recording.") }

            let output = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dechaff-preview-\(UUID().uuidString).wav")
            let options = ProcessingOptions(
                outputFormat: .wav, shortenSilences: true, trimInSeconds: window.start, trimOutSeconds: window.end,
                compressorThreshold: Float(settings.compressorThreshold), compressorHeadRoom: Float(settings.compressorHeadRoom),
                compressorAttack: Float(settings.compressorAttack), compressorRelease: Float(settings.compressorRelease),
                compressorMakeupGain: Float(settings.compressorMakeupGain))
            let request = EpisodeRequest(inputURL: url, outputURL: output, options: options,
                                         metadata: ID3Metadata(), chapters: [])
            let processor = EpisodeProcessor(lamePath: settings.lamePath)
            let outcome = await runBlocking({ processor.run(request, progress: { _ in }, log: { _ in }) },
                                            onCancel: { processor.cancel() })
            guard case .finished = outcome else { throw ToolError("Couldn't render the preview.") }

            let play = try args.bool("play") ?? true
            if play {
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = [output.path]
                try? opener.run()
            }
            return .json([
                "preview_path": .string(output.path),
                "point": timeJSON(t),
                "window": ["start": timeJSON(window.start), "end": timeJSON(window.end)],
                "refinement": refinement,
                "playing": .bool(play),
                "note": "Loudness is measured on the preview alone, so its level may differ slightly from the episode.",
            ])
        }
    }

    // MARK: - Maintenance and settings

    var updateYtDlp: MCPTool {
        MCPTool(name: "update_yt_dlp", title: "Update yt-dlp",
                description: "Installs the latest yt-dlp (DeChaff's YouTube downloader) if a newer one is out. "
                    + "YouTube changes often break downloads until yt-dlp catches up — try this when "
                    + "list_channel_videos or download_audio fail with a YouTube error.",
                inputSchema: Schema.object(["wait_seconds": Schema.waitSeconds]),
                annotations: ["destructiveHint": false, "idempotentHint": true, "openWorldHint": true]) { raw, context in
            let args = Args(raw)
            let job = jobs.running(kind: "update", summary: "Update yt-dlp")
                ?? jobs.start(kind: "update", summary: "Update yt-dlp") { _ in
                    switch try await YtDlpInstaller.update(defaults: AppSettings().defaults) {
                    case .upToDate(let v):
                        return ["status": "up_to_date", "version": .string(v)]
                    case .updated(let from, let to):
                        return ["status": "updated", "from": JSONValue(from), "to": .string(to)]
                    }
                }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 90, context: context))
        }
    }

    var updateSettings: MCPTool {
        MCPTool(name: "update_settings", title: "Change DeChaff settings",
                description: "Changes DeChaff's saved settings — the same ones as the app's Settings window. Only the "
                    + "fields given are changed. The house style fields (trim_start, trim_end, minimum_sermon_minutes, "
                    + "chapter_titles, artwork_per_series, spoken_cues) are the app's Settings → Service tab: use them "
                    + "when the user describes how their services run. Use artwork_path to save a new series' artwork as "
                    + "the default, and church_instructions for anything else about how they like episodes made. "
                    + "Confirm with the user first.",
                inputSchema: Schema.object([
                    "church_instructions": Schema.string("Replaces the church's instructions for the assistant."),
                    "trim_start": Schema.string("House style — where episodes start: sermon (after the Bible reading) "
                        + "or reading (include it).", enum: HouseStyle.TrimStart.allCases.map(\.rawValue)),
                    "trim_end": Schema.string("House style — where episodes end: amen (the closing prayer's Amen) or "
                        + "song_intro (just before the closing song is introduced).",
                        enum: HouseStyle.TrimEnd.allCases.map(\.rawValue)),
                    "minimum_sermon_minutes": Schema.integer("House style — the shortest sermon, in minutes; the end "
                        + "isn't looked for earlier than this after the sermon starts."),
                    "artwork_per_series": Schema.boolean("House style — true if the church uses new artwork for each "
                        + "series, false if every episode uses the same artwork."),
                    "spoken_cues": Schema.object(Dictionary(uniqueKeysWithValues: ServiceLandmark.Kind.spoken.map {
                        ($0.rawValue, Schema.string("\($0.label): \($0.usage) Comma-separated phrases; \"\" ignores this cue."))
                    })),
                    "title_date_order": Schema.string("How numeric dates in video titles are written.",
                        enum: TitleDateOrder.allCases.map(\.rawValue)),
                    "video_listing": Schema.string("Where the services are on the channel.",
                        enum: ChannelListing.allCases.map(\.rawValue)),
                    "chapter_titles": Schema.string("House style — chapter titles, one per line, in order, using "
                        + "{title} {reading} {series} {preacher}; a line {points} means one chapter per sermon point. "
                        + "e.g. \"Bible Reading: {reading}\\nSermon: {title}\". Empty string: the assistant chooses."),
                    "title_format": Schema.string("How the church's YouTube titles are laid out, e.g. "
                        + "\"{title}, {reading} | {preacher} | {series} | {date}\"."),
                    "filename_template": Schema.string("How finished episodes are named, using {date} {title} {reading} "
                        + "{preacher} {series}."),
                    "youtube_channel_url": Schema.string("The church's channel URL or @handle."),
                    "youtube_video_limit": Schema.integer("Videos to list: 5, 10 or 20."),
                    "default_preacher": Schema.string("Preacher the next episode starts with."),
                    "default_series": Schema.string("Series the next episode starts with."),
                    "artwork_path": Schema.string("Image to save as the default artwork (square, 1400 px or more)."),
                ]),
                annotations: ["destructiveHint": false, "idempotentHint": true, "openWorldHint": false]) { raw, _ in
            let args = Args(raw)
            let settings = AppSettings()
            let d = settings.defaults
            var changed: [JSONValue] = []

            if let v = args.string("title_format") {
                guard v.contains("{") else { throw ToolError("title_format needs placeholders such as {title}.") }
                d.set(v, forKey: "dechaff.titleFormat"); changed.append("title_format")
            }
            if let v = args.string("filename_template") {
                guard FilenameTemplate.resolve(v, values: ["title": "Test", "date": "2026-01-01"]) != nil else {
                    throw ToolError("filename_template doesn't produce a usable file name.")
                }
                d.set(v, forKey: "dechaff.filenameTemplate"); changed.append("filename_template")
            }
            if let v = args.string("youtube_channel_url") {
                d.set(v.trimmingCharacters(in: .whitespaces), forKey: "dechaff.youtube.channelURL")
                changed.append("youtube_channel_url")
            }
            if let v = try args.int("youtube_video_limit") {
                guard [5, 10, 20].contains(v) else { throw ToolError("youtube_video_limit must be 5, 10 or 20.") }
                d.set(v, forKey: "dechaff.youtube.videoLimit"); changed.append("youtube_video_limit")
            }
            if let v = args.string("church_instructions") {
                d.set(v, forKey: "dechaff.mcp.instructions"); changed.append("church_instructions")
            }
            var style = settings.houseStyle
            if let v = args.string("trim_start") {
                guard let value = HouseStyle.TrimStart(rawValue: v) else { throw ToolError("trim_start must be sermon or reading.") }
                style.trimStart = value; changed.append("trim_start")
            }
            if let v = args.string("trim_end") {
                guard let value = HouseStyle.TrimEnd(rawValue: v) else { throw ToolError("trim_end must be amen or song_intro.") }
                style.trimEnd = value; changed.append("trim_end")
            }
            if let v = args["chapter_titles"]?.stringValue {  // "" clears it
                style.chapterTitles = v; changed.append("chapter_titles")
            }
            if let v = try args.int("minimum_sermon_minutes") {
                guard (2...60).contains(v) else { throw ToolError("minimum_sermon_minutes must be 2–60.") }
                style.minimumSermonMinutes = v; changed.append("minimum_sermon_minutes")
            }
            if let v = try args.bool("artwork_per_series") {
                style.artworkPerSeries = v; changed.append("artwork_per_series")
            }
            for (key, value) in args.object("spoken_cues")?.raw.objectValue ?? [:] {
                guard let kind = ServiceLandmark.Kind(rawValue: key), ServiceLandmark.Kind.spoken.contains(kind),
                      let text = value.stringValue else {
                    throw ToolError("spoken_cues.\(key) isn't a cue — use one of "
                        + ServiceLandmark.Kind.spoken.map(\.rawValue).joined(separator: ", ") + ".")
                }
                style.cues[kind] = ServiceLandmark.Kind.phrases(from: text); changed.append(.string("spoken_cues.\(key)"))
            }
            if let v = args.string("title_date_order") {
                guard let order = TitleDateOrder(rawValue: v) else { throw ToolError("title_date_order must be day_first or month_first.") }
                d.set(order.rawValue, forKey: TitleDateOrder.key); changed.append("title_date_order")
            }
            if let v = args.string("video_listing") {
                guard let listing = ChannelListing(rawValue: v) else {
                    throw ToolError("video_listing must be " + ChannelListing.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                }
                d.set(listing.rawValue, forKey: ChannelListing.key); changed.append("video_listing")
            }
            if style != settings.houseStyle { style.save(to: d) }
            if let v = args.string("default_preacher") { d.set(v, forKey: "dechaff.preacher"); changed.append("default_preacher") }
            if let v = args.string("default_series") { d.set(v, forKey: "dechaff.series"); changed.append("default_series") }
            if let path = args.string("artwork_path") {
                d.set(try loadArtwork(path), forKey: "dechaff.artwork"); changed.append("artwork")
            }
            guard !changed.isEmpty else { throw ToolError("Nothing to change — give at least one setting.") }
            return .json([
                "changed": .array(changed),
                "settings": AppSettings().json,
                "note": .string("DeChaff picks these up the next time it's opened. New church instructions reach "
                    + "the prepare_sermon prompt now and the server's instructions on reconnect."),
            ])
        }
    }

    var revealInFinder: MCPTool {
        MCPTool(name: "reveal_in_finder", title: "Show in Finder",
                description: "Opens a Finder window with the file selected — e.g. the finished episode, ready to upload.",
                inputSchema: Schema.object(["path": Schema.string("Absolute path to a file on this Mac.")],
                                           required: ["path"]),
                annotations: ["readOnlyHint": true, "openWorldHint": false]) { raw, _ in
            let url = expandPath(try Args(raw).requiredString("path"))
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("\(url.path) doesn't exist.") }
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-R", url.path]
            try opener.run()
            opener.waitUntilExit()
            return .json(["revealed": .string(url.path)])
        }
    }

    // MARK: - Hand-off to the app

    var openInDeChaff: MCPTool {
        MCPTool(name: "open_in_dechaff", title: "Open in DeChaff",
                description: "Opens the episode in the DeChaff app so the user can adjust it by hand — drag a chapter "
                    + "marker, fine-tune the trim, cut a passage, fix a tag. Takes the same episode arguments as "
                    + "process_sermon (cuts are refined into silence unless refine is false) and opens the app on the "
                    + "chosen step with everything filled in. When the user says they're done, call get_dechaff_plan to "
                    + "see what they changed. They may also process it in the app themselves.",
                inputSchema: Schema.object(Self.episodeSchema.merging([
                    "step": Schema.string("Which step to open on (default chapters).",
                                          enum: ["trim", "info", "chapters", "output"]),
                ]) { a, _ in a }),
                annotations: ["destructiveHint": false, "openWorldHint": false]) { raw, _ in
            let args = Args(raw)
            let episode = try await parseEpisode(args, settings: AppSettings())
            let plan = EpisodePlan(
                sourcePath: episode.url.path, trimIn: episode.trimIn, trimOut: episode.trimOut,
                excluded: episode.excluded.map { .init(start: $0.startSeconds, end: $0.endSeconds) },
                chapters: episode.chapters.map { .init(time: $0.timeSeconds, title: $0.title) },
                title: episode.tags.title, reading: episode.tags.reading, preacher: episode.tags.preacher,
                series: episode.tags.series, date: episode.tags.date, artwork: episode.tags.artwork,
                editedBy: .assistant)
            try EpisodePlanFile.save(plan)
            let step = args.string("step") ?? "chapters"
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Send it to the app this server is embedded in, so both are the same version;
            // a server built from source falls back to whichever DeChaff is the default.
            let link = "dechaff://open-plan?step=\(step)"
            let app = Bundle.main.bundleURL
            opener.arguments = app.pathExtension == "app" ? ["-a", app.path, link] : [link]
            try opener.run()
            opener.waitUntilExit()
            guard opener.terminationStatus == 0 else {
                throw ToolError("Saved the plan but couldn't open DeChaff. Is it installed?")
            }
            var o = planJSON(plan)
            o["opened_on"] = .string(step)
            o["warnings"] = .array(episode.warnings)
            o["next_step"] = .string("Tell the user it's open in DeChaff. When they say they're done, call "
                + "get_dechaff_plan, summarise what they changed, and process with process_sermon from_plan: true once "
                + "they confirm.")
            return .json(.object(o))
        }
    }

    var getDeChaffPlan: MCPTool {
        MCPTool(name: "get_dechaff_plan", title: "Read the episode from DeChaff",
                description: "Returns the episode as it currently stands in the DeChaff app — recording, trim, cut "
                    + "sections, chapters and tags — including any changes the user made by hand. edited_by says whether "
                    + "the user (app) or you (assistant) changed it last.",
                inputSchema: Schema.object([:]),
                annotations: Self.readOnly) { _, _ in
            guard let plan = EpisodePlanFile.load() else {
                throw ToolError("There's no episode open in DeChaff.")
            }
            var o = planJSON(plan)
            o["next_step"] = "To process it exactly as it is, run process_sermon with from_plan: true."
            return .json(.object(o))
        }
    }

    // MARK: - Episodes (shared by process_sermon and open_in_dechaff)

    /// The arguments that describe an episode — what open_in_dechaff hands to the app and
    /// process_sermon processes.
    static let episodeSchema: [String: JSONValue] = [
        "path": Schema.path,
        "video_id": Schema.videoID,
        "trim_start": Schema.cutPoint("First word to keep. Omit to start at the beginning."),
        "trim_end": Schema.cutPoint("Last word to keep. Omit to keep to the end."),
        "refine": Schema.boolean("Snap trim and chapter points into silence (default true)."),
        "exclude": Schema.array(Schema.object([
            "start": Schema.number("Start of the passage to cut, in source seconds."),
            "end": Schema.number("End of the passage to cut, in source seconds."),
        ], required: ["start", "end"]), "Passages to cut out of the middle (e.g. notices), in source seconds."),
        "tags": Schema.tags,
        "chapters": Schema.array(Schema.object([
            "at": Schema.cutPoint("First word of the chapter."),
            "title": Schema.string("Chapter title."),
        ], required: ["at", "title"]), "Chapter markers. Include one at the trim start (e.g. \"Introduction\")."),
    ]

    struct ParsedEpisode {
        var url: URL
        var trimIn: Double
        var trimOut: Double
        var excluded: [ExcludedRange]
        var chapters: [Chapter]
        var tags: SermonTags
        var warnings: [JSONValue]
        var cutReports: [String: JSONValue]
    }

    /// Reads an episode from tool arguments — refining cuts into silence unless refine is
    /// false — or, with from_plan, from the plan the user last left in the app.
    func parseEpisode(_ args: Args, settings: AppSettings) async throws -> ParsedEpisode {
        if try args.bool("from_plan") == true {
            guard let plan = EpisodePlanFile.load() else {
                throw ToolError("There's no episode open in DeChaff. Use open_in_dechaff first.")
            }
            guard FileManager.default.fileExists(atPath: plan.sourcePath) else {
                throw ToolError("The recording in DeChaff's plan is gone: \(plan.sourcePath).")
            }
            var tags = SermonTags(title: plan.title, reading: plan.reading, preacher: plan.preacher,
                                  series: plan.series, artwork: plan.artwork ?? settings.artwork)
            tags.date = plan.date
            return ParsedEpisode(
                url: URL(fileURLWithPath: plan.sourcePath), trimIn: plan.trimIn, trimOut: plan.trimOut,
                excluded: plan.excluded.map { ExcludedRange(startSeconds: $0.start, endSeconds: $0.end) },
                chapters: plan.chapters.map { Chapter(timeSeconds: $0.time, title: $0.title) },
                tags: tags, warnings: [], cutReports: [:])
        }

        let url = try current.resolve(args)
        let words = await transcripts.words(for: url) ?? []
        let refine = try args.bool("refine") ?? true
        let refiner = CutPointRefiner()
        let duration = audioDuration(url) ?? 0
        var cutReports: [String: JSONValue] = [:]
        var warnings: [JSONValue] = []

        func cut(_ edge: CutEdge, _ key: String) throws -> Double? {
            guard let spec = try CutPointSpec(args[key], name: key) else { return nil }
            if refine {
                let r = try refiner.refine(edge: edge, spec, words: words, audioURL: url)
                cutReports[key] = refinementJSON(r)
                if r.quality != .clean { warnings.append(.string("\(key): " + r.notes.joined(separator: " "))) }
                return r.time
            }
            switch spec {
            case .time(let t): return t
            case .word(let i):
                guard words.indices.contains(i) else { throw ToolError("\(key).word_index \(i) is out of range.") }
                return edge == .start ? words[i].startTime : words[i].endTime
            }
        }
        let trimIn = try cut(.start, "trim_start") ?? 0
        let trimOut = min(try cut(.end, "trim_end") ?? duration, duration > 0 ? duration : .infinity)
        guard trimOut > trimIn + 1 else {
            throw ToolError("Trim end (\(formatTime(trimOut))) must be after trim start (\(formatTime(trimIn))).")
        }

        var chapters: [Chapter] = []
        for (i, c) in (try args.array("chapters") ?? []).enumerated() {
            let ch = Args(c)
            guard let spec = try CutPointSpec(ch["at"], name: "chapters[\(i)].at") else {
                throw ToolError("chapters[\(i)] needs \"at\".")
            }
            var t: Double
            if refine {
                let r = try refiner.refine(edge: .start, spec, words: words, audioURL: url)
                t = r.time
                if r.quality == .forced { warnings.append(.string("chapter \(i + 1): " + r.notes.joined(separator: " "))) }
            } else if case .time(let s) = spec {
                t = s
            } else if case .word(let w) = spec, words.indices.contains(w) {
                t = words[w].startTime
            } else {
                throw ToolError("chapters[\(i)].at.word_index is out of range.")
            }
            // A chapter a hair before the trim start belongs at the very start.
            if t < trimIn && t > trimIn - 1 { t = trimIn }
            guard t >= trimIn && t < trimOut else {
                throw ToolError("Chapter \(i + 1) (\(formatTime(t))) is outside the trimmed range.")
            }
            chapters.append(Chapter(timeSeconds: t, title: ch.string("title") ?? "Chapter \(i + 1)"))
        }

        // Tags
        let tagArgs = args.object("tags") ?? Args(.object([:]))
        var tags = SermonTags(title: tagArgs.string("title") ?? "", reading: tagArgs.string("reading") ?? "",
                              preacher: tagArgs.string("preacher") ?? "", series: tagArgs.string("series") ?? "",
                              artwork: settings.artwork)
        if let d = tagArgs.string("date") {
            guard let date = parseExtractedDate(d, order: AppSettings().titleDateOrder) else { throw ToolError("Couldn't read date “\(d)” — use YYYY-MM-DD.") }
            tags.date = date
        }
        if let art = tagArgs.string("artwork_path") {
            tags.artwork = try loadArtwork(art)
        }

        var excluded: [ExcludedRange] = []
        for (i, e) in (try args.array("exclude") ?? []).enumerated() {
            let ex = Args(e)
            guard let a = try ex.double("start"), let b = try ex.double("end"), b > a else {
                throw ToolError("exclude[\(i)] needs start < end, in seconds.")
            }
            excluded.append(ExcludedRange(startSeconds: a, endSeconds: b))
        }
        return ParsedEpisode(url: url, trimIn: trimIn, trimOut: trimOut, excluded: excluded, chapters: chapters,
                             tags: tags, warnings: warnings, cutReports: cutReports)
    }

    var readTags: MCPTool {
        MCPTool(name: "read_tags", title: "Read ID3 tags",
                description: "Reads an MP3's ID3 tags: title, artist, album, year, artwork and chapter markers. "
                    + "Use it to check a finished episode.",
                inputSchema: Schema.object(["path": Schema.string("Absolute path to the MP3.")], required: ["path"]),
                annotations: Self.readOnly) { raw, _ in
            let url = try Args(raw).existingFile("path")
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let tag = ID3Tag.read(data) else { return .json(["path": .string(url.path), "id3": .null]) }
            return .json([
                "path": .string(url.path),
                "id3_version": .string("2.\(tag.version)"),
                "title": JSONValue(tag.text["TIT2"]), "artist": JSONValue(tag.text["TPE1"]),
                "album": JSONValue(tag.text["TALB"]), "year": JSONValue(tag.text["TYER"] ?? tag.text["TDRC"]),
                "artwork": tag.artwork.map { (art: Data) -> JSONValue in
                    ["bytes": .number(Double(art.count)), "mime": JSONValue(tag.artworkMIME)]
                } ?? .null,
                "chapters": .array(tag.chapters.map {
                    ["title": .string($0.title), "start": .string(formatTime($0.startSeconds)),
                     "end": .string(formatTime($0.endSeconds)), "start_seconds": rounded($0.startSeconds, 3)]
                }),
                "duration": JSONValue(audioDuration(url).map(formatTime)),
            ])
        }
    }

    var writeTags: MCPTool {
        MCPTool(name: "write_tags", title: "Write ID3 tags",
                description: "Rewrites a finished MP3's tags without re-encoding — e.g. to fix a typo in the title or "
                    + "move a chapter. Fields not given keep their current values. Chapter times here are on the "
                    + "episode's own timeline (as read_tags shows them), not the source recording's.",
                inputSchema: Schema.object([
                    "path": Schema.string("Absolute path to the MP3."),
                    "tags": Schema.tags,
                    "chapters": Schema.array(Schema.object([
                        "time": ["type": ["number", "string"], "description": "Seconds or \"mm:ss\" into the episode."],
                        "title": Schema.string("Chapter title."),
                    ], required: ["time", "title"]), "Replaces all chapters. Omit to keep the current ones."),
                ], required: ["path"]),
                annotations: ["destructiveHint": true, "idempotentHint": true, "openWorldHint": false]) { raw, _ in
            let args = Args(raw)
            let url = try args.existingFile("path")
            guard url.pathExtension.lowercased() == "mp3" else { throw ToolError("write_tags only works on MP3 files.") }
            let existing = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(ID3Tag.read)
            let t = args.object("tags") ?? Args(.object([:]))

            var metadata = ID3Metadata(title: existing?.text["TIT2"] ?? "", artist: existing?.text["TPE1"] ?? "",
                                       album: existing?.text["TALB"] ?? "", year: existing?.text["TYER"] ?? "",
                                       artwork: existing?.artwork)
            if t.string("title") != nil || t.string("reading") != nil {
                metadata.title = [t.string("title"), t.string("reading")].compactMap { $0 }.joined(separator: ", ")
            }
            if let p = t.string("preacher") { metadata.artist = p }
            if let s = t.string("series") { metadata.album = s }
            if let d = t.string("date") {
                guard let date = parseExtractedDate(d, order: AppSettings().titleDateOrder) else { throw ToolError("Couldn't read date “\(d)” — use YYYY-MM-DD.") }
                metadata.year = String(Calendar.current.component(.year, from: date))
            }
            if let art = t.string("artwork_path") {
                metadata.artwork = try loadArtwork(art)
            }

            var chapters = (existing?.chapters ?? []).map { Chapter(timeSeconds: $0.startSeconds, title: $0.title) }
            if let given = try args.array("chapters") {
                chapters = try given.enumerated().map { i, c in
                    let ch = Args(c)
                    guard let time = try ch.double("time") else { throw ToolError("chapters[\(i)] needs time.") }
                    return Chapter(timeSeconds: time, title: ch.string("title") ?? "Chapter \(i + 1)")
                }
            }

            var log: [String] = []
            VoiceIsolationProcessor().writeTags(chapters: chapters, metadata: metadata, to: url.path) { log.append($0) }
            if let failure = log.first(where: { $0.hasPrefix("⚠️") }) { throw ToolError(failure) }
            return .json(["path": .string(url.path), "result": .string(log.last ?? "Saved"),
                          "chapters": .number(Double(chapters.count))])
        }
    }

    // MARK: - Jobs

    var getJob: MCPTool {
        MCPTool(name: "get_job", title: "Wait for a job",
                description: "Waits for a running download, analysis, transcription or processing job and returns its "
                    + "result — or its progress if still running after wait_seconds. With no job_id, lists all jobs.",
                inputSchema: Schema.object([
                    "job_id": Schema.string("The job_id a tool returned."),
                    "wait_seconds": Schema.waitSeconds,
                ]),
                annotations: Self.readOnly) { raw, context in
            let args = Args(raw)
            guard let id = args.string("job_id") else {
                return .json(["jobs": .array(jobs.all.map { $0.status() })])
            }
            guard let job = jobs.job(id) else { throw ToolError("No job \(id).") }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    var cancelJob: MCPTool {
        MCPTool(name: "cancel_job", title: "Cancel a job",
                description: "Stops a running job. A cancelled processing job removes its partial output.",
                inputSchema: Schema.object(["job_id": Schema.string("The job to stop.")], required: ["job_id"]),
                annotations: ["destructiveHint": false, "openWorldHint": false]) { raw, _ in
            let id = try Args(raw).requiredString("job_id")
            guard let job = jobs.job(id) else { throw ToolError("No job \(id).") }
            job.cancel()
            return .json(job.status())
        }
    }

    // MARK: - Helpers

    static let ytDlpMissing = ToolError(
        "yt-dlp isn't installed yet. Open DeChaff once (it installs and updates yt-dlp automatically), "
        + "or check Settings → General.")

    /// Reads an image and re-encodes it as JPEG, as the app does when artwork is chosen.
    private func loadArtwork(_ path: String) throws -> Data {
        let url = expandPath(path)
        guard let data = try? Data(contentsOf: url) else { throw ToolError("Couldn't read artwork at \(url.path).") }
        guard let jpeg = jpegImage(data) else { throw ToolError("\(url.lastPathComponent) isn't an image DeChaff can read.") }
        return jpeg
    }

    private func requireTranscript(_ url: URL) async throws -> [TranscriptWord] {
        guard let words = await transcripts.words(for: url) else {
            throw ToolError("No transcript for \(url.lastPathComponent) yet — run transcribe first.")
        }
        return words
    }
}

// MARK: - Free helpers

private func isoDate(_ date: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
}

/// A plan as the assistant sees it: times in seconds and as m:ss, artwork as a yes/no.
private func planJSON(_ plan: EpisodePlan) -> [String: JSONValue] {
    let kept = keptDuration(keptRanges(trimIn: plan.trimIn, trimOut: plan.trimOut,
                                       excluding: plan.excluded.map { ExcludedRange(startSeconds: $0.start, endSeconds: $0.end) }))
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    return [
        "path": .string(plan.sourcePath),
        "trim": ["start": timeJSON(plan.trimIn), "end": timeJSON(plan.trimOut), "kept": .string(formatTime(kept))],
        "excluded": .array(plan.excluded.map { ["start": timeJSON($0.start), "end": timeJSON($0.end)] }),
        "chapters": .array(plan.chapters.sorted { $0.time < $1.time }.map { ["time": timeJSON($0.time), "title": .string($0.title)] }),
        "tags": [
            "title": .string(plan.title), "reading": .string(plan.reading), "preacher": .string(plan.preacher),
            "series": .string(plan.series), "date": .string(dateFormatter.string(from: plan.date)),
            "artwork": .bool(plan.artwork != nil),
        ],
        "edited_by": .string(plan.editedBy == .app ? "user (in the DeChaff app)" : "assistant"),
        "updated_at": .string(ISO8601DateFormatter().string(from: plan.updatedAt)),
    ]
}

/// The user's AI Assistant prompt with its placeholders filled exactly as the app fills
/// them, for the assistant to follow with the sermon transcript as its input.
private func websiteCopyJSON(template: String, tags: SermonTags, trimIn: Double, trimOut: Double,
                             outputSeconds: Double?) -> JSONValue {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "dd/MM/yyyy"
    let duration = outputSeconds ?? (trimOut - trimIn)
    let h = Int(duration) / 3600, m = (Int(duration) % 3600) / 60, sec = Int(duration) % 60
    let prompt = template
        .replacingOccurrences(of: "{title}", with: tags.title)
        .replacingOccurrences(of: "{preacher}", with: tags.preacher)
        .replacingOccurrences(of: "{series}", with: tags.series)
        .replacingOccurrences(of: "{reading}", with: tags.reading)
        .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: tags.date))
        .replacingOccurrences(of: "{year}", with: tags.year)
        .replacingOccurrences(of: "{duration}", with: h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                                                            : String(format: "%d:%02d", m, sec))
    return [
        "instructions": .string("Finish by following this prompt from DeChaff's AI Assistant settings exactly. Its input is "
            + "the transcript of the episode — read it with get_transcript format \"text\" (plain paragraphs, no "
            + "times) from \(formatTime(trimIn)) to \(formatTime(trimOut)), continuing if it says it was truncated. "
            + "Report the finished file first, then give the prompt's result as its own block, exactly in the "
            + "format the prompt asks for, with nothing of yours mixed into that block."),
        "transcript_range": ["start": timeJSON(trimIn), "end": timeJSON(trimOut)],
        "prompt": .string(prompt),
    ]
}

/// A finished download as the assistant sees it.
private func downloadJSON(_ file: URL, videoID: String?, info: DownloadInfo?) -> [String: JSONValue] {
    var o: [String: JSONValue] = [
        "path": .string(file.path),
        "video_id": JSONValue(videoID),
        "duration": JSONValue(audioDuration(file).map(formatTime)),
        "duration_seconds": JSONValue(audioDuration(file)),
    ]
    if let info {
        o["title"] = .string(info.title)
        o["upload_date"] = JSONValue(parseYouTubeUploadDate(info.uploadDate).map(isoDate))
    }
    return o
}

/// A video's title and date, saved beside its cached download so a later session can
/// show them without asking YouTube again.
struct DownloadInfo: Codable {
    var title: String
    var uploadDate: String

    private static func url(_ id: String) -> URL { DownloadCache.directory.appendingPathComponent("info-\(id).json") }

    static func load(_ id: String) -> DownloadInfo? {
        (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(DownloadInfo.self, from: $0) }
    }

    func save(_ id: String) {
        try? JSONEncoder().encode(self).write(to: Self.url(id), options: .atomic)
    }
}

/// Series and preachers the church has used, most recent first — from the app's last-used
/// values and the episode history — for recognising them in hand-typed titles.
private func knownNames() -> (series: [String], preachers: [String]) {
    let settings = AppSettings()
    let history = EpisodeHistory.load()
    func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    return (dedupe([settings.lastSeries] + EpisodeHistory.recentValues(history, \.series)),
            dedupe([settings.lastPreacher] + EpisodeHistory.recentValues(history, \.preacher)))
}

/// Sermon fields from a video title, each with a confidence. The strict template parse is
/// trusted when it matches cleanly; otherwise on-device AI (when given); either way each
/// field is checked against a parse by shape (`guessSermonFields`), which also fills gaps
/// such as a series missing from the title. Fields below "high" are listed under "check".
private func titleFieldsJSON(_ title: String, format: String, onDevice: SermonMetadata?) -> JSONValue {
    let known = knownNames()
    let guess = guessSermonFields(title, knownSeries: known.series, knownPreachers: known.preachers)
    let template = extractSermonMetadataViaTemplate(from: title, format: format)
    let templateClean = template.map { m in
        ![m.title, m.bibleReading, m.speaker, m.series, m.date].contains { $0.contains("|") }
    } ?? false

    var base: SermonMetadata? = nil
    var baseConfidence = FieldConfidence.low
    var method = "title_layout"
    if templateClean, let template {
        base = template; baseConfidence = .high; method = "template"
    } else if let onDevice {
        base = onDevice; baseConfidence = .medium; method = "apple_intelligence"
    }

    var values: [String: JSONValue] = ["method": .string(method)]
    var confidence: [String: JSONValue] = [:]
    var notes: [String: JSONValue] = [:]
    var check: [JSONValue] = []
    let fields: [(String, String?, GuessedSermonFields.Field)] = [
        ("title", base?.title, guess.title), ("reading", base?.bibleReading, guess.reading),
        ("preacher", base?.speaker, guess.preacher), ("series", base?.series, guess.series),
        ("date", base?.date, guess.date),
    ]
    for (name, baseValue, guessed) in fields {
        let b = (baseValue ?? "").trimmingCharacters(in: .whitespaces)
        var value = b, conf = baseConfidence, note: String? = nil
        let agrees = !b.isEmpty && b.compare(guessed.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        if b.isEmpty || b.contains("|") {
            // The model missed it or ran fields together: take the reading by shape.
            (value, conf, note) = (guessed.value, guessed.confidence, guessed.note)
        } else if agrees {
            conf = .high
        } else if guessed.confidence == .high && (name == "reading" || name == "date") {
            // A recognised Bible reference or date beats a free-text guess.
            (value, conf, note) = (guessed.value, .high, "the title has \"\(guessed.value)\"; the parse said \"\(b)\"")
        }
        if name == "date", let d = parseExtractedDate(value, order: AppSettings().titleDateOrder) { value = isoDate(d) }
        values[name] = .string(value)
        confidence[name] = .string(value.isEmpty ? "none" : conf.rawValue)
        if let note { notes[name] = .string(note) }
        if value.isEmpty || conf < .high { check.append(.string(name)) }
    }
    values["confidence"] = .object(confidence)
    if !notes.isEmpty { values["notes"] = .object(notes) }
    if !guess.unused.isEmpty { values["unused_parts"] = .array(guess.unused.map { .string($0) }) }
    values["check"] = .array(check)
    return .object(values)
}

private func audioDuration(_ url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    return Double(file.length) / file.fileFormat.sampleRate
}

private func transcriptSummary(_ words: [TranscriptWord], cached: Bool) -> JSONValue {
    let preview = words.prefix(40).map(\.text).joined(separator: " ")
    return [
        "word_count": .number(Double(words.count)),
        "first_word": .string(formatTime(words.first?.startTime ?? 0)),
        "last_word": .string(formatTime(words.last?.endTime ?? 0)),
        "cached": .bool(cached),
        "preview": .string(preview),
        "next_step": "Read it with get_transcript (use start/end windows for long files) or find phrases with search_transcript.",
    ]
}

/// Lowercased with punctuation stripped, so "Pray." matches "pray".
private func normalizeWord(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "’" })
        .replacingOccurrences(of: "’", with: "'")
}

/// Splits words into sentences: after . ? ! or at a pause of a second or more.
private func sentences(_ words: [TranscriptWord], _ range: ClosedRange<Int>) -> [ClosedRange<Int>] {
    var result: [ClosedRange<Int>] = []
    var start = range.lowerBound
    for i in range {
        let last = words[i].text.last
        let endsSentence = last == "." || last == "?" || last == "!"
        let pauseFollows = i < range.upperBound && words[i + 1].startTime - words[i].endTime >= 1.0
        if endsSentence || pauseFollows || i == range.upperBound {
            result.append(start...i)
            start = i + 1
        }
    }
    return result
}

// MARK: - Trim suggestions

private func trimSuggestionJSON(_ words: [TranscriptWord], analysis: AudioAnalysis?, style: HouseStyle) -> JSONValue {
    let s = suggestTrim(words: words, music: analysis?.musicSegments ?? [], style: style)

    /// A point with the words either side, the point's own word in [[ ]].
    func pointJSON(_ p: TrimSuggestion.Point?) -> JSONValue {
        guard let p else { return .null }
        let i = p.wordIndex
        let before = words[max(0, i - 10)..<i].map(\.text).joined(separator: " ")
        let after = words[min(words.count, i + 1)..<min(words.count, i + 11)].map(\.text).joined(separator: " ")
        return [
            "word_index": .number(Double(i)), "time": .string(formatTime(p.time)),
            "confidence": .string(p.confidence.rawValue), "reason": .string(p.reason),
            "context": .string("… \(before) [[\(words[i].text)]] \(after) …"),
        ]
    }

    var chapters: [JSONValue] = []
    for (n, line) in style.chapterLines.enumerated() {
        let lower = line.lowercased()
        var at: TrimSuggestion.Point? = nil
        if line == "{points}" {
            chapters.append(["title": "One chapter per main point", "at": .string("choose from the sermon's structure")])
            continue
        } else if lower.contains("reading") {
            at = s.readingStart
        } else if lower.contains("sermon") || lower.contains("{title}") {
            at = s.sermonStart
        } else if n == 0 {
            at = s.trimStart
        }
        chapters.append(["title_template": .string(line),
                         "at": at.map { JSONValue.number(Double($0.wordIndex)) } ?? "choose from the transcript"])
    }

    // Everything found, minus the many incidental "Amen"s — only those near the end matter.
    let endTime = s.trimEnd?.time ?? .infinity
    let landmarks = s.landmarks.filter { $0.kind != .amen || abs($0.time - endTime) < 300 }.prefix(80)

    var notes = s.notes.map { JSONValue.string($0) }
    if analysis == nil { notes.append("No music detection — the end was placed from spoken cues alone.") }
    return [
        "house_style": houseStyleJSON(style),
        "trim_start": pointJSON(s.trimStart),
        "trim_end": pointJSON(s.trimEnd),
        "reading_start": pointJSON(s.readingStart),
        "sermon_start": pointJSON(s.sermonStart),
        "chapters": .array(chapters),
        "music_segments": .array((analysis?.musicSegments ?? []).map {
            ["start": .string(formatTime($0.startSeconds)), "end": .string(formatTime($0.endSeconds))]
        }),
        "landmarks": .array(landmarks.map {
            ["kind": .string($0.kind.rawValue), "word_index": .number(Double($0.wordIndex)),
             "time": .string(formatTime($0.time)), "phrase": .string($0.phrase)]
        }),
        "notes": .array(notes),
        "next_step": .string("Check each point's context (get_transcript around any that isn't high confidence), then "
            + "refine_cuts with trim_start, trim_end and the chapters."),
    ]
}

func houseStyleJSON(_ style: HouseStyle) -> JSONValue {
    [
        "trim_start": .string(style.trimStart.rawValue),
        "trim_end": .string(style.trimEnd.rawValue),
        "minimum_sermon_minutes": .number(Double(style.minimumSermonMinutes)),
        "chapter_titles": .array(style.chapterLines.map { .string($0) }),
        "artwork_per_series": .bool(style.artworkPerSeries),
        "spoken_cues": .object(Dictionary(uniqueKeysWithValues: style.cuePhrases.map { kind, phrases in
            (kind.rawValue, JSONValue.array(phrases.map { .string($0) }))
        })),
        "guidance": .string(style.guidance),
    ]
}

// MARK: - Finding episode files

/// MP3s under `folder` (subfolders to `maxDepth`), newest first. Skips hidden folders and packages.
private func mp3Files(under folder: URL, maxDepth: Int) -> [(URL, Date)] {
    guard let e = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var found: [(URL, Date)] = []
    var scanned = 0
    for case let url as URL in e {
        scanned += 1
        if scanned > 20_000 { break }  // a huge Downloads folder shouldn't stall the tool
        if e.level > maxDepth { e.skipDescendants(); continue }
        guard url.pathExtension.lowercased() == "mp3" else { continue }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        found.append((url, modified))
    }
    return found.sorted { $0.1 > $1.1 }
}

/// Where a recorded episode is now: its saved path, or a file of the same name in the scanned
/// folder, ~/Music, ~/Desktop or ~/Documents (searched a few levels deep).
private func locateEpisode(_ path: String, near folder: URL) -> String? {
    if FileManager.default.fileExists(atPath: path) { return path }
    let name = URL(fileURLWithPath: path).lastPathComponent
    let home = FileManager.default.homeDirectoryForCurrentUser
    let places = [folder, home.appendingPathComponent("Downloads"), home.appendingPathComponent("Music"),
                  home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents")]
    var seen = Set<String>()
    for place in places where seen.insert(place.path).inserted {
        if let hit = mp3Files(under: place, maxDepth: 4).first(where: { $0.0.lastPathComponent == name }) {
            return hit.0.path
        }
    }
    return nil
}
