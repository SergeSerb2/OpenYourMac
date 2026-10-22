import AppKit
import SwiftUI
import Darwin

struct ConfigError: Error, Equatable, LocalizedError {
    var message: String
    var line: Int?

    var errorDescription: String? { line.map { "\(message) (line \($0))" } ?? message }
}

@MainActor
final class ConfigStore: ObservableObject {
    let fileURL: URL
    @Published private(set) var options = ConfigOptions()
    @Published private(set) var bindings: [String: [KeyCombo]] = [:]
    @Published private(set) var bindingStrings: [String: [String]] = [:]
    @Published private(set) var rules: [WindowRule] = []
    @Published private(set) var lastError: ConfigError?
    @Published private(set) var warnings: [ConfigError] = []
    @Published private(set) var engineBindingWarnings: [ConfigError] = []
    @Published private(set) var handEditedOptions: [String] = []
    @Published private(set) var handEditedBindings: Set<String> = []
    @Published private(set) var hasOpaqueBindingTable = false

    var canCheckAllShortcutConflicts: Bool { handEditedBindings.isEmpty && !hasOpaqueBindingTable }

    func handEditedKeys(_ paths: [PartialKeyPath<ConfigOptions>]) -> [String] {
        paths.compactMap { ConfigOptions.tomlKeys[$0] }.filter { handEditedOptions.contains($0) }.sorted()
    }

    @Published private(set) var isValidating = false
    @Published private(set) var optionOverrides: [OptionOverride] = []
    @Published var pendingOverrideEdit: PendingOptionOverride?
    private var saveFailure: ConfigError?
    private var writeTask: Task<Result<URL?, ConfigError>, Never>?

    private var document = ConfigDocument("")
    /// The bytes `document` was read from or last written as.
    private var loadedData: Data?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var validationTask: Task<Void, Never>?
    private var validationGeneration = 0
    private var pendingOptions: [PartialKeyPath<ConfigOptions>: ConfigDocument.Value] = [:]
    private var optionSaveWork: DispatchWorkItem?

    init(fileURL: URL = AppPaths.configFile) {
        self.fileURL = fileURL
        do {
            if AppPaths.isSnapshot {
                let data = try Self.defaultData()
                document = try Self.decode(data)
                loadedData = data
                parseDocument()
                validate()
                return
            }
            let isNew = !FileManager.default.fileExists(atPath: fileURL.path)
            if isNew {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let defaults = try Self.decode(Self.defaultData())
                document = defaults
                parseDocument()
                enqueueEdit(allowMissing: true) { $0 = defaults }
            } else {
                reloadFromDisk()
            }
            startWatching()
        } catch {
            lastError = Self.configError(from: error)
        }
    }

    deinit {
        fileWatch?.cancel()
        directoryWatch?.cancel()
        reloadWork?.cancel()
        validationTask?.cancel()
        optionSaveWork?.cancel()
    }

    // MARK: Options

    func set<V: Equatable>(_ keyPath: WritableKeyPath<ConfigOptions, V>, _ value: V, darkAppearance: Bool = false) {
        guard let token = Self.encode(value) else { return }
        guard !requestOverrideEdit(keyPath, value: token, dark: darkAppearance) else { return }
        options[keyPath: keyPath] = value
        pendingOptions[keyPath] = token
        enqueueEdit(completion: { [weak self] in
            guard let self else { return }
            if self.pendingOptions[keyPath] == token { self.pendingOptions.removeValue(forKey: keyPath) }
            self.parseDocument()
        }) { try Self.setOption(keyPath, value: token, in: &$0) }
    }

    func binding<V: Equatable>(_ keyPath: WritableKeyPath<ConfigOptions, V>) -> Binding<V> {
        Binding(get: { self.options[keyPath: keyPath] }, set: { self.set(keyPath, $0) })
    }

