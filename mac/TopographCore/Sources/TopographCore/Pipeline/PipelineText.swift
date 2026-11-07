import CryptoKit
import Foundation

/// The small helpers in pipeline/topograph/util.py: text repair, dates and platform ids.
public enum PipelineText {
    public static func fixMojibake(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 >= 0x80 }) else { return text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            guard scalar.value < 256 else { return text }
            bytes.append(UInt8(scalar.value))
        }
        return String(bytes: bytes, encoding: .utf8) ?? text
    }

    /// The characters Python's `str.strip()` removes.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    public static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, isSpace(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isSpace(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    public static func clean(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let stripped = strip(text)
        return stripped.isEmpty ? nil : stripped
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let unavailable = regex(
        #"\{learnmore\}|^\s*(you[’']re unable to view this (post|tweet)|this (post|tweet) (is from a suspended account|was deleted|is unavailable|has been deleted|is from an account that no longer exists|violated|has been withheld|is no longer available))"#,
        .caseInsensitive)

    /// X's notice in place of a post that's gone, not anything you engaged with.
    public static func isUnavailable(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return unavailable.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let linksAndMentions = regex(#"https?://\S+|www\.\S+|(?<!\w)@\w+"#)
    private static let notWord = regex(#"\W+"#)

    /// Whether text says anything beyond links and @mentions.
    public static func hasWords(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let rest = linksAndMentions.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let bare = notWord.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "")
        return bare.unicodeScalars.count >= 3
    }

    static func firstGroups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    public static let minTime = 1_104_537_600   // 2005-01-01
    public static let maxTime = 2_208_988_800   // 2040-01-01

    public static func plausibleTime(_ value: JSONValue?) -> Int? {
        guard let number = value?.number, number >= Double(minTime), number <= Double(maxTime) else { return nil }
        return Int(number)
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let twitterDate = regex(#"^[A-Za-z]{3} ([A-Za-z]{3}) (\d{1,2}) (\d{2}):(\d{2}):(\d{2}) ([+-]\d{4}) (\d{4})$"#)
    private static let mailDate = regex(#"^(?:[A-Za-z]{3}, )?(\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2})(?::(\d{2}))? ?([+-]\d{4}|GMT|UTC)?$"#)

    private static func seconds(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, offset: Int?) -> Int? {
        guard (1...12).contains(month), (1...31).contains(day), hour < 25, minute < 60, second < 62 else { return nil }
        var parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        var calendar = Calendar(identifier: .gregorian)
        // A time with no zone is local, the same as Python's `datetime`.
        calendar.timeZone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        guard parts.isValidDate, let date = calendar.date(from: parts) else { return nil }
        return Int(date.timeIntervalSince1970.rounded(.down))
    }

    private static func zoneOffset(_ text: String?) -> Int? {
        guard let text, let first = text.first else { return nil }
        if text == "GMT" || text == "UTC" || text == "Z" { return 0 }
        let digits = text.dropFirst().filter(\.isNumber)
        guard first == "+" || first == "-", digits.count >= 2 else { return nil }
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.dropFirst(2).prefix(2)) ?? 0
        return (first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// 'Wed Jul 03 14:23:01 +0000 2024', a mail-style date or an ISO one, to unix seconds.
    public static func parseTwitterDate(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        if let groups = firstGroups(twitterDate, text), let month = months[groups[1]!.lowercased()] {
            return seconds(Int(groups[7]!)!, month, Int(groups[2]!)!, Int(groups[3]!)!, Int(groups[4]!)!, Int(groups[5]!)!, offset: zoneOffset(groups[6]))
        }
        if let groups = firstGroups(mailDate, text), let month = months[groups[2]!.lowercased()] {
            return seconds(Int(groups[3]!)!, month, Int(groups[1]!)!, Int(groups[4]!)!, Int(groups[5]!)!, Int(groups[6] ?? "0")!, offset: zoneOffset(groups[7]))
        }
        return isoTime(text.replacingOccurrences(of: "Z", with: "+00:00"))
    }

    private static let isoPattern = regex(#"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?)?\s*([+-]\d{2}(?::?\d{2})?)?$"#)

    /// `datetime.fromisoformat(...).timestamp()`, whole seconds.
    public static func isoTime(_ text: String) -> Int? {
        guard let groups = firstGroups(isoPattern, text) else { return nil }
        return seconds(Int(groups[1]!)!, Int(groups[2]!)!, Int(groups[3]!)!, Int(groups[4] ?? "0")!, Int(groups[5] ?? "0")!, Int(groups[6] ?? "0")!, offset: zoneOffset(groups[7]))
    }

    /// Takeout's ISO times, with or without fractions, and its `+00:00` style.
    public static func takeoutTime(_ value: String?) -> Int {
        guard let value, !value.isEmpty else { return 0 }
        let text = strip(value).replacingOccurrences(of: "Z", with: "+00:00").replacingOccurrences(of: " UTC", with: "+00:00")
        return isoTime(text) ?? 0
    }

    /// X and Twitter ids since late 2010 hold their creation time.
    public static func snowflakeTime(_ id: String) -> Int? {
        guard let number = UInt64(id), number > 1 << 32 else { return nil }
        let time = (Int(number >> 22) + 1_288_834_974_657) / 1000
        return (minTime...maxTime).contains(time) ? time : nil
    }

    private static let alphabet: [UInt8: UInt64] = {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var out: [UInt8: UInt64] = [:]
        for (index, byte) in letters.utf8.enumerated() { out[byte] = UInt64(index) }
        return out
    }()

    /// Instagram media ids run in time order, so a shortcode gives a rough date.
    public static func instagramShortcodeTime(_ code: String) -> Int? {
        var number: UInt64 = 0
        for byte in code.utf8.prefix(11) {
            guard let digit = alphabet[byte] else { return nil }
            // Too large for 64 bits is far past any plausible date.
            let (product, overflowed) = number.multipliedReportingOverflow(by: 64)
            guard !overflowed else { return nil }
            number = product + digit
        }
        let time = (Int(number >> 23) + 1_314_220_021_721) / 1000
        return (minTime...maxTime).contains(time) ? time : nil
    }

    private static let instagramURL = regex(#"instagram\.com/(?:[A-Za-z0-9_.]+/)?(p|reel|reels|tv)/([A-Za-z0-9_-]+)"#)

    public static func instagramShortcode(_ url: String?) -> String? {
        guard let url, let groups = firstGroups(instagramURL, url) else { return nil }
        return groups[2]
    }

    public static let videoExtensions: Set<String> = [".mp4", ".mov", ".m4v", ".webm"]
    public static let imageExtensions: Set<String> = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"]

    /// The extension with its dot, lowercased, or nothing, as `PurePosixPath.suffix` has it.
    public static func suffix(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex, last.index(after: dot) != last.endIndex else { return "" }
        return last[dot...].lowercased()
    }

    public static func stem(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        let suffix = suffix(last)
        return suffix.isEmpty ? last : String(last.dropLast(suffix.count))
    }

    public static func sha1Prefix(_ text: String, _ length: Int = 16) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length).description
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
