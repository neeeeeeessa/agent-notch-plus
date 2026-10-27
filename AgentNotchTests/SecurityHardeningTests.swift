import Foundation
import Testing

@testable import AgentNotch

struct SecurityHardeningTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "security-hardening-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func usageAccessDefaultsEmptyDespiteHiddenProviders() {
        let defaults = isolatedDefaults()
        defaults.set(ProviderID.allCases.map(\.rawValue), forKey: "hiddenProviders")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.usageAccessProviders.isEmpty)
        #expect(preferences.hiddenProviders == Set(ProviderID.allCases))
    }

    @Test func newInstallShowsNotchOnHover() {
        let preferences = Preferences(defaults: isolatedDefaults())
        #expect(preferences.notchVisibility == .onHover)
    }

    @Test func emptyAllowListDoesNotFetch() async {
        let claude = CallCounter(id: .claude)
        let grok = CallCounter(id: .grokBuild)
        let codex = CallCounter(id: .codex)
        let store = UsageStore(
            providers: [claude, grok, codex],
            defaults: isolatedDefaults(),
            enabledProviders: []
        )
        store.refreshAll()
        store.refresh(.claude)
        store.refresh(.grokBuild)
        store.refresh(.codex)
        await Task.yield()
        #expect(claude.calls == 0)
        #expect(grok.calls == 0)
        #expect(codex.calls == 0)
        #expect(store.status(for: .claude) == .failed(UsageStore.disconnectedStatus))
    }

    @Test @MainActor func clickingAnOffProviderOpensSettingsInsteadOfRefreshing() {
        let claude = CallCounter(id: .claude)
        let codex = CallCounter(id: .codex)
        let defaults = isolatedDefaults()
        let store = UsageStore(providers: [claude, codex], defaults: defaults, enabledProviders: [.codex])
        let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
        var opened = 0
        model.openSettings = { opened += 1 }
        model.cellClicked(.claude)
        #expect(opened == 1)
        #expect(model.spinTurns[.claude] == nil)
        model.cellClicked(.codex)
        #expect(opened == 1)
        #expect(model.spinTurns[.codex] == 1)
    }

    @Test func enableOneProviderFetchesOnlyThatProvider() async {
        let claude = CallCounter(id: .claude)
        let codex = CallCounter(id: .codex)
        let store = UsageStore(
            providers: [claude, codex],
            defaults: isolatedDefaults(),
            enabledProviders: []
        )
        store.setEnabledProviders([.codex])
        await waitUntil { codex.calls == 1 }
        #expect(codex.calls == 1)
        #expect(claude.calls == 0)
        #expect(store.status(for: .codex).snapshot?.account == "synthetic")
        #expect(store.status(for: .claude) == .failed(UsageStore.disconnectedStatus))
    }

    @Test func disableClearsSnapshotAndLateResultCannotRepublishAcrossReenable() async {
        let claude = HoldProvider(id: .claude)
        let store = UsageStore(
            providers: [claude],
            defaults: isolatedDefaults(),
            enabledProviders: []
        )
        store.setEnabledProviders([.claude])
        await waitUntil { claude.calls == 1 }
        claude.succeedNext(account: "first-synthetic")
        await waitUntil { store.status(for: .claude).snapshot?.account == "first-synthetic" }

        store.refresh(.claude)
        await waitUntil { claude.calls == 2 }
        store.setEnabledProviders([])
        #expect(store.status(for: .claude) == .failed(UsageStore.disconnectedStatus))
        #expect(store.status(for: .claude).snapshot == nil)
        #expect(store.refreshing.isEmpty)

        store.setEnabledProviders([.claude])
        await waitUntil { claude.calls == 3 }
        claude.succeedNext(account: "stale-synthetic")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(store.status(for: .claude).snapshot?.account != "stale-synthetic")
        claude.succeedNext(account: "fresh-synthetic")
        await waitUntil { store.status(for: .claude).snapshot?.account == "fresh-synthetic" }
        #expect(store.status(for: .claude).snapshot?.account == "fresh-synthetic")
    }

    @Test func cachedSnapshotIsNotRestored() {
        let defaults = isolatedDefaults()
        let stale = ProviderSnapshot(
            id: .claude,
            account: "cached-synthetic",
            plan: nil,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defaults.set(try? JSONEncoder().encode([stale]), forKey: "lastGoodReadings")
        let store = UsageStore(
            providers: [CallCounter(id: .claude)],
            defaults: defaults,
            enabledProviders: [.claude]
        )
        #expect(store.status(for: .claude) == .waiting)
        #expect(store.status(for: .claude).snapshot == nil)
    }

    @Test func httpAllowlistAcceptsExactUsageURLsOnly() {
        for raw in ProviderHTTP.allowedUsageURLs {
            #expect(ProviderHTTP.allows(URL(string: raw)!))
        }
        let rejected = [
            "https://api.anthropic.com.evil.example/api/oauth/usage",
            "https://evil-api.anthropic.com/api/oauth/usage",
            "http://api.anthropic.com/api/oauth/usage",
            "https://api.anthropic.com/api/oauth/usage/extra",
            "https://api.anthropic.com/api/oauth/usage?leak=1",
            "https://user:secret@api.anthropic.com/api/oauth/usage",
            "https://api.anthropic.com:8443/api/oauth/usage",
            "https://chatgpt.com/backend-api/wham/usage/other",
            "https://cursor.com/api/usage-summary",
        ]
        for raw in rejected {
            #expect(ProviderHTTP.allows(URL(string: raw)!) == false)
        }
    }

    @Test func ephemeralSessionDisablesCookiesCacheAndCredentials() {
        let config = ProviderHTTP.makeConfiguration()
        #expect(config.identifier == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.timeoutIntervalForRequest == ProviderHTTP.requestTimeout)
    }

    @Test func redirectDelegatePassesNil() {
        let delegate = ProviderHTTPRedirectRejector()
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let response = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "https://evil.example/steal"]
        )!
        let session = URLSession(configuration: ProviderHTTP.makeConfiguration())
        let task = session.dataTask(with: URLRequest(url: url))
        var seen: URLRequest??
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://evil.example/steal")!),
            completionHandler: { seen = $0 }
        )
        task.cancel()
        session.invalidateAndCancel()
        #expect(seen != nil)
        #expect(seen??.url == nil)
    }

    @Test @MainActor func retiredOAuthSignInRefreshAndSaveFail() async throws {
        await #expect(throws: ClaudeCredentialAccessError.signInDisabled) {
            try await ClaudeOAuthLogin.signIn()
        }
        let session = ClaudeOAuthSession(
            accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh",
            expiresAt: Date().timeIntervalSince1970 + 3600,
            email: nil
        )
        await #expect(throws: ClaudeCredentialAccessError.refreshDisabled) {
            try await ClaudeOAuthLogin.refresh(session)
        }
        #expect(throws: ClaudeCredentialAccessError.sessionSaveDisabled) {
            try ClaudeOAuthStore.save(session)
        }
        #expect(try ClaudeOAuthStore.load() == nil)
    }

    @Test func claudeCodeBlobDropsRefreshToken() throws {
        let millis = Data(
            #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1788542453069}}"#
                .utf8)
        let fromMillis = try #require(ClaudeOAuthSession.fromClaudeCodeBlob(millis))
        #expect(fromMillis.accessToken == "tok")
        #expect(fromMillis.refreshToken == "")
        #expect(abs(fromMillis.expiresAt - 1_788_542_453.069) < 0.01)
        let seconds = Data(
            #"{"claudeAiOauth":{"accessToken":"tok2","refreshToken":"nope","expiresAt":1700000000}}"#
                .utf8)
        let fromSeconds = try #require(ClaudeOAuthSession.fromClaudeCodeBlob(seconds))
        #expect(fromSeconds.accessToken == "tok2")
        #expect(fromSeconds.refreshToken == "")
        #expect(fromSeconds.expiresAt == 1_700_000_000)
    }

    @Test func codexQuotaTokenIgnoresAPIKeyAndRolloutsStayClosed() {
        let provider = CodexLocalProvider()
        #expect(
            provider.quotaAccessToken(
                in: Data(#"{"tokens":{"access_token":"oauth-synthetic"},"OPENAI_API_KEY":"sk"}"#.utf8)
            ) == "oauth-synthetic")
        #expect(provider.quotaAccessToken(in: Data(#"{"OPENAI_API_KEY":"sk-synthetic"}"#.utf8)) == nil)
        do {
            _ = try provider.snapshotFromRollouts()
            Issue.record("session log scanning should throw")
        } catch let error as UsageProviderError {
            #expect(error.message == CodexLocalProvider.sessionLogScanningDisabled)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func unknownKeychainGrantRejectsBeforeSecurity() {
        let service = "synthetic-unknown-\(UUID().uuidString)"
        do {
            try Keychain.requestReadAccess(service: service)
            Issue.record("unknown service should throw")
        } catch let error as UsageProviderError {
            #expect(error.message == "Keychain service is not allowlisted")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func approvedSessionKeepsOnlySanitizedFieldsAndReusesThem() throws {
        let store = KeychainSessionStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var osReads = 0
        let claudeRaw = Data(
            #"{"claudeAiOauth":{"accessToken":"claude-access","refreshToken":"claude-refresh","expiresAt":1700003600000,"idToken":"claude-id"},"extra":"drop"}"#
                .utf8)
        osReads += 1
        try store.retainApproved(
            service: "Claude Code-credentials", account: nil, dataProtection: false, raw: claudeRaw, now: now)
        let first = try #require(
            try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now))
        let second = try #require(
            try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now))
        #expect(first == second)
        #expect(osReads == 1)
        let text = String(decoding: first, as: UTF8.self)
        #expect(!text.contains("claude-refresh"))
        #expect(!text.contains("claude-id"))
        #expect(!text.contains("extra"))
        let session = try #require(ClaudeOAuthSession.fromClaudeCodeBlob(first))
        #expect(session.accessToken == "claude-access")
        #expect(session.refreshToken == "")

        let codexRaw = Data(
            #"{"tokens":{"access_token":"codex-access","refresh_token":"codex-refresh","id_token":"codex-id","account_id":"acct-1"},"OPENAI_API_KEY":"sk-synthetic"}"#
                .utf8)
        try store.retainApproved(
            service: "Codex Auth", account: nil, dataProtection: false, raw: codexRaw, now: now)
        let codex = try #require(
            try store.cachedData(service: "Codex Auth", account: nil, dataProtection: false, now: now))
        let codexText = String(decoding: codex, as: UTF8.self)
        #expect(codexText.contains("codex-access"))
        #expect(codexText.contains("acct-1"))
        #expect(!codexText.contains("codex-refresh"))
        #expect(!codexText.contains("codex-id"))
        #expect(!codexText.contains("OPENAI_API_KEY"))
        #expect(!codexText.contains("sk-synthetic"))
    }

    @Test func sessionMissExpiryMismatchAndDiscardDeny() throws {
        let store = KeychainSessionStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = Data(
            #"{"claudeAiOauth":{"accessToken":"claude-access","refreshToken":"claude-refresh","expiresAt":1700003600}}"#
                .utf8)
        try store.retainApproved(
            service: "Claude Code-credentials", account: nil, dataProtection: false, raw: raw, now: now)
        do {
            _ = try store.cachedData(
                service: "Claude Code-credentials", account: "other", dataProtection: false, now: now)
            Issue.record("mismatched account should deny")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }
        do {
            _ = try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: true, now: now)
            Issue.record("mismatched data protection should deny")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }
        let stillApproved = try #require(
            try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now))
        #expect(String(decoding: stillApproved, as: UTF8.self).contains("claude-access"))
        let expiredAt = Date(timeIntervalSince1970: 1_700_003_600)
        do {
            _ = try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: expiredAt)
            Issue.record("expired session should throw")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }
        do {
            _ = try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now)
            Issue.record("expired session should stay cleared")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }

        try store.retainApproved(
            service: "Codex Auth", account: nil, dataProtection: false,
            raw: Data(#"{"tokens":{"access_token":"codex-access"}}"#.utf8), now: now)
        store.discard(service: "Codex Auth")
        do {
            _ = try store.cachedData(service: "Codex Auth", account: nil, dataProtection: false, now: now)
            Issue.record("discarded session should throw")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }

        #expect(throws: UsageProviderError.self) {
            try store.retainApproved(
                service: "Claude Code-credentials", account: nil, dataProtection: false,
                raw: Data(#"{"claudeAiOauth":{"accessToken":"","expiresAt":1700003600}}"#.utf8), now: now)
        }
        #expect(
            try store.cachedData(service: "synthetic-unknown", account: nil, dataProtection: false, now: now)
                == nil)
    }

    @Test @MainActor func repeatedGrantDoesNotOverlapAndCancelBlocksCompletion() {
        let coordinator = UsageAccessGrantCoordinator()
        let generation = coordinator.begin(.claude)
        #expect(generation == 0)
        #expect(coordinator.begin(.claude) == nil)
        #expect(coordinator.approving == [.claude])
        #expect(coordinator.begin(.codex) == 0)
        coordinator.cancel(.claude)
        #expect(coordinator.complete(.claude, generation: generation ?? 0) == false)
        #expect(coordinator.approving.contains(.claude) == false)
        #expect(coordinator.complete(.codex, generation: 0))
    }

    @Test func grantDiscardThenCompleteCannotPublish() throws {
        let store = KeychainSessionStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let grantA = try #require(store.beginGrant(service: "Claude Code-credentials"))
        store.discard(service: "Claude Code-credentials")
        #expect(store.beginGrant(service: "Claude Code-credentials") == nil)
        #expect(throws: UsageProviderError.self) {
            try store.completeGrant(
                grantA, raw: Self.claudeRaw("discarded-access"), account: nil, dataProtection: false, now: now)
        }
        do {
            _ = try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now)
            Issue.record("discarded grant should not leave data")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }
    }

    @Test func cancelledGrantCannotClearALaterSession() throws {
        let store = KeychainSessionStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let grantA = try #require(store.beginGrant(service: "Codex Auth"))
        store.invalidatePending(service: "Codex Auth")
        #expect(store.beginGrant(service: "Codex Auth") == nil)
        #expect(throws: UsageProviderError.self) {
            try store.completeGrant(
                grantA,
                raw: Data(#"{"tokens":{"access_token":"codex-a"}}"#.utf8),
                account: nil,
                dataProtection: false,
                now: now
            )
        }
        let grantB = try #require(store.beginGrant(service: "Codex Auth"))
        try store.completeGrant(
            grantB,
            raw: Data(#"{"tokens":{"access_token":"codex-b","refresh_token":"drop"}}"#.utf8),
            account: nil,
            dataProtection: false,
            now: now
        )
        #expect(throws: UsageProviderError.self) {
            try store.completeGrant(
                grantA,
                raw: Data(#"{"tokens":{"access_token":"codex-a"}}"#.utf8),
                account: nil,
                dataProtection: false,
                now: now
            )
        }
        store.failGrant(grantA)
        let kept = try #require(
            try store.cachedData(service: "Codex Auth", account: nil, dataProtection: false, now: now))
        let text = String(decoding: kept, as: UTF8.self)
        #expect(text.contains("codex-b"))
        #expect(!text.contains("codex-a"))
        #expect(!text.contains("refresh_token"))
    }

    @Test func overlappingGrantIsDeniedAcrossFreshCallers() {
        let store = KeychainSessionStore()
        let first = store.beginGrant(service: "Claude Code-credentials")
        let secondView = store.beginGrant(service: "Claude Code-credentials")
        #expect(first != nil)
        #expect(secondView == nil)
        #expect(store.beginGrant(service: "Codex Auth") != nil)
    }

    @Test func failedGrantClearsOnlyItsGeneration() throws {
        let store = KeychainSessionStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let grantA = try #require(store.beginGrant(service: "Codex Auth"))
        store.invalidatePending(service: "Codex Auth")
        #expect(store.beginGrant(service: "Codex Auth") == nil)
        store.failGrant(grantA)
        let grantB = try #require(store.beginGrant(service: "Codex Auth"))
        try store.completeGrant(
            grantB,
            raw: Data(#"{"tokens":{"access_token":"codex-live"}}"#.utf8),
            account: nil,
            dataProtection: false,
            now: now
        )
        store.failGrant(grantA)
        let kept = try #require(
            try store.cachedData(service: "Codex Auth", account: nil, dataProtection: false, now: now))
        #expect(String(decoding: kept, as: UTF8.self).contains("codex-live"))

        let own = try #require(store.beginGrant(service: "Claude Code-credentials"))
        store.failGrant(own)
        do {
            _ = try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now)
            Issue.record("failed grant should not leave a session")
        } catch let error as UsageProviderError {
            #expect(error.message == Keychain.reconnectMessage)
        }
    }

    @Test func oneGrantIsReusedWithoutAnotherRead() throws {
        let store = KeychainSessionStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var osReads = 0
        let ticket = try #require(store.beginGrant(service: "Claude Code-credentials"))
        osReads += 1
        try store.completeGrant(
            ticket, raw: Self.claudeRaw("claude-once"), account: nil, dataProtection: false, now: now)
        let first = try #require(
            try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now))
        let second = try #require(
            try store.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false, now: now))
        #expect(osReads == 1)
        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self).contains("claude-once"))
    }

    @Test func startupPreservesPersistedAllowListIncludingKeychainProviders() {
        let persisted: Set<ProviderID> = [.claude, .codex, .grokBuild]
        #expect(UsageAccessStartup.persistedAllowList([], codexAuthFileReadable: false).isEmpty)
        #expect(
            UsageAccessStartup.persistedAllowList(persisted, codexAuthFileReadable: true) == persisted)
        #expect(
            UsageAccessStartup.persistedAllowList(persisted, codexAuthFileReadable: false) == persisted)
    }

    @Test func needsAuthDropsApprovedSessionOtherFailuresKeepIt() async {
        final class ClearLog: @unchecked Sendable {
            var ids: [ProviderID] = []
        }
        let log = ClearLog()
        let denied = ThrowingProvider(id: .claude, error: .needsAuth("HTTP 401"))
        let store = UsageStore(
            providers: [denied],
            defaults: isolatedDefaults(),
            enabledProviders: [.claude],
            revokeCredential: { log.ids.append($0) }
        )
        store.refresh(.claude)
        await waitUntil { store.status(for: .claude) == .needsAuth("HTTP 401") }
        #expect(log.ids == [.claude])
        #expect(store.status(for: .claude) != .failed(UsageStore.disconnectedStatus))

        let blip = ThrowingProvider(id: .codex, error: .badResponse("request failed"))
        let kept = UsageStore(
            providers: [blip],
            defaults: isolatedDefaults(),
            enabledProviders: [.codex],
            revokeCredential: { log.ids.append($0) }
        )
        kept.refresh(.codex)
        await waitUntil { kept.status(for: .codex) == .failed("request failed") }
        #expect(log.ids == [.claude])
    }

    @Test func unknownKeychainServiceReturnsNilWithoutRead() throws {
        let service = "synthetic-unknown-\(UUID().uuidString)"
        #expect(Keychain.readableServices.contains(service) == false)
        #expect(try Keychain.data(service: service, account: "synthetic") == nil)
    }

    @Test func freshReaderUsesPersistedApprovalWithoutForeground() throws {
        let probe = KeychainProbe()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        probe.approved = [.claude]
        probe.directData = Self.claudeRaw("restart-access")
        let reader = probe.reader(now: now)
        let data = try #require(
            try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false))
        #expect(probe.directCalls == 1)
        #expect(probe.foregroundPrompts == 0)
        #expect(probe.toolCalls == 0)
        #expect(probe.resolved == 0)
        #expect(String(decoding: data, as: UTF8.self).contains("restart-access"))
        #expect(!String(decoding: data, as: UTF8.self).contains("drop"))
        let again = try #require(
            try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false))
        #expect(again == data)
        #expect(probe.directCalls == 1)
    }

    @Test func unapprovedOrRefusedNeverTouchKeychain() throws {
        let probe = KeychainProbe()
        probe.directData = Self.claudeRaw("hidden")
        let reader = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(throws: UsageProviderError.self) {
            try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false)
        }
        probe.approved = [.claude]
        probe.refused = [.claude]
        #expect(throws: UsageProviderError.self) {
            try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false)
        }
        #expect(probe.directCalls == 0)
        #expect(probe.toolCalls == 0)
        #expect(try reader.data(service: "not-allowlisted", account: nil, dataProtection: false) == nil)
    }

    @Test func foregroundDenialPersistsAndSkipsTool() throws {
        let probe = KeychainProbe()
        probe.directOutcome = .interactionRefused
        let reader = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(throws: UsageProviderError.self) {
            try reader.requestForeground(service: "Codex Auth")
        }
        #expect(probe.refused == [.codex])
        #expect(probe.toolCalls == 0)
        #expect(probe.foregroundPrompts == 1)
        probe.approved = [.codex]
        probe.directData = Data(#"{"tokens":{"access_token":"should-not-read"}}"#.utf8)
        #expect(throws: UsageProviderError.self) {
            try reader.data(service: "Codex Auth", account: nil, dataProtection: false)
        }
        #expect(probe.directCalls == 1)
        probe.directOutcome = .data(Data(#"{"tokens":{"access_token":"codex-ok","refresh_token":"no"}}"#.utf8))
        try reader.requestForeground(service: "Codex Auth")
        #expect(probe.refused.isEmpty)
        #expect(probe.toolCalls == 0)
    }

    @Test func silentRefusalFallsBackOnlyForExactAccount() throws {
        let probe = KeychainProbe()
        probe.approved = [.codex]
        probe.directOutcome = .interactionRefused
        probe.toolData = Data(#"{"tokens":{"access_token":"from-tool","refresh_token":"no"}}"#.utf8)
        let reader = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try #require(
            try reader.data(service: "Codex Auth", account: "exact-user", dataProtection: false))
        #expect(String(decoding: data, as: UTF8.self).contains("from-tool"))
        #expect(!String(decoding: data, as: UTF8.self).contains("refresh_token"))
        #expect(probe.toolAccounts == ["exact-user"])
        #expect(probe.resolved == 0)

        let ambiguous = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        probe.resolvedAccounts = .ambiguous
        #expect(throws: UsageProviderError.self) {
            try ambiguous.data(service: "Codex Auth", account: nil, dataProtection: false)
        }
        #expect(probe.toolCalls == 1)

        let unique = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        probe.resolvedAccounts = .unique("only-account")
        let resolved = try #require(try unique.data(service: "Codex Auth", account: nil, dataProtection: false))
        #expect(String(decoding: resolved, as: UTF8.self).contains("from-tool"))
        #expect(probe.toolAccounts == ["exact-user", "only-account"])
    }

    @Test func directSuccessLockedAndAmbiguousDoNotSpawnTool() throws {
        let probe = KeychainProbe()
        probe.approved = [.claude]
        probe.directData = Self.claudeRaw("direct-only")
        let reader = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false)
        #expect(probe.toolCalls == 0)

        probe.directOutcome = .interactionRefused
        probe.unlocked = false
        let locked = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(throws: UsageProviderError.self) {
            try locked.data(service: "Claude Code-credentials", account: "acct", dataProtection: false)
        }
        #expect(probe.toolCalls == 0)

        probe.unlocked = true
        probe.resolvedAccounts = .ambiguous
        let unclear = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(throws: UsageProviderError.self) {
            try unclear.data(service: "Claude Code-credentials", account: nil, dataProtection: false)
        }
        #expect(probe.toolCalls == 0)
    }

    @Test func expiredRamReadsCurrentToken() throws {
        let probe = KeychainProbe()
        probe.approved = [.claude]
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let reader = probe.reader(now: earlier)
        try reader.sessions.retainApproved(
            service: "Claude Code-credentials", account: nil, dataProtection: false,
            raw: Self.claudeRaw("old-access"), now: earlier)
        probe.now = Date(timeIntervalSince1970: 1_700_003_600)
        probe.directData = Data(
            #"{"claudeAiOauth":{"accessToken":"new-owner","refreshToken":"nope","expiresAt":1700007200000}}"#
                .utf8)
        let data = try #require(
            try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("new-owner"))
        #expect(!text.contains("old-access"))
        #expect(!text.contains("nope"))
        #expect(probe.directCalls == 1)
        #expect(probe.toolCalls == 0)
    }

    @Test func revokeDuringReadDoesNotCacheLateResult() throws {
        let probe = KeychainProbe()
        probe.approved = [.claude]
        let reader = probe.reader(now: Date(timeIntervalSince1970: 1_700_000_000))
        probe.directOutcome = .data(Self.claudeRaw("late-access"))
        probe.onDirect = { reader.sessions.discard(service: "Claude Code-credentials") }
        #expect(throws: UsageProviderError.self) {
            try reader.data(service: "Claude Code-credentials", account: nil, dataProtection: false)
        }
        #expect(throws: UsageProviderError.self) {
            try reader.sessions.cachedData(
                service: "Claude Code-credentials", account: nil, dataProtection: false,
                now: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    @Test func metadataSelectionKeepsNewestPersistentRefAndSameAccount() {
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_003_000)
        let older = Self.meta(ref: Data("old-ref".utf8), modified: olderDate, account: "same")
        let newer = Self.meta(ref: Data("new-ref".utf8), modified: newerDate, account: "same")
        let undated = Self.meta(ref: Data("undated-ref".utf8), modified: nil, account: "same")
        let single = KeychainItemSelection.newest(from: newer)
        #expect(single?.persistentRef == Data("new-ref".utf8))
        let fromArray = KeychainItemSelection.newest(from: [older, undated, newer])
        #expect(fromArray?.persistentRef == Data("new-ref".utf8))
        #expect(fromArray?.modifiedAt == newerDate)
        #expect(KeychainItemSelection.sharedAccount(from: [older, newer]) == "same")
        let other = Self.meta(ref: Data("other-ref".utf8), modified: newerDate, account: "other")
        #expect(KeychainItemSelection.sharedAccount(from: [older, other]) == nil)
        let missing = Self.meta(ref: Data("missing-ref".utf8), modified: newerDate, account: nil)
        #expect(KeychainItemSelection.sharedAccount(from: [older, missing]) == nil)
    }

    @Test func toolRunnerTimesOutAndCapsOutputWithoutSecurity() {
        let started = Date()
        let slow = LocalSecurityTool.run(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 30;"],
            options: LocalSecurityTool.Options(timeout: 0.4, maxBytes: 256 * 1024)
        )
        #expect(slow == nil)
        #expect(Date().timeIntervalSince(started) < 3)
        let huge = LocalSecurityTool.run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["zzzz"],
            options: LocalSecurityTool.Options(timeout: 2, maxBytes: 1024)
        )
        #expect(huge == nil)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-tool-\(UUID().uuidString).txt")
        try? Data("hello-synthetic\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let small = LocalSecurityTool.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [file.path],
            options: LocalSecurityTool.Options(timeout: 2, maxBytes: 256 * 1024)
        )
        #expect(small == Data("hello-synthetic".utf8))
    }

    private static func meta(ref: Data, modified: Date?, account: String?) -> [String: Any] {
        var row: [String: Any] = [
            kSecValuePersistentRef as String: ref,
            kSecAttrService as String: "Claude Code-credentials",
        ]
        if let modified { row[kSecAttrModificationDate as String] = modified }
        if let account { row[kSecAttrAccount as String] = account }
        return row
    }

    private static func claudeRaw(_ token: String) -> Data {
        Data(
            #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"drop","expiresAt":1700003600000}}"#
                .utf8)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private nonisolated final class KeychainProbe: @unchecked Sendable {
    var approved: Set<ProviderID> = []
    var refused: Set<ProviderID> = []
    var directOutcome: KeychainDirectOutcome = .missing
    var toolData: Data?
    var resolvedAccounts: KeychainAccountResolution = .unavailable
    var unlocked = true
    var now = Date()
    var directCalls = 0
    var foregroundPrompts = 0
    var toolCalls = 0
    var toolAccounts: [String] = []
    var resolved = 0
    var onDirect: () -> Void = {}

    var directData: Data? {
        get { nil }
        set {
            if let newValue { directOutcome = .data(newValue) }
        }
    }

    func reader(now: Date) -> KeychainAccessReader {
        self.now = now
        return KeychainAccessReader(
            isApproved: { [self] in self.approved.contains($0) },
            isRefused: { [self] in self.refused.contains($0) },
            setRefused: { [self] id, refused in
                if refused { self.refused.insert(id) } else { self.refused.remove(id) }
            },
            directRead: { [self] _, _, _, allowPrompt in
                self.directCalls += 1
                if allowPrompt { self.foregroundPrompts += 1 }
                self.onDirect()
                return self.directOutcome
            },
            resolveAccount: { [self] _ in
                self.resolved += 1
                return self.resolvedAccounts
            },
            isKeychainUnlocked: { [self] in self.unlocked },
            toolRead: { [self] _, account in
                self.toolCalls += 1
                self.toolAccounts.append(account)
                return self.toolData
            },
            now: { [self] in self.now }
        )
    }
}

private struct ThrowingProvider: UsageProvider, Sendable {
    var id: ProviderID
    var error: UsageProviderError

    func fetch() async throws -> ProviderSnapshot {
        throw error
    }
}

private final class CallCounter: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var callCount = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    init(id: ProviderID) {
        self.id = id
    }

    func fetch() async throws -> ProviderSnapshot {
        lock.lock()
        callCount += 1
        lock.unlock()
        return ProviderSnapshot(id: id, account: "synthetic", plan: nil, windows: [], fetchedAt: Date())
    }
}

private final class HoldProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var callCount = 0
    private var waiters: [CheckedContinuation<ProviderSnapshot, Never>] = []
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    init(id: ProviderID) {
        self.id = id
    }

    func fetch() async throws -> ProviderSnapshot {
        lock.lock()
        callCount += 1
        lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func succeedNext(account: String) {
        lock.lock()
        let continuation = waiters.removeFirst()
        lock.unlock()
        continuation.resume(
            returning: ProviderSnapshot(
                id: id, account: account, plan: nil, windows: [], fetchedAt: Date()))
    }
}
