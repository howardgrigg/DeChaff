import Foundation

// MARK: - Server-side definitions

/// What a tool returns. `text` is what the model reads; `structured` is the same data as
/// JSON for clients that support `structuredContent`.
public struct ToolResult: Sendable {
    public var text: String
    public var structured: JSONValue?
    /// Images the model can look at, sent after the text.
    public var images: [Image]
    public var isError: Bool

    public struct Image: Sendable {
        public let data: Data
        public let mimeType: String
        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public init(text: String, structured: JSONValue? = nil, images: [Image] = [], isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.images = images
        self.isError = isError
    }

    /// A JSON object result, shown to the model as indented JSON.
    public static func json(_ value: JSONValue) -> ToolResult {
        ToolResult(text: value.prettyPrinted(), structured: value.objectValue != nil ? value : nil)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(text: message, isError: true)
    }
}

/// A failure a tool reports to the model (bad arguments, missing file…) rather than a crash.
public struct ToolError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Lets a running tool report progress for clients that asked for it.
public struct ToolContext: Sendable {
    let sendProgress: @Sendable (Double, Double?, String?) async -> Void

    public init(sendProgress: @escaping @Sendable (Double, Double?, String?) async -> Void = { _, _, _ in }) {
        self.sendProgress = sendProgress
    }

    public func progress(_ value: Double, total: Double? = nil, message: String? = nil) async {
        await sendProgress(value, total, message)
    }
}

public struct MCPTool: Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: JSONValue?
    public let handler: @Sendable (JSONValue, ToolContext) async throws -> ToolResult

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue,
                annotations: JSONValue? = nil,
                handler: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolResult) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.handler = handler
    }

    var listing: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "description": .string(description),
                                      "inputSchema": inputSchema]
        if let title { o["title"] = .string(title) }
        if let annotations { o["annotations"] = annotations }
        return .object(o)
    }
}

public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public let name: String
        public let description: String
        public let required: Bool
        public init(name: String, description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public let name: String
    public let title: String?
    public let description: String
    public let arguments: [Argument]
    public let render: @Sendable ([String: String]) -> String

    public init(name: String, title: String? = nil, description: String, arguments: [Argument] = [],
                render: @escaping @Sendable ([String: String]) -> String) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.render = render
    }
}

public struct MCPResource: Sendable {
    public let uri: String
    public let name: String
    public let description: String
    public let mimeType: String
    public let read: @Sendable () async throws -> String

    public init(uri: String, name: String, description: String, mimeType: String = "application/json",
                read: @escaping @Sendable () async throws -> String) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.read = read
    }
}

// MARK: - Server

