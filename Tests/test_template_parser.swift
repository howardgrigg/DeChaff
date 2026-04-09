#!/usr/bin/env swift
// Run with: swift Tests/test_template_parser.swift

import Foundation

// MARK: - Parser (copy of SermonMetadataExtractor tier 3)

struct SermonMetadata {
    var title: String
    var bibleReading: String
    var speaker: String
    var series: String
    var date: String
}

func extractViaTemplate(from title: String, format: String) -> SermonMetadata? {
    guard let placeholderRegex = try? NSRegularExpression(pattern: #"\{(\w+)\}"#) else { return nil }

    let matches = placeholderRegex.matches(in: format, range: NSRange(format.startIndex..., in: format))
    guard !matches.isEmpty else { return nil }

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

// MARK: - Test harness

var passed = 0
var failed = 0

func check(
    _ label: String,
    format: String,
    title: String,
    expectedTitle: String = "",
    expectedReading: String = "",
    expectedSpeaker: String = "",
    expectedSeries: String = "",
    expectedDate: String = "",
    expectNil: Bool = false
) {
    let result = extractViaTemplate(from: title, format: format)

    if expectNil {
        if result == nil {
            print("✅ \(label)")
            passed += 1
        } else {
            print("❌ \(label) — expected nil, got \(result!)")
            failed += 1
        }
        return
    }

    guard let r = result else {
        print("❌ \(label) — returned nil")
        failed += 1
        return
    }

    var errors: [String] = []
    if r.title        != expectedTitle   { errors.append("title: got \"\(r.title)\" want \"\(expectedTitle)\"") }
    if r.bibleReading != expectedReading { errors.append("reading: got \"\(r.bibleReading)\" want \"\(expectedReading)\"") }
    if r.speaker      != expectedSpeaker { errors.append("speaker: got \"\(r.speaker)\" want \"\(expectedSpeaker)\"") }
    if r.series       != expectedSeries  { errors.append("series: got \"\(r.series)\" want \"\(expectedSeries)\"") }
    if r.date         != expectedDate    { errors.append("date: got \"\(r.date)\" want \"\(expectedDate)\"") }

    if errors.isEmpty {
        print("✅ \(label)")
        passed += 1
    } else {
        print("❌ \(label)")
        for e in errors { print("     \(e)") }
        failed += 1
    }
}

// MARK: - Tests

// ── Default format ──────────────────────────────────────────────────────────
check(
    "Default format — all fields",
    format: "{title}, {reading} | {preacher} | {series} | {date}",
    title:  "The Good Shepherd, John 10:1–18 | Rev. James Hart | Foundations | 6 Apr 2026",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  "Foundations",
    expectedDate:    "6 Apr 2026"
)

check(
    "Default format — missing date",
    format: "{title}, {reading} | {preacher} | {series} | {date}",
    title:  "Grace Abounding, Romans 5:1–5 | Pastor Mike | Core Series",
    expectedTitle:   "Grace Abounding",
    expectedReading: "Romans 5:1–5",
    expectedSpeaker: "Pastor Mike",
    expectedSeries:  "Core Series",
    expectedDate:    ""
)

check(
    "Default format — missing series and date",
    format: "{title}, {reading} | {preacher} | {series} | {date}",
    title:  "Walking by Faith, Hebrews 11:1 | Dr. Anne Webb",
    expectedTitle:   "Walking by Faith",
    expectedReading: "Hebrews 11:1",
    expectedSpeaker: "Dr. Anne Webb",
    expectedSeries:  "",
    expectedDate:    ""
)

// ── Dash separator ──────────────────────────────────────────────────────────
check(
    "Dash separator — all fields",
    format: "{title} - {reading} - {preacher} - {series}",
    title:  "The Good Shepherd - John 10:1–18 - Rev. James Hart - Foundations",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  "Foundations"
)

check(
    "Dash separator — missing series",
    format: "{title} - {reading} - {preacher} - {series}",
    title:  "The Good Shepherd - John 10:1–18 - Rev. James Hart",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  ""
)

// ── Em dash separator ───────────────────────────────────────────────────────
check(
    "Em dash separator",
    format: "{title} — {preacher} — {series}",
    title:  "The Good Shepherd — Rev. James Hart — Foundations",
    expectedTitle:   "The Good Shepherd",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  "Foundations"
)

// ── Slash separator ─────────────────────────────────────────────────────────
check(
    "Slash separator",
    format: "{preacher} / {title} / {reading}",
    title:  "Rev. James Hart / The Good Shepherd / John 10:1–18",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart"
)

// ── Date first ──────────────────────────────────────────────────────────────
check(
    "Date-first format",
    format: "{date} | {preacher} | {title}, {reading}",
    title:  "6 Apr 2026 | Rev. James Hart | The Good Shepherd, John 10:1–18",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart",
    expectedDate:    "6 Apr 2026"
)

// ── Series prefix ───────────────────────────────────────────────────────────
check(
    "Series colon prefix",
    format: "{series}: {title} | {preacher}",
    title:  "Foundations: The Good Shepherd | Rev. James Hart",
    expectedTitle:   "The Good Shepherd",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  "Foundations"
)

// ── Preacher first ──────────────────────────────────────────────────────────
check(
    "Preacher first, pipe separated",
    format: "{preacher} | {title} | {reading} | {series}",
    title:  "Rev. James Hart | The Good Shepherd | John 10:1–18 | Foundations",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  "Foundations"
)

// ── Title only ──────────────────────────────────────────────────────────────
check(
    "Title only format",
    format: "{title}",
    title:  "The Good Shepherd",
    expectedTitle: "The Good Shepherd"
)

// ── All fields, different date position ─────────────────────────────────────
check(
    "Date between preacher and series",
    format: "{title}, {reading} | {preacher} | {date} | {series}",
    title:  "The Good Shepherd, John 10:1–18 | Rev. James Hart | 6 Apr 2026 | Foundations",
    expectedTitle:   "The Good Shepherd",
    expectedReading: "John 10:1–18",
    expectedSpeaker: "Rev. James Hart",
    expectedSeries:  "Foundations",
    expectedDate:    "6 Apr 2026"
)

// ── Unrecognised format / no match ──────────────────────────────────────────
check(
    "Completely different separator — should not match",
    format: "{title} :: {preacher} :: {series}",
    title:  "The Good Shepherd | Rev. James Hart | Foundations",
    expectNil: true
)

// ── Nil guard — empty result ─────────────────────────────────────────────────
check(
    "Gibberish title against specific format — should return nil",
    format: "{title}, {reading} | {preacher} | {series} | {date}",
    title:  "zz",
    expectNil: true
)

// ── Real-world style titles ──────────────────────────────────────────────────
check(
    "Real-world: City On a Hill style",
    format: "{title}, {reading} | {preacher} | {series} | {date}",
    title:  "The Saving Power of Jesus, Romans 1:16–17 | Howard Grigg | Gospel Foundations | 6 Apr 2026",
    expectedTitle:   "The Saving Power of Jesus",
    expectedReading: "Romans 1:16–17",
    expectedSpeaker: "Howard Grigg",
    expectedSeries:  "Gospel Foundations",
    expectedDate:    "6 Apr 2026"
)

check(
    "Real-world: short title format with date first",
    format: "{date} - {title} - {preacher}",
    title:  "06/04/2026 - The Saving Power of Jesus - Howard Grigg",
    expectedTitle:   "The Saving Power of Jesus",
    expectedSpeaker: "Howard Grigg",
    expectedDate:    "06/04/2026"
)

check(
    "Real-world: no reading or series",
    format: "{preacher} | {title} | {date}",
    title:  "Howard Grigg | The Saving Power of Jesus | 6 Apr 2026",
    expectedTitle:   "The Saving Power of Jesus",
    expectedSpeaker: "Howard Grigg",
    expectedDate:    "6 Apr 2026"
)

// MARK: - Summary

print("\n\(passed + failed) tests: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
