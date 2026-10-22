import AppKit
import SwiftUI

/// Window content: sidebar + selected page, with onboarding and toasts on top.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if state.sidebarVisible {
                    SidebarView()
                        .frame(width: Theme.sidebarWidth)
                        .transition(.move(edge: .leading))
                }
                PageContainer()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.contentBackground)
                    .overlay(alignment: .topLeading) {
                        if !state.sidebarVisible {
                            SidebarToggleButton()
                                .padding(.leading, 84)
                                .padding(.top, 9)
                        }
                    }
            }

            if state.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = toasts.current {
                ToastView(message: message)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// Switches between pages.
struct PageContainer: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.page {
            case .overview: OverviewView()
            case .macSetup: MacSetupView()
            case .actions: ActionsView()
            case .configuration: ConfigurationView()
            case .shortcuts: ShortcutsView()
            case .help: HelpView()
            }
        }
        .id(state.page)
    }
}

/// Round button that shows or hides the sidebar.
struct SidebarToggleButton: View {
    @EnvironmentObject private var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { state.sidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.07)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}

/// Behind-window vibrancy for the sidebar.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
