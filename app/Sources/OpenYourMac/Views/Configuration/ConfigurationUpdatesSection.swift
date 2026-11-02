import SwiftUI

/// Version, update status, and the update preferences, in one card.
struct ConfigurationUpdatesSection: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        PageSection("Updates", caption: "Signed updates from \(AppPaths.appName). Sparkle checks each download before it installs.") {
            Card {
                UpdateStatusHeader()
                    .padding(.vertical, 14)
                CardDivider()
                SettingToggleRow(
                    title: "Check for Updates Automatically",
                    subtitle: "Look for a new version once a day, in the background",
                    isOn: $updates.automaticallyChecksForUpdates
                )
                CardDivider()
                SettingToggleRow(
                    title: "Download and Install Automatically",
                    subtitle: updates.automaticallyChecksForUpdates
                        ? "Get new versions in the background. They install when \(AppPaths.appName) quits, or when you restart it from here."
                        : "Turn on automatic checks to use this",
                    isOn: $updates.automaticallyDownloadsUpdates,
                    disabled: !updates.automaticallyChecksForUpdates
                )
                CardDivider()
                HStack(spacing: 14) {
                    Button("Release Notes") { NSWorkspace.shared.open(AppPaths.releaseNotesURL) }
                        .buttonStyle(LinkButtonStyle())
                        .font(.system(size: 12))
                    Spacer()
                    InfoNote(text: "Updates keep your settings, shortcuts, and rules.", systemImage: "lock.shield")
                }
                .padding(.vertical, 11)
            }
        }
    }
}

/// App icon, version, live status line, and one action button.
struct UpdateStatusHeader: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMark(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(AppPaths.appName) \(AppPaths.appVersion)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Build \(AppPaths.appBuild)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.tileFill))
                }
                UpdateStatusLine()
            }
            Spacer(minLength: 12)
            UpdateActionButton()
        }
    }
}

/// One line that says what the updater is doing, with a matching glyph.
struct UpdateStatusLine: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            glyph
            Text(text)
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(color == Theme.textSecondary ? Theme.textSecondary : color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var glyph: some View {
        if case .checking = updates.phase {
            ProgressView().controlSize(.mini).frame(width: 12, height: 10)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch updates.phase {
        case .idle: return "clock"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.seal.fill"
        case .available: return "arrow.down.circle.fill"
        case .installing: return "arrow.down.circle"
        case .readyToInstall: return "arrow.clockwise.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch updates.phase {
        case .upToDate: return Theme.success
        case .available, .installing, .readyToInstall: return Theme.accent
        case .failed: return Theme.warning
        default: return Theme.textSecondary
        }
    }

    private var text: String {
        switch updates.phase {
        case .idle:
            return updates.lastUpdateCheck.map { "Last checked \(Self.relative($0))" } ?? "Not checked yet"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            let checked = updates.lastUpdateCheck.map { " · Checked \(Self.relative($0))" } ?? ""
            return "You have the latest version\(checked)"
        case .available(let update):
            let size = update.sizeLabel.map { " · \($0)" } ?? ""
            return "Version \(update.version) is available\(size)"
        case .installing(let update):
            return "Getting version \(update.version) ready…"
        case .readyToInstall(let update):
            return "Version \(update.version) is ready. It installs when \(AppPaths.appName) quits."
        case .failed(let message):
            return message
        }
    }

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// "Check Now", "Install 1.0.2…", or "Restart to Update", depending on the state.
struct UpdateActionButton: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        let prominent = updates.phase.update != nil
        Group {
            if prominent {
                Button(title) { updates.checkForUpdates() }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button(title) { updates.checkForUpdates() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .disabled(!updates.primaryActionEnabled)
        .opacity(updates.primaryActionEnabled ? 1 : 0.45)
        .fixedSize()
    }

    private var title: String {
        switch updates.phase {
        case .idle, .upToDate, .failed: return "Check Now"
        default: return updates.primaryActionTitle
        }
    }
}
