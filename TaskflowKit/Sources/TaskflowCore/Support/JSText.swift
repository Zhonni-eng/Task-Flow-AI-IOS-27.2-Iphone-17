// String helpers with the JavaScript semantics the Windows app's limits and normalization rely on:
// lengths and slices count UTF-16 code units, trim() removes Unicode whitespace, and
// toLocaleLowerCase() is a plain lower-case mapping.
import Foundation

enum JSText {
    /// String.prototype.slice(0, max) by UTF-16 units, never splitting a surrogate pair.
    static func slice(_ text: String, _ max: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > max else { return text }
        var end = max
        if end > 0, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        return String(decoding: units[0..<end], as: UTF16.self)
    }

    static func length(_ text: String) -> Int { text.utf16.count }

    static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func trimEnd(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// text.replace(/\s+/g, ' ')
    static func collapseWhitespace(_ text: String) -> String {
        collapseWhitespace(text) { $0 }
    }

    /// Collapses whitespace runs into one space and maps every other scalar through `map`, in
    /// one pass (search folding uses it to also turn "ё" into "е").
    static func collapseWhitespace(_ text: String, map: (Unicode.Scalar) -> Unicode.Scalar) -> String {
        var result = String.UnicodeScalarView()
        var inSpace = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !inSpace { result.append(" ") }
                inSpace = true
            } else {
                result.append(map(scalar))
                inSpace = false
            }
        }
        return String(result)
    }

    /// CharacterSet.whitespacesAndNewlines membership, without the CharacterSet lookup for ASCII
    /// (tab, LF, VT, FF, CR and space are its only ASCII members).
    @inline(__always)
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 { return scalar.value == 0x20 || (0x09...0x0D).contains(scalar.value) }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func lower(_ text: String) -> String { text.lowercased() }

    /// String.prototype.includes: a plain code-unit substring match (no grapheme or
    /// canonical-equivalence matching, unlike String.contains), on the UTF-8 bytes.
    static func includes(_ text: String, _ part: String) -> Bool {
        if part.isEmpty { return true }
        var text = text, part = part
        return text.withUTF8 { haystack in
            part.withUTF8 { needle in
                guard needle.count <= haystack.count else { return false }
                let first = needle[0]
                var start = 0
                let last = haystack.count - needle.count
                while start <= last {
                    if haystack[start] == first {
                        var offset = 1
                        while offset < needle.count && haystack[start + offset] == needle[offset] { offset += 1 }
                        if offset == needle.count { return true }
                    }
                    start += 1
                }
                return false
            }
        }
    }

    /// String(value) for a JSON value as JavaScript would print it (null/undefined become "").
    static func string(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: return text
        case .number(let number)?:
            if number.isFinite, number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        case .bool(let flag)?: return flag ? "true" : "false"
        default: return ""
        }
    }
}

/// ISO timestamps as written by Date.prototype.toISOString ("2026-11-03T09:30:00.000Z").
public enum ISOTime {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    public static func string(_ date: Date) -> String { fractional.format(date) }

    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = canonicalDate(text) { return date }
        if let date = try? fractional.parse(text) { return date }
        if let date = try? plain.parse(text) { return date }
        // A date-only ISO string is UTC midnight in JavaScript.
        if Schedule.isDateKey(text) { return Schedule.localInstant(text, timeZone: TimeZone(identifier: "UTC")!) }
        return nil
    }

    public static let epoch = "1970-01-01T00:00:00.000Z"

    /// "YYYY-MM-DDTHH:MM:SS.sssZ" - the form `string` writes and nearly every stored timestamp
    /// has - read directly (the format style parser is much slower). Anything else, or a value
    /// out of range, returns nil and goes through the full parser.
    static func canonicalDate(_ text: String) -> Date? {
        guard text.utf8.count == 24 else { return nil }
        let chars = Array(text.utf8)
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90] // - - T : : . Z
        var value = 0
        var numbers: [Int] = []
        for (index, char) in chars.enumerated() {
            if let expected = separators[index] {
                guard char == expected else { return nil }
                numbers.append(value)
                value = 0
            } else {
                guard char >= 48 && char <= 57 else { return nil }
                value = value * 10 + Int(char - 48)
            }
        }
        guard numbers.count == 7 else { return nil }
        let (year, month, day, hour, minute, second, millis) = (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5], numbers[6])
        guard year >= 1, (1...12).contains(month), day >= 1, day <= Schedule.daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        let seconds = Schedule.epochDay(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(seconds) + Double(millis) / 1000)
    }
}
