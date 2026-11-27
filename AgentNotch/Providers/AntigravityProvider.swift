import CoreFoundation
import Foundation
import Security

nonisolated struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity

    func fetch() async throws -> ProviderSnapshot {
        let discovery = AntigravityDiscovery()
        var server = discovery.hub()
        if server == nil {
            for candidate in discovery.processEndpoints() {
                try Task.checkCancellation()
                if (try? await candidate.post(.probe)) != nil {
                    server = candidate
                    break
                }
            }
        }
        guard let server else {
            throw UsageProviderError.needsAuth("Open Antigravity to update your usage")
        }
        if let data = try? await server.post(.summary),
           let snapshot = try? AntigravityQuota.parse(data, grouped: true) {
            return snapshot
        }
        try Task.checkCancellation()
        do {
            let data = try await server.post(.status)
            return try AntigravityQuota.parse(data, grouped: false)
        } catch let error as URLError {
            try Task.checkCancellation()
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .timedOut:
                throw UsageProviderError.needsAuth("Open Antigravity to update your usage")
            default:
                throw UsageProviderError.unavailable("Antigravity usage is unavailable")
            }
        }
    }
}

nonisolated struct AntigravityEndpoint {
    enum Method: String, CaseIterable {
        case probe = "GetUnleashData"
        case summary = "RetrieveUserQuotaSummary"
        case status = "GetUserStatus"
    }

    static let path = "/exa.language_server_pb.LanguageServerService/"
    let port: Int
    let token: String
    var plainHTTP = false

    func allows(_ url: URL) -> Bool {
        guard (1...65535).contains(port),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == (plainHTTP ? "http" : "https"),
              parts.host == "127.0.0.1", parts.percentEncodedHost == "127.0.0.1",
              parts.port == port, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        return Method.allCases.contains { parts.percentEncodedPath == Self.path + $0.rawValue }
    }

    func post(_ method: Method) async throws -> Data {
        guard let url = URL(string: "\(plainHTTP ? "http" : "https")://127.0.0.1:\(port)\(Self.path)\(method.rawValue)"),
              allows(url) else { throw UsageProviderError.badResponse("Invalid Antigravity endpoint") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration, delegate: AntigravityLoopbackDelegate(port: port),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UsageProviderError.unavailable("Antigravity usage is unavailable")
        }
        return data
    }
}

