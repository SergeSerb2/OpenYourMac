import SwiftUI

struct ConfigurationGeneralSection: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        PageSection("General", caption: "Startup and updates — these apply immediately") {
            Card {
                LoginItemSettingRow()
                if let error = loginItem.lastError {
                    ConfigurationInlineMessage(text: error, tint: Theme.danger)
                        .padding(.bottom, 12)
                }
                CardDivider()
                SettingToggleRow(
                    title: "Start Window Manager Automatically",
                    subtitle: "Start managing windows as soon as \(AppPaths.appName) opens",
                    isOn: $preferences.startEngineAutomatically
                )
                CardDivider()
                SettingToggleRow(
                    title: "Show This Window When \(AppPaths.appName) Opens",
                    subtitle: "When launched at login, \(AppPaths.appName) always starts quietly in the menu bar",
                    isOn: $preferences.showWindowOnLaunch
                )
                CardDivider()
                SettingToggleRow(
                    title: "Show in Dock",
                    subtitle: "When off, \(AppPaths.appName) stays in the menu bar; it appears in the Dock while this window is open",
                    isOn: $preferences.showInDock
                )
                CardDivider()
                SettingToggleRow(
                    title: "Automatically Check for Updates",
                    subtitle: lastChecked,
                    isOn: $updates.automaticallyChecksForUpdates
                )
                CardDivider()
                SettingToggleRow(
                    title: "Automatically Download and Install Updates",
                    subtitle: "Download signed updates in the background and install them when the app quits",
                    isOn: $updates.automaticallyDownloadsUpdates
                )
                .disabled(!updates.automaticallyChecksForUpdates)
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!updates.canCheckForUpdates)
                    .opacity(updates.canCheckForUpdates ? 1 : 0.45)
                    .padding(.bottom, 10)
            }
        }
    }

    private var lastChecked: String {
        guard let date = updates.lastUpdateCheck else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

struct ConfigurationDisplaysSection: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var displays: DisplayStore

    var body: some View {
        PageSection("Displays", caption: "Choose which displays \(AppPaths.appName) tiles. Windows on a switched-off display stay where you put them.") {
            Card {
                DividedRows(data: displays.displays) { display in
                    HStack(spacing: 12) {
                        Image(systemName: "display")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 26)
                        SettingToggleRow(title: display.name, subtitle: display.summary, isOn: managed(display.id))
                            .accessibilityLabel("Manage windows on \(display.name)")
                            .help("Manage windows on this display")
                    }
                }
                ForEach(disconnectedIDs, id: \.self) { id in
                    CardDivider()
                    SettingToggleRow(
                        title: "Disconnected display",
                        subtitle: "Switched off. It stays off when you reconnect it.",
                        isOn: managed(id)
                    )
                    .accessibilityLabel("Manage windows on disconnected display \(id)")
                }
                if displays.displays.isEmpty && disconnectedIDs.isEmpty {
                    InfoNote(text: "No displays are connected.", systemImage: "display")
                        .padding(.vertical, 12)
                }
                InfoNote(text: "Drag a window onto a display that is switched off to take it out of the strip; drag it back to tile it again.")
                    .padding(.bottom, 12)
                if !displays.displays.isEmpty && displays.displays.allSatisfy({ !displays.isManaged($0) }) {
                    ConfigurationInlineMessage(text: "Every display is switched off, so \(AppPaths.appName) isn't arranging any windows right now.", tint: Theme.warning)
                        .padding(.bottom, 12)
                }
            }
            .configOptions([\.ignoredDisplays])
        }
    }

    private var disconnectedIDs: [String] {
        config.options.ignoredDisplays.filter { id in !displays.displays.contains { DisplayStore.entry(id, matches: $0.id) } }
    }

    private func managed(_ id: String) -> Binding<Bool> {
        Binding(get: { displays.isManaged(id) }, set: { displays.setManaged(id, $0) })
    }
}
