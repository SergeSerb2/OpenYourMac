import AppKit
import ApplicationServices
import Combine
import Darwin

/// Checks the macOS settings that affect OpenYourMac and offers fixes.
@MainActor
final class MacSetupChecker: ObservableObject {
    @Published private(set) var checks: [SetupCheck] = []
    private weak var config: ConfigStore?
    private var configSubscription: AnyCancellable?
    private var timer: Timer?
    /// Number of views currently asking for live monitoring.
    private var clients = 0
    private var mainWindowVisible = false
    private var observers: [NSObjectProtocol] = []
    /// Window manager daemons found by the last refresh, for the Quit action.
    private var otherPIDs: [pid_t] = []

    var failing: [SetupCheck] {
        checks.filter { !$0.isRecommendation && ($0.state == .fail || $0.state == .warning) }
    }

    var allPassing: Bool { failing.isEmpty }

    var separateSpacesReady: Bool {
        checks.first { $0.id == "separateSpaces" }?.state == .pass
    }

    var groups: [SetupGroup] {
        SetupGroup.allCases.filter { group in checks.contains { $0.group == group } }
    }

    init() {
        refresh()
        if !AppPaths.isSnapshot {
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                observers.append(observer)
            }
        }
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func configure(config: ConfigStore) {
        self.config = config
        configSubscription = config.$options.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    // MARK: Monitoring

    /// Refreshes every second while at least one client is monitoring.
    func beginMonitoring() {
        clients += 1
        updateMonitoring()
    }

    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard clients > 0, mainWindowVisible, !AppPaths.isSnapshot else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endMonitoring() {
        clients = max(0, clients - 1)
        updateMonitoring()
    }

    // MARK: Actions

    func perform(_ action: SetupAction, for checkID: String) {
        guard !AppPaths.isSnapshot else { return }
        switch action.kind {
        case .openSettings(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .setSwipeFingers(let fingers):
            if [0, 3, 4].contains(fingers) {
                config?.set(\.swipeGestureFingers, fingers)
            }
        case .quitApps(let bundleIDs):
            quitApps(bundleIDs, includingDaemons: checkID == "otherWindowManagers")
        case .automaticFix:
            guard checkID == "rearrangeSpaces" else { return }
            stopRearrangingSpaces()
        }
        refresh()
    }

    private func quitApps(_ bundleIDs: [String], includingDaemons: Bool) {
        for app in NSWorkspace.shared.runningApplications
        where bundleIDs.contains(app.bundleIdentifier ?? "") || (includingDaemons && otherPIDs.contains(app.processIdentifier)) {
            app.terminate()
        }
        // Daemons such as yabai are not NSRunningApplications; ask them to quit with SIGTERM.
        for pid in otherPIDs where includingDaemons {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            } else {
                kill(pid, SIGTERM)
            }
        }
    }

    /// Turns off "Automatically rearrange Spaces" and restarts the Dock to apply it.
    private func stopRearrangingSpaces() {
        let dock = "com.apple.dock" as CFString
        CFPreferencesSetValue("mru-spaces" as CFString, kCFBooleanFalse, dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        Task {
            _ = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"])
            refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: Checks

    func refresh() {
        let fingers: Int? = config?.handEditedOptions.contains("swipe_gesture_fingers") == true
            ? nil : config?.options.effectiveSwipeGestureFingers ?? 4
        let threeFingerSwipe = swipeSetting(fingers: "Three")
        let fourFingerSwipe = swipeSetting(fingers: "Four")
        let otherManagers = runningWindowManagers()
        checks = essentialChecks()
            + trackpadChecks(fingers: fingers, threeFingerSwipe: threeFingerSwipe, fourFingerSwipe: fourFingerSwipe)
            + missionControlChecks(otherManagers: otherManagers)
            + displayChecks()
    }

    private func essentialChecks() -> [SetupCheck] {
        let path = Bundle.main.bundleURL.path
        let userApplications = AppPaths.home.appendingPathComponent("Applications").path + "/"
        let isInApplications = !path.contains("/AppTranslocation/")
            && (path.hasPrefix("/Applications/") || path.hasPrefix(userApplications))
        return [
            Self.check(
                "accessibility", in: .essentials,
                passes: AXIsProcessTrusted(),
                passTitle: "\(AppPaths.appName) can move windows",
                failTitle: "Allow \(AppPaths.appName) in Accessibility",
                passDetail: "Permission granted.",
                failDetail: "macOS requires permission before an app can move your windows.",
                instruction: "Turn on \(AppPaths.appName) in the list.",
                settingPath: "System Settings › Privacy & Security › Accessibility",
                actions: [Self.openSettings("Open Accessibility Settings", pane: "com.apple.preference.security?Privacy_Accessibility")]
            ),
            Self.check(
                "appLocation", in: .essentials,
                passes: isInApplications,
                passTitle: "\(AppPaths.appName) is in Applications",
                failTitle: "Move \(AppPaths.appName) to Applications",
                passDetail: "Installed in Applications.",
                failDetail: "Keep the app in Applications so its permission remains stable after updates.",
                instruction: "Quit the app, move it to Applications, then open it again.",
                actions: [SetupAction(id: "reveal-app", label: "Reveal \(AppPaths.appName)", kind: .reveal(Bundle.main.bundleURL), isPrimary: true)]
            ),
        ]
    }

    /// Swipe settings use 0 (off), 1 (swipe between pages), or 2 (swipe between full-screen apps).
    private func trackpadChecks(fingers: Int?, threeFingerSwipe: Int, fourFingerSwipe: Int) -> [SetupCheck] {
        let trackpadSettings = Self.openSettings("Open Trackpad Settings", pane: "com.apple.Trackpad-Settings.extension")
        guard let fingers else {
            return [SetupCheck(id: "desktopSwipe", group: .trackpad, title: "Swipe settings are hand-edited",
                               detail: "The app cannot read the finger count. Check the configuration file before comparing macOS gestures.",
                               state: .unknown, actions: [trackpadSettings])]
        }
        let conflicts: Bool
        switch fingers {
        case 3: conflicts = threeFingerSwipe == 2
        case 4: conflicts = threeFingerSwipe == 2 || fourFingerSwipe == 2
        default: conflicts = false
        }
        let instruction = fingers == 3
            ? "Set “Swipe between full-screen applications” to four fingers or Off."
            : "Set “Swipe between full-screen applications” to Off. This disables desktop swipes with both three and four fingers. To keep desktop swipes, set macOS to four fingers and \(AppPaths.appName) to three. You can also turn off the app's swipe and scroll while holding ⌃⌥."
        var alternatives = [trackpadSettings]
        if fingers == 4, threeFingerSwipe != 2 {
            alternatives.append(Self.swipeFingersAction(3))
        }
        if fingers == 3, threeFingerSwipe != 2, fourFingerSwipe != 2 {
            alternatives.append(Self.swipeFingersAction(4))
        }
        alternatives.append(Self.swipeFingersAction(0))

        var checks = [
            Self.check(
                "desktopSwipe", in: .trackpad,
                passes: !conflicts,
                passTitle: fingers == 0 ? "Trackpad swipe is off in \(AppPaths.appName)" : "\(fingers)-finger swipes go to \(AppPaths.appName)",
                failTitle: fingers == 3 ? "Move full-screen app swipes off 3 fingers" : "macOS also switches desktops with 4 fingers",
                passDetail: fingers == 0 ? "Nothing can clash with it." : "macOS doesn't switch desktops with \(fingers) fingers.",
                failDetail: "macOS uses the same gesture to change desktops, which interrupts the strip swipe.",
                instruction: instruction,
                settingPath: "System Settings › Trackpad › More Gestures",
                actions: alternatives
            ),
        ]
        guard fingers == 3 else { return checks }

        let threeFingerDrag = trackpadValues("ThreeFingerDrag", globalKey: "threeFingerDragGesture").contains { $0 != 0 }
        checks.append(Self.check(
            "pageSwipe", in: .trackpad,
            passes: threeFingerSwipe != 1,
            passTitle: "3-finger swipes don't change pages",
            failTitle: "Move “Swipe between pages” off 3 fingers",
            passDetail: "Page swipes use two fingers.",
            failDetail: "A strip swipe can also go back or forward in a browser or Finder.",
            instruction: "Choose two fingers for “Swipe between pages”.",
            settingPath: "System Settings › Trackpad › More Gestures",
            actions: [trackpadSettings, Self.swipeFingersAction(4)]
        ))
        checks.append(Self.check(
            "threeFingerDrag", in: .trackpad,
            passes: !threeFingerDrag,
            passTitle: "Three Finger Drag is off",
            failTitle: "Turn off Three Finger Drag",
            passDetail: "Three Finger Drag is off.",
            failDetail: "This gesture drags windows instead of scrolling the strip.",
            instruction: "Select a dragging style other than Three Finger Drag.",
            settingPath: "System Settings › Accessibility › Pointer Control › Trackpad Options",
            actions: [
                Self.openSettings("Open Pointer Control Settings", pane: "com.apple.Accessibility-Settings.extension?PointerControl"),
                Self.swipeFingersAction(4),
            ]
        ))
        return checks
    }

    private func missionControlChecks(otherManagers: (names: [String], ids: [String])) -> [SetupCheck] {
        let desktopSettings = Self.openSettings("Open Desktop & Dock Settings", pane: "com.apple.Desktop-Settings.extension")
        let names = otherManagers.names.joined(separator: ", ")
        var checks = [
            Self.check(
                "otherWindowManagers", in: .missionControl,
                passes: otherManagers.names.isEmpty,
                passTitle: "No other window manager is running",
                failTitle: "Quit \(names) (\(otherManagers.names.count == 1 ? "it also moves" : "they also move") windows)",
                passDetail: "Nothing else is moving your windows.",
                failDetail: "Two window managers can move the same windows and use the same shortcuts.",
                instruction: "Also turn off its launch-at-login option if needed.",
                actions: [SetupAction(id: "quit-managers", label: "Quit \(names)", kind: .quitApps(otherManagers.ids), isPrimary: true)]
            ),
            Self.check(
                "rearrangeSpaces", in: .missionControl,
                passes: !preferenceBool("mru-spaces", in: "com.apple.dock", fallback: true),
                passTitle: "Desktops stay in order",
                failTitle: "Stop macOS reordering your desktops",
                passDetail: "macOS won't reorder your desktops.",
                failDetail: "Automatic reordering can move a strip to a different desktop.",
                instruction: "Turn off “Automatically rearrange Spaces based on most recent use”.",
                settingPath: "System Settings › Desktop & Dock › Mission Control",
                actions: [
                    SetupAction(id: "fix-spaces", label: "Turn It Off for Me", kind: .automaticFix, isPrimary: true),
                    Self.openSettings("Open Desktop & Dock Settings", pane: "com.apple.Desktop-Settings.extension", isPrimary: false),
                ]
            ),
            Self.check(
                "stageManager", in: .missionControl,
                passes: !preferenceBool("GloballyEnabled", in: "com.apple.WindowManager"),
                passTitle: "Stage Manager is off",
                failTitle: "Turn off Stage Manager",
                passDetail: "Stage Manager is off.",
                failDetail: "Stage Manager also arranges windows and can interrupt the strip.",
                instruction: "Turn off Stage Manager.",
                settingPath: "System Settings › Desktop & Dock",
                actions: [desktopSettings]
            ),
        ]
        if #available(macOS 15, *) {
            let tilingSettings = [
                ("EnableTilingByEdgeDrag", "Drag windows to screen edges to tile"),
                ("EnableTopTilingByEdgeDrag", "Drag windows to menu bar to fill screen"),
                ("EnableTilingOptionAccelerator", "Hold ⌥ key while dragging windows to tile"),
            ]
            let enabled = tilingSettings
                .filter { preferenceBool($0.0, in: "com.apple.WindowManager", fallback: true) }
                .map(\.1)
            checks.append(Self.check(
                "tiling", in: .missionControl,
                passes: enabled.isEmpty,
                passTitle: "macOS window tiling is off",
                failTitle: "Turn off macOS window tiling",
                passDetail: "macOS tiling won't interfere.",
                failDetail: "macOS can resize a window at a screen edge while \(AppPaths.appName) is arranging it.",
                instruction: "Turn off: " + enabled.joined(separator: "; ") + ".",
                settingPath: "System Settings › Desktop & Dock › Windows",
                actions: [desktopSettings]
            ))
        }
        return checks
    }

    /// Separate Spaces is required even with one display. Arrangement is optional.
    private func displayChecks() -> [SetupCheck] {
        let ignored = config?.options.ignoredDisplays.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        let screens = NSScreen.screens.filter { screen in
            guard let id = screen.displayID, let uuid = DisplayStore.identity(for: id) else { return true }
            return !ignored.contains(uuid.lowercased())
        }
        let effective = NSScreen.screensHaveSeparateSpaces
        let saved = !preferenceBool("spans-displays", in: "com.apple.spaces")
        let pendingLogout = effective != saved
        var checks = [
            Self.check(
                "separateSpaces", in: .displays,
                passes: effective && saved,
                passTitle: "Each display has its own desktops",
                failTitle: pendingLogout && saved ? "Log out to apply separate Spaces" : "Turn on “Displays have separate Spaces”",
                passDetail: "Every display has its own strip.",
                failDetail: pendingLogout ? "The saved setting and this session differ. The change needs a logout." : "The window manager requires separate Spaces, even with one display.",
                instruction: saved ? "Log out and back in to apply the setting." : "Turn it on, then log out and back in.",
                settingPath: "System Settings › Desktop & Dock › Mission Control",
                needsLogout: true,
                actions: [Self.openSettings("Open Desktop & Dock Settings", pane: "com.apple.Desktop-Settings.extension")]
            ),
        ]
        if screens.count > 1 {
            checks.append(Self.check(
                "displayArrangement", in: .displays,
                passes: !Self.hasSideBySideDisplays(screens),
                passTitle: "Displays are stacked",
                failTitle: "Consider stacking your displays",
                passDetail: "Windows slide fully off both edges.",
                failDetail: "A vertical display arrangement lets windows scroll beyond either edge. Side by side also works.",
                settingPath: "System Settings › Displays › Arrange",
                isRecommendation: true,
                actions: [Self.openSettings("Open Displays Settings", pane: "com.apple.Displays-Settings.extension")]
            ))
        }
        return checks
    }

    /// True when two screens overlap vertically and touch at a left or right edge.
    private static func hasSideBySideDisplays(_ screens: [NSScreen]) -> Bool {
        for (index, screen) in screens.enumerated() {
            for other in screens.dropFirst(index + 1) {
                let a = screen.frame
                let b = other.frame
                let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                let touchesHorizontally = abs(a.maxX - b.minX) <= 1 || abs(b.maxX - a.minX) <= 1
                if verticalOverlap > 1 && touchesHorizontally {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Check building

    /// A passing check shows the pass texts only; a failing one adds the instruction and actions.
    private static func check(
        _ id: String,
        in group: SetupGroup,
        passes: Bool,
        passTitle: String,
        failTitle: String,
        passDetail: String,
        failDetail: String,
        instruction: String? = nil,
        settingPath: String? = nil,
        isRecommendation: Bool = false,
        needsLogout: Bool = false,
        actions: [SetupAction] = []
    ) -> SetupCheck {
        SetupCheck(
            id: id,
            group: group,
            title: passes ? passTitle : failTitle,
            detail: passes ? passDetail : failDetail,
            state: passes ? .pass : isRecommendation ? .warning : .fail,
            instruction: passes ? nil : instruction,
            settingPath: passes ? nil : settingPath,
            isRecommendation: isRecommendation,
            needsLogout: !passes && needsLogout,
            actions: passes ? [] : actions
        )
    }

    private static func openSettings(_ label: String, pane: String, isPrimary: Bool = true) -> SetupAction {
        SetupAction(id: pane, label: label, kind: .openSettings(URL(string: "x-apple.systempreferences:" + pane)!), isPrimary: isPrimary)
    }

    private static func swipeFingersAction(_ fingers: Int) -> SetupAction {
        SetupAction(
            id: "fingers-\(fingers)",
            label: fingers == 0 ? "Turn Off Trackpad Swipe" : "Use \(fingers) Fingers in \(AppPaths.appName)",
            kind: .setSwipeFingers(fingers)
        )
    }

    // MARK: Preferences

    /// Normal domains use current user / any host. Gesture globals use current host.
    static func preference(_ key: String, domain: String? = nil) -> Any? {
        let app = domain.map { $0 as CFString } ?? kCFPreferencesAnyApplication
        let host = domain == nil ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, host)
        return CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, host)
    }

    private func preferenceBool(_ key: String, in domain: String, fallback: Bool = false) -> Bool {
        (Self.preference(key, domain: domain) as? NSNumber)?.boolValue ?? fallback
    }

    /// A trackpad setting from the built-in and Bluetooth trackpad domains, then the current-host global.
    private func trackpadValues(_ suffix: String, globalKey: String) -> [Int] {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let domainValues = domains.compactMap { (Self.preference("Trackpad" + suffix, domain: $0) as? NSNumber)?.intValue }
        let globalValue = (Self.preference("com.apple.trackpad." + globalKey) as? NSNumber)?.intValue
        return domainValues + [globalValue].compactMap { $0 }
    }

    /// The strongest horizontal swipe setting for `fingers` ("Three" or "Four") across all sources.
    private func swipeSetting(fingers: String) -> Int {
        let values = trackpadValues(fingers + "FingerHorizSwipeGesture", globalKey: fingers.lowercased() + "FingerHorizSwipeGesture")
        if values.contains(2) { return 2 }
        if values.contains(1) { return 1 }
        return 0
    }

    // MARK: Other window managers

    private static let knownApps = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.crowdcafe.windowmagnet": "Magnet",
        "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace",
        "com.manytricks.Moom": "Moom",
        "com.MrKai77.Loop": "Loop",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.mizage.Divvy": "Divvy",
        "com.mizage.direct.Divvy": "Divvy",
        "com.divisiblebyzero.Spectacle": "Spectacle",
        "com.irradiatedsoftware.SizeUp": "SizeUp",
        "com.withmarko.OneMenu": "OneMenu",
        "com.lwouis.alt-tab-macos.Swish": "Swish",
        "co.highlyopinionated.swish": "Swish",
        "com.ahmedgagan.paneru": "ChainYourMac",
    ]

    /// Process names of window manager daemons, mapped to display names.
    private static let knownDaemons = [
        "yabai": "yabai",
        "aerospace": "AeroSpace",
        "paneru": "Paneru",
    ]

    /// Finds running window managers, and records their PIDs for the Quit action.
    private func runningWindowManagers() -> (names: [String], ids: [String]) {
        var names = Set<String>()
        var bundleIDs: [String] = []
        var pids: [pid_t] = []
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = Self.knownApps[id] {
                names.insert(name)
                bundleIDs.append(id)
                pids.append(app.processIdentifier)
            }
        }
        // CLI daemons may not appear in NSWorkspace's application list.
        for process in Self.allProcesses() {
            if let label = Self.knownDaemons[process.name] {
                names.insert(label)
                pids.append(process.pid)
            }
        }
        otherPIDs = pids
        return (names.sorted(), bundleIDs)
    }

    /// Every process with its lower-cased short name, read with sysctl.
    private static func allProcesses() -> [(name: String, pid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Leave room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = processes.count * stride
        let status = processes.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return [] }
        return processes.prefix(size / stride).map { process in
            var process = process
            let name = withUnsafeBytes(of: &process.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (name.lowercased(), process.kp_proc.p_pid)
        }
    }
}
