import Foundation
import Testing

@testable import AgentNotch

/// A reading that can no longer refresh must not pass for the current percentage forever.
struct OutdatedReadingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(age: TimeInterval, stale: Bool, resetsIn: TimeInterval? = nil) -> ProviderStatus {
        let snapshot = ProviderSnapshot(
            id: .antigravity, account: nil, plan: nil,
            windows: [LimitWindow(id: "w", label: "Weekly", usedFraction: 0.41,
                                  resetsAt: resetsIn.map { now.addingTimeInterval($0) })],
            sessions: [], fetchedAt: now.addingTimeInterval(-age))
        return .ready(snapshot, stale: stale)
    }

    @Test func freshReadingIsNeverOutdated() {
        #expect(!status(age: 3 * 3600, stale: false).isOutdated(at: now))
        #expect(!status(age: 60, stale: false, resetsIn: -60).isOutdated(at: now))
    }

    @Test func staleReadingShowsPercentageOnlyBriefly() {
        #expect(!status(age: 14 * 60, stale: true, resetsIn: 3600).isOutdated(at: now))
        #expect(status(age: 15 * 60, stale: true, resetsIn: 3600).isOutdated(at: now))
        #expect(status(age: 41 * 60, stale: true).isOutdated(at: now))
    }

    @Test func staleReadingPastItsResetIsOutdatedAtOnce() {
        #expect(status(age: 60, stale: true, resetsIn: -1).isOutdated(at: now))
        #expect(status(age: 60, stale: true, resetsIn: 0).isOutdated(at: now))
    }

    @Test func nonReadyStatusesAreNotOutdated() {
        #expect(!ProviderStatus.waiting.isOutdated(at: now))
        #expect(!ProviderStatus.needsAuth("x").isOutdated(at: now))
        #expect(!ProviderStatus.failed("x").isOutdated(at: now))
    }

    static let ageCases: [(TimeInterval, String)] = [
        (0, "1m"), (59, "1m"), (900, "15m"), (3540, "59m"),
        (3600, "1h"), (169_200, "47h"), (172_800, "2d"), (864_000, "10d"),
    ]

    @Test(arguments: ageCases)
    func ageLabel(age: TimeInterval, expected: String) {
        #expect(ProviderStatus.ageLabel(since: now.addingTimeInterval(-age), now: now) == expected)
    }
}
