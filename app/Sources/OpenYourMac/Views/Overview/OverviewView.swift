import SwiftUI

/// Overview: status, first shortcuts, and quick actions.
/// This page is the style reference for the other pages.
struct OverviewView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var setup: MacSetupChecker
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        PageScaffold(
            title: headline,
            subtitle: subheadline,
            titleDot: engine.state.statusColor,
            accessory: { startStopButton }
        ) {
            HStack(spacing: 10) {
                StatusCard(label: "Window Manager", value: engine.state.label, color: engine.state.statusColor)
                StatusCard(
                    label: "Permission",
                    value: permissions.isTrusted ? "Allowed" : "Missing",
                    color: permissions.isTrusted ? Theme.success : Theme.danger
                )
                StatusCard(
                    label: "Mac Setup",
                    value: setup.allPassing ? "Ready" : "\(setup.failing.count) to fix",
                    color: setup.allPassing ? Theme.success : Theme.warning
                )
            }

            if !permissions.isTrusted {
                FinishSettingUpCard()
            } else if case .failed(let failure) = engine.state {
                EngineFailureCard(failure: failure)
            }

            if !preferences.gettingStartedDismissed {
                PageSection("Getting Started", caption: "The five shortcuts you need. Everything else is in Help.") {
                    GettingStartedCard()
                }
            }

            PageSection("Quick Actions", caption: "Common things, one click away") {
                Card(inset: 14) {
                    HStack(spacing: 8) {
                        QuickActionTile(title: "Restart", subtitle: "Restart the window manager") {
                            if engine.state.isRunning { state.restartEngineFromUI() } else { state.startEngineFromUI() }
                        }
                        QuickActionTile(title: "Settings", subtitle: "Configuration") {
                            state.page = .configuration
                        }
                        QuickActionTile(title: "Shortcuts", subtitle: "Change your keys") {
                            state.page = .shortcuts
                        }
                        QuickActionTile(title: "Permission", subtitle: "Accessibility settings") {
                            permissions.openAccessibilitySettings()
                        }
                    }
                }
            }
        }
        .onAppear { setup.refresh() }
    }

    private var headline: String {
        switch engine.state {
        case .running: return "\(AppPaths.appName) is running"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped: return "\(AppPaths.appName) is stopped"
        case .failed: return "The window manager stopped"
        }
    }

    private var subheadline: String {
        switch engine.state {
        case .running: return "Your windows are on the strip. Use the shortcuts below, or swipe the trackpad."
        case .starting, .stopping: return "One moment."
        case .stopped:
            return permissions.isTrusted
                ? "Windows are left where they are. Click Start to put them on the strip."
                : "\(AppPaths.appName) can't move windows until Accessibility is allowed. You can finish that in Mac Setup."
        case .failed(let failure): return failure.summary
        }
    }

    private var startStopButton: some View {
        Button(engine.state.isRunning ? "Stop" : "Start") {
            engine.state.isRunning ? engine.stop() : state.startEngineFromUI()
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(engine.state.isBusy)
        .keyboardShortcut(.defaultAction)
    }
}

