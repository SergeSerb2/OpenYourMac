import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        GeometryReader { proxy in
            sidebar(compact: proxy.size.height < 650)
        }
        .background {
            if isSnapshot {
                Color(nsColor: .dynamic(light: 0xE8E6E6, dark: 0x2B2A2A))
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
                .padding(.top, compact ? 8 : 19)

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.top, compact ? 8 : 12)
                .padding(.bottom, compact ? 8 : 12)

            VStack(spacing: 3) {
                ForEach(SidebarPage.allCases) { page in
                    SidebarItem(page: page, isSelected: state.page == page, compact: compact) {
                        state.page = page
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            OpenSourceCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            EngineControlTiles()
                .padding(.horizontal, 16)

            Text("\(AppPaths.appName) \(AppPaths.appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, compact ? 8 : 14)
                .padding(.bottom, compact ? 10 : 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppPaths.appName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 5) {
                StatusDot(color: engine.state.statusColor, size: 7)
                Text(engine.state.sidebarLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(engine.state.statusColor)
            }
        }
    }
}

private struct SidebarItem: View {
    let page: SidebarPage
    let isSelected: Bool
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.82))
                    Text(page.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 20)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, compact ? 5 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.contentBackground) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.16) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(page.title), \(page.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Bottom card that replaces a license badge: OpenYourMac is free and open source.
private struct OpenSourceCard: View {
    @EnvironmentObject private var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.navigate(to: .help, anchor: "about")
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open Source · MIT")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Free for every Mac")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(hovering ? 0.16 : 0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("About OpenYourMac")
    }
}

/// Start/Stop and Restart tiles at the bottom of the sidebar.
private struct EngineControlTiles: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        HStack(spacing: 8) {
            tile(
                title: engine.state.isRunning ? "Stop" : "Start",
                systemImage: engine.state.isRunning ? "stop.fill" : "play.fill"
            ) {
                engine.state.isRunning ? engine.stop() : state.startEngineFromUI()
            }
            tile(title: "Restart", systemImage: "arrow.clockwise") {
                state.restartEngineFromUI()
            }
            .disabled(!engine.state.isRunning)
        }
        .disabled(engine.state.isBusy)
    }

    private func tile(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.contentBackground.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
