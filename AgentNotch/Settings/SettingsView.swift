import AppKit
import SwiftUI

/// Foreground grant. File check and the single Keychain read run off the main actor.
nonisolated enum UsageAccessGrant {
    nonisolated static func perform(_ id: ProviderID) throws {
        switch id {
        case .claude:
            try Keychain.requestReadAccess(service: ClaudeOAuthStore.claudeCodeService)
        case .codex:
            let authFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
            if FileManager.default.isReadableFile(atPath: authFile.path) { return }
            try Keychain.requestReadAccess(service: "Codex Auth")
        case .grokBuild:
            break
        }
    }
}

/// One in-flight grant per provider. A later off or disappeared view invalidates that generation.
@MainActor
@Observable
final class UsageAccessGrantCoordinator {
    private(set) var approving: Set<ProviderID> = []
    private var generation: [ProviderID: UInt] = [:]

    func begin(_ id: ProviderID) -> UInt? {
        if approving.contains(id) { return nil }
        approving.insert(id)
        return generation[id, default: 0]
    }

    func cancel(_ id: ProviderID) {
        generation[id, default: 0] &+= 1
        approving.remove(id)
    }

    func complete(_ id: ProviderID, generation: UInt) -> Bool {
        guard self.generation[id, default: 0] == generation else { return false }
        approving.remove(id)
        return true
    }
}

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let store: UsageStore
    var checkForUpdates: () -> Void = {}
    #if !AGENTNOTCH_DEMO
    @State private var usageAccessError: String?
    @State private var grantCoordinator = UsageAccessGrantCoordinator()
    #endif

    private static let width: CGFloat = 460

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                assistants
                placement
                presence
                updates
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        #if !AGENTNOTCH_DEMO
        .onDisappear {
            for id in ProviderID.allCases where grantCoordinator.approving.contains(id) {
                Keychain.clearApprovedSession(provider: id)
                grantCoordinator.cancel(id)
                Keychain.invalidatePendingGrant(provider: id)
            }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if AGENTNOTCH_DEMO
            Text("Demo — sample data")
                .font(.system(size: 22, weight: .bold))
            Text("No account credentials or provider connections are used.")
                .settingsDetail()
            #else
            Text("Agent Notch Plus")
                .font(.system(size: 22, weight: .bold))
            Text("Account access is off until you enable a provider. That permission is remembered until you turn it off.")
                .settingsDetail()
            #endif
        }
    }

    private var assistants: some View {
        Section("Assistants") {
            VStack(spacing: 8) {
                ForEach(ProviderID.allCases) { id in
                    #if AGENTNOTCH_DEMO
                    AccountRow(
                        id: id,
                        status: store.status(for: id),
                        isEnabled: Binding(
                            get: { !preferences.hiddenProviders.contains(id) },
                            set: { preferences.setProvider(id, enabled: $0) }
                        )
                    )
                    #else
                    AccountRow(
                        id: id,
                        status: store.status(for: id),
                        isEnabled: Binding(
                            get: { preferences.usageAccessProviders.contains(id) },
                            set: { allowed in
                                if !allowed {
                                    grantCoordinator.cancel(id)
                                    Keychain.clearApprovedSession(provider: id)
                                    preferences.setUsageAccess(id, allowed: false)
                                    store.setEnabledProviders(preferences.usageAccessProviders)
                                    usageAccessError = nil
                                    return
                                }
                                guard let generation = grantCoordinator.begin(id) else { return }
                                let providerID = id
                                Task { @MainActor in
                                    let outcome = await Task.detached { () -> Result<Void, Error> in
                                        do {
                                            try UsageAccessGrant.perform(providerID)
                                            return .success(())
                                        } catch {
                                            return .failure(error)
                                        }
                                    }.value
                                    guard grantCoordinator.complete(providerID, generation: generation) else {
                                        return
                                    }
                                    switch outcome {
                                    case .success:
                                        preferences.setUsageAccess(providerID, allowed: true)
                                        store.setEnabledProviders(preferences.usageAccessProviders)
                                        usageAccessError = nil
                                    case .failure(let error):
                                        if Keychain.isOverlappingGrant(error) { return }
                                        preferences.setUsageAccess(providerID, allowed: false)
                                        store.setEnabledProviders(preferences.usageAccessProviders)
                                        usageAccessError = (error as? UsageProviderError)?.message
                                            ?? "macOS did not allow reading the existing sign-in."
                                    }
                                }
                            }
                        ),
                        grantsUsageAccess: true,
                        isApproving: grantCoordinator.approving.contains(id)
                    )
                    #endif
                }
            }
            #if !AGENTNOTCH_DEMO
            Text("Allow usage access stays off until you enable a provider, and that choice is remembered until you turn it off. Claude, Codex, and Grok may send an existing access token only to that provider. macOS may ask the first time a Keychain item is read.")
                .settingsDetail()
            if let usageAccessError {
                Text(usageAccessError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
    }

    private var placement: some View {
        Section("Where the notch appears") {
            SettingsPicker(selection: $preferences.notchVisibility)
            SettingsPicker(selection: $preferences.notchEdge)
        }
    }

    private var presence: some View {
        Section("App icon") {
            SettingsPicker(selection: $preferences.appPresence)
        }
    }

    private var updates: some View {
        Section("Updates") {
            // Matches AppUpdater: only release builds start Sparkle.
            #if DEBUG || AGENTNOTCH_DEMO
            Text("Updates disabled for this local build")
                .settingsDetail()
            #else
            Text("New versions are checked automatically and offered here before they install.")
                .settingsDetail()
            Button("Check for Updates…", action: checkForUpdates)
            #endif
        }
    }

    private var footer: some View {
        SettingsFooter()
    }
}

/// Fork credit. The sentence stays in order. A link grows in its own box so the words beside it stay put.
struct SettingsFooter: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        FooterSentence(version: version)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 6)
    }
}

