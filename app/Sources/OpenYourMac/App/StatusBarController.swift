import AppKit
import Combine

/// The menu bar icon and its menu. The menu is rebuilt when the engine state
/// changes and each time it opens.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let item: NSStatusItem
    private var subscriptions: Set<AnyCancellable> = []

    /// Window actions offered in the Actions submenu, in separated groups.
    private static let actionGroups: [[(title: String, command: EngineCommand)]] = [
        [
            ("Focus Left", .focus(.west)),
            ("Focus Right", .focus(.east)),
            ("Focus Up", .focus(.north)),
            ("Focus Down", .focus(.south)),
            ("Focus First", .focus(.first)),
            ("Focus Last", .focus(.last)),
        ],
        [
            ("Move Window Left", .swap(.west)),
            ("Move Window Right", .swap(.east)),
            ("Move Window Up", .swap(.north)),
            ("Move Window Down", .swap(.south)),
            ("Move Window to First", .swap(.first)),
            ("Move Window to Last", .swap(.last)),
        ],
        [
            ("Center Window", .center),
            ("Resize Window", .resize),
            ("Full Width", .fullWidth),
            ("Wider", .wider),
            ("Narrower", .narrower),
            ("Taller", .taller),
            ("Shorter", .shorter),
            ("Equal Heights", .equalize),
        ],
        [
            ("Stack Left", .stack),
            ("Unstack", .unstack),
            ("Stack Right", .consumeEast),
            ("Unstack to the Left", .expelWest),
            ("Tabs", .tabbed),
        ],
        [
            ("Float / Unfloat", .manage),
            ("Next Display", .nextDisplay),
        ],
        [
            ("Print State", .printState),
            ("Quit Window Manager", .quit),
        ],
    ]

    init(state: AppState) {
        self.state = state
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let image = NSImage(systemSymbolName: "rectangle.3.offgrid", accessibilityDescription: AppPaths.appName)
            ?? NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: AppPaths.appName)
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        state.engine.$state
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
            .store(in: &subscriptions)
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        state.setup.refresh()
        state.loginItem.refresh()
        rebuild()
    }

    // MARK: Menu

    private func rebuild() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false
        let engineState = state.engine.state
        item.button?.appearsDisabled = !engineState.isRunning

        add(AppPaths.appName, to: menu, enabled: false)
        add("Status: \(engineState.label)", to: menu, enabled: false)
        if case .failed(let failure) = engineState {
            add("\(failureTitle(failure)) — Show Details…", to: menu, action: #selector(showDetails))
        }
        let failingCount = state.setup.failing.count
        if failingCount > 0 {
            add("\(failingCount) macOS \(failingCount == 1 ? "Setting Needs" : "Settings Need") Changing", to: menu, action: #selector(showSetup))
        }
        menu.addItem(.separator())

        add("Open \(AppPaths.appName)", to: menu, action: #selector(openWindow), key: "o")
        add("Start", to: menu, action: #selector(start), key: "s", enabled: !engineState.isBusy)
        add("Stop", to: menu, action: #selector(stop), key: "t")
        add("Restart", to: menu, action: #selector(restart), key: "r", enabled: !engineState.isBusy)
        add("Actions", to: menu).submenu = makeActionsMenu()
        menu.addItem(.separator())

        add("Settings", to: menu, action: #selector(showSettings))
        let revealItem = add("Reveal Config File in Finder", to: menu, action: #selector(revealConfig))
        revealItem.isAlternate = true
        revealItem.keyEquivalentModifierMask = [.option]
        add("Mac Setup", to: menu, action: #selector(showSetup))
        add("Accessibility Settings", to: menu, action: #selector(accessibility))
        let loginTitle = state.loginItem.requiresApproval ? "Launch at Login — Requires Approval" : "Launch at Login"
        add(loginTitle, to: menu, action: #selector(toggleLogin)).state = state.loginItem.requiresApproval ? .mixed : state.loginItem.isEnabled ? .on : .off
        if state.loginItem.requiresApproval {
            add("Open Login Items Settings…", to: menu, action: #selector(loginSettings))
        }
        menu.addItem(.separator())

        add("Check for Updates…", to: menu, action: #selector(checkUpdates), enabled: !state.updates.isChecking)
        add("Quit \(AppPaths.appName)", to: menu, action: #selector(quit), key: "q")
    }

    private func makeActionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Actions")
        menu.autoenablesItems = false
        for (index, group) in Self.actionGroups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for (title, command) in group {
                add(title, to: menu, action: #selector(performAction(_:))).representedObject = command
            }
        }
        return menu
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
        row.target = self
        row.isEnabled = enabled
        menu.addItem(row)
        return row
    }

    private func failureTitle(_ failure: EngineFailure) -> String {
        switch failure {
        case .accessibilityMissing: return "Accessibility permission is missing"
        case .configError: return "The configuration file has an error"
        case .binaryMissing: return "Engine binary is missing"
        case .alreadyRunning: return "Another window manager instance is running"
        case .launchFailed: return "The window manager could not start"
        case .crashed: return "The window manager stopped"
        }
    }

    // MARK: Actions

    /// Starts only when allowed; otherwise shows what is missing.
    private func permittedStart(restart: Bool = false) {
        state.permissions.refresh()
        guard state.permissions.isTrusted else {
            state.navigate(to: .macSetup)
            return
        }
        guard state.preferences.onboardingCompleted else {
            state.showOnboarding = true
            state.openMainWindow()
            return
        }
        if restart {
            state.engine.restart()
        } else {
            state.engine.start()
        }
    }

    @objc private func openWindow() { state.openMainWindow() }

    @objc private func showDetails() { state.navigate(to: .overview) }

    @objc private func showSetup() { state.navigate(to: .macSetup) }

    @objc private func showSettings() { state.navigate(to: .configuration) }

    @objc private func revealConfig() { state.config.revealInFinder() }

    @objc private func start() { permittedStart() }

    @objc private func stop() { state.engine.stop() }

    @objc private func restart() { permittedStart(restart: true) }

    @objc private func accessibility() { state.permissions.openAccessibilitySettings() }

    @objc private func toggleLogin() { state.loginItem.setEnabled(!state.loginItem.isRegistered) }

    @objc private func loginSettings() { state.loginItem.openSettings() }

    @objc private func checkUpdates() { state.updates.checkNow(userInitiated: true) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? EngineCommand else { return }
        state.perform(command)
    }
}
