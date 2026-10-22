import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WindowRuleEditorSheet: View {
    let rule: WindowRule?
    let onClose: () -> Void
    @EnvironmentObject private var config: ConfigStore
    @State private var bundleID: String?
    @State private var appName: String?
    @State private var titleMode: ConfigurationTitleMode
    @State private var containsText: String
    @State private var patternText: String
    @State private var floating: WindowRule.Floating
    @State private var placementMode: ConfigurationPlacementMode
    @State private var column: Int
    @State private var runningApps: [ConfigurationRuleApp] = []
    @State private var appError: String?
    @State private var confirmingDelete = false
    @State private var confirmingAllWindows = false
    @State private var saveError: ConfigError?
    @State private var isSaving = false

    init(rule: WindowRule?, onClose: @escaping () -> Void) {
        self.rule = rule
        self.onClose = onClose
        _bundleID = State(initialValue: rule?.bundleID)
        _appName = State(initialValue: rule?.appName)
        _floating = State(initialValue: rule?.floating ?? .automatic)
        switch rule?.titleMatch ?? .any {
        case .any:
            _titleMode = State(initialValue: .any)
            _containsText = State(initialValue: "")
            _patternText = State(initialValue: ".*")
        case .contains(let text):
            _titleMode = State(initialValue: .contains)
            _containsText = State(initialValue: text)
            _patternText = State(initialValue: NSRegularExpression.escapedPattern(for: text))
        case .pattern(let text):
            _titleMode = State(initialValue: .pattern)
            _containsText = State(initialValue: "")
            _patternText = State(initialValue: text)
        }
        switch rule?.placement ?? .automatic {
        case .automatic:
            _placementMode = State(initialValue: .automatic)
            _column = State(initialValue: 1)
        case .start:
            _placementMode = State(initialValue: .start)
            _column = State(initialValue: 1)
        case .end:
            _placementMode = State(initialValue: .end)
            _column = State(initialValue: 1)
        case .column(let index):
            _placementMode = State(initialValue: .column)
            _column = State(initialValue: index)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(rule == nil ? "Add Window Rule" : "Edit Window Rule")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Close")
            }
            if let saveError { ConfigurationErrorCard(error: saveError) }
            PageSection("Which windows") {
                Card {
                    appRow
                    CardDivider()
                    titleRows
                }
            }
            PageSection("What happens") {
                Card {
                    SettingPickerRow(title: "Floating", subtitle: "Automatic uses normal rules. Tile forces tiling, including dialogs. Float keeps windows out of the strip.", options: WindowRule.Floating.allCases.map { ($0, $0.rawValue) }, selection: $floating, pickerWidth: 220)
                    CardDivider()
                    placementRows
                }
            }
            if appliesToEveryWindow {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                    Text("No app or title limit is set: this rule will apply to every window of every app.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.Font.rowSubtitle)
            }
            footer
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.contentBackground)
        .disabled(isSaving)
        .onAppear { runningApps = ConfigurationRuleApp.running }
        .alert("Delete this rule?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let rule else { return }
                isSaving = true
                Task { finish(await config.deleteRule(id: rule.id)) }
            }
        } message: {
            Text("Windows matched by this rule will return to their normal behavior.")
        }
        .alert("Apply this rule to every window?", isPresented: $confirmingAllWindows) {
            Button("Cancel", role: .cancel) {}
            Button("Save Anyway") { save() }
        } message: {
            Text("No app is selected and the title matches everything. This rule will apply to every window of every app.")
        }
    }

    private var appRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                RowLabel(title: "App")
                Menu {
                    Button("Any app") { bundleID = nil; appName = nil; appError = nil }
                    Divider()
                    ForEach(runningApps) { app in
                        Button { select(app) } label: {
                            HStack {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                Text("\(app.name) (\(app.bundleID))")
                            }
                        }
                    }
                    Divider()
                    Button("Choose…") { chooseApp() }
                } label: {
                    HStack(spacing: 6) {
                        if let icon = selectedApp?.icon {
                            Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                        }
                        Text(selectedAppName).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 245, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("App for this rule")
            }
            if let bundleID {
                Text(bundleID)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            Text("Choose the app this rule is for.")
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(Theme.textTertiary)
            if let appError {
                Text(appError).font(Theme.Font.rowSubtitle).foregroundStyle(Theme.danger)
            }
        }
        .padding(.vertical, 12)
    }

    private var titleRows: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingPickerRow(
                title: "Title", options: ConfigurationTitleMode.allCases.map { ($0, $0.rawValue) },
                selection: titleModeSelection, pickerWidth: 280
            )
            .padding(.vertical, -8)
            if titleMode != .any {
                TextField(titleMode == .pattern ? "Title pattern" : "Leave empty for all its windows", text: titleText)
                    .textFieldStyle(.roundedBorder)
                    .font(titleMode == .pattern ? Theme.Font.mono : Theme.Font.rowTitle)
                    .accessibilityLabel(titleMode == .pattern ? "Title pattern" : "Window title contains")
            }
            Text(titleMode == .pattern ? "Title pattern (regular expression, matched anywhere in the title)" : "Leave empty for all its windows")
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let patternError {
                Text(patternError)
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    private var placementRows: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                RowLabel(title: "Placement")
                Picker("Placement", selection: $placementMode) {
                    ForEach(ConfigurationPlacementMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            if placementMode == .column {
                Stepper("Column \(column)", value: $column, in: columnRange)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("Always open at column")
            }
            Text("Where new windows like this join the strip. Automatic puts them next to the window you're using.")
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .disabled(floating == .float)
        .opacity(floating == .float ? 0.45 : 1)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if rule != nil {
                Button("Delete", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(LinkButtonStyle(color: Theme.danger))
            }
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                if appliesToEveryWindow { confirmingAllWindows = true } else { save() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(patternError != nil)
            .opacity(patternError != nil ? 0.45 : 1)
        }
    }

    private var selectedApp: ConfigurationRuleApp? {
        guard let bundleID else { return nil }
        return runningApps.first { $0.bundleID == bundleID } ?? ConfigurationRuleApp.resolve(bundleID: bundleID)
    }

    private var selectedAppName: String { selectedApp?.name ?? appName ?? bundleID ?? "Any app" }

    private var titleText: Binding<String> {
        titleMode == .pattern ? $patternText : $containsText
    }

    private var titleModeSelection: Binding<ConfigurationTitleMode> {
        Binding(get: { titleMode }, set: { mode in
            if mode == .pattern && titleMode == .contains {
                patternText = NSRegularExpression.escapedPattern(for: containsText)
            } else if mode == .contains && titleMode == .pattern,
                      case .contains(let literal) = WindowRule.TitleMatch(regex: patternText) {
                containsText = literal
            }
            titleMode = mode
        })
    }

    private var columnRange: ClosedRange<Int> {
        if case .column(let existing) = rule?.placement { return 1...max(20, existing) }
        return 1...20
    }

    private var titleMatch: WindowRule.TitleMatch {
        switch titleMode {
        case .any: return .any
        case .contains: return containsText.isEmpty ? .any : .contains(containsText)
        case .pattern: return .pattern(patternText)
        }
    }

    private var patternError: String? {
        titleMode == .pattern ? WindowRule.validatePattern(patternText, checkSyntax: !FileManager.default.isExecutableFile(atPath: AppPaths.engineBinary.path)) : nil
    }

    private var appliesToEveryWindow: Bool {
        guard bundleID == nil, let regex = try? NSRegularExpression(pattern: titleMatch.regex) else { return false }
        // Matching anywhere includes zero-length matches. Check empty and nonempty titles,
        // so an empty-title-only pattern such as ^$ is not treated as universal.
        return ["", "A window title", "123", "\n", "🪟"].allSatisfy { title in
            regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
        }
    }

    private var placement: WindowRule.Placement {
        switch placementMode {
        case .automatic: return .automatic
        case .start: return .start
        case .end: return .end
        case .column: return .column(column)
        }
    }

    private func save() {
        guard patternError == nil else { return }
        let resolvedName = bundleID == nil ? nil : selectedAppName
        let updated = WindowRule(
            id: rule?.id ?? config.uniqueRuleID(base: resolvedName ?? "rule"),
            bundleID: bundleID, appName: resolvedName,
            titleMatch: titleMatch, floating: floating, placement: placement
        )
        guard !isSaving else { return }
        isSaving = true
        Task { finish(await config.saveRule(updated)) }
    }

    private func finish(_ result: Result<Void, ConfigError>) {
        isSaving = false
        switch result {
        case .success: onClose()
        case .failure(let error): saveError = error
        }
    }

    private func select(_ app: ConfigurationRuleApp) {
        bundleID = app.bundleID
        appName = app.name
        appError = nil
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else {
                appError = "This app has no bundle identifier. Choose another app."
                return
            }
            select(ConfigurationRuleApp(bundleID: id, name: ConfigurationRuleApp.displayName(at: url), icon: NSWorkspace.shared.icon(forFile: url.path)))
        }
    }
}

private enum ConfigurationTitleMode: String, CaseIterable {
    case any = "Any title", contains = "Contains", pattern = "Pattern"
}

private enum ConfigurationPlacementMode: String, CaseIterable {
    case automatic = "Automatic"
    case start = "Start of the strip"
    case end = "End of the strip"
    case column = "Always open at column N"
}
