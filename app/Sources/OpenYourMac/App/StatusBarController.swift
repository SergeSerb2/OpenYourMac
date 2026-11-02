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
        item.button?.image = Self.statusImage(badged: false)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        state.engine.$state
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
            .store(in: &subscriptions)
        state.$pausedUntil
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
            .store(in: &subscriptions)
        state.updates.$phase
            .combineLatest(state.updates.$hasUnseenUpdate)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
            .store(in: &subscriptions)
        rebuild()
    }

    /// The strip glyph, with a small dot when an update waits for the user.
    private static func statusImage(badged: Bool, note: String = "update available") -> NSImage? {
        let name = AppPaths.appName
        guard let symbol = NSImage(systemSymbolName: "rectangle.3.offgrid", accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: name) else { return nil }
        guard badged else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: symbol.size.width + 4, height: max(symbol.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(x: 0, y: (rect.height - symbol.size.height) / 2)
            symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(name), \(note)"
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === item.menu else { return }
        // The Windows submenu reads this when it opens.
        state.strip.refreshSoon()
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
        let updates = state.updates
        let failed: Bool = { if case .failed = engineState { return true } else { return false } }()
        let badged = failed || updates.hasUnseenUpdate || { if case .readyToInstall = updates.phase { return true } else { return false } }()
        item.button?.image = Self.statusImage(badged: badged, note: failed ? "needs attention" : "update available")

        add(AppPaths.appName, to: menu, enabled: false)
        if let until = state.pausedUntil {
            add("Status: Paused until \(AppState.timeFormatter.string(from: until))", to: menu, enabled: false)
        } else {
            add("Status: \(engineState.label)", to: menu, enabled: false)
        }
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
        if state.pausedUntil != nil {
            add("Resume Now", to: menu, action: #selector(resumeNow))
        } else {
            let pause = add("Pause", to: menu, enabled: engineState.isRunning)
            let pauseMenu = NSMenu(title: "Pause")
            pauseMenu.autoenablesItems = false
            for (title, minutes) in [("For 5 Minutes", 5), ("For 15 Minutes", 15), ("For 30 Minutes", 30), ("For 1 Hour", 60)] {
                add(title, to: pauseMenu, action: #selector(pauseFor(_:))).tag = minutes
            }
            pause.submenu = pauseMenu
        }
        let windows = add("Windows", to: menu, enabled: engineState.isRunning)
        let windowsMenu = NSMenu(title: "Windows")
        windowsMenu.delegate = self
        windows.submenu = windowsMenu
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

        add(updateMenuTitle, to: menu, action: #selector(checkUpdates), enabled: updates.primaryActionEnabled)
        add("Quit \(AppPaths.appName)", to: menu, action: #selector(quit), key: "q")
    }

    /// Fills the Windows submenu with the strip's columns as it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Windows" else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false
        let layouts = state.strip.layouts
        if layouts.allSatisfy({ $0.columns.isEmpty }) {
            add("No windows on the strip", to: menu, enabled: false)
        }
        for layout in layouts where !layout.columns.isEmpty {
            if layouts.count > 1 {
                add(layout.displayName, to: menu, enabled: false)
            }
            for column in layout.columns {
                let names = column.windows.map(\.appName).joined(separator: " + ")
                let title = column.windows.count == 1 && !column.windows[0].title.isEmpty
                    ? "\(names) — \(column.windows[0].title)" : names
                let row = add(String(title.prefix(70)), to: menu, action: #selector(focusColumn(_:)))
                row.representedObject = ColumnTarget(layout: layout, column: column)
                row.state = column.isFocused ? .on : .off
                if let bundleID = column.windows.first?.bundleID {
                    let icon = AppIconCache.icon(for: bundleID).copy() as? NSImage
                    icon?.size = NSSize(width: 16, height: 16)
                    row.image = icon
                }
                row.toolTip = "Column \(column.number)"
            }
        }
        menu.addItem(.separator())
        add("Show Strip Map…", to: menu, action: #selector(showDetails))
    }

    private final class ColumnTarget: NSObject {
        let layout: StripLayout
        let column: StripLayout.Column
        init(layout: StripLayout, column: StripLayout.Column) {
            self.layout = layout
            self.column = column
        }
    }

    @objc private func focusColumn(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ColumnTarget else { return }
        state.strip.focus(target.column, in: target.layout)
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

    private var updateMenuTitle: String {
        switch state.updates.phase {
        case .available(let update): return "Update Available: \(AppPaths.appName) \(update.version)…"
        case .readyToInstall(let update): return "Restart to Install \(update.version)"
        case .installing(let update): return "Installing \(update.version)…"
        default: return "Check for Updates…"
        }
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

    @objc private func stop() { state.stopEngineByUser() }

    @objc private func restart() { permittedStart(restart: true) }

    @objc private func accessibility() { state.permissions.openAccessibilitySettings() }

    @objc private func toggleLogin() { state.loginItem.setEnabled(!state.loginItem.isRegistered) }

    @objc private func loginSettings() { state.loginItem.openSettings() }

    @objc private func checkUpdates() { state.updates.checkForUpdates() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pauseFor(_ sender: NSMenuItem) { state.pause(minutes: sender.tag) }

    @objc private func resumeNow() { state.resumeFromPause() }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? EngineCommand else { return }
        state.perform(command)
    }
}