/// A Model Context Protocol server over newline-delimited JSON-RPC on stdio.
/// Supports tools (with progress and cancellation), prompts and static resources.
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let name: String
    let version: String
    let instructions: String?
    let tools: [String: MCPTool]
    let toolOrder: [String]
    let prompts: [String: MCPPrompt]
    let promptOrder: [String]
    let resources: [MCPResource]

    private var inFlight: [String: Task<Void, Never>] = [:]
    private let writeLine: @Sendable (String) -> Void

    public init(name: String, version: String, instructions: String? = nil,
                tools: [MCPTool], prompts: [MCPPrompt] = [], resources: [MCPResource] = [],
                writeLine: @escaping @Sendable (String) -> Void = MCPServer.writeToStdout) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.toolOrder = tools.map(\.name)
        self.prompts = Dictionary(prompts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.promptOrder = prompts.map(\.name)
        self.resources = resources
        self.writeLine = writeLine
    }

    /// Serialises writes so concurrent responses never interleave on stdout.
    public static let writeToStdout: @Sendable (String) -> Void = {
        let lock = NSLock()
        return { line in
            lock.lock(); defer { lock.unlock() }
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }()

    /// Reads messages from stdin until it closes. Each request runs in its own task,
    /// so a long tool call never blocks pings, listings or cancellations.
    public func run() async {
        let lines = AsyncStream<String> { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            thread.start()
        }
        for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            receive(line)
        }
        // stdin closed: the client has gone. Let in-flight work wind down.
        for task in inFlight.values { task.cancel() }
    }

    /// Handles one incoming line. Requests are answered asynchronously through `writeLine`.
    public func receive(_ line: String) {
        let message: JSONValue
        do {
            message = try JSONValue.parse(line)
        } catch {
            send(errorResponse(id: .null, code: -32700, message: "Parse error"))
            return
        }
        // Batches were removed from MCP in 2025-06-18 but older clients may still send them.
        if let batch = message.arrayValue {
            for item in batch { dispatch(item) }
        } else {
            dispatch(message)
        }
    }

    private func dispatch(_ message: JSONValue) {
        guard let method = message["method"]?.stringValue else { return }  // a response to us — ignore
        let id = message["id"]
        let params = message["params"] ?? .object([:])

        guard let id, !id.isNull else {
            handleNotification(method, params)
            return
        }
        let key = id.encodedLine()
        let task = Task { [weak self] in
            guard let self else { return }
            let response = await self.respond(to: method, id: id, params: params)
            await self.finish(key, response)
        }
        inFlight[key] = task
    }

    private func finish(_ key: String, _ response: JSONValue?) {
        inFlight[key] = nil
        if let response { send(response) }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        switch method {
        case "notifications/cancelled":
            if let id = params["requestId"] { inFlight[id.encodedLine()]?.cancel() }
        default:
            break  // notifications/initialized and friends need no reply
        }
    }

    /// Builds the response for one request; nil when the request was cancelled
    /// (the spec says not to answer those).
    func respond(to method: String, id: JSONValue, params: JSONValue) async -> JSONValue? {
        do {
            let result = try await handle(method, params)
            if Task.isCancelled { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            return errorResponse(id: id, code: error.code, message: error.message)
        } catch {
            if Task.isCancelled { return nil }
            return errorResponse(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    private func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            var capabilities: [String: JSONValue] = ["tools": ["listChanged": false]]
            if !prompts.isEmpty { capabilities["prompts"] = ["listChanged": false] }
            if !resources.isEmpty { capabilities["resources"] = ["listChanged": false, "subscribe": false] }
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": .object(capabilities),
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return .object(result)

        case "ping":
            return .object([:])

        case "tools/list":
            return ["tools": .array(toolOrder.compactMap { tools[$0]?.listing })]

        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = tools[name] else {
                throw RPCError(code: -32602, message: "Unknown tool: \(params["name"]?.stringValue ?? "(none)")")
            }
            let arguments = params["arguments"] ?? .object([:])
            let context = progressContext(token: params["_meta"]?["progressToken"])
            let result: ToolResult
            do {
                result = try await tool.handler(arguments, context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Tool failures go back to the model as results it can read and act on.
                result = .error(error.localizedDescription)
            }
            let images: [JSONValue] = result.images.map {
                ["type": "image", "data": .string($0.data.base64EncodedString()), "mimeType": .string($0.mimeType)]
            }
            var o: [String: JSONValue] = [
                "content": .array([["type": "text", "text": .string(result.text)]] + images),
                "isError": .bool(result.isError),
            ]
            if let structured = result.structured { o["structuredContent"] = structured }
            return .object(o)

        case "prompts/list":
            return ["prompts": .array(promptOrder.compactMap { prompts[$0] }.map { p in
                var o: [String: JSONValue] = [
                    "name": .string(p.name), "description": .string(p.description),
                    "arguments": .array(p.arguments.map {
                        ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)]
                    }),
                ]
                if let title = p.title { o["title"] = .string(title) }
                return .object(o)
            })]

        case "prompts/get":
            guard let name = params["name"]?.stringValue, let prompt = prompts[name] else {
                throw RPCError(code: -32602, message: "Unknown prompt: \(params["name"]?.stringValue ?? "(none)")")
            }
            var args: [String: String] = [:]
            for (k, v) in params["arguments"]?.objectValue ?? [:] { args[k] = v.stringValue ?? v.encodedLine() }
            for a in prompt.arguments where a.required && (args[a.name] ?? "").isEmpty {
                throw RPCError(code: -32602, message: "Missing required argument: \(a.name)")
            }
            return [
                "description": .string(prompt.description),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(prompt.render(args))]]],
            ]

        case "resources/list":
            return ["resources": .array(resources.map {
                ["uri": .string($0.uri), "name": .string($0.name),
                 "description": .string($0.description), "mimeType": .string($0.mimeType)]
            })]

        case "resources/templates/list":
            return ["resourceTemplates": []]

        case "resources/read":
            guard let uri = params["uri"]?.stringValue, let resource = resources.first(where: { $0.uri == uri }) else {
                throw RPCError(code: -32002, message: "Resource not found: \(params["uri"]?.stringValue ?? "(none)")")
            }
            let text = try await resource.read()
            return ["contents": [["uri": .string(uri), "mimeType": .string(resource.mimeType), "text": .string(text)]]]

        case "logging/setLevel":
            return .object([:])

        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func progressContext(token: JSONValue?) -> ToolContext {
        guard let token, !token.isNull else { return ToolContext() }
        return ToolContext { [weak self] progress, total, message in
            var params: [String: JSONValue] = ["progressToken": token, "progress": .number(progress)]
            if let total { params["total"] = .number(total) }
            if let message { params["message"] = .string(message) }
            await self?.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": .object(params)])
        }
    }

    private func send(_ message: JSONValue) {
        writeLine(message.encodedLine())
    }

    private func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}

struct RPCError: Error {
    let code: Int
    let message: String
}

/// Diagnostics go to stderr — stdout belongs to the protocol.
public func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
