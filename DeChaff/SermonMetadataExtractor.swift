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
/// The template uses {title}, {reading}, {preacher}, {series}, {date} placeholders.
/// Groups are separated by | and fields within a group by the literal separator in the template.
private func extractViaTemplate(from title: String, format: String) -> SermonMetadata? {
    // Split template and title on pipe
    let templateGroups = format.components(separatedBy: "|")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let titleGroups = title.components(separatedBy: "|")
        .map { $0.trimmingCharacters(in: .whitespaces) }

    var values: [String: String] = [:]

    for (i, templateGroup) in templateGroups.enumerated() {
        guard i < titleGroups.count else { break }
        let segment = titleGroups[i]
        let fields = placeholders(in: templateGroup)
        guard !fields.isEmpty else { continue }

        if fields.count == 1 {
            values[fields[0]] = segment
        } else {
            // Derive the separator between the first two fields from the template
            let sep = separator(in: templateGroup, between: fields[0], and: fields[1])
            let parts = segment.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for (j, field) in fields.enumerated() {
                values[field] = j < parts.count ? parts[j] : ""
            }
        }
    }

    guard !values.isEmpty,
          !(values["title"] ?? "").isEmpty || !(values["preacher"] ?? "").isEmpty else {
        return nil
    }

    return SermonMetadata(
        title:        values["title"]    ?? "",
        bibleReading: values["reading"]  ?? "",
        speaker:      values["preacher"] ?? "",
        series:       values["series"]   ?? "",
        date:         values["date"]     ?? ""
    )
}

/// Returns the ordered list of placeholder names (without braces) in a template string.
private func placeholders(in template: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"\{(\w+)\}"#) else { return [] }
    return regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        .compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: template) else { return nil }
            return String(template[range])
        }
}

/// Finds the literal separator text between two named placeholders in a template string.
private func separator(in template: String, between first: String, and second: String) -> String {
    let pattern = #"\{\#(first)\}(.+?)\{\#(second)\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)),
          let range = Range(match.range(at: 1), in: template) else {
        return ","
    }
    let sep = String(template[range]).trimmingCharacters(in: .whitespaces)
    return sep.isEmpty ? "," : sep
}
