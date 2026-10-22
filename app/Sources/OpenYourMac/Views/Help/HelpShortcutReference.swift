import SwiftUI

struct HelpShortcutReference: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var state: AppState

    var body: some View {
        PageSection("Shortcut Reference", caption: "Every action and its keys, as set right now") {
            Card(inset: 16) {
                ForEach(Array(ShortcutGroup.allCases.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { CardDivider().padding(.vertical, 16) }
                    Text(group.title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary).padding(.bottom, 8)
                    VStack(spacing: 10) {
                        ForEach(ShortcutCatalog.actions(in: group)) { action in referenceRow(action) }
                    }
                }
                HStack(spacing: 16) {
                    Text("Change any of them in Shortcuts. Each action can have more than one.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                    Button("Open Shortcuts") { state.page = .shortcuts }.buttonStyle(SecondaryButtonStyle())
                }.padding(.top, 24)
            }
        }
    }

    private func referenceRow(_ action: ShortcutAction) -> some View {
        ShortcutsRowLayout(spacing: 20) {
            RowLabel(title: action.title, subtitle: action.subtitle, emphasized: true)
            let combos = config.combos(for: action.id)
            if combos.isEmpty {
                Text("No shortcut set").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            } else {
                FlowLayout(spacing: 12, lineSpacing: 6) {
                    ForEach(Array(combos.enumerated()), id: \.offset) { _, combo in
                        KeyCapRow(glyphs: combo.glyphs, size: 18)
                    }
                }
            }
        }
    }
}
