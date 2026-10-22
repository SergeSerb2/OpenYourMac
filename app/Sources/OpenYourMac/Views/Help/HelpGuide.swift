import AppKit
import SwiftUI

private struct HelpAnswer: Identifiable {
    let title: String
    let text: String
    var actions: [String] = []
    var id: String { title }
}

struct HelpGuideSection: View {
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        PageSection("How Do I…", caption: "Click a question to see the answer") {
            Card(inset: 16) {
                VStack(spacing: 8) {
                    ForEach(answers) { answer in
                        DisclosureRow(answer.title) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(answer.text)
                                if !answer.actions.isEmpty { HelpActionKeys(actionIDs: answer.actions) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var answers: [HelpAnswer] {
        [
            HelpAnswer(title: "Move between windows?", text: "Use Focus Left or Focus Right to move along the strip, or click a window. Focus First and Focus Last go to its ends. The numbered actions focus the top window in columns 1–8; 9 means the last column. Numbered move actions move the focused window to that column. In a stacked column, Focus Up and Focus Down move between its windows.", actions: ["window_focus_west", "window_focus_east", "window_focus_first", "window_focus_last"] + (1...9).map { "window_focus_\($0)" } + ["window_focus_north", "window_focus_south"]),
            HelpAnswer(title: "Move a window to another place in the strip?", text: "Move Window Left and Move Window Right shift the focused window by one place. Move Window to First or Last sends it to an end. With Drag to Reorder enabled in Configuration, you can also drag its title bar over another column.", actions: ["window_swap_west", "window_swap_east", "window_swap_first", "window_swap_last"]),
            HelpAnswer(title: "Center a window?", text: "Center Window slides the strip until the focused window is in the middle. To do this whenever you change focus, choose Always under Configuration › Layout › Center Focused Column.", actions: ["window_center"]),
            HelpAnswer(title: "Make a window wider, or full width?", text: "Resize Window steps through the widths in Configuration › Preset Window Widths. Full Width fills the screen's available width; use it again to return. Wider and Narrower make smaller changes. You can also drag a window's edge.", actions: ["window_resize", "window_fullwidth", "window_wider", "window_narrower"]),
            HelpAnswer(title: "Keep a window out of the strip (float it)?", text: "Float / Unfloat releases the focused window so it stays where you put it. Use the action again to return it to the strip. For a lasting rule, choose Configuration › Window Rules › Add Rule, select the app, and enable Float. A title match can limit the rule to windows such as Picture in Picture.", actions: ["window_manage"]),
            HelpAnswer(title: "Stack windows in one column, or show them as tabs?", text: "Stack Left or Stack Right joins the focused window to the neighboring column. Unstack gives it a column again. Taller, Shorter and Equal Heights divide the space inside a stack. Tabs shows one member at a time; Focus Up and Focus Down select another member.", actions: ["window_stack", "window_consume_east", "window_unstack", "window_taller", "window_shorter", "window_equalize", "window_tabbed", "window_focus_north", "window_focus_south"]),
            HelpAnswer(title: "Scroll the strip with the trackpad?", text: swipeAnswer),
            HelpAnswer(title: "Use more than one display?", text: "Each display has its own strip. Next Display moves the focused window to the next one, whether the displays are arranged horizontally or vertically. Configuration › Displays lets you leave a display unmanaged. Enable “Displays have separate Spaces” in System Settings › Desktop & Dock, and follow any advice in Mac Setup.", actions: ["window_nextdisplay"]),
            HelpAnswer(title: "Focus a window just by pointing at it?", text: "Enable Focus Follows Mouse under Configuration › Behavior to focus a window when you move the pointer over it. Mouse Follows Focus moves the pointer to a window you select with the keyboard. Both options start off."),
            HelpAnswer(title: "Pause, stop or quit, and get my windows back?", text: "Choose Stop in the sidebar or menu bar, or use Quit Window Manager. Windows outside the screen return to view, and management stays off until you choose Start. Quitting \(AppPaths.appName) also stops management and brings the windows back.", actions: ["quit"])
        ]
    }

    private var swipeAnswer: String {
        guard config.handEditedKeys([\.swipeGestureFingers]).isEmpty else {
            return "Swipe settings are hand-edited. Check the finger count in your configuration file, then compare it with macOS Trackpad settings."
        }
        let fingers = config.options.swipeGestureFingers
        if fingers == 0 {
            return "Trackpad swiping is off. Enable it in Configuration › Gestures & Mouse; four fingers is a good starting point. Then open Mac Setup to check whether a macOS gesture uses the same fingers."
        }
        return "Swipe horizontally with \(fingers) fingers. If the whole desktop moves instead, macOS is using that gesture too. Mac Setup shows which setting to change. Configuration › Gestures & Mouse lets you choose three or four fingers and reverse the direction."
    }
}

struct HelpTroubleshootingSection: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var permissions: PermissionManager
    @State private var confirmRepair = false

    var body: some View {
        PageSection("Troubleshooting", caption: "When something doesn't work the way it should") {
            Card(inset: 16) {
                VStack(spacing: 8) {
                    DisclosureRow("Windows don't move") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Check the sidebar status and choose Start if management is stopped. Allow \(AppPaths.appName) in System Settings › Privacy & Security › Accessibility. Then use Mac Setup to check Stage Manager and other window managers. If only one app is affected, look for a floating rule in Configuration › Window Rules.")
                            macSetupButton
                        }
                    }
                    DisclosureRow("The swipe snaps back or slides the whole desktop") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("A macOS gesture is probably using the same fingers. Mac Setup identifies the conflict, often “Swipe between full-screen applications,” and links to the right System Settings page.")
                            macSetupButton
                        }
                    }
                    DisclosureRow("A window keeps resizing or tiles strangely") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tool windows, pop-ups and apps with fixed window sizes may resist tiling. Float the window, or add a Float rule for the app under Configuration › Window Rules.")
                            HelpActionKeys(actionIDs: ["window_manage"])
                            Button("Open Configuration") { state.page = .configuration }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    DisclosureRow("Shortcuts type characters, or don't work") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Option shortcuts can type characters such as ç or ß. In Shortcuts, switch unchanged older bindings to the Control-Option set, or record other keys. Check for conflicts between actions too. Another window manager can also claim the same keys; Mac Setup checks for those apps.")
                            HStack {
                                Button("Open Shortcuts") { state.page = .shortcuts }.buttonStyle(SecondaryButtonStyle())
                                macSetupButton
                            }
                        }
                    }
                    DisclosureRow("After an update, \(AppPaths.appName) says the permission is missing") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("macOS can retain a grant for the previous app copy. If \(AppPaths.appName) is already enabled in Accessibility but still reports a missing permission, repair its entry and allow it again.")
                            Button("Repair Permission…") { confirmRepair = true }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    DisclosureRow("The window manager stops by itself") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("The app tries to restart an engine that crashes. If the failures continue, Overview shows the cause and recent log lines. Reveal the full engine log below and include it when you report the issue.")
                            HStack {
                                Button("Open Overview") { state.page = .overview }.buttonStyle(SecondaryButtonStyle())
                                Button("Reveal Engine Log") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.engineLog]) }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
            }
        }
        .alert("Repair the Accessibility permission?", isPresented: $confirmRepair) {
            Button("Cancel", role: .cancel) { }
            Button("Repair Permission") { permissions.repair() }
        } message: {
            Text("This clears \(AppPaths.appName)'s existing permission entry and asks macOS for a new grant. You will need to allow the app again in Accessibility settings.")
        }
    }

    private var macSetupButton: some View {
        Button("Open Mac Setup") { state.page = .macSetup }.buttonStyle(SecondaryButtonStyle())
    }
}
