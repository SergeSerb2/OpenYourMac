import Foundation

/// Groups shown on the Shortcuts page and in Help → Shortcut Reference, in order.
enum ShortcutGroup: String, CaseIterable, Identifiable {
    case focus, moveWindow, jumpByNumber, size, columnsAndStacks, pin, floatingAndDisplays, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .moveWindow: return "Move Window"
        case .jumpByNumber: return "Jump by Number"
        case .size: return "Size"
        case .columnsAndStacks: return "Columns & Stacks"
        case .pin: return "Pin"
        case .floatingAndDisplays: return "Floating & Displays"
        case .other: return "Other"
        }
    }

    var caption: String {
        switch self {
        case .focus: return "Switch to another window in the strip"
        case .moveWindow: return "Move the focused window to a new place in the strip"
        case .jumpByNumber: return "Address columns 1–8; 9 always selects the last column"
        case .size: return "Center and resize the focused window"
        case .columnsAndStacks: return "Put several windows in one column"
        case .pin: return "Keep a window on screen at the edge while the rest of the strip scrolls"
        case .floatingAndDisplays: return "Take a window out of the strip, or send it to another display"
        case .other: return "Stop the window manager"
        }
    }
}

/// One bindable action. `id` is the key in the config's `[bindings]` table.
struct ShortcutAction: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let group: ShortcutGroup
    let defaults: [KeyCombo]
    var isDestructive = false

    /// The engine command this binding runs (`window_focus_west` → `window focus west`).
    var command: EngineCommand { EngineCommand(bindingName: id) }
}

enum ShortcutCatalog {
    static let all: [ShortcutAction] = build()

    static func action(_ id: String) -> ShortcutAction? { byID[id] }

    static func actions(in group: ShortcutGroup) -> [ShortcutAction] {
        all.filter { $0.group == group }
    }

    private static let byID: [String: ShortcutAction] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static func combo(_ s: String) -> KeyCombo {
        guard let combo = KeyCombo(configString: s) else { preconditionFailure("bad default shortcut \(s)") }
        return combo
    }

    private static func build() -> [ShortcutAction] {
        let ca = "ctrl + alt"
        let cas = "ctrl + alt + shift"
        var list: [ShortcutAction] = []
        func add(_ id: String, _ title: String, _ subtitle: String, _ group: ShortcutGroup, _ keys: [String], destructive: Bool = false) {
            list.append(ShortcutAction(id: id, title: title, subtitle: subtitle, group: group, defaults: keys.map(combo), isDestructive: destructive))
        }

        add("window_focus_west", "Focus Left", "Switch to the window on the left", .focus, ["\(ca) - leftarrow", "\(ca) - h"])
        add("window_focus_east", "Focus Right", "Switch to the window on the right", .focus, ["\(ca) - rightarrow", "\(ca) - l"])
        add("window_focus_north", "Focus Up", "Switch to the window above, in a stacked column", .focus, ["\(ca) - uparrow", "\(ca) - k"])
        add("window_focus_south", "Focus Down", "Switch to the window below, in a stacked column", .focus, ["\(ca) - downarrow", "\(ca) - j"])
        add("window_focus_first", "Focus First", "Jump to the first window in the strip", .focus, ["ctrl + alt + cmd - leftarrow"])
        add("window_focus_last", "Focus Last", "Jump to the last window in the strip", .focus, ["ctrl + alt + cmd - rightarrow"])
        add("strip_show", "Show Strip", "Show the strip minimap; it stays up while you hold the keys", .focus, ["\(ca) - s"])

        add("window_swap_west", "Move Window Left", "Move the focused window one place left", .moveWindow, ["\(cas) - leftarrow", "\(cas) - h"])
        add("window_swap_east", "Move Window Right", "Move the focused window one place right", .moveWindow, ["\(cas) - rightarrow", "\(cas) - l"])
        add("window_swap_north", "Move Window Up", "Move the focused window up inside its column", .moveWindow, ["\(cas) - uparrow", "\(cas) - k"])
        add("window_swap_south", "Move Window Down", "Move the focused window down inside its column", .moveWindow, ["\(cas) - downarrow", "\(cas) - j"])
        add("window_swap_first", "Move Window to First", "Move the focused window to the start of the strip", .moveWindow, ["ctrl + alt + cmd + shift - leftarrow"])
        add("window_swap_last", "Move Window to Last", "Move the focused window to the end of the strip", .moveWindow, ["ctrl + alt + cmd + shift - rightarrow"])

        for n in 1...8 {
            add("window_focus_\(n)", "Jump to \(n)", "Switch to the top window of column \(n)", .jumpByNumber, ["\(ca) - \(n)"])
        }
        add("window_focus_9", "Jump to Last", "Switch to the top window of the last column", .jumpByNumber, ["\(ca) - 9"])
        for n in 1...8 {
            add("window_swap_\(n)", "Move to \(n)", "Move the focused window to column \(n)", .jumpByNumber, ["\(cas) - \(n)"])
        }
        add("window_swap_9", "Move to Last", "Move the focused window to the end of the strip", .jumpByNumber, ["\(cas) - 9"])

        add("window_center", "Center Window", "Scroll the strip so the focused window is in the middle", .size, ["\(ca) - c"])
        add("window_resize", "Resize Window", "Cycle through your preset widths", .size, ["\(ca) - r"])
        add("window_fullwidth", "Full Width", "Make the focused window as wide as the screen, or back", .size, ["\(ca) - f"])
        add("window_wider", "Wider", "Make the focused column a bit wider", .size, ["\(ca) - equal"])
        add("window_narrower", "Narrower", "Make the focused column a bit narrower", .size, ["\(ca) - minus"])
        add("window_taller", "Taller", "More height inside a stacked column (or for a lone window with Keep Original Height)", .size, ["\(cas) - equal"])
        add("window_shorter", "Shorter", "Less height inside a stacked column (or for a lone window with Keep Original Height)", .size, ["\(cas) - minus"])
        add("window_equalize", "Equal Heights", "Share a stacked column's height evenly again (or give a lone window with Keep Original Height the full height)", .size, ["\(ca) - 0"])

        add("window_stack", "Stack Left", "Put the focused window into the column on its left", .columnsAndStacks, ["\(ca) - ]"])
        add("window_unstack", "Unstack", "Give the focused window its own column again", .columnsAndStacks, ["\(cas) - ]"])
        add("window_consume_east", "Stack Right", "Put the focused window into the column on its right", .columnsAndStacks, ["\(ca) - ["])
        add("window_expel_west", "Unstack to the Left", "Take the focused window out of its column, to the left", .columnsAndStacks, ["\(cas) - ["])
        add("window_tabbed", "Tabs", "Show the focused column as tabs, one window at a time", .columnsAndStacks, ["\(cas) - t"])

        add("window_pin_left", "Pin Left", "Keep the focused column at the left edge; press again to put it back", .pin, ["\(ca) - p"])
        add("window_pin_right", "Pin Right", "Keep the focused column at the right edge; press again to put it back", .pin, ["\(cas) - p"])

        add("window_manage", "Float / Unfloat", "Take the focused window out of the strip, or put it back", .floatingAndDisplays, ["\(ca) - t"])
        add("window_nextdisplay", "Next Display", "Send the focused window to the next display's strip", .floatingAndDisplays, ["\(ca) - n"])

        add("quit", "Quit Window Manager", "Stop managing windows and put them all back on screen", .other, ["\(ca) - q"], destructive: true)
        return list
    }
}
