import CoreGraphics
import Foundation
import Observation
import os
import Testing

@testable import AgentNotch

#if AGENTNOTCH_DEMO
@MainActor
struct QuietMascotTests {
    private func makeModel(visibility: NotchVisibility) -> NotchViewModel {
        let defaults = UserDefaults(suiteName: "QuietMascotTests.\(UUID().uuidString)")!
        defaults.set(NotchEdge.right.rawValue, forKey: "notchEdge")
        defaults.set(visibility.rawValue, forKey: "notchVisibility")
        let store = UsageStore(providers: [], defaults: defaults)
        return NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
    }

    private func published(_ track: @escaping () -> Void, _ mutate: () -> Void) -> Bool {
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking(track) {
            fired.withLock { $0 = true }
        }
        mutate()
        return fired.withLock { $0 }
    }

    @Test func alwaysShowInteractingFollowsHeadNotPanelMargin() {
        let model = makeModel(visibility: .alwaysShow)
        let layout = model.layout
        let head = CGPoint(x: layout.headRect.midX, y: layout.headRect.midY)
        model.pointerMoved(to: head)
        #expect(model.isPeekInteracting)
        let margin = CGPoint(x: layout.panelSize.width / 2, y: 0)
        model.pointerMoved(to: margin)
        #expect(!model.isPeekInteracting)
        model.pointerMoved(to: nil)
        #expect(!model.isPeekInteracting)
    }

    @Test func onHoverCollapsedPillCenterInteracts() {
        let model = makeModel(visibility: .onHover)
        #expect(!model.isExpanded)
        let pill = model.layout.pillRect
        model.pointerMoved(to: CGPoint(x: pill.midX, y: pill.midY))
        #expect(model.isPeekInteracting)
        model.pointerMoved(to: nil)
        #expect(!model.isPeekInteracting)
    }

    @Test func interactingAndCuePublish() {
        let model = makeModel(visibility: .alwaysShow)
        let head = CGPoint(x: model.layout.headRect.midX, y: model.layout.headRect.midY)
        #expect(published({ _ = model.isPeekInteracting }, { model.pointerMoved(to: head) }))
        #expect(model.isPeekInteracting)
        #expect(published({ _ = model.isPeekInteracting }, { model.pointerMoved(to: nil) }))
        #expect(!model.isPeekInteracting)
        #expect(published({ _ = model.peekCue }, { model.headClicked() }))
        #expect(model.peekCue == .boop)
    }
}
#endif
