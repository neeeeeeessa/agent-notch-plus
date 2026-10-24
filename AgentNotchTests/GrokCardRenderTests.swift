import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentNotch

/// Renders the three-circle notch and the shared Grok card from synthetic data. No account is read.
@MainActor
struct GrokCardRenderTests {
    private struct Stub: UsageProvider {
        let snapshot: ProviderSnapshot
        var id: ProviderID { snapshot.id }
        func fetch() async throws -> ProviderSnapshot { snapshot }
    }

    private static let outputDirectory = ProcessInfo.processInfo.environment["AGENTNOTCH_RENDER_DIR"]

    private func render(_ view: some View, _ name: String) throws -> CGSize {
        let renderer = ImageRenderer(content: view.background(Color(white: 0.82)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let dir = Self.outputDirectory {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
    }

    private func grokSnapshot(extra: Bool) -> ProviderSnapshot {
        let now = Date()
        var billing = GrokBilling()
        billing.products = [
            UsageShare(id: "GrokBuild", label: "Grok Build", percentOfAllowance: 30),
            UsageShare(id: "GrokBot", label: "Grok Bot", percentOfAllowance: 15),
            UsageShare(id: "Cursor", label: "Cursor", percentOfAllowance: 10),
        ]
        billing.periodIsWeekly = true
        billing.periodStart = now.addingTimeInterval(-4 * 86400)
        billing.periodEnd = now.addingTimeInterval(3 * 86400)
        billing.isUnifiedBilling = true
        billing.prepaidBalanceCents = nil
        billing.topUpMethod = nil
        if extra {
            billing.onDemandEnabled = true
            billing.onDemandUsedCents = 1250
            billing.onDemandCapCents = 5000
        }
        var snapshot = ProviderSnapshot(
            id: .grokBuild, account: nil, plan: extra ? "Super grok" : nil,
            windows: [LimitWindow(id: "credits", label: "Weekly allowance", usedFraction: 0.55, resetsAt: billing.periodEnd)],
            fetchedAt: now.addingTimeInterval(-90))
        snapshot.grokBilling = billing
        return snapshot
    }

    private func store(_ grok: ProviderSnapshot) async -> (UsageStore, UserDefaults) {
        let now = Date()
        let samples: [ProviderID: Double] = [.claude: 0.40, .codex: 0.18]
        let providers: [Stub] = ProviderID.allCases.map { id in
            if id == .grokBuild { return Stub(snapshot: grok) }
            return Stub(snapshot: ProviderSnapshot(id: id, account: nil, plan: nil,
                windows: [LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: samples[id] ?? 0,
                    resetsAt: now.addingTimeInterval(3 * 86400))], fetchedAt: now))
        }
        let defaults = UserDefaults(suiteName: "GrokCardRender.\(UUID().uuidString)")!
        defaults.set(NotchVisibility.alwaysShow.rawValue, forKey: "notchVisibility")
        let store = UsageStore(providers: providers, defaults: defaults)
        store.refreshAll()
        while store.isRefreshing { await Task.yield() }
        return (store, defaults)
    }

    @Test func threeCircleNotchAndGrokCardRenderAndFitEveryEdge() async throws {
        let (store, defaults) = await store(grokSnapshot(extra: false))
        for edge in NotchEdge.allCases {
            defaults.set(edge.rawValue, forKey: "notchEdge")
            let model = NotchViewModel(preferences: Preferences(defaults: defaults), store: store)
            #expect(model.providers == [.claude, .codex, .grokBuild])
            model.freezeForCapture(orb: false)
            _ = try render(NotchRootView(model: model), "notch-\(edge.rawValue)")
        }
        for (name, extra) in [("card-grok", false), ("card-grok-extra", true)] {
            let status = ProviderStatus.ready(grokSnapshot(extra: extra), stale: false)
            let size = try render(
                TooltipCard(id: .grokBuild, status: status, direction: .pointsRight, tailCenter: 40), name)
            print("GROK CARD \(name) size=\(size)")
            #expect(size.height <= NotchMetrics.tooltipMaxHeight)
        }
        let stale = ProviderStatus.ready(grokSnapshot(extra: true), stale: true)
        let staleSize = try render(
            TooltipCard(id: .grokBuild, status: stale, direction: .pointsRight, tailCenter: 40), "card-grok-stale")
        #expect(staleSize.height <= NotchMetrics.tooltipMaxHeight)
        var worst = grokSnapshot(extra: true)
        worst.grokBilling?.products = (0..<8).map {
            UsageShare(id: "Product\($0)", label: "Long product name \($0)", percentOfAllowance: 5.5)
        }
        worst.grokBilling?.omittedProducts = 3
        let worstSize = try render(
            TooltipCard(id: .grokBuild, status: .ready(worst, stale: true), direction: .pointsRight, tailCenter: 40),
            "card-grok-worst")
        print("GROK CARD worst size=\(worstSize)")
        #expect(worstSize.height <= NotchMetrics.tooltipMaxHeight)
        // The tallest allowed card must sit inside the panel on every edge, for every circle.
        for edge in NotchEdge.allCases {
            let layout = NotchLayout(edge: edge, cells: 3, isExpanded: true, tooltipHeight: NotchMetrics.tooltipMaxHeight)
            let panel = CGRect(origin: .zero, size: layout.panelSize)
            for index in 0..<3 {
                #expect(panel.contains(layout.tooltipRect(for: index)), "edge \(edge.rawValue) cell \(index)")
            }
        }
    }
}