/// The five starter shortcuts plus the swipe hint.
private struct GettingStartedCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Card(padding: EdgeInsets(top: 12, leading: Theme.cardPadding, bottom: 14, trailing: Theme.cardPadding)) {
            VStack(spacing: 9) {
                row("Focus left / right", pair: ("window_focus_west", "window_focus_east"))
                row("Move window left / right", pair: ("window_swap_west", "window_swap_east"))
                row("Center the window", single: "window_center")
                row("Resize (cycle widths)", single: "window_resize")
                row("Float / unfloat", single: "window_manage")
                HStack {
                    Text("Scroll the strip")
                        .font(Theme.Font.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    scrollHint
                }
            }
            CardDivider().padding(.vertical, 12)
            HStack(spacing: 8) {
                Button("All Shortcuts & Help") { state.page = .help }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Mac Setup") { state.page = .macSetup }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Got It") {
                    withAnimation(.easeInOut(duration: 0.2)) { preferences.gettingStartedDismissed = true }
                }
                .buttonStyle(LinkButtonStyle())
                .help("Hide this card. The same list is in Help.")
            }
        }
    }

    private func row(_ title: String, single id: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.Font.rowTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let combo = config.combos(for: id).first {
                KeyCapRow(glyphs: combo.glyphs)
            } else {
                notSet
            }
        }
    }

    /// Shows "⌃ ⌥ ← / →" when both shortcuts share modifiers.
    private func row(_ title: String, pair: (String, String)) -> some View {
        HStack {
            Text(title)
                .font(Theme.Font.rowTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            let a = config.combos(for: pair.0).first
            let b = config.combos(for: pair.1).first
            if let a, let b, a.modifiers == b.modifiers {
                HStack(spacing: 3) {
                    KeyCapRow(glyphs: Array(a.glyphs.dropLast()))
                    KeyCap(glyph: KeyCombo.glyph(forKey: a.key))
                    Text("/").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 2)
                    KeyCap(glyph: KeyCombo.glyph(forKey: b.key))
                }
            } else {
                HStack(spacing: 6) {
                    if let a { KeyCapRow(glyphs: a.glyphs) }
                    Text("/").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    if let b { KeyCapRow(glyphs: b.glyphs) }
                }
            }
        }
    }

    private var notSet: some View {
        Text("Not set").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
    }

    @ViewBuilder private var scrollHint: some View {
        let fingers = config.options.swipeGestureFingers
        HStack(spacing: 6) {
            if config.handEditedKeys([\.swipeGestureFingers, \.scrollModifier]).isEmpty {
                if config.options.scrollModifier != .off {
                    KeyCapRow(glyphs: config.options.scrollModifier.label.map { String($0) })
                    Text("+ scroll").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                if fingers > 0 {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Text(config.options.scrollModifier == .off ? "swipe with \(fingers) fingers" : "or swipe with \(fingers) fingers")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("Gestures are set in the configuration file.")
            }
        }
    }
}

/// Shown while the Accessibility permission is missing.
private struct FinishSettingUpCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var preferences: Preferences
    @State private var confirmRepair = false

    var body: some View {
        PageSection("Finish Setting Up", caption: "\(AppPaths.appName) can't move windows until this is done") {
            Card(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14), fill: Theme.warning.opacity(0.06), stroke: Theme.warning.opacity(0.22)) {
                HStack(alignment: .top, spacing: 12) {
                    CheckGlyph(state: .fail, size: 18)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Allow \(AppPaths.appName) in Accessibility")
                            .font(Theme.Font.rowTitleEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Turn on \(AppPaths.appName) in System Settings › Privacy & Security › Accessibility. It ticks green here by itself.")
                            .font(Theme.Font.rowSubtitle)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Open Accessibility Settings") {
                                permissions.request()
                                permissions.openAccessibilitySettings()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            Button("Mac Setup") { state.page = .macSetup }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.top, 6)
                    }
                }
                CardDivider().padding(.vertical, 12)
                HStack(spacing: 6) {
                    Text("Already switched on in System Settings but still shown as missing?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Repair Permission…") { confirmRepair = true }
                        .buttonStyle(LinkButtonStyle())
                        .font(.system(size: 11.5))
                }
            }
        }
        .alert("Reset \(AppPaths.appName)'s Accessibility permission?", isPresented: $confirmRepair) {
            Button("Reset and Grant Again") { permissions.repair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS sometimes keeps an old permission after an update. This clears it and asks again; turn \(AppPaths.appName) back on in the list.")
        }
    }
}

/// Shown when the engine could not start or keeps stopping.
struct EngineFailureCard: View {
    let failure: EngineFailure
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        Card(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14), fill: Theme.danger.opacity(0.07), stroke: Theme.danger.opacity(0.22)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(failure.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !engine.recentLog.isEmpty, failure.showsLog {
                        ScrollView {
                            Text(engine.recentLog.suffix(8).joined(separator: "\n"))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 110)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    }
                    HStack(spacing: 8) {
                        switch failure {
                        case .accessibilityMissing:
                            Button("Open Accessibility Settings") { permissions.openAccessibilitySettings() }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("Mac Setup") { state.page = .macSetup }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        case .configError:
                            Button("Show Configuration File") { config.revealInFinder() }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("Try Again") { state.startEngineFromUI() }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        default:
                            Button("Try Again") { state.startEngineFromUI() }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("Reveal Engine Log") {
                                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.engineLog])
                            }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

extension EngineFailure {
    var title: String {
        switch self {
        case .accessibilityMissing: return "\(AppPaths.appName) can't move windows until this permission is on"
        case .configError: return "The configuration file has an error"
        case .binaryMissing: return "The window manager is missing"
        case .crashed: return "The window manager stops by itself"
        case .launchFailed: return "The window manager could not start"
        case .alreadyRunning: return "Window manager is already running"
        }
    }

    var summary: String {
        switch self {
        case .accessibilityMissing:
            return "The window manager could not start because \(AppPaths.appName) is not allowed to control windows yet. Turn on \(AppPaths.appName) in System Settings › Privacy & Security › Accessibility."
        case .configError(let message, let line):
            let at = line.map { " (line \($0))" } ?? ""
            return "The window manager could not read your configuration, so it did not start. Fix the file and start again\(at): \(message)"
        case .binaryMissing:
            return "Engine binary is missing. Reinstall \(AppPaths.appName) and try again."
        case .crashed:
            return "\(AppPaths.appName) restarts it automatically after a crash, but it kept stopping. The last log lines are below."
        case .launchFailed(let detail):
            return "Engine operation failed: \(detail)"
        case .alreadyRunning:
            return "Another copy of the window manager is running. Quit it, then start again."
        }
    }

    var showsLog: Bool {
        switch self {
        case .crashed, .configError, .launchFailed: return true
        default: return false
        }
    }
}
