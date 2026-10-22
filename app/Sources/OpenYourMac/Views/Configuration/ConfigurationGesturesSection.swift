import SwiftUI

struct ConfigurationGesturesSection: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var setup: MacSetupChecker
    @EnvironmentObject private var state: AppState

    var body: some View {
        PageSection("Gestures & Mouse", caption: "Scroll and rearrange the strip without the keyboard") {
            Card {
                SettingPickerRow(
                    title: "Swipe to Scroll the Strip", subtitle: "Swipe left or right on the trackpad to move through your windows",
                    options: [(0, "Off"), (3, "3 Fingers"), (4, "4 Fingers"), (5, "5 Fingers")] + ([0, 3, 4, 5].contains(config.options.swipeGestureFingers) ? [] : [(config.options.swipeGestureFingers, "Custom value: \(config.options.swipeGestureFingers) (uses 4)")]),
                    selection: config.binding(\.swipeGestureFingers), pickerWidth: hasCustomFingers ? 244 : 310, usesMenu: hasCustomFingers
                )
                swipeStatus.padding(.bottom, 2)
                SettingToggleRow(title: "Natural Swipe Direction", subtitle: "Content follows your fingers, like scrolling on macOS", isOn: config.binding(\.swipeNatural), disabled: swipeOff)
                SettingPickerRow(
                    title: "Swipe Settles", subtitle: config.options.swipeSnap.explanation,
                    options: SwipeSettle.allCases.map { ($0, $0.label) },
                    selection: config.binding(\.swipeSnap), pickerWidth: 110
                )
                .disabled(swipeOff)
                .opacity(swipeOff ? 0.45 : 1)
                CardDivider()
                SettingToggleRow(title: "Drag to Reorder", subtitle: "Drag a tiled window over another column to move it there", isOn: config.binding(\.dragReorder))
                CardDivider()
                SettingPickerRow(
                    title: "Scroll to Move Through the Strip", subtitle: "Hold these keys and scroll with a mouse wheel or trackpad to step between windows",
                    options: (ScrollModifier.allCases.contains(config.options.scrollModifier) ? ScrollModifier.allCases : ScrollModifier.allCases + [config.options.scrollModifier]).map { ($0, ScrollModifier.allCases.contains($0) ? $0.label : "Custom value: \($0.label)") },
                    selection: config.binding(\.scrollModifier), pickerWidth: hasCustomModifier ? 244 : 196, usesMenu: hasCustomModifier
                )
            }
            .configOptions([\.swipeGestureFingers, \.swipeNatural, \.swipeSnap, \.dragReorder, \.scrollModifier])
        }
    }

    private var hasCustomFingers: Bool { ![0, 3, 4, 5].contains(config.options.swipeGestureFingers) }
    private var hasCustomModifier: Bool { !ScrollModifier.allCases.contains(config.options.scrollModifier) }
    private var swipeOff: Bool { config.options.swipeGestureFingers == 0 }

    private var swipeChecks: [SetupCheck] {
        setup.checks.filter {
            $0.id == "desktopSwipe" || $0.id == "pageSwipe" || (config.options.effectiveSwipeGestureFingers == 3 && $0.id == "threeFingerDrag")
        }
    }

    private var conflict: SetupCheck? {
        swipeChecks.first { $0.state == .fail || $0.state == .warning }
    }

    private var swipeStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: swipeOff ? "info.circle" : (conflict != nil ? "exclamationmark.triangle" : (swipeChecks.isEmpty || swipeChecks.contains { $0.state == .unknown } ? "info.circle" : "checkmark.circle")))
                .foregroundStyle(conflict != nil && !swipeOff ? Theme.warning : Theme.textSecondary)
            Text(swipeMessage)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !swipeOff && (conflict != nil || swipeChecks.isEmpty) {
                Button("Mac Setup") { state.page = .macSetup }
                    .buttonStyle(LinkButtonStyle())
                    .fixedSize()
            }
        }
        .font(Theme.Font.rowSubtitle)
    }

    private var swipeMessage: String {
        let fingers = config.options.effectiveSwipeGestureFingers
        if swipeOff { return "The swipe is off right now." }
        if let conflict {
            switch conflict.id {
            case "desktopSwipe" where fingers == 4:
                return "macOS also uses 4-finger swipes. Turn off ‘Swipe between full-screen applications’ in Trackpad settings. To keep desktop swipes, set them to four fingers and use 3 Fingers here, or switch this off and hold \(config.options.scrollModifier == .off ? "⌃⌥" : config.options.scrollModifier.label) while scrolling."
            case "desktopSwipe":
                return "macOS also uses 3-finger desktop swipes. Set ‘Swipe between full-screen applications’ to four fingers, turn it off, or choose another swipe here."
            case "threeFingerDrag":
                return "macOS uses three fingers to drag windows. Turn off three-finger dragging in Accessibility › Pointer Control, or use 4 Fingers here."
            default:
                return "macOS also uses this swipe to turn pages. Change ‘Swipe between pages’ in Trackpad settings, or choose another swipe here."
            }
        }
        guard !swipeChecks.isEmpty, swipeChecks.allSatisfy({ $0.state == .pass }) else {
            return "Check Mac Setup to see whether macOS uses this swipe."
        }
        return "macOS isn't using \(fingers)-finger swipes for anything else, so the strip has them to itself."
    }
}
