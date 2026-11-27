import Foundation
import Testing

@testable import AgentNotch

/// Claude's resets copied from claude.ai's usage page: parsed exactly, or not at all.
struct ClaudeResetsPageTests {
    /// 2026-11-27 18:00 UTC.
    private let checkedAt = Date(timeIntervalSince1970: 1_795_802_400)

    private let pageText = """
    Limit resets
    4 available
    Full reset

    Expires Dec 10, 11:00 PM GMT+1
    Reset for free
    Fable reset · 3

    All expire Mar 9, 2027, 8:59 AM GMT+1
    Refills your 5-hour limit and your Fable allowance, and gives back what Fable used on your weekly limit. It doesn’t reset your whole week.
    Reset for free

    Last updated: just now
    """

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    @Test func parsesTheLivePageLayout() throws {
        let credits = try #require(ClaudeResetsPage.parse(pageText, checkedAt: checkedAt))
        #expect(credits.availableCount == 4)
        #expect(credits.checkedAt == checkedAt)
        #expect(credits.items.map(\.label) == ["Full reset", "Fable reset"])
        #expect(credits.items.map(\.count) == [1, 3])
        #expect(credits.items[0].expiresAt == utc("2026-12-10T22:00:00Z"))
        #expect(credits.items[1].expiresAt == utc("2027-03-09T07:59:00Z"))
        #expect(credits.activeCount(now: checkedAt) == 4)
    }

    @Test func missingSectionOrCountIsNotAvailableNotZero() {
        #expect(ClaudeResetsPage.parse("Log in to Claude", checkedAt: checkedAt) == nil)
        #expect(ClaudeResetsPage.parse("Limit resets\nFull reset\nExpires Dec 10, 11:00 PM GMT+1",
                                       checkedAt: checkedAt) == nil)
    }

    @Test func zeroAvailableIsZero() throws {
        let credits = try #require(ClaudeResetsPage.parse("Limit resets\n0 available\nLast updated: just now",
                                                          checkedAt: checkedAt))
        #expect(credits.activeCount(now: checkedAt) == 0)
    }

    @Test func rowsThatDisagreeWithTheCountKeepOnlyTheCount() throws {
        let text = "Limit resets\n5 available\nFull reset\nExpires Dec 10, 11:00 PM GMT+1"
        let credits = try #require(ClaudeResetsPage.parse(text, checkedAt: checkedAt))
        #expect(credits.items.isEmpty)
        #expect(credits.activeCount(now: checkedAt) == 5)
    }

    @Test func yearlessDateRollsIntoNextYear() {
        // Captured on Dec 30: "Jan 2" means the coming January.
        let lateDecember = utc("2026-12-30T12:00:00Z")
        #expect(ClaudeResetsPage.parseDate("Jan 2, 9:00 AM GMT", reference: lateDecember)
                == utc("2027-01-02T09:00:00Z"))
        #expect(ClaudeResetsPage.parseDate("Dec 10, 11:00 PM GMT-5", reference: checkedAt)
                == utc("2026-12-11T04:00:00Z"))
        #expect(ClaudeResetsPage.parseDate("soon", reference: checkedAt) == nil)
    }

    @Test func loadReadsOnlyFreshSafeCaptures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("claude-resets.json")

        func write(checkedAt: String, mode: Int = 0o600) throws {
            let json = try JSONSerialization.data(withJSONObject: ["version": 1, "checkedAt": checkedAt, "text": pageText])
            try json.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }

        try write(checkedAt: "2026-11-27T18:00:00Z")
        #expect(ClaudeResetsPage.load(from: file, now: checkedAt)?.availableCount == 4)
        // Older than a week: ignored.
        #expect(ClaudeResetsPage.load(from: file, now: checkedAt.addingTimeInterval(8 * 86_400)) == nil)
        // Writable by others: ignored.
        try write(checkedAt: "2026-11-27T18:00:00Z", mode: 0o666)
        #expect(ClaudeResetsPage.load(from: file, now: checkedAt) == nil)
        // A symlink to a valid capture: ignored.
        try write(checkedAt: "2026-11-27T18:00:00Z")
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(ClaudeResetsPage.load(from: link, now: checkedAt) == nil)
    }
}
