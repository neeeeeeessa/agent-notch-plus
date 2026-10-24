import CryptoKit
import Foundation
import Testing

@testable import AgentNotch

/// Synthetic fixtures for the one shared Grok circle. No real auth file, token or request is used.
struct GrokSharedQuotaTests {
    private static let sample = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-01-05T12:00:00.000+00:00","end":"2026-01-12T12:00:00.000+00:00"},
        "creditUsagePercent":40.0,
        "productUsage":[{"product":"GrokBuild","usagePercent":20.0},{"product":"GrokBot","usagePercent":12.0},{"product":"Cursor","usagePercent":8.0}],
        "isUnifiedBillingUser":true,"prepaidBalance":{"val":250},"topUpMethod":"TOP_UP_METHOD_CARD",
        "billingPeriodStart":"2026-01-05T12:00:00.000+00:00","billingPeriodEnd":"2026-01-12T12:00:00.000+00:00"}}
        """

    private func parse(_ json: String) throws -> (windows: [LimitWindow], billing: GrokBilling, tier: String?) {
        try GrokBuildUsage.parse(Data(json.utf8))
    }

    // MARK: Provider set

    @Test func exactlyThreeCirclesInApprovedOrder() {
        #expect(ProviderID.allCases == [.claude, .codex, .grokBuild])
        #expect(ProviderID.grokBuild.rawValue == "grokBuild")
        #expect(ProviderID.grokBuild.displayName == "Grok")
    }

    @Test func savedApprovalSurvivesAndRetiredProvidersAreDropped() {
        let name = "grok-shared-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["claude", "codex", "cursor", "grokBot", "grokBuild"], forKey: "usageAccessProviders")
        defaults.set(["cursor", "grokBot"], forKey: "hiddenProviders")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.usageAccessProviders == [.claude, .codex, .grokBuild])
        #expect(preferences.visibleProviders == [.claude, .codex, .grokBuild])
    }

    @Test func cursorEndpointIsNoLongerAllowlisted() {
        #expect(ProviderHTTP.allows(URL(string: "https://cursor.com/api/usage-summary")!) == false)
        #expect(ProviderHTTP.allows(URL(string: "https://api.anthropic.com/api/oauth/usage")!))
        #expect(ProviderHTTP.allows(URL(string: "https://chatgpt.com/backend-api/wham/usage")!))
        #expect(ProviderHTTP.allows(URL(string: ProviderHTTP.grokBuildBillingURL)!))
        #expect(ProviderHTTP.allowedUsageURLs.count == 3)
    }

    // MARK: Parser

    @Test func liveShapeGivesOverallHeadlineAndBreakdown() throws {
        let parsed = try parse(Self.sample)
        #expect(parsed.windows.count == 1)
        #expect(parsed.windows[0].id == "credits")
        #expect(parsed.windows[0].label == "Weekly allowance")
        #expect(abs(parsed.windows[0].usedFraction - 0.40) < 0.0001)
        #expect(parsed.windows[0].resetsAt == JSONDate.parse("2026-01-12T12:00:00.000+00:00"))
        let billing = parsed.billing
        #expect(billing.products.map(\.id) == ["GrokBuild", "GrokBot", "Cursor"])
        #expect(billing.products.map(\.label) == ["Grok Build", "Grok Bot", "Cursor"])
        #expect(billing.products.map(\.percentOfAllowance) == [20, 12, 8])
        #expect(billing.periodIsWeekly == true)
        #expect(billing.periodStart == JSONDate.parse("2026-01-05T12:00:00.000+00:00"))
        #expect(billing.isUnifiedBilling == true)
        #expect(billing.prepaidBalanceCents == 250)
        #expect(billing.onDemandEnabled == nil)
        #expect(billing.onDemandUsedCents == nil)
        #expect(billing.onDemandCapCents == nil)
        #expect(billing.topUpMethod == "Card")
        #expect(parsed.tier == nil)
    }

    @Test func missingOverallIsNotZeroAndNotASum() {
        let noOverall = """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-01-08T00:00:00Z"},"productUsage":[{"product":"GrokBuild","usagePercent":12}]}}
            """
        let boolOverall = #"{"config":{"creditUsagePercent":true}}"#
        let negative = #"{"config":{"creditUsagePercent":-1}}"#
        let stringy = #"{"config":{"creditUsagePercent":"40"}}"#
        let fresh = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-01-08T00:00:00Z"}}}"#
        for body in [noOverall, boolOverall, negative, stringy, fresh] {
            #expect(throws: UsageProviderError.self) { try parse(body) }
        }
        #expect(throws: UsageProviderError.self) { try parse("[]") }
        #expect(throws: UsageProviderError.self) { try parse(#"{"nothing":1}"#) }
    }

    @Test func absurdPercentagesAreRejectedNotTrapped() throws {
        #expect(throws: UsageProviderError.self) { try parse(#"{"config":{"creditUsagePercent":1e100}}"#) }
        #expect(throws: UsageProviderError.self) { try parse(#"{"config":{"creditUsagePercent":10001}}"#) }
        let rows = try parse(#"{"config":{"creditUsagePercent":10000,"productUsage":[{"product":"GrokBuild","usagePercent":1e300},{"product":"Cursor","usagePercent":3}]}}"#)
        #expect(rows.billing.products.map(\.id) == ["Cursor"])
        #expect(GrokCardText.percent(1e300).isEmpty == false)
        _ = GrokCardText.shareOfUsed(points: 1e300, overall: 1e-300)  // must not trap
    }

    @Test func overageIsKeptNotClamped() throws {
        let parsed = try parse(#"{"config":{"creditUsagePercent":112.5}}"#)
        #expect(abs(parsed.windows[0].usedFraction - 1.125) < 0.0001)
        #expect(parsed.windows[0].label == "Allowance")
        #expect(parsed.billing.products.isEmpty)
        #expect(parsed.billing.isUnifiedBilling == nil)
        #expect(parsed.billing.prepaidBalanceCents == nil)
    }

    @Test func invalidProductRowsAreSkippedNotZeroed() throws {
        let body = """
            {"config":{"creditUsagePercent":40,"productUsage":[
            {"product":"GrokBuild","usagePercent":20},
            {"product":"GrokBot","usagePercent":true},
            {"product":"Cursor"},
            {"product":"","usagePercent":3},
            {"product":"<script>","usagePercent":3},
            {"product":"GrokBuild","usagePercent":99},
            {"product":"GrokImagine","usagePercent":5},
            "junk",
            {"product":"Voice","usagePercent":-2}
            ]}}
            """
        let billing = try parse(body).billing
        // GrokBuild arrived twice with different values, so neither value is shown.
        #expect(billing.products.map(\.id) == ["GrokImagine"])
        #expect(billing.products.map(\.percentOfAllowance) == [5])
        #expect(billing.products[0].label == "Grok Imagine")
        #expect(billing.conflictingProducts == ["Grok Build"])
        let same = try parse(#"{"config":{"creditUsagePercent":9,"productUsage":[{"product":"Cursor","usagePercent":9},{"product":"Cursor","usagePercent":9}]}}"#).billing
        #expect(same.products.map(\.id) == ["Cursor"])
        #expect(same.conflictingProducts.isEmpty)
    }

    @Test func productRowsAreCappedWithoutDroppingSharedProducts() throws {
        let others = (0..<10).map { #"{"product":"P\#($0)","usagePercent":1}"# }
        let shared = [
            #"{"product":"Cursor","usagePercent":4}"#, #"{"product":"GrokBot","usagePercent":7}"#,
            #"{"product":"GrokBuild","usagePercent":11}"#,
        ]
        let rows = (others + shared).joined(separator: ",")
        let billing = try parse(#"{"config":{"creditUsagePercent":57,"productUsage":[\#(rows)]}}"#).billing
        #expect(billing.products.count == 8)
        #expect(billing.omittedProducts == 5)
        #expect(billing.omittedProductPercent == 5)
        #expect(billing.products.map(\.id) == ["P0", "P1", "P2", "P3", "P4", "Cursor", "GrokBot", "GrokBuild"])
        let few = try parse(Self.sample).billing
        #expect(few.omittedProducts == 0)
    }

    @Test func centsAndExtraUsageFields() throws {
        let body = """
            {"on_demand_enabled":true,"subscription_tier":"SUBSCRIPTION_TIER_SUPER_GROK",
            "config":{"creditUsagePercent":10,"prepaidBalance":{},"onDemandUsed":{"val":"1250"},"onDemandCap":{"val":5000},"isUnifiedBillingUser":"yes","topUpMethod":"TOP_UP_METHOD_UNSPECIFIED"}}
            """
        let parsed = try parse(body)
        // The official client serializes a zero Cent as `{}` (serde default, proto3 omits zero): a reported 0.
        // An absent key stays unknown, as `overageIsKeptNotClamped` checks.
        #expect(parsed.billing.prepaidBalanceCents == 0)
        #expect(parsed.billing.onDemandUsedCents == 1250)
        #expect(parsed.billing.onDemandCapCents == 5000)
        #expect(parsed.billing.onDemandEnabled == true)
        #expect(parsed.billing.isUnifiedBilling == nil)
        #expect(parsed.billing.topUpMethod == nil)
        #expect(parsed.tier == "Super grok")

        let bad = """
            {"on_demand_enabled":1,"subscription_tier":"<b>evil</b>",
            "config":{"creditUsagePercent":10,"prepaidBalance":{"val":true},"onDemandUsed":{"val":"12.5"},"onDemandCap":"5000","topUpMethod":"saved"}}
            """
        let rejected = try parse(bad)
        #expect(rejected.billing.prepaidBalanceCents == nil)
        #expect(rejected.billing.onDemandUsedCents == nil)
        #expect(rejected.billing.onDemandCapCents == nil)
        #expect(rejected.billing.onDemandEnabled == nil)
        #expect(rejected.billing.topUpMethod == nil)
        #expect(rejected.tier == nil)

        let negative = """
            {"config":{"creditUsagePercent":10,"prepaidBalance":{"val":-1},"onDemandUsed":{"val":"-500"},"onDemandCap":{"val":5000}}}
            """
        let negatives = try parse(negative).billing
        #expect(negatives.prepaidBalanceCents == nil)
        #expect(negatives.onDemandUsedCents == nil)
        #expect(negatives.onDemandCapCents == 5000)
    }

    // MARK: Card text

    @Test func cardTextKeepsPointsAndLabelsShareOfUsed() throws {
        let parsed = try parse(Self.sample)
        #expect(GrokCardText.percent(26) == "26%")
        #expect(GrokCardText.percent(26.04) == "26%")
        #expect(GrokCardText.percent(26.5) == "26.5%")
        #expect(GrokCardText.shareOfUsed(points: 20, overall: 40) == 50)
        #expect(GrokCardText.shareOfUsed(points: 12, overall: 40) == 30)
        #expect(GrokCardText.shareOfUsed(points: 8, overall: 40) == 20)
        #expect(GrokCardText.shareOfUsed(points: 3, overall: 0) == nil)
        #expect(GrokCardText.addsUp(billing: parsed.billing, overall: 40))
        var mismatch = parsed.billing
        mismatch.products.removeLast()
        #expect(GrokCardText.addsUp(billing: mismatch, overall: 40) == false)
        #expect(GrokCardText.dollars(cents: 0) == "$0.00")
        #expect(GrokCardText.dollars(cents: 1250) == "$12.50")
    }

    @Test func extraLinesShowOnlyReportedFields() throws {
        let sample = try parse(Self.sample).billing
        #expect(GrokCardText.extraLines(billing: sample) == ["Prepaid credits: $2.50", "Top-up: Card"])
        #expect(GrokCardText.extraLines(billing: GrokBilling()) == [])
        var capped = GrokBilling()
        capped.onDemandEnabled = true
        capped.onDemandUsedCents = 1250
        capped.onDemandCapCents = 5000
        #expect(GrokCardText.extraLines(billing: capped) == ["On-demand used: $12.50 of $50.00 cap · $37.50 left · on"])
        capped.onDemandUsedCents = 6000
        #expect(GrokCardText.extraLines(billing: capped) == ["On-demand used: $60.00 of $50.00 cap · $0.00 left · on"])
        capped.onDemandUsedCents = 1250
        capped.onDemandCapCents = 0
        #expect(GrokCardText.extraLines(billing: capped) == ["On-demand used: $12.50 of $0.00 cap · on"])
        capped.onDemandCapCents = nil
        #expect(GrokCardText.extraLines(billing: capped) == ["On-demand used: $12.50 (no cap reported) · on"])
        capped.onDemandEnabled = nil
        #expect(GrokCardText.extraLines(billing: capped) == ["On-demand used: $12.50 (no cap reported)"])
        capped.onDemandEnabled = false
        #expect(GrokCardText.extraLines(billing: capped) == ["On-demand used: $12.50 (no cap reported) · off"])
        var capOnly = GrokBilling()
        capOnly.onDemandCapCents = 5000
        #expect(GrokCardText.extraLines(billing: capOnly) == ["On-demand cap: $50.00"])
        capOnly.onDemandEnabled = false
        #expect(GrokCardText.extraLines(billing: capOnly) == ["On-demand cap: $50.00 · off"])
        var off = GrokBilling()
        off.onDemandEnabled = false
        #expect(GrokCardText.extraLines(billing: off) == ["On-demand usage: off"])
        var on = GrokBilling()
        on.onDemandEnabled = true
        #expect(GrokCardText.extraLines(billing: on) == ["On-demand usage: on"])
    }

    @Test func periodCaptionNeedsUnifiedFlag() throws {
        let sample = try parse(Self.sample).billing
        let caption = try #require(GrokCardText.periodCaption(billing: sample))
        #expect(caption.hasPrefix("Shared weekly allowance"))
        var notUnified = sample
        notUnified.isUnifiedBilling = nil
        #expect(GrokCardText.periodCaption(billing: notUnified)?.hasPrefix("Shared") != true)
    }

    // MARK: Account binding

    private func authFile(token: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokSharedQuotaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auth.json")
        let json = #"{"https://auth.x.ai::synthetic":{"key":"\#(token)","expires_at":"2099-01-01T00:00:00Z","refresh_token":"refresh-secret"}}"#
        try Data(json.utf8).write(to: url)
        return url
    }

    private func jwt(sub: String?) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = sub.map { #"{"sub":"\#($0)","exp":4070908800}"# } ?? #"{"exp":4070908800}"#
        return "\(b64(#"{"alg":"none"}"#)).\(b64(payload)).sig"
    }

    @Test func accountKeyIsAHashOfTheSubjectOnly() throws {
        let url = try authFile(token: jwt(sub: "user-123"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = try GrokBuildAuth.load(from: url, now: Date(timeIntervalSince1970: 1_700_000_000))
        let expected = SHA256.hash(data: Data("grok-sub:user-123".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(session.accountKey == expected)
        #expect(!String(describing: session).contains("refresh-secret"))
        #expect(!(session.accountKey ?? "").contains("user-123"))

        let opaque = try authFile(token: "not-a-jwt")
        defer { try? FileManager.default.removeItem(at: opaque.deletingLastPathComponent()) }
        #expect(try GrokBuildAuth.load(from: opaque, now: Date(timeIntervalSince1970: 1_700_000_000)).accountKey == nil)
        let noSub = try authFile(token: jwt(sub: nil))
        defer { try? FileManager.default.removeItem(at: noSub.deletingLastPathComponent()) }
        #expect(try GrokBuildAuth.load(from: noSub, now: Date(timeIntervalSince1970: 1_700_000_000)).accountKey == nil)
    }

    private final class BoundProvider: UsageProvider, @unchecked Sendable {
        let id: ProviderID = .grokBuild
        private let lock = NSLock()
        private var binding: String?
        private var fail = false
        private var usage = 0.40

        func set(binding: String?, fail: Bool, usage: Double = 0.40) {
            lock.lock()
            self.binding = binding
            self.fail = fail
            self.usage = usage
            lock.unlock()
        }

        func currentAccountBinding() -> AccountBindingCheck {
            lock.lock()
            defer { lock.unlock() }
            return .key(binding)
        }

        func fetch() async throws -> ProviderSnapshot {
            lock.lock()
            let (binding, fail, usage) = (self.binding, self.fail, self.usage)
            lock.unlock()
            if fail { throw UsageProviderError.badResponse("HTTP 503") }
            var snapshot = ProviderSnapshot(
                id: id, account: nil, plan: nil,
                windows: [LimitWindow(id: "credits", label: "Weekly allowance", usedFraction: usage, resetsAt: nil)],
                fetchedAt: Date())
            snapshot.accountBinding = binding
            return snapshot
        }
    }

    private func settle(_ store: UsageStore) async {
        for _ in 0..<200 where store.isRefreshing { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func sameAccountFailureKeepsStaleReading() async {
        let provider = BoundProvider()
        provider.set(binding: "a", fail: false)
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        provider.set(binding: "a", fail: true)
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.status(for: .grokBuild).isStale)
        #expect(store.status(for: .grokBuild).snapshot?.accountBinding == "a")
    }

    @Test func accountChangeDropsTheOtherAccountsReading() async {
        let provider = BoundProvider()
        provider.set(binding: "a", fail: false)
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        provider.set(binding: "b", fail: true)
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.status(for: .grokBuild).snapshot == nil)
        if case .failed = store.status(for: .grokBuild) {} else { Issue.record("expected failed status") }
    }

    @Test func unconfirmedAccountDropsReadingToo() async {
        let provider = BoundProvider()
        provider.set(binding: "a", fail: false)
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        provider.set(binding: nil, fail: true)
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.status(for: .grokBuild).snapshot == nil)
    }

    private final class RateLimitedBoundProvider: UsageProvider, @unchecked Sendable {
        let id: ProviderID = .grokBuild
        private let lock = NSLock()
        private var binding: String? = "a"
        private var limited = false
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func set(binding: String?, limited: Bool) {
            lock.lock(); self.binding = binding; self.limited = limited; lock.unlock()
        }
        func currentAccountBinding() -> AccountBindingCheck {
            lock.lock(); defer { lock.unlock() }; return .key(binding)
        }
        func fetch() async throws -> ProviderSnapshot {
            lock.lock(); count += 1; let (binding, limited) = (self.binding, self.limited); lock.unlock()
            if limited { throw UsageProviderError.rateLimited(retryAfter: 900) }
            var snapshot = ProviderSnapshot(
                id: id, account: nil, plan: nil,
                windows: [LimitWindow(id: "credits", label: "Weekly allowance", usedFraction: 0.40, resetsAt: nil)],
                fetchedAt: Date())
            snapshot.accountBinding = binding
            return snapshot
        }
    }

    @Test func accountSwitchDuringCooldownDropsReadingAndFetches() async {
        let provider = RateLimitedBoundProvider()
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        provider.set(binding: "a", limited: true)
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.status(for: .grokBuild).snapshot?.accountBinding == "a")
        store.refresh(.grokBuild)  // same account, still cooling down: no request
        await settle(store)
        #expect(provider.calls == 2)

        provider.set(binding: "b", limited: false)
        store.refresh(.grokBuild)
        await settle(store)
        #expect(provider.calls == 3)
        #expect(store.status(for: .grokBuild).snapshot?.accountBinding == "b")
    }

    /// Fetch result carries one binding while the auth file already holds another.
    private final class SplitBindingProvider: UsageProvider, @unchecked Sendable {
        let id: ProviderID = .grokBuild
        private let lock = NSLock()
        private var live: String? = "a"
        private var fetched: String? = "a"
        private var limited = false
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func set(live: String?, fetched: String?, limited: Bool = false) {
            lock.lock(); self.live = live; self.fetched = fetched; self.limited = limited; lock.unlock()
        }
        func currentAccountBinding() -> AccountBindingCheck {
            lock.lock(); defer { lock.unlock() }; return .key(live)
        }
        func fetch() async throws -> ProviderSnapshot {
            lock.lock(); count += 1; let (fetched, limited) = (self.fetched, self.limited); lock.unlock()
            if limited { throw UsageProviderError.rateLimited(retryAfter: 900) }
            return ProviderSnapshot(
                id: id, account: nil, plan: nil,
                windows: [LimitWindow(id: "credits", label: "Weekly allowance", usedFraction: 0.40, resetsAt: nil)],
                fetchedAt: Date(), accountBinding: fetched)
        }
    }

    @Test func inFlightSuccessForPreviousAccountIsNotPublished() async {
        let provider = SplitBindingProvider()
        provider.set(live: "b", fetched: "a")
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.status(for: .grokBuild).snapshot == nil)
        if case .failed = store.status(for: .grokBuild) {} else { Issue.record("expected failed status") }
        provider.set(live: "b", fetched: "b")
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.status(for: .grokBuild).snapshot?.accountBinding == "b")
    }

    @Test func firstReadRateLimitDoesNotBlockAnotherAccount() async {
        let provider = SplitBindingProvider()
        provider.set(live: "a", fetched: "a", limited: true)
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        store.refresh(.grokBuild)  // same account cooling down: skipped
        await settle(store)
        #expect(provider.calls == 1)
        provider.set(live: "b", fetched: "b")
        store.refresh(.grokBuild)
        await settle(store)
        #expect(provider.calls == 2)
        #expect(store.status(for: .grokBuild).snapshot?.accountBinding == "b")
    }

    @Test func accountSwitchDoesNotFireLimitEvents() async {
        let provider = BoundProvider()
        provider.set(binding: "a", fail: false, usage: 1.0)
        let store = UsageStore(providers: [provider], enabledProviders: [.grokBuild])
        store.refresh(.grokBuild)
        await settle(store)
        let revision = store.limitEventRevision
        provider.set(binding: "b", fail: false, usage: 0.02)
        store.refresh(.grokBuild)
        await settle(store)
        #expect(store.limitEventRevision == revision)
        #expect(store.status(for: .grokBuild).snapshot?.accountBinding == "b")
    }
}
