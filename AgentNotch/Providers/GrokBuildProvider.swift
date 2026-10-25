import CryptoKit
import Foundation

// Portions adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// Upstream pinned at https://github.com/vinzdg/codenotch/commit/6522e9f3ee0fe35d46e428b441e6e80b586eacbb
// The bundled notice is AgentNotch/Resources/Codenotch-LICENSE.txt.
// Access tokens are request-scoped. Refresh tokens, client ids, and email are not read or stored.

enum GrokBuildAuth {
    static let trustedIssuer = "https://auth.x.ai"
    static let needsSignIn = "Sign in with the Grok CLI to read Grok usage"
    static let maxBytes = 256 * 1024

    struct Session: Equatable {
        var accessToken: String
        var expiresAt: Date
        /// SHA-256 of the subject. The raw subject is never stored.
        var accountKey: String? = nil
    }

    static var defaultAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    static func load(from url: URL, now: Date = Date()) throws -> Session {
        let data = try readFile(at: url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageProviderError.needsAuth(needsSignIn)
        }
        let live = root.compactMap { key, value -> Session? in
            guard let entry = value as? [String: Any], isTrusted(key: key, entry: entry) else { return nil }
            guard let token = entry["key"] as? String, !token.isEmpty else { return nil }
            guard let expiresAt = expiry(entry["expires_at"]), expiresAt > now else { return nil }
            return Session(accessToken: token, expiresAt: expiresAt, accountKey: accountKey(for: token))
        }
        guard live.count == 1, let session = live.first else {
            throw UsageProviderError.needsAuth(needsSignIn)
        }
        return session
    }

    /// Hash only, so a subject from the access token never sits in the session or the UI.
    static func accountKey(for accessToken: String) -> String? {
        let parts = accessToken.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        guard let payload = base64URLDecode(parts[1]) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        guard let sub = object["sub"] as? String, !sub.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("grok-sub:\(sub)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }

    static func isTrusted(key: String, entry: [String: Any]) -> Bool {
        guard let separator = key.range(of: "::") else { return false }
        let issuer = String(key[..<separator.lowerBound])
        let clientID = String(key[separator.upperBound...])
        guard issuer == trustedIssuer, !clientID.isEmpty else { return false }
        if entry.keys.contains("oidc_issuer") {
            guard (entry["oidc_issuer"] as? String) == trustedIssuer else { return false }
        }
        return true
    }

    static func expiry(_ any: Any?) -> Date? {
        if let text = any as? String { return JSONDate.parse(text) }
        guard let number = any as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        let seconds = raw >= 100_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func readFile(at url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        if values?.isSymbolicLink == true { throw UsageProviderError.needsAuth(needsSignIn) }
        guard values?.isRegularFile == true else { throw UsageProviderError.needsAuth(needsSignIn) }
        if let size = values?.fileSize, size > maxBytes { throw UsageProviderError.needsAuth(needsSignIn) }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.uncached])
        } catch {
            throw UsageProviderError.needsAuth(needsSignIn)
        }
        guard data.count <= maxBytes else { throw UsageProviderError.needsAuth(needsSignIn) }
        return data
    }
}

enum GrokBuildUsage {
    /// Headline is only `creditUsagePercent`. Product rows are a breakdown, never a stand-in for that total.
    static func parse(_ data: Data) throws -> (windows: [LimitWindow], billing: GrokBilling, tier: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let config = root["config"] as? [String: Any]
        else { throw UsageProviderError.badResponse("unreadable Grok billing") }

        guard let overall = percentPoints(config["creditUsagePercent"]) else {
            throw UsageProviderError.unavailable("Grok billing did not report overall usage")
        }

        let period = config["currentPeriod"] as? [String: Any]
        let periodType = period?["type"] as? String
        let weekly = periodType?.contains("WEEKLY") == true
        let window = LimitWindow(
            id: "credits",
            label: weekly ? "Weekly allowance" : "Allowance",
            usedFraction: overall / 100,
            resetsAt: date(period?["end"]) ?? date(config["billingPeriodEnd"])
        )
        let productRows = products(from: config["productUsage"])
        let billing = GrokBilling(
            products: productRows.rows,
            periodIsWeekly: periodType.map { $0.contains("WEEKLY") },
            periodStart: date(period?["start"]),
            periodEnd: date(period?["end"]),
            isUnifiedBilling: jsonBool(config["isUnifiedBillingUser"]),
            prepaidBalanceCents: cents(config["prepaidBalance"]),
            onDemandEnabled: jsonBool(root["on_demand_enabled"]),
            onDemandUsedCents: cents(config["onDemandUsed"]),
            onDemandCapCents: cents(config["onDemandCap"]),
            topUpMethod: (config["topUpMethod"] as? String).flatMap(topUpPhrase),
            omittedProducts: productRows.omitted,
            omittedProductPercent: productRows.omittedPercent,
            conflictingProducts: productRows.conflicting
        )
        let tier = (root["subscription_tier"] as? String).flatMap(tierPhrase)
        return ([window], billing, tier)
    }

