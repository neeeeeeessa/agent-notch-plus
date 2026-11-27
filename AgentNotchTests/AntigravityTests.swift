import Foundation
import Security
import Testing
@testable import AgentNotch

struct AntigravityTests {
    private static let server = "/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm"

    private actor Calls {
        private var values: [String] = []
        func record(_ endpoint: AntigravityEndpoint, _ method: AntigravityEndpoint.Method) {
            values.append("\(endpoint.port):\(endpoint.plainHTTP):\(method.rawValue)")
        }
        func all() -> [String] { values }
    }

    private func discoveryFixture() -> AntigravityDiscovery {
        var discovery = AntigravityDiscovery()
        discovery.files = { _ in [URL(fileURLWithPath: "/fake/hub_live.json")] }
        discovery.read = { _ in Data(#"{"pid":42,"httpPort":1234,"csrfToken":"hub"}"#.utf8) }
        discovery.alive = { $0 == 42 || $0 == 43 }
        discovery.run = { command, args in
            if command == "/bin/ps" {
                if args.contains("42") { return "42 \(getuid()) \(Self.server)" }
                if args.contains("43") {
                    return "43 \(getuid()) \(Self.server) --csrf_token ide --extension_server_port 9999 --extension_server_csrf_token ext"
                }
                // The listing step must ask for short executable paths only.
                guard args.contains("pid=,comm=") else { return "" }
                return "7 /Applications/Other.app/Contents/MacOS/Other\n43 \(Self.server)"
            }
            return args.contains("42") ? "n127.0.0.1:1234" : "n127.0.0.1:4321"
        }
        return discovery
    }

    @Test func deadHubFallsThroughToProcessAndOnlyTransportErrorAllowsHTTP() async throws {
        let calls = Calls()
        let provider = AntigravityProvider(discovery: discoveryFixture()) { endpoint, method in
            await calls.record(endpoint, method)
            if endpoint.port == 1234 { throw UsageProviderError.unavailable("HTTP error") }
            if !endpoint.plainHTTP { throw URLError(.secureConnectionFailed) }
            switch method {
            case .summary: throw UsageProviderError.unavailable("Missing summary")
            case .status:
                return Data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini","quotaInfo":{"remainingFraction":0.5}}]}}}"#.utf8)
            }
        }
        #expect(try await provider.fetch().headline?.usedFraction == 0.5)
        #expect(await calls.all() == [
            "1234:false:RetrieveUserQuotaSummary", "1234:false:GetUserStatus",
            "4321:false:RetrieveUserQuotaSummary",
            "4321:true:RetrieveUserQuotaSummary", "4321:true:GetUserStatus",
        ])
    }

