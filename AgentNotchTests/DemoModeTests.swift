import Foundation
import Testing

@testable import AgentNotch

#if AGENTNOTCH_DEMO
struct DemoModeTests {
    @Test func sampleProvidersReturnSampleData() async throws {
        for id in ProviderID.allCases {
            let snapshot = try await DemoUsageProvider(id: id).fetch()
            #expect(snapshot.id == id)
            #expect(snapshot.account == "Sample data")
            #expect(!snapshot.windows.isEmpty)
        }
    }

    @Test func keychainReadReturnsNil() throws {
        let service = "app.lucabecker.AgentNotch.demo-guard.\(UUID().uuidString)"
        let data = try Keychain.data(service: service, account: "synthetic")
        #expect(data == nil)
    }

    @Test func keychainSetThrows() {
        let service = "app.lucabecker.AgentNotch.demo-guard.\(UUID().uuidString)"
        #expect(throws: (any Error).self) {
            try Keychain.set(Data("synthetic".utf8), service: service, account: "synthetic")
        }
    }

    @Test func providerHTTPThrows() async {
        let url = URL(string: "https://example.invalid")!
        await #expect(throws: (any Error).self) {
            try await ProviderHTTP.get(url: url, headers: [:], authFailed: "synthetic")
        }
    }

    @Test func refreshThrows() async {
        let session = ClaudeOAuthSession(
            accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh",
            expiresAt: Date().timeIntervalSince1970 + 3600,
            email: nil
        )
        await #expect(throws: (any Error).self) {
            try await ClaudeOAuthLogin.refresh(session)
        }
    }

    @Test @MainActor func signInThrows() async {
        await #expect(throws: (any Error).self) {
            try await ClaudeOAuthLogin.signIn()
        }
    }

    @Test @MainActor func updaterDoesNotStart() {
        let updater = AppUpdater(restorePresence: {})
        #expect(updater.controller == nil)
        #expect(updater.canCheckForUpdates == false)
    }
}
#endif