private struct FooterSentence: View {
    let version: String

    var body: some View {
        FooterFlow {
            FooterLink(title: "Agent Notch Plus", url: "https://github.com/neeeeeeessa/agent-notch-plus")
            FooterSpace()
            FooterWord("is developed by")
            FooterSpace()
            FooterLink(title: "Vanessa Simões", url: "https://x.com/enchantedcode")
            FooterWord(".")
            FooterSpace()
            FooterWord("Forked from")
            FooterSpace()
            FooterLink(title: "Agent Notch", url: "https://github.com/itslucadev/AgentNotch")
            FooterSpace()
            FooterWord("by Luca Becker · v\(version)")
        }
    }
}

private struct FooterWord: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

private struct FooterSpace: View {
    var body: some View {
        Text(" ")
            .font(.system(size: 11))
            .accessibilityHidden(true)
            .layoutValue(key: FooterIsSpaceKey.self, value: true)
    }
}

private struct FooterLink: View {
    let title: String
    let url: String
    @State private var hovered = false
    @Environment(\.controlActiveState) private var controlActiveState

    private let rest: CGFloat = 11
    private let grown: CGFloat = 11.5

    /// Same accent the on-switches use: blue while this window is active, gray when another app is front.
    private var tint: Color {
        if controlActiveState == .inactive {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        return Color.accentColor
    }

    var body: some View {
        Link(destination: URL(string: url)!) {
            ZStack {
                Text(title)
                    .font(.system(size: grown))
                    .hidden()
                Text(title)
                    .font(.system(size: hovered ? grown : rest))
                    .foregroundStyle(tint)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .tint(tint)
        .pointerStyle(.link)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { hovered = hovering }
        }
    }
}

nonisolated private struct FooterIsSpaceKey: LayoutValueKey {
    static let defaultValue = false
}

/// Centered lines. A space at the wrap stays on the previous line.
private struct FooterFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 404
        let lines = wrap(subviews, width: width)
        let spacing = lineSpacing(lines.count)
        let height = lines.reduce(0) { $0 + $1.height } + spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = wrap(subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for item in line.items {
                item.view.place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += line.height + 3
        }
    }

    private func lineSpacing(_ count: Int) -> CGFloat {
        CGFloat(max(count - 1, 0)) * 3
    }

    private struct Item {
        let view: LayoutSubview
        let size: CGSize
        let isSpace: Bool
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrap(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let isSpace = view[FooterIsSpaceKey.self]
            let item = Item(view: view, size: size, isSpace: isSpace)
            if !line.items.isEmpty, !isSpace, line.width + size.width > width {
                lines.append(line)
                line = Line()
            }
            if line.items.isEmpty, isSpace { continue }
            line.items.append(item)
            line.width += size.width
            line.height = max(line.height, size.height)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// Section title plus its content, spaced like a System Settings group.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
    }
}

/// Rounded surface shared by rows and the login toggle so trailing switches line up.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Equal-width segmented control with the selected option's explanation underneath.
private struct SettingsPicker<Option: CaseIterable & Identifiable & Hashable & SettingsOption>: View
where Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Option.allCases) { option in
                    let selected = option == selection
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selected ? Color.primary.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.18)) { selection = option }
                        }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(selection.detail)
                .settingsDetail()
                .padding(.horizontal, 2)
        }
    }
}

protocol SettingsOption {
    var title: String { get }
    var detail: String { get }
}

extension NotchVisibility: SettingsOption {}
extension NotchEdge: SettingsOption {}
extension AppPresence: SettingsOption {}

private extension Text {
    func settingsDetail() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One assistant. Demo keeps a visual on/off switch. Live grants usage access and does not open an account session.
struct AccountRow: View {
    let id: ProviderID
    let status: ProviderStatus
    @Binding var isEnabled: Bool
    var grantsUsageAccess: Bool = false
    var isApproving: Bool = false

    var body: some View {
        SettingsCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.black)
                    Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    ProviderGlyph(id: id)
                        .frame(width: 15, height: 15)
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(id.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if grantsUsageAccess {
                        Text("Allow usage access")
                            .font(.system(size: 11, weight: .medium))
                        Text(accessExplanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !grantsUsageAccess {
                    Button {} label: {
                        Text(id.manageTitle).frame(width: 84)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                }

                Toggle(grantsUsageAccess ? "Allow usage access" : "", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(isApproving)
            }
        }
    }

    private var accessExplanation: String {
        switch id {
        case .claude:
            "Reads the existing Claude Code sign-in and sends that token only to api.anthropic.com."
        case .codex:
            "Reads the existing Codex sign-in and sends that token only to chatgpt.com."
        case .grokBuild:
            "Sends the existing Grok CLI access token only to cli-chat-proxy.grok.com. Shows the shared weekly allowance used by Grok Build, Grok Bot and Cursor."
        }
    }

    private var statusText: String {
        if isApproving { return "Approving this sign-in…" }
        guard isEnabled else {
            if grantsUsageAccess { return UsageStore.disconnectedStatus }
            return "Off. The notch is not reading \(id.ownerTool)."
        }
        switch status {
        case .ready(let snapshot, _):
            let who = [snapshot.account, snapshot.plan].compactMap { $0 }.joined(separator: " · ")
            return who.isEmpty ? "Signed in through \(id.ownerTool)" : who
        case .waiting: return "Waiting for the first reading"
        case .needsAuth(let message): return message
        case .failed(let message): return message
        }
    }
}
