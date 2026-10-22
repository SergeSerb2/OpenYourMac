import Foundation

enum ShortcutsWarnings {
    static func canonical(_ combo: KeyCombo) -> KeyCombo {
        let aliases = [",": "comma", ".": "period", "`": "grave", "[": "leftbracket", "]": "rightbracket",
                       ";": "semicolon", "'": "quote", "/": "slash", "\\": "backslash", "=": "equal", "-": "minus"]
        return KeyCombo(modifiers: combo.modifiers, key: aliases[combo.key] ?? combo.key)
    }

    /// Two bindings conflict when at least one physical modifier event matches both.
    static func overlaps(_ lhs: KeyCombo, _ rhs: KeyCombo) -> Bool {
        guard let leftCode = lhs.resolvedKeyCode, let rightCode = rhs.resolvedKeyCode, leftCode == rightCode else { return false }
        let groups: [(KeyCombo.Modifiers, KeyCombo.Modifiers, KeyCombo.Modifiers)] = [
            (.ctrl, .lctrl, .rctrl), (.alt, .lalt, .ralt),
            (.shift, .lshift, .rshift), (.cmd, .lcmd, .rcmd)
        ]
        for (generic, left, right) in groups {
            func sides(_ mods: KeyCombo.Modifiers) -> Int {
                (mods.contains(generic) ? 3 : 0) | (mods.contains(left) ? 1 : 0) | (mods.contains(right) ? 2 : 0)
            }
            let a = sides(lhs.modifiers), b = sides(rhs.modifiers)
            if a == 0 || b == 0 { if a != b { return false } }
            else if a & b == 0 { return false }
        }
        return lhs.modifiers.contains(.fn) == rhs.modifiers.contains(.fn)
    }

    static func reason(for combo: KeyCombo) -> String? {
        let canonical = canonical(combo)
        if let reason = known.first(where: { overlaps($0.key, canonical) })?.value { return reason }
        var modifiers = canonical.modifiers
        for (generic, left, right) in [(KeyCombo.Modifiers.ctrl, KeyCombo.Modifiers.lctrl, KeyCombo.Modifiers.rctrl), (.alt, .lalt, .ralt), (.shift, .lshift, .rshift), (.cmd, .lcmd, .rcmd)] {
            if !modifiers.intersection([generic, left, right]).isEmpty {
                modifiers.subtract([left, right])
                modifiers.insert(generic)
            }
        }
        let combo = KeyCombo(modifiers: modifiers, key: canonical.key)
        let character = combo.key.count == 1 && combo.key.first.map { $0.isLetter || $0.isNumber } == true
        if character && (combo.modifiers == .alt || combo.modifiers == [.alt, .shift]) {
            return "These keys normally type a special character, such as ç, ß or ™. Using them here will prevent that character from being typed in other apps."
        }
        if combo.modifiers == .shift {
            return "These keys normally type a capital letter or symbol. Using them here will prevent that input in other apps."
        }
        if combo.modifiers.contains(.cmd) && !combo.modifiers.contains(.ctrl) && !combo.modifiers.contains(.alt) {
            return "Apps often use these keys for their own commands. Those commands will be unavailable while this shortcut is active."
        }
        return nil
    }

    /// Static macOS defaults, not a scan of the user's system shortcuts.
    static let known: [KeyCombo: String] = {
        let entries: [(String, String)] = [
            ("cmd - q", "Quits the current app."),
            ("cmd - w", "Closes the current window or tab."),
            ("cmd - h", "Hides the current app."),
            ("cmd - m", "Minimizes the current window."),
            ("cmd - tab", "Switches between apps."),
            ("cmd - space", "Opens Spotlight."),
            ("cmd - c", "Copies the selection."),
            ("cmd - v", "Pastes from the clipboard."),
            ("cmd - x", "Cuts the selection."),
            ("cmd - z", "Undoes the last change."),
            ("cmd + shift - z", "Redoes the last change."),
            ("cmd - a", "Selects all content."),
            ("cmd - s", "Saves the current document."),
            ("cmd - n", "Opens a new window."),
            ("cmd - t", "Opens a new tab."),
            ("cmd - o", "Opens a file."),
            ("cmd - p", "Prints the current document."),
            ("cmd - f", "Finds text."),
            ("cmd - r", "Reloads the current page."),
            ("cmd - l", "Selects the browser's address bar."),
            ("cmd - b", "Makes selected text bold."),
            ("cmd - i", "Makes selected text italic."),
            ("cmd - u", "Underlines selected text."),
            ("cmd - comma", "Opens the current app's settings."),
            ("cmd - grave", "Switches between windows of the current app."),
            ("cmd + shift - 3", "Captures a screenshot of the screen."),
            ("cmd + shift - 4", "Captures a selected part of the screen."),
            ("cmd + shift - 5", "Opens the screenshot tools."),
            ("cmd - leftarrow", "Moves the text cursor to the start of a line."),
            ("cmd - rightarrow", "Moves the text cursor to the end of a line."),
            ("cmd - uparrow", "Moves to the start of a document."),
            ("cmd - downarrow", "Moves to the end of a document."),
            ("ctrl - uparrow", "Opens Mission Control."),
            ("ctrl - downarrow", "Shows the current app's windows in App Exposé."),
            ("ctrl - leftarrow", "Switches to the desktop on the left."),
            ("ctrl - rightarrow", "Switches to the desktop on the right."),
            ("alt - leftarrow", "Moves the text cursor back by one word."),
            ("alt - rightarrow", "Moves the text cursor forward by one word."),
            ("alt - uparrow", "Moves the text cursor up by one paragraph."),
            ("alt - downarrow", "Moves the text cursor down by one paragraph."),
            ("alt + shift - leftarrow", "Selects the previous word."),
            ("alt + shift - rightarrow", "Selects the next word."),
            ("alt - delete", "Deletes the previous word."),
            ("ctrl - space", "Switches the keyboard input source."),
            ("cmd + ctrl - q", "Locks the screen."),
            ("cmd + ctrl - f", "Enters or leaves full screen."),
            ("cmd + ctrl - space", "Opens the emoji and symbol picker."),
            ("alt + cmd - escape", "Opens Force Quit."),
            ("alt + cmd - d", "Shows or hides the Dock."),
            ("alt + cmd - h", "Hides all other apps."),
            ("alt + cmd - m", "Minimizes all windows of the current app.")
        ]
        return Dictionary(uniqueKeysWithValues: entries.compactMap { keys, reason in
            KeyCombo(configString: keys).map { (canonical($0), reason) }
        })
    }()
}