nonisolated final class AntigravityLoopbackDelegate: NSObject, URLSessionTaskDelegate {
    let port: Int

    init(port: Int) { self.port = port }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1", space.port == port, !space.isProxy(),
              space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

nonisolated struct AntigravityDiscovery {
    var directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity/daemon")
    var files: @Sendable (URL) -> [URL] = { directory in
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }
    var read: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    var alive: @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
    var run: @Sendable (String, [String]) -> String = { executable, arguments in
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private struct Hub: Decodable {
        var pid: Int32
        var httpPort: Int
        var csrfToken: String
    }

    func hub() -> AntigravityEndpoint? {
        for file in files(directory) where file.lastPathComponent.hasPrefix("hub_") && file.pathExtension == "json" {
            guard let data = read(file), let hub = try? JSONDecoder().decode(Hub.self, from: data),
                  hub.pid > 0, alive(hub.pid), (1...65535).contains(hub.httpPort),
                  Self.validToken(hub.csrfToken) else { continue }
            return AntigravityEndpoint(port: hub.httpPort, token: hub.csrfToken)
        }
        return nil
    }

    func processEndpoints() -> [AntigravityEndpoint] {
        run("/bin/ps", ["-ax", "-o", "pid=,command="]).split(separator: "\n").flatMap { line -> [AntigravityEndpoint] in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0, alive(pid),
                  let process = Self.parseCommand(String(fields[1])) else { return [] }
            let ports = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
                .split(separator: "\n")
                .compactMap { line -> Int? in
                    guard line.hasPrefix("n"), let suffix = line.split(separator: ":").last else { return nil }
                    return Int(suffix)
                }
                .filter { (1...65535).contains($0) }
            var endpoints = Set(ports).sorted().map { AntigravityEndpoint(port: $0, token: process.token) }
            if let extensionPort = process.extensionPort, let token = process.extensionToken {
                endpoints.append(AntigravityEndpoint(port: extensionPort, token: token))
                endpoints.append(AntigravityEndpoint(port: extensionPort, token: token, plainHTTP: true))
            }
            return endpoints
        }
    }

    static func parseCommand(_ command: String) -> (token: String, extensionPort: Int?, extensionToken: String?)? {
        let args = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = args.first,
              executable.hasPrefix("/Applications/Antigravity.app/Contents/"),
              URL(fileURLWithPath: executable).lastPathComponent.hasPrefix("language_server") else { return nil }
        func value(_ flag: String) -> String? {
            for (index, arg) in args.enumerated().dropFirst() {
                if arg == flag, index + 1 < args.count { return args[index + 1] }
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            }
            return nil
        }
        guard let token = value("--csrf_token"), validToken(token) else { return nil }
        let port = value("--extension_server_port").flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
        let extensionToken = value("--extension_server_csrf_token").flatMap { validToken($0) ? $0 : nil }
        return (token, port, extensionToken)
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("--") && token.utf8.allSatisfy { (33...126).contains($0) }
    }
}

nonisolated enum AntigravityQuota {
    private struct Reading {
        var rank: Int
        var label: String
        var remaining: Double
        var reset: Date?
        var verified: Bool
    }

    static func parse(_ data: Data, grouped: Bool, now: Date = Date()) throws -> ProviderSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageProviderError.badResponse("Invalid Antigravity usage response")
        }
        let response = root["response"] as? [String: Any] ?? root
        let status = response["userStatus"] as? [String: Any] ?? response
        let readings = grouped ? groupReadings(response) : modelReadings(status)
        guard readings.contains(where: { $0.remaining < 1 || $0.verified }) else {
            throw UsageProviderError.unavailable("Antigravity limits not available")
        }
        let windows = Dictionary(grouping: readings, by: \.rank).sorted { $0.key < $1.key }.compactMap { rank, readings in
            readings.min(by: { $0.remaining < $1.remaining }).map {
                LimitWindow(id: String(rank), label: $0.label, usedFraction: 1 - $0.remaining, resetsAt: $0.reset)
            }
        }
        let tier = status["userTier"] as? [String: Any]
        return ProviderSnapshot(id: .antigravity, account: (status["email"] ?? status["userEmail"]) as? String,
                                plan: (tier?["description"] ?? tier?["name"] ?? status["planName"]) as? String,
                                windows: windows, fetchedAt: now)
    }

    private static func groupReadings(_ response: [String: Any]) -> [Reading] {
        let groups = response["groups"] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            let name = (group["displayName"] as? String ?? "").lowercased()
            let gemini = name.contains("gemini")
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            return buckets.compactMap { bucket -> Reading? in
                let hints = ["bucketId", "displayName", "cadence", "windowCadence", "description"]
                    .compactMap { bucket[$0] as? String }.joined(separator: " ").lowercased()
                let normalized = hints.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                let weekly = normalized.contains("week") || normalized.contains("7 day")
                let session = ["five hour", "5 hour", "5h", "session", "18000"].contains { normalized.contains($0) }
                guard weekly || session, let info = bucket["remaining"] as? [String: Any],
                      let remaining = fraction(info["remainingFraction"]) else { return nil }
                let reset = date(bucket["resetTime"] ?? info["resetTime"] ?? bucket["resetsAt"])
                return Reading(rank: (gemini ? 0 : 2) + (weekly ? 1 : 0),
                               label: (gemini ? "Gemini" : "Claude + GPT") + (weekly ? " weekly" : " session"),
                               remaining: remaining, reset: reset,
                               verified: reset != nil || (info["verified"] as? Bool == true))
            }
        }
    }

    private static func modelReadings(_ status: [String: Any]) -> [Reading] {
        let config = status["cascadeModelConfigData"] as? [String: Any]
        let models = config?["clientModelConfigs"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard let quota = model["quotaInfo"] as? [String: Any],
                  let remaining = fraction(quota["remainingFraction"]) else { return nil }
            let name = (model["label"] ?? model["modelName"] ?? model["model"]) as? String ?? ""
            let gemini = name.localizedCaseInsensitiveContains("gemini")
            let reset = date(quota["resetTime"])
            return Reading(rank: gemini ? 0 : 2, label: gemini ? "Gemini" : "Claude + GPT",
                           remaining: remaining, reset: reset,
                           verified: reset != nil || (quota["verified"] as? Bool == true))
        }
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              (0...1).contains(value.doubleValue) else { return nil }
        return value.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init),
           seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }
}
