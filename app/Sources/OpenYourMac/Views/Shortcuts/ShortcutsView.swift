import AppKit
import SwiftUI

struct ShortcutsView: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var recorder = ShortcutsRecorder()
    @AppStorage("shortcuts.legacyOptionBannerDismissed") private var migrationDismissed = false
    @State private var activeAlert: ShortcutsAlert?

    var body: some View {
        PageScaffold(title: "Keyboard Shortcuts", subtitle: "Click a shortcut and press the keys you want. Changes save by themselves.") {
            ConfigurationDiagnostics()
            if let error = recorder.error { ConfigurationInlineMessage(text: error, tint: Theme.danger) }
            instructions
            if !config.canCheckAllShortcutConflicts {
                Card(inset: 16) {
                    ConfigurationFileOnlyRow(keys: config.hasOpaqueBindingTable ? ["bindings"] : config.handEditedBindings.sorted())
                    InfoNote(text: "Record and migrate shortcuts after these entries use simple values. The app must read every binding to check conflicts.")
                }
            }
            if !migrationDismissed && hasOldDefaults { migrationBanner }
            ForEach(ShortcutGroup.allCases) { group in
                PageSection(group.title, caption: group.caption) {
                    Card(padding: EdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)) {
                        ForEach(ShortcutCatalog.actions(in: group)) { action in shortcutRow(action) }
                    }
                }
            }
            footer
        }
        .onDisappear { recorder.cancel() }
        .onChange(of: state.page) { _ in recorder.cancel() }
        .onChange(of: config.bindingStrings) { _ in recorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.cancel() }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .conflict(let candidate): return conflictAlert(candidate)
            case .reset:
                return Alert(title: Text("Reset every shortcut to the defaults?"),
                             message: Text("Your shortcuts will be replaced by the Control-Option defaults. Other settings and window rules stay as they are."),
                             primaryButton: .destructive(Text("Reset Shortcuts")) { reset() },
                             secondaryButton: .cancel())
            }
        }
    }

    private var instructions: some View {
        Card(inset: 16) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("How to Set Shortcuts").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Click a shortcut and press its new keys. Use + to add another shortcut, or Esc to cancel.\n\(AppPaths.appName) warns before you take keys used by macOS or another action.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    KeyCapRow(glyphs: ["⌃", "⌥", "⇧", "←"], size: 18, spacing: 3)
                    Text("Example").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        ShortcutsRowLayout {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(action.isDestructive ? Theme.danger : Theme.textPrimary)
                Text(action.subtitle).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if config.hasOpaqueBindingTable || config.handEditedBindings.contains(action.id) {
                Text("Hand-edited, edit in the file").font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    let shortcuts = config.bindingStrings[action.id] ?? []
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, raw in
                        let combo = KeyCombo(configString: raw).flatMap { $0.resolvedKeyCode == nil ? nil : $0 }
                        HStack(spacing: 2) {
                            captureButton(action, index: index, combo: combo, raw: raw)
                            Button {
                                recorder.cancel()
                                config.setCombo(nil, for: action.id, at: index)
                            } label: { Image(systemName: "xmark") }
                            .buttonStyle(IconButtonStyle())
                            .help("Remove this shortcut")
                            .accessibilityLabel("Remove \(combo?.displayString ?? raw) from \(action.title)")
                        }
                    }
                    if recorder.slot == .init(actionID: action.id, index: shortcuts.count) {
                        captureButton(action, index: shortcuts.count, combo: nil)
                    }
                    Button { begin(action, index: shortcuts.count) } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle())
                        .help("Add another shortcut for this action")
                        .accessibilityLabel("Add a shortcut for \(action.title)")
                        .disabled(!config.canCheckAllShortcutConflicts)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 66)
    }

    private func captureButton(_ action: ShortcutAction, index: Int, combo: KeyCombo?, raw: String? = nil) -> some View {
        let recording = recorder.slot == .init(actionID: action.id, index: index)
        let usedBy = combo.map { config.actions(using: $0, except: action.id) } ?? []
        let conflict = usedBy.isEmpty ? combo.flatMap { ShortcutsWarnings.reason(for: $0) }
            : "Also used by " + usedBy.map(\.title).joined(separator: ", ")
        return Button { begin(action, index: index) } label: {
            ShortcutCapsule(glyphs: combo?.glyphs ?? raw.map { ["Inactive: \($0)"] } ?? [], isRecording: recording,
                            isConflict: combo.map { !usedBy.isEmpty || ShortcutsWarnings.reason(for: $0) != nil } ?? (raw != nil),
                            isDestructive: action.isDestructive, prompt: recorder.prompt)
        }
        .buttonStyle(.plain)
        .disabled(!config.canCheckAllShortcutConflicts)
        .help(recording ? "Press the new keys, or Escape to cancel" : "Click to record a new shortcut")
        .accessibilityLabel("\(action.title): \(combo?.displayString ?? raw ?? "Add shortcut")")
        .accessibilityValue(recording ? recorder.prompt : (conflict ?? "Ready to record"))
        .accessibilityHint(recording ? (recorder.isReady ? "Press new keys. Escape cancels recording." : "Wait for the shortcut pause to finish.") : "Records a new shortcut")
    }

    private var hasOldDefaults: Bool {
        ShortcutCatalog.all.contains { hasOldDefaults($0) }
    }

    private func hasOldDefaults(_ action: ShortcutAction) -> Bool {
        config.bindingStrings[action.id]?.count == config.combos(for: action.id).count && ShortcutsMigration.matches(config.combos(for: action.id), for: action.id)
    }

    private var migrationBanner: some View {
        Card(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16), fill: Theme.warning.opacity(0.07), stroke: Theme.warning.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Switch to the newer shortcut set?").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Older Option shortcuts can move the text cursor or type special characters. The Control-Option set avoids those overlaps. Only actions that still have their old defaults will change; your custom shortcuts stay.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Switch to ⌃⌥ Shortcuts") {
                        recorder.cancel()
                        Task {
                            switch await config.migrateBindings() {
                            case .success(let skipped):
                                migrationDismissed = true
                                let names = skipped.compactMap { ShortcutCatalog.action($0)?.title }.joined(separator: ", ")
                                toasts.show(skipped.isEmpty ? "Switched unchanged shortcuts to Control-Option." : "Switched available shortcuts. Kept conflicts unchanged: \(names).", kind: skipped.isEmpty ? .success : .warning)
                            case .failure: break
                            }
                        }
                    }.buttonStyle(SecondaryButtonStyle()).disabled(!config.canCheckAllShortcutConflicts)
                    Button("Keep Mine") { migrationDismissed = true }.buttonStyle(LinkButtonStyle())
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Reload from Disk") { recorder.cancel(); config.reloadFromDisk() }
                .buttonStyle(SecondaryButtonStyle())
                .help("Pick up changes made to the settings file in a text editor")
            Spacer()
            Button("Reset to Defaults…") { recorder.cancel(); activeAlert = .reset }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func begin(_ action: ShortcutAction, index: Int) {
        recorder.begin(.init(actionID: action.id, index: index), engine: engine) { slot, combo in
            let candidate = PendingShortcut(slot: slot, combo: combo,
                                            original: config.bindingStrings,
                                            usedBy: config.actions(using: combo, except: slot.actionID),
                                            reason: ShortcutsWarnings.reason(for: combo))
            if !candidate.usedBy.isEmpty || candidate.reason != nil { activeAlert = .conflict(candidate) } else { commit(candidate) }
        }
    }

    private func conflictAlert(_ candidate: PendingShortcut) -> Alert {
        let names = candidate.usedBy.map(\.title).joined(separator: ", ")
        let title = candidate.usedBy.isEmpty ? "This shortcut is used by macOS" : "Already used by \(names)"
        let actionTitle = ShortcutCatalog.action(candidate.slot.actionID)?.title ?? "this action"
        var message = candidate.usedBy.isEmpty ? "\(candidate.combo.displayString):" : "\(candidate.combo.displayString) will move from \(names) to \(actionTitle)."
        if let reason = candidate.reason { message += "\n\n\(reason) This use will be unavailable while \(AppPaths.appName) runs." }
        return Alert(title: Text(title), message: Text(message), primaryButton: .default(Text(candidate.usedBy.isEmpty ? "Use Anyway" : "Use for \(actionTitle)")) { commit(candidate) }, secondaryButton: .cancel())
    }

    private func commit(_ candidate: PendingShortcut) {
        config.reassignCombo(candidate.combo, for: candidate.slot.actionID, at: candidate.slot.index, expected: candidate.original)
    }

    private func reset() {
        Task {
            if case .success = await config.resetBindingsToDefaults().value {
                toasts.show("Shortcuts reset to defaults.", kind: .success)
            }
        }
    }
}

