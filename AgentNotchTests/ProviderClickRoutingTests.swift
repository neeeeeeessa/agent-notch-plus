import AppKit
import SwiftUI
import Testing
@testable import AgentNotch

struct ProviderClickRoutingTests {
    @Test @MainActor func clicksReachOnlyTheirOwnProviderOnEveryEdge() async throws {
        for edge in NotchEdge.allCases {
            let domain = "ProviderClickRoutingTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = Preferences(defaults: defaults)
            preferences.notchEdge = edge
            preferences.notchVisibility = .alwaysShow
            // No real provider, sign-in, network request or live preferences are involved.
            let model = NotchViewModel(preferences: preferences, store: UsageStore(providers: []))
            let panel = NotchPanel(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: model.panelSize))
            panel.level = .normal
            let host = NSHostingView(rootView: NotchRootView(model: model))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: model.panelSize)
            panel.contentView = host
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil); panel.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            for (index, id) in model.providers.enumerated() {
                let before = model.spinTurns
                let center = model.layout.ringCenter(index)
                let point = NSPoint(x: center.x, y: host.isFlipped ? center.y : host.bounds.height - center.y)
                let location = host.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: panel.windowNumber, context: nil, eventNumber: index * 2,
                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    panel.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(40))
                let changed = model.providers.filter { (model.spinTurns[$0] ?? 0) != (before[$0] ?? 0) }
                print("CLICK ROUTING edge=\(edge.rawValue) requested=\(id.rawValue) received=\(changed.map(\.rawValue).joined(separator: ","))")
                #expect(changed == [id])
                #expect(model.spinTurns[id] == (before[id] ?? 0) + 1)
            }
        }
    }
}
