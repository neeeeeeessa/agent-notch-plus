import Foundation
import SwiftUI

/// Identity of a usage source. Raw values are persisted in preferences.
nonisolated enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex
    case grokBuild

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grokBuild: "Grok"
        }
    }

    /// Where the account is managed. Codex stays in its own app.
    var manageURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/#settings/Account")!
        case .grokBuild: URL(string: "https://accounts.x.ai")!
        }
    }

    var manageTitle: String {
        switch self {
        case .claude: "Open Claude"
        case .codex: "Open Codex"
        case .grokBuild: "Open Grok"
        }
    }

    /// Name of the tool that owns the credential on this Mac.
    var ownerTool: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grokBuild: "Grok CLI"
        }
    }

    var signInHint: String {
        switch self {
        case .claude: "Sign in with Claude to read your usage"
        case .codex: "Sign in to Codex to read your usage"
        case .grokBuild: "Sign in with the Grok CLI to read your Grok usage"
        }
    }

    /// Stable identity colour. Independent of usage band.
    var accentColor: Color {
        switch self {
        case .claude:
            Color(.sRGB, red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0, opacity: 1)
        case .codex:
            Color(.sRGB, red: 122.0 / 255.0, green: 157.0 / 255.0, blue: 255.0 / 255.0, opacity: 1)
        case .grokBuild:
            Color(.sRGB, red: 0.0 / 255.0, green: 191.0 / 255.0, blue: 168.0 / 255.0, opacity: 1)
        }
    }
}

/// One metered limit window, e.g. Claude's five hour session or the Grok weekly allowance.
nonisolated struct LimitWindow: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var label: String
    /// 0...1, may exceed 1 when a provider reports overage.
    var usedFraction: Double
    var resetsAt: Date?

    var band: UsageBand { UsageBand(fraction: usedFraction) }
}

/// A live agent process owned by the provider's tool, shown under the limits.
nonisolated struct AgentSession: Codable, Sendable, Identifiable, Equatable {
    enum Activity: String, Codable, Sendable {
        case idle
        case working
        case waiting
    }

    var id: String
    var name: String
    var detail: String
    var activity: Activity
    var startedAt: Date
}

/// One product's share of a pooled allowance. `percentOfAllowance` is percentage points, as reported.
nonisolated struct UsageShare: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var percentOfAllowance: Double
}

/// Extra Grok billing fields. Product rows are only those the server reported with a valid percent.
nonisolated struct GrokBilling: Codable, Sendable, Equatable {
    var products: [UsageShare] = []
    var periodIsWeekly: Bool?
    var periodStart: Date?
    var periodEnd: Date?
    var isUnifiedBilling: Bool?
    var prepaidBalanceCents: Int64?
    var onDemandEnabled: Bool?
    var onDemandUsedCents: Int64?
    var onDemandCapCents: Int64?
    var topUpMethod: String?
    /// Valid product rows past the eight the card keeps.
    var omittedProducts: Int = 0
    /// Sum of `percentOfAllowance` for the valid rows the card does not keep.
    var omittedProductPercent: Double = 0
    /// Labels of products dropped because two valid rows disagreed. Shown as neither value.
    var conflictingProducts: [String] = []
}

