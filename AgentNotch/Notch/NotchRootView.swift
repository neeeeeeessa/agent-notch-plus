import SwiftUI

/// Everything drawn inside the transparent notch panel.
struct NotchRootView: View {
    @Bindable var model: NotchViewModel
    // ImageRenderer lays out each frame independently, so the offscreen capture supplies
    // the same transition properties at the current point in the timeline.
    var recordedExpansion: CGFloat? = nil
    var recordedTooltip: CGFloat? = nil
    var recordedViewport: ClosedRange<CGFloat>? = nil

    private var expansion: CGFloat { recordedExpansion ?? (model.isExpanded ? 1 : 0) }

    var body: some View {
        let layout = model.layout
        ZStack(alignment: .topLeading) {
            notchBody(layout)
            pillEyes(layout)
            if model.providers.isEmpty {
                if model.isExpanded { chooseAssistants(layout) }
            } else {
                cells(layout)
                settingsOrb(layout)
                peekHead(layout)
                tooltip(layout)
            }
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .topLeading)
        .animation(.spring(duration: 0.42, bounce: 0.22), value: model.isExpanded)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: model.isOrbHovered)
        .animation(.spring(duration: 0.28, bounce: 0.18), value: model.hoveredProvider)
    }

    private func notchBody(_ layout: NotchLayout) -> some View {
        var rect = layout.shapeRect
        var corner = layout.cornerRadius
        var ear = layout.earRadius
        if let progress = recordedExpansion {
            let closed = NotchLayout(edge: layout.edge, cells: layout.cells, isExpanded: false, tooltipHeight: 0)
            let start = closed.shapeRect
            let end = NotchLayout(edge: layout.edge, cells: layout.cells, isExpanded: true, tooltipHeight: 0)
            func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
            rect = CGRect(x: interpolate(start.minX, end.shapeRect.minX),
                          y: interpolate(start.minY, end.shapeRect.minY),
                          width: interpolate(start.width, end.shapeRect.width),
                          height: interpolate(start.height, end.shapeRect.height))
            corner = interpolate(closed.cornerRadius, end.cornerRadius)
            ear = interpolate(closed.earRadius, end.earRadius)
        }
        return SideNotchShape(edge: layout.edge, cornerRadius: corner, earRadius: ear)
            .fill(.black)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func chooseAssistants(_ layout: NotchLayout) -> some View {
        let rect = layout.bodyRect
        return Button(action: model.orbClicked) {
            Text("Choose assistants")
                .font(.system(size: 11, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.white)
                .frame(width: rect.width - 8, height: rect.height - 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    private func cells(_ layout: NotchLayout) -> some View {
        ForEach(Array(model.providers.enumerated()), id: \.element) { index, id in
            let rect = layout.cellRect(index)
            ProviderCell(
                id: id,
                status: model.status(for: id),
                spinTurns: model.spinTurns[id] ?? 0
            )
            .frame(width: rect.width, height: rect.height)
            // Bound the click target to the cell frame before position expands layout across the panel.
            .contentShape(Rectangle())
            .onTapGesture { model.cellClicked(id) }
            .position(x: rect.midX, y: rect.midY)
            .opacity(expansion)
            .scaleEffect(0.6 + 0.4 * expansion, anchor: layout.edge.anchorAtEdge)
        }
    }

    private func settingsOrb(_ layout: NotchLayout) -> some View {
        SettingsOrb(
            edge: layout.edge, isHovered: model.isOrbHovered, arcCenter: layout.arcCenter, orbRect: layout.orbRect
        )
        .onTapGesture { model.orbClicked() }
        .opacity(expansion)
    }

    /// Collapsed: Peek looks out of the pill. Fades with the pill as the body opens.
    private func pillEyes(_ layout: NotchLayout) -> some View {
        let rect = layout.pillRect
        return PeekView(model: model, layout: layout, style: .pill, paused: model.isExpanded)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.pillCornerRadius))
            .position(x: rect.midX, y: rect.midY)
            .opacity(1 - expansion)
            .allowsHitTesting(false)
    }

    /// Expanded: the head off the body's start, revealed exactly like the orb at the other end.
    private func peekHead(_ layout: NotchLayout) -> some View {
        let rect = layout.headRect
        // Room for a clip's rings past the disc; the click target stays the disc plus two points
        // of slack on each side, as the waiting nudge swells it.
        let side = PeekClip.side
        return PeekView(model: model, layout: layout, style: .head, paused: !model.isExpanded)
            .frame(width: side, height: side)
            .contentShape(Circle().inset(by: (side - rect.width) / 2 - 2))
            .onTapGesture { model.headClicked() }
            .position(x: rect.midX, y: rect.midY)
            .scaleEffect(0.3 + 0.7 * expansion, anchor: layout.edge.anchorAtEdge)
            .opacity(expansion)
            .allowsHitTesting(model.isExpanded)
    }

    private func tooltipRect(_ layout: NotchLayout, index: Int) -> CGRect {
        var rect = layout.tooltipRect(for: index)
        if let viewport = recordedViewport {
            rect.origin.y = min(max(rect.minY, viewport.lowerBound), viewport.upperBound - rect.height)
        }
        return rect
    }

    @ViewBuilder
    private func tooltip(_ layout: NotchLayout) -> some View {
        if model.isExpanded, let id = model.hoveredProvider, let index = model.hoveredIndex {
            let rect = tooltipRect(layout, index: index)
            TooltipCard(
                id: id,
                status: model.status(for: id),
                direction: layout.tooltipDirection,
                tailCenter: layout.isStacked ? layout.ringCenter(index).y - rect.minY : layout.tooltipTailCenter(for: index),
                awaitingOwnerTool: model.isAwaitingOwnerTool(id)
            )
            .frame(width: rect.width)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: { height in
                model.tooltipHeight = height
            }
            .scaleEffect(0.86 + 0.14 * (recordedTooltip ?? 1), anchor: layout.edge.anchorAtEdge)
            .opacity(recordedTooltip ?? 1)
            .position(x: rect.midX, y: rect.midY)
            .transition(.scale(scale: 0.86, anchor: layout.edge.anchorAtEdge).combined(with: .opacity))
            .id(id)
        }
    }
}

extension NotchEdge {
    /// Unit point on the screen-edge side, used to grow content out of the edge.
    var anchorAtEdge: UnitPoint {
        switch self {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }
}

/// Hardware-notch profile: convex corners on the free side, concave ears where it meets the screen edge.
/// The rect includes the ears, so the flat body spans `rect` minus one ear radius at each end.
struct SideNotchShape: Shape {
    var edge: NotchEdge
    var cornerRadius: CGFloat
    var earRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, earRadius) }
        set {
            cornerRadius = newValue.first
            earRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Build for the right edge in a (thickness x length) space, then map onto the requested edge.
        let stacked = edge == .left || edge == .right
        let thickness = stacked ? rect.width : rect.height
        let length = stacked ? rect.height : rect.width
        let ear = min(earRadius, length / 2)
        let radius = min(cornerRadius, thickness, (length - 2 * ear) / 2)

        var path = Path()
        path.move(to: CGPoint(x: thickness, y: 0))
        // Top ear: concave quarter arc centred on the edge at the body's start.
        path.addArc(
            center: CGPoint(x: thickness - ear, y: 0), radius: ear, startAngle: .degrees(0), endAngle: .degrees(90),
            clockwise: false)
        path.addLine(to: CGPoint(x: radius, y: ear))
        path.addArc(
            center: CGPoint(x: radius, y: ear + radius), radius: radius, startAngle: .degrees(270),
            endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: length - ear - radius))
        path.addArc(
            center: CGPoint(x: radius, y: length - ear - radius), radius: radius, startAngle: .degrees(180),
            endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: thickness - ear, y: length - ear))
        // Bottom ear.
        path.addArc(
            center: CGPoint(x: thickness - ear, y: length), radius: ear, startAngle: .degrees(270),
            endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()

        let transform: CGAffineTransform
        switch edge {
        case .right: transform = .identity
        case .left: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: thickness, ty: 0)
        case .top: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: thickness)
        case .bottom: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
        return path.applying(transform.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Ring, glyph and percentage for one provider.
struct ProviderCell: View {
    let id: ProviderID
    let status: ProviderStatus
    let spinTurns: Int

    private var headline: LimitWindow? { status.snapshot?.headline }
    private var dimmed: Bool { headline == nil || status.isStale }

    var body: some View {
        VStack(spacing: NotchMetrics.ringLabelSpacing) {
            ZStack {
                StatusRing(
                    fraction: headline?.usedFraction,
                    color: headline == nil ? .clear : id.accentColor,
                    dimmed: status.isStale
                )
                .rotationEffect(.degrees(Double(spinTurns) * 360))
                .animation(.easeInOut(duration: 0.75), value: spinTurns)
                ProviderGlyph(id: id)
                    .frame(width: NotchMetrics.glyphSize, height: NotchMetrics.glyphSize)
                    .foregroundStyle(.white)
                    .opacity(dimmed ? 0.42 : 1)
            }
            .frame(width: NotchMetrics.ringDiameter, height: NotchMetrics.ringDiameter)
            label
                .frame(height: NotchMetrics.labelHeight)
        }
    }

    @ViewBuilder
    private var label: some View {
        if let headline {
            Text("\(Int((headline.usedFraction * 100).rounded()))%")
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(id.accentColor)
                .opacity(status.isStale ? 0.6 : 1)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: headline.usedFraction)
        } else {
            Capsule()
                .fill(.white)
                .frame(width: 12, height: 2)
        }
    }
}

/// Thick near-black track with a thinner arc running down its middle, clockwise from twelve o'clock.
struct StatusRing: View {
    var fraction: Double?
    var color: Color
    var dimmed: Bool

    var body: some View {
        let inset = NotchMetrics.trackLineWidth / 2
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.075), lineWidth: NotchMetrics.trackLineWidth)
                .padding(inset)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: NotchMetrics.ringLineWidth, lineCap: .round))
                    .padding(inset)
                    .rotationEffect(.degrees(-90))
                    .opacity(dimmed ? 0.45 : 1)
                    .animation(.spring(duration: 0.6, bounce: 0.1), value: fraction)
            }
        }
    }
}

