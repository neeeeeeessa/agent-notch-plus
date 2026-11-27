import CoreFoundation
import Foundation
import Security

nonisolated struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity

    var discovery = AntigravityDiscovery()
    var transport: @Sendable (AntigravityEndpoint, AntigravityEndpoint.Method) async throws -> Data = {
        try await $0.post($1)
    }

    @concurrent
    func fetch() async throws -> ProviderSnapshot {
        let hub = discovery.hub()
        try Task.checkCancellation()
        var answeredWithout: UsageProviderError?
        if let hub {
            do {
                if let snapshot = try await read(hub) { return snapshot }
            } catch let error as UsageProviderError {
                answeredWithout = error
            }
        }
        for candidate in discovery.processEndpoints() {
            try Task.checkCancellation()
            do {
                if let snapshot = try await read(candidate) { return snapshot }
            } catch let error as UsageProviderError {
                answeredWithout = answeredWithout ?? error
            }
        }
        try Task.checkCancellation()
        throw answeredWithout ?? UsageProviderError.needsAuth("Open Antigravity to update your usage")
    }

    /// Asks one candidate for quota: the grouped summary first, then per-model status.
    /// HTTPS first; plain HTTP on the same loopback port only after a TLS or transport failure.
    /// Returns nil when nothing answered there, and throws when the server answered without usable quota.
    private func read(_ candidate: AntigravityEndpoint) async throws -> ProviderSnapshot? {
        for plainHTTP in [false, true] {
            var endpoint = candidate
            endpoint.plainHTTP = plainHTTP
            var answered = false
            var failure: UsageProviderError?
            methods: for (method, grouped) in [(AntigravityEndpoint.Method.summary, true), (.status, false)] {
                try Task.checkCancellation()
                do {
                    let data = try await transport(endpoint, method)
                    answered = true
                    do {
                        return try AntigravityQuota.parse(data, grouped: grouped)
                    } catch let error as UsageProviderError {
                        failure = error
                    }
                } catch let error as URLError {
                    if !answered, !Self.permitsHTTPFallback(error.code) { return nil }
                    break methods
                } catch let error as UsageProviderError {
                    answered = true
                    failure = failure ?? error
                }
            }
            if answered {
                if let failure { throw failure }
                return nil
            }
        }
        return nil
    }

    private static func permitsHTTPFallback(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotParseResponse,
             .badServerResponse, .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            true
        default:
            false
        }
    }

}

