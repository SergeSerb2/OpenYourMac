import AppKit
import SwiftUI
import Combine

enum SidebarPage: String, CaseIterable, Identifiable {
    case overview, macSetup, actions, configuration, shortcuts, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .macSetup: return "Mac Setup"
        case .actions: return "Actions"
        case .configuration: return "Configuration"
        case .shortcuts: return "Shortcuts"
        case .help: return "Help"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Status & Quick Controls"
        case .macSetup: return "macOS Settings Check"
        case .actions: return "Window Operations"
        case .configuration: return "Settings & Rules"
        case .shortcuts: return "Keyboard Bindings"
        case .help: return "Guide & Support"
        }
    }
}

/// Root object. Owns every service and is injected into the view tree, with
/// each service also injected as its own environment object.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let preferences = Preferences()
    let config = ConfigStore()
    let engine = EngineController()
    let permissions = PermissionManager()
    let setup = MacSetupChecker()
    let displays = DisplayStore()
    let loginItem = LoginItemManager()
    let cli = CLIInstaller()
    let updates = UpdateChecker()
    let toasts = ToastCenter()
    let frontmost = FrontmostAppTracker()

    @Published var page: SidebarPage = .overview
    @Published var showOnboarding = false
    @Published var sidebarVisible = true
    @Published var isMainWindowVisible = false
    /// Set by Help links to scroll a page to a section after switching.
    @Published var pendingAnchor: String?

    /// Called by the window controller to show the main window.
    var openMainWindow: () -> Void = {}

    private var subscriptions: Set<AnyCancellable> = []

    init() {
        engine.configure(config: config, preferences: preferences, permissions: permissions)
        displays.configure(config: config)
        setup.configure(config: config)
        $isMainWindowVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setup.setMainWindowVisible(visible)
                self?.engine.setMainWindowVisible(visible)
            }
            .store(in: &subscriptions)
        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self, !trusted, self.engine.state.isRunning || self.engine.state == .starting else { return }
                self.engine.stop(failure: .accessibilityMissing)
            }
            .store(in: &subscriptions)
        // The config file is the source of truth for detailed logging.
        config.$options
            .sink { [weak self] options in
                guard let self, self.preferences.detailedLogging != options.detailedLogging else { return }
                self.preferences.detailedLogging = options.detailedLogging
            }
            .store(in: &subscriptions)
        showOnboarding = !preferences.onboardingCompleted
        if !permissions.isTrusted {
            permissions.waitForGrant { [weak self] in self?.autoStartIfReady() }
        }
    }

    func autoStartIfReady() {
        setup.refresh()
        guard !AppPaths.isSnapshot, preferences.startEngineAutomatically,
              preferences.onboardingCompleted, permissions.isTrusted,
              setup.separateSpacesReady, engine.state == .stopped else { return }
        engine.start()
    }

    func navigate(to page: SidebarPage, anchor: String? = nil) {
        self.page = page
        pendingAnchor = anchor
        openMainWindow()
    }

    /// Runs a window action from the UI. Shows a toast when it cannot run.
    func perform(_ command: EngineCommand) {
        guard engine.state.isRunning else {
            toasts.show("The window manager is stopped. Start it to use these actions.", kind: .warning)
            return
        }
        Task {
            let result = await engine.send(command)
            if case .failure(let error) = result {
                toasts.show(error.message, kind: .error)
            }
        }
    }

    func completeOnboarding() {
        preferences.onboardingCompleted = true
        withAnimation(.easeInOut(duration: 0.3)) { showOnboarding = false }
    }
}

extension View {
    /// Injects the app state and every service as environment objects.
    func withAppEnvironment(_ state: AppState) -> some View {
        environmentObject(state)
            .environmentObject(state.preferences)
            .environmentObject(state.config)
            .environmentObject(state.engine)
            .environmentObject(state.permissions)
            .environmentObject(state.setup)
            .environmentObject(state.displays)
            .environmentObject(state.loginItem)
            .environmentObject(state.cli)
            .environmentObject(state.updates)
            .environmentObject(state.toasts)
            .environmentObject(state.frontmost)
    }
}
