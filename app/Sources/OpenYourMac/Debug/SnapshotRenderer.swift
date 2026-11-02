import AppKit
import SwiftUI

/// Snapshot mode makes pages render at full height (no scroll view) and the
/// sidebar use a solid fill, so offscreen PNGs show everything.
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotFixedViewportKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }

    var snapshotFixedViewport: Bool {
        get { self[SnapshotFixedViewportKey.self] }
        set { self[SnapshotFixedViewportKey.self] = newValue }
    }
}

/// `OpenYourMac --snapshot <dir>` renders each page offscreen, in dark and
/// light appearance, to `<dir>/<page>-<appearance>.png`. Nothing is shown on
/// screen and the engine is never started.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL, viewport: CGSize? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let state = AppState.shared
        state.showOnboarding = false
        state.engine.setPreviewState(.running)
        // Let the engine finish checking the config so pages show its result.
        let deadline = Date().addingTimeInterval(5)
        while state.config.isValidating, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let pageFilter = ProcessInfo.processInfo.environment["OYM_SNAPSHOT_PAGES"]?.split(separator: ",").map(String.init)
        let increasedContrast = ProcessInfo.processInfo.environment["OYM_SNAPSHOT_CONTRAST"] == "increased"
        applyUpdatePreview(ProcessInfo.processInfo.environment["OYM_SNAPSHOT_UPDATE"], to: state)
        state.strip.setPreview(sampleStrip())

        for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearanceName == .darkAqua ? "dark" : "light"
            for page in SidebarPage.allCases where pageFilter == nil || pageFilter!.contains(page.rawValue) {
                state.page = page
                render(
                    RootView().withAppEnvironment(state),
                    appearance: appearanceName, viewport: viewport, increasedContrast: increasedContrast,
                    to: outputDirectory.appendingPathComponent("\(page.rawValue)-\(suffix).png")
                )
            }
            if pageFilter?.contains("settingsReference") == true {
                render(
                    PageScaffold(title: "Settings File Reference", subtitle: "Common product settings") {
                        HelpSettingsReference().frame(width: 1000 - Theme.pagePadding * 2)
                    }.background(Theme.contentBackground).withAppEnvironment(state),
                    appearance: appearanceName, viewport: nil, increasedContrast: increasedContrast,
                    to: outputDirectory.appendingPathComponent("settings-reference-\(suffix).png")
                )
            }
            if pageFilter?.contains("ruleEditor") == true {
                for floating in WindowRule.Floating.allCases {
                    var rule = state.config.rules.first(where: { !$0.isHandEdited })
                        ?? WindowRule(id: "example", titleMatch: .any, floating: .automatic, placement: .automatic)
                    rule.floating = floating
                    render(
                        WindowRuleEditorSheet(rule: rule, onClose: {}).withAppEnvironment(state),
                        appearance: appearanceName, viewport: CGSize(width: 560, height: 1100), increasedContrast: increasedContrast,
                        to: outputDirectory.appendingPathComponent("rule-\(floating.rawValue.lowercased())-\(suffix).png")
                    )
                }
            }
            if pageFilter == nil || pageFilter!.contains("onboarding") {
                // Through RootView, exactly as the app shows it over the window,
                // on top of the first page (as on a real first launch).
                state.page = .overview
                state.showOnboarding = true
                defer { state.showOnboarding = false }
                render(
                    RootView().withAppEnvironment(state),
                    appearance: appearanceName, viewport: viewport, increasedContrast: increasedContrast,
                    fixedHeight: 700,
                    to: outputDirectory.appendingPathComponent("onboarding-\(suffix).png")
                )
            }
        }
        print("Snapshots written to \(outputDirectory.path)")
    }

    /// `OYM_SNAPSHOT_UPDATE` shows one update state: checking, current, available,
    /// installing, ready, failed, updated, or updated-permission.
    private static func applyUpdatePreview(_ name: String?, to state: AppState) {
        guard let name else { return }
        let sample = AvailableUpdate(version: "1.1.0", build: "60", size: 19_400_000)
        let checked = Date().addingTimeInterval(-3 * 3600)
        switch name {
        case "checking": state.updates.setPreview(.checking, lastCheck: checked)
        case "current": state.updates.setPreview(.upToDate, lastCheck: checked)
        case "available": state.updates.setPreview(.available(sample), lastCheck: checked)
        case "installing": state.updates.setPreview(.installing(sample), lastCheck: checked)
        case "ready": state.updates.setPreview(.readyToInstall(sample), lastCheck: checked)
        case "failed":
            state.updates.setPreview(.failed("Could not reach the update server. Check your internet connection and try again."), lastCheck: checked)
        case "updated": state.updates.setPreview(.upToDate, lastCheck: Date(), updatedFrom: "1.0.0")
        case "updated-permission":
            state.updates.setPreview(.upToDate, lastCheck: Date(), updatedFrom: "1.0.0")
            state.preferences.onboardingCompleted = true
            state.permissions.setPreview(trusted: false)
            state.engine.setPreviewState(.stopped)
        default: break
        }
    }

    /// A believable strip for the live map: two columns off screen, a stack,
    /// and one floating window.
    private static func sampleStrip() -> [StripLayout] {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func window(_ id: Int, _ bundle: String, _ name: String, x: Double, y: Double = 38, width: Double, height: Double = 936,
                    focused: Bool = false, floating: Bool = false) -> EngineSnapshot.Window {
            EngineSnapshot.Window(
                windowID: id, bundleID: bundle, appName: name, title: name, focused: focused, floating: floating,
                displayID: 1, frame: .init(x: x, y: y, width: width, height: height), visible: true
            )
        }
        let columns: [[EngineSnapshot.Window]] = [
            [window(1, "com.apple.mail", "Mail", x: -1012, width: 1000)],
            [window(2, "com.apple.Safari", "Safari", x: 8, width: 820)],
            [window(3, "com.apple.dt.Xcode", "Xcode", x: 836, width: 668, focused: true)],
            [window(4, "com.apple.Terminal", "Terminal", x: 1512, width: 600, height: 464),
             window(5, "com.apple.Notes", "Notes", x: 1512, y: 510, width: 600, height: 464)],
            [window(6, "com.apple.finder", "Finder", x: 2120, width: 760)],
        ]
        let layout = StripLayout(
            displayID: 1, displayName: "Built-in Display", viewport: screen,
            columns: columns.enumerated().map { index, windows in
                StripLayout.Column(
                    windows: windows,
                    frame: windows.dropFirst().reduce(windows[0].frame!.rect) { $0.union($1.frame!.rect) },
                    number: index + 1
                )
            },
            floating: [window(7, "com.apple.calculator", "Calculator", x: 600, y: 300, width: 230, height: 400, floating: true)],
            workspaceNumber: 1,
            workspaces: [.init(number: 1, windowCount: 7), .init(number: 2, windowCount: 3)],
            isActive: true
        )
        return [layout]
    }

    private static func render<V: View>(
        _ view: V, appearance: NSAppearance.Name, viewport: CGSize?, increasedContrast: Bool,
        fixedHeight: CGFloat? = nil, to url: URL
    ) {
        let width: CGFloat = viewport?.width ?? 1000
        let fixedHeight = viewport?.height ?? fixedHeight
        let resolvedAppearance: NSAppearance.Name = increasedContrast
            ? (appearance == .darkAqua ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : appearance
        let host = NSHostingView(rootView: view
            .environment(\.isSnapshot, true)
            .environment(\.snapshotFixedViewport, viewport != nil))
        host.appearance = NSAppearance(named: resolvedAppearance)
        // Same chrome as the real main window, kept offscreen and never ordered front.
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: fixedHeight ?? 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: resolvedAppearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: fixedHeight ?? 700)
        pump()
        if fixedHeight == nil {
            // Measure, resize, and measure again until the height settles:
            // text wraps differently once the width is final.
            var height: CGFloat = 700
            for _ in 0..<4 {
                let fitting = max(700, min(host.fittingSize.height.rounded(.up), 8000))
                if abs(fitting - height) < 1 { break }
                height = fitting
                window.setContentSize(NSSize(width: width, height: height))
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                pump()
            }
        }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        window.contentView = nil
    }

    /// Lets SwiftUI finish layout and AppKit-backed controls draw.
    private static func pump() {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }
}
