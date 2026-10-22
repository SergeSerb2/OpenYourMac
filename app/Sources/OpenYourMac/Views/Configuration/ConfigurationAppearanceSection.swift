import SwiftUI

struct ConfigurationAppearanceSection: View {
    @EnvironmentObject private var config: ConfigStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PageSection("Appearance", caption: "How windows move, and how to spot the focused one") {
            Card {
                SettingPickerRow(
                    title: "Animation", subtitle: config.options.animation == .custom ? "Windows move over \(config.options.animationDurationMS.formatted()) ms" : config.options.animation.explanation,
                    options: AnimationStyle.allCases.filter { $0 != .custom || config.options.animation == .custom }.map { ($0, $0.label) },
                    selection: config.binding(\.animation), pickerWidth: 212
                )
                CardDivider()
                SettingToggleRow(title: "Focus Border", subtitle: "Draw a border around the focused window", isOn: config.binding(\.focusBorder))
                ConfigurationBorderColorRow(colorHex: config.debouncedBinding(\.focusBorderColor), disabled: !config.options.focusBorder)
                SettingSliderRow(
                    title: "Border Width", value: config.debouncedBinding(\.focusBorderWidth),
                    range: 1...12, step: 0.5, format: { "\($0.formatted()) pt" }, disabled: !config.options.focusBorder, onEditingEnded: config.flushPendingOptions
                )
                SettingSliderRow(
                    title: "Corner Radius", value: config.debouncedBinding(\.focusBorderRadius),
                    range: 0...40, step: 0.5, format: { "\($0.formatted()) pt" }, disabled: !config.options.focusBorder, onEditingEnded: config.flushPendingOptions
                )
                CardDivider()
                SettingToggleRow(title: config.usesNativeBrightness ? "Inactive Window Brightness" : "Dim Inactive Windows",
                                 subtitle: config.usesNativeBrightness ? "Legacy native brightness in \(colorScheme == .dark ? "dark" : "light") appearance; changing it updates the legacy key" : "Darken every window except the focused one",
                                 isOn: Binding(get: { config.usesNativeBrightness ? config.inactiveOpacity(dark: colorScheme == .dark) != 0 : config.options.dimInactive },
                                               set: { config.set(\.dimInactive, $0, darkAppearance: colorScheme == .dark) }))
                SettingSliderRow(
                    title: config.usesNativeBrightness ? "Brightness" : "Dim Strength",
                    value: Binding(get: { config.inactiveOpacity(dark: colorScheme == .dark) },
                                   set: { config.debouncedBinding(\.dimInactiveOpacity, darkAppearance: colorScheme == .dark).wrappedValue = $0 }),
                    range: 0...(config.hasLegacyDimming ? 1 : 0.9), step: 0.05,
                    format: { ($0 * 100).formatted(.number.precision(.fractionLength(0...2))) + "%" }, disabled: config.usesNativeBrightness ? config.inactiveOpacity(dark: colorScheme == .dark) == 0 : !config.options.dimInactive, onEditingEnded: config.flushPendingOptions
                )
                CardDivider()
                SettingToggleRow(title: "Strip Minimap", subtitle: "Show an overview while you navigate; the Show Strip shortcut works either way", isOn: config.binding(\.minimap))
                CardDivider()
                SettingToggleRow(title: "Interactive Minimap", subtitle: "Hold the shortcut keys to keep it open. Click a window to focus it, or drag to reorder.", isOn: config.binding(\.stripIndicatorInteractive))
                CardDivider()
                SettingToggleRow(title: "Pin Indicator", subtitle: "Mark pinned columns with an indicator line and a pin in the minimap", isOn: config.binding(\.pinIndicator))
            }
            .configOptions([\.animation, \.focusBorder, \.focusBorderWidth, \.focusBorderColor, \.focusBorderRadius, \.dimInactive, \.dimInactiveOpacity, \.minimap, \.stripIndicatorInteractive, \.pinIndicator])
        }
    }
}

private struct ConfigurationBorderColorRow: View {
    @Binding var colorHex: String
    let disabled: Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                RowLabel(title: "Border Color")
                TextField("#RRGGBBAA", text: Binding(get: { draft }, set: {
                    draft = $0
                    commitDraft()
                }))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .frame(width: 96)
                    .accessibilityLabel("Border color hex value")
                    .onSubmit { commitDraft() }
                ColorPicker("Border Color", selection: pickerColor, supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 46)
                    .accessibilityLabel("Choose border color")
            }
            if !draft.isEmpty && BorderRGBA.color(draft) == nil {
                Text("Enter six or eight hex digits, like #F7A028 or #FF000080")
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.vertical, 6)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onAppear { draft = colorHex }
        .onChange(of: colorHex) { draft = $0 }
    }

    private var pickerColor: Binding<Color> {
        Binding(get: { BorderRGBA.color(colorHex) ?? Theme.accent }, set: { colorHex = BorderRGBA.hex($0, keepAlpha: BorderRGBA.hasAlpha(colorHex)) })
    }

    private func commitDraft() {
        guard let color = BorderRGBA.color(draft) else { return }
        let normalized = BorderRGBA.hex(color, keepAlpha: BorderRGBA.hasAlpha(draft))
        if colorHex != normalized { colorHex = normalized }
    }
}

private enum BorderRGBA {
    private static func digits(_ input: String) -> String {
        String(input.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" }))
    }

    static func hasAlpha(_ input: String) -> Bool { digits(input).count == 8 }

    static func color(_ input: String) -> Color? {
        let hex = digits(input)
        guard [6, 8].contains(hex.utf8.count), hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(hex, radix: 16) else { return nil }
        let rgb = hex.count == 8 ? value >> 8 : value
        let alpha = hex.count == 8 ? CGFloat(value & 255) / 255 : 1
        return Color(nsColor: NSColor(hex: rgb, alpha: alpha))
    }

    static func hex(_ color: Color, keepAlpha: Bool) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let alpha = Int((c.alphaComponent * 255).rounded())
        return color.hexString + (keepAlpha || alpha < 255 ? String(format: "%02X", alpha) : "")
    }
}
