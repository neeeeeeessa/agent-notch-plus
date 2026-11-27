import Foundation
import OSLog

nonisolated struct ClaudeOAuthProvider: UsageProvider {
    private static let log = Logger(subsystem: "io.github.neeeeeeessa.AgentNotchPlus", category: "ClaudeOAuth")
    var id: ProviderID { .claude }

    private static let usageWithResetsEndpoint = URL(string: ProviderHTTP.claudeUsageWithResetsURL)!

    /// Reads Claude Code's existing keychain item only while `fetch` runs. The access token is a local.
    func fetch() async throws -> ProviderSnapshot {
        guard
            let data = try Keychain.data(
                service: ClaudeOAuthStore.claudeCodeService, dataProtection: false)
        else {
            throw UsageProviderError.needsAuth(Self.renewInClaudeCode)
        }
        guard let session = ClaudeOAuthSession.fromClaudeCodeBlob(data) else {
            throw UsageProviderError.needsAuth(Self.renewInClaudeCode)
        }
        guard session.expires > Date() else {
            throw UsageProviderError.needsAuth(Self.renewInClaudeCode)
        }
        let accessToken = session.accessToken
        let body = try await ProviderHTTP.get(
            url: Self.usageWithResetsEndpoint,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
            ],
            authFailed: Self.renewInClaudeCode
        )
        let root = try ProviderJSON.object(body)
        return ProviderSnapshot(
            id: .claude,
            account: nil,
            plan: nil,
            windows: windows(from: root),
            sessions: [],
            fetchedAt: Date(),
            // The API withholds resets from this client; fall back to the last claude.ai page capture.
            resetCredits: resetCredits(from: root) ?? ClaudeResetsPage.load()
        )
    }

    static let renewInClaudeCode =
        "Refresh sign-in in Claude Code. Agent Notch Plus does not sign in or refresh tokens."

    func windows(from root: [String: Any]) -> [LimitWindow] {
        var windows: [LimitWindow] = []
        if let window = bucketWindow(
            root["five_hour"],
            id: "session",
            label: "Current session"
        ) {
            windows.append(window)
        }
        if let window = bucketWindow(
            root["seven_day"],
            id: "weekly",
            label: "All models"
        ) {
            windows.append(window)
        }
        let limits = root["limits"] as? [Any] ?? []
        for entry in limits {
            guard let object = entry as? [String: Any],
                object["kind"] as? String == "weekly_scoped",
                let scope = object["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let displayName = model["display_name"] as? String, !displayName.isEmpty,
                let percent = ProviderJSON.double(object["percent"])
            else { continue }
            windows.append(
                LimitWindow(
                    id: "weekly_\(displayName.lowercased())",
                    label: displayName,
                    usedFraction: percent / 100,
                    resetsAt: (object["resets_at"] as? String).flatMap(JSONDate.parse)
                )
            )
        }
        return windows
    }

    func bucketWindow(_ raw: Any?, id: String, label: String) -> LimitWindow? {
        guard let object = raw as? [String: Any],
            let utilization = ProviderJSON.double(object["utilization"])
        else { return nil }
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: utilization / 100,
            resetsAt: (object["resets_at"] as? String).flatMap(JSONDate.parse)
        )
    }

    func resetCredits(from root: [String: Any], now: Date = Date()) -> ResetCredits? {
        if let block = root["cedar_ember"] as? [String: Any] {
            let eligibleFlag = jsonBool(block["eligible"])
            let reason = (block["ineligible_reason"] as? String) ?? "none"
            let grants = block["grants"] as? [Any] ?? []
            Self.log.notice("claude cedar_ember eligible=\(eligibleFlag.map(String.init) ?? "nil", privacy: .public) reason=\(reason, privacy: .public) grants=\(grants.count)")
            var items: [ResetCredit] = []
            for (index, raw) in grants.enumerated() {
                guard let grant = raw as? [String: Any] else { continue }
                if jsonBool(grant["paused"]) == true { continue }
                guard let resetsLeft = ProviderJSON.int(grant["resets_left"]), resetsLeft > 0 else { continue }
                let endsAt = (grant["ends_at"] as? String).flatMap(JSONDate.parse)
                if let endsAt, endsAt <= now { continue }
                let label = grantLabel(grant)
                let rawID = (grant["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = (rawID?.isEmpty == false ? rawID! : "\(index)-\(label)-\(Int(endsAt?.timeIntervalSince1970 ?? 0))")
                items.append(ResetCredit(id: id, label: label, expiresAt: endsAt, count: resetsLeft))
            }
            items.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            let total = items.reduce(0) { $0 + $1.count }
            if total > 0 { return ResetCredits(availableCount: total, items: items) }
            if eligibleFlag == true || reason == "no_grant" {
                return ResetCredits(availableCount: 0)
            }
            return nil
        }
        Self.log.notice("claude cedar_ember absent")
        if let tide = root["juniper_tide"] as? [String: Any],
           (tide["arm"] as? String) == "reset",
           let available = jsonBool(tide["available"])
        {
            if available {
                return ResetCredits(
                    availableCount: 1,
                    items: [ResetCredit(id: "juniper-5h", label: "5-hour reset", expiresAt: nil, count: 1)]
                )
            }
            return ResetCredits(availableCount: 0)
        }
        return nil
    }

    private func grantLabel(_ grant: [String: Any]) -> String {
        if let explicit = (grant["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty
        {
            return explicit
        }
        if jsonBool(grant["gives_back_weekly"]) == true { return "Fable reset" }
        let kind = ((grant["type"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch kind {
        case "session": return "5-hour reset"
        case "weekly": return "Weekly reset"
        case "full": return "Full reset"
        default: break
        }
        let clears = (grant["clears"] as? [Any])?.compactMap { $0 as? String } ?? []
        let hasFiveHour = clears.contains("five_hour")
        let hasOther = clears.contains { $0 != "five_hour" }
        if hasFiveHour && !hasOther { return "5-hour reset" }
        if hasOther && !hasFiveHour { return "Weekly reset" }
        return "Full reset"
    }

    private func jsonBool(_ any: Any?) -> Bool? {
        guard let number = any as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
