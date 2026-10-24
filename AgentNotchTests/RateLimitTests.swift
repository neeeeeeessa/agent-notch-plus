import Foundation
import Testing

@testable import AgentNotch

/// A 429 right after a good reading must not dim it; the store waits out the cooldown instead of hammering.
struct RateLimitTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            value += seconds
            lock.unlock()
        }
    }

    private final class Scripted: UsageProvider, @unchecked Sendable {
        let id: ProviderID
        let clock: Clock
        private let lock = NSLock()
        private var queue: [UsageProviderError?] = []
        private var count = 0
        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        init(id: ProviderID, clock: Clock) {
            self.id = id
            self.clock = clock
        }

        /// nil succeeds, an error throws. Runs in order; an empty queue succeeds.
        func script(_ outcomes: [UsageProviderError?]) {
            lock.lock()
            queue = outcomes
            lock.unlock()
        }

        func fetch() async throws -> ProviderSnapshot {
            lock.lock()
            count += 1
            let next = queue.isEmpty ? nil : queue.removeFirst()
            lock.unlock()
            if let next { throw next }
            return ProviderSnapshot(
                id: id, account: nil, plan: nil,
                windows: [LimitWindow(id: "session", label: "Current session", usedFraction: 0.4, resetsAt: nil)],
                fetchedAt: clock.now)
        }
    }

    private func settle(_ store: UsageStore) async {
        for _ in 0..<200 where store.isRefreshing { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func makeStore(_ provider: Scripted, clock: Clock) -> UsageStore {
        UsageStore(providers: [provider], enabledProviders: [provider.id], now: { clock.now })
    }

    @Test func rateLimitAfterFreshReadingKeepsItBright() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        #expect(store.status(for: .claude).isStale == false)

        claude.script([.rateLimited(retryAfter: nil)])
        clock.advance(5)
        store.refresh(.claude)  // the owner's click right after a poll
        await settle(store)
        #expect(claude.calls == 2)
        #expect(store.status(for: .claude).snapshot != nil)
        #expect(store.status(for: .claude).isStale == false)
    }

    @Test func cooldownSkipsRequestsUntilItExpires() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        claude.script([.rateLimited(retryAfter: nil)])
        store.refresh(.claude)
        await settle(store)
        #expect(claude.calls == 2)

        clock.advance(UsageStore.rateLimitDefaultCooldown - 1)
        store.refresh(.claude)
        await settle(store)
        #expect(claude.calls == 2)

        clock.advance(2)
        store.refresh(.claude)
        await settle(store)
        #expect(claude.calls == 3)
        #expect(store.status(for: .claude).isStale == false)
    }

    @Test func retryAfterIsClampedToTheMinimum() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        claude.script([.rateLimited(retryAfter: 1)])
        store.refresh(.claude)
        await settle(store)
        clock.advance(UsageStore.rateLimitMinCooldown - 1)
        store.refresh(.claude)
        await settle(store)
        #expect(claude.calls == 2)
        clock.advance(2)
        store.refresh(.claude)
        await settle(store)
        #expect(claude.calls == 3)
    }

    @Test func oldReadingDimsWhileStillRateLimited() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        claude.script([.rateLimited(retryAfter: 900)])
        store.refresh(.claude)
        await settle(store)
        #expect(store.status(for: .claude).isStale == false)

        clock.advance(UsageStore.rateLimitedReadingGrace + 1)
        store.refresh(.claude)  // skipped by cooldown, but the reading is now old
        await settle(store)
        #expect(claude.calls == 2)
        #expect(store.status(for: .claude).isStale)
        #expect(store.status(for: .claude).snapshot != nil)
    }

    @Test func rateLimitWithoutReadingShowsMessage() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        claude.script([.rateLimited(retryAfter: nil)])
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        #expect(store.status(for: .claude) == .failed(UsageProviderError.rateLimited(retryAfter: nil).message))
    }

    @Test func realFailureStillDims() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        claude.script([.badResponse("HTTP 503")])
        store.refresh(.claude)
        await settle(store)
        #expect(store.status(for: .claude).isStale)
    }

    @Test func revokeClearsCooldown() async {
        let clock = Clock()
        let claude = Scripted(id: .claude, clock: clock)
        let store = makeStore(claude, clock: clock)
        store.refresh(.claude)
        await settle(store)
        claude.script([.rateLimited(retryAfter: 900)])
        store.refresh(.claude)
        await settle(store)
        store.setEnabledProviders([])
        store.setEnabledProviders([.claude])  // re-enable refreshes immediately
        await settle(store)
        #expect(claude.calls == 3)
    }

    @Test func retryAfterHeaderParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ProviderHTTP.retryAfterSeconds("120", now: now) == 120)
        #expect(ProviderHTTP.retryAfterSeconds("0", now: now) == 0)
        #expect(ProviderHTTP.retryAfterSeconds("99999", now: now) == 3600)
        #expect(ProviderHTTP.retryAfterSeconds("-5", now: now) == nil)
        #expect(ProviderHTTP.retryAfterSeconds("soon", now: now) == nil)
        #expect(ProviderHTTP.retryAfterSeconds(nil, now: now) == nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: now.addingTimeInterval(90))
        let parsed = ProviderHTTP.retryAfterSeconds(date, now: now)
        #expect(parsed.map { abs($0 - 90) < 1 } == true)
    }
}