/// Reserve room for the label while extra alternatives wrap on the right.
struct ShortcutsRowLayout: Layout {
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 675
        let sizes = measure(width: width, subviews: subviews)
        return CGSize(width: width, height: max(sizes.label.height, sizes.keys.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let sizes = measure(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - sizes.label.height / 2),
                          proposal: ProposedViewSize(sizes.label))
        subviews[1].place(at: CGPoint(x: bounds.maxX - sizes.keys.width, y: bounds.midY - sizes.keys.height / 2),
                          proposal: ProposedViewSize(sizes.keys))
    }

    private func measure(width: CGFloat, subviews: Subviews) -> (label: CGSize, keys: CGSize) {
        guard subviews.count == 2 else { return (.zero, .zero) }
        let labelMinimum = min(210, width * 0.45)
        let keys = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - labelMinimum - spacing), height: nil))
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - keys.width - spacing), height: nil))
        return (label, keys)
    }
}

private struct PendingShortcut: Identifiable {
    let id = UUID()
    let slot: ShortcutsRecorder.Slot
    let combo: KeyCombo
    let original: [String: [String]]
    let usedBy: [ShortcutAction]
    let reason: String?
}

private enum ShortcutsAlert: Identifiable {
    case reset
    case conflict(PendingShortcut)

    var id: String {
        switch self {
        case .reset: return "reset"
        case .conflict(let candidate): return candidate.id.uuidString
        }
    }
}
