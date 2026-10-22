import AppKit
import Carbon.HIToolbox

/// One keyboard shortcut in the engine's config syntax:
/// `"ctrl + alt + shift - leftarrow"` (modifiers joined by `+`, then ` - `, then the key name).
struct KeyCombo: Hashable, Codable, CustomStringConvertible {
    struct Modifiers: OptionSet, Hashable, Codable {
        let rawValue: Int
        static let ctrl = Modifiers(rawValue: 1 << 0)
        static let alt = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let cmd = Modifiers(rawValue: 1 << 3)
        static let fn = Modifiers(rawValue: 1 << 4)
        static let lctrl = Modifiers(rawValue: 1 << 5)
        static let rctrl = Modifiers(rawValue: 1 << 6)
        static let lalt = Modifiers(rawValue: 1 << 7)
        static let ralt = Modifiers(rawValue: 1 << 8)
        static let lshift = Modifiers(rawValue: 1 << 9)
        static let rshift = Modifiers(rawValue: 1 << 10)
        static let lcmd = Modifiers(rawValue: 1 << 11)
        static let rcmd = Modifiers(rawValue: 1 << 12)

        /// Display and serialisation order: ⌃ ⌥ ⇧ ⌘.
        static let ordered: [(Modifiers, name: String, glyph: String)] = [
            (.ctrl, "ctrl", "⌃"),
            (.lctrl, "lctrl", "⌃"), (.rctrl, "rctrl", "⌃"),
            (.alt, "alt", "⌥"),
            (.lalt, "lalt", "⌥"), (.ralt, "ralt", "⌥"),
            (.shift, "shift", "⇧"),
            (.lshift, "lshift", "⇧"), (.rshift, "rshift", "⇧"),
            (.cmd, "cmd", "⌘"),
            (.lcmd, "lcmd", "⌘"), (.rcmd, "rcmd", "⌘"),
            (.fn, "fn", "fn"),
        ]
    }

    var modifiers: Modifiers
    /// Engine key name: a layout character ("h", "]", "1") or a literal name
    /// ("leftarrow", "equal", "minus", "return", "f5", …).
    var key: String

