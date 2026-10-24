import SwiftUI

nonisolated enum TooltipDirection {
    case pointsRight
    case pointsLeft
    case pointsUp
    case pointsDown
}

/// Black speech bubble beside a ring: limit windows with bars, then live sessions.
struct TooltipCard: View {
    let id: ProviderID
    let status: ProviderStatus
    let direction: TooltipDirection
    /// Where the tail apex sits along the card's notch-facing edge, measured from that edge's start.
    let tailCenter: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch status {
            case .ready(let snapshot, let stale):
                let grokBilling = id == .grokBuild ? snapshot.grokBilling : nil
                if let grokBilling {
                    grokBillingSection(snapshot: snapshot, billing: grokBilling, stale: stale)
                } else {
                    ForEach(snapshot.windows) { window in
                        LimitWindowRow(window: window, color: id.accentColor)
                            .padding(.top, 6)
                    }
                }
                if !snapshot.sessions.isEmpty {
                    Divider()
                        .overlay(Color.white.opacity(0.12))
                        .padding(.top, 14)
                    ForEach(snapshot.sessions.prefix(6)) { session in
                        SessionRow(session: session)
                            .padding(.top, 10)
                    }
                }
                // The Grok card reports a failed update on its own source line.
                if stale, grokBilling == nil {
                    note(
                        "Couldn't read usage; showing the last reading from \(snapshot.fetchedAt, format: .relative(presentation: .named))."
                    )
                }
            case .waiting:
                note("Waiting for the first reading")
            case .needsAuth(let message):
                note(message)
                note(
                    "You stay signed in to the tool that owns the account. Switch accounts in \(id.ownerTool); the notch follows."
                )
            case .failed(let message):
                note(message)
            }
        }
        .padding(NotchMetrics.tooltipPadding)
        .padding(.bottom, 3)
        .frame(width: NotchMetrics.tooltipWidth, alignment: .leading)
        .background {
            TooltipShell(direction: direction, tailCenter: tailCenter)
                .fill(.black)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderGlyph(id: id)
                .frame(width: 16, height: 16)
                .foregroundStyle(.white)
            Text("\(id.displayName) Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(id.accentColor)
            Spacer(minLength: 0)
            if let plan = status.snapshot?.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private func note(_ text: String) -> some View {
        note(LocalizedStringKey(text))
    }

    private func grokBillingSection(snapshot: ProviderSnapshot, billing: GrokBilling, stale: Bool) -> some View {
        let overall = (snapshot.windows.first?.usedFraction ?? 0) * 100
        let caption = GrokCardText.periodCaption(billing: billing)
        let extras = GrokCardText.extraLines(billing: billing)
        let productsAddUp = GrokCardText.addsUp(billing: billing, overall: overall)
        return VStack(alignment: .leading, spacing: 0) {
            if let window = snapshot.windows.first {
                LimitWindowRow(window: window, color: id.accentColor, showsAllowanceLeft: true)
                    .padding(.top, 6)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            if !billing.products.isEmpty {
                let showsBars = billing.products.count <= 4
                VStack(alignment: .leading, spacing: showsBars ? 3 : 2) {
                    ForEach(billing.products) { share in
                        grokProductRow(share, overall: overall, showsBar: showsBars)
                    }
                }
                .padding(.top, 5)
                if billing.omittedProducts > 0 {
                    let omittedPercent = GrokCardText.percent(billing.omittedProductPercent)
                    Text(
                        billing.omittedProducts == 1
                            ? "1 more product: \(omittedPercent)"
                            : "\(billing.omittedProducts) more products: \(omittedPercent)"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                }
            }
            if !billing.conflictingProducts.isEmpty {
                Text(
                    "\(billing.conflictingProducts.joined(separator: ", ")) reported twice with different values; not shown"
                )
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            }
            if !billing.products.isEmpty, !productsAddUp {
                Text("Rows are as reported and may not add up.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            if !extras.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Extra credits are billed separately.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 5)
            }
            Text(
                "\(stale ? "Couldn't update · last reading" : "Live from Grok billing ·") \(snapshot.fetchedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))"
            )
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func grokProductRow(_ share: UsageShare, overall: Double, showsBar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text(share.label)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(GrokCardText.percent(share.percentOfAllowance))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                if let shareOfUsed = GrokCardText.shareOfUsed(points: share.percentOfAllowance, overall: overall) {
                    Text(" · \(shareOfUsed)% of used")
                        .foregroundStyle(.white.opacity(0.5))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            if showsBar {
                UsageBar(
                    fraction: share.percentOfAllowance / 100,
                    color: id.accentColor.opacity(0.7),
                    thickness: 3
                )
            }
        }
    }
}

/// Formatting for the Grok card. Internal so tests can lock the wording without rendering.
nonisolated enum GrokCardText {
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        let nearest = value.rounded()
        if abs(value - nearest) <= 0.05, let whole = Int(exactly: nearest) {
            return "\(whole)%"
        }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func shareOfUsed(points: Double, overall: Double) -> Int? {
        guard overall != 0, points.isFinite, overall.isFinite else { return nil }
        let rounded = (points / overall * 100).rounded()
        return Int(exactly: rounded)
    }

    static func dollars(cents: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = NSDecimalNumber(decimal: Decimal(cents) / 100)
        return formatter.string(from: amount) ?? String(format: "$%.2f", locale: Locale(identifier: "en_US"), Double(cents) / 100)
    }

    static func periodCaption(billing: GrokBilling) -> String? {
        guard billing.isUnifiedBilling == true else { return nil }
        let title = billing.periodIsWeekly == true ? "Shared weekly allowance" : "Shared allowance"
        guard let start = billing.periodStart, let end = billing.periodEnd, start <= end else { return title }
        return "\(title) · \(periodRange(start, end))"
    }

    static func extraLines(billing: GrokBilling) -> [String] {
        var lines: [String] = []
        if let prepaid = billing.prepaidBalanceCents {
            lines.append("Prepaid credits: \(dollars(cents: prepaid))")
        }
        if let used = billing.onDemandUsedCents {
            var line = "On-demand used: \(dollars(cents: used))"
            if let cap = billing.onDemandCapCents {
                line += " of \(dollars(cents: cap)) cap"
                if cap > 0 {
                    line += " · \(dollars(cents: onDemandRemainingCents(cap: cap, used: used))) left"
                }
            } else {
                line += " (no cap reported)"
            }
            line += onDemandSuffix(billing.onDemandEnabled)
            lines.append(line)
        } else if let cap = billing.onDemandCapCents {
            var line = "On-demand cap: \(dollars(cents: cap))"
            line += onDemandSuffix(billing.onDemandEnabled)
            lines.append(line)
        } else if billing.onDemandEnabled == false {
            lines.append("On-demand usage: off")
        } else if billing.onDemandEnabled == true {
            lines.append("On-demand usage: on")
        }
        if let method = billing.topUpMethod {
            lines.append("Top-up: \(method)")
        }
        return lines
    }

    private static func onDemandSuffix(_ enabled: Bool?) -> String {
        switch enabled {
        case true: " · on"
        case false: " · off"
        case nil: ""
        }
    }

    /// `max(0, cap - used)` without trapping when the subtraction does not fit in `Int64`.
    private static func onDemandRemainingCents(cap: Int64, used: Int64) -> Int64 {
        if used >= cap { return 0 }
        let (difference, overflow) = cap.subtractingReportingOverflow(used)
        return overflow ? Int64.max : difference
    }

    static func addsUp(billing: GrokBilling, overall: Double) -> Bool {
        guard overall.isFinite else { return false }
        let sum = billing.products.reduce(0.0) { $0 + $1.percentOfAllowance }
        return abs(sum - overall) <= 1
    }

    /// Compact local range such as "Oct 20 – 27", so the caption stays on one line.
    private static func periodRange(_ start: Date, _ end: Date) -> String {
        (start..<end).formatted(Date.IntervalFormatStyle(timeZone: .current).month(.abbreviated).day())
    }
}

struct LimitWindowRow: View {
    let window: LimitWindow
    let color: Color
    var showsAllowanceLeft: Bool = false

    private var usedPercent: Int {
        let scaled = (window.usedFraction * 100).rounded()
        if let exact = Int(exactly: scaled) { return exact }
        // Out-of-range or non-finite fractions must not trap. NaN fails both comparisons.
        if scaled > 0 { return 10_000 }
        if scaled < 0 { return -9_999 }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Text(resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            UsageBar(fraction: window.usedFraction, color: color)
            HStack(spacing: 8) {
                Text("\(usedPercent)% Used")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
                if showsAllowanceLeft, usedPercent <= 100 {
                    Spacer(minLength: 8)
                    Text("\(max(0, 100 - usedPercent))% left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }
            }
        }
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        let raw = resetsAt.timeIntervalSinceNow / 60
        let minutes: Int
        if raw.isFinite, let exact = Int(exactly: raw.rounded(.towardZero)) {
            minutes = exact
        } else {
            minutes = raw > 0 ? Int.max : 0
        }
        if minutes < 1 { return "Resets now" }
        if minutes < 60 { return "Resets in \(minutes) min" }
        return "Resets " + resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    var thickness: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: thickness)
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(activityColor)
                .frame(width: 6, height: 6)
            Text(session.name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(elapsed)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .monospacedDigit()
        }
    }

    private var activityColor: Color {
        switch session.activity {
        case .working: UsageBand.ample.color
        case .waiting: UsageBand.watch.color
        case .idle: .white.opacity(0.35)
        }
    }

    private var elapsed: String {
        let seconds = Int(-session.startedAt.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }
}

/// Rounded card with a curved tail on the notch side.
struct TooltipShell: Shape {
    var direction: TooltipDirection
    var tailCenter: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = NotchMetrics.tooltipCornerRadius
        let length = NotchMetrics.tooltipTailLength
        let base = NotchMetrics.tooltipTailBase
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

        // Tail geometry along the facing edge: `along` runs along that edge, `out` points away from the card.
        let edgeLength = direction == .pointsRight || direction == .pointsLeft ? rect.height : rect.width
        let apex = min(max(tailCenter, radius + base / 2), edgeLength - radius - base / 2)
        let map: (CGFloat, CGFloat) -> CGPoint
        switch direction {
        case .pointsRight: map = { along, out in CGPoint(x: rect.maxX + out, y: rect.minY + along) }
        case .pointsLeft: map = { along, out in CGPoint(x: rect.minX - out, y: rect.minY + along) }
        case .pointsDown: map = { along, out in CGPoint(x: rect.minX + along, y: rect.maxY + out) }
        case .pointsUp: map = { along, out in CGPoint(x: rect.minX + along, y: rect.minY - out) }
        }

        var tail = Path()
        tail.move(to: map(apex - base / 2, -1))
        tail.addQuadCurve(to: map(apex, length), control: map(apex - base * 0.18, length * 0.55))
        tail.addQuadCurve(to: map(apex + base / 2, -1), control: map(apex + base * 0.18, length * 0.55))
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}
