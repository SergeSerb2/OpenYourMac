import AppKit
import SwiftUI

struct ConfigurationFooter: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var toasts: ToastCenter
    @State private var confirmingReset = false

    var body: some View {
        HStack(spacing: 12) {
            Button("Reveal Config File") { config.revealInFinder() }
                .buttonStyle(SecondaryButtonStyle())
                .help("Show the settings file in Finder to edit it by hand")
            Menu {
                Button("Open in Text Editor") { config.openInEditor() }
                Button("Reload from Disk") { config.reloadFromDisk() }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config.fileURL.path, forType: .string)
                    toasts.show("Configuration path copied", kind: .success)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More configuration file actions")
            Spacer()
            Button("Reset to Defaults…") { confirmingReset = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .alert("Reset the configuration to defaults?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset to Defaults", role: .destructive) { Task { await reset() } }
        } message: {
            Text("This replaces all settings, shortcuts and window rules with the defaults. Your current file is kept beside it as a dated backup.")
        }
    }

    private func reset() async {
        do {
            if let backup = try await config.resetToDefaults() {
                toasts.show("Defaults restored. Previous file saved as \(backup.lastPathComponent).", kind: .success)
            } else {
                toasts.show("Configuration reset to defaults", kind: .success)
            }
        } catch {
            toasts.show("Could not reset the configuration: \(error.localizedDescription)", kind: .error)
        }
    }
}
