import Foundation

enum ClaudeAPIError: LocalizedError {
    case noAPIKey
    case httpError(Int, String)
    case unexpectedResponse
    case refused(String?)
    case truncated

    var errorDescription: String? {
        switch self {
        case .noAPIKey:                return "No API key configured. Add your Claude API key in Settings → AI Assistant."
        case .httpError(let code, let msg):
            if code == 401 { return "Invalid API key. Check your key in Settings → AI Assistant." }
            if code == 429 { return "Rate limited — try again in a moment." }
            return "API error \(code): \(msg)"
        case .unexpectedResponse:     return "Unexpected response from Claude API."
        case .refused(let category):
            return "Claude declined this request\(category.map { " (\($0))" } ?? ""). Try again, or choose a different model in Settings → AI Assistant."
        case .truncated:              return "Claude's reply was cut off before it finished. Try again."
        }
    }
}

enum ClaudeModel {
    static let knownModels: [(name: String, id: String)] = [
        ("Claude Opus 5.5 (recommended)",   "claude-opus-5-5"),
        ("Claude Sonnet 5.5",               "claude-sonnet-5-5"),
        ("Claude Haiku 5.5 (fastest)",      "claude-haiku-5-5"),
        ("Claude Fable 5.1 (most capable)", "claude-fable-5-1"),
        ("Claude Opus 4.6",                 "claude-opus-4-6"),
        ("Claude Sonnet 4.6",               "claude-sonnet-4-6"),
    ]
    static let defaultID = "claude-opus-5-5"

    /// Models that accept server-side `fallbacks: "default"`, which re-runs a request a
    /// safety classifier declined on another model instead of returning the refusal.
    /// Haiku 5.5 has no fallback and older models reject the parameter.
    static let supportsDefaultFallback: Set<String> = [
        "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1",
    ]
}

enum ClaudeAPIClient {
    static func sendMessage(apiKey: String, model: String, systemPrompt: String, transcript: String) async throws -> String {
        let model = model.isEmpty ? ClaudeModel.defaultID : model
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A full sermon transcript with thinking can take well over URLSession's 60 s default.
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            // Current models think before answering, and thinking counts towards this cap.
            "max_tokens": 16000,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": transcript]
            ]
        ]
        if ClaudeModel.supportsDefaultFallback.contains(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
                .flatMap { ($0 as? [String: Any])?["message"] as? String }
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw ClaudeAPIError.httpError(statusCode, errorMsg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClaudeAPIError.unexpectedResponse
        }
        switch json["stop_reason"] as? String {
        case "refusal":
            throw ClaudeAPIError.refused((json["stop_details"] as? [String: Any])?["category"] as? String)
        case "max_tokens":
            throw ClaudeAPIError.truncated
        default:
            break
        }
        // The reply can open with thinking blocks (which carry no text), so join the text blocks.
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClaudeAPIError.unexpectedResponse }
        return text
    }
}
