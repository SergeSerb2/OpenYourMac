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
        state.updates.recordLaunch()
        let relaunch = UpdateRelaunch.consume()
        state.updates.prepareForRelaunch = { [weak self] in self?.recordStateForUpdateRelaunch() }

        let launchedAtLogin = Self.wasLaunchedAsLoginItem()
        let launchedForURL = router.handledLaunchURL
        // After an update relaunch, keep the window as the user left it.
        let launchedQuietly = launchedAtLogin || launchedForURL || (relaunch.map { !$0.showWindow } ?? false)
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
            let restore = relaunch?.engineWasRunning == true
            autoStartIfReady(restoringRunningEngine: restore)
            if restore {
                // The update may need the permission again; start once it is back.
                state.permissions.waitForGrant { [weak self] in self?.autoStartIfReady(restoringRunningEngine: true) }
            }
        }
        router.finishLaunching()
        if !launchedQuietly {
            introduceMacSetupIfNeeded()
        }
        if let from = state.updates.updatedFrom {
            announceUpdate(from: from)
        }
        state.updates.start()
    }

    /// Sparkle is about to quit and relaunch the app with the new version.
    private func recordStateForUpdateRelaunch() {
        UpdateRelaunch(
            engineWasRunning: state.engine.state.isRunning || state.engine.state == .starting,
            showWindow: state.isMainWindowVisible
        ).save()
    }

    /// The first launch of a new version. An ad-hoc-signed update can lose the
    /// Accessibility permission, so say so plainly instead of failing quietly.
    private func announceUpdate(from previous: String) {
        state.permissions.refresh()
        if state.preferences.onboardingCompleted, !state.permissions.isTrusted {
            state.navigate(to: .overview)
            return
        }
        if state.isMainWindowVisible {
            state.toasts.show("Updated to \(AppPaths.appName) \(AppPaths.appVersion)", kind: .success, duration: 4)
        }
    }

    /// Handles a normal SIGTERM through the same bounded quit path as ⌘Q.
    private func installTerminationHandler() {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Terminate from the run loop, not inside this main-queue block, so the
        // save before quitting can run.
        source.setEventHandler {
            RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
        }
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
        // Sparkle's windows belong to this app. Show the Dock icon while they are
        // open so a menu bar app's update window does not get lost.
        state.updates.$isPresentingUpdateUI
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] presenting in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.windowController.applyDockVisibility(self.state.preferences.showInDock)
                    if presenting { NSApp.activate(ignoringOtherApps: true) }
                }
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

    private func autoStartIfReady(restoringRunningEngine: Bool = false) {
        guard !terminating else { return }
        state.autoStartIfReady(restoringRunningEngine: restoringRunningEngine)
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
        windowController.applyDockVisibility(state.preferences.showInDock)
    }

    func applicationDidUnhide(_ notification: Notification) {
        windowController.applyDockVisibility(state.preferences.showInDock)
        windowController.refreshVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        // Nothing to save: quit now. This is the usual case, and it does not
        // depend on the main queue, which a caller may be blocking.
        guard state.config.hasUnsavedWork else { return .terminateNow }
        let reply = TerminationReply()
        Task {
            if case .failure(let error) = await state.config.flushForTermination() {
                NSLog("Could not save configuration before quitting: %@", error.localizedDescription)
            }
            reply.send()
        }
        // A terminate request made inside a main-queue block (a signal handler,
        // an XPC reply) stops Swift tasks from running until it returns. AppKit
        // still services run loop blocks while it waits, so this reply always
        // arrives and quitting cannot hang.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4) { reply.send() }
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

    @objc fileprivate func goToPage(_ sender: NSMenuItem) {
        guard SidebarPage.allCases.indices.contains(sender.tag) else { return }
        state.navigate(to: SidebarPage.allCases[sender.tag])
    }

    @objc fileprivate func showHelp(_ sender: Any?) {
        state.navigate(to: .help)
    }

    @objc fileprivate func revealEngineLog(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.engineLog])
    }
}

/// Replies once to a delayed termination, through the main run loop.
private final class TerminationReply: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false

    func send() {
        lock.lock()
        defer { lock.unlock() }
        guard !sent else { return }
        sent = true
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        CFRunLoopWakeUp(main)
    }
}

/// What to restore after Sparkle relaunches the app with a new version.
/// Stored for one launch only.
struct UpdateRelaunch {
    var engineWasRunning: Bool
    var showWindow: Bool

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(engineWasRunning, forKey: UpdateChecker.Key.relaunchRestoreEngine)
        defaults.set(showWindow, forKey: UpdateChecker.Key.relaunchShowWindow)
    }

    /// Reads and clears the saved state.
    static func consume() -> UpdateRelaunch? {
        guard !AppPaths.isSnapshot else { return nil }
        let defaults = UserDefaults.standard
        guard let engine = defaults.object(forKey: UpdateChecker.Key.relaunchRestoreEngine) as? Bool else { return nil }
        let show = defaults.bool(forKey: UpdateChecker.Key.relaunchShowWindow)
        defaults.removeObject(forKey: UpdateChecker.Key.relaunchRestoreEngine)
        defaults.removeObject(forKey: UpdateChecker.Key.relaunchShowWindow)
        return UpdateRelaunch(engineWasRunning: engine, showWindow: show)
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
        let windowOpen = window?.isVisible == true && !NSApp.isHidden
        NSApp.setActivationPolicy(show || windowOpen || state.updates.isPresentingUpdateUI ? .regular : .accessory)
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
        main.addItem(submenuItem(makeGoMenu()))
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

    /// ⌘1…⌘6 open each page, in sidebar order.
    private static func makeGoMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        for (index, page) in SidebarPage.allCases.enumerated() {
            let item = menu.addItem(withTitle: page.title, action: #selector(AppDelegate.goToPage(_:)), keyEquivalent: "\(page.shortcutNumber)")
            item.tag = index
            item.target = NSApp.delegate
        }
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
