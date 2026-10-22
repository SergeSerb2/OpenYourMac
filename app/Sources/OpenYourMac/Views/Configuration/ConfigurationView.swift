import SwiftUI

struct ConfigurationView: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var setup: MacSetupChecker
    @EnvironmentObject private var displays: DisplayStore
    @EnvironmentObject private var loginItem: LoginItemManager

    var body: some View {
        PageScaffold(
            title: "Configuration",
            subtitle: "Customize how \(AppPaths.appName) manages your windows. Changes save and apply as you make them; other settings in your file stay untouched."
        ) {
            ConfigurationDiagnostics()
            if !config.optionOverrides.isEmpty {
                Card(inset: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Settings controlled by legacy keys").font(Theme.Font.rowTitleEmphasis)
                        Text("The controls show the effective values. When you change one, confirm an update to its overriding key.")
                            .font(Theme.Font.rowSubtitle)
                        ForEach(config.optionOverrides) { override in
                            Text(override.summary).font(Theme.Font.mono).textSelection(.enabled)
                        }
                    }
                }
            }
            ConfigurationGeneralSection()
            ConfigurationDisplaysSection()
            ConfigurationLayoutSection()
            PresetWidthsEditor()
            ConfigurationAppearanceSection()
            ConfigurationGesturesSection()
            ConfigurationBehaviorSection()
            ConfigurationRulesSection()
            ConfigurationFooter()
        }
        .alert(item: $config.pendingOverrideEdit) { request in
            Alert(title: Text("Update the overriding setting?"),
                  message: Text("\(request.override.summary) controls this setting. Apply \(request.value.token) by updating that override? Other settings stay as they are."),
                  primaryButton: .default(Text("Update Setting")) { config.confirmOverrideEdit(request) },
                  secondaryButton: .cancel())
        }
        .onAppear {
            displays.refresh()
            loginItem.refresh()
            setup.refresh()
            setup.beginMonitoring()
        }
        .onDisappear {
            setup.endMonitoring()
            config.flushPendingOptions()
        }
        .onChange(of: config.options.swipeGestureFingers) { _ in setup.refresh() }
    }
}

struct ConfigurationErrorCard: View {
    let error: ConfigError

    var body: some View {
        Card(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14), fill: Theme.danger.opacity(0.07), stroke: Theme.danger.opacity(0.22)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 5) {
                    Text("The configuration file has an error")
                        .font(Theme.Font.rowTitleEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Text(error.message)
                        .font(Theme.Font.rowSubtitle)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let line = error.line {
                        Text("Line \(line)")
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
        }
    }
}

/// Replaces controls whose values the lossless editor cannot read safely.
struct ConfigurationFileOnlyRow: View {
    let keys: [String]
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand-edited, edit in the file").font(Theme.Font.rowTitleEmphasis)
            Text(keys.joined(separator: ", ")).font(Theme.Font.mono).textSelection(.enabled)
            Text("The engine reads these entries. The app keeps their original text and cannot show or edit their values here.")
                .font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open in editor") { config.openInEditor() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(.vertical, 8)
    }
}

private struct ConfigurationFileOnlyModifier: ViewModifier {
    let paths: [PartialKeyPath<ConfigOptions>]
    @EnvironmentObject private var config: ConfigStore

    func body(content: Content) -> some View {
        let keys = config.handEditedKeys(paths)
        if keys.isEmpty { content }
        else { Card(inset: 16) { ConfigurationFileOnlyRow(keys: keys) } }
    }
}

extension View {
    func configOptions(_ paths: [PartialKeyPath<ConfigOptions>]) -> some View {
        modifier(ConfigurationFileOnlyModifier(paths: paths))
    }
}

struct ConfigurationInlineMessage: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.rowSubtitle)
    }
}

struct ConfigurationDiagnostics: View {
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        if let error = config.lastError { ConfigurationErrorCard(error: error) }
        if config.isValidating { InfoNote(text: "Checking the configuration with the engine…") }
        ForEach(Array((config.warnings + config.engineBindingWarnings).enumerated()), id: \.offset) { _, warning in
            ConfigurationInlineMessage(text: warning.localizedDescription, tint: Theme.warning)
        }
    }
}
