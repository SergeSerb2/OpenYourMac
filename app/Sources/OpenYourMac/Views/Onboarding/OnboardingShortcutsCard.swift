import SwiftUI

struct OnboardingShortcutsCard: View {
    @EnvironmentObject private var config: ConfigStore
    var stripLesson = false
    @State private var settingsPage: SidebarPage?

    var body: some View {
        Card(inset: 16) {
            VStack(spacing: 12) {
                if stripLesson {
                    row("Focus left", commands: [.focus(.west)])
                    row("Focus right", commands: [.focus(.east)])
                    row("Send to next display", commands: [.nextDisplay])
                } else {
                    row("Focus left / right", commands: [.focus(.west), .focus(.east)])
                    row("Move window left / right", commands: [.swap(.west), .swap(.east)])
                    row("Center the window", commands: [.center])
                    row("Resize (cycle widths)", commands: [.resize])
                    row("Float / unfloat", commands: [.manage])
                }
                CardDivider()
                HStack {
                    Text("Scroll the strip")
                        .font(Theme.Font.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    scrollHint
                }
            }
        }
        .sheet(item: $settingsPage) { page in
            OnboardingSettingsSheet(page: page)
        }
    }

    private func row(_ title: String, commands: [EngineCommand]) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.Font.rowTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                    if index > 0 { Text("/").foregroundStyle(Theme.textSecondary) }
                    if let combo = config.combos(for: command.bindingName).first {
                        KeyCapRow(glyphs: combo.glyphs)
                    } else {
                        Text("Not set").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if commands.contains(where: { config.combos(for: $0.bindingName).isEmpty }) {
                Button("Set Shortcuts…") { settingsPage = .shortcuts }
                    .buttonStyle(LinkButtonStyle())
            }
        }
    }

    @ViewBuilder private var scrollHint: some View {
        let fingers = config.options.swipeGestureFingers
        HStack(spacing: 5) {
            if config.handEditedKeys([\.swipeGestureFingers, \.scrollModifier]).isEmpty {
                if config.options.scrollModifier != .off {
                    KeyCapRow(glyphs: config.options.scrollModifier.label.map(String.init))
                    Text("+ scroll")
                }
                if fingers > 0 {
                    Text(config.options.scrollModifier == .off ? "\(fingers)-finger swipe" : "or \(fingers)-finger swipe")
                }
                if fingers == 0, config.options.scrollModifier == .off {
                    Text("Off")
                    Button("Configure Gestures…") { settingsPage = .configuration }
                        .buttonStyle(LinkButtonStyle())
                }
            } else {
                Text("Gestures are set in the configuration file.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }
}

private struct OnboardingSettingsSheet: View {
    let page: SidebarPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(page.title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if page == .shortcuts { ShortcutsView() }
            else { ConfigurationView() }
        }
        .frame(width: 900, height: 650)
        .background(Theme.contentBackground)
    }
}
