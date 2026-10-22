import Foundation

enum ShortcutsMigration {
    /// Only exact older shipped sets qualify. A user's edited alternatives stay intact.
    static let oldDefaults: [String: [KeyCombo]] = {
        var values: [String: [String]] = [:]
        for (direction, letter, arrow) in [("west", "h", "leftarrow"), ("east", "l", "rightarrow"),
                                            ("north", "k", "uparrow"), ("south", "j", "downarrow")] {
            values["window_focus_\(direction)"] = ["alt - \(letter)", "alt - \(arrow)"]
            values["window_swap_\(direction)"] = ["alt + shift - \(letter)", "alt + shift - \(arrow)"]
        }
        values["window_focus_first"] = ["ctrl + alt - h"]
        values["window_focus_last"] = ["ctrl + alt - l"]
        for (id, key) in [("window_center", "c"), ("window_resize", "r"), ("window_fullwidth", "f"),
                          ("window_stack", "]"), ("window_consume_east", "["), ("window_manage", "t"), ("window_nextdisplay", "n")] {
            values[id] = ["alt - \(key)"]
        }
        values["window_unstack"] = ["alt + shift - ]"]
        values["window_expel_west"] = ["alt + shift - ["]
        values["window_tabbed"] = ["ctrl + alt - t"]
        return values.mapValues { $0.compactMap(KeyCombo.init(configString:)) }
    }()

    static func matches(_ combos: [KeyCombo], for actionID: String) -> Bool {
        guard let older = oldDefaults[actionID] else { return false }
        return Set(combos.map(ShortcutsWarnings.canonical)) == Set(older.map(ShortcutsWarnings.canonical))
    }
}
