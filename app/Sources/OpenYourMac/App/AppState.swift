import AppKit
import SwiftUI
import Combine

enum SidebarPage: String, CaseIterable, Identifiable {
    case overview, actions, shortcuts, configuration, macSetup, help

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

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.3.offgrid"
        case .macSetup: return "checklist"
        case .actions: return "bolt.fill"
        case .configuration: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .help: return "questionmark"
        }
    }

    /// Names accepted by `openyourmac://open/<page>`.
    init?(urlName: String) {
        switch urlName.lowercased() {
        case "overview", "home": self = .overview
        case "actions": self = .actions
        case "shortcuts", "keys": self = .shortcuts
        case "configuration", "settings", "preferences": self = .configuration
        case "macsetup", "mac-setup", "setup": self = .macSetup
        case "help": self = .help
        default: return nil
        }
    }

    /// ⌘1…⌘6 in the Go menu.
    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// Sidebar order and headings.
    static let groups: [(title: String, pages: [SidebarPage])] = [
        ("Windows", [.overview, .actions, .shortcuts]),
        ("Setup", [.configuration, .macSetup, .help]),
    ]

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
    let strip = StripMonitor()

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
        strip.configure(engine: engine)
        setup.configure(config: config)
        $isMainWindowVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setup.setMainWindowVisible(visible)
                self?.engine.setMainWindowVisible(visible)
                self?.strip.setWindowVisible(visible)
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

    /// Starts the engine when everything it needs is ready. After an update
    /// relaunch, a running engine is restored even if automatic start is off.
    func autoStartIfReady(restoringRunningEngine: Bool = false) {
        setup.refresh()
        guard !AppPaths.isSnapshot, preferences.startEngineAutomatically || restoringRunningEngine,
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
            .environmentObject(state.strip)
    }
}