    init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased() == "plus" ? "+" : key.lowercased()
    }

    /// Parses `"ctrl + alt - h"`. Also accepts a bare key (`"f13"`).
    /// Left/right specific modifiers retain their identity when written back.
    init?(configString: String) {
        let trimmed = configString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let modifierPart: Substring
        let keyPart: Substring
        if let dash = trimmed.firstIndex(of: "-"), dash != trimmed.startIndex {
            modifierPart = trimmed[..<dash]
            keyPart = trimmed[trimmed.index(after: dash)...]
        } else {
            modifierPart = ""
            keyPart = Substring(trimmed)
        }
        var mods: Modifiers = []
        for raw in modifierPart.isEmpty ? [] : modifierPart.split(separator: "+", omittingEmptySubsequences: false) {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "ctrl": mods.insert(.ctrl)
            case "lctrl": mods.insert(.lctrl)
            case "rctrl": mods.insert(.rctrl)
            case "alt": mods.insert(.alt)
            case "lalt": mods.insert(.lalt)
            case "ralt": mods.insert(.ralt)
            case "shift": mods.insert(.shift)
            case "lshift": mods.insert(.lshift)
            case "rshift": mods.insert(.rshift)
            case "cmd": mods.insert(.cmd)
            case "lcmd": mods.insert(.lcmd)
            case "rcmd": mods.insert(.rcmd)
            case "fn": mods.insert(.fn)
            case "": return nil
            default: return nil
            }
        }
        let key = keyPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        self.modifiers = mods
        self.key = key
    }

    /// Serialised form written to the config file.
    var configString: String {
        let mods = Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.name)
        return mods.isEmpty ? key : mods.joined(separator: " + ") + " - " + key
    }

    var description: String { configString }

    /// Key-cap glyphs in display order, e.g. ["⌃", "⌥", "←"].
    var glyphs: [String] {
        Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.glyph) + [KeyCombo.glyph(forKey: key)]
    }

    /// Compact text such as "⌃⌥←" for menus and tooltips.
    var displayString: String { glyphs.joined() }

    // MARK: Key names

    /// Literal (layout independent) keys: engine name → virtual key code.
    static let literalKeys: [String: Int] = [
        "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
        "escape": kVK_Escape, "forwarddelete": kVK_ForwardDelete, "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "help": kVK_Help,
        "leftarrow": kVK_LeftArrow, "rightarrow": kVK_RightArrow, "uparrow": kVK_UpArrow, "downarrow": kVK_DownArrow,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17,
        "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1, "keypad2": kVK_ANSI_Keypad2,
        "keypad3": kVK_ANSI_Keypad3, "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
        "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7, "keypad8": kVK_ANSI_Keypad8,
        "keypad9": kVK_ANSI_Keypad9, "keypaddecimal": kVK_ANSI_KeypadDecimal,
        "keypadmultiply": kVK_ANSI_KeypadMultiply, "keypadplus": kVK_ANSI_KeypadPlus,
        "keypadclear": kVK_ANSI_KeypadClear, "keypaddivide": kVK_ANSI_KeypadDivide,
        "keypadenter": kVK_ANSI_KeypadEnter, "keypadminus": kVK_ANSI_KeypadMinus,
        "keypadequals": kVK_ANSI_KeypadEquals,
    ]

    /// Mirrors the engine's physical-name table. Only these codes are translated
    /// through Carbon; extra ISO/JIS/media keys must never fall back to a character.
    static let virtualKeys: [(name: String, code: Int)] = [
        ("a", 0x00),
        ("s", 0x01),
        ("d", 0x02),
        ("f", 0x03),
        ("h", 0x04),
        ("g", 0x05),
        ("z", 0x06),
        ("x", 0x07),
        ("c", 0x08),
        ("v", 0x09),
        ("section", 0x0a),
        ("b", 0x0b),
        ("q", 0x0c),
        ("w", 0x0d),
        ("e", 0x0e),
        ("r", 0x0f),
        ("y", 0x10),
        ("t", 0x11),
        ("1", 0x12),
        ("2", 0x13),
        ("3", 0x14),
        ("4", 0x15),
        ("6", 0x16),
        ("5", 0x17),
        ("equal", 0x18),
        ("9", 0x19),
        ("7", 0x1a),
        ("minus", 0x1b),
        ("8", 0x1c),
        ("0", 0x1d),
        ("rightbracket", 0x1e),
        ("o", 0x1f),
        ("u", 0x20),
        ("leftbracket", 0x21),
        ("i", 0x22),
        ("p", 0x23),
        ("l", 0x25),
        ("j", 0x26),
        ("quote", 0x27),
        ("k", 0x28),
        ("semicolon", 0x29),
        ("backslash", 0x2a),
        ("comma", 0x2b),
        ("slash", 0x2c),
        ("n", 0x2d),
        ("m", 0x2e),
        ("period", 0x2f),
        ("grave", 0x32),
        ("keypaddecimal", 0x41),
        ("keypadmultiply", 0x43),
        ("keypadplus", 0x45),
        ("keypadclear", 0x47),
        ("keypaddivide", 0x4b),
        ("keypadenter", 0x4c),
        ("keypadminus", 0x4e),
        ("keypadequals", 0x51),
        ("keypad0", 0x52),
        ("keypad1", 0x53),
        ("keypad2", 0x54),
        ("keypad3", 0x55),
        ("keypad4", 0x56),
        ("keypad5", 0x57),
        ("keypad6", 0x58),
        ("keypad7", 0x59),
        ("keypad8", 0x5b),
        ("keypad9", 0x5c),
    ]

    private static let otherLiteralKeys: [String: Int] = [
        "command": 0x37,
        "shift": 0x38,
        "capslock": 0x39,
        "option": 0x3a,
        "control": 0x3b,
        "rightcommand": 0x36,
        "rightshift": 0x3c,
        "rightoption": 0x3d,
        "rightcontrol": 0x3e,
        "function": 0x3f,
        "volumeup": 0x48,
        "volumedown": 0x49,
        "mute": 0x4a,
        "contextualmenu": 0x6e,
    ]

    private static let layoutKeymaps = NSCache<NSString, NSDictionary>()

    private static func layoutKeymap() -> [String: Int] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return [:] }
        let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        let cacheKey = "\(id)-\(LMGetKbdType())" as NSString
        if let cached = layoutKeymaps.object(forKey: cacheKey) as? [String: Int] { return cached }
        var result: [String: Int] = [:]
        for (_, code) in virtualKeys {
            if let character = layoutCharacter(forKeyCode: UInt16(code)), result[character] == nil { result[character] = code }
        }
        layoutKeymaps.setObject(result as NSDictionary, forKey: cacheKey)
        return result
    }

    /// Uses the same lookup order as engine/src/config.rs.
    var resolvedKeyCode: Int? {
        if let code = Self.layoutKeymap()[key] { return code }
        let physical = key == "[" ? "leftbracket" : key == "]" ? "rightbracket" : key
        return Self.virtualKeys.first { $0.name == physical }?.code ?? Self.literalKeys[key] ?? Self.otherLiteralKeys[key]
    }

    static func glyph(forKey key: String) -> String {
        switch key {
        case "leftarrow": return "←"
        case "rightarrow": return "→"
        case "uparrow": return "↑"
        case "downarrow": return "↓"
        case "equal": return "="
        case "minus": return "-"
        case "plus": return "+"
        case "return": return "↩"
        case "keypadenter": return "⌤"
        case "tab": return "⇥"
        case "space": return "Space"
        case "delete": return "⌫"
        case "forwarddelete": return "⌦"
        case "escape": return "⎋"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        case "leftbracket": return "["
        case "rightbracket": return "]"
        case "semicolon": return ";"
        case "quote": return "'"
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "backslash": return "\\"
        case "grave": return "`"
        default:
            if key.hasPrefix("keypad") { return "Num " + key.dropFirst(6).uppercased() }
            if key.count > 1, key.hasPrefix("f"), Int(key.dropFirst()) != nil { return key.uppercased() }
            return key.uppercased()
        }
    }

    /// Builds a combo from a key-down event. Returns nil for bare modifier presses.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Modifiers = []
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.cmd) }
        let code = Int(event.keyCode)
        if let literal = KeyCombo.literalKeys.first(where: { $0.value == code })?.key {
            // Function/navigation keys can carry .function intrinsically. Do not
            // infer Fn there; ordinary literal keys can safely retain explicit Fn.
            let intrinsic = literal.hasPrefix("f") && Int(literal.dropFirst()) != nil
                || ["leftarrow", "rightarrow", "uparrow", "downarrow", "home", "end", "pageup", "pagedown", "forwarddelete"].contains(literal)
            if event.modifierFlags.rawValue & 0x100 != 0 || flags.contains(.function) && !intrinsic { mods.insert(.fn) }
            let combo = KeyCombo(modifiers: mods, key: literal)
            guard combo.resolvedKeyCode == code else { return nil }
            self = combo
            return
        }
        if flags.contains(.function) { mods.insert(.fn) }
        guard let chars = KeyCombo.layoutCharacter(forKeyCode: UInt16(code)) ?? event.charactersIgnoringModifiers?.lowercased(),
              let first = chars.first, !chars.isEmpty
        else { return nil }
        let char = String(first)
        let key = char == "=" && code == kVK_ANSI_Equal ? "equal" : char
        let combo = KeyCombo(modifiers: mods, key: key)
        guard Self.virtualKeys.contains(where: { $0.code == code }), combo.resolvedKeyCode == code else { return nil }
        self = combo
    }

    /// The character a key produces in the current ASCII-capable layout with no modifiers.
    static func layoutCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).lowercased()
            return s.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : s
        }
    }
}