    static func humanize(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return result
    }

    private static let preferredProductKeys: Set<String> = ["GrokBuild", "GrokBot", "Cursor"]

    private static func products(from any: Any?) -> (rows: [UsageShare], omitted: Int, omittedPercent: Double, conflicting: [String]) {
        let rows: [Any]
        if let list = any as? [Any] {
            rows = list
        } else if let list = any as? [[String: Any]] {
            rows = list.map { $0 as Any }
        } else {
            return ([], 0, 0, [])
        }
        var firstPercent: [String: Double] = [:]
        var valid: [UsageShare] = []
        var conflicting: [String] = []
        var conflicted = Set<String>()
        for row in rows {
            guard let object = row as? [String: Any],
                let key = object["product"] as? String,
                isToken(key),
                let points = percentPoints(object["usagePercent"])
            else { continue }
            if let previous = firstPercent[key] {
                // A later copy with the same percent is ignored. A different percent makes the product ambiguous.
                if !conflicted.contains(key), abs(previous - points) > 0.0001 {
                    conflicting.append(productLabel(key))
                    conflicted.insert(key)
                    valid.removeAll { $0.id == key }
                }
                continue
            }
            firstPercent[key] = points
            valid.append(UsageShare(id: key, label: productLabel(key), percentOfAllowance: points))
        }
        guard valid.count > 8 else { return (valid, 0, 0, conflicting) }
        var chosen = Set<String>()
        for share in valid where preferredProductKeys.contains(share.id) {
            chosen.insert(share.id)
        }
        for share in valid where !chosen.contains(share.id) {
            guard chosen.count < 8 else { break }
            chosen.insert(share.id)
        }
        let kept = valid.filter { chosen.contains($0.id) }
        let omittedPercent = valid.reduce(0.0) { partial, share in
            chosen.contains(share.id) ? partial : partial + share.percentOfAllowance
        }
        return (kept, valid.count - kept.count, omittedPercent, conflicting)
    }

    private static func productLabel(_ key: String) -> String {
        switch key {
        case "GrokBuild": "Grok Build"
        case "GrokBot": "Grok Bot"
        case "Cursor": "Cursor"
        default: humanize(key)
        }
    }

    private static func percentPoints(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value = number.doubleValue
        // Above 10_000 is not a usable allowance figure: the headline becomes unavailable and the row is skipped.
        guard value.isFinite, value >= 0, value <= 10_000 else { return nil }
        return value
    }

