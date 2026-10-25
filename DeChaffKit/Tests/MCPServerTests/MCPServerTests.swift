import Foundation
import Testing
@testable import MCPServer

/// Collects everything the server writes so tests can inspect responses.
private final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }

    var messages: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { try? JSONValue.parse($0) }
    }

    /// Waits for the response to request `id`.
    func response(id: Int, timeout: Double = 5) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = messages.first(where: { $0["id"] == .number(Double(id)) }) { return m }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ToolError("no response to request \(id)")
    }
}

private func makeServer(_ outbox: Outbox) -> MCPServer {
    let echo = MCPTool(
        name: "echo", description: "Echoes its text argument.",
        inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
    ) { args, context in
        await context.progress(0.5, total: 1, message: "halfway")
        guard let text = args["text"]?.stringValue else { throw ToolError("text is required") }
        return .json(["echo": .string(text)])
    }
    let slow = MCPTool(name: "slow", description: "Sleeps until cancelled.",
                       inputSchema: ["type": "object"]) { _, _ in
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return ToolResult(text: "done")
    }
    let picture = MCPTool(name: "picture", description: "Returns an image.",
                          inputSchema: ["type": "object"]) { _, _ in
        ToolResult(text: "A picture.", images: [.init(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")])
    }
    let prompt = MCPPrompt(name: "greet", description: "Greets someone.",
                           arguments: [.init(name: "who", description: "Name", required: true)]) {
        "Hello, \($0["who"] ?? "")!"
    }
    let resource = MCPResource(uri: "test://settings", name: "Settings", description: "Test settings") { "{\"a\":1}" }
    return MCPServer(name: "test", version: "1.0", instructions: "Be nice.",
                     tools: [echo, slow, picture], prompts: [prompt], resources: [resource],
                     writeLine: { outbox.append($0) })
}

private func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> String {
    JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        .encodedLine()
}

@Suite struct MCPServerTests {
    @Test func initializeNegotiatesVersionAndCapabilities() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive(request(1, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:],
                                                       "clientInfo": ["name": "t", "version": "1"]]))
        let r = try await out.response(id: 1)
        #expect(r["result"]?["protocolVersion"] == "2025-03-26")
        #expect(r["result"]?["serverInfo"]?["name"] == "test")
        #expect(r["result"]?["instructions"] == "Be nice.")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(r["result"]?["capabilities"]?["prompts"] != nil)

        await server.receive(request(2, "initialize", ["protocolVersion": "1999-01-01"]))
        let r2 = try await out.response(id: 2)
        #expect(r2["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])
    }

    @Test func listsAndCallsTools() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive(request(1, "tools/list"))
        let list = try await out.response(id: 1)
        #expect(list["result"]?["tools"]?.arrayValue?.map { $0["name"] } == ["echo", "slow", "picture"])

        await server.receive(request(2, "tools/call", ["name": "echo", "arguments": ["text": "hi"],
                                                       "_meta": ["progressToken": "tok"]]))
        let call = try await out.response(id: 2)
        #expect(call["result"]?["isError"] == false)
        #expect(call["result"]?["structuredContent"]?["echo"] == "hi")
        #expect(call["result"]?["content"]?.arrayValue?.first?["type"] == "text")

        let progress = out.messages.first { $0["method"] == "notifications/progress" }
        #expect(progress?["params"]?["progressToken"] == "tok")
        #expect(progress?["params"]?["progress"] == 0.5)
    }

    @Test func imagesFollowTheText() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive(request(1, "tools/call", ["name": "picture"]))
        let content = try await out.response(id: 1)["result"]?["content"]?.arrayValue
        #expect(content?.map { $0["type"] } == ["text", "image"])
        #expect(content?.last?["data"] == .string(Data([0xFF, 0xD8, 0xFF]).base64EncodedString()))
        #expect(content?.last?["mimeType"] == "image/jpeg")
    }

    @Test func toolFailuresComeBackAsErrorResults() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive(request(1, "tools/call", ["name": "echo", "arguments": [:]]))
        let r = try await out.response(id: 1)
        #expect(r["result"]?["isError"] == true)
        #expect(r["result"]?["content"]?.arrayValue?.first?["text"] == "text is required")

        await server.receive(request(2, "tools/call", ["name": "nope"]))
        let unknown = try await out.response(id: 2)
        #expect(unknown["error"]?["code"] == -32602)
    }

    @Test func protocolErrors() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive("{not json")
        await server.receive(request(1, "no/such/method"))
        let r = try await out.response(id: 1)
        #expect(r["error"]?["code"] == -32601)
        #expect(out.messages.contains { $0["error"]?["code"] == -32700 })
    }

    @Test func cancelledRequestsGetNoResponse() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive(request(7, "tools/call", ["name": "slow"]))
        await server.receive(JSONValue.object(["jsonrpc": "2.0", "method": "notifications/cancelled",
                                               "params": ["requestId": 7]]).encodedLine())
        await server.receive(request(8, "ping"))
        _ = try await out.response(id: 8)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!out.messages.contains { $0["id"] == 7 })
    }

    @Test func promptsAndResources() async throws {
        let out = Outbox()
        let server = makeServer(out)
        await server.receive(request(1, "prompts/get", ["name": "greet", "arguments": ["who": "Howard"]]))
        let p = try await out.response(id: 1)
        #expect(p["result"]?["messages"]?.arrayValue?.first?["content"]?["text"] == "Hello, Howard!")

        await server.receive(request(2, "prompts/get", ["name": "greet", "arguments": [:]]))
        #expect(try await out.response(id: 2)["error"]?["code"] == -32602)

        await server.receive(request(3, "resources/read", ["uri": "test://settings"]))
        let r = try await out.response(id: 3)
        #expect(r["result"]?["contents"]?.arrayValue?.first?["text"] == "{\"a\":1}")
    }

    @Test func jsonValueRoundTrips() throws {
        let v: JSONValue = ["a": 1, "b": [true, nil, 2.5, "x"], "c": ["d": "e"]]
        #expect(try JSONValue.parse(v.encodedLine()) == v)
        #expect(JSONValue.number(3).encodedLine() == "3")
        #expect(JSONValue.string("12.5").doubleValue == 12.5)
        #expect(JSONValue.number(4).intValue == 4)
        #expect(JSONValue.number(4.5).intValue == nil)
    }
}
