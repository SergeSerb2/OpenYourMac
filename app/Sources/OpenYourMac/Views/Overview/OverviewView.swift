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
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        PageScaffold(
            title: headline,
            subtitle: subheadline,
            titleDot: engine.state.statusColor,
            accessory: { headerButtons }
        ) {
            if !permissions.isTrusted {
                FinishSettingUpCard()
            } else if case .failed(let failure) = engine.state {
                EngineFailureCard(failure: failure)
            }

            OverviewUpdateBanner()

            PageSection("Your Strip", caption: "A live map of your windows. The dashed frame is your screen. Click a column to focus it.") {
                Card(inset: 14) {
                    LiveStripView()
                }
            }

            HStack(spacing: 10) {
                HealthTile(
                    symbol: permissions.isTrusted ? "hand.raised.fill" : "hand.raised.slash.fill",
                    label: "Accessibility",
                    value: permissions.isTrusted ? "Allowed" : "Missing",
                    color: permissions.isTrusted ? Theme.success : Theme.danger
                ) { state.navigate(to: .macSetup) }
                HealthTile(
                    symbol: "checklist",
                    label: "Mac Setup",
                    value: setup.allPassing ? "All set" : "\(setup.failing.count) to fix",
                    color: setup.allPassing ? Theme.success : Theme.warning
                ) { state.navigate(to: .macSetup) }
                HealthTile(
                    symbol: "arrow.triangle.2.circlepath",
                    label: "Updates",
                    value: updates.phase.update.map { "\($0.version) available" } ?? "Version \(AppPaths.appVersion)",
                    color: updates.phase.update == nil ? Theme.success : Theme.accent
                ) { state.navigate(to: .configuration, anchor: "updates") }
            }

            if !preferences.gettingStartedDismissed {
                PageSection("Getting Started", caption: "The five shortcuts you need. Everything else is in Help.") {
                    GettingStartedCard()
                }
            }

            PageSection("Quick Actions", caption: "Common things, one click away") {
                Card(inset: 14) {
                    HStack(spacing: 8) {
                        QuickActionTile(title: "Show Strip", subtitle: "Open the minimap", systemImage: "rectangle.split.3x1") {
                            state.perform(.showStrip)
                        }
                        QuickActionTile(title: "Settings", subtitle: "Gaps, widths, rules", systemImage: "slider.horizontal.3") {
                            state.page = .configuration
                        }
                        QuickActionTile(title: "Shortcuts", subtitle: "Change your keys", systemImage: "command") {
                            state.page = .shortcuts
                        }
                        QuickActionTile(title: "Edit Config", subtitle: "Open the TOML file", systemImage: "doc.text") {
                            config.openInEditor()
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
        case .stopped:
            if let until = state.pausedUntil { return "Paused until \(AppState.timeFormatter.string(from: until))" }
            return "\(AppPaths.appName) is stopped"
        case .failed: return "The window manager stopped"
        }
    }

    private var subheadline: String {
        switch engine.state {
        case .running: return "Your windows are on the strip. Use the shortcuts below, or swipe the trackpad."
        case .starting, .stopping: return "One moment."
        case .stopped where state.pausedUntil != nil:
            return "Windows stay where they are. The window manager starts again by itself, or click Resume."
        case .stopped:
            return permissions.isTrusted
                ? "Windows are left where they are. Click Start to put them on the strip."
                : "\(AppPaths.appName) can't move windows until Accessibility is allowed. You can finish that in Mac Setup."
        case .failed(let failure): return failure.summary
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
            if engine.state.isRunning {
                Button {
                    state.restartEngineFromUI()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(engine.state.isBusy)
                Button {
                    state.stopEngineByUser()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(engine.state.isBusy)
            } else if state.pausedUntil != nil {
                Button {
                    state.resumeFromPause()
                } label: {
                    Label("Resume Now", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    state.startEngineFromUI()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(engine.state.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A small status tile that opens the page where you can act on it.
private struct HealthTile: View {
    let symbol: String
    let label: String
    let value: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconDisc(systemImage: symbol, diameter: 30, tint: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(hovering ? 1 : 0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(hovering ? Theme.tileFillHover : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(label): \(value)")
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
    @EnvironmentObject private var updates: UpdateChecker
    @State private var confirmRepair = false

    var body: some View {
        if let previous = updates.updatedFrom, preferences.onboardingCompleted {
            AfterUpdatePermissionCard(previous: previous)
        } else {
            firstSetup
        }
    }

    private var firstSetup: some View {
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

/// After an update, macOS can treat the new build as a different app. The old
/// Accessibility entry then stays switched on but no longer applies.
private struct AfterUpdatePermissionCard: View {
    let previous: String
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        PageSection("Allow \(AppPaths.appName) Again", caption: "Updated from \(previous) to \(AppPaths.appVersion)") {
            Card(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14), fill: Theme.warning.opacity(0.06), stroke: Theme.warning.opacity(0.22)) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.rotation")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.warning)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("macOS needs your permission again after the update")
                            .font(Theme.Font.rowTitleEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                        Text("This build is not signed by an Apple developer ID, so macOS sees the new version as a new app. The old switch in Accessibility no longer applies. Reset it, then turn \(AppPaths.appName) on again.\(preferences.startEngineAutomatically ? " The window manager starts by itself when you are done." : "")")
                            .font(Theme.Font.rowSubtitle)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Reset and Allow Again") { permissions.repair() }
                                .buttonStyle(PrimaryButtonStyle())
                            Button("Open Accessibility Settings") { permissions.openAccessibilitySettings() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.top, 6)
                    }
                }
            }
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
