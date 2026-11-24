import Foundation

/// Parses the date formats feeds use in practice: RFC 822 for RSS (with its
/// many variations) and RFC 3339 / ISO 8601 for Atom and Dublin Core.
///
/// Not thread-safe; create one per parse.
final class FeedDates {
    private let rfc822: [DateFormatter]
    private let iso: ISO8601DateFormatter
    private let isoFractional: ISO8601DateFormatter

    init() {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy",
        ]
        rfc822 = formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            return f
        }
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.first?.isNumber == true, s.contains("T") || s.count == 10 {
            if let d = isoFractional.date(from: s) ?? iso.date(from: s) { return d }
            if s.count == 10, let d = iso.date(from: s + "T00:00:00Z") { return d }
            // ISO without a zone, e.g. "2026-11-24T10:00:00": assume UTC.
            if let d = iso.date(from: s + "Z") { return d }
        }
        // "UT" is valid RFC 822 but DateFormatter doesn't know it.
        var normalized = s
        if normalized.hasSuffix(" UT") { normalized = String(normalized.dropLast(3)) + " GMT" }
        for f in rfc822 {
            if let d = f.date(from: normalized) { return d }
        }
        return nil
    }
}