/// Collapsed: a thin black arc curling from the body's end into the screen edge. Hovered: a gear orb.
struct SettingsOrb: View {
    let edge: NotchEdge
    let isHovered: Bool
    let arcCenter: CGPoint
    let orbRect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            SettingsArc(edge: edge, center: arcCenter)
                .stroke(.black, style: StrokeStyle(lineWidth: NotchMetrics.arcLineWidth, lineCap: .round))
                .opacity(isHovered ? 0 : 1)

            ZStack {
                Circle().fill(.black)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(isHovered ? 0 : -60))
            }
            .frame(width: orbRect.width, height: orbRect.height)
            .scaleEffect(isHovered ? 1 : 0.3, anchor: edge.anchorAtEdge)
            .opacity(isHovered ? 1 : 0)
            .position(x: orbRect.midX, y: orbRect.midY)
        }
        .contentShape(Circle().path(in: orbRect).union(Rectangle().path(in: arcHotRect)))
    }

    private var arcHotRect: CGRect {
        let reach = NotchMetrics.arcRadius + 4
        return CGRect(x: arcCenter.x - reach, y: arcCenter.y - reach, width: 2 * reach, height: 2 * reach)
    }
}

/// Quarter arc from the body's end direction round into the screen edge.
struct SettingsArc: Shape {
    var edge: NotchEdge
    var center: CGPoint

    func path(in rect: CGRect) -> Path {
        // Angles in SwiftUI's y-down space: 0 right, 90 down, 180 left, 270 up.
        let (start, end): (Double, Double)
        switch edge {
        case .right: (start, end) = (270, 360)
        case .left: (start, end) = (270, 180)
        case .top: (start, end) = (180, 270)
        case .bottom: (start, end) = (180, 90)
        }
        var path = Path()
        path.addArc(
            center: center, radius: NotchMetrics.arcRadius, startAngle: .degrees(start), endAngle: .degrees(end),
            clockwise: end < start)
        return path
    }
}
