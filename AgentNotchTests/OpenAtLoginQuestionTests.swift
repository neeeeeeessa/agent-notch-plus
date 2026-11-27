import Foundation
import Testing

@testable import AgentNotch

struct OpenAtLoginQuestionTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "open-at-login-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func newInstallStartsOffAndAsks() {
        let preferences = Preferences(defaults: isolatedDefaults(), loginItemEnabled: false)
        #expect(!preferences.opensAtLogin)
        #expect(preferences.needsOpenAtLoginQuestion)
    }

    @Test func existingInstallNotYetAskedIsAsked() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "hasLaunchedBefore")
        #expect(Preferences(defaults: defaults, loginItemEnabled: false).needsOpenAtLoginQuestion)
    }

    @Test func asksOnlyOnceAcrossLaunches() {
        let defaults = isolatedDefaults()
        Preferences(defaults: defaults, loginItemEnabled: false).markOpenAtLoginAsked()
        #expect(!Preferences(defaults: defaults, loginItemEnabled: false).needsOpenAtLoginQuestion)
    }
}
