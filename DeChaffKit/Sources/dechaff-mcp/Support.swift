import Foundation
import MCPServer
import DeChaffCore

// MARK: - Arguments

/// Typed access to a tool's JSON arguments, with errors phrased for the model.
struct Args {
    let raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    subscript(key: String) -> JSONValue? {
        guard let v = raw[key], !v.isNull else { return nil }
        return v
    }

    func string(_ key: String) -> String? {
        guard let s = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = string(key) else { throw ToolError("Missing required argument “\(key)”.") }
        return s
    }

    func double(_ key: String) throws -> Double? {
        guard let v = self[key] else { return nil }
        if let s = v.stringValue, let t = parseTimeString(s) { return t }
        guard let d = v.doubleValue else { throw ToolError("“\(key)” must be a number.") }
        return d
    }

    func int(_ key: String) throws -> Int? {
        guard let v = self[key] else { return nil }
        guard let i = v.intValue else { throw ToolError("“\(key)” must be a whole number.") }
        return i
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = self[key] else { return nil }
        guard let b = v.boolValue else { throw ToolError("“\(key)” must be true or false.") }
        return b
    }

    func object(_ key: String) -> Args? {
        self[key]?.objectValue.map { Args(.object($0)) }
    }

    func array(_ key: String) throws -> [JSONValue]? {
        guard let v = self[key] else { return nil }
        guard let a = v.arrayValue else { throw ToolError("“\(key)” must be an array.") }
        return a
    }

    /// An existing file path (`~` expanded).
    func existingFile(_ key: String) throws -> URL {
        let url = expandPath(try requiredString(key))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("No file at \(url.path).")
        }
        return url
    }
}

func expandPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

/// Parses "754.2", "12:34", "12:34.5" or "1:02:03" into seconds.
func parseTimeString(_ s: String) -> Double? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
    guard (1...3).contains(parts.count) else { return nil }
    var total = 0.0
    for (i, part) in parts.enumerated() {
        guard let v = Double(part), v >= 0 else { return nil }
        // Minutes/seconds fields after the first must be < 60.
        if i > 0 && v >= 60 { return nil }
        total = total * 60 + v
    }
    return total
}

/// "1:02:03.4" / "12:34.5" — rounded to tenths, for showing times to the model.
func formatTime(_ seconds: Double) -> String {
    let s = max(0, seconds)
    let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
    let sec = s - Double(h * 3600 + m * 60)
    return h > 0 ? String(format: "%d:%02d:%04.1f", h, m, sec) : String(format: "%d:%04.1f", m, sec)
}

func rounded(_ v: Double, _ places: Int = 2) -> JSONValue {
    let f = pow(10.0, Double(places))
    return .number((v * f).rounded() / f)
}

/// A time as both seconds and a readable string.
func timeJSON(_ seconds: Double) -> JSONValue {
    ["seconds": rounded(seconds, 3), "formatted": .string(formatTime(seconds))]
}

// MARK: - Schema helpers

enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }

    static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func array(_ items: JSONValue, _ description: String) -> JSONValue {
        ["type": "array", "items": items, "description": .string(description)]
    }

    /// A cut point: a transcript word (preferred) or a time on the source timeline.
    static func cutPoint(_ description: String) -> JSONValue {
        [
            "description": .string(description + " Give either word_index (from get_transcript/search_transcript) "
                                   + "or time (seconds, or \"mm:ss.s\") on the source recording's timeline."),
            "type": "object",
            "properties": [
                "word_index": ["type": "integer", "minimum": 0],
                "time": ["type": ["number", "string"]],
            ],
        ]
    }

    static let path = string("Absolute path to an audio file on this Mac (~ is expanded).")

    static let waitSeconds = number(
        "How long to wait for the work to finish before returning a job_id to poll with get_job (default 40, max 600).")

    static let tags = object([
        "title": string("Sermon title, e.g. \"The Good Shepherd\"."),
        "reading": string("Bible reading, e.g. \"John 10:1–18\". Joined to the title in the ID3 title tag."),
        "preacher": string("Preacher's name (ID3 artist)."),
        "series": string("Sermon series (ID3 album)."),
        "date": string("Sermon date, YYYY-MM-DD (also accepts e.g. \"23 Mar 2025\"). Sets the year tag and the {date} in the filename."),
        "artwork_path": string("JPEG cover art. Defaults to the artwork last used in the DeChaff app."),
    ])
}

