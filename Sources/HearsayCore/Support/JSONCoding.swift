import Foundation

/// ISO 8601 with fractional seconds on write; accepts with or without fractions on read.
enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let seconds = try? c.decode(Double.self) { return millisecondRounded(Date(timeIntervalSince1970: seconds)) }
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }

    /// Formats whole milliseconds computed here: the system formatter truncates fractions, so a parsed
    /// `.456` stored as `.45599...` would write back as `.455` and drift on every round trip.
    static func formatDate(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (sec, frac) = ms.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(frac < 0 ? sec - 1 : sec))
        let base = whole.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        return base.dropLast() + String(format: ".%03dZ", frac < 0 ? frac + 1000 : frac)
    }

    /// Parses ISO 8601 with or without fractions; rounds to whole milliseconds so writes and reads agree.
    static func parseDate(_ s: String) -> Date? {
        let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
        return parsed.map(millisecondRounded)
    }

    static func millisecondRounded(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
