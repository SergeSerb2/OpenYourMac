import AppKit
import SwiftUI
import Combine
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState.shared
    private var windowController: MainWindowController!
    private var statusBar: StatusBarController!
    private var router: URLRouter!
    private var subscriptions: Set<AnyCancellable> = []
    private var terminationSource: DispatchSourceSignal?
    private var terminating = false

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(state.preferences.showInDock ? .regular : .accessory)
        // Handle openyourmac:// URLs, including the one that launched us.
        router = URLRouter(state: state)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        windowController = MainWindowController(state: state)
        state.openMainWindow = { [weak self] in self?.windowController.show() }
        statusBar = StatusBarController(state: state)
        installTerminationHandler()
        observePreferences()

        let launchedAtLogin = Self.wasLaunchedAsLoginItem()
        let launchedForURL = router.handledLaunchURL
        let launchedQuietly = launchedAtLogin || launchedForURL
        if state.preferences.showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        if !launchedQuietly, state.preferences.showWindowOnLaunch || state.showOnboarding {
            windowController.show()
        }

        // A lifecycle URL owns its start/stop decision. Do not counteract a stop URL.
        if !router.handledLifecycleLaunchURL {
            autoStartIfReady()
        }
        router.finishLaunching()
        if !launchedQuietly {
            introduceMacSetupIfNeeded()
        }
        state.updates.start()
    }

    /// Handles a normal SIGTERM through the same bounded quit path as ⌘Q.
    private func installTerminationHandler() {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    private func observePreferences() {
        state.preferences.$showInDock
            .dropFirst()
            .sink { [weak self] show in
                DispatchQueue.main.async { self?.windowController.applyDockVisibility(show) }
            }
            .store(in: &subscriptions)
        state.preferences.$onboardingCompleted
            .dropFirst()
            .sink { [weak self] completed in
                guard completed else { return }
                DispatchQueue.main.async { self?.autoStartIfReady() }
            }
            .store(in: &subscriptions)
    }

    /// Once after onboarding, opens Mac Setup if a macOS setting needs changing.
    private func introduceMacSetupIfNeeded() {
        guard state.preferences.onboardingCompleted, !state.preferences.macSetupIntroduced else { return }
        state.preferences.macSetupIntroduced = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.state.setup.refresh()
            if !self.state.setup.allPassing {
                self.state.navigate(to: .macSetup)
            }
        }
    }

    private func autoStartIfReady() {
        guard !terminating else { return }
        state.autoStartIfReady()
    }

    /// True when macOS started the app as a login item.
    private static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: Running

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.show()
        return true
    }

    func applicationDidHide(_ notification: Notification) {
        windowController.refreshVisibility()
        if !state.preferences.showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidUnhide(_ notification: Notification) {
        windowController.applyDockVisibility(state.preferences.showInDock)
        windowController.refreshVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            if case .failure(let error) = await state.config.flushForTermination() {
                NSLog("Could not save configuration before quitting: %@", error.localizedDescription)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        terminationSource?.cancel()
        state.engine.stopForTermination()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            router.handle(url)
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        router.handle(url)
    }

    // MARK: Help menu actions

    @objc fileprivate func showHelp(_ sender: Any?) {
        state.navigate(to: .help)
    }

    @objc fileprivate func revealEngineLog(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.engineLog])
    }
}

/// The main window: a fixed-chrome NSWindow hosting the SwiftUI root view.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        if !state.preferences.showInDock {
            NSApp.setActivationPolicy(.regular)
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshVisibility()
    }

    /// Shows the Dock icon when the preference asks for it or the window is open.
    func applyDockVisibility(_ show: Bool) {
        NSApp.setActivationPolicy(show || (window?.isVisible == true && !NSApp.isHidden) ? .regular : .accessory)
    }

    /// Closing only hides the window, so its state survives.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        refreshVisibility()
        applyDockVisibility(state.preferences.showInDock)
        return false
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { refreshVisibility() }

    func windowDidMiniaturize(_ notification: Notification) { refreshVisibility() }

    func windowDidDeminiaturize(_ notification: Notification) { refreshVisibility() }

    func windowWillClose(_ notification: Notification) { state.isMainWindowVisible = false }

    func refreshVisibility() {
        state.isMainWindowVisible = window.map {
            $0.isVisible && !$0.isMiniaturized && !NSApp.isHidden && $0.occlusionState.contains(.visible)
        } ?? false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppPaths.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RootView().withAppEnvironment(state))
        window.setFrameAutosaveName("OpenYourMacMainWindow")
        if !state.preferences.windowFrameSaved {
            window.center()
            state.preferences.windowFrameSaved = true
        }
        return window
    }
}

/// Minimal main menu so standard shortcuts (⌘Q, ⌘W, copy/paste) work.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(makeAppMenu()))
        main.addItem(submenuItem(makeEditMenu()))
        let windowMenu = makeWindowMenu()
        main.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu
        let helpMenu = makeHelpMenu()
        main.addItem(submenuItem(helpMenu))
        NSApp.helpMenu = helpMenu
        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeAppMenu() -> NSMenu {
        let name = AppPaths.appName
        let menu = NSMenu()
        menu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return menu
    }

    private static func makeHelpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        let help = menu.addItem(withTitle: "\(AppPaths.appName) Help", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "?")
        help.target = NSApp.delegate
        let revealLog = menu.addItem(withTitle: "Reveal Engine Log", action: #selector(AppDelegate.revealEngineLog(_:)), keyEquivalent: "")
        revealLog.target = NSApp.delegate
        return menu
    }
}
