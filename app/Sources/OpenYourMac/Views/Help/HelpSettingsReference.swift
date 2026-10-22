import SwiftUI

struct HelpSettingsReference: View {
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        PageSection("Settings File Reference", caption: "Common product settings for editing the file by hand (Configuration › Reveal Config File)") {
            Card(inset: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    InfoNote(text: "This page covers common product settings, not every engine option. Compatibility keys and nested tables such as restore, padding, swipe and decorations are also accepted. Nested settings can override the flat controls. Edit complex TOML in the file; the app preserves its text.")
                    ForEach(HelpSettingsGroup.all) { group in
                        DisclosureRow(group.title, expanded: isSnapshot) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(group.entries, id: \.key) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.key).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(entry.detail)
                                    }
                                }
                                if let example = group.example {
                                    Text(example).font(Theme.Font.mono).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.keyCapFill))
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct HelpSettingsEntry {
    let key: String
    let detail: String
    init(_ key: String, _ detail: String) { self.key = key; self.detail = detail }
}

private struct HelpSettingsGroup: Identifiable {
    let title: String
    let entries: [HelpSettingsEntry]
    var example: String? = nil
    var id: String { title }

    static let all: [HelpSettingsGroup] = [
        HelpSettingsGroup(title: "Behavior: focus_follows_mouse, mouse_follows_focus, session_restore, native_tabs, float_dialogs", entries: [
            .init("focus_follows_mouse", "Boolean, default false. Focus a window when the pointer moves over it."),
            .init("mouse_follows_focus", "Boolean, default false. Move the pointer to a window selected by a focus command."),
            .init("session_restore", "Boolean, default true. Remember column order and widths across restarts."),
            .init("native_tabs", "Boolean, default true. Keep an app's native tabs, such as Finder or Terminal tabs, at one place in the strip."),
            .init("float_dialogs", "Boolean, default true. Leave dialogs, panels and previews floating. An explicit floating = false window rule can override this."),
            .init("float_recheck", "Boolean, default true. Check automatically floated windows again when more window information becomes available. Explicit user floats stay floating."),
            .init("exit_native_fullscreen", "Boolean, default false. Allow the engine's native full-screen exit behavior."),
            .init("tab_bar_clicks", "Boolean, default true. Let a click on a column's tab bar select a window."),
            .init("tab_bar_titles", "Boolean, default true. Include window titles in column tabs."),
            .init("detailed_logging", "Boolean, default false. Write extra engine decisions and window titles to the log. Turn it off after troubleshooting.")
        ]),
        HelpSettingsGroup(title: "Layout: preset_column_widths, gap_inner, gap_outer, dock_aware, center_focused_column, keep_window_height", entries: [
            .init("preset_column_widths", "Array of width fractions, default \(ConfigDocument.Value.array(ConfigOptions.defaultPresetColumnWidths.map(ConfigDocument.Value.float)).token). Resize cycles them in the order supplied. Each value must be greater than 0.05 and at most 1. Out-of-range values are ignored; if no usable values remain, the engine uses its defaults. Non-finite numbers are rejected."),
            .init("gap_inner", "Number, default 8. Space between columns and stacked windows, in logical screen points. Range 0–64."),
            .init("gap_outer", "Number, default 8. Space at the edges of the layout, in points. Range 0–64."),
            .init("dock_aware", "Boolean, default true. Keep the layout clear of the Dock."),
            .init("center_focused_column", "String, default \"never\". Use \"never\", \"on-overflow\" or \"always\". The aliases \"on_overflow\" and \"overflow\" also select overflow mode. Unknown values use never."),
            .init("keep_window_height", "Boolean, default false. A window in its own column keeps its opening or manually chosen height. Taller, Shorter and Equal Heights can then change it.")
        ], example: "[options]\npreset_column_widths = [0.25, 0.5, 0.75]\ncenter_focused_column = \"on-overflow\""),
        HelpSettingsGroup(title: "Look: focus_border, dim_inactive, minimap, strip_indicator_interactive", entries: [
            .init("focus_border", "Boolean, default false. Draw an outline around the focused window."),
            .init("focus_border_width", "Number in points, default 2. Range 1–12."),
            .init("focus_border_color", "Hex color string, default \"#F7A028\". Use six RGB or eight RGBA hex digits, with an optional #. Invalid colors make the file invalid."),
            .init("focus_border_radius", "Number in points, default 10. Range 0–40."),
            .init("dim_inactive", "Boolean, default false. Darken windows that do not have focus."),
            .init("dim_inactive_opacity", "Number, default 0.25. The settings control and engine use 0–0.9. Larger values make inactive windows darker."),
            .init("minimap", "Boolean, default true. Show a small strip overview during navigation. The Show Strip action works even when this is false."),
            .init("strip_indicator_interactive", "Boolean, default true. Hold the shortcut keys to keep the overview visible, click a window to focus it, or drag a tile to reorder."),
            .init("pin_indicator", "Boolean, default true. Show the pinned-column edge line and minimap marking. Turning it off does not unpin windows."),
            .init("pinned_color", "Hex RGB or RGBA string, default \"#4C9AFF\". Sets the pin indicator color."),
            .init("animation", "String, default \"smooth\" (222 ms). \"fast\" uses 140 ms and \"instant\" uses 0 ms. Unknown values use smooth."),
            .init("animation_duration_ms", "Optional number, unset by default. Set a duration from 0 to 2000 ms. Takes priority over animation_speed and animation."),
            .init("animation_speed", "Optional legacy number, unset by default. Despite its name, it is a duration in milliseconds, from 0 to 2000. Used when animation_duration_ms is absent."),
            .init("animation_damping", "Number, default 1.0. Multiplier for the exponential position decay rate, from 0.4 to 1.5. Larger values settle faster."),
            .init("use_skylight", "Boolean, default true. Use the fast macOS window-bounds lookup, with Accessibility as its fallback.")
        ]),
        HelpSettingsGroup(title: "Trackpad and displays: swipe_gesture_fingers, swipe_natural, drag_reorder, ignored_displays", entries: [
            .init("swipe_gesture_fingers", "Unsigned integer, default 4. Choose 0 for off, or 3, 4 or 5 fingers. Other unsigned integers use 4. Floating-point and negative values are invalid."),
            .init("swipe_natural", "Boolean, default true. Make the strip follow your fingers; false reverses it."),
            .init("swipe_sensitivity", "Number, default 1.6. Gesture travel multiplier, from 0.2 to 5.0."),
            .init("swipe_snap", "String, default \"snap\". \"free\" lets the strip stop where you leave it; other values select snap."),
            .init("drag_reorder", "Boolean, default true. Drag a tiled window across another column to change its position."),
            .init("scroll_modifier", "String, default \"ctrl + alt\". Hold exactly these modifiers while scrolling to move along the strip. Join ctrl, alt, shift or cmd with +. Option/opt/⌥, command/⌘, control/⌃ and ⇧ aliases are accepted. Use \"off\", \"none\" or \"false\" to disable."),
            .init("ignored_displays", "Array of display-ID strings, default []. Matching ignores surrounding spaces and letter case. Configure this in Configuration › Displays; use display identities, not display names or numeric screen IDs."),
            .init("continuous_swipe", "Boolean, default false. Extends the scroll limits so an endpoint can move to the opposite screen edge, leaving extra empty space. false keeps the strip within its usual edge limits. The nested swipe.continuous setting takes priority. This is separate from swipe_snap, which controls how motion settles.")
        ]),
        HelpSettingsGroup(title: "Shortcuts: the [bindings] table", entries: [
            .init("action = shortcut", "Use an action ID from the shortcut catalog. A shortcut is a string with modifiers joined by +, followed by - and a key. Modifiers are ctrl, alt (Option), shift and cmd. Key names include leftarrow, minus, equal and comma. Function keys can be used alone."),
            .init("Multiple shortcuts", "Use an array of strings for alternatives. They run the same action, independently. Remove an action's binding to leave it unbound. Shortcuts warns about keys that are already used.")
        ], example: "[bindings]\nwindow_focus_west = [\"ctrl + alt - leftarrow\", \"ctrl + alt - h\"]\nwindow_center = \"ctrl + alt - c\""),
        HelpSettingsGroup(title: "Window rules: [windows.<name>] tables", entries: [
            .init("[windows.<name>]", "Each table name identifies one rule. Use distinct rules that do not contradict each other; overlapping rules have no guaranteed order."),
            .init("title", "Regular-expression string. Use \".*\" for any title (the app supplies this default). Matching searches anywhere; ^ and $ match the ends. Look-around and back-references are not supported. Invalid expressions make the config invalid."),
            .init("bundle_id", "Optional string, no default restriction. Match this exact app bundle ID as well as the title, for example \"com.apple.Safari\"."),
            .init("floating", "Optional Boolean. true keeps matches out of the strip; false tiles them, including dialogs. Omit it to leave the normal floating decision unchanged."),
            .init("index", "Optional unsigned integer. The insertion column for a newly managed window: 0 is the first column, N is column N + 1. Omit for automatic placement next to the focused window. Values beyond the strip append."),
            .init("horizontal_padding", "File-only option: a nonnegative integer in points. Replaces the normal left/right gap for matching windows; omit to keep normal spacing."),
            .init("vertical_padding", "File-only option: a nonnegative integer in points. Replaces the top/bottom gap for matching windows; omit to keep normal spacing.")
        ], example: "[windows.safari]\ntitle = \".*\"\nbundle_id = \"com.apple.Safari\"\nfloating = false")
    ]
}