// MARK: - Cut points

enum CutPointSpec {
    case word(Int)
    case time(Double)

    /// Accepts {"word_index": n}, {"time": t}, a bare number, or a "mm:ss" string.
    init?(_ value: JSONValue?, name: String) throws {
        guard let value, !value.isNull else { return nil }
        if let o = value.objectValue {
            if let w = o["word_index"], !w.isNull {
                guard let i = w.intValue, i >= 0 else { throw ToolError("\(name).word_index must be a non-negative integer.") }
                self = .word(i)
            } else if let t = o["time"], !t.isNull {
                guard let s = t.stringValue.flatMap(parseTimeString) ?? t.doubleValue, s >= 0 else {
                    throw ToolError("\(name).time must be seconds or \"mm:ss\".")
                }
                self = .time(s)
            } else {
                throw ToolError("\(name) needs word_index or time.")
            }
        } else if let s = value.stringValue.flatMap(parseTimeString) ?? value.doubleValue {
            self = .time(s)
        } else {
            throw ToolError("\(name) must be {\"word_index\": n} or {\"time\": seconds}.")
        }
    }
}

extension CutPointRefiner {
    /// Refines a cut from a tool argument. With no transcript, a word index is an error
    /// and a time is refined from the audio alone.
    func refine(edge: CutEdge, _ spec: CutPointSpec, words: [TranscriptWord], audioURL: URL) throws -> CutRefinement {
        switch spec {
        case .word(let i):
            guard !words.isEmpty else { throw ToolError("word_index needs a transcript — run transcribe first, or pass a time.") }
            guard words.indices.contains(i) else { throw ToolError("word_index \(i) is out of range (0–\(words.count - 1)).") }
            return try refine(edge: edge, wordIndex: i, words: words, audioURL: audioURL)
        case .time(let t):
            return try refine(edge: edge, time: t, words: words, audioURL: audioURL)
        }
    }
}

func refinementJSON(_ r: CutRefinement) -> JSONValue {
    var o: [String: JSONValue] = [
        "edge": .string(r.edge.rawValue),
        "cut": timeJSON(r.time),
        "quality": .string(r.quality.rawValue),
        "level_at_cut_db": rounded(Double(r.levelAtCutDB), 1),
        "noise_floor_db": rounded(Double(r.noiseFloorDB), 1),
        "notes": .array(r.notes.map { .string($0) }),
    ]
    if let w = r.wordIndex { o["word_index"] = .number(Double(w)) }
    if let w = r.word { o["word"] = .string(w) }
    if let t = r.transcriptBoundary { o["transcript_boundary"] = timeJSON(t) }
    if let t = r.detectedBoundary { o["speech_boundary"] = timeJSON(t) }
    return .object(o)
}

// MARK: - Jobs

/// Long-running work (downloads, transcription, processing) runs as a job so a tool call
/// can return before the client's request timeout and be picked up again with get_job.
final class Job: @unchecked Sendable {
    enum State: String { case running, succeeded, failed, cancelled }

    let id: String
    let kind: String
    let summary: String
    let startedAt = Date()

    private let lock = NSLock()
    private var _state = State.running
    private var _progress = 0.0
    private var _message: String?
    private var _result: JSONValue?
    private var _error: String?
    private var _log: [String] = []
    private var task: Task<Void, Never>?
    private var cancelHandlers: [@Sendable () -> Void] = []

    init(id: String, kind: String, summary: String) {
        self.id = id
        self.kind = kind
        self.summary = summary
    }

