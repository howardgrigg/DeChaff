import Foundation
import DeChaffCore

// MARK: - Three-tier extraction

/// Extracts sermon metadata using a three-tier fallback:
/// 1. On-device Apple Intelligence (FoundationModels)
/// 2. Claude API (if API key is configured)
/// 3. Template-aware string parsing
/// Tiers 1 and 3 live in DeChaffCore so the MCP server shares them.
func extractSermonMetadata(from youtubeTitle: String, titleFormat: String = defaultTitleFormat) async -> SermonMetadata? {
    // Tier 1: Apple Intelligence
    if let result = await extractSermonMetadataOnDevice(from: youtubeTitle, titleFormat: titleFormat) {
        return result
    }

    // Tier 2: Claude API
    if let result = await extractViaClaudeAPI(from: youtubeTitle, titleFormat: titleFormat) {
        return result
    }

    // Tier 3: Template-aware parsing
    return extractSermonMetadataViaTemplate(from: youtubeTitle, format: titleFormat)
}

// MARK: - Tier 2: Claude API

private func extractViaClaudeAPI(from title: String, titleFormat: String) async -> SermonMetadata? {
    guard let keyData = KeychainHelper.load(account: "claude-api-key"),
          let apiKey = String(data: keyData, encoding: .utf8), !apiKey.isEmpty else {
        return nil
    }

    do {
        let model = UserDefaults.standard.string(forKey: "dechaff.ai.model") ?? ClaudeModel.defaultID
        let response = try await ClaudeAPIClient.sendMessage(
            apiKey: apiKey,
            model: model,
            systemPrompt: sermonMetadataInstructions(titleFormat: titleFormat) + """

                Respond with ONLY a JSON object, no markdown fencing, no explanation:
                {"title": "...", "bibleReading": "...", "speaker": "...", "series": "...", "date": "..."}
                Use empty string for any field not found. Format the date as "dd MMM yyyy".
                """,
            transcript: "Extract sermon metadata from this YouTube title: \"\(title)\""
        )

        guard let data = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }

        return SermonMetadata(
            title: json["title"] ?? "",
            bibleReading: json["bibleReading"] ?? "",
            speaker: json["speaker"] ?? "",
            series: json["series"] ?? "",
            date: json["date"] ?? ""
        )
    } catch {
        return nil
    }
}
