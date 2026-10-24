import AppKit
import Foundation
import Observation
import os

/// Owns the providers, schedules refreshes and keeps the last good reading per provider.
@Observable
final class UsageStore {
    private static let log = Logger(subsystem: "app.lucabecker.AgentNotch", category: "UsageStore")
    static let disconnectedStatus = "Disconnected"

    /// Regular polling cadence. Providers are cheap local reads plus one small HTTPS call.
    static let refreshInterval: TimeInterval = 60

    /// Anthropic returns 429 when usage is polled again within about two minutes.
    static let rateLimitDefaultCooldown: TimeInterval = 120
    static let rateLimitMinCooldown: TimeInterval = 30
    static let rateLimitMaxCooldown: TimeInterval = 900
    /// How long a fresh reading stays bright after a 429. Older readings dim without a new request.
    static let rateLimitedReadingGrace: TimeInterval = 300

    private(set) var statuses: [ProviderID: ProviderStatus] = [:]
    private(set) var refreshing: Set<ProviderID> = []
    /// Last non-empty batch of limit transitions. Tests read this; the notch consumes `onLimitEvents`.
    private(set) var latestLimitEvents: [LimitEvent] = []
    /// Increments only when a transition is published, so a silent refresh is observable.
    private(set) var limitEventRevision = 0
    var onLimitEvents: ([LimitEvent]) -> Void = { _ in }

    private let providers: [ProviderID: any UsageProvider]
    private let gate = NSLock()
    /// `nil` at init means every injected provider (demo and existing tests). Live boot passes an explicit set.
    private var enabledProviders: Set<ProviderID>
    /// Bumped on revoke so a finished request cannot publish after disable or a later re-enable.
    private var requestGeneration: [ProviderID: UInt] = [:]
    /// Requests at or after this instant are allowed again. A 429 must not be retried immediately.
    private var cooldownUntil: [ProviderID: Date] = [:]
    /// Account key the cooldown was recorded for. A missing or nil entry cannot confirm the cooldown.
    private var cooldownBinding: [ProviderID: String?] = [:]
    private var timer: Timer?
    private var inFlight: [ProviderID: Task<Void, Never>] = [:]
    private var wakeObserver: NSObjectProtocol?
    /// Drops a rejected RAM sign-in. Defaults to the process session store. Tests pass a spy.
    private let revokeCredential: (ProviderID) -> Void
    /// Clock for rate-limit decisions. Tests pass a fake clock.
    private let now: () -> Date

