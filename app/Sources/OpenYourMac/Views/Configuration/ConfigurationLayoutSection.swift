import SwiftUI

struct ConfigurationLayoutSection: View {
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        PageSection("Layout", caption: "Spacing and how the strip positions your windows") {
            Card {
                SettingSliderRow(title: "Gap Between Windows", value: config.debouncedBinding(\.gapInner), range: 0...64, step: 0.5, format: { "\($0.formatted()) pt" }, onEditingEnded: config.flushPendingOptions)
                SettingSliderRow(title: "Gap at Screen Edges", value: config.debouncedBinding(\.gapOuter), range: 0...64, step: 0.5, format: { "\($0.formatted()) pt" }, onEditingEnded: config.flushPendingOptions)
                CardDivider()
                SettingToggleRow(title: "Keep Clear of the Dock", subtitle: "Tile windows inside the area the Dock leaves free", isOn: config.binding(\.dockAware))
                CardDivider()
                SettingToggleRow(
                    title: "Keep Original Height",
                    subtitle: "Keep each window's opening height instead of filling the screen. Stacked windows still share their column.",
                    isOn: config.binding(\.keepWindowHeight)
                )
                CardDivider()
                SettingPickerRow(
                    title: "Center Focused Column",
                    subtitle: config.options.centerFocusedColumn.explanation,
                    options: CenterMode.allCases.map { ($0, $0.label) },
                    selection: config.binding(\.centerFocusedColumn),
                    pickerWidth: 300
                )
            }
            .configOptions([\.gapInner, \.gapOuter, \.dockAware, \.centerFocusedColumn, \.keepWindowHeight])
        }
    }
}

struct ConfigurationBehaviorSection: View {
    @EnvironmentObject private var config: ConfigStore

    var body: some View {
        PageSection("Behavior", caption: "Focus handling and what is remembered between sessions") {
            Card {
                SettingToggleRow(title: "Restore Layout After Restart", subtitle: "Remember column order and widths when the window manager restarts", isOn: config.binding(\.sessionRestore))
                CardDivider()
                SettingToggleRow(title: "Native Tabs as One Column", subtitle: "Finder, Terminal, TextEdit… tabs share one column. Only the tab in front is tiled.", isOn: config.binding(\.nativeTabs))
                CardDivider()
                SettingToggleRow(title: "Float Dialogs and Previews", subtitle: "Keep dialogs, Quick Look and image previews above the strip instead of making them columns", isOn: config.binding(\.floatDialogs))
                CardDivider()
                SettingToggleRow(title: "Focus Follows Mouse", subtitle: "Hover over a window to focus it without a click", isOn: config.binding(\.focusFollowsMouse))
                CardDivider()
                SettingToggleRow(title: "Mouse Follows Focus", subtitle: "Move the pointer to the window you switch to", isOn: config.binding(\.mouseFollowsFocus))
            }
            .configOptions([\.sessionRestore, \.nativeTabs, \.floatDialogs, \.focusFollowsMouse, \.mouseFollowsFocus])
        }
    }
}
