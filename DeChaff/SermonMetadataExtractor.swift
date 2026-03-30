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

// MARK: - Three-tier extraction

private let systemInstructions = """
    You extract structured metadata from church sermon YouTube video titles.

    A common format is: "Title, Bible Reading | Preacher | Series | Date"
    For example: "The Good Shepherd, John 10:1–18 | Rev. James Hart | Foundations Series | 23 Mar 2025"

    Fields are separated by pipe characters (|). Within a segment, a comma often separates the \
    sermon title from the Bible reading. Not all fields are always present — the format is entered \
    by hand and may vary or be incomplete.

    The date segment may appear in various formats (e.g. "23 Mar 2025", "15/3/26", "March 15, 2025"). \
    Always normalise it to "dd MMM yyyy" format (e.g. "23 Mar 2025").

    Only populate fields you are confident about. Use empty string for anything not clearly present. \
    Never invent information.
    """

/// Extracts sermon metadata using a three-tier fallback:
/// 1. On-device Apple Intelligence (FoundationModels)
/// 2. Claude API (if API key is configured)
/// 3. Regex/string parsing
func extractSermonMetadata(from youtubeTitle: String) async -> SermonMetadata? {
    // Tier 1: Apple Intelligence
    if let result = await extractViaAppleIntelligence(from: youtubeTitle) {
        return result
    }

    // Tier 2: Claude API
    if let result = await extractViaClaudeAPI(from: youtubeTitle) {
        return result
    }

    // Tier 3: Regex/string parsing
    return extractViaRegex(from: youtubeTitle)
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

private func extractViaAppleIntelligence(from title: String) async -> SermonMetadata? {
    guard case .available = SystemLanguageModel.default.availability else { return nil }

    let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: systemInstructions
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

private func extractViaClaudeAPI(from title: String) async -> SermonMetadata? {
    guard let keyData = KeychainHelper.load(account: "claude-api-key"),
          let apiKey = String(data: keyData, encoding: .utf8), !apiKey.isEmpty else {
        return nil
    }

    do {
        let response = try await ClaudeAPIClient.sendMessage(
            apiKey: apiKey,
            systemPrompt: systemInstructions + """

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

// MARK: - Tier 3: Regex / string parsing

/// Parses titles in the common format:
///   "Sermon Title, Bible Reading | Preacher | Series | Date"
/// Pipe-delimited segments, with an optional comma separating title from reading in the first segment.
private func extractViaRegex(from title: String) -> SermonMetadata? {
    let segments = title.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !segments.isEmpty else { return nil }

    var sermonTitle = ""
    var bibleReading = ""
    var speaker = ""
    var series = ""
    var date = ""

    // First segment: "Title, Bible Reading" or just "Title"
    let first = segments[0]
    // Look for a Bible reference pattern after a comma: e.g. "Title, John 3:16"
    // Bible ref pattern: optional book number, book name, chapter:verse(s)
    let biblePattern = #",\s*((?:\d\s+)?[A-Z][a-z]+(?:\s[A-Z][a-z]+)*\s+\d+(?:[:\.\-–]\d+)*(?:\s*[\-–]\s*\d+(?:[:\.\-–]\d+)*)?)"#
    if let match = first.range(of: biblePattern, options: .regularExpression) {
        let fullMatch = String(first[match])
        bibleReading = fullMatch.trimmingCharacters(in: .whitespaces)
        if bibleReading.hasPrefix(",") {
            bibleReading = String(bibleReading.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        sermonTitle = String(first[first.startIndex..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
        if sermonTitle.hasSuffix(",") {
            sermonTitle = String(sermonTitle.dropLast()).trimmingCharacters(in: .whitespaces)
        }
    } else if first.contains(",") {
        // Fallback: split on last comma
        let parts = first.components(separatedBy: ",")
        sermonTitle = parts.dropLast().joined(separator: ",").trimmingCharacters(in: .whitespaces)
        bibleReading = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
    } else {
        sermonTitle = first
    }

    // Remaining segments: identify date vs non-date fields
    // Date patterns: "23 Mar 2025", "15 March 2025", "23 Mar 25", "15/3/26", etc.
    let datePattern = #"^\d{1,2}\s+\w+\s+\d{2,4}$|^\d{1,2}/\d{1,2}/\d{2,4}$|^\w+\s+\d{1,2},?\s+\d{4}$"#
    var nonDateSegments: [String] = []
    for segment in segments.dropFirst() where !segment.isEmpty {
        if segment.range(of: datePattern, options: .regularExpression) != nil {
            date = segment
        } else {
            nonDateSegments.append(segment)
        }
    }

    if nonDateSegments.count >= 1 { speaker = nonDateSegments[0] }
    if nonDateSegments.count >= 2 { series = nonDateSegments[1] }

    // Only return if we got at least a title
    guard !sermonTitle.isEmpty else { return nil }

    return SermonMetadata(
        title: sermonTitle,
        bibleReading: bibleReading,
        speaker: speaker,
        series: series,
        date: date
    )
}
