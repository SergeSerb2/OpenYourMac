import SwiftUI

struct HelpView: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @EnvironmentObject private var state: AppState

    var body: some View {
        PageScaffold(title: "Help", subtitle: "How to do things, what to try when something's off, and every shortcut.") {
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
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            strip.id("strip")
            HelpGuideSection().id("how-to")
            HelpTroubleshootingSection().id("troubleshooting")
            HelpShortcutReference().id("shortcuts")
            HelpSettingsReference().id("settings")
            HelpIntegrations().id("integrations")
            HelpSystemInformation().id("system")
            HelpAbout().id("about")
        }
    }

    private var strip: some View {
        PageSection("The Strip", caption: "The one idea behind \(AppPaths.appName)") {
            Card(inset: 16) {
                Text("Your windows sit next to each other on a horizontal strip. The screen is a view into part of that strip. Focus a window and the strip slides to bring it into view. New windows add space instead of making every window smaller. Each display has a strip of its own.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scrollToPendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = state.pendingAnchor else { return }
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
