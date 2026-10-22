import AppKit
import SwiftUI

struct HelpIntegrations: View {
    @EnvironmentObject private var cli: CLIInstaller
    @EnvironmentObject private var toasts: ToastCenter
    @State private var errorMessage: String?
    @State private var showPathHint = false
    @State private var confirmsReplacement = false

    var body: some View {
        PageSection("Integrations", caption: "Control \(AppPaths.appName) from Raycast, Alfred, Shortcuts or the terminal") {
            Card(inset: 16) {
                urlScheme
                CardDivider().padding(.vertical, 16)
                raycast
                CardDivider().padding(.vertical, 16)
                commandLine
            }
        }
        .onAppear { cli.refresh() }
        .alert("Integration could not be completed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Replace the existing link?", isPresented: $confirmsReplacement) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { installCLI(replaceExisting: true) }
        } message: {
            Text("The link at ~/.local/bin/openyourmac points to another tool or app. Replace it with this copy of \(AppPaths.appName)?")
        }
    }

    private var urlScheme: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("URL Scheme", icon: "link", text: "Use an openyourmac:// URL to run a window action. Open it in the background with open -g to keep this app's window out of your way.")
            CopyableCommand(command: "open -g \"openyourmac://window/focus/east\"")
            DisclosureRow("Show All URLs") {
                VStack(spacing: 6) {
                    ForEach(allURLs, id: \.self) { CopyableCommand(command: $0) }
                }
            }
        }
    }

    private var raycast: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Raycast Script Commands", icon: "command", text: "Export the scripts to a new folder, then add that folder in Raycast › Settings › Extensions › Script Commands › Add Directory. Existing folders stay unchanged. The actions appear in the \(AppPaths.appName) package.")
            Button("Export Raycast Scripts…", action: exportRaycast).buttonStyle(SecondaryButtonStyle())
        }
    }

    private var commandLine: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Command Line", icon: "terminal", text: "Run window actions from a shell, for example: openyourmac window focus east. Install a link at ~/.local/bin/openyourmac that points to the command inside this app.")
            FlowLayout(spacing: 12, lineSpacing: 8) {
                Button(installTitle) {
                    cli.refresh()
                    if case .pointsElsewhere = cli.status { confirmsReplacement = true }
                    else { installCLI() }
                }.buttonStyle(SecondaryButtonStyle())
                HStack(spacing: 6) {
                    StatusDot(color: statusColor)
                    Text(statusLabel).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            if showPathHint {
                InfoNote(text: "If your shell cannot find the command, add ~/.local/bin to PATH. For zsh, add this line to ~/.zshrc, then open a new terminal:")
                CopyableCommand(command: "export PATH=\"$HOME/.local/bin:$PATH\"")
            }
        }
    }

    private func heading(_ title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.accent)
                .frame(width: 32).padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var allURLs: [String] {
        (EngineCommand.urlAllowList.map { "\(AppPaths.urlScheme)://" + $0.arguments.joined(separator: "/") }
         + ["start", "stop", "restart", "toggle"].map { "\(AppPaths.urlScheme)://\($0)" }).sorted()
    }

    private var installTitle: String {
        switch cli.status {
        case .installed, .pointsElsewhere: return "Reinstall openyourmac CLI"
        case .notInstalled, .blocked: return "Install openyourmac CLI"
        }
    }

    private var statusLabel: String {
        switch cli.status {
        case .installed: return "Installed"
        case .notInstalled: return "Not installed"
        case .pointsElsewhere: return "Points at another copy of the app"
        case .blocked: return "A different file already exists at \(AppPaths.abbreviated(AppPaths.cliLink))"
        }
    }

    private var statusColor: Color {
        switch cli.status {
        case .installed: return Theme.success
        case .notInstalled: return Theme.textTertiary
        case .pointsElsewhere, .blocked: return Theme.warning
        }
    }

    private func installCLI(replaceExisting: Bool = false) {
        do {
            try cli.install(replaceExisting: replaceExisting)
            cli.refresh()
            guard cli.status == .installed else {
                errorMessage = "The command-line link could not be verified. \(statusLabel)."
                return
            }
            toasts.show("Installed at ~/.local/bin/openyourmac. Open a new terminal and run openyourmac --help.", kind: .success, duration: 5)
            let bin = AppPaths.home.appendingPathComponent(".local/bin").standardizedFileURL.path
            let paths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map(String.init)
            showPathHint = !paths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == bin }
        } catch { errorMessage = error.localizedDescription }
    }

    private func exportRaycast() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to put the “\(AppPaths.appName) Raycast” folder."
        panel.prompt = "Export Here"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                let folder = try RaycastExporter.export(to: destination)
                toasts.show("Raycast scripts exported.", kind: .success)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
