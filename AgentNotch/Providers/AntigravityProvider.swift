import AppKit
import CoreFoundation
import Foundation
import OSLog
import Security
import Synchronization

nonisolated struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity

    var discovery = AntigravityDiscovery()
    var transport: @Sendable (AntigravityEndpoint, AntigravityEndpoint.Method) async throws -> Data = {
        try await $0.post($1)
    }

    private final class DiscoveryCache: Sendable {
        let lastMiss = Mutex<ContinuousClock.Instant?>(nil)
    }
    private let discoveryCache = DiscoveryCache()
    private static let appBundleIdentifiers = ["com.google.antigravity", "com.google.antigravity-ide"]
    var now: @Sendable () -> ContinuousClock.Instant = { .now }
    var appIsRunning: @Sendable () -> Bool = {
        Self.appBundleIdentifiers.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    func resetDiscoveryBackoff() {
        discoveryCache.lastMiss.withLock { $0 = nil }
    }

    @concurrent
    func fetch() async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        let hubs = discovery.hubs()
        if !hubs.isEmpty { resetDiscoveryBackoff() }
        var attempted = Set<AntigravityEndpoint>()
        var failure: UsageProviderError?
        var authenticationFailure: UsageProviderError?

        func attempt(_ endpoint: AntigravityEndpoint, verifiedTLS: Bool = false) async throws -> (ProviderSnapshot?, canDowngrade: Bool) {
            try Task.checkCancellation()
            guard attempted.insert(endpoint).inserted else { return (nil, false) }
            do {
                return (try await read(endpoint), false)
            } catch let error as URLError {
                try Task.checkCancellation()
                return (nil, Self.permitsHTTPFallback(error.code, verifiedTLS: verifiedTLS))
            } catch let error as UsageProviderError {
                if case .authenticationRejected = error {
                    authenticationFailure = authenticationFailure ?? error
                } else {
                    failure = failure ?? error
                }
                return (nil, false)
            }
        }

        // A hub knows the separate HTTPS and HTTP ports. Never probe a known HTTP port over TLS.
        let verifiedTLSPorts = Set(hubs.compactMap { $0.https?.port })
        var blockedPlainPorts = Set<Int>()
        for hub in hubs {
            if let https = hub.https {
                let (snapshot, canDowngrade) = try await attempt(https, verifiedTLS: true)
                if let snapshot { return snapshot }
                if !canDowngrade {
                    if let port = hub.http?.port { blockedPlainPorts.insert(port) }
                    continue
                }
            }
            if let http = hub.http, let snapshot = try await attempt(http).0 { return snapshot }
        }
        let shouldScan = discoveryCache.lastMiss.withLock { miss in
            miss.map { now() - $0 >= .seconds(120) } ?? true
        }
        if shouldScan || appIsRunning(), let candidates = discovery.processEndpoints() {
            try Task.checkCancellation()
            if candidates.isEmpty { discoveryCache.lastMiss.withLock { $0 = now() } }
            var fallbacks: [AntigravityEndpoint] = []
            for candidate in candidates {
                let (snapshot, canDowngrade) = try await attempt(candidate, verifiedTLS: verifiedTLSPorts.contains(candidate.port))
                if let snapshot { return snapshot }
                if canDowngrade, !verifiedTLSPorts.contains(candidate.port), !blockedPlainPorts.contains(candidate.port) {
                    fallbacks.append(AntigravityEndpoint(port: candidate.port, token: candidate.token, plainHTTP: true))
                }
            }
            for candidate in fallbacks {
                if let snapshot = try await attempt(candidate).0 { return snapshot }
            }
        }
        try Task.checkCancellation()
        throw authenticationFailure ?? failure ?? UsageProviderError.needsAuth("Open Antigravity to update your usage")
    }

    private func read(_ endpoint: AntigravityEndpoint) async throws -> ProviderSnapshot {
        let summary: ProviderSnapshot
        do {
            summary = try AntigravityQuota.parse(await transport(endpoint, .summary), grouped: true)
        } catch let error as UsageProviderError {
            if case .authenticationRejected = error { throw error }
            do {
                return try AntigravityQuota.parse(await transport(endpoint, .status), grouped: false)
            } catch is URLError {
                try Task.checkCancellation()
                // The server answered the summary request over this transport.
                throw error
            }
        }

        var enriched = summary
        do {
            let identity = try AntigravityQuota.identity(await transport(endpoint, .status))
            enriched.account = identity.account ?? summary.account
            enriched.plan = identity.plan ?? summary.plan
            enriched.accountBinding = identity.binding ?? summary.accountBinding
        } catch let error as UsageProviderError {
            if case .authenticationRejected = error {
                enriched.account = nil
                enriched.plan = nil
                enriched.accountBinding = nil
            }
        } catch {
            try Task.checkCancellation()
        }
        return enriched
    }

    private static func permitsHTTPFallback(_ code: URLError.Code, verifiedTLS: Bool) -> Bool {
        switch code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut:
            !verifiedTLS
        case .cannotParseResponse,
             .badServerResponse, .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            true
        default:
            false
        }
    }

}

