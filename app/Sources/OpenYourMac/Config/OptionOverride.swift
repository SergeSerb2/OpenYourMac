import Foundation

struct OptionOverride: Equatable, Identifiable {
    enum Kind { case direct, inverted, duration, direction, dimColor, nativeDim }
    let path: PartialKeyPath<ConfigOptions>
    let table: [String]
    let key: String
    let kind: Kind
    let value: ConfigDocument.Value?
    var id: String { (table + [key]).joined(separator: ".") }
    var summary: String { "\(id) = \(value?.token ?? "(not set)")" }

    /// Opaque legacy parents can override modern keys even without a table header.
    static func handEditedEntry(_ path: PartialKeyPath<ConfigOptions>, in doc: ConfigDocument) -> ConfigDocument.Entry? {
        let paths: [[String]]
        switch path {
        case \ConfigOptions.animation: paths = [["options", "animation_duration_ms"], ["options", "animation_speed"]]
        case \ConfigOptions.sessionRestore: paths = [["restore", "enabled"]]
        case \ConfigOptions.nativeTabs: paths = [["options", "disable_native_tabs"]]
        case \ConfigOptions.swipeGestureFingers: paths = [["swipe", "gesture", "fingers_count"]]
        case \ConfigOptions.swipeNatural: paths = [["swipe", "gesture", "direction"], ["options", "swipe_gesture_direction"]]
        case \ConfigOptions.scrollModifier: paths = [["swipe", "scroll", "modifier"]]
        case \ConfigOptions.focusBorder: paths = [["decorations", "active", "border", "enabled"], ["options", "border_active_window"]]
        case \ConfigOptions.focusBorderWidth: paths = [["decorations", "active", "border", "width"], ["options", "border_width"]]
        case \ConfigOptions.focusBorderRadius: paths = [["decorations", "active", "border", "radius"], ["options", "border_radius"]]
        case \ConfigOptions.focusBorderColor:
            paths = ["color", "opacity"].map { ["decorations", "active", "border", $0] }
                + [["options", "border_color"], ["options", "border_opacity"]]
        case \ConfigOptions.dimInactive, \ConfigOptions.dimInactiveOpacity:
            paths = ["color", "opacity", "opacity_night"].map { ["decorations", "inactive", "dim", $0] }
                + [["options", "dim_inactive_color"], ["options", "dim_inactive_windows"]]
        default: paths = []
        }
        let fileOnly = [\ConfigOptions.focusBorder, \ConfigOptions.focusBorderWidth, \ConfigOptions.focusBorderRadius, \ConfigOptions.focusBorderColor].contains(path)
        for path in paths {
            if let entry = doc.opaqueEntry(containing: path) { return entry }
            if let key = path.last, let entry = doc.entry(key, in: Array(path.dropLast())), fileOnly || !entry.editable { return entry }
        }
        return nil
    }