    func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var state: State { withLock { _state } }
    var progress: Double { withLock { _progress } }
    var result: JSONValue? { withLock { _result } }
    var error: String? { withLock { _error } }
    var log: [String] { withLock { _log } }

    func update(progress: Double, message: String? = nil) {
        withLock {
            _progress = min(max(progress, _progress), 1)
            if let message { _message = message }
        }
    }

    func appendLog(_ line: String) { withLock { _log.append(line) } }

    /// Runs `handler` when the job is cancelled — e.g. to stop a processor or kill a process.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let alreadyCancelled = withLock { () -> Bool in
            if _state == .cancelled { return true }
            cancelHandlers.append(handler)
            return false
        }
        if alreadyCancelled { handler() }
    }

    func cancel() {
        let (handlers, task) = withLock { () -> ([@Sendable () -> Void], Task<Void, Never>?) in
            guard _state == .running else { return ([], nil) }
            _state = .cancelled
            return (cancelHandlers, self.task)
        }
        task?.cancel()
        handlers.forEach { $0() }
    }

    fileprivate func start(_ work: @escaping @Sendable (Job) async throws -> JSONValue) {
        let t = Task {
            do {
                let value = try await work(self)
                withLock {
                    guard _state == .running else { return }
                    _state = .succeeded; _result = value; _progress = 1
                }
            } catch {
                withLock {
                    guard _state == .running else { return }
                    if error is CancellationError { _state = .cancelled } else {
                        _state = .failed; _error = error.localizedDescription
                    }
                }
            }
        }
        withLock { task = t }
    }

    func status() -> JSONValue {
        withLock {
            var o: [String: JSONValue] = [
                "job_id": .string(id), "kind": .string(kind), "summary": .string(summary),
                "status": .string(_state.rawValue),
                "progress": rounded(_progress, 3),
                "elapsed_seconds": rounded(Date().timeIntervalSince(startedAt), 1),
            ]
            if let m = _message { o["message"] = .string(m) }
            if let e = _error { o["error"] = .string(e) }
            if !_log.isEmpty { o["recent_log"] = .array(_log.suffix(8).map { .string($0) }) }
            return .object(o)
        }
    }
}

final class JobStore: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var counter = 0

    func start(kind: String, summary: String,
               work: @escaping @Sendable (Job) async throws -> JSONValue) -> Job {
        let job: Job = {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            let job = Job(id: "\(kind)-\(counter)", kind: kind, summary: summary)
            jobs[job.id] = job
            return job
        }()
        job.start(work)
        return job
    }

    func job(_ id: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    /// The running job of `kind` whose summary matches, so repeated calls share one job.
    func running(kind: String, summary: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.first { $0.kind == kind && $0.summary == summary && $0.state == .running }
    }

    var all: [Job] {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Waits up to `seconds` for `job`. Returns its result when done (throwing its error if it
    /// failed), or a "still running" status the model can poll with get_job.
    func wait(for job: Job, upTo seconds: Double, context: ToolContext) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), 600))
        var lastReported = -1.0
        while job.state == .running && Date() < deadline {
            let p = job.progress
            if p - lastReported >= 0.01 {
                lastReported = p
                await context.progress(p, total: 1, message: job.summary)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        switch job.state {
        case .succeeded:
            return job.result ?? .object([:])
        case .failed:
            throw ToolError("\(job.summary) failed: \(job.error ?? "unknown error")")
        case .cancelled:
            throw ToolError("\(job.summary) was cancelled.")
        case .running:
            var status = job.status().objectValue ?? [:]
            status["next_step"] = .string("Still running. Call get_job with job_id \"\(job.id)\" to wait for the result.")
            return .object(status)
        }
    }
}

/// Runs blocking work on a background queue, calling `onCancel` if the awaiting task is cancelled.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T, onCancel: @escaping @Sendable () -> Void) async -> T {
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    } onCancel: {
        onCancel()
    }
}
