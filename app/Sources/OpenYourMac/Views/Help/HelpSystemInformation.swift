import AppKit
import SwiftUI

struct HelpSystemInformation: View {
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        PageSection("System Information", caption: "Details about your installation") {
            Card(inset: 16) {
                VStack(spacing: 0) {
                    info("App Location", Bundle.main.bundlePath)
                    CardDivider()
                    info("Version", "\(AppPaths.appVersion) (\(AppPaths.appBuild))")
                    CardDivider()
                    info("Window Manager Engine", engine.engineVersion)
                    CardDivider()
                    info("Engine Log", AppPaths.abbreviated(AppPaths.engineLog))
                    CardDivider()
                    info("Config File", AppPaths.abbreviated(config.fileURL))
                }
                HStack(spacing: 10) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }.buttonStyle(SecondaryButtonStyle())
                    Button("Reveal Engine Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.engineLog])
                    }.buttonStyle(SecondaryButtonStyle())
                }.padding(.top, 12)
                CardDivider().padding(.top, 16)
                SettingToggleRow(title: "Detailed logging", subtitle: "For support: records window decisions, moves, resizing and focus changes, including window titles. Turn it off when you finish.", isOn: $preferences.detailedLogging)
            }
        }
        .onChange(of: preferences.detailedLogging) { engine.setDetailedLogging($0) }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 9)
    }
}