    static func find(_ path: PartialKeyPath<ConfigOptions>, in doc: ConfigDocument, dark: Bool = false) -> OptionOverride? {
        guard handEditedEntry(path, in: doc) == nil else { return nil }
        func field(_ table: [String], _ key: String, _ kind: Kind = .direct, evenIfMissing: Bool = false) -> OptionOverride? {
            guard evenIfMissing || doc.entry(key, in: table) != nil else { return nil }
            return OptionOverride(path: path, table: table, key: key, kind: kind, value: doc.value(key, in: table))
        }
        switch path {
        case \ConfigOptions.animation:
            for key in ["animation_duration_ms", "animation_speed"] {
                if doc.value(key, in: ["options"])?.number?.isFinite == true { return field(["options"], key, .duration) }
            }
        case \ConfigOptions.sessionRestore: return field(["restore"], "enabled")
        case \ConfigOptions.nativeTabs: return field(["options"], "disable_native_tabs", .inverted)
        case \ConfigOptions.swipeGestureFingers: return field(["swipe", "gesture"], "fingers_count")
        case \ConfigOptions.swipeNatural:
            return field(["swipe", "gesture"], "direction", .direction) ?? field(["options"], "swipe_gesture_direction", .direction)
        case \ConfigOptions.scrollModifier: return field(["swipe", "scroll"], "modifier")
        case \ConfigOptions.dimInactive, \ConfigOptions.dimInactiveOpacity:
            let table = ["decorations", "inactive", "dim"]
            let hasNested = doc.tables.contains(table) || doc.entries.contains { $0.table == table }
            if hasNested {
                let colored = doc.value("color", in: table)?.string != nil
                let key = !colored && dark && doc.entry("opacity_night", in: table) != nil ? "opacity_night" : "opacity"
                return field(table, key, path == \ConfigOptions.dimInactive ? (colored ? .dimColor : .nativeDim) : .direct, evenIfMissing: true)
            }
            if doc.value("dim_inactive_color", in: ["options"]) != nil {
                return field(["options"], "dim_inactive_windows", path == \ConfigOptions.dimInactive ? .dimColor : .direct, evenIfMissing: true)
            }
            if doc.value("dim_inactive", in: ["options"]) != .bool(true),
               doc.value("dim_inactive_windows", in: ["options"]) != nil {
                return field(["options"], "dim_inactive_windows", path == \ConfigOptions.dimInactive ? .nativeDim : .direct)
            }
        default: break
        }
        return nil
    }

    func apply(to options: inout ConfigOptions) {
        switch path {
        case \ConfigOptions.animation:
            let ms = min(2000, max(0, value?.number ?? 222))
            options.animationDurationMS = ms
            options.animation = ms == 0 ? .instant : ms == 140 ? .fast : ms == 222 ? .smooth : .custom
        case \ConfigOptions.sessionRestore:
            if case .bool(let enabled) = value { options.sessionRestore = enabled }
        case \ConfigOptions.nativeTabs:
            if case .bool(let disabled) = value { options.nativeTabs = !disabled }
        case \ConfigOptions.swipeGestureFingers:
            if case .integer(let fingers) = value, fingers >= 0 { options.swipeGestureFingers = fingers }
        case \ConfigOptions.swipeNatural: options.swipeNatural = value?.string != "Reversed"
        case \ConfigOptions.scrollModifier:
            if let raw = value?.string, let modifier = ScrollModifier(engineValue: raw, nested: true) { options.scrollModifier = modifier }
        case \ConfigOptions.dimInactive:
            options.dimInactive = (value?.number ?? 0) != 0
        case \ConfigOptions.dimInactiveOpacity:
            options.dimInactiveOpacity = value?.number ?? 0
        default: break
        }
    }

    /// Updates the specific overriding key after explicit consent; unrelated legacy settings stay intact.
    func update(_ token: ConfigDocument.Value, in doc: inout ConfigDocument) throws {
        var value: ConfigDocument.Value? = token
        switch kind {
        case .inverted:
            if case .bool(let enabled) = token { value = .bool(!enabled) }
        case .duration:
            value = .float(token.string == "instant" ? 0 : token.string == "fast" ? 140 : 222)
        case .direction:
            if case .bool(let natural) = token { value = .string(natural ? "Natural" : "Reversed") }
        case .dimColor, .nativeDim:
            if case .bool(let enabled) = token {
                value = .float(enabled ? max(self.value?.number ?? 0, 0.25) : 0)
            }
        case .direct:
            if path == \ConfigOptions.scrollModifier && token.string == "off" {
                value = nil
                try doc.set("scroll_modifier", in: ["options"], to: token)
            } else if path == \ConfigOptions.dimInactive, case .bool(let enabled) = token {
                // Native brightness has no boolean switch; zero disables it.
                value = .float(enabled ? 0.25 : 0)
            }
        }
        try doc.set(key, in: table, to: value)
    }
}

struct PendingOptionOverride: Identifiable {
    let id = UUID()
    let override: OptionOverride
    let value: ConfigDocument.Value
}
