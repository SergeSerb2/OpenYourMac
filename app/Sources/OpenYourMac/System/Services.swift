import AppKit

enum SetupGroup: String, CaseIterable, Identifiable {
    case essentials, trackpad, missionControl, displays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .essentials: return "Essentials"
        case .trackpad: return "Trackpad"
        case .missionControl: return "Mission Control & Windows"
        case .displays: return "Displays"
        }
    }

    var systemImage: String {
        switch self {
        case .essentials: return "checkmark.shield"
        case .trackpad: return "hand.point.up.left"
        case .missionControl: return "rectangle.3.group"
        case .displays: return "display.2"
        }
    }
}

/// A button offered under a failing check.
struct SetupAction: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Opens a System Settings pane (deep link).
        case openSettings(URL)
        /// OpenYourMac changes the macOS setting itself ("Turn It Off for Me").
        case automaticFix
        /// Quits other apps by bundle identifier (NSRunningApplication.terminate).
        case quitApps([String])
        /// Reveals a file in Finder.
        case reveal(URL)
        /// Changes OpenYourMac's own `swipe_gesture_fingers` (0, 3 or 4).
        case setSwipeFingers(Int)
    }

    var id: String
    var label: String
    var kind: Kind
    /// Shown as the filled button; others are secondary.
    var isPrimary = false
}

struct SetupCheck: Identifiable, Equatable {
    var id: String
    var group: SetupGroup
    /// Passing title ("Stage Manager is off") or failing title ("Turn off Stage Manager").
    var title: String
    /// Passing note, or the failure explanation ("It moves windows too, …").
    var detail: String
    var state: CheckState
    /// What to change, shown under a failing check ("Turn on OpenYourMac in the list.").
    var instruction: String?
    /// Human path in System Settings ("System Settings › Desktop & Dock").
    var settingPath: String?
    /// Recommendations never count as blocking failures.
    var isRecommendation = false
    /// The change only applies after logging out and back in.
    var needsLogout = false
    var actions: [SetupAction] = []
}

struct ConnectedDisplay: Identifiable, Equatable {
    /// Display UUID (stable across reconnects); this is what `ignored_displays` stores.
    var id: String
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var isMain: Bool

    var summary: String {
        "\(pixelWidth) × \(pixelHeight)" + (isMain ? " · Main display" : "")
    }
}

// MARK: - Last used app

/// Remembers the last app that was frontmost before OpenYourMac, because
/// window actions apply to that app's focused window.
@MainActor
final class FrontmostAppTracker: ObservableObject {
    @Published private(set) var lastAppName: String?
    @Published private(set) var lastBundleID: String?
    private var observer: NSObjectProtocol?

    init() {
        record(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    /// Records regular apps other than OpenYourMac itself.
    private func record(_ app: NSRunningApplication?) {
        guard let app,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular
        else { return }
        lastAppName = app.localizedName
        lastBundleID = app.bundleIdentifier
    }
}
