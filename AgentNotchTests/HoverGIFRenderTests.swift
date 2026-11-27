import AppKit
import SwiftUI
import Testing

@testable import AgentNotch

@MainActor
struct HoverGIFRenderTests {
    private nonisolated static let output = ProcessInfo.processInfo.environment["AGENTNOTCH_RENDER_HOVER_DIR"]

    @Test(.enabled(if: Self.output != nil, "Set AGENTNOTCH_RENDER_HOVER_DIR to render the README GIF"))
    func renderHover() async throws {
        #if AGENTNOTCH_DEMO
            let directory = URL(fileURLWithPath: try #require(Self.output), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suite = "HoverGIFRender.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let preferences = Preferences(defaults: defaults, loginItemEnabled: false)
            preferences.notchEdge = .right
            preferences.notchVisibility = .onHover
            preferences.hiddenProviders = []
            let providers = ProviderID.allCases.map { SampleProvider(id: $0) }
            let store = UsageStore(providers: providers, defaults: defaults)
            store.refreshAll()
            while store.isRefreshing { await Task.yield() }

            let model = NotchViewModel(preferences: preferences, store: store)
            #expect(model.providers == [.claude, .codex, .grokBuild, .antigravity])
            try await record(model, into: directory)
        #else
            Issue.record("Compile with AGENTNOTCH_DEMO to render the hover GIF")
        #endif
    }

    #if AGENTNOTCH_DEMO
        private struct SampleProvider: UsageProvider {
            let id: ProviderID

            func fetch() async throws -> ProviderSnapshot {
                var sample = try await DemoUsageProvider(id: id).fetch()
                // Keep the original GIF's single-window Claude and Codex examples.
                let originalUsage: [ProviderID: Double] = [.claude: 0.40, .codex: 0.18]
                if let fraction = originalUsage[id] {
                    sample.windows = [
                        LimitWindow(
                            id: "weekly", label: "Weekly limit",
                            usedFraction: fraction,
                            resetsAt: sample.fetchedAt.addingTimeInterval(3 * 86400))
                    ]
                    sample.sessions = []
                }
                return sample
            }
        }

        private func record(_ model: NotchViewModel, into directory: URL) async throws {
            let size = model.panelSize
            let scale: CGFloat = 1.55
            let origin = CGPoint(x: 640 - size.width * scale, y: 442 - size.height * scale / 2)
            let viewport = ((14 - origin.y) / scale)...((856 - origin.y) / scale)
            let expanded = NotchLayout(edge: .right, cells: model.providers.count, isExpanded: true, tooltipHeight: 0)
            func onCanvas(_ point: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            }

            // Seconds from the start, with holds at each ring long enough to read its card.
            let rest = CGPoint(x: 340, y: 367)
            let pill = onCanvas(CGPoint(x: expanded.pillRect.midX, y: expanded.pillRect.midY))
            let rings = model.providers.indices.map { onCanvas(expanded.ringCenter($0)) }
            // Leave through the gap between the middle cells before moving up to Claude.
            let approachX = 640 - NotchMetrics.thickness * scale - 10
            let waypoints: [(Double, CGPoint)] = [
                (0, rest), (0.28, rest), (0.77, pill), (1.20, pill),
                (1.48, CGPoint(x: approachX, y: pill.y)), (1.74, CGPoint(x: approachX, y: rings[0].y)),
                (2.00, rings[0]), (4.16, rings[0]),
                (4.73, rings[1]), (6.65, rings[1]), (7.24, rings[2]), (9.65, rings[2]),
                (10.23, rings[3]), (13.00, rings[3]), (13.38, rest), (14.45, rest),
            ]
            let fps = 24
            let frames = Int(14.45 * Double(fps))
            let clock = ContinuousClock()
            let start = clock.now
            var expansion: CGFloat = 0
            var tooltip: CGFloat = 0
            var lastProvider: ProviderID?
            var seen: [ProviderID] = []
            var lastSample = start
            var positions = "frame,x,y,cursor\n"

            for frame in 0..<frames {
                let time = Double(frame) / Double(fps)
                try await clock.sleep(until: start + .seconds(time))
                let now = clock.now
                let elapsed = lastSample.duration(to: now)
                let dt = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                lastSample = now

                let next = try #require(waypoints.firstIndex { $0.0 > time })
                let (t0, a) = waypoints[next - 1]
                let (t1, b) = waypoints[next]
                let f = ease((time - t0) / (t1 - t0))
                let point = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                let local = CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
                model.pointerMoved(to: local)
                let provider = model.hoveredProvider
                if let provider, provider != lastProvider, let index = model.hoveredIndex {
                    // ImageRenderer has no hosted geometry callbacks. Measure the same card before positioning it.
                    let card = TooltipCard(
                        id: provider, status: model.status(for: provider),
                        direction: .pointsRight, tailCenter: 40)
                    let measurement = ImageRenderer(content: card)
                    model.tooltipHeight = CGFloat(try #require(measurement.cgImage).height)
                    #expect(model.layout.tooltipRect(for: index).height >= model.tooltipHeight)
                    tooltip = 0
                    if !seen.contains(provider) { seen.append(provider) }
                }
                lastProvider = provider
                expansion = model.isExpanded ? min(1, expansion + dt / 0.36) : max(0, expansion - dt / 0.32)
                tooltip = min(1, tooltip + dt / 0.22)
                let hand =
                    model.isExpanded && model.providers.indices.contains { expanded.cellRect($0).contains(local) }
                positions += "\(frame),\(point.x),\(point.y),\(hand ? "hand" : "arrow")\n"

                let view = ZStack(alignment: .topLeading) {
                    NotchRootView(
                        model: model, recordedExpansion: ease(expansion), recordedTooltip: ease(tooltip),
                        recordedViewport: viewport
                    )
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: origin.x, y: origin.y)
                    cursor(hand: hand)
                        .offset(x: point.x - (hand ? 8 : 2), y: point.y - 2)
                }
                .frame(width: 640, height: 870, alignment: .topLeading)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", frame)))
            }
            #expect(seen == model.providers)
            try positions.write(to: directory.appendingPathComponent("pointer.csv"), atomically: true, encoding: .utf8)
        }

        private func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }

        private func cursor(hand: Bool) -> some View {
            let path = Path { p in
                if hand {
                    p.move(to: CGPoint(x: 5, y: 21))
                    p.addQuadCurve(to: CGPoint(x: 2, y: 12), control: CGPoint(x: 3, y: 16))
                    p.addQuadCurve(to: CGPoint(x: 5, y: 12), control: CGPoint(x: 3, y: 9))
                    p.addLine(to: CGPoint(x: 7, y: 15))
                    p.addLine(to: CGPoint(x: 7, y: 4))
                    p.addQuadCurve(to: CGPoint(x: 10, y: 4), control: CGPoint(x: 8.5, y: 0))
                    p.addLine(to: CGPoint(x: 10, y: 10))
                    p.addQuadCurve(to: CGPoint(x: 16, y: 11), control: CGPoint(x: 14, y: 7.5))
                    p.addQuadCurve(to: CGPoint(x: 15, y: 21), control: CGPoint(x: 18, y: 13))
                } else {
                    let points = [(2, 2), (2, 23), (7, 18), (11, 26), (14, 24), (10, 17), (17, 17)]
                    p.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
                }
                p.closeSubpath()
            }
            return path.fill(hand ? .white : .black)
                .overlay { path.stroke(hand ? .black : .white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round)) }
                .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                .frame(width: 20, height: 29)
        }
    #endif
}
