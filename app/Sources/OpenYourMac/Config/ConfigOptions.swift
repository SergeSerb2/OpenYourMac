import Foundation

/// Typed view of the `[options]` table. Property names mirror the TOML keys
/// (camelCase ⇄ snake_case); defaults match the engine fallback.
struct ConfigOptions: Equatable {
    // Behavior
    var focusFollowsMouse = false            // focus_follows_mouse
    var mouseFollowsFocus = false            // mouse_follows_focus
    var sessionRestore = true                // session_restore
    var nativeTabs = true                    // native_tabs
    var floatDialogs = true                  // float_dialogs

    // Layout
    static let defaultPresetColumnWidths = [0.25, 0.33333, 0.5, 0.66667, 0.75]
    var presetColumnWidths = Self.defaultPresetColumnWidths
    var gapInner = 8.0                        // gap_inner (points)
    var gapOuter = 8.0                        // gap_outer (points)
    var dockAware = true                      // dock_aware
    var centerFocusedColumn: CenterMode = .never  // center_focused_column
    var keepWindowHeight = false              // keep_window_height

    // Appearance
    var animationDurationMS = 222.0
    var animation: AnimationStyle = .smooth   // animation
    var focusBorder = false                   // focus_border
    var focusBorderWidth = 2.0                // focus_border_width (points)
    var focusBorderColor = "#F7A028"          // focus_border_color
    var focusBorderRadius = 10.0              // focus_border_radius (points)
    var dimInactive = false                   // dim_inactive
    var dimInactiveOpacity = 0.25             // dim_inactive_opacity (0…1)
    var minimap = true                        // minimap
    var stripIndicatorInteractive = true      // strip_indicator_interactive
    var pinIndicator = true                   // pin_indicator

    // Gestures & mouse
    var swipeGestureFingers = 4               // swipe_gesture_fingers (0 = off, 3, 4)
    var effectiveSwipeGestureFingers: Int { [0, 3, 4, 5].contains(swipeGestureFingers) ? swipeGestureFingers : 4 }
    var swipeNatural = true                   // swipe_natural
    var swipeSnap: SwipeSettle = .snap        // swipe_snap
    var dragReorder = true                    // drag_reorder
    var scrollModifier: ScrollModifier = .ctrlAlt  // scroll_modifier

    // Diagnostics
    var detailedLogging = false               // detailed_logging

    // Displays
    var ignoredDisplays: [String] = []        // ignored_displays (display UUIDs)

    /// Map of every typed property to its TOML key. Used by the config store.
    static let tomlKeys: [PartialKeyPath<ConfigOptions>: String] = [
        \.focusFollowsMouse: "focus_follows_mouse",
        \.mouseFollowsFocus: "mouse_follows_focus",
        \.sessionRestore: "session_restore",
        \.nativeTabs: "native_tabs",
        \.floatDialogs: "float_dialogs",
        \.presetColumnWidths: "preset_column_widths",
        \.gapInner: "gap_inner",
        \.gapOuter: "gap_outer",
        \.dockAware: "dock_aware",
        \.centerFocusedColumn: "center_focused_column",
        \.keepWindowHeight: "keep_window_height",
        \.animation: "animation",
        \.focusBorder: "focus_border",
        \.focusBorderWidth: "focus_border_width",
        \.focusBorderColor: "focus_border_color",
        \.focusBorderRadius: "focus_border_radius",
        \.dimInactive: "dim_inactive",
        \.dimInactiveOpacity: "dim_inactive_opacity",
        \.minimap: "minimap",
        \.stripIndicatorInteractive: "strip_indicator_interactive",
        \.pinIndicator: "pin_indicator",
        \.swipeGestureFingers: "swipe_gesture_fingers",
        \.swipeNatural: "swipe_natural",
        \.swipeSnap: "swipe_snap",
        \.dragReorder: "drag_reorder",
        \.scrollModifier: "scroll_modifier",
        \.ignoredDisplays: "ignored_displays",
        \.detailedLogging: "detailed_logging",
    ]
}

enum CenterMode: String, CaseIterable {
    case never
    case onOverflow = "on-overflow"
    case always

    var label: String {
        switch self {
        case .never: return "Never"
        case .onOverflow: return "On Overflow"
        case .always: return "Always"
        }
    }

    var explanation: String {
        switch self {
        case .never: return "Scroll only as far as needed to bring the focused column on screen"
        case .onOverflow: return "Center the focused column when it would not fit next to the previous one"
        case .always: return "Always keep the focused column in the middle of the screen"
        }
    }
}

enum AnimationStyle: String, CaseIterable {
    case smooth, fast, instant, custom

    var label: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .smooth: return "Windows glide into place"
        case .fast: return "Windows move quickly"
        case .instant: return "Windows jump straight to their place"
        case .custom: return "The configuration file sets a custom duration"
        }
    }
}

enum SwipeSettle: String, CaseIterable {
    case snap, free

    var label: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .snap: return "Come to rest with a window lined up with the left edge, centred, or lined up with the right edge"
        case .free: return "Come to rest wherever the swipe leaves the strip"
        }
    }
}

struct ScrollModifier: RawRepresentable, Hashable, CaseIterable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let ctrlAlt = Self(rawValue: "ctrl + alt")
    static let altCmd = Self(rawValue: "alt + cmd")
    static let ctrlCmd = Self(rawValue: "ctrl + cmd")
    static let off = Self(rawValue: "off")
    static let allCases = [ctrlAlt, altCmd, ctrlCmd, off]

    init?(engineValue: String, nested: Bool = false) {
        let text = engineValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !nested && ["off", "none", "false"].contains(text) { self = .off; return }
        let aliases = ["control": "ctrl", "⌃": "ctrl", "option": "alt", "opt": "alt", "⌥": "alt",
                       "command": "cmd", "⌘": "cmd", "⇧": "shift"]
        let terms = text.components(separatedBy: "+").map { term -> String in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return nested ? trimmed : aliases[trimmed] ?? trimmed
        }
        let allowed = nested ? KeyCombo.Modifiers.ordered.map(\.name) : ["ctrl", "alt", "shift", "cmd"]
        guard terms.allSatisfy({ allowed.contains($0) }),
              let combo = KeyCombo(configString: terms.joined(separator: " + ") + " - x") else { return nil }
        rawValue = KeyCombo.Modifiers.ordered.filter { combo.modifiers.contains($0.0) }.map(\.name).joined(separator: " + ")
    }

    var label: String {
        if self == .off { return "Off" }
        guard let combo = KeyCombo(configString: rawValue + " - x") else { return rawValue }
        return KeyCombo.Modifiers.ordered.filter { combo.modifiers.contains($0.0) }.map {
            ($0.name.hasPrefix("l") ? "L" : $0.name.hasPrefix("r") ? "R" : "") + $0.glyph
        }.joined()
    }
}
