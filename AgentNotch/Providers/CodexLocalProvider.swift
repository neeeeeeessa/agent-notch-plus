import Foundation

nonisolated struct CodexLocalProvider: UsageProvider {
    var id: ProviderID { .codex }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let resetCreditsURL = URL(string: ProviderHTTP.codexResetCreditsURL)!

    static let sessionLogScanningDisabled = "Session log scanning is disabled"

    func fetch() async throws -> ProviderSnapshot {
        guard let live = try await liveSnapshot() else {
            throw UsageProviderError.needsAuth("Sign in to ChatGPT to read your usage")
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
            authFailed: "Sign in to ChatGPT to read your usage"
        )
        let usageObject = try ProviderJSON.object(data)
        var result = try snapshot(from: usageObject)
        if shouldFetchResetCreditDetails(in: usageObject) {
            var creditHeaders = headers
            creditHeaders["originator"] = "Codex Desktop"
            creditHeaders["OAI-Product-Sku"] = "CODEX"
            do {
                let creditsData = try await ProviderHTTP.get(
                    url: Self.resetCreditsURL,
                    headers: creditHeaders,
                    authFailed: "Sign in to ChatGPT to read your usage"
                )
                if let detailed = parseResetCredits(from: try ProviderJSON.object(creditsData)) {
                    result.resetCredits = detailed
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the primary usage snapshot and any summary available_count when detail fetch fails.
            }
        }
        return result
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
            throw UsageProviderError.unavailable("ChatGPT reported no usage windows")
        }
        let plan = ((limits["plan_type"] as? String) ?? (nested["plan_type"] as? String))
            .flatMap { $0.isEmpty ? nil : $0 }
        let resetCredits = resetCreditsSummary(from: limits, nested: nested)
        return ProviderSnapshot(
            id: .codex,
            account: nil,
            plan: plan.map(ProviderJSON.capitalised),
            windows: windows,
            fetchedAt: Date(),
            resetCredits: resetCredits
        )
    }

    func shouldFetchResetCreditDetails(in usageObject: [String: Any]) -> Bool {
        let nested = usageObject["rate_limit"] as? [String: Any]
        if let summary = (usageObject["rate_limit_reset_credits"] as? [String: Any])
            ?? (nested?["rate_limit_reset_credits"] as? [String: Any]),
            let available = ProviderJSON.int(summary["available_count"])
        {
            return available > 0
        }
        return true
    }

    private func resetCreditsSummary(from limits: [String: Any], nested: [String: Any]) -> ResetCredits? {
        guard let summary = (limits["rate_limit_reset_credits"] as? [String: Any])
            ?? (nested["rate_limit_reset_credits"] as? [String: Any]),
            let available = ProviderJSON.int(summary["available_count"]),
            available >= 0
        else { return nil }
        return ResetCredits(availableCount: available)
    }

    func parseResetCredits(from object: [String: Any], now: Date = Date()) -> ResetCredits? {
        let hasCreditsKey = object["credits"] is [Any]
        let reportedCount = ProviderJSON.int(object["available_count"])
        guard hasCreditsKey || reportedCount != nil else { return nil }
        let rawList = (object["credits"] as? [Any]) ?? []
        var items: [ResetCredit] = []
        for (index, raw) in rawList.enumerated() {
            guard let entry = raw as? [String: Any] else { continue }
            if let status = (entry["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !status.isEmpty,
               status.lowercased() != "available"
            {
                continue
            }
            let expiresAt = parseDate(entry["expires_at"])
            if let expiresAt, expiresAt <= now { continue }
            let label = resetCreditLabel(entry)
            let rawID = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (rawID?.isEmpty == false ? rawID! : "\(index)-\(label)-\(Int(expiresAt?.timeIntervalSince1970 ?? 0))")
            items.append(ResetCredit(id: id, label: label, expiresAt: expiresAt))
        }
        items.sort {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
        let count = !items.isEmpty ? items.count : max(0, reportedCount ?? 0)
        return ResetCredits(availableCount: count, items: items)
    }

    private func resetCreditLabel(_ entry: [String: Any]) -> String {
        if let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            return title
        }
        let resetType = ((entry["reset_type"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch resetType {
        case "primary", "five_hour", "5h", "session":
            return "5-hour reset"
        case "secondary", "weekly", "seven_day", "7d":
            return "Weekly reset"
        case "full", "all", "both", "":
            return "Full reset"
        default:
            return ProviderJSON.capitalised(resetType.replacingOccurrences(of: "_", with: " "))
        }
    }

    private func parseDate(_ raw: Any?) -> Date? {
        if let text = raw as? String {
            return JSONDate.parse(text)
        }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            guard value.isFinite, value > 0 else { return nil }
            let seconds = value >= 100_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
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