    private static func jsonBool(_ any: Any?) -> Bool? {
        guard let number = any as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// `{}` is zero cents. A missing key is nil. A negative amount is unknown.
    private static func cents(_ any: Any?) -> Int64? {
        guard let object = any as? [String: Any] else { return nil }
        if object.isEmpty { return 0 }
        guard let val = object["val"] else { return nil }
        if let text = val as? String { return cents(text) }
        guard let number = val as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, let exact = Int64(exactly: value) else { return nil }
        return exact
    }

    /// 1–18 ASCII digits. A leading minus is not a sign; the amount is unknown.
    private static func cents(_ text: String) -> Int64? {
        guard (1...18).contains(text.count), text.allSatisfy({ $0.isASCII && $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return Int64(text)
    }

    private static func topUpPhrase(_ raw: String) -> String? {
        if raw == "TOP_UP_METHOD_UNSPECIFIED" { return nil }
        guard raw.range(of: #"^TOP_UP_METHOD_[A-Z_]{1,48}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return phrase(String(raw.dropFirst("TOP_UP_METHOD_".count)))
    }

    private static func tierPhrase(_ raw: String) -> String? {
        guard isToken(raw) else { return nil }
        let prefix = "SUBSCRIPTION_TIER_"
        let body = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        guard !body.isEmpty else { return nil }
        return phrase(body)
    }

    private static func phrase(_ raw: String) -> String {
        ProviderJSON.capitalised(raw.lowercased().replacingOccurrences(of: "_", with: " "))
    }

    private static func isToken(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 40 else { return false }
        return raw.allSatisfy { character in
            character.isLetter || character.isNumber || character == " " || character == "_" || character == "-"
        }
    }

    private static func date(_ any: Any?) -> Date? {
        GrokBuildAuth.expiry(any)
    }
}

/// Asks the Grok CLI to renew its own sign-in when the saved access token has expired.
/// The CLI stays the only reader and writer of its refresh token, so the app never races it on rotation.
nonisolated final class GrokCLIRenewal: @unchecked Sendable {
    static let shared = GrokCLIRenewal()
    /// One attempt per window, so a signed-out CLI is not launched on every poll.
    static let minInterval: TimeInterval = 600
    static let candidatePaths = [
        "/opt/homebrew/bin/grok",
        "/usr/local/bin/grok",
        NSHomeDirectory() + "/.local/bin/grok",
    ]

    private let lock = NSLock()
    private var lastAttempt: Date?
    private let clock: @Sendable () -> Date
    private let runCLI: @Sendable () -> Void

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        runCLI: @escaping @Sendable () -> Void = { GrokCLIRenewal.runModelsCommand() }
    ) {
        self.clock = clock
        self.runCLI = runCLI
    }

    /// Returns false when an attempt already ran inside `minInterval`.
    func renew() async -> Bool {
        let now = clock()
        let allowed: Bool = lock.withLock {
            if let last = lastAttempt, now.timeIntervalSince(last) < Self.minInterval { return false }
            lastAttempt = now
            return true
        }
        guard allowed else { return false }
        let run = runCLI
        await Task.detached { run() }.value
        return true
    }

    /// `grok models` sends no prompt. Loading the signed-in config renews an expired token as a side effect.
    static func runModelsCommand() {
        guard let path = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        _ = LocalSecurityTool.run(
            executable: URL(fileURLWithPath: path),
            arguments: ["models"],
            options: LocalSecurityTool.Options(timeout: 30)
        )
    }
}

/// Reads the shared Grok allowance with the CLI access token. Never reads the refresh token;
/// an expired token is renewed by the CLI itself through `GrokCLIRenewal`.
struct GrokBuildProvider: UsageProvider {
    var id: ProviderID { .grokBuild }
    var authURL: URL
    var renewal: GrokCLIRenewal

    static let billingURL = URL(string: ProviderHTTP.grokBuildBillingURL)!

    init(authURL: URL = GrokBuildAuth.defaultAuthURL, renewal: GrokCLIRenewal = .shared) {
        self.authURL = authURL
        self.renewal = renewal
    }

    func currentAccountBinding() -> AccountBindingCheck {
        .key((try? GrokBuildAuth.load(from: authURL))?.accountKey)
    }

    /// The saved session, or the one the CLI writes after renewing an expired token.
    func session() async throws -> GrokBuildAuth.Session {
        if let session = try? GrokBuildAuth.load(from: authURL) { return session }
        _ = await renewal.renew()
        return try GrokBuildAuth.load(from: authURL)
    }

    func fetch() async throws -> ProviderSnapshot {
        let session = try await session()
        let data = try await ProviderHTTP.get(
            url: Self.billingURL,
            headers: [
                "Authorization": "Bearer \(session.accessToken)",
                "X-XAI-Token-Auth": "xai-grok-cli",
                "Accept": "application/json",
            ],
            authFailed: GrokBuildAuth.needsSignIn
        )
        let parsed = try GrokBuildUsage.parse(data)
        return ProviderSnapshot(
            id: id,
            account: nil,
            plan: parsed.tier,
            windows: parsed.windows,
            fetchedAt: Date(),
            sourceIsStale: false,
            grokBilling: parsed.billing,
            accountBinding: session.accountKey
        )
    }
}
