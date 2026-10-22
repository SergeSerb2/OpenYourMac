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
