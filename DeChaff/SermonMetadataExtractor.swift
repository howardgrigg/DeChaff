import FoundationModels
import Foundation
import DeChaffCore

// MARK: - Structured output schema

@Generable
struct SermonMetadata {
    @Guide(description: "The sermon title or topic. Empty string if not found.")
    var title: String

    @Guide(description: "Bible reading or passage reference, e.g. 'Romans 8:28' or 'John 10:1–18'. Empty string if not found.")
    var bibleReading: String

    @Guide(description: "Preacher or speaker name. Empty string if not found.")
    var speaker: String

    @Guide(description: "Sermon series name. Empty string if not found.")
    var series: String

    @Guide(description: "Date of the sermon as 'dd MMM yyyy', e.g. '23 Mar 2025'. Empty string if not found.")
    var date: String
}

// MARK: - Three-tier extraction

/// Builds the system instructions string for metadata extraction, injecting the user's title format.
private func systemInstructions(titleFormat: String) -> String {
    """
    You extract structured metadata from church sermon YouTube video titles.

    The expected format for this church is: "\(titleFormat)"
    where {title} is the sermon title or topic, {reading} is the Bible reading or passage, \
    {preacher} is the speaker or preacher name, {series} is the sermon series name, \
    and {date} is the date of the sermon.

    Fields may be separated by pipe characters (|), commas, dashes, or other delimiters \
    as shown in the format above. Not all fields are always present — the format is entered \
    by hand and may vary or be incomplete.

    The date may appear in various formats (e.g. "23 Mar 2025", "15/3/26", "March 15, 2025"). \
    Always normalise it to "dd MMM yyyy" format (e.g. "23 Mar 2025").

    Only populate fields you are confident about. Use empty string for anything not clearly present. \
    Never invent information.
    """
}

/// Extracts sermon metadata using a three-tier fallback:
/// 1. On-device Apple Intelligence (FoundationModels)
/// 2. Claude API (if API key is configured)
/// 3. Template-aware string parsing
func extractSermonMetadata(from youtubeTitle: String, titleFormat: String = defaultTitleFormat) async -> SermonMetadata? {
    // Tier 1: Apple Intelligence
    if let result = await extractViaAppleIntelligence(from: youtubeTitle, titleFormat: titleFormat) {
        return result
    }

    // Tier 2: Claude API
    if let result = await extractViaClaudeAPI(from: youtubeTitle, titleFormat: titleFormat) {
        return result
    }

    // Tier 3: Template-aware parsing
    return extractViaTemplate(from: youtubeTitle, format: titleFormat)
}

// MARK: - Tier 1: Apple Intelligence

private func extractViaAppleIntelligence(from title: String, titleFormat: String) async -> SermonMetadata? {
    guard case .available = SystemLanguageModel.default.availability else { return nil }

    let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: systemInstructions(titleFormat: titleFormat)
    )

    do {
        let response = try await session.respond(
            to: "Extract sermon metadata from this YouTube title: \"\(title)\"",
            generating: SermonMetadata.self
        )
        return response.content
    } catch {
        return nil
    }
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
            systemPrompt: systemInstructions(titleFormat: titleFormat) + """

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

// MARK: - Tier 3: Template-aware string parsing

private func extractViaTemplate(from title: String, format: String) -> SermonMetadata? {
    parseSermonTitle(title, format: format).map {
        SermonMetadata(title: $0.title, bibleReading: $0.reading, speaker: $0.preacher,
                       series: $0.series, date: $0.date)
    }
}
