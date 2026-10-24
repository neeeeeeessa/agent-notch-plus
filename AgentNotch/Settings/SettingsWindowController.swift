import AppKit
import SwiftUI

/// Single settings window, created on first use and reused afterwards.
final class SettingsWindowController {
    private let preferences: Preferences
    private let store: UsageStore
    private var window: NSWindow?

    init(
        preferences: Preferences,
        store: UsageStore
    ) {
        self.preferences = preferences
        self.store = store
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                store: store
            ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Agent Notch Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        let fitted = hosting.view.fittingSize
        window.setContentSize(fitted)
        let margin: CGFloat = 48
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
            window.frame.height > visible.height - margin
        {
            let chrome = window.frame.height - fitted.height
            let contentHeight = max(320, visible.height - margin - chrome)
            window.setContentSize(NSSize(width: fitted.width, height: contentHeight))
        }
        return window
    }
}
