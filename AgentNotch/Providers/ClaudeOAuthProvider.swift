import Foundation

nonisolated struct ClaudeOAuthProvider: UsageProvider {
    var id: ProviderID { .claude }

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
            url: ClaudeOAuth.usageEndpoint,
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
            fetchedAt: Date()
        )
    }

    static let renewInClaudeCode =
        "Refresh sign-in in Claude Code. Agent Notch does not sign in or refresh tokens."

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
}
