import Foundation
import AVFoundation
import MCPServer
import DeChaffCore

/// The DeChaff tools: find and fetch a sermon, survey and transcribe it, choose clean
/// cut points, and produce the tagged, chaptered MP3.
struct DeChaffTools: Sendable {
    let jobs = JobStore()
    let transcripts = TranscriptStore()

    var all: [MCPTool] {
        [getSettings, getArtwork, listChannelVideos, downloadAudio, analyzeAudio, transcribe, getTranscript,
         searchTranscript, refineCuts, previewCut, openInDeChaff, getDeChaffPlan, processSermon, readTags,
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
                    + "channel given), newest first, preferring the channel's livestreams. Each title gets a quick "
                    + "parse into sermon fields using the church's title format; titles are typed by hand, so treat "
                    + "it as a guess and read the raw title. download_audio extracts the fields more carefully.",
                inputSchema: Schema.object([
                    "channel": Schema.string("Channel URL or @handle. Defaults to the channel in DeChaff's settings."),
                    "limit": Schema.integer("How many videos (default: DeChaff's setting, usually 10)."),
                    "tab": Schema.string("Which part of the channel: live (livestreams), videos (ordinary uploads) or "
                        + "auto — livestreams if the channel has any (default).", enum: ["auto", "live", "videos"]),
                ]),
                annotations: ["readOnlyHint": true, "openWorldHint": true]) { raw, _ in
            let args = Args(raw)
            let settings = AppSettings()
            guard let client = YtDlpClient.installed else { throw Self.ytDlpMissing }
            var channel = args.string("channel") ?? settings.channelURL
            if channel.hasPrefix("@") { channel = "https://www.youtube.com/\(channel)" }
            if let tab = args.string("tab"), tab != "auto" {
                // An explicit tab URL skips the client's livestreams-first default.
                let base = channel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .replacingOccurrences(of: "/videos", with: "").replacingOccurrences(of: "/streams", with: "")
                channel = base + (tab == "live" ? "/streams" : "/videos")
            }
            let limit = min(max(try args.int("limit") ?? settings.videoLimit, 1), 50)
            let videos = try await client.fetchVideoList(channelURL: channel, limit: limit)
            return .json([
                "channel": .string(channel),
                "videos": .array(videos.map { v in
                    var o: [String: JSONValue] = [
                        "id": .string(v.id), "url": .string("https://youtu.be/\(v.id)"), "title": .string(v.title),
                        "upload_date": JSONValue(parseYouTubeUploadDate(v.uploadDate).map(isoDate)),
                        "parsed": parsedJSON(v.title, format: settings.titleFormat),
                    ]
                    if let d = v.durationSeconds { o["duration"] = .string(formatTime(Double(d))) }
                    return .object(o)
                }),
            ])
        }
    }

    var downloadAudio: MCPTool {
        MCPTool(name: "download_audio", title: "Download audio",
                description: "Downloads the audio of a YouTube video (or any yt-dlp-supported URL) to a temporary file "
                    + "and returns its path, plus the video title's sermon fields (extracted with on-device Apple "
                    + "Intelligence when available, as the app does; \"method\" says which). Takes a minute or two "
                    + "for a long livestream; returns a job_id to poll with get_job if it runs past wait_seconds.",
                inputSchema: Schema.object([
                    "url": Schema.string("Video URL, e.g. https://youtu.be/abc123."),
                    "wait_seconds": Schema.waitSeconds,
                ], required: ["url"]),
                annotations: ["openWorldHint": true]) { raw, context in
            let args = Args(raw)
            let url = try args.requiredString("url")
            guard let client = YtDlpClient.installed else { throw Self.ytDlpMissing }
            let titleFormat = AppSettings().titleFormat
            let job = jobs.running(kind: "download", summary: "Download \(url)")
                ?? jobs.start(kind: "download", summary: "Download \(url)") { job in
                    async let info = try? client.fetchInfo(url: url)
                    let file = try await client.downloadAudio(
                        url: url,
                        onStart: { process in job.onCancel { process.terminate() } },
                        onLine: { line in
                            if let p = YtDlpClient.parseProgress(line) { job.update(progress: p * 0.99) }
                        })
                    let entry = await info
                    var o: [String: JSONValue] = [
                        "path": .string(file.path),
                        "duration": JSONValue(audioDuration(file).map(formatTime)),
                        "duration_seconds": JSONValue(audioDuration(file)),
                    ]
                    if let entry {
                        o["title"] = .string(entry.title)
                        o["upload_date"] = JSONValue(parseYouTubeUploadDate(entry.uploadDate).map(isoDate))
                        o["parsed"] = await extractedJSON(entry.title, format: titleFormat)
                    }
                    o["next_step"] = "Run analyze_audio and transcribe on this path to plan the trim."
                    return .object(o)
                }
            return .json(try await jobs.wait(for: job, upTo: try args.double("wait_seconds") ?? 40, context: context))
        }
    }