    @Test func reachableHubUsesHTTPSAndSkipsProcessProbe() async throws {
        let calls = Calls()
        let provider = AntigravityProvider(discovery: discoveryFixture()) { endpoint, method in
            await calls.record(endpoint, method)
            return Data(#"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"weekly","remainingFraction":0.5}]}]}"#.utf8)
        }
        #expect(try await provider.fetch().headline?.label == "Gemini weekly")
        #expect(await calls.all() == ["1234:false:RetrieveUserQuotaSummary"])
    }

    /// Antigravity 2.35.2 has no GetUnleashData; a server that only 404s it must still be read.
    @Test func serverWithoutProbeMethodIsStillRead() async throws {
        let provider = AntigravityProvider(discovery: discoveryFixture()) { endpoint, method in
            guard endpoint.port == 1234, !endpoint.plainHTTP, method == .summary else {
                throw UsageProviderError.unavailable("HTTP 404")
            }
            return Data(Self.liveSummary.utf8)
        }
        let snapshot = try await provider.fetch()
        #expect(snapshot.headline?.label == "Gemini session")
    }

    /// Reply captured from Antigravity 2.35.2's local server (Pro plan), unchanged apart from layout.
    static let liveSummary = """
    {"response":{"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen, Orchestrator (Neon), Orchestrator (Carbon), Orchestrator (Argon), Gemini 3.8 Flash","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","description":"You have used some of your weekly limit, it will fully refresh in 5 days, 20 hours.","window":"weekly","remainingFraction":0.66096336,"resetTime":"2026-12-03T10:22:49Z"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","description":"You have used some of your 5-hour limit, it will fully refresh in 34 minutes.","window":"5h","remainingFraction":0.1785842,"resetTime":"2026-11-27T14:12:16Z"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1}]}],
    "description":"Within each group, models share a weekly limit and a 5-hour limit."}}
    """

    @Test func liveSummaryMapsToFourWindowsInRingOrder() throws {
        let snapshot = try AntigravityQuota.parse(Data(Self.liveSummary.utf8), grouped: true)
        #expect(snapshot.windows.map(\.label) == [
            "Gemini session", "Gemini weekly", "Claude + GPT session", "Claude + GPT weekly",
        ])
        #expect(abs((snapshot.headline?.usedFraction ?? 0) - (1 - 0.1785842)) < 0.000001)
        #expect(snapshot.headline?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-27T14:12:16Z"))
        #expect(snapshot.windows.last?.usedFraction == 0)
    }

    @Test func listenerFilteringAndExecutableTraversal() {
        #expect(AntigravityDiscovery.parseListeningPorts("""
        p42
        n*:1234
        n127.0.0.1:4321
        n[::1]:9000
        n192.168.1.1:9001
        n127.0.0.10:9002
        n*:65536
        n*:12 (LISTEN)
        """) == [1234, 4321])
        #expect(AntigravityDiscovery.parseCommand("/Applications/Antigravity.app/Contents/../Contents/language_server --csrf_token main") == nil)
        #expect(discoveryFixture().processEndpoints().map(\.port) == [4321])
    }

    @Test func hubReaderRejectsSymlinkDirectoryAndOversizedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hub_real.json")
        let link = directory.appendingPathComponent("hub_link.json")
        let data = Data("{}".utf8)
        try data.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(AntigravityDiscovery.readHubFile(file) == data)
        #expect(AntigravityDiscovery.readHubFile(link) == nil)
        #expect(AntigravityDiscovery.readHubFile(directory) == nil)
        try Data(count: 65537).write(to: file)
        #expect(AntigravityDiscovery.readHubFile(file) == nil)
    }

    @Test func datesAndVerifiedFullQuota() throws {
        #expect(AntigravityQuota.date(true) == nil)
        #expect(AntigravityQuota.date(1795780800250) == Date(timeIntervalSince1970: 1795780800.25))
        #expect(AntigravityQuota.date(["seconds": "1795780800", "nanos": 250000000]) == Date(timeIntervalSince1970: 1795780800.25))
        #expect(AntigravityQuota.date(["seconds": 1795780800, "nanos": true]) == nil)
        #expect(AntigravityQuota.date(["seconds": 1795780800, "nanos": NSNull()]) == Date(timeIntervalSince1970: 1795780800))
        func quota(_ fields: String) throws -> ProviderSnapshot {
            try AntigravityQuota.parse(Data("""
            {"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"weekly",\(fields)}]}]}
            """.utf8), grouped: true)
        }
        #expect(throws: UsageProviderError.self) { try quota(#""remainingFraction":1,"resetTime":true"#) }
        #expect(throws: UsageProviderError.self) { try quota(#""remainingFraction":false"#) }
        #expect(try quota(#""remainingFraction":1,"verified":true"#).headline?.usedFraction == 0)
        #expect(try quota(#""remainingFraction":1,"resetTime":1795780800"#).headline?.usedFraction == 0)
    }

    @Test func cadenceUsesBucketMetadataAndTiesPreferKnownReset() throws {
        let snapshot = try AntigravityQuota.parse(Data("""
        {"groups":[{"displayName":"Gemini","buckets":[
          {"bucketId":"five-hour","remainingFraction":0.5,"description":"Also has weekly quota"},
          {"bucketId":"five-hour","remainingFraction":0.5,"resetTime":1795780800}
        ]},{"displayName":"Other","buckets":[{"bucketId":"weekly","remainingFraction":0}]}]}
        """.utf8), grouped: true)
        #expect(snapshot.windows.map(\.label) == ["Gemini session"])
        #expect(snapshot.headline?.resetsAt == Date(timeIntervalSince1970: 1795780800))

        let opaque = try AntigravityQuota.parse(Data("""
        {"groups":[{"displayName":"Gemini","buckets":[
          {"bucketId":"b5h9f2","cadence":"WEEKLY","remainingFraction":0.4},
          {"bucketId":"q-5h","remainingFraction":0.7}
        ]}]}
        """.utf8), grouped: true)
        #expect(opaque.windows.map(\.label) == ["Gemini session", "Gemini weekly"])
        #expect(opaque.windows.map(\.usedFraction) == [1 - 0.7, 1 - 0.4])
    }

    @Test func processFallbackReadsFullArgvOnlyForOwnedLanguageServers() {
        var discovery = discoveryFixture()
        let base = discovery.run
        discovery.run = { command, args in
            // Same language server, but owned by another user.
            if command == "/bin/ps", args.contains("43") {
                return "43 \(getuid() + 1) \(Self.server) --csrf_token ide"
            }
            return base(command, args)
        }
        #expect(discovery.processEndpoints().isEmpty)
    }

    private final class TestTrustSpace: URLProtectionSpace, @unchecked Sendable {
        let testTrust: SecTrust

        init(trust: SecTrust, scheme: String) {
            testTrust = trust
            super.init(host: "127.0.0.1", port: 1234, protocol: scheme, realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }

        required init?(coder: NSCoder) { nil }

        override var serverTrust: SecTrust? { testTrust }
    }

    @Test func trustChallengeAcceptsLoopbackHTTPSAndRejectsHTTP() throws {
        // Synthetic self-signed certificate. The delegate scopes trust without evaluating its validity dates.
        let der = try #require(Data(base64Encoded: "MIIBWzCCAQKgAwIBAgIUbqQ8sw9THdjEwhDc/PL+vSe7zngwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MTEyNzEyMzk0MFoXDTI2MTEyODEyMzk0MFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE2MfEYrJaALWf+YMY0+U26g9bj8kEZ/S+ZaNNq5YyA9cJlV9muMMg0ydKiaFxNJyW5EsYlh61rFVygI92keldWaMyMDAwHQYDVR0OBBYEFMJNBMLlxCYZRQEQTls4x/Fm0FQcMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgLF0XMxod3yf56/JnksqWnlJZkiETjyU+k9WYP3qHv9oCIH570SSoMjxPJbw390wdbFn/tpCM/8XnHKIvYBGdLWTk"))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var createdTrust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &createdTrust) == errSecSuccess)
        let trust = try #require(createdTrust)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let delegate = AntigravityLoopbackDelegate(port: 1234)
        for scheme in ["https", "http"] {
            let challenge = URLAuthenticationChallenge(
                protectionSpace: TestTrustSpace(trust: trust, scheme: scheme), proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender()
            )
            delegate.urlSession(session, didReceive: challenge) { disposition, credential in
                #expect(disposition == (scheme == "https" ? .useCredential : .cancelAuthenticationChallenge))
                #expect((credential != nil) == (scheme == "https"))
            }
        }
    }

    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    @Test func trustIsLimitedToServerTrustOnTheDiscoveredHTTPSPort() {
        let delegate = AntigravityLoopbackDelegate(port: 1234)
        func space(_ host: String = "127.0.0.1", _ port: Int = 1234, _ scheme: String = "https",
                   _ method: String = NSURLAuthenticationMethodServerTrust) -> URLProtectionSpace {
            URLProtectionSpace(host: host, port: port, protocol: scheme, realm: nil, authenticationMethod: method)
        }
        #expect(delegate.allowsTrust(in: space()))
        #expect(!delegate.allowsTrust(in: space("localhost")))
        #expect(!delegate.allowsTrust(in: space("127.0.0.1", 1235)))
        #expect(!delegate.allowsTrust(in: space("127.0.0.1", 1234, "http")))
        #expect(!delegate.allowsTrust(in: space("127.0.0.1", 1234, "https", NSURLAuthenticationMethodHTTPBasic)))
        #expect(!delegate.allowsTrust(in: URLProtectionSpace(proxyHost: "127.0.0.1", port: 1234,
            type: NSURLProtectionSpaceHTTPSProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)))
    }

    @Test func groupedWindowsAreOrderedAndWeeklyOnlyCanLead() throws {
        let payload = Data("""
        {"response":{"groups":[
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"weekly","remaining":{"remainingFraction":0.25}},
            {"displayName":"Five Hour Limit","remaining":{"remainingFraction":0.5}}]},
          {"displayName":"Gemini Models","buckets":[
            {"displayName":"Weekly Limit","remaining":{"remainingFraction":0.75}},
            {"displayName":"Five Hour Limit","remaining":{"remainingFraction":0.5}}]}
        ]}}
        """.utf8)
        let windows = try AntigravityQuota.parse(payload, grouped: true).windows
        #expect(windows.map(\.label) == ["Gemini session", "Gemini weekly", "Claude + GPT session", "Claude + GPT weekly"])
        #expect(windows.map(\.usedFraction) == [0.5, 0.25, 0.5, 0.75])

        let weekly = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"weekly","remaining":{"remainingFraction":0.75}}]}]}
        """.utf8)
        #expect(try AntigravityQuota.parse(weekly, grouped: true).headline?.label == "Gemini weekly")
    }

    @Test func fallbackUsesLowestKnownFractionAndItsReset() throws {
        let payload = Data("""
        {"userStatus":{"email":"sample@example.invalid","userTier":{"description":"Sample plan"},
         "cascadeModelConfigData":{"clientModelConfigs":[
           {"label":"Gemini A","quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-11-27T13:00:00Z"}},
           {"label":"Gemini B","quotaInfo":{"remainingFraction":0.25,"resetTime":1795780800}},
           {"label":"Gemini C","quotaInfo":{"resetTime":1795780900}},
           {"label":"Claude","quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-11-27T13:00:00Z"}},
           {"label":"GPT"},
           {"label":"Other","quotaInfo":{"remainingFraction":0}}
         ]}}}
        """.utf8)
        let snapshot = try AntigravityQuota.parse(payload, grouped: false)
        #expect(snapshot.plan == "Sample plan")
        #expect(snapshot.account == "sample@example.invalid")
        #expect(snapshot.windows.map(\.label) == ["Gemini", "Claude + GPT"])
        #expect(snapshot.windows.map(\.usedFraction) == [0.75, 0.5])
        #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1795780800))
        #expect(snapshot.windows.last?.resetsAt != nil)
    }

    @Test func unverifiedFullAndMalformedResponsesFail() {
        let full = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"weekly","remaining":{"remainingFraction":1}}]}]}
        """.utf8)
        #expect(throws: UsageProviderError.self) { try AntigravityQuota.parse(full, grouped: true) }
        #expect(throws: UsageProviderError.self) { try AntigravityQuota.parse(Data("bad JSON".utf8), grouped: false) }
    }

    @Test func discoverySkipsStaleHubAndParsesAntigravityArgv() throws {
        let stale = URL(fileURLWithPath: "/fake/hub_stale.json")
        let live = URL(fileURLWithPath: "/fake/hub_live.json")
        var discovery = discoveryFixture()
        discovery.files = { _ in [stale, live] }
        discovery.alive = { $0 == 42 }
        discovery.read = { url in
            Data("""
            {"pid":\(url == live ? 42 : 41),"httpPort":1234,"csrfToken":"test-only"}
            """.utf8)
        }
        #expect(discovery.hub()?.port == 1234)
        discovery.alive = { _ in false }
        #expect(discovery.hub() == nil)

        let argv = "/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm --csrf_token main --extension_server_port=4040 --extension_server_csrf_token ext"
        let process = try #require(AntigravityDiscovery.parseCommand(argv))
        #expect(process.token == "main")
        #expect(process.extensionPort == 4040)
        #expect(process.extensionToken == "ext")
        #expect(AntigravityDiscovery.parseCommand("/tmp/language_server --csrf_token test") == nil)
    }

    @Test func loopbackAllowlistAndRedirectPolicy() throws {
        let endpoint = AntigravityEndpoint(port: 1234, token: "test-only")
        let path = AntigravityEndpoint.path + "GetUserStatus"
        let allowed = try #require(URL(string: "https://127.0.0.1:1234" + path))
        #expect(endpoint.allows(allowed))
        for url in ["https://localhost.evil.com:1234" + path, "https://[::1]:1234" + path,
                    "https://127.0.0.1:1235" + path, "https://127.0.0.1:1234/other",
                    "https://user@127.0.0.1:1234" + path, allowed.absoluteString + "?x=1",
                    allowed.absoluteString + "#x", "http://127.0.0.1:1234" + path] {
            #expect(!endpoint.allows(try #require(URL(string: url))))
        }
        let redirect = try #require(HTTPURLResponse(url: allowed, statusCode: 307, httpVersion: nil, headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        AntigravityLoopbackDelegate(port: 1234).urlSession(
            session, task: session.dataTask(with: allowed), willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: allowed)
        ) { request in
            #expect(request == nil)
        }
    }
}
