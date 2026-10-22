import SwiftUI

struct PresetWidthsEditor: View {
    @EnvironmentObject private var config: ConfigStore
    @State private var editingWidth: Int?
    @State private var addingWidth = false

    var body: some View {
        PageSection("Preset Window Widths", caption: "Define the sizes to cycle through when resizing") {
            Card(padding: EdgeInsets(top: 16, leading: Theme.cardPadding, bottom: 14, trailing: Theme.cardPadding)) {
                FlowLayout(spacing: 8) {
                    ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                        Chip("") {
                            HStack(spacing: 4) {
                                Button("\(percentage(width))%") { editingWidth = index }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Change \(percentage(width)) percent width")
                                Button { remove(index) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.plain)
                                .disabled(widths.count <= 1)
                                .opacity(widths.count <= 1 ? 0.35 : 1)
                                .accessibilityLabel("Remove \(percentage(width)) percent width")
                            }
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .padding(.leading, -4)
                        }
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1))
                        .popover(isPresented: showing(index), arrowEdge: .bottom) {
                            ConfigurationWidthPopover(original: percentage(width), existing: widths.enumerated().filter { $0.offset != index }.map { percentage($0.element) }) { value in
                                replace(index, with: Double(value) / 100)
                                editingWidth = nil
                            } onCancel: { editingWidth = nil }
                        }
                    }
                    Button { addingWidth = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.accentSofter))
                            .overlay(Circle().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a preset width")
                    .popover(isPresented: $addingWidth, arrowEdge: .bottom) {
                        ConfigurationWidthPopover(original: nil, existing: widths.map(percentage)) { value in
                            store(widths + [Double(value) / 100])
                            addingWidth = false
                        } onCancel: { addingWidth = false }
                    }
                }
                InfoNote(text: "Percentages of the screen width. Click one to change it, or + to add one. Press the Resize shortcut to cycle through them.")
                    .padding(.top, 12)
            }
            .configOptions([\.presetColumnWidths])
        }
    }

    private var source: [Double] { config.options.presetColumnWidths }
    private var validIndices: [Int] { source.indices.filter { source[$0].isFinite && source[$0] > 0.05 && source[$0] <= 1 } }
    private var widths: [Double] { validIndices.isEmpty ? ConfigOptions().presetColumnWidths : validIndices.map { source[$0] } }
    private func percentage(_ value: Double) -> String { (value * 100).formatted(.number.precision(.fractionLength(0...8))) }

    private func showing(_ index: Int) -> Binding<Bool> {
        Binding(get: { editingWidth == index }, set: { if !$0 { editingWidth = nil } })
    }

    private func replace(_ index: Int, with value: Double) {
        var values = validIndices.isEmpty ? widths : source
        values[validIndices.isEmpty ? index : validIndices[index]] = value
        config.setPresetWidths(values, expected: source)
    }

    private func remove(_ index: Int) {
        guard widths.count > 1 else { return }
        var values = validIndices.isEmpty ? widths : source
        values.remove(at: validIndices.isEmpty ? index : validIndices[index])
        config.setPresetWidths(values, expected: source)
    }

    private func store(_ values: [Double]) {
        // Add only the new entry. Do not round, sort, or discard untouched source entries.
        let appended = values.dropFirst(widths.count)
        config.setPresetWidths((validIndices.isEmpty ? widths : source) + appended, expected: source)
    }
}

private struct ConfigurationWidthPopover: View {
    let original: String?
    let existing: [String]
    let onSave: (Int) -> Void
    let onCancel: () -> Void
    @State private var draft: String
    @FocusState private var fieldFocused: Bool

    init(original: String?, existing: [String], onSave: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        let suggestion = [40, 60, 80, 90, 100].first { !existing.contains(String($0)) }
            ?? (6...100).first { !existing.contains(String($0)) } ?? 40
        _draft = State(initialValue: original ?? String(suggestion))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "Add a width" : "Change width")
                .font(Theme.Font.rowTitleEmphasis)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                TextField("40", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .focused($fieldFocused)
                    .accessibilityLabel("Width percentage")
                    .onSubmit { save() }
                Text("% of the screen")
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(Theme.textSecondary)
                Stepper("Width percentage", value: stepperValue, in: 6...100)
                    .labelsHidden()
            }
            if let validation {
                Text(validation)
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil)
                    .opacity(validation != nil ? 0.45 : 1)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { fieldFocused = true }
    }

    private var value: Int? {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("%") { text.removeLast() }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var validation: String? {
        if draft == original { return nil }
        guard let value else { return "Type a whole number, like 40" }
        guard (6...100).contains(value) else { return "Pick a width from 6% to 100%" }
        if existing.contains(where: { Double($0) == Double(value) }) { return "\(value)% is already a preset" }
        return nil
    }

    private var stepperValue: Binding<Int> {
        Binding(get: { max(6, min(value ?? 40, 100)) }, set: { draft = String($0) })
    }

    private func save() {
        if draft == original { onCancel(); return }
        guard validation == nil, let value else { return }
        onSave(value)
    }
}
