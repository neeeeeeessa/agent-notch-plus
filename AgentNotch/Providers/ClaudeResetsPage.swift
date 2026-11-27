import Foundation

/// Claude's banked limit resets as last read from claude.ai's usage page.
///
/// Anthropic's usage API withholds resets from third-party clients (`cedar_ember` answers
/// `reason=surface`), so a scheduled browser check outside this app copies the page's
/// "Limit resets" text into a local file. This app never opens claude.ai and never sees
/// the browser's sign-in; it only parses that text. See `Scripts/claude-resets-capture.py`.
nonisolated enum ClaudeResetsPage {
    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/agent-notch-plus/claude-resets.json")
    }

    /// Older captures are ignored rather than shown.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maxBytes = 64 * 1024

    private struct Capture: Decodable {
        let version: Int
        let checkedAt: Date
        let text: String
    }

    /// Reads the capture file. nil when it is missing, unsafe, malformed or too old.
    static func load(from url: URL = fileURL, now: Date = Date()) -> ResetCredits? {
        guard let data = readOwnedFile(url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let capture = try? decoder.decode(Capture.self, from: data), capture.version == 1,
              capture.checkedAt <= now.addingTimeInterval(300),
              now.timeIntervalSince(capture.checkedAt) <= maxAge else { return nil }
        return parse(capture.text, checkedAt: capture.checkedAt)
    }

    /// A regular file owned by this user, not writable by others, not a symlink, at most `maxBytes`.
    private static func readOwnedFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0, info.st_size <= maxBytes else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }

    /// Parses the page's "Limit resets" section, e.g.
    ///
    ///     Limit resets
    ///     4 available
    ///     Full reset
    ///     Expires Dec 10, 11:00 PM GMT+1
    ///     Fable reset · 3
    ///     All expire Mar 9, 2027, 8:59 AM GMT+1
    ///
    /// nil when the section or its count is missing, so a changed page reads as "Not available", never as zero.
    static func parse(_ text: String, checkedAt: Date) -> ResetCredits? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let start = lines.firstIndex(of: "Limit resets") else { return nil }
        var available: Int?
        var items: [ResetCredit] = []
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("Last updated") || line == "Usage credits" { break }
            if available == nil, let count = availableCount(line) {
                available = count
            } else if index + 1 < lines.count, let expiry = expiryText(lines[index + 1]) {
                let (label, count) = labelAndCount(line)
                let expiresAt = parseDate(expiry, reference: checkedAt)
                items.append(ResetCredit(id: "claude-page-\(items.count)-\(label)", label: label,
                                         expiresAt: expiresAt, count: count))
                index += 1
            }
            index += 1
        }
        guard let available else { return nil }
        items.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        // Rows that disagree with the headline count are dropped so the count stays the page's own.
        let listed = items.reduce(0) { $0 + $1.count }
        return ResetCredits(availableCount: available, items: listed == available ? items : [], checkedAt: checkedAt)
    }

    private static func availableCount(_ line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count == 2, parts[1] == "available" else { return nil }
        return parts[0] == "No" ? 0 : Int(parts[0])
    }

    private static func expiryText(_ line: String) -> String? {
        for prefix in ["Expires ", "All expire "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// "Fable reset · 3" -> ("Fable reset", 3); "Full reset" -> ("Full reset", 1).
    private static func labelAndCount(_ line: String) -> (String, Int) {
        let parts = line.components(separatedBy: " · ")
        if parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)), count > 0 {
            return (parts[0], count)
        }
        return (line, 1)
    }

    /// "Dec 10, 11:00 PM GMT+1" or "Mar 9, 2027, 8:59 AM GMT+1". A missing year is the next one
    /// at or after the capture, since the page only lists credits that have not expired.
    static func parseDate(_ text: String, reference: Date) -> Date? {
        var body = text
        var zone = TimeZone.current
        if let range = body.range(of: #"\s(GMT|UTC)([+-]\d{1,2})?(?::?(\d{2}))?$"#, options: .regularExpression) {
            let suffix = body[range].trimmingCharacters(in: .whitespaces).dropFirst(3)
            body = String(body[..<range.lowerBound])
            var seconds = 0
            if let sign = suffix.first, sign == "+" || sign == "-" {
                let numbers = suffix.dropFirst().split(separator: ":")
                let hours = Int(numbers.first ?? "") ?? 0
                let minutes = numbers.count > 1 ? Int(numbers[1]) ?? 0 : 0
                seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            }
            zone = TimeZone(secondsFromGMT: seconds) ?? zone
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        if let date = formatter.date(from: body) { return date }
        // No year: insert the capture's year after the day, and roll forward if that is in the past.
        guard let comma = body.range(of: ", ") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: reference)
        for candidate in [year, year + 1] {
            let withYear = body.replacingCharacters(in: comma, with: ", \(candidate), ")
            if let date = formatter.date(from: withYear), date > reference.addingTimeInterval(-86_400) {
                return date
            }
        }
        return nil
    }
}
