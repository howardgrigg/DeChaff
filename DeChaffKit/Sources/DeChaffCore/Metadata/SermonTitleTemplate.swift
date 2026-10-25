import Foundation

// MARK: - Defaults

public let defaultTitleFormat    = "{title}, {reading} | {preacher} | {series} | {date}"
public let defaultFilenameTemplate = "{date} {title}, {reading} | {preacher} | {series}"

// MARK: - Parsed fields

/// Sermon fields pulled out of a video title. Empty strings mean "not found".
public struct ParsedSermonTitle: Sendable, Equatable {
    public var title: String
    public var reading: String
    public var preacher: String
    public var series: String
    public var date: String

    public init(title: String = "", reading: String = "", preacher: String = "",
                series: String = "", date: String = "") {
        self.title = title
        self.reading = reading
        self.preacher = preacher
        self.series = series
        self.date = date
    }
}

// MARK: - Template-aware parsing

/// Parses a video title using the user-defined format template.
/// Converts the template into a regex by escaping its literal parts and replacing each
/// {placeholder} with a capture group — so any separator the user configures is matched exactly,
/// with no assumptions about | or any other delimiter.
public func parseSermonTitle(_ title: String, format: String) -> ParsedSermonTitle? {
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
            regexParts.append(separatorPattern(seg.literal))
            regexParts.append(i == used.count - 1 ? "(.+)" : "(.+?)")
        }
        if count == segments.count {
            regexParts.append(separatorPattern(trailingLiteral))
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

        return ParsedSermonTitle(
            title:    values["title"]    ?? "",
            reading:  values["reading"]  ?? "",
            preacher: values["preacher"] ?? "",
            series:   values["series"]   ?? "",
            date:     values["date"]     ?? ""
        )
    }

    return nil
}

/// A template's literal text as a regex that tolerates any spacing around it, since
/// titles are typed by hand: " | " also matches "Gospel| 25/10" and "Gospel  |25/10".
private func separatorPattern(_ literal: String) -> String {
    let words = literal.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
    if words.isEmpty { return literal.isEmpty ? "" : #"\s+"# }
    return #"\s*"# + words.joined(separator: #"\s+"#) + #"\s*"#
}

// MARK: - Dates

/// Parses a date string from metadata extraction into a Date.
/// Handles formats like "23 Mar 2025", "15 March 2025", "23 Mar 25".
public func parseExtractedDate(_ raw: String) -> Date? {
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

/// Parses a yt-dlp upload date string like "20240317" into a Date, or nil if unparseable.
/// Uses the local calendar at noon so DatePicker shows the correct day regardless of timezone.
public func parseYouTubeUploadDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 8,
          let year  = Int(trimmed.prefix(4)),
          let month = Int(trimmed.dropFirst(4).prefix(2)), (1...12).contains(month),
          let day   = Int(trimmed.suffix(2)), (1...31).contains(day) else { return nil }
    return Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
}
