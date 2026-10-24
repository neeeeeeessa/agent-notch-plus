import Foundation
import SQLite3

nonisolated enum JSONDate: Sendable {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }
}

nonisolated enum ProviderJSON: Sendable {
    static func object(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageProviderError.badResponse("unreadable JSON")
        }
        guard let object = value as? [String: Any] else {
            throw UsageProviderError.badResponse("expected a JSON object")
        }
        return object
    }

    static func double(_ any: Any?) -> Double? {
        if any is NSNull { return nil }
        if let number = any as? NSNumber { return number.doubleValue }
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? String { return Double(value) }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if any is NSNull { return nil }
        if let number = any as? NSNumber { return number.intValue }
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String { return Int(value) }
        return nil
    }

    static func capitalised(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }
}

nonisolated enum ProviderHTTP: Sendable {
    static let grokBuildBillingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let allowedUsageURLs: Set<String> = [
        "https://api.anthropic.com/api/oauth/usage",
        "https://chatgpt.com/backend-api/wham/usage",
        grokBuildBillingURL,
    ]
    static let blockedEndpoint = "Usage request blocked: endpoint is not allowlisted"
    static let requestTimeout: TimeInterval = 20

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https",
            url.user == nil,
            url.password == nil,
            url.port == nil,
            (url.fragment ?? "").isEmpty
        else { return false }
        let absolute = url.absoluteString
        guard allowedUsageURLs.contains(absolute) else { return false }
        if url.query != nil {
            return absolute == grokBuildBillingURL
        }
        return true
    }

    /// Retry-After is delay-seconds or an IMF-fixdate. Anything else is ignored so the store can pick its own cooldown.
    static func retryAfterSeconds(_ value: String?, now: Date) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let seconds: TimeInterval
        if raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            guard let parsed = TimeInterval(raw), parsed.isFinite else { return nil }
            seconds = parsed
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: raw) else { return nil }
            seconds = date.timeIntervalSince(now)
        }
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, 3600)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        return config
    }

    static func get(url: URL, headers: [String: String], authFailed: String) async throws -> Data {
        #if AGENTNOTCH_DEMO
        throw UsageProviderError.unavailable("Demo mode does not access accounts")
        #else
        guard allows(url) else {
            throw UsageProviderError.unavailable(blockedEndpoint)
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("AgentNotch/1.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let delegate = RedirectRejector()
        let session = URLSession(
            configuration: makeConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageProviderError.badResponse("request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageProviderError.badResponse("missing HTTP response")
        }
        if (300...399).contains(http.statusCode) {
            throw UsageProviderError.badResponse("redirect rejected")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw UsageProviderError.needsAuth(authFailed)
        case 429:
            throw UsageProviderError.rateLimited(
                retryAfter: retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
            )
        default:
            throw UsageProviderError.badResponse("HTTP \(http.statusCode)")
        }
        #endif
    }
}

/// Refuses every redirect. A 3xx must not be followed, including to another allowlisted host.
final class ProviderHTTPRedirectRejector: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension ProviderHTTP {
    typealias RedirectRejector = ProviderHTTPRedirectRejector
}

nonisolated enum ReadonlySQLite: Sendable {
    static func queryColumn(path: String, sql: String, bind: String? = nil) -> [String]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        let allowed = CharacterSet.urlPathAllowed
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let uri = "file:\(encoded)?immutable=1"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let opened = sqlite3_open_v2(uri, &db, flags, nil)
        guard opened == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if let bind {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(stmt, 1, bind, -1, transient) == SQLITE_OK else { return nil }
        }

        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                rows.append(String(cString: cString))
            }
        }
        return rows
    }
}
