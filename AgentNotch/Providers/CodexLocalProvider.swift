import Foundation

nonisolated struct CodexLocalProvider: UsageProvider {
    var id: ProviderID { .codex }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static let sessionLogScanningDisabled = "Session log scanning is disabled"

    func fetch() async throws -> ProviderSnapshot {
        guard let live = try await liveSnapshot() else {
            throw UsageProviderError.needsAuth("Sign in to Codex to read your usage")
        }
        return live
    }

    func liveSnapshot() async throws -> ProviderSnapshot? {
        guard let blob = try authBlob(), let token = quotaAccessToken(in: blob) else { return nil }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
        ]
        if let accountID = authAccountID(in: blob) {
            headers["chatgpt-account-id"] = accountID
        }
        let data = try await ProviderHTTP.get(
            url: Self.usageURL,
            headers: headers,
            authFailed: "Sign in to Codex to read your usage"
        )
        return try snapshot(from: try ProviderJSON.object(data))
    }

    /// Rollout and state-database scanning is retired. This returns before any file access.
    func snapshotFromRollouts() throws -> ProviderSnapshot {
        throw UsageProviderError.unavailable(Self.sessionLogScanningDisabled)
    }

    func authBlob() throws -> Data? {
        if let data = authFileData() { return data }
        return try Keychain.data(service: "Codex Auth", dataProtection: false)
    }

    func authFileData() -> Data? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/auth.json")
        return try? Data(contentsOf: url)
    }

    /// Live quota calls accept only an OAuth access token. API keys are not sent to the usage endpoint.
    func quotaAccessToken(in data: Data?) -> String? {
        guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// Legacy parser kept for the pure API-key test. Live fetch and auth checks do not call this.
    func authToken(in data: Data?) -> String? {
        guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let tokens = json["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        {
            return token
        }
        if let token = json["OPENAI_API_KEY"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    func authAccountID(in data: Data?) -> String? {
        guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any],
            let id = tokens["account_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    func rateLimits(in data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() where line.contains("\"rate_limits\"") {
            guard let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData),
                let found = firstRateLimits(json)
            else { continue }
            return found
        }
        return nil
    }

    private func firstRateLimits(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let nested = dict["rate_limits"] as? [String: Any] {
                return nested
            }
            for child in dict.values {
                if let found = firstRateLimits(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstRateLimits(child) { return found }
            }
        }
        return nil
    }

    func snapshot(from limits: [String: Any]) throws -> ProviderSnapshot {
        let nested = limits["rate_limit"] as? [String: Any] ?? limits
        var windows: [LimitWindow] = []
        let primary = nested["primary_window"] ?? nested["primary"] ?? limits["primary"]
        let secondary = nested["secondary_window"] ?? nested["secondary"] ?? limits["secondary"]
        if let window = window(id: "primary", from: primary) {
            windows.append(window)
        }
        if let window = window(id: "secondary", from: secondary) {
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.unavailable("Codex reported no usage windows")
        }
        let plan = ((limits["plan_type"] as? String) ?? (nested["plan_type"] as? String))
            .flatMap { $0.isEmpty ? nil : $0 }
        return ProviderSnapshot(
            id: .codex,
            account: nil,
            plan: plan.map(ProviderJSON.capitalised),
            windows: windows,
            fetchedAt: Date()
        )
    }

    func window(id: String, from raw: Any?) -> LimitWindow? {
        guard let object = raw as? [String: Any],
            let used = ProviderJSON.double(object["used_percent"])
        else { return nil }
        let minutes =
            ProviderJSON.int(object["window_minutes"])
            ?? ProviderJSON.int(object["window_duration_mins"])
            ?? ProviderJSON.int(object["limit_window_seconds"]).map { $0 / 60 }
        guard let minutes else { return nil }
        let resetRaw = ProviderJSON.double(object["resets_at"]) ?? ProviderJSON.double(object["reset_at"])
        let resets = resetRaw.map { Date(timeIntervalSince1970: $0) }
        return LimitWindow(
            id: id,
            label: label(minutes: minutes),
            usedFraction: used / 100,
            resetsAt: resets
        )
    }

    private func label(minutes: Int) -> String {
        switch minutes {
        case 300: "Current session"
        case 10080: "Weekly limit"
        default:
            if minutes % 1440 == 0 {
                "\(minutes / 1440) day limit"
            } else {
                "\(minutes / 60) hour limit"
            }
        }
    }
}
