import Foundation

enum ClaudeAPIError: LocalizedError {
    case noAPIKey
    case httpError(Int, String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:                return "No API key configured. Add your Claude API key in Settings → AI Assistant."
        case .httpError(let code, let msg):
            if code == 401 { return "Invalid API key. Check your key in Settings → AI Assistant." }
            if code == 429 { return "Rate limited — try again in a moment." }
            return "API error \(code): \(msg)"
        case .unexpectedResponse:     return "Unexpected response from Claude API."
        }
    }
}

enum ClaudeModel {
    static let knownModels: [(name: String, id: String)] = [
        ("Claude Sonnet 4.6 (recommended)", "claude-sonnet-4-6"),
        ("Claude Haiku 4.5",                "claude-haiku-4-5-20251001"),
        ("Claude Opus 4.6",                 "claude-opus-4-6"),
        ("Claude 3.5 Sonnet",               "claude-3-5-sonnet-20241022"),
        ("Claude 3.5 Haiku",                "claude-3-5-haiku-20241022"),
    ]
    static let defaultID = "claude-sonnet-4-6"
}

enum ClaudeAPIClient {
    static func sendMessage(apiKey: String, model: String, systemPrompt: String, transcript: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model.isEmpty ? ClaudeModel.defaultID : model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": transcript]
            ]
        ]
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
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw ClaudeAPIError.unexpectedResponse
        }
        return text
    }
}
