import Foundation
import Testing

@testable import AgentNotch

struct GrokProvidersTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokProvidersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func trustedIssuerAcceptsOneLiveEntryAndDropsRefreshToken() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        let json = """
            {"https://auth.x.ai::synthetic-client":{"key":"access-synthetic","expires_at":"2099-01-01T00:00:00Z","refresh_token":"refresh-secret","oidc_client_id":"secret-client","email":"person@example.com","oidc_issuer":"https://auth.x.ai"}}
            """
        try Data(json.utf8).write(to: url)
        let session = try GrokBuildAuth.load(from: url, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(session.accessToken == "access-synthetic")
        #expect(session.expiresAt == JSONDate.parse("2099-01-01T00:00:00Z"))
        let labels = Mirror(reflecting: session).children.compactMap(\.label)
        #expect(labels == ["accessToken", "expiresAt", "accountKey"])
        #expect(!String(describing: session).contains("refresh-secret"))
        #expect(!String(describing: session).contains("person@example.com"))
    }

    @Test func untrustedExpiredAndAmbiguousAuthNeedSignIn() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rejected = [
            #"{"https://auth.x.ai.evil::id":{"key":"t","expires_at":"2099-01-01T00:00:00Z","oidc_issuer":"https://auth.x.ai"}}"#,
            #"{"https://auth.x.ai::id":{"key":"t","expires_at":"2099-01-01T00:00:00Z","oidc_issuer":"https://auth.x.ai.evil"}}"#,
            #"{"https://login.example::id":{"key":"t","expires_at":"2099-01-01T00:00:00Z"}}"#,
            #"{"https://auth.x.ai::id":{"key":"t","expires_at":"2000-01-01T00:00:00Z"}}"#,
            #"{"https://auth.x.ai::id":{"key":"t"}}"#,
            #"{"https://auth.x.ai::a":{"key":"t","expires_at":"2099-01-01T00:00:00Z"},"https://auth.x.ai::b":{"key":"u","expires_at":"2099-06-01T00:00:00Z"}}"#,
        ]
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        for body in rejected {
            try Data(body.utf8).write(to: url)
            expectSignIn {
                try GrokBuildAuth.load(from: url, now: now)
            }
        }
        let seconds = #"{"https://auth.x.ai::id":{"key":"sec","expires_at":2000000000}}"#
        try Data(seconds.utf8).write(to: url)
        let fromSeconds = try GrokBuildAuth.load(from: url, now: now)
        #expect(fromSeconds.accessToken == "sec")
        #expect(fromSeconds.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        let millis = #"{"https://auth.x.ai::id":{"key":"ms","expires_at":2000000000000}}"#
        try Data(millis.utf8).write(to: url)
        let fromMillis = try GrokBuildAuth.load(from: url, now: now)
        #expect(fromMillis.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test func billingParserReadsWeeklyHeadlineAndProductRows() throws {
        let credits = """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2099-01-01T00:00:00Z","end":"2099-01-08T00:00:00Z"},"creditUsagePercent":36.5,"productUsage":[{"product":"GrokBuild","usagePercent":36.5}],"billingPeriodEnd":"2099-02-01T00:00:00Z"}}
            """
        let parsed = try GrokBuildUsage.parse(Data(credits.utf8))
        #expect(parsed.windows.count == 1)
        #expect(parsed.windows[0].id == "credits")
        #expect(parsed.windows[0].label == "Weekly allowance")
        #expect(abs(parsed.windows[0].usedFraction - 0.365) < 0.0001)
        #expect(parsed.windows[0].resetsAt == JSONDate.parse("2099-01-08T00:00:00Z"))
        #expect(parsed.billing.products.map(\.label) == ["Grok Build"])

        let fallbackReset = """
            {"config":{"creditUsagePercent":12,"billingPeriodEnd":"2099-03-01T00:00:00Z"}}
            """
        let fallback = try GrokBuildUsage.parse(Data(fallbackReset.utf8))
        #expect(fallback.windows[0].resetsAt == JSONDate.parse("2099-03-01T00:00:00Z"))
    }

    @Test func allowlistAcceptsExactGrokBillingURLOnly() {
        #expect(ProviderHTTP.allows(URL(string: "https://api.anthropic.com/api/oauth/usage")!))
        #expect(ProviderHTTP.allows(URL(string: "https://chatgpt.com/backend-api/wham/usage")!))
        #expect(ProviderHTTP.allows(URL(string: ProviderHTTP.grokBuildBillingURL)!))
        let rejected = [
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits&extra=1",
            "https://cli-chat-proxy.grok.com/v1/billing?format=json",
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits&format=credits",
            "https://cli-chat-proxy.grok.com/v1/billing",
            "http://cli-chat-proxy.grok.com/v1/billing?format=credits",
            "https://user:secret@cli-chat-proxy.grok.com/v1/billing?format=credits",
            "https://cli-chat-proxy.grok.com:443/v1/billing?format=credits",
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits#frag",
            "https://cli-chat-proxy.grok.com.evil/v1/billing?format=credits",
            "https://api.anthropic.com/api/oauth/usage?leak=1",
            "https://cursor.com/api/usage-summary",
        ]
        for raw in rejected {
            #expect(ProviderHTTP.allows(URL(string: raw)!) == false)
        }
    }

    @Test func oldAllowListDoesNotAuthorizeNewProviders() {
        let name = "grok-providers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(["claude", "cursor", "codex"], forKey: "usageAccessProviders")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.usageAccessProviders == [.claude, .codex])
        #expect(preferences.usageAccessProviders.contains(.grokBuild) == false)
    }

    private func expectSignIn(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected Grok CLI sign-in")
        } catch let error as UsageProviderError {
            #expect(error.message == GrokBuildAuth.needsSignIn)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    private static let expiredAuth = #"{"https://auth.x.ai::id":{"key":"old","expires_at":"2000-01-01T00:00:00Z"}}"#
    private static let liveAuth = #"{"https://auth.x.ai::id":{"key":"renewed","expires_at":"2099-01-01T00:00:00Z"}}"#

    @Test func expiredTokenIsRenewedByTheCLIOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        try Data(Self.expiredAuth.utf8).write(to: url)
        let runs = Counter()
        let renewal = GrokCLIRenewal(runCLI: {
            runs.increment()
            try? Data(Self.liveAuth.utf8).write(to: url)
        })
        let provider = GrokBuildProvider(authURL: url, renewal: renewal)
        let session = try await provider.session()
        #expect(session.accessToken == "renewed")
        _ = try await provider.session()
        #expect(runs.value == 1)
    }

    @Test func liveTokenDoesNotLaunchTheCLI() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        try Data(Self.liveAuth.utf8).write(to: url)
        let runs = Counter()
        let provider = GrokBuildProvider(authURL: url, renewal: GrokCLIRenewal(runCLI: { runs.increment() }))
        _ = try await provider.session()
        #expect(runs.value == 0)
    }

    @Test func signedOutCLIIsRetriedOnlyAfterTheWindow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        try Data(Self.expiredAuth.utf8).write(to: url)
        let runs = Counter()
        let clock = Counter()
        let renewal = GrokCLIRenewal(
            clock: { Date(timeIntervalSince1970: Double(clock.value)) },
            runCLI: { runs.increment() }
        )
        let provider = GrokBuildProvider(authURL: url, renewal: renewal)
        for _ in 0..<3 {
            await expectSignInAsync { _ = try await provider.session() }
        }
        #expect(runs.value == 1)
        clock.add(Int(GrokCLIRenewal.minInterval))
        await expectSignInAsync { _ = try await provider.session() }
        #expect(runs.value == 2)
    }

    private func expectSignInAsync(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected Grok CLI sign-in")
        } catch let error as UsageProviderError {
            #expect(error.message == GrokBuildAuth.needsSignIn)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { add(1) }
    func add(_ amount: Int) { lock.withLock { count += amount } }
}
