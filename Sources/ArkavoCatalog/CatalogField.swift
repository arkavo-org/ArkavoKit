import Foundation

/// The field rules every catalog format shares, as tdf-iroh-s3's `docs/creator-catalogs.md` states them. Text is
/// checked as UTF-8 bytes, never with `String ==`, which would accept canonically equivalent text.
public enum CatalogField {
    public static let maxSubjectBytes = 248
    public static let maxContentIDBytes = 256
    /// 2^53 − 1, the largest integer every JSON reader holds exactly.
    public static let maxVersion: UInt64 = 9_007_199_254_740_991
    /// 4 GiB − 1, the viewer's limit.
    public static let maxPayloadSize: UInt64 = 4_294_967_295
    public static let maxTitleBytes = 512
    public static let maxAttributeFQNs = 32
    public static let maxAttributeFQNBytes = 512

    /// A creator's `sub`: 1–248 bytes of `[A-Za-z0-9:._@-]`, not `.` and not containing `..`.
    public static func isValidSubject(_ value: String) -> Bool {
        isIdentifier(value, maxBytes: maxSubjectBytes)
    }

    /// 1–256 bytes of `[A-Za-z0-9:._@-]`, not `.` and not containing `..`.
    public static func isValidContentID(_ value: String) -> Bool {
        isIdentifier(value, maxBytes: maxContentIDBytes)
    }

    /// A BLAKE3 or SHA-256 digest as the contracts write it: exactly 64 lowercase hex characters.
    public static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// 1–512 UTF-8 bytes.
    public static func isValidTitle(_ value: String) -> Bool {
        (1...maxTitleBytes).contains(value.utf8.count)
    }

    /// `title` cut at a character boundary to `maxTitleBytes`, or nil when nothing is left.
    public static func truncatedTitle(_ title: String) -> String? {
        var result = ""
        var bytes = 0
        for character in title {
            let size = character.utf8.count
            guard bytes + size <= maxTitleBytes else { break }
            result.append(character)
            bytes += size
        }
        return result.isEmpty ? nil : result
    }

    /// A policy attribute as a catalog lists it, for display; it grants nothing. At most 512 bytes, all visible ASCII
    /// (0x21–0x7E), the literal `https://`, then a host.
    ///
    /// The node parses the URL with the WHATWG rules and requires a non-empty host. This check is a strict subset of
    /// that, so anything it accepts the node accepts: the authority, up to the first `/`, `?`, `#` or `\`, is a host of
    /// dot-separated labels of `[A-Za-z0-9_-]`, with no userinfo, no IP literal in brackets, no percent escape and no
    /// `xn--` label (the parser would check its Punycode), and an optional port of at most 65535. A host whose last label
    /// is a number (digits, or `0x` and hex digits) must be a dotted-quad IPv4 address, since the parser reads any such
    /// host as one.
    public static func isAttributeFQN(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array("https://".utf8)
        guard bytes.count <= maxAttributeFQNBytes, bytes.allSatisfy({ (0x21...0x7E).contains($0) }),
              bytes.starts(with: prefix) else { return false }
        let rest = bytes.dropFirst(prefix.count)
        let authority = rest.prefix { !"/?#\\".utf8.contains($0) }
        var host = authority[...]
        if let colon = authority.firstIndex(of: UInt8(ascii: ":")) {
            host = authority[..<colon]
            let port = authority[authority.index(after: colon)...]
            // An empty port is allowed, as the WHATWG parser allows it.
            guard port.count <= 5, port.allSatisfy(isDigit), port.isEmpty || Int(String(decoding: port, as: UTF8.self))! <= 65_535
            else { return false }
        }
        let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard !host.isEmpty, labels.allSatisfy({ label in
            !label.isEmpty && !label.map({ isLetter($0) ? $0 | 0x20 : $0 }).starts(with: "xn--".utf8)
                && label.allSatisfy { isDigit($0) || isLetter($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
        }) else { return false }
        guard let last = labels.last, isNumber(last) else { return true }
        return labels.count == 4 && labels.allSatisfy { label in
            label.allSatisfy(isDigit) && label.count <= 3 && (label.count == 1 || label.first != UInt8(ascii: "0"))
                && Int(String(decoding: label, as: UTF8.self))! <= 255
        }
    }

    // MARK: Integers

    /// A JSON integer's text: digits only, without a sign, fraction, exponent or leading zero; nil when it does not fit
    /// 64 bits.
    static func integer(_ text: String) -> UInt64? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy(isDigit), bytes.count == 1 || bytes[0] != UInt8(ascii: "0") else {
            return nil
        }
        return UInt64(text)
    }

    static func integer(_ value: StrictJSON?, in range: ClosedRange<UInt64>) -> UInt64? {
        guard case .number(let text)? = value, let integer = integer(text), range.contains(integer) else { return nil }
        return integer
    }

    // MARK: Timestamps

    /// Exactly `YYYY-MM-DDTHH:MM:SSZ`: a real proleptic-Gregorian date, hours 00–23, minutes and seconds 00–59, UTC. No
    /// fraction, offset, lowercase letter or leap second.
    public static func timestamp(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 20, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              bytes[19] == UInt8(ascii: "Z") else { return nil }
        func field(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard isDigit(bytes[index]) else { return nil }
                value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = field(0..<4), let month = field(5..<7), let day = field(8..<10), let hour = field(11..<13),
              let minute = field(14..<16), let second = field(17..<19),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    /// `date`, rounded down to the second, as `YYYY-MM-DDTHH:MM:SSZ`; nil outside the years 0000–9999.
    public static func timestamp(_ date: Date) -> String? {
        // 0000-01-01T00:00:00Z to 9999-12-31T23:59:59Z; checked before the conversion to Int, which traps when the
        // interval is not finite or does not fit.
        let interval = date.timeIntervalSince1970.rounded(.down)
        guard interval.isFinite, (-62_167_219_200...253_402_300_799).contains(interval) else { return nil }
        let seconds = Int(interval)
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let time = seconds - days * 86_400
        let (year, month, day) = civilFromDays(days)
        guard (0...9_999).contains(year) else { return nil }
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(time / 3_600, 2)):\(pad(time % 3_600 / 60, 2)):"
            + "\(pad(time % 60, 2))Z"
    }

    // MARK: Helpers

    private static func isIdentifier(_ value: String, maxBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maxBytes).contains(bytes.count), bytes != [UInt8(ascii: ".")],
              !zip(bytes, bytes.dropFirst()).contains(where: { $0 == UInt8(ascii: ".") && $1 == UInt8(ascii: ".") })
        else { return false }
        return bytes.allSatisfy { isDigit($0) || isLetter($0) || ":._@-".utf8.contains($0) }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The WHATWG host parser's "ends in a number" test for one label: all digits, or `0x` or `0X` and hex digits.
    private static func isNumber(_ label: ArraySlice<UInt8>) -> Bool {
        if label.allSatisfy(isDigit) { return true }
        let rest = label.dropFirst(2)
        return label.count >= 2 && label.first == UInt8(ascii: "0")
            && (label[label.index(after: label.startIndex)] | 0x20) == UInt8(ascii: "x")
            && rest.allSatisfy { isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0 | 0x20) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days from 1970-01-01 to a proleptic-Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `daysFromCivil` (Howard Hinnant's `civil_from_days`).
    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
