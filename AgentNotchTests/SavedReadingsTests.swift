import Foundation
import Testing

@testable import AgentNotch

/// The last reading survives a restart and an expired sign-in, dated, without any account detail on disk.
@MainActor
struct SavedReadingsTests {
    private struct ScriptedProvider: UsageProvider {
        let id: ProviderID
        let box: OutcomeBox
        func fetch() async throws -> ProviderSnapshot { try box.outcome.get() }
    }

    private final class OutcomeBox: @unchecked Sendable {
        var outcome: Result<ProviderSnapshot, UsageProviderError>
        init(_ outcome: Result<ProviderSnapshot, UsageProviderError>) { self.outcome = outcome }
    }

    private func defaults() -> UserDefaults {
        let name = "SavedReadingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func snapshot(fraction: Double, fetchedAt: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .claude, account: "person@example.com", plan: "max",
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: fraction, resetsAt: nil)],
            sessions: [AgentSession(id: "1", name: "s", detail: "", activity: .working, startedAt: fetchedAt)],
            fetchedAt: fetchedAt, accountBinding: "binding-secret")
    }

    private func store(_ box: OutcomeBox, saved: UserDefaults, revoked: (@Sendable (ProviderID) -> Void)? = nil)
        -> UsageStore
    {
        UsageStore(
            providers: [ScriptedProvider(id: .claude, box: box)],
            defaults: saved,
            enabledProviders: [.claude],
            revokeCredential: revoked ?? { _ in },
            savedReadings: saved
        )
    }

    private func settle(_ store: UsageStore) async {
        while store.isRefreshing { await Task.yield() }
    }

    @Test func readingSurvivesRestartAsOlderDataWithoutAccountDetail() async throws {
        let saved = defaults()
        let first = store(OutcomeBox(.success(snapshot(fraction: 0.4))), saved: saved)
        first.refresh(.claude)
        await settle(first)

        let raw = try #require(saved.data(forKey: UsageStore.savedReadingsKey))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains("person@example.com"))
        #expect(!text.contains("binding-secret"))

        let restarted = store(OutcomeBox(.failure(.badResponse("offline"))), saved: saved)
        guard case .ready(let restored, true) = restarted.status(for: .claude) else {
            Issue.record("expected the saved reading, dated")
            return
        }
        #expect(restored.windows.first?.usedFraction == 0.4)
        #expect(restored.account == nil)
        #expect(restored.sessions.isEmpty)

        // Wi-Fi not up yet at login: the saved reading stays instead of an error.
        restarted.refresh(.claude)
        await settle(restarted)
        #expect(restarted.status(for: .claude).snapshot?.windows.first?.usedFraction == 0.4)
        #expect(restarted.status(for: .claude).isStale)
    }

    @Test func expiredSignInKeepsTheLastReadingUntilTheToolRenews() async {
        let saved = defaults()
        let box = OutcomeBox(.success(snapshot(fraction: 0.3)))
        let live = store(box, saved: saved)
        live.refresh(.claude)
        await settle(live)

        box.outcome = .failure(.needsAuth("HTTP 401"))
        live.refresh(.claude)
        await settle(live)
        #expect(live.status(for: .claude).isStale)
        #expect(live.status(for: .claude).snapshot?.windows.first?.usedFraction == 0.3)
        #expect(live.awaitingOwnerTool == [.claude])

        box.outcome = .success(snapshot(fraction: 0.5))
        live.refresh(.claude)
        await settle(live)
        #expect(live.status(for: .claude).snapshot?.windows.first?.usedFraction == 0.5)
        #expect(!live.status(for: .claude).isStale)
        #expect(live.awaitingOwnerTool.isEmpty)
    }

    @Test func noReadingYetStillAsksToSignIn() async {
        let live = store(OutcomeBox(.failure(.needsAuth("HTTP 401"))), saved: defaults())
        live.refresh(.claude)
        await settle(live)
        #expect(live.status(for: .claude) == .needsAuth("HTTP 401"))
        #expect(live.awaitingOwnerTool.isEmpty)
    }

    @Test func turningAccessOffForgetsTheSavedReading() async {
        let saved = defaults()
        let live = store(OutcomeBox(.success(snapshot(fraction: 0.4))), saved: saved)
        live.refresh(.claude)
        await settle(live)
        live.setEnabledProviders([])
        let restarted = store(OutcomeBox(.failure(.badResponse("offline"))), saved: saved)
        #expect(restarted.status(for: .claude) == .waiting)
    }

    @Test func storeWithoutSavedReadingsWritesNothing() async {
        let defaults = defaults()
        let live = UsageStore(
            providers: [ScriptedProvider(id: .claude, box: OutcomeBox(.success(snapshot(fraction: 0.4))))],
            defaults: defaults
        )
        live.refresh(.claude)
        await settle(live)
        #expect(defaults.data(forKey: UsageStore.savedReadingsKey) == nil)
    }
}