    // MARK: - Analysis

    var analyzeAudio: MCPTool {
        MCPTool(name: "analyze_audio", title: "Analyse audio",
                description: "Surveys a recording: duration, integrated loudness (LUFS), music segments (worship, "
                    + "intros — usually what gets trimmed) and long silences. Times are on the source timeline.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "detect_music": Schema.boolean("Classify music segments (default true; adds ~10–20 s)."),
                    "min_silence_seconds": Schema.number("Only report silences at least this long (default 2)."),
                    "wait_seconds": Schema.waitSeconds,
                ], required: ["path"]),
                annotations: Self.readOnly) { raw, context in
            let args = Args(raw)
            let url = try args.existingFile("path")
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
                    "force": Schema.boolean("Transcribe again even if a cached transcript exists."),
                    "wait_seconds": Schema.waitSeconds,
                ], required: ["path"]),
                annotations: Self.readOnly) { raw, context in
            let args = Args(raw)
            let url = try args.existingFile("path")
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
                    + "start–end time — use it on a short window to inspect a boundary.",
                inputSchema: Schema.object([
                    "path": Schema.path,
                    "start": ["type": ["number", "string"], "description": "Window start (seconds or \"mm:ss\")."],
                    "end": ["type": ["number", "string"], "description": "Window end (seconds or \"mm:ss\")."],
                    "format": Schema.string("\"sentences\" (default) or \"words\".", enum: ["sentences", "words"]),
                    "max_chars": Schema.integer("Truncate output after this many characters (default 40000)."),
                ], required: ["path"]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let url = try args.existingFile("path")
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
            if args.string("format") == "words" {
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
                    "query": Schema.string("Words to find."),
                    "max_results": Schema.integer("Default 20."),
                ], required: ["path", "query"]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let url = try args.existingFile("path")
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
                    "trim_start": Schema.cutPoint("First word to keep."),
                    "trim_end": Schema.cutPoint("Last word to keep."),
                    "chapters": Schema.array(Schema.object([
                        "at": Schema.cutPoint("First word of the chapter."),
                        "title": Schema.string("Chapter title."),
                    ], required: ["at", "title"]), "Chapter starts to snap to the speech that begins them."),
                ], required: ["path"]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let url = try args.existingFile("path")
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
                    // Like the app: the next episode starts from this one's preacher, series and artwork.
                    // Test renders (WAV, or no title) leave the saved defaults alone.
                    let remember = format == .mp3 && !finalTags.title.isEmpty
                    if remember {
                        AppSettings().rememberLastUsed(preacher: finalTags.preacher, series: finalTags.series,
                                                       artwork: finalTags.artwork)
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
                description: "Lists recent finished episodes (tagged MP3s, newest first) with their title, preacher, "
                    + "series, chapters and whether they use the saved artwork. Use it to match last week: the same "
                    + "spelling of the series, the same chapter style, and to notice when the series has changed.",
                inputSchema: Schema.object([
                    "folder": Schema.string("Folder to look in (default ~/Downloads, where YouTube episodes are saved)."),
                    "limit": Schema.integer("How many episodes (default 8)."),
                ]),
                annotations: Self.readOnly) { raw, _ in
            let args = Args(raw)
            let folder = expandPath(args.string("folder") ?? "~/Downloads")
            let limit = min(max(try args.int("limit") ?? 8, 1), 50)
            let saved = AppSettings().artwork
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension.lowercased() == "mp3" }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            var episodes: [JSONValue] = []
            for (url, modified) in files where episodes.count < limit {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let tag = ID3Tag.read(data), let title = tag.text["TIT2"], !title.isEmpty else { continue }
                episodes.append([
                    "path": .string(url.path),
                    "modified": .string(ISO8601DateFormatter().string(from: modified)),
                    "title": .string(title),
                    "preacher": JSONValue(tag.text["TPE1"]),
                    "series": JSONValue(tag.text["TALB"]),
                    "year": JSONValue(tag.text["TYER"] ?? tag.text["TDRC"]),
                    "duration": JSONValue(audioDuration(url).map(formatTime)),
                    "chapters": .array(tag.chapters.map {
                        ["title": .string($0.title), "start": .string(formatTime($0.startSeconds))]
                    }),
                    "artwork": tag.artwork == nil ? "none"
                        : .string(tag.artwork == saved ? "same as DeChaff's saved artwork" : "different from the saved artwork"),
                ])
            }
            return .json(["folder": .string(folder.path), "episodes": .array(episodes)])
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
                    "at": Schema.cutPoint("The trim or chapter point to hear."),
                    "edge": Schema.string("start: hear the episode begin; end: hear it finish; chapter: hear "
                        + "either side of a chapter point (default chapter).", enum: ["start", "end", "chapter"]),
                    "seconds": Schema.number("Length of the preview (default 10)."),
                    "refine": Schema.boolean("Snap the point into silence first (default true)."),
                    "play": Schema.boolean("Open the preview in the default audio app (default true)."),
                ], required: ["path", "at"]),
                annotations: ["destructiveHint": false, "openWorldHint": false]) { raw, _ in
            let args = Args(raw)
            let url = try args.existingFile("path")
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
                    + "fields given are changed. Use artwork_path to save a new series' artwork as the default, and "
                    + "church_instructions to record how the user likes episodes made. Confirm with the user first.",
                inputSchema: Schema.object([
                    "church_instructions": Schema.string("Replaces the church's instructions for the assistant."),
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
                ]) { a, _ in a }, required: ["path"]),
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

        let url = try args.existingFile("path")
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
            guard let date = parseExtractedDate(d) else { throw ToolError("Couldn't read date “\(d)” — use YYYY-MM-DD.") }
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
                inputSchema: Schema.object(["path": Schema.path], required: ["path"]),
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
                guard let date = parseExtractedDate(d) else { throw ToolError("Couldn't read date “\(d)” — use YYYY-MM-DD.") }
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
            + "the transcript of the episode — read all of it with get_transcript from \(formatTime(trimIn)) to "
            + "\(formatTime(trimOut)), continuing where it says it was truncated. Give the user the result "
            + "verbatim, in the format the prompt asks for, with nothing added before or after it."),
        "prompt": .string(prompt),
    ]
}

/// Quick template parse — cheap enough for every title in a listing, but literal
/// about separators, so a hand-typed title that strays from the format misparses.
private func parsedJSON(_ title: String, format: String) -> JSONValue {
    guard let m = extractSermonMetadataViaTemplate(from: title, format: format) else { return .null }
    return metadataJSON(m, method: "template")
}

/// Sermon fields as the app extracts them: on-device Apple Intelligence (guided by the
/// title format) when available, else the template parse.
private func extractedJSON(_ title: String, format: String) async -> JSONValue {
    if let m = await extractSermonMetadataOnDevice(from: title, titleFormat: format) {
        return metadataJSON(m, method: "apple_intelligence")
    }
    return parsedJSON(title, format: format)
}

private func metadataJSON(_ m: SermonMetadata, method: String) -> JSONValue {
    [
        "title": .string(m.title), "reading": .string(m.bibleReading),
        "preacher": .string(m.speaker), "series": .string(m.series),
        "date": .string(parseExtractedDate(m.date).map(isoDate) ?? m.date),
        "method": .string(method),
    ]
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
