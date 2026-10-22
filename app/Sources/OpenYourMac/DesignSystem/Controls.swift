import SwiftUI

// MARK: - Setting rows

/// Label on the left, switch on the right. Vertical padding matches the
/// other setting rows so they line up inside one card.
struct SettingToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.regular)
        }
        .padding(.vertical, 12)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// Label on the left, segmented control on the right.
struct SettingPickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var pickerWidth: CGFloat? = nil
    var usesMenu = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            if usesMenu {
                Picker(title, selection: $selection) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].label).tag(options[index].value)
                    }
                }
                .labelsHidden()
                .frame(width: pickerWidth)
            } else {
                SegmentedPicker(title: title, options: options, selection: $selection)
                    .frame(width: pickerWidth)
            }
        }
        .padding(.vertical, 12)
    }
}

/// Native segmented control with our labels.
struct SegmentedPicker<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].label).tag(options[index].value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A pending login registration can be disabled while macOS awaits approval.
struct LoginItemSettingRow: View {
    @EnvironmentObject private var loginItem: LoginItemManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingToggleRow(
                title: "Launch at Login",
                subtitle: loginItem.requiresApproval
                    ? "Requires approval in System Settings before the app can open at login"
                    : "Open \(AppPaths.appName) in the menu bar when you log in",
                isOn: Binding(get: { loginItem.isRegistered }, set: { loginItem.setEnabled($0) })
            )
            if loginItem.requiresApproval {
                Button("Open Login Items Settings") { loginItem.openSettings() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.bottom, 12)
            }
        }
    }
}

/// Title and value on one line, a ticked slider underneath.
struct SettingSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var disabled = false
    var onEditingEnded: () -> Void = {}
    @EnvironmentObject private var config: ConfigStore

    private var isCustom: Bool { !range.contains(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(isCustom ? "Custom value: \(format(value))" : format(value))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            if isCustom {
                Text("This file value is outside this control's range. Edit it in the file.")
                    .font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary)
                Button("Open in editor") { config.openInEditor() }.buttonStyle(LinkButtonStyle())
            } else {
                StepSlider(value: $value, range: range, step: step, onEditingEnded: onEditingEnded)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
            }
        }
        .padding(.vertical, 8)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Slider with a filled track, a white pill knob, and step dots underneath.
/// Snaps to `step`; click anywhere on the track to jump; arrow keys and
/// VoiceOver adjust by one step.
struct StepSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var onEditingEnded: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private let trackHeight: CGFloat = 6
    private let knobSize = CGSize(width: 22, height: 14)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usable = max(width - knobSize.width, 1)
            let x = CGFloat(fraction) * usable
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)
                    .offset(y: (knobSize.height - trackHeight) / 2)
                Capsule()
                    .fill(Color.primary.opacity(isEnabled ? 0.32 : 0.18))
                    .frame(width: x + knobSize.width / 2, height: trackHeight)
                    .offset(y: (knobSize.height - trackHeight) / 2)
                dots(usable: usable)
                    .offset(x: knobSize.width / 2, y: knobSize.height + 4)
                Capsule()
                    .fill(Color.white)
                    .frame(width: knobSize.width, height: knobSize.height)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = (drag.location.x - knobSize.width / 2) / usable
                        set(fraction: Double(min(max(f, 0), 1)))
                    }
                    .onEnded { _ in onEditingEnded() }
            )
        }
        .frame(height: knobSize.height + 8)
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: nudge(-1)
            case .right, .up: nudge(1)
            default: break
            }
        }
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double { (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span }

    private func set(fraction f: Double) {
        let raw = range.lowerBound + f * span
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }

    private func nudge(_ steps: Double) {
        let next = min(max(value + steps * (step > 0 ? step : span / 20), range.lowerBound), range.upperBound)
        if next != value { value = next }
    }

    /// Up to ~33 evenly spaced dots, one per step when that is few enough.
    private func dots(usable: CGFloat) -> some View {
        let steps = step > 0 ? Int((span / step).rounded()) : 10
        let stride = max(1, Int((Double(steps) / 32).rounded(.up)))
        let count = steps / stride
        return ZStack(alignment: .leading) {
            ForEach(0...max(count, 1), id: \.self) { i in
                Circle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 2, height: 2)
                    .offset(x: count == 0 ? 0 : usable * CGFloat(i) / CGFloat(count) - 1)
            }
        }
        .frame(width: usable, alignment: .leading)
    }
}

// MARK: - Buttons

/// Filled neutral button (the grey "Stop", "Check for Updates…" buttons).
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Theme.neutralButtonFillPressed : Theme.neutralButtonFill)
            )
            .contentShape(Rectangle())
    }
}