nonisolated struct AntigravityEndpoint {
    enum Method: String, CaseIterable {
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
        #if AGENTNOTCH_DEMO
        throw UsageProviderError.unavailable("Antigravity networking is disabled in demo mode")
        #else
        guard let url = URL(string: "\(plainHTTP ? "http" : "https")://127.0.0.1:\(port)\(Self.path)\(method.rawValue)"),
              allows(url) else { throw UsageProviderError.badResponse("Invalid Antigravity endpoint") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
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
        #endif
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
        guard allowsTrust(in: space),
              let trust = space.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func allowsTrust(in space: URLProtectionSpace) -> Bool {
        space.host == "127.0.0.1" && space.port == port && !space.isProxy()
            && space.protocol == NSURLProtectionSpaceHTTPS
            && space.authenticationMethod == NSURLAuthenticationMethodServerTrust
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
    var read: @Sendable (URL) -> Data? = { Self.readHubFile($0) }
    var alive: @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
    var run: @Sendable (String, [String]) -> String = { executable, arguments in
        guard let data = LocalSecurityTool.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            options: .init(timeout: 2, maxBytes: 256 * 1024)
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func readHubFile(_ url: URL) -> Data? {
        let limit = 64 * 1024
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
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
                  Self.validToken(hub.csrfToken),
                  ownsLanguageServer(hub.pid),
                  listeningPorts(hub.pid).contains(hub.httpPort) else { continue }
            return AntigravityEndpoint(port: hub.httpPort, token: hub.csrfToken)
        }
        return nil
    }

    /// Lists short executable paths first, then reads full argv only for Antigravity's own language servers,
    /// so a Mac full of long command lines cannot push the listing past the output cap.
    func processEndpoints() -> [AntigravityEndpoint] {
        run("/bin/ps", ["-x", "-o", "pid=,comm="]).split(separator: "\n").flatMap { line -> [AntigravityEndpoint] in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0,
                  fields[1].hasPrefix(Self.appContents), alive(pid),
                  let command = languageServerCommand(pid),
                  let process = Self.parseCommand(command) else { return [] }
            return listeningPorts(pid).sorted().map { port in
                let token = port == process.extensionPort ? process.extensionToken ?? process.token : process.token
                return AntigravityEndpoint(port: port, token: token)
            }
        }
    }

    private static let appContents = "/Applications/Antigravity.app/Contents/"

    private func ownsLanguageServer(_ pid: Int32) -> Bool { languageServerCommand(pid) != nil }

    /// Full argv of `pid`, only when this user owns it and it is Antigravity's language server.
    private func languageServerCommand(_ pid: Int32) -> String? {
        let output = run("/bin/ps", ["-ww", "-p", String(pid), "-o", "pid=,uid=,command="])
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, Int32(fields[0]) == pid, UInt32(fields[1]) == getuid() else { continue }
            let command = String(fields[2])
            if Self.isLanguageServer(command) { return command }
        }
        return nil
    }

    private func listeningPorts(_ pid: Int32) -> Set<Int> {
        Self.parseListeningPorts(run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-i4TCP", "-sTCP:LISTEN", "-Fn"]))
    }

    static func parseListeningPorts(_ output: String) -> Set<Int> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == "n127.0.0.1" || fields[0] == "n*",
                  fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(fields[1]), (1...65535).contains(port) else { return nil }
            return port
        })
    }

    private static func isLanguageServer(_ command: String) -> Bool {
        guard let executable = command.split(whereSeparator: \.isWhitespace).first,
              executable.hasPrefix(appContents),
              !executable.split(separator: "/").contains("..") else { return false }
        let root = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents", isDirectory: true)
            .resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: String(executable)).standardizedFileURL.resolvingSymlinksInPath()
        return resolved.path.hasPrefix(root + "/") && resolved.lastPathComponent.hasPrefix("language_server")
    }

    static func parseCommand(_ command: String) -> (token: String, extensionPort: Int?, extensionToken: String?)? {
        guard isLanguageServer(command) else { return nil }
        let args = command.split(whereSeparator: \.isWhitespace).map(String.init)
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
            readings.min(by: {
                if $0.remaining == $1.remaining { return $0.reset != nil && $1.reset == nil }
                return $0.remaining < $1.remaining
            }).map {
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
        return groups.flatMap { group -> [Reading] in
            guard let gemini = isGemini(group["displayName"] as? String ?? "") else { return [] }
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            return buckets.compactMap { bucket -> Reading? in
                let weekly = ["cadence", "windowCadence", "window", "displayName", "bucketId", "description"]
                    .compactMap { cadence(bucket[$0] as? String ?? "") }.first
                let info = bucket["remaining"] as? [String: Any]
                guard let weekly,
                      let remaining = fraction(info?["remainingFraction"]) ?? fraction(bucket["remainingFraction"])
                else { return nil }
                let reset = date(bucket["resetTime"]) ?? date(info?["resetTime"]) ?? date(bucket["resetsAt"])
                return Reading(rank: (gemini ? 0 : 2) + (weekly ? 1 : 0),
                               label: (gemini ? "Gemini" : "Claude + GPT") + (weekly ? " weekly" : " session"),
                               remaining: remaining, reset: reset,
                               verified: reset != nil || isTrue(info?["verified"] ?? bucket["verified"]))
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
            guard let gemini = isGemini(name) else { return nil }
            let reset = date(quota["resetTime"])
            return Reading(rank: gemini ? 0 : 2, label: gemini ? "Gemini" : "Claude + GPT",
                           remaining: remaining, reset: reset,
                           verified: reset != nil || isTrue(quota["verified"]))
        }
    }

    private static func isGemini(_ name: String) -> Bool? {
        let name = name.lowercased()
        if name.contains("gemini") { return true }
        if ["claude", "gpt", "openai", "anthropic", "sonnet", "opus"].contains(where: name.contains) { return false }
        return nil
    }

    private static func cadence(_ value: String) -> Bool? {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if normalized.contains("week") || normalized.contains("7 day") { return true }
        if ["five hour", "5 hour", "session"].contains(where: normalized.contains) { return false }
        // Short codes only count as whole words, so an opaque id like "b5h9f2" is not read as a cadence.
        let words = normalized.split { !$0.isLetter && !$0.isNumber }
        if words.contains("5h") || words.contains("18000s") || words.contains("18000") { return false }
        return nil
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return (value as? String).flatMap(Double.init)
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let fraction = number(value), (0...1).contains(fraction) else { return nil }
        return fraction
    }

    static func date(_ value: Any?) -> Date? {
        if let timestamp = value as? [String: Any], let seconds = number(timestamp["seconds"]),
           seconds.isFinite, seconds > 0 {
            let rawNanos = timestamp["nanos"]
            let nanos = rawNanos == nil || rawNanos is NSNull ? 0 : number(rawNanos)
            guard let nanos, (0..<1_000_000_000).contains(nanos) else { return nil }
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
        }
        if let seconds = number(value), seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds >= 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }
}