nonisolated struct AntigravityEndpoint: Hashable {
    static let maxResponseBytes = 2 * 1024 * 1024
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

    func post(_ method: Method, configure: ((URLSessionConfiguration) -> Void)? = nil) async throws -> Data {
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
        configure?(configuration)
        let delegate = AntigravityLoopbackDelegate(port: port)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse else {
            throw UsageProviderError.badResponse("Invalid Antigravity quota response")
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw UsageProviderError.authenticationRejected(ProviderID.antigravity.signInHint)
        }
        guard response.mimeType == "application/json",
              response.expectedContentLength <= Self.maxResponseBytes else {
            throw UsageProviderError.badResponse("Invalid Antigravity quota response")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maxResponseBytes else {
                throw UsageProviderError.badResponse("Antigravity quota response is too large")
            }
            data.append(byte)
        }
        if response.statusCode != 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           AntigravityQuota.isAuthError(root) {
            throw UsageProviderError.authenticationRejected(ProviderID.antigravity.signInHint)
        }
        guard response.statusCode == 200 else {
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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
        return urls.filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }
    var read: @Sendable (URL) -> Data? = { Self.readHubFile($0) }
    var alive: @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }
    var run: @Sendable (String, [String]) -> String? = { executable, arguments in
        guard let data = LocalSecurityTool.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            options: .init(timeout: 2, maxBytes: 256 * 1024)
        ) else { return nil }
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
        var httpsPort: Int?
        var httpPort: Int?
        var csrfToken: String
    }

    struct HubEndpoints: Hashable {
        let https: AntigravityEndpoint?
        let http: AntigravityEndpoint?
    }

    private static let appRoot = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents", isDirectory: true)
    private static let googleCLIRequirement =
        #"identifier "cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
    static let defaultSignedExecutables: [URL] = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            home.appendingPathComponent(".gemini/bin/agy"),
            home.appendingPathComponent(".local/bin/agy"),
        ]
    }()

    var executableRoot = Self.appRoot
    var signedExecutables = Self.defaultSignedExecutables
    var isExecutable: @Sendable (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
    var verifySignedProcess: @Sendable (Int32, URL) -> Bool = {
        Self.verifyGoogleSignedCLI(pid: $0, expectedExecutable: $1)
    }
    var clock: @Sendable () -> ContinuousClock.Instant = { .now }

    func hubs() -> [HubEndpoints] {
        let deadline = clock() + .seconds(3)
        var rejected = Set<Int32>()
        var portsByProcess: [Int32: Set<Int>] = [:]
        var seen = Set<HubEndpoints>()
        var result: [HubEndpoints] = []
        for file in files(directory) where file.lastPathComponent.hasPrefix("hub_") && file.pathExtension == "json" {
            guard !Task.isCancelled, clock() < deadline else { break }
            guard let data = read(file), let hub = try? JSONDecoder().decode(Hub.self, from: data),
                  hub.pid > 0, Self.validToken(hub.csrfToken), !rejected.contains(hub.pid) else { continue }
            if portsByProcess[hub.pid] == nil {
                guard alive(hub.pid),
                      let listing = run("/bin/ps", ["-ww", "-p", String(hub.pid), "-o", "pid=,comm="]),
                      let executable = processPaths(listing).first(where: { $0.pid == hub.pid })?.path,
                      let _ = languageServerArguments(hub.pid, executable: executable) else {
                    rejected.insert(hub.pid)
                    continue
                }
                guard !Task.isCancelled, clock() < deadline else { break }
                portsByProcess[hub.pid] = listeningPorts(hub.pid)
            }
            let ports = portsByProcess[hub.pid] ?? []
            // An advertised HTTPS port must belong to this PID before the hub can be trusted.
            if let httpsPort = hub.httpsPort, !ports.contains(httpsPort) { continue }
            let https = hub.httpsPort.map { AntigravityEndpoint(port: $0, token: hub.csrfToken) }
            let http = hub.httpPort.flatMap { port in
                ports.contains(port) ? AntigravityEndpoint(port: port, token: hub.csrfToken, plainHTTP: true) : nil
            }
            let endpoints = HubEndpoints(https: https, http: http)
            if (https != nil || http != nil), seen.insert(endpoints).inserted { result.append(endpoints) }
        }
        return result
    }

    /// nil means the scan hit its deadline or was cancelled, so it cannot count as a miss.
    func processEndpoints() -> [AntigravityEndpoint]? {
        guard !Task.isCancelled else { return nil }
        let deadline = clock() + .seconds(3)
        var seen = Set<Int32>()
        var result: [AntigravityEndpoint] = []
        guard let listing = run("/bin/ps", ["-x", "-ww", "-o", "pid=,comm="]) else { return nil }
        for (pid, executable) in processPaths(listing) {
            guard !Task.isCancelled, clock() < deadline else { return result.isEmpty ? nil : result }
            guard seen.insert(pid).inserted, alive(pid),
                  let arguments = languageServerArguments(pid, executable: executable) else { continue }
            guard !Task.isCancelled, clock() < deadline else { return result.isEmpty ? nil : result }
            if let process = Self.parseArguments(arguments) {
                result += listeningPorts(pid).sorted().map { port in
                    let token = port == process.extensionPort ? process.extensionToken ?? process.token : process.token
                    return AntigravityEndpoint(port: port, token: token)
                }
            } else if isSignedCLI(executable) {
                // `agy` (e.g. T3 Code's `agy acp`) keeps its token in memory and writes no hub file.
                // Its plain-HTTP loopback port answers the quota summary without one. Reached only after
                // `languageServerArguments` verified the process's Google signature and owner.
                result += listeningPorts(pid).sorted().map { AntigravityEndpoint(port: $0, token: "", plainHTTP: true) }
            }
        }
        if result.isEmpty, Task.isCancelled || clock() >= deadline { return nil }
        return result
    }

    private func processPaths(_ output: String) -> [(pid: Int32, path: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0,
                  matchesCandidatePath(fields[1]) else { return nil }
            return (pid, String(fields[1]))
        }
    }

    /// A `agy` path from `signedExecutables`, as opposed to the desktop app's `language_server`.
    private func isSignedCLI(_ path: String) -> Bool {
        !path.hasPrefix(executableRoot.path + "/") && matchesCandidatePath(Substring(path))
    }

    private func matchesCandidatePath(_ path: Substring) -> Bool {
        if path.hasPrefix(executableRoot.path + "/"),
           path.split(separator: "/").last?.hasPrefix("language_server") == true {
            return true
        }
        return signedExecutables.contains {
            path == $0.path || path == $0.resolvingSymlinksInPath().path
        }
    }

    private func languageServerArguments(_ pid: Int32, executable: String) -> Substring? {
        guard validProcessExecutable(executable, pid: pid) else { return nil }
        guard let output = run("/bin/ps", ["-ww", "-p", String(pid), "-o", "pid=,uid=,command="]) else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, Int32(fields[0]) == pid, UInt32(fields[1]) == getuid() else { continue }
            return Self.commandArguments(fields[2], executable: executable)
        }
        return nil
    }

    func validExecutable(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains("..") else { return false }
        let root = executableRoot.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return resolved.path.hasPrefix(root + "/") && resolved.lastPathComponent.hasPrefix("language_server")
            && isExecutable(resolved)
    }

    func validProcessExecutable(_ path: String, pid: Int32) -> Bool {
        if validExecutable(path) { return true }
        guard pid > 0, !path.split(separator: "/").contains("..") else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let allowed = signedExecutables.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == resolved.path
        }
        return allowed && isExecutable(resolved) && verifySignedProcess(pid, resolved)
    }

    /// Cryptographically verifies a live `agy` process against Google LLC's Developer ID and hardened runtime.
    static func verifyGoogleSignedCLI(pid: Int32, expectedExecutable: URL) -> Bool {
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &dynamicCode
        ) == errSecSuccess, let dynamicCode else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            googleCLIRequirement as CFString, [], &requirement
        ) == errSecSuccess, let requirement else { return false }

        guard SecCodeCheckValidity(
            dynamicCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement
        ) == errSecSuccess else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        var codePath: CFURL?
        guard SecCodeCopyPath(staticCode, [], &codePath) == errSecSuccess,
              let codeURL = codePath as URL?,
              codeURL.resolvingSymlinksInPath().standardizedFileURL.path
                  == expectedExecutable.resolvingSymlinksInPath().standardizedFileURL.path
        else { return false }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF
        ) == errSecSuccess, let info = infoCF as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? UInt32 else { return false }

        let hardenedRuntime: UInt32 = 0x0001_0000
        let adHoc: UInt32 = 0x0000_0002
        return (flags & hardenedRuntime) != 0 && (flags & adHoc) == 0
    }

    static func commandArguments(_ command: Substring, executable: String) -> Substring? {
        guard command.hasPrefix(executable) else { return nil }
        let arguments = command.dropFirst(executable.count)
        guard arguments.first?.isWhitespace ?? true else { return nil }
        return arguments
    }

    private func listeningPorts(_ pid: Int32) -> Set<Int> {
        Self.parseListeningPorts(run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-i4TCP", "-sTCP:LISTEN", "-Fn"]) ?? "")
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

    private static func parseArguments(_ arguments: Substring) -> (token: String, extensionPort: Int?, extensionToken: String?)? {
        let args = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        func value(_ flag: String) -> String? {
            for (index, arg) in args.enumerated() {
                if arg == flag || arg == String(flag.dropFirst()), index + 1 < args.count { return args[index + 1] }
                for spelling in [flag, String(flag.dropFirst())] where arg.hasPrefix(spelling + "=") {
                    return String(arg.dropFirst(spelling.count + 1))
                }
            }
            return nil
        }
        guard let token = value("--csrf_token"), validToken(token) else { return nil }
        let port = value("--extension_server_port").flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
        let extensionToken = value("--extension_server_csrf_token").flatMap { validToken($0) ? $0 : nil }
        return (token, port, extensionToken)
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 4096 && !token.hasPrefix("-") && token.utf8.allSatisfy { (33...126).contains($0) }
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
        let (response, status) = try decode(data)
        let readings = grouped ? groupReadings(response) : modelReadings(status)
        guard readings.contains(where: { $0.remaining < 1 || $0.verified }) else {
            throw UsageProviderError.unavailable("Antigravity limits not available")
        }
        let windows = Dictionary(grouping: readings, by: \.rank).sorted { $0.key < $1.key }.compactMap { rank, readings in
            readings.min(by: {
                if $0.remaining == $1.remaining { return $0.reset != nil && $1.reset == nil }
                return $0.remaining < $1.remaining
            }).map {
                LimitWindow(id: (grouped ? ["gemini-session", "gemini-weekly", "3p-session", "3p-weekly"] : ["gemini", "", "3p"])[rank], label: $0.label, usedFraction: 1 - $0.remaining, resetsAt: $0.reset)
            }
        }
        let identity = identity(in: status)
        let banked = grouped ? bankedResets(in: response, now: now) : nil
        return ProviderSnapshot(id: .antigravity, account: identity.account, plan: identity.plan, windows: windows,
                                fetchedAt: now, resetCredits: banked, accountBinding: identity.binding)
    }

    private static let log = Logger(subsystem: "io.github.neeeeeeessa.AgentNotchPlus", category: "AntigravityQuota")

    private static func bankedResets(in response: [String: Any], now: Date) -> ResetCredits {
        let rawList = (response["bankedResets"] ?? response["banked_resets"]) as? [Any] ?? []
        Self.log.notice("antigravity bankedResets count=\(rawList.count)")
        var items: [ResetCredit] = []
        for (index, raw) in rawList.enumerated() {
            guard let entry = raw as? [String: Any] else { continue }
            let expireTime = date(entry["expireTime"] ?? entry["expire_time"])
            if let expireTime, expireTime <= now { continue }
            let count: Int
            if let rawCount = entry["remainingCount"] ?? entry["remaining_count"] {
                guard let parsed = number(rawCount), parsed >= 1, let exact = Int(exactly: parsed.rounded(.towardZero)) else {
                    continue
                }
                count = exact
            } else {
                count = 1
            }
            let rawLabel = (entry["displayLabel"] ?? entry["display_label"]) as? String
            let trimmedLabel = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (trimmedLabel?.isEmpty == false ? trimmedLabel! : "Full reset")
            let rawID = ((entry["resetId"] ?? entry["reset_id"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (rawID?.isEmpty == false ? rawID! : "\(index)-\(label)-\(Int(expireTime?.timeIntervalSince1970 ?? 0))")
            items.append(ResetCredit(id: id, label: label, expiresAt: expireTime, count: count))
        }
        items.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let total = items.reduce(0) { $0 + $1.count }
        return ResetCredits(availableCount: total, items: items)
    }

    static func isAuthError(_ root: [String: Any]) -> Bool {
        let code = (root["error"] as? [String: Any])?["code"] ?? root["code"]
        return ["unauthenticated", "permission_denied"].contains(code as? String ?? "")
    }

    private static func decode(_ data: Data) throws -> (response: [String: Any], status: [String: Any]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageProviderError.badResponse("Invalid Antigravity usage response")
        }
        let response = root["response"] as? [String: Any] ?? root
        if isAuthError(root) || isAuthError(response) {
            throw UsageProviderError.authenticationRejected(ProviderID.antigravity.signInHint)
        }
        return (response, response["userStatus"] as? [String: Any] ?? response)
    }

    static func identity(_ data: Data) throws -> (account: String?, plan: String?, binding: String?) {
        identity(in: try decode(data).status)
    }

    private static func identity(in status: [String: Any]) -> (account: String?, plan: String?, binding: String?) {
        let tier = status["userTier"] as? [String: Any]
        let planStatus = status["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let email = ((status["email"] ?? status["userEmail"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let account = email.flatMap { $0.isEmpty ? nil : $0 }
        let plans = [planInfo?["planName"], planInfo?["teamsTier"], planStatus?["teamsTier"],
                     tier?["description"], tier?["name"], status["planName"]]
        let plan = plans.compactMap { $0 as? String }.first { !$0.isEmpty }
        return (account, plan, account?.lowercased())
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