/// Filled accent button for the main call to action.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 9 : 6)
            .background(
                RoundedRectangle(cornerRadius: large ? 8 : 6, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// Text-only accent button ("Got It", "Show All URLs").
struct LinkButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

/// Accent-tinted pill with an outline ("Paneru on GitHub", "Report Issue").
struct TintedButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(color.opacity(0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// Small borderless glyph button (× and + next to shortcuts).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 20
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary.opacity(configuration.isPressed ? 0.5 : 1))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }
}

/// Raised tile that brightens on hover and darkens when pressed.
struct TileButtonStyle: ButtonStyle {
    var radius: CGFloat = Theme.tileRadius
    /// Flat tiles have no fill until hovered (Overview quick actions).
    var flat = false
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, radius: radius, flat: flat)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        let flat: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(configuration.isPressed ? Theme.tileFillPressed : (hovering ? Theme.tileFillHover : (flat ? Color.clear : Theme.tileFill)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(flat ? Theme.cardStroke.opacity(1.4) : Theme.tileStroke, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Status

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Small card with a caption, a value, and a status dot (Overview).
struct StatusCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                StatusDot(color: color)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}

// MARK: - Key caps

/// One key cap: ⌃ ⌥ ⇧ ⌘ ← → or a letter.
struct KeyCap: View {
    let glyph: String
    var size: CGFloat = 20

    var body: some View {
        Text(glyph)
            .font(Theme.Font.keyCap)
            .foregroundStyle(Theme.textPrimary)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, glyph.count > 1 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.keyCapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.keyCapStroke, lineWidth: 1)
            )
    }
}

/// A row of key caps for one shortcut.
struct KeyCapRow: View {
    let glyphs: [String]
    var size: CGFloat = 20
    var spacing: CGFloat = 3

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                KeyCap(glyph: glyph, size: size)
            }
        }
    }
}

// MARK: - Icon disc

/// Circular accent disc holding an SF Symbol (tiles, feature rows).
struct IconDisc: View {
    let systemImage: String
    var diameter: CGFloat = 44
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.40, weight: .regular))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Chips

/// Accent chip with an optional trailing remove button (preset widths).
struct Chip<Trailing: View>: View {
    let text: String
    var tint: Color = Theme.accent
    @ViewBuilder var trailing: () -> Trailing

    init(_ text: String, tint: Color = Theme.accent, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.tint = tint
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            trailing()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// Quiet grey badge with an optional glyph (window rule summaries).
struct Badge: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9))
            }
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.tileFill))
    }
}

// MARK: - Checks

enum CheckState: Equatable {
    case pass, fail, warning, unknown
}

/// Round status glyph for checklists.
struct CheckGlyph: View {
    let state: CheckState
    var size: CGFloat = 18

    var body: some View {
        switch state {
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black.opacity(0.85), Theme.success)
                .font(.system(size: size))
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Theme.danger)
                .font(.system(size: size))
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black.opacity(0.8), Theme.warning)
                .font(.system(size: size))
        case .unknown:
            Image(systemName: "circle.dashed")
                .foregroundStyle(Theme.textTertiary)
                .font(.system(size: size))
        }
    }
}

// MARK: - Disclosure rows (FAQ)

/// Raised row with a chevron that expands to show an answer.
struct DisclosureRow<Answer: View>: View {
    let title: String
    @ViewBuilder var answer: () -> Answer
    @State private var expanded = false

    init(_ title: String, expanded: Bool = false, @ViewBuilder answer: @escaping () -> Answer) {
        self.title = title
        self.answer = answer
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the answer" : "Shows the answer")

            if expanded {
                answer()
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tileFill)
        )
    }
}

// MARK: - Copyable command

/// Monospaced command line with a Copy button (Integrations).
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(command)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(LinkButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tileFill))
    }
}

// MARK: - Shortcut capsule

/// Bordered capsule that shows one shortcut's key caps (Shortcuts page).
/// `isRecording` swaps the caps for a prompt with an accent outline.
/// `isConflict` tints the outline red. `isDestructive` tints it for Quit.
struct ShortcutCapsule: View {
    let glyphs: [String]
    var isRecording = false
    var isConflict = false
    var isDestructive = false
    var prompt = "Press keys…"
    @State private var hovering = false

    var body: some View {
        Group {
            if isRecording {
                Text(prompt)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 72)
                    .padding(.vertical, 2)
            } else {
                KeyCapRow(glyphs: glyphs, size: 20, spacing: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isRecording ? Theme.accent.opacity(0.10) : Color.primary.opacity(hovering ? 0.05 : 0.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(outline, lineWidth: isRecording || isConflict ? 1.5 : 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isRecording)
    }

    private var outline: Color {
        if isRecording { return Theme.accent }
        if isConflict { return Theme.danger.opacity(0.8) }
        if isDestructive { return Theme.danger.opacity(0.35) }
        return Color.primary.opacity(hovering ? 0.22 : 0.14)
    }
}
