import SwiftUI

/// Help topics, shown one at a time.
enum HelpTopic: String, CaseIterable, Identifiable {
    case guide, shortcuts, settings, integrations, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guide: return "Guide"
        case .shortcuts: return "Shortcuts"
        case .settings: return "Settings File"
        case .integrations: return "Integrations"
        case .about: return "About"
        }
    }

    /// The topic that holds a section anchor used by links elsewhere in the app.
    init(anchor: String) {
        switch anchor {
        case "shortcuts": self = .shortcuts
        case "settings": self = .settings
        case "integrations": self = .integrations
        case "system", "about": self = .about
        default: self = .guide
        }
    }
}

struct HelpView: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @EnvironmentObject private var state: AppState
    @State private var topic: HelpTopic = .guide

    var body: some View {
        PageScaffold(title: "Help", subtitle: "How to do things, what to try when something's off, and every shortcut.") {
            Picker("Topic", selection: $topic) {
                ForEach(HelpTopic.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            if isSnapshot {
                // Match SnapshotRenderer's width so wrapped text contributes its full height.
                sections
                    .frame(width: 1000 - (state.sidebarVisible ? Theme.sidebarWidth + 1 : 0) - Theme.pagePadding * 2)
            } else {
                ScrollViewReader { proxy in
                    sections
                        .onAppear { scrollToPendingAnchor(proxy) }
                        .onChange(of: state.pendingAnchor) { _ in scrollToPendingAnchor(proxy) }
                }
            }
        }
        .onAppear {
            if let anchor = state.pendingAnchor { topic = HelpTopic(anchor: anchor) }
            if isSnapshot, let name = ProcessInfo.processInfo.environment["OYM_SNAPSHOT_HELP"], let chosen = HelpTopic(rawValue: name) {
                topic = chosen
            }
        }
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            switch topic {
            case .guide:
                strip.id("strip")
                HelpGuideSection().id("how-to")
                HelpTroubleshootingSection().id("troubleshooting")
            case .shortcuts:
                HelpShortcutReference().id("shortcuts")
            case .settings:
                HelpSettingsReference().id("settings")
            case .integrations:
                HelpIntegrations().id("integrations")
            case .about:
                HelpAbout().id("about")
                HelpSystemInformation().id("system")
            }
        }
    }

    private var strip: some View {
        PageSection("The Strip", caption: "The one idea behind \(AppPaths.appName)") {
            Card(inset: 16) {
                HStack(alignment: .center, spacing: 18) {
                    BrandMark(size: 56)
                    Text("Your windows sit next to each other on a horizontal strip. The screen is a view into part of that strip. Focus a window and the strip slides to bring it into view. New windows add space instead of making every window smaller. Each display has a strip of its own.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func scrollToPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = state.pendingAnchor else { return }
        topic = HelpTopic(anchor: anchor)
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            if state.pendingAnchor == anchor { state.pendingAnchor = nil }
        }
    }
}

/// Current alternatives are read here, so answers update along with the editor.
struct HelpActionKeys: View {
    let actionIDs: [String]
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actionIDs, id: \.self) { id in
                if let action = ShortcutCatalog.action(id) {
                    FlowLayout(spacing: 8, lineSpacing: 5) {
                        Text(action.title).font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        let combos = config.combos(for: id)
                        if combos.isEmpty {
                            Text("No shortcut set — add one in Shortcuts")
                                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(Array(combos.enumerated()), id: \.offset) { _, combo in
                            KeyCapRow(glyphs: combo.glyphs, size: 18)
                        }
                    }
                }
            }
        }
    }
}