    init(
        providers: [any UsageProvider],
        defaults: UserDefaults = .standard,
        enabledProviders: Set<ProviderID>? = nil,
        revokeCredential: @escaping (ProviderID) -> Void = { Keychain.clearApprovedSession(provider: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.revokeCredential = revokeCredential
        self.now = now
        _ = defaults
        let enabled = enabledProviders ?? Set(self.providers.keys)
        self.enabledProviders = enabled
        for id in self.providers.keys {
            statuses[id] = enabled.contains(id) ? .waiting : .failed(Self.disconnectedStatus)
        }
    }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func status(for id: ProviderID) -> ProviderStatus {
        statuses[id] ?? .waiting
    }

    /// Starts periodic polling and refreshes immediately.
    func start() {
        refreshAll()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
    }

    /// Replaces the live allow-list. Revoked providers drop in-flight work and snapshots. Newly allowed providers refresh alone.
    func setEnabledProviders(_ ids: Set<ProviderID>) {
        let previous: Set<ProviderID>
        gate.lock()
        previous = enabledProviders
        enabledProviders = ids.intersection(Set(providers.keys))
        let current = enabledProviders
        gate.unlock()
        for id in providers.keys where previous.contains(id) && !current.contains(id) {
            revoke(id)
        }
        for id in providers.keys where current.contains(id) && !previous.contains(id) {
            refresh(id)
        }
    }

    func refreshAll() {
        for id in providers.keys where isEnabled(id) {
            refresh(id)
        }
    }

    func refresh(_ id: ProviderID) {
        guard let provider = providers[id] else { return }
        guard isEnabled(id) else { return }
        if inFlight[id] != nil {
            Self.log.debug("refresh skipped: one already in flight for \(id.rawValue)")
            return
        }
        let current = now()
        if let until = cooldownUntil[id], current < until {
            // A cooldown recorded for another account, or for one we cannot confirm, must not block the new account.
            let cooldownIsUnconfirmed: Bool
            if case .key(let key) = providers[id]?.currentAccountBinding() {
                let stored = cooldownBinding[id] ?? nil
                cooldownIsUnconfirmed = key == nil || stored == nil || stored != key
            } else {
                cooldownIsUnconfirmed = false
            }
            if cooldownIsUnconfirmed {
                statuses[id] = .failed(Self.unconfirmedAccountStatus)
                cooldownUntil[id] = nil
                cooldownBinding.removeValue(forKey: id)
            } else {
                // The poll is suppressed, but a reading past the grace window still has to dim.
                if case .ready(let snapshot, false) = statuses[id],
                    current.timeIntervalSince(snapshot.fetchedAt) > Self.rateLimitedReadingGrace
                {
                    statuses[id] = .ready(snapshot, stale: true)
                }
                Self.log.debug("refresh skipped: rate limit cooldown for \(id.rawValue)")
                return
            }
        }
        let token = currentGeneration(id)
        refreshing.insert(id)
        inFlight[id] = Task { [weak self] in
            let outcome: Result<ProviderSnapshot, Error>
            do {
                outcome = .success(try await provider.fetch())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            guard self.currentGeneration(id) == token, self.isEnabled(id) else { return }
            self.apply(outcome, for: id)
            guard self.currentGeneration(id) == token else { return }
            self.inFlight[id] = nil
            self.refreshing.remove(id)
        }
    }

    private func isEnabled(_ id: ProviderID) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return enabledProviders.contains(id)
    }

    private func currentGeneration(_ id: ProviderID) -> UInt {
        gate.lock()
        defer { gate.unlock() }
        return requestGeneration[id] ?? 0
    }

    private func revoke(_ id: ProviderID) {
        Keychain.clearApprovedSession(provider: id)
        gate.lock()
        requestGeneration[id, default: 0] &+= 1
        gate.unlock()
        inFlight[id]?.cancel()
        inFlight[id] = nil
        refreshing.remove(id)
        cooldownUntil[id] = nil
        cooldownBinding.removeValue(forKey: id)
        statuses[id] = .failed(Self.disconnectedStatus)
        latestLimitEvents.removeAll { $0.provider == id }
    }

    private static let unconfirmedAccountStatus =
        "Grok account changed or could not be confirmed; waiting for a new reading"

    private func apply(_ outcome: Result<ProviderSnapshot, Error>, for id: ProviderID) {
        let previousStatus = statuses[id]
        let previous = previousStatus?.snapshot
        switch outcome {
        case .success(let snapshot):
            cooldownUntil[id] = nil
            cooldownBinding.removeValue(forKey: id)
            // An in-flight success can land after the signed-in account changed. Do not publish it.
            if case .key(let k) = providers[id]?.currentAccountBinding(),
                k == nil || snapshot.accountBinding == nil || k != snapshot.accountBinding
            {
                statuses[id] = .failed(Self.unconfirmedAccountStatus)
                Self.log.notice("\(id.rawValue, privacy: .public) usage dropped: account changed")
                break
            }
            // A successful read carries its own binding, so no second local auth read is needed.
            // Readings from different accounts must not produce exhausted or reset transitions.
            let sameAccount = previous?.accountBinding == snapshot.accountBinding ? previous : nil
            let events = LimitEvent.detect(previous: sameAccount, current: snapshot, now: Date())
            statuses[id] = .ready(snapshot, stale: snapshot.sourceIsStale)
            Self.log.notice("\(id.rawValue, privacy: .public) usage ready")
            if !events.isEmpty {
                latestLimitEvents = events
                limitEventRevision += 1
                onLimitEvents(events)
            }
        case .failure(let error):
            let binding = providers[id]?.currentAccountBinding() ?? .notApplicable
            let previousForAccount = previousReading(previous, binding: binding)
            switch error {
            case UsageProviderError.needsAuth(let message):
                revokeCredential(id)
                statuses[id] = .needsAuth(message)
                Self.log.notice("\(id.rawValue, privacy: .public) usage needs authentication")
            case UsageProviderError.rateLimited(let retryAfter):
                let current = now()
                let requested = retryAfter ?? Self.rateLimitDefaultCooldown
                let delay = min(max(requested, Self.rateLimitMinCooldown), Self.rateLimitMaxCooldown)
                cooldownUntil[id] = current.addingTimeInterval(delay)
                switch binding {
                case .key(let k):
                    cooldownBinding.updateValue(k, forKey: id)
                case .notApplicable:
                    cooldownBinding.removeValue(forKey: id)
                }
                if let snapshot = previousForAccount {
                    // A 429 must not fade a reading that is still inside the grace window.
                    let agedOut = current.timeIntervalSince(snapshot.fetchedAt) > Self.rateLimitedReadingGrace
                    let stale = previousStatus?.isStale == true || snapshot.sourceIsStale || agedOut
                    statuses[id] = .ready(snapshot, stale: stale)
                } else {
                    statuses[id] = .failed(failureText(previous: previous, binding: binding, fallback: UsageProviderError.rateLimited(retryAfter: retryAfter).message))
                }
                Self.log.notice("\(id.rawValue, privacy: .public) usage rate limited")
            case let providerError as UsageProviderError:
                statuses[id] = previousForAccount.map { .ready($0, stale: true) }
                    ?? .failed(failureText(previous: previous, binding: binding, fallback: providerError.message))
                Self.log.notice("\(id.rawValue, privacy: .public) usage failed: \(providerError.message, privacy: .public)")
            default:
                Self.log.error("\(id.rawValue) refresh failed: \(error.localizedDescription)")
                statuses[id] = previousForAccount.map { .ready($0, stale: true) }
                    ?? .failed(failureText(previous: previous, binding: binding, fallback: "Couldn't read usage"))
            }
        }
    }

    /// Keeps a reading only when it still belongs to the account the provider would fetch.
    private func previousReading(_ previous: ProviderSnapshot?, binding: AccountBindingCheck) -> ProviderSnapshot? {
        switch binding {
        case .notApplicable:
            return previous
        case .key(let key):
            guard let previous, let key, let bound = previous.accountBinding, key == bound else { return nil }
            return previous
        }
    }

    private func failureText(previous: ProviderSnapshot?, binding: AccountBindingCheck, fallback: String) -> String {
        if previous != nil, case .key = binding {
            return Self.unconfirmedAccountStatus
        }
        return fallback
    }
}
