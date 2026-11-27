import Foundation
import Testing
@testable import AgentNotch

struct AntigravityTests {
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
           {"label":"GPT"}
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
        var discovery = AntigravityDiscovery()
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