    /// Shows continuous edits immediately, but writes only after they settle.
    func debouncedBinding<V: Equatable>(_ keyPath: WritableKeyPath<ConfigOptions, V>, darkAppearance: Bool = false) -> Binding<V> {
        Binding(get: { self.options[keyPath: keyPath] }, set: { [self] value in
            if keyPath == \ConfigOptions.dimInactiveOpacity && usesNativeBrightness {
                guard (value as? Double) != inactiveOpacity(dark: darkAppearance) else { return }
            } else if self.options[keyPath: keyPath] == value { return }
            guard let token = Self.encode(value) else { return }
            guard !requestOverrideEdit(keyPath, value: token, dark: darkAppearance) else { return }
            self.options[keyPath: keyPath] = value
            self.pendingOptions[keyPath] = token
            self.optionSaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushPendingOptions() }
            self.optionSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        })
    }

    func flushPendingOptions() {
        optionSaveWork?.cancel()
        optionSaveWork = nil
        guard !pendingOptions.isEmpty else { return }
        let pending = pendingOptions
        enqueueEdit(completion: { [weak self] in
            guard let self else { return }
            // Revert only this batch; newer slider changes remain visible and queued.
            for (path, value) in pending where self.pendingOptions[path] == value {
                self.pendingOptions.removeValue(forKey: path)
            }
            self.parseDocument()
        }) { document in
            for (path, value) in pending { try Self.setOption(path, value: value, in: &document) }
        }
    }

    @discardableResult
    func setPresetWidths(_ values: [Double], expected: [Double]) -> Task<Result<URL?, ConfigError>, Never> {
        enqueueEdit { document in
            let current: [Double]
            if let entry = document.entry("preset_column_widths", in: ["options"]) {
                guard case .array(let raw) = entry.value, raw.allSatisfy({ $0.number != nil }) else {
                    throw ConfigError(message: "These preset widths use complex TOML. Edit them by hand.", line: entry.line + 1)
                }
                current = raw.compactMap(\.number)
            } else { current = ConfigOptions().presetColumnWidths }
            func sameNumber(_ a: Double, _ b: Double) -> Bool { a == b || a.isNaN && b.isNaN }
            guard current.count == expected.count, zip(current, expected).allSatisfy({ sameNumber($0, $1) }) else {
                throw ConfigError(message: "The preset widths changed. Try the edit again.", line: nil)
            }
            guard values.contains(where: { $0.isFinite && $0 > 0.05 && $0 <= 1 }),
                  values.allSatisfy({ value in
                      value.isFinite && value > 0.05 && value <= 1 || expected.contains(where: { sameNumber($0, value) })
                  }) else {
                throw ConfigError(message: "New preset widths must be greater than 5% and at most 100%.", line: nil)
            }
            try document.set("preset_column_widths", in: ["options"], to: .array(values.map(ConfigDocument.Value.float)))
        }
    }

    func waitForPendingWrites() async {
        flushPendingOptions()
        _ = await writeTask?.value
        await validationTask?.value
    }

    /// Keeps the main actor available while the final debounced edit and queue drain.
    func flushForTermination(timeout: TimeInterval = 3) async -> Result<Void, ConfigError> {
        flushPendingOptions()
        return await withCheckedContinuation { continuation in
            var finished = false
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled, !finished else { return }
                finished = true
                continuation.resume(returning: .failure(ConfigError(message: "Timed out saving the configuration before quitting.", line: nil)))
            }
            Task {
                _ = await writeTask?.value
                await validationTask?.value
                guard !finished else { return }
                finished = true
                deadline.cancel()
                if let error = lastError { continuation.resume(returning: .failure(error)) }
                else { continuation.resume(returning: .success(())) }
            }
        }
    }

    var hasLegacyDimming: Bool { OptionOverride.find(\ConfigOptions.dimInactiveOpacity, in: document) != nil }

    var usesNativeBrightness: Bool {
        OptionOverride.find(\ConfigOptions.dimInactive, in: document)?.kind == .nativeDim
    }

    func inactiveOpacity(dark: Bool) -> Double {
        guard usesNativeBrightness else { return options.dimInactiveOpacity }
        let override = OptionOverride.find(\ConfigOptions.dimInactiveOpacity, in: document, dark: dark)
        let fallback = document.value("dim_inactive_windows", in: ["options"])?.number ?? 0
        let value = override?.value?.number ?? fallback
        return value.isFinite ? value : 0
    }

    private func requestOverrideEdit(_ path: PartialKeyPath<ConfigOptions>, value: ConfigDocument.Value, dark: Bool = false) -> Bool {
        if let entry = OptionOverride.handEditedEntry(path, in: document) {
            lastError = ConfigError(message: "This setting uses complex TOML. Edit it by hand.", line: entry.line + 1)
            return true
        }
        guard let override = OptionOverride.find(path, in: document, dark: dark) else { return false }
        pendingOverrideEdit = PendingOptionOverride(override: override, value: value)
        return true
    }

    func confirmOverrideEdit(_ request: PendingOptionOverride) {
        pendingOverrideEdit = nil
        enqueueEdit { document in
            guard OptionOverride.find(request.override.path, in: document, dark: request.override.key == "opacity_night") == request.override else {
                throw ConfigError(message: "The overriding setting changed. Reload and choose the setting again.", line: nil)
            }
            try request.override.update(request.value, in: &document)
        }
    }

    private static func setOption(_ path: PartialKeyPath<ConfigOptions>, value: ConfigDocument.Value, in document: inout ConfigDocument) throws {
        guard let key = ConfigOptions.tomlKeys[path] else { return }
        if let entry = OptionOverride.handEditedEntry(path, in: document) {
            throw ConfigError(message: "This setting uses complex TOML. Edit it by hand.", line: entry.line + 1)
        }
        if let override = OptionOverride.find(path, in: document) {
            throw ConfigError(message: "This setting is controlled by \(override.id). Reload and confirm its update.", line: nil)
        }
        try document.set(key, in: ["options"], to: value)
    }

    // MARK: Shortcuts

    func combos(for actionID: String) -> [KeyCombo] { bindings[actionID] ?? [] }

    @discardableResult
    func setCombos(_ combos: [KeyCombo], for actionID: String) -> Task<Result<URL?, ConfigError>, Never> {
        enqueueEdit { try $0.set(actionID, in: ["bindings"], to: Self.bindingValue(for: combos)) }
    }

    /// Edits one slot in the latest file, retaining opaque and side-specific strings.
    @discardableResult
    func setCombo(_ combo: KeyCombo?, for actionID: String, at index: Int) -> Task<Result<URL?, ConfigError>, Never> {
        let expected = bindingStrings[actionID] ?? []
        return enqueueEdit { document in
            guard try Self.rawBindings(actionID, in: document) == expected else {
                throw ConfigError(message: "The shortcuts changed. Try the edit again.", line: nil)
            }
            let value = document.value(actionID, in: ["bindings"])
            var values: [ConfigDocument.Value]
            switch value {
            case .array(let elements): values = elements
            case .some(let value): values = [value]
            case nil: values = []
            }
            guard values.allSatisfy({ $0.string != nil }) else {
                throw ConfigError(message: "This binding contains values that are not shortcut strings. Edit it by hand.", line: nil)
            }
            guard index >= 0, index <= values.count else {
                throw ConfigError(message: "The shortcuts changed. Record this shortcut again.", line: nil)
            }
            if let combo {
                if index == values.count { values.append(.string(combo.configString)) }
                else { values[index] = .string(combo.configString) }
            } else if values.indices.contains(index) {
                values.remove(at: index)
            }
            let updated: ConfigDocument.Value? = values.isEmpty ? nil : (values.count == 1 ? values[0] : .array(values))
            try document.set(actionID, in: ["bindings"], to: updated)
        }
    }

    /// Moves a binding only if every slot still matches the conflict decision shown to the user.
    @discardableResult
    func reassignCombo(_ combo: KeyCombo, for actionID: String, at index: Int,
                       expected: [String: [String]]) -> Task<Result<URL?, ConfigError>, Never> {
        enqueueEdit { document in
            let current = try Self.allRawBindings(in: document)
            guard current == expected else {
                throw ConfigError(message: "The shortcuts changed during recording. Record this shortcut again.", line: nil)
            }
            var destination = current[actionID] ?? []
            guard destination.indices.contains(index) || index == destination.count else {
                throw ConfigError(message: "The shortcut slot changed. Record this shortcut again.", line: nil)
            }
            for id in current.keys.sorted() where id != actionID {
                let old = current[id] ?? []
                let kept = old.filter { raw in
                    !(KeyCombo(configString: raw).map { ShortcutsWarnings.overlaps($0, combo) } ?? false)
                }
                if kept != old { try Self.writeBindings(kept, for: id, in: &document) }
            }
            if index == destination.count { destination.append(combo.configString) }
            else { destination[index] = combo.configString }
            try Self.writeBindings(destination, for: actionID, in: &document)
        }
    }

    func migrateBindings() async -> Result<[String], ConfigError> {
        var skipped: [String] = []
        return await enqueueEdit { document in
            let current = try Self.allRawBindings(in: document)
            var proposals: [String: [KeyCombo]] = [:]
            for action in ShortcutCatalog.all {
                let raw = try Self.rawBindings(action.id, in: document)
                let combos = raw.compactMap(KeyCombo.init(configString:))
                if raw.count == combos.count && ShortcutsMigration.matches(combos, for: action.id) {
                    proposals[action.id] = action.defaults
                }
            }
            // A skipped action keeps its old keys, which can block another proposal.
            while true {
                let blocked = proposals.keys.filter { id in
                    let others = current.filter { $0.key != id && proposals[$0.key] == nil }
                        .values.flatMap { $0 }.compactMap(KeyCombo.init(configString:))
                    let proposedOthers = proposals.filter { $0.key != id }.values.flatMap { $0 }
                    return proposals[id]!.contains { combo in
                        (others + proposedOthers).contains { ShortcutsWarnings.overlaps($0, combo) }
                    }
                }
                if blocked.isEmpty { break }
                skipped.append(contentsOf: blocked)
                for id in blocked { proposals.removeValue(forKey: id) }
            }
            for (id, combos) in proposals {
                try document.set(id, in: ["bindings"], to: Self.bindingValue(for: combos))
            }
        }.value.map { _ in skipped.sorted() }
    }

    private static func allRawBindings(in document: ConfigDocument) throws -> [String: [String]] {
        guard document.opaqueEntry(containing: ["bindings"]) == nil else {
            throw ConfigError(message: "Bindings use hand-edited TOML. Open the file to check all conflicts.", line: nil)
        }
        var result: [String: [String]] = [:]
        for entry in document.entries where entry.table == ["bindings"] {
            result[entry.key] = try rawBindings(entry.key, in: document)
        }
        return result
    }

    private static func rawBindings(_ id: String, in document: ConfigDocument) throws -> [String] {
        guard let entry = document.entry(id, in: ["bindings"]) else { return [] }
        let values: [ConfigDocument.Value]
        if case .array(let array) = entry.value { values = array }
        else if let value = entry.value { values = [value] }
        else { throw ConfigError(message: "This binding uses complex TOML. Edit it by hand.", line: entry.line + 1) }
        guard values.allSatisfy({ $0.string != nil }) else {
            throw ConfigError(message: "This binding contains values that are not shortcut strings.", line: entry.line + 1)
        }
        return values.compactMap(\.string)
    }

    private static func writeBindings(_ raw: [String], for id: String, in document: inout ConfigDocument) throws {
        let values = raw.map(ConfigDocument.Value.string)
        try document.set(id, in: ["bindings"], to: values.isEmpty ? nil : (values.count == 1 ? values[0] : .array(values)))
    }

    func actions(using combo: KeyCombo, except exceptActionID: String? = nil) -> [ShortcutAction] {
        bindings.keys.sorted().filter { id in
            id != exceptActionID && combos(for: id).contains { ShortcutsWarnings.overlaps($0, combo) }
        }.map { id in
            ShortcutCatalog.action(id) ?? ShortcutAction(id: id, title: id, subtitle: "Engine action from the file", group: .other, defaults: [])
        }
    }

    func action(using combo: KeyCombo, except exceptActionID: String? = nil) -> ShortcutAction? {
        actions(using: combo, except: exceptActionID).first
    }

    @discardableResult
    func resetBindingsToDefaults() -> Task<Result<URL?, ConfigError>, Never> {
        // Unknown action keys are preserved, as are all other tables.
        enqueueEdit { document in
            for action in ShortcutCatalog.all {
                try document.set(action.id, in: ["bindings"], to: Self.bindingValue(for: action.defaults))
            }
        }
    }

    // MARK: Window rules

    @discardableResult
    func saveRule(_ rule: WindowRule) async -> Result<Void, ConfigError> {
        return await enqueueEdit { document in
            guard !rule.isHandEdited, !Self.ruleUsesComplexTOML(rule.id, in: document) else {
                throw ConfigError(message: "This rule is hand-edited. Open it in the file.", line: nil)
            }
            let table = ["windows", rule.id]
            try document.set("title", in: table, to: .string(rule.titleMatch.regex))
            try document.set("bundle_id", in: table, to: rule.bundleID.map(ConfigDocument.Value.string))
            try document.set("floating", in: table, to: rule.floating.value.map(ConfigDocument.Value.bool))
            let index: Int?
            switch rule.placement {
            case .automatic: index = nil
            case .start: index = 0
            // The engine appends out-of-range indices. Keep this within TOML i64.
            case .end: index = Int(Int32.max)
            case .column(let column): index = max(0, column - 1)
            }
            try document.set("index", in: table, to: index.map(ConfigDocument.Value.integer))
        }.value.map { _ in () }
    }

    @discardableResult
    func deleteRule(id: String) async -> Result<Void, ConfigError> {
        await enqueueEdit { document in
            guard !Self.ruleUsesComplexTOML(id, in: document) else {
                throw ConfigError(message: "This rule is hand-edited. Open it in the file.", line: nil)
            }
            document.removeTable(["windows", id])
        }.value.map { _ in () }
    }

    func uniqueRuleID(base: String) -> String {
        let slug = String(base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let root = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let prefix = root.isEmpty ? "rule" : root
        var candidate = prefix
        var suffix = 2
        while rules.contains(where: { $0.id == candidate }) {
            candidate = "\(prefix)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: File

    func reloadFromDisk(clearSaveError: Bool = true) {
        if clearSaveError { saveFailure = nil }
        do {
            let data = try Data(contentsOf: fileURL)
            document = try Self.decode(data)
            loadedData = data
            parseDocument()
            validate()
        } catch {
            validationGeneration += 1
            validationTask?.cancel()
            isValidating = false
            lastError = saveFailure ?? Self.configError(from: error)
        }
    }

    @discardableResult
    func resetToDefaults() async throws -> URL? {
        flushPendingOptions()
        let defaults = try Self.decode(Self.defaultData())
        return try await enqueueEdit(keepBackup: true) { $0 = defaults }.value.get()
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

    func openInEditor() { NSWorkspace.shared.open(fileURL) }

    /// All mutations share this queue, candidate validation, and guarded publication.
    @discardableResult
    private func enqueueEdit(allowMissing: Bool = false, keepBackup: Bool = false, completion: (() -> Void)? = nil,
                             _ change: @escaping (inout ConfigDocument) throws -> Void) -> Task<Result<URL?, ConfigError>, Never> {
        let previous = writeTask
        let task = Task { [self] in
            _ = await previous?.value
            let result = await performEdit(allowMissing: allowMissing, keepBackup: keepBackup, change)
            completion?()
            return result
        }
        writeTask = task
        return task
    }

    private func performEdit(allowMissing: Bool, keepBackup: Bool, _ change: (inout ConfigDocument) throws -> Void) async -> Result<URL?, ConfigError> {
        do {
            for _ in 0..<4 {
                do {
                    let original = try ConfigFile.Version.read(fileURL)
                    if allowMissing && original != nil {
                        reloadFromDisk()
                        return .success(nil)
                    }
                    guard original != nil || allowMissing else {
                        throw ConfigError(message: "The config file was removed. Reload it before editing.", line: nil)
                    }
                    var candidate = try Self.decode(original?.data ?? Data())
                    try change(&candidate)
                    let data = Data(candidate.text.utf8)
                    let target = original?.target ?? fileURL.resolvingSymlinksInPath()
                    let temp = try ConfigFile.stage(data, beside: target)
                    var committed = false
                    defer { if !committed { try? FileManager.default.removeItem(at: temp) } }
                    _ = try await Self.checkConfig(temp)
                    try Task.checkCancellation()
                    let backup: URL?
                    if data == original?.data {
                        guard try ConfigFile.Version.read(fileURL) == original else { throw ConfigFile.Changed() }
                        backup = nil
                    } else {
                        // After exchange the temporary path is a recovery file: never delete it on error.
                        do {
                            backup = try ConfigFile.commit(temp, to: fileURL, expected: original, keepBackup: keepBackup)
                            committed = true
                        } catch let error as ConfigFile.RecoveryError {
                            committed = true
                            throw error
                        }
                    }
                    saveFailure = nil
                    reloadFromDisk()
                    return .success(backup)
                } catch is ConfigFile.Changed { continue }
            }
            throw ConfigError(message: "The config keeps changing on disk. Try the edit again.", line: nil)
        } catch {
            let failure = Self.configError(from: error)
            saveFailure = failure
            reloadFromDisk(clearSaveError: false)
            lastError = failure
            return .failure(failure)
        }
    }

    private static func checkConfig(_ url: URL) async throws -> [ConfigError] {
        guard FileManager.default.isExecutableFile(atPath: AppPaths.engineBinary.path) else {
            throw ConfigError(message: "The engine is unavailable. The configuration could not be validated or saved.", line: nil)
        }
        let result = await ProcessRunner.run(AppPaths.engineBinary, arguments: ["check-config", url.path], timeout: 5)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConfigError(message: message.isEmpty ? "The engine could not validate the config." : message,
                              line: ProcessRunner.errorLine(result.output))
        }
        return result.output.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("warning: ") else { return nil }
            return ConfigError(message: String(line.dropFirst("warning: ".count)), line: nil)
        }
    }

    // MARK: Encoding

    static func defaultData() throws -> Data {
        if let template = AppPaths.defaultConfigTemplate {
            var defaults = try decode(Data(contentsOf: template))
            try defaults.set("preset_column_widths", in: ["options"], to: .array(ConfigOptions.defaultPresetColumnWidths.map(ConfigDocument.Value.float)))
            return Data(defaults.text.utf8)
        }
        var document = ConfigDocument("# OpenYourMac configuration\n[options]\n\n[bindings]\n")
        let defaults = ConfigOptions()
        for (path, key) in ConfigOptions.tomlKeys.sorted(by: { $0.value < $1.value }) {
            try document.set(key, in: ["options"], to: encode(defaults[keyPath: path]))
        }
        for action in ShortcutCatalog.all {
            if let value = bindingValue(for: action.defaults) {
                try document.set(action.id, in: ["bindings"], to: value)
            }
        }
        try document.set("title", in: ["windows", "pip"], to: .string("Picture.*(in)?.*[Pp]icture"))
        try document.set("floating", in: ["windows", "pip"], to: .bool(true))
        return Data(document.text.utf8)
    }

    /// A single string for one combo, an array for several, nil (remove the key) for none.
    private static func bindingValue(for combos: [KeyCombo]) -> ConfigDocument.Value? {
        let values = combos.map { ConfigDocument.Value.string($0.configString) }
        switch values.count {
        case 0: return nil
        case 1: return values[0]
        default: return .array(values)
        }
    }

    private static func encode(_ value: Any) -> ConfigDocument.Value? {
        switch value {
        case let bool as Bool: return .bool(bool)
        case let integer as Int: return .integer(integer)
        case let double as Double where double.isFinite: return .float(double)
        case let string as String: return .string(string)
        case let doubles as [Double] where doubles.allSatisfy(\.isFinite): return .array(doubles.map(ConfigDocument.Value.float))
        case let strings as [String]: return .array(strings.map(ConfigDocument.Value.string))
        case let mode as CenterMode: return .string(mode.rawValue)
        case let style as AnimationStyle where style != .custom: return .string(style.rawValue)
        case let settle as SwipeSettle: return .string(settle.rawValue)
        case let modifier as ScrollModifier: return .string(modifier.rawValue)
        default: return nil
        }
    }

    /// Decodes UTF-8 without dropping a byte-order mark, so a rewrite keeps it.
    private static func decode(_ data: Data) throws -> ConfigDocument {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ConfigError(message: "The config file is not UTF-8 text.", line: nil)
        }
        return ConfigDocument(String(decoding: data, as: UTF8.self))
    }

    private static func configError(from error: Error) -> ConfigError {
        (error as? ConfigError) ?? ConfigError(message: error.localizedDescription, line: nil)
    }

    // MARK: Parsing

    /// Rebuilds the typed model from `document`. Invalid values keep their defaults and add a warning.
    private func parseDocument() {
        var notes: [ConfigError] = []
        var parsedOptions = parseOptions(notes: &notes)
        for (path, value) in pendingOptions { _ = Self.assign(value, to: path, in: &parsedOptions) }
        var overrideIDs = Set<String>()
        optionOverrides = ConfigOptions.tomlKeys.keys.compactMap { OptionOverride.find($0, in: document) }
            .sorted { $0.id < $1.id }.filter { overrideIDs.insert($0.id).inserted }
        let parsedBindings = parseBindings(notes: &notes)
        let parsedRules = parseRules()
        options = parsedOptions
        bindings = parsedBindings
        rules = parsedRules
        warnings = notes
    }

    private func parseOptions(notes: inout [ConfigError]) -> ConfigOptions {
        var parsed = ConfigOptions()
        handEditedOptions = ConfigOptions.tomlKeys.compactMap { path, key in
            if OptionOverride.handEditedEntry(path, in: document) != nil { return key }
            if document.opaqueEntry(containing: ["options", key]) != nil { return key }
            if let entry = document.entry(key, in: ["options"]), !entry.editable { return key }
            return nil
        }.sorted()
        for (path, key) in ConfigOptions.tomlKeys.sorted(by: { $0.value < $1.value }) {
            guard let entry = document.entry(key, in: ["options"]) else { continue }
            if handEditedOptions.contains(key) { continue }
            let isValid = entry.value.map { Self.assign($0, to: path, in: &parsed) } ?? false
            if !isValid {
                notes.append(ConfigError(message: "Invalid value for ‘\(key)’; using its default.", line: entry.line + 1))
            }
        }
        let validWidths = parsed.presetColumnWidths.filter { $0.isFinite && $0 > 0.05 && $0 <= 1 }
        if validWidths.count != parsed.presetColumnWidths.count || validWidths.isEmpty {
            notes.append(ConfigError(message: "The engine ignores preset widths outside (5%, 100%]. The effective cycle is shown below; your file stays unchanged until you edit it.", line: document.entry("preset_column_widths", in: ["options"]).map { $0.line + 1 }))
        }
        parsed.animationDurationMS = parsed.animation == .instant ? 0 : parsed.animation == .fast ? 140 : 222
        for path in ConfigOptions.tomlKeys.keys { OptionOverride.find(path, in: document)?.apply(to: &parsed) }
        return parsed
    }

    /// Stores `value` at `path` when its type fits. Returns false when it does not.
    private static func assign(_ value: ConfigDocument.Value, to path: PartialKeyPath<ConfigOptions>, in options: inout ConfigOptions) -> Bool {
        if let path = path as? WritableKeyPath<ConfigOptions, Bool>, case .bool(let bool) = value {
            options[keyPath: path] = bool
        } else if let path = path as? WritableKeyPath<ConfigOptions, Int>, case .integer(let integer) = value, integer >= 0 {
            options[keyPath: path] = integer
        } else if let path = path as? WritableKeyPath<ConfigOptions, Double>, let number = value.number, number.isFinite {
            options[keyPath: path] = number
        } else if let path = path as? WritableKeyPath<ConfigOptions, String>, let string = value.string {
            options[keyPath: path] = string
        } else if let path = path as? WritableKeyPath<ConfigOptions, [Double]>, case .array(let elements) = value, elements.allSatisfy({ $0.number != nil }) {
            options[keyPath: path] = elements.compactMap(\.number)
        } else if let path = path as? WritableKeyPath<ConfigOptions, [String]>, case .array(let elements) = value, elements.allSatisfy({ $0.string != nil }) {
            options[keyPath: path] = elements.compactMap(\.string)
        } else if let string = value.string {
            return assignEnum(string, to: path, in: &options)
        } else {
            return false
        }
        return true
    }

    private static func assignEnum(_ rawValue: String, to path: PartialKeyPath<ConfigOptions>, in options: inout ConfigOptions) -> Bool {
        if let path = path as? WritableKeyPath<ConfigOptions, CenterMode>, let mode = CenterMode(rawValue: ["overflow": "on-overflow", "on_overflow": "on-overflow"][rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            options[keyPath: path] = mode
        } else if let path = path as? WritableKeyPath<ConfigOptions, AnimationStyle>, let style = AnimationStyle(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)), style != .custom {
            options[keyPath: path] = style
        } else if let path = path as? WritableKeyPath<ConfigOptions, SwipeSettle>, let settle = SwipeSettle(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            options[keyPath: path] = settle
        } else if let path = path as? WritableKeyPath<ConfigOptions, ScrollModifier>, let modifier = ScrollModifier(engineValue: rawValue) {
            options[keyPath: path] = modifier
        } else {
            return false
        }
        return true
    }

    private func parseBindings(notes: inout [ConfigError]) -> [String: [KeyCombo]] {
        var shortcuts: [String: [KeyCombo]] = [:]
        var raw: [String: [String]] = [:]
        handEditedBindings = []
        hasOpaqueBindingTable = document.opaqueEntry(containing: ["bindings"]) != nil
        for entry in document.entries where entry.table == ["bindings"] {
            guard let values = try? Self.rawBindings(entry.key, in: document) else {
                handEditedBindings.insert(entry.key)
                continue
            }
            if !entry.editable { handEditedBindings.insert(entry.key) }
            raw[entry.key] = values
            let combos = values.compactMap(KeyCombo.init(configString:)).filter { $0.resolvedKeyCode != nil }
            if combos.count != values.count {
                notes.append(ConfigError(message: "Inactive or unrecognised shortcut for ‘\(entry.key)’; edit its raw value in the file.", line: entry.line + 1))
            }
            shortcuts[entry.key] = combos
        }
        bindingStrings = raw
        return shortcuts
    }

    private static func ruleUsesComplexTOML(_ id: String, in document: ConfigDocument) -> Bool {
        let table = ["windows", id]
        let exists = document.definedPaths.contains { $0.starts(with: table) }
        return document.opaqueEntry(containing: ["windows"]) != nil
            || exists && !document.tables.contains(table)
            || document.opaqueEntry(containing: table) != nil
            || document.entries.contains { $0.table == table && ["title", "bundle_id", "floating", "index"].contains($0.key) && !$0.editable }
    }

    private func parseRules() -> [WindowRule] {
        var parsed: [WindowRule] = []
        var ids = Set(document.definedPaths.filter { $0.first == "windows" && $0.count >= 2 }.map { $0[1] })
        let opaqueRoot = document.opaqueEntry(containing: ["windows"]) != nil
        if opaqueRoot { ids.insert("(inline window rules)") }
        for id in ids.sorted() {
            let table = ["windows", id]
            let isHandEdited = Self.ruleUsesComplexTOML(id, in: document)
            let title = document.value("title", in: table)?.string ?? ".*"
            let bundleID = document.value("bundle_id", in: table)?.string
            let floating: WindowRule.Floating
            if case .bool(let value) = document.value("floating", in: table) {
                floating = value ? .float : .tile
            } else { floating = .automatic }
            let appName = bundleID.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent
            }
            parsed.append(WindowRule(
                id: id,
                bundleID: bundleID,
                appName: appName,
                titleMatch: .init(regex: title),
                floating: floating,
                isHandEdited: isHandEdited,
                placement: placement(in: table)
            ))
        }
        return parsed
    }

    /// Reads the engine's zero-based `index` back into a UI placement.
    private func placement(in table: [String]) -> WindowRule.Placement {
        guard case .integer(let index) = document.value("index", in: table), index >= 0
        else { return .automatic }
        if index == 0 { return .start }
        if index >= Int(Int32.max) { return .end }
        return .column(index + 1)
    }

    // MARK: Validation and watching

    /// Asks the engine to check the file. Only the result for the latest content is shown.
    private func validate() {
        validationGeneration += 1
        let generation = validationGeneration
        validationTask?.cancel()
        // A missing file has nothing to check; do not leave the page waiting.
        guard let validatedData = loadedData else {
            isValidating = false
            return
        }
        isValidating = true
        validationTask = Task { [weak self] in
            var failure: ConfigError?
            var bindingWarnings: [ConfigError] = []
            do {
                let temp = try ConfigFile.stage(validatedData, beside: FileManager.default.temporaryDirectory.appendingPathComponent("config.toml"))
                defer { try? FileManager.default.removeItem(at: temp) }
                bindingWarnings = try await Self.checkConfig(temp)
            } catch { failure = Self.configError(from: error) }
            guard !Task.isCancelled, let self, self.validationGeneration == generation,
                  self.loadedData == validatedData,
                  // Snapshots render built-in defaults that are never written to disk.
                  AppPaths.isSnapshot || (try? Data(contentsOf: self.fileURL)) == validatedData else { return }
            self.isValidating = false
            self.engineBindingWarnings = bindingWarnings
            self.lastError = self.saveFailure ?? failure
        }
    }

    /// Watches the folder too: editors often replace the file instead of writing to it.
    private func startWatching() {
        directoryWatch = watch(fileURL.deletingLastPathComponent(), mask: [.write, .rename, .delete])
        rearmFileWatch()
    }

    private func rearmFileWatch() {
        fileWatch?.cancel()
        fileWatch = watch(fileURL, mask: [.write, .rename, .delete, .attrib])
    }

    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.resume()
        return source
    }

    /// Coalesces a burst of file events into one reload.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (try? Data(contentsOf: self.fileURL)) != self.loadedData {
                    self.reloadFromDisk(clearSaveError: false)
                }
                self.rearmFileWatch()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
