import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var setup: MacSetupChecker
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        GeometryReader { proxy in
            sidebar(compact: proxy.size.height < 650)
        }
        .background {
            if isSnapshot {
                Color(nsColor: .dynamic(light: 0xECEBF2, dark: 0x26252C))
            } else {
                VisualEffectBackground(material: .sidebar)
            }
        }
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                SidebarToggleButton()
            }
            .padding(.top, 9)
            .padding(.trailing, 10)
            .frame(height: 50)

            header
                .padding(.horizontal, 16)
                .padding(.top, compact ? 0 : 6)
                .padding(.bottom, compact ? 12 : 20)

            ForEach(Array(SidebarPage.groups.enumerated()), id: \.offset) { index, group in
                Text(group.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.top, index == 0 ? 0 : (compact ? 8 : 14))
                    .padding(.bottom, 5)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 2) {
                    ForEach(group.pages) { page in
                        SidebarItem(
                            page: page,
                            isSelected: state.page == page,
                            badge: page == .macSetup && !setup.failing.isEmpty ? setup.failing.count : nil,
                            compact: compact
                        ) {
                            state.page = page
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 12)

            SidebarUpdateCard()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            EnginePowerCard()
                .padding(.horizontal, 12)

            Button {
                state.navigate(to: .help, anchor: "about")
            } label: {
                Text("Version \(AppPaths.appVersion) · Free and open source")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("About \(AppPaths.appName)")
            .padding(.top, compact ? 8 : 12)
            .padding(.bottom, compact ? 10 : 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusColor: Color {
        state.pausedUntil == nil ? engine.state.statusColor : Theme.warning
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppPaths.appName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    StatusDot(color: statusColor, size: 6)
                        .background {
                            if engine.state.isRunning {
                                PulseRing(color: engine.state.statusColor)
                            }
                        }
                    Text(state.pausedUntil == nil ? engine.state.sidebarLabel : "Paused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A soft ring that breathes around the running status dot.
private struct PulseRing: View {
    let color: Color
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Circle()
            .stroke(color.opacity(expanded ? 0 : 0.6), lineWidth: 1.5)
            .scaleEffect(expanded ? 2.4 : 1)
            .onAppear {
                guard !reduceMotion, !isSnapshot else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { expanded = true }
            }
            .accessibilityHidden(true)
    }
}

private struct SidebarItem: View {
    let page: SidebarPage
    let isSelected: Bool
    var badge: Int?
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.14)))
                    Image(systemName: page.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Theme.accent)
                }
                .frame(width: 26, height: 26)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Theme.warning))
                        .accessibilityLabel("\(badge) to fix")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, compact ? 3 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.contentBackground) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)))
                    .shadow(color: .black.opacity(isSelected ? 0.10 : 0), radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(page.subtitle) (⌘\(page.shortcutNumber))")
        .accessibilityLabel("\(page.title), \(page.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Window manager on/off switch and restart, at the bottom of the sidebar.
private struct EnginePowerCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Window Manager")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("Window Manager", isOn: Binding(
                get: { engine.state.isRunning || engine.state == .starting },
                set: { on in on ? state.startEngineFromUI() : engine.stop() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(engine.state.isBusy)
            .help(engine.state.isRunning ? "Stop arranging windows" : "Start arranging windows")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.contentBackground.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var detail: String {
        switch engine.state {
        case .running: return "Arranging windows"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped:
            return state.pausedUntil.map { "Paused until \(AppState.timeFormatter.string(from: $0))" } ?? "Off"
        case .failed: return "Needs attention"
        }
    }
}

/// Appears when a new version is waiting. Opens the Updates settings.
private struct SidebarUpdateCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var updates: UpdateChecker
    @State private var hovering = false

    var body: some View {
        if let update = updates.phase.update {
            Button {
                state.navigate(to: .configuration, anchor: "updates")
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isReady ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isReady ? "Restart to Update" : "Update Available")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Version \(update.version)")
                            .font(.system(size: 10.5))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(hovering ? 0.9 : 1))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Show update details")
            .accessibilityLabel(isReady ? "Restart to update to version \(update.version)" : "Update available: version \(update.version)")
        }
    }

    private var isReady: Bool {
        if case .readyToInstall = updates.phase { return true }
        return false
    }
}

extension EngineState {
    var statusColor: Color {
        switch self {
        case .running: return Theme.success
        case .starting, .stopping: return Theme.warning
        case .failed: return Theme.danger
        case .stopped: return Theme.textSecondary
        }
    }

    var sidebarLabel: String {
        switch self {
        case .failed: return "Needs attention"
        default: return label
        }
    }
}

extension AppState {
    /// Start from a button: asks for the permission first if it is missing.
    func startEngineFromUI() {
        permissions.refresh()
        guard permissions.isTrusted else {
            permissions.request()
            toasts.show("\(AppPaths.appName) can't move windows until Accessibility is allowed. You can finish that in Mac Setup.", kind: .warning, duration: 4)
            return
        }
        engine.start()
    }

    func restartEngineFromUI() {
        permissions.refresh()
        guard permissions.isTrusted else {
            permissions.request()
            toasts.show("\(AppPaths.appName) can't move windows until Accessibility is allowed. You can finish that in Mac Setup.", kind: .warning, duration: 4)
            return
        }
        toasts.show("Restarting…", kind: .info, duration: 30)
        engine.restart { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .running:
                self.toasts.show("Window manager restarted", kind: .success)
            case .failed(let failure):
                self.toasts.show(failure.summary, kind: .error, duration: 5)
            default:
                self.toasts.show("Restart cancelled", kind: .info)
            }
        }
    }
}
