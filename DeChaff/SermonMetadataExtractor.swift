import FoundationModels
import Foundation

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

// MARK: - Defaults

let defaultTitleFormat    = "{title}, {reading} | {preacher} | {series} | {date}"
let defaultFilenameTemplate = "{date} {title}, {reading} | {preacher} | {series}"

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

/// Parses a date string from metadata extraction into a Date.
/// Handles formats like "23 Mar 2025", "15 March 2025", "23 Mar 25".
func parseExtractedDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")

    // Try common formats
    for format in ["d MMM yyyy", "dd MMM yyyy", "d MMMM yyyy", "dd MMMM yyyy",
                    "d MMM yy", "dd MMM yy", "d/M/yy", "d/M/yyyy",
                    "MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            // Set to noon local to avoid timezone date-shift issues in DatePicker
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return Calendar.current.date(from: DateComponents(
                year: comps.year, month: comps.month, day: comps.day, hour: 12
            ))
        }
    }
    return nil
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

/// Parses a YouTube title using the user-defined format template.
/// Converts the template into a regex by escaping its literal parts and replacing each
/// {placeholder} with a capture group — so any separator the user configures is matched exactly,
/// with no assumptions about | or any other delimiter.
private func extractViaTemplate(from title: String, format: String) -> SermonMetadata? {
    guard let placeholderRegex = try? NSRegularExpression(pattern: #"\{(\w+)\}"#) else { return nil }

    let matches = placeholderRegex.matches(in: format, range: NSRange(format.startIndex..., in: format))
    guard !matches.isEmpty else { return nil }

    // Build segments: each holds the literal text immediately before it and its field name.
    struct Segment { let literal: String; let field: String }
    var segments: [Segment] = []
    var lastEnd = format.startIndex

    for match in matches {
        let matchRange = Range(match.range, in: format)!
        let fieldRange = Range(match.range(at: 1), in: format)!
        segments.append(Segment(
            literal: String(format[lastEnd..<matchRange.lowerBound]),
            field:   String(format[fieldRange])
        ))
        lastEnd = matchRange.upperBound
    }
    let trailingLiteral = String(format[lastEnd...])

    // Try matching with all segments, then progressively fewer trailing ones.
    // Require at least 2 matching fields (or 1 if the template itself only has 1).
    let minCount = min(2, segments.count)
    for count in (minCount...segments.count).reversed() {
        let used = Array(segments.prefix(count))

        var regexParts: [String] = []
        for (i, seg) in used.enumerated() {
            if !seg.literal.isEmpty {
                regexParts.append(NSRegularExpression.escapedPattern(for: seg.literal))
            }
            regexParts.append(i == used.count - 1 ? "(.+)" : "(.+?)")
        }
        if count == segments.count && !trailingLiteral.isEmpty {
            regexParts.append(NSRegularExpression.escapedPattern(for: trailingLiteral))
        }

        let pattern = "^" + regexParts.joined() + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else {
            continue
        }

        var values: [String: String] = [:]
        for (i, seg) in used.enumerated() {
            if let range = Range(match.range(at: i + 1), in: title) {
                values[seg.field] = String(title[range]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard !(values["title"] ?? "").isEmpty || !(values["preacher"] ?? "").isEmpty else {
            continue
        }

        return SermonMetadata(
            title:        values["title"]    ?? "",
            bibleReading: values["reading"]  ?? "",
            speaker:      values["preacher"] ?? "",
            series:       values["series"]   ?? "",
            date:         values["date"]     ?? ""
        )
    }

    return nil
}
