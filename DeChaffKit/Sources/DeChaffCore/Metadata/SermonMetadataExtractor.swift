import FoundationModels
import Foundation

// MARK: - Structured output schema

@Generable
public struct SermonMetadata: Sendable {
    @Guide(description: "The sermon title or topic. Empty string if not found.")
    public var title: String

    @Guide(description: "Bible reading or passage reference, e.g. 'Romans 8:28' or 'John 10:1–18'. Empty string if not found.")
    public var bibleReading: String

    @Guide(description: "Preacher or speaker name. Empty string if not found.")
    public var speaker: String

    @Guide(description: "Sermon series name. Empty string if not found.")
    public var series: String

    @Guide(description: "Date of the sermon as 'dd MMM yyyy', e.g. '23 Mar 2025'. Empty string if not found.")
    public var date: String

    public init(title: String, bibleReading: String, speaker: String, series: String, date: String) {
        self.title = title
        self.bibleReading = bibleReading
        self.speaker = speaker
        self.series = series
        self.date = date
    }
}

// MARK: - Instructions

/// Builds the system instructions string for metadata extraction, injecting the user's title format.
public func sermonMetadataInstructions(titleFormat: String) -> String {
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

// MARK: - Extraction tiers

/// On-device Apple Intelligence (FoundationModels). Nil when the model is unavailable
/// (not enabled, unsupported Mac, still downloading) or the request fails.
public func extractSermonMetadataOnDevice(from title: String, titleFormat: String) async -> SermonMetadata? {
    guard case .available = SystemLanguageModel.default.availability else { return nil }

    let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: sermonMetadataInstructions(titleFormat: titleFormat)
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

/// Template-aware string parsing — the fallback when no model is available.
public func extractSermonMetadataViaTemplate(from title: String, format: String) -> SermonMetadata? {
    parseSermonTitle(title, format: format).map {
        SermonMetadata(title: $0.title, bibleReading: $0.reading, speaker: $0.preacher,
                       series: $0.series, date: $0.date)
    }
}
