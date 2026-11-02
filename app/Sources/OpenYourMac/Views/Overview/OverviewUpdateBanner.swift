import SwiftUI

/// Overview banner for a waiting update, or for the first launch after one.
struct OverviewUpdateBanner: View {
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        if let update = updates.phase.update {
            banner(
                symbol: isReady ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill",
                title: isReady ? "\(AppPaths.appName) \(update.version) is ready to install" : "\(AppPaths.appName) \(update.version) is available",
                detail: isReady
                    ? "It installs the next time \(AppPaths.appName) quits. Restart now to finish. Your windows stay where they are."
                    : "A signed update is ready to download. Your settings, shortcuts, and rules stay as they are."
            ) {
                UpdateActionButton()
                Button("Release Notes") { NSWorkspace.shared.open(AppPaths.releaseNotesURL) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        } else if let previous = updates.updatedFrom, permissions.isTrusted {
            banner(
                symbol: "sparkles",
                title: "Updated to \(AppPaths.appName) \(AppPaths.appVersion)",
                detail: "You were on \(previous). See what changed in this version."
            ) {
                Button("What's New") { NSWorkspace.shared.open(AppPaths.releaseNotesURL) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Dismiss") {
                    withAnimation(.easeInOut(duration: 0.2)) { updates.dismissWhatsNew() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var isReady: Bool {
        if case .readyToInstall = updates.phase { return true }
        return false
    }

    private func banner<Actions: View>(
        symbol: String, title: String, detail: String, @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        Card(
            padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14),
            fill: Theme.accent.opacity(0.07),
            stroke: Theme.accent.opacity(0.24)
        ) {
            HStack(alignment: .center, spacing: 14) {
                IconDisc(systemImage: symbol, diameter: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Theme.Font.rowTitleEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(Theme.Font.rowSubtitle)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }
                    .fixedSize()
            }
        }
        .transition(.opacity)
    }
}
