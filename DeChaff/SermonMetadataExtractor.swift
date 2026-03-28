import FoundationModels

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
}

// MARK: - Extraction

/// Extracts sermon metadata from a YouTube title using the on-device language model.
/// Returns nil if Apple Intelligence is unavailable or inference fails.
func extractSermonMetadata(from youtubeTitle: String) async -> SermonMetadata? {
    guard case .available = SystemLanguageModel.default.availability else { return nil }

    let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: """
            You extract structured metadata from church sermon YouTube video titles.

            A common format is: "Title, Bible Reading | Preacher | Series | Date"
            For example: "The Good Shepherd, John 10:1–18 | Rev. James Hart | Foundations Series | 23 Mar 2025"

            Fields are separated by pipe characters (|). Within a segment, a comma often separates the \
            sermon title from the Bible reading. Not all fields are always present — the format is entered \
            by hand and may vary or be incomplete.

            Only populate fields you are confident about. Use empty string for anything not clearly present. \
            Never invent information.
            """
    )

    do {
        let response = try await session.respond(
            to: "Extract sermon metadata from this YouTube title: \"\(youtubeTitle)\"",
            generating: SermonMetadata.self
        )
        return response.content
    } catch {
        return nil
    }
}