/// A complete reading from one provider.
nonisolated struct ProviderSnapshot: Codable, Sendable, Equatable {
    var id: ProviderID
    var account: String?
    var plan: String?
    var windows: [LimitWindow]
    var sessions: [AgentSession] = []
    var fetchedAt: Date
    /// True when the provider's own source is already old. A fresh fetch of an expired cache stays stale.
    var sourceIsStale: Bool = false
    var grokBilling: GrokBilling? = nil
    /// RAM-only account identity used to avoid showing one account's reading for another. Never displayed, logged or persisted.
    var accountBinding: String? = nil

    /// The window that drives the ring: the first one, which every provider orders as its headline.
    var headline: LimitWindow? { windows.first }

    private enum CodingKeys: String, CodingKey {
        case id, account, plan, windows, sessions, fetchedAt, sourceIsStale, grokBilling
    }

    init(
        id: ProviderID,
        account: String?,
        plan: String?,
        windows: [LimitWindow],
        sessions: [AgentSession] = [],
        fetchedAt: Date,
        sourceIsStale: Bool = false,
        grokBilling: GrokBilling? = nil,
        accountBinding: String? = nil
    ) {
        self.id = id
        self.account = account
        self.plan = plan
        self.windows = windows
        self.sessions = sessions
        self.fetchedAt = fetchedAt
        self.sourceIsStale = sourceIsStale
        self.grokBilling = grokBilling
        self.accountBinding = accountBinding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        windows = try container.decode([LimitWindow].self, forKey: .windows)
        sessions = try container.decode([AgentSession].self, forKey: .sessions)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        sourceIsStale = try container.decode(Bool.self, forKey: .sourceIsStale)
        grokBilling = try container.decodeIfPresent(GrokBilling.self, forKey: .grokBilling)
        accountBinding = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encode(windows, forKey: .windows)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(sourceIsStale, forKey: .sourceIsStale)
        try container.encodeIfPresent(grokBilling, forKey: .grokBilling)
    }
}

/// Colour band derived from how much of a window is used.
nonisolated enum UsageBand: Sendable {
    case ample
    case watch
    case critical
    case exhausted

    init(fraction: Double) {
        switch fraction {
        case ..<0.5: self = .ample
        case ..<0.7: self = .watch
        case ..<1.0: self = .critical
        default: self = .exhausted
        }
    }

    var color: Color {
        switch self {
        case .ample: Color(red: 0.13, green: 0.92, blue: 0.53)
        case .watch: Color(red: 0.84, green: 0.89, blue: 0.09)
        case .critical: Color(red: 1.0, green: 0.36, blue: 0.16)
        case .exhausted: Color(red: 1.0, green: 0.23, blue: 0.19)
        }
    }
}

/// What the notch knows about a provider right now.
nonisolated enum ProviderStatus: Sendable, Equatable {
    /// No reading yet and nothing cached.
    case waiting
    /// A reading, possibly stale if `stale` is set because the last refresh failed.
    case ready(ProviderSnapshot, stale: Bool)
    /// The owning tool is signed out or its credential expired.
    case needsAuth(String)
    /// The read failed for another reason.
    case failed(String)

    var snapshot: ProviderSnapshot? {
        if case .ready(let snapshot, _) = self { return snapshot }
        return nil
    }

    var isStale: Bool {
        if case .ready(_, true) = self { return true }
        return false
    }
}

nonisolated enum UsageProviderError: Error, Sendable {
    /// The tool that owns the account is signed out, or the credential is unusable.
    case needsAuth(String)
    /// Nothing to read yet, e.g. Codex has not written a rate limit snapshot.
    case unavailable(String)
    /// The endpoint answered with something unexpected.
    case badResponse(String)
    /// The endpoint is rate limiting. `retryAfter` is seconds from a usable Retry-After header.
    case rateLimited(retryAfter: TimeInterval?)

    var message: String {
        switch self {
        case .needsAuth(let message), .unavailable(let message), .badResponse(let message):
            message
        case .rateLimited:
            "Usage is rate limited; retrying shortly"
        }
    }
}

/// Local, no-network check for whether the next fetch still belongs to the account last shown.
nonisolated enum AccountBindingCheck: Sendable, Equatable {
    case notApplicable
    case key(String?)
}

/// A usage source. Each one reads a credential that is already on this Mac.
nonisolated protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
    /// Local, no-network identity of the account the next fetch would use. nil means the provider does not bind accounts.
    func currentAccountBinding() -> AccountBindingCheck
}

extension UsageProvider {
    nonisolated func currentAccountBinding() -> AccountBindingCheck { .notApplicable }
}
