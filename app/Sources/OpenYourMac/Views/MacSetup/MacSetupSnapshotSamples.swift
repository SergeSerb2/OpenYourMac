#if DEBUG
import Foundation

/// Rendering fixtures only; never changes a service or a macOS setting.
/// OYM_MAC_SETUP_STATE accepts failure, single, or recommendation. The
/// checklist reads this only inside the snapshot environment.
enum MacSetupSnapshotSamples {
    static var checks: [SetupCheck]? {
        switch ProcessInfo.processInfo.environment["OYM_MAC_SETUP_STATE"] {
        case "failure": return failures
        case "recommendation": return [recommendation]
        case "single": return [failures[0]]
        default: return nil
        }
    }

    private static func settings(_ label: String, _ address: String) -> SetupAction {
        SetupAction(id: address, label: label, kind: .openSettings(URL(string: address) ?? AppPaths.setupGuideURL))
    }

    private static var failures: [SetupCheck] {
        [
            SetupCheck(
                id: "accessibility", group: .essentials,
                title: "Allow \(AppPaths.appName) in Accessibility",
                detail: "macOS needs your permission before this app can move windows.", state: .fail,
                instruction: "Turn on \(AppPaths.appName) in the list.",
                settingPath: "System Settings › Privacy & Security › Accessibility",
                actions: [settings("Open Accessibility Settings", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")]
            ),
            SetupCheck(
                id: "desktopSwipe", group: .trackpad,
                title: "macOS also switches desktops with 4 fingers",
                detail: "A strip swipe can also move the whole desktop.", state: .fail,
                instruction: "Set “Swipe between full-screen applications” to Off. To keep desktop swipes, set it to four fingers and use three fingers here instead.",
                settingPath: "System Settings › Trackpad › More Gestures",
                actions: [
                    settings("Open Trackpad Settings", "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"),
                    SetupAction(id: "threeFingers", label: "Use 3 Fingers in \(AppPaths.appName)", kind: .setSwipeFingers(3)),
                ]
            ),
            SetupCheck(
                id: "otherWindowManagers", group: .missionControl,
                title: "Quit Rectangle (it also moves windows)",
                detail: "Two window managers can move the same window at the same time.", state: .fail,
                instruction: "If it starts at login, turn that off in its own settings too.",
                actions: [SetupAction(id: "quitRectangle", label: "Quit Rectangle", kind: .quitApps(["com.knollsoft.Rectangle"]), isPrimary: true)]
            ),
            SetupCheck(
                id: "rearrangeSpaces", group: .missionControl,
                title: "Stop macOS reordering your desktops",
                detail: "Keep each strip on the desktop where you left it.", state: .fail,
                instruction: "Turn off “Automatically rearrange Spaces based on most recent use”.",
                settingPath: "System Settings › Desktop & Dock › Mission Control",
                actions: [
                    SetupAction(id: "fixOrder", label: "Turn It Off for Me", kind: .automaticFix, isPrimary: true),
                    settings("Open Desktop & Dock Settings", "x-apple.systempreferences:com.apple.Desktop-Settings.extension"),
                ]
            ),
            SetupCheck(
                id: "separateSpaces", group: .displays,
                title: "Turn on “Displays have separate Spaces”",
                detail: "Each display needs its own desktops for its own strip.", state: .fail,
                instruction: "Turn on “Displays have separate Spaces”.",
                settingPath: "System Settings › Desktop & Dock › Mission Control", needsLogout: true,
                actions: [settings("Open Desktop & Dock Settings", "x-apple.systempreferences:com.apple.Desktop-Settings.extension")]
            ),
            recommendation,
        ]
    }

    private static var recommendation: SetupCheck {
        SetupCheck(
            id: "displayArrangement", group: .displays, title: "Consider stacking your displays",
            detail: "Side by side works. Placing one display above the other lets windows slide fully off both edges.",
            state: .warning, instruction: "Arrange one display above the other.",
            settingPath: "System Settings › Displays › Arrange", isRecommendation: true,
            actions: [settings("Open Displays Settings", "x-apple.systempreferences:com.apple.Displays-Settings.extension")]
        )
    }
}
#endif
