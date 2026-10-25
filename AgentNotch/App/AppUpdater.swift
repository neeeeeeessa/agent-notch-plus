import AppKit
@preconcurrency import Sparkle

/// Owns Sparkle and brings the app forward when an update alert needs a window.
///
/// Agent Notch often runs as a menu-bar accessory (`LSUIElement`), so Sparkle's
/// standard alert would otherwise appear behind everything or not become key.
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController?
    private let restorePresence: () -> Void

    var updater: SPUUpdater? { controller?.updater }
    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    /// Only signed release builds update themselves, from the feed in `Config/Info.plist`.
    /// Debug and demo builds never start Sparkle, so local test installs stay as built.
    init(restorePresence: @escaping () -> Void) {
        self.restorePresence = restorePresence
        super.init()
        #if !DEBUG && !AGENTNOTCH_DEMO
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: self
            )
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restorePresence()
    }
}
