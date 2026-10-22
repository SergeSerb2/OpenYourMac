import AppKit

/// Hidden integration diagnostics. These use the production stores and files;
/// they never request permission, run fixes, or register login items. The restart
/// diagnostic requires an explicit IPC-only wrapper, test service and scratch HOME.
/// Use HOME=/tmp/oym-core-home and --selftest-config <directory> [operation].
@MainActor
enum CoreDiagnostics {
    // EngineController keeps a weak reference, so diagnostics own the preferences.
    private static let diagnosticPreferences = Preferences(defaults: nil)

    /// Runs the diagnostic named on the command line. Returns false when none was requested.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--selftest-config"), args.count > index + 1 {
            let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let operation = args.count > index + 2 ? args[index + 2] : "inspect"
            var finished = false
            Task {
                await runConfigSelfTest(in: folder, operation: operation)
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return true
        }
        if args.contains("--diagnose-setup") {
            let config = ConfigStore()
            diagnoseSetup(config: config)
            withExtendedLifetime(config) {}
            return true
        }
        return false
    }

    // MARK: Config

    private static func runConfigSelfTest(in folder: URL, operation: String) async {
        let config = ConfigStore(fileURL: folder.appendingPathComponent("openyourmac.toml"))
        await config.waitForPendingWrites()
        switch operation {
        case "export-raycast":
            do {
                print("export=\(try RaycastExporter.export(to: folder).path)")
            } catch { print("export-error=\(error.localizedDescription)") }
        case "restart-engine":
            await diagnoseRestart()
        case "external-quit":
            await diagnoseExternalQuit(config: config)
        case "capture-keys":
            await diagnoseCapture(config: config)
        case "capture-local":
            await diagnoseCapture(config: config, launchEngine: false)
        case "capture-busy":
            guard let engine = diagnosticEngine(config: config) else { return }
            defer { engine.stopForTermination() }
            engine.start()
            let recorder = ShortcutsRecorder()
            recorder.begin(.init(actionID: "window_focus_west", index: 0), engine: engine) { _, _ in }
            print("capture-busy-ready=\(recorder.isReady) error=\(recorder.error ?? "none")")
            recorder.cancel()
        case "restart-clean-exit":
            await diagnoseRestartCleanExit(config: config)
        case "quit-save", "quit-save-failure", "quit-save-timeout":
            config.set(\.gapOuter, 42)
            if operation == "quit-save-failure" { config.set(\.focusBorderColor, "invalid") }
            config.debouncedBinding(\.gapInner).wrappedValue = 31
            let start = Date()
            let result = await config.flushForTermination(timeout: operation == "quit-save-timeout" ? 0 : 3)
            switch result {
            case .success: print("quit-save=success")
            case .failure(let error): print("quit-save=\(error.localizedDescription)")
            }
            print("quit-save-seconds=\(Date().timeIntervalSince(start))")
        case "contract-writes":
            await diagnoseWrites(config: config, in: folder)
        case "setup":
            diagnoseSetup(config: config)
        case "edit":
            config.set(\.gapInner, 24)
            config.set(\.dockAware, false)
            config.setCombos([KeyCombo(modifiers: [.ctrl, .alt], key: "h")], for: "window_focus_west")
            config.setCombos([KeyCombo(modifiers: [.ctrl, .alt], key: "l"), KeyCombo(modifiers: [.ctrl, .alt], key: "rightarrow")], for: "window_focus_east")
            config.setCombos([], for: "window_focus_north")
            printRuleResult(await config.saveRule(WindowRule(
                id: "diagnostic",
                bundleID: "com.example.App",
                appName: nil,
                titleMatch: .contains("Example [1]"),
                floating: .float,
                placement: .column(3)
            )))
        case "same-rule":
            if let rule = config.rules.first {
                printRuleResult(await config.saveRule(rule))
            }
        case "delete-rule":
            printRuleResult(await config.deleteRule(id: "diagnostic"))
        case "edit-slot":
            _ = await config.setCombo(KeyCombo(modifiers: [.ctrl, .alt], key: "+"), for: "window_focus_west", at: 2).value
            print("slots=\(config.bindingStrings["window_focus_west"] ?? [])")
        case "invalid-rule":
            printRuleResult(await config.saveRule(WindowRule(id: "invalid", titleMatch: .pattern("(?>a)"), floating: .float, placement: .automatic)))
        case "double-reset":
            do {
                config.set(\.gapInner, 19)
                print("backup=\(try await config.resetToDefaults()?.path ?? "none")")
                print("unchanged-backup=\(try await config.resetToDefaults()?.path ?? "none")")
                config.set(\.gapInner, 21)
                print("backup=\(try await config.resetToDefaults()?.path ?? "none")")
            } catch { print(error.localizedDescription) }
        case "debounce":
            let original = try? Data(contentsOf: config.fileURL)
            let binding = config.debouncedBinding(\.gapInner)
            for value in 9...20 {
                binding.wrappedValue = Double(value)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            print("live=\(config.options.gapInner) disk-unchanged=\(original == (try? Data(contentsOf: config.fileURL)))")
            try? await Task.sleep(nanoseconds: 400_000_000)
            await config.waitForPendingWrites()
            print("settled=\(config.options.gapInner)")
            binding.wrappedValue = 22
            config.flushPendingOptions()
            await config.waitForPendingWrites()
            print("drag-end=\(config.options.gapInner)")
        case "reset-bindings":
            config.resetBindingsToDefaults()
        case "reset":
            do {
                print("backup=\(try await config.resetToDefaults()?.path ?? "none")")
            } catch {
                print(error.localizedDescription)
            }
        case "migrate-bindings":
            switch await config.migrateBindings() {
            case .success(let skipped): print("migration=success skipped=\(skipped.joined(separator: ","))")
            case .failure(let error): print("migration=failed \(error.localizedDescription)")
            }
        case "reassign-shortcut":
            let expected = config.bindingStrings
            print("reassign=\(await config.reassignCombo(KeyCombo(modifiers: [.ctrl, .alt], key: "h"), for: "window_focus_west", at: 0, expected: expected).value)")
        case "edit-width":
            var widths = config.options.presetColumnWidths
            if !widths.isEmpty { widths[0] = 0.8 }
            print("width-edit=\(await config.setPresetWidths(widths, expected: config.options.presetColumnWidths).value)")
        case "override-edits":
            func update<V: Equatable>(_ path: WritableKeyPath<ConfigOptions, V>, _ value: V) async {
                config.set(path, value)
                if let request = config.pendingOverrideEdit {
                    print("confirm-override=\(request.override.id)")
                    config.confirmOverrideEdit(request)
                }
                await config.waitForPendingWrites()
            }
            await update(\.animation, .instant)
            await update(\.sessionRestore, false)
            await update(\.nativeTabs, true)
            await update(\.swipeGestureFingers, 3)
            await update(\.swipeNatural, true)
            await update(\.scrollModifier, .off)
            await update(\.dimInactiveOpacity, 0.4)
            await update(\.dimInactive, false)
        case "override-dim-dark":
            config.set(\.dimInactiveOpacity, 0.4, darkAppearance: true)
            if let request = config.pendingOverrideEdit { config.confirmOverrideEdit(request) }
            await config.waitForPendingWrites()
            config.set(\.dimInactive, false, darkAppearance: true)
            if let request = config.pendingOverrideEdit { config.confirmOverrideEdit(request) }
            await config.waitForPendingWrites()
        case "record-pause":
            guard let engine = diagnosticEngine(config: config) else { return }
            // Only the real IPC send path runs; this diagnostic never launches an engine.
            engine.setPreviewState(.running)
            let recorder = ShortcutsRecorder()
            recorder.begin(.init(actionID: "window_focus_west", index: 0), engine: engine) { _, _ in }
            print("record-initial-ready=\(recorder.isReady)")
            let duration = Double(ProcessInfo.processInfo.environment["OYM_RECORD_SECONDS"] ?? "3") ?? 3
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(duration, 30)) * 1_000_000_000))
            print("record-ready=\(recorder.isReady) recording=\(recorder.slot != nil) error=\(recorder.error ?? "none")")
            recorder.cancel()
        case "complex":
            config.set(\.presetColumnWidths, [0.4, 0.6])
        default:
            break
        }
        await config.waitForPendingWrites()
        // Give vnode events and asynchronous check-config results time to arrive.
        let duration: TimeInterval = operation == "watch" ? 4 : 0.5
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        print("file=\(config.fileURL.path)")
        print("gap_inner=\(config.options.gapInner) dock_aware=\(config.options.dockAware) animation=\(config.options.animation.rawValue)")
        print("widths=\(config.options.presetColumnWidths) center=\(config.options.centerFocusedColumn.rawValue) scroll=\(config.options.scrollModifier.rawValue)")
        print("restore=\(config.options.sessionRestore) native-tabs=\(config.options.nativeTabs) fingers=\(config.options.swipeGestureFingers) natural=\(config.options.swipeNatural) dim=\(config.options.dimInactive) opacity=\(config.options.dimInactiveOpacity) duration=\(config.options.animationDurationMS)")
        if let rule = config.rules.first(where: { $0.id == "diagnostic" }) { print("literal-title-roundtrip=\(rule.titleMatch == .contains("Example [1]"))") }
        print("bindings=\(config.bindings.count) rules=\(config.rules.map(\.id).joined(separator: ","))")
        print("hand-edited-options=\(config.handEditedOptions.joined(separator: ",")) hand-edited-bindings=\(config.handEditedBindings.sorted().joined(separator: ",")) opaque-bindings=\(config.hasOpaqueBindingTable)")
        for rule in config.rules { print("rule=\(rule.id) floating=\(rule.floating.rawValue) hand-edited=\(rule.isHandEdited) placement=\(rule.placement)") }
        for (id, raw) in config.bindingStrings.sorted(by: { $0.key < $1.key }) {
            for chord in raw {
                let active = KeyCombo(configString: chord)?.resolvedKeyCode != nil
                print("binding=\(id) chord=\(chord) resolvable=\(active)")
            }
        }
        if let combo = KeyCombo(configString: "ctrl + alt - h") { print("conflict-h=\(config.action(using: combo, except: "window_focus_west")?.id ?? "none")") }
        let displays = DisplayStore()
        displays.configure(config: config)
        print("managed-displays=\(displays.displays.filter { displays.isManaged($0) }.count)/\(displays.displays.count)")
        if let error = config.lastError {
            print("error=\(error.localizedDescription)")
        }
        for warning in config.warnings + config.engineBindingWarnings {
            print("warning=\(warning.localizedDescription)")
        }
    }

    private static func printRuleResult(_ result: Result<Void, ConfigError>) {
        switch result {
        case .success: print("rule-result=success")
        case .failure(let error): print("rule-result=\(error.localizedDescription)")
        }
    }

    /// Exercises the same guarded write queue used by the settings and shortcuts pages.
    private static func diagnoseWrites(config: ConfigStore, in folder: URL) async {
        func checkpoint(_ name: String) async {
            await config.waitForPendingWrites()
            do {
                try Data(contentsOf: config.fileURL).write(to: folder.appendingPathComponent("contract-\(name).toml"))
                print("write-\(name)=\(config.lastError?.localizedDescription ?? "ok")")
            } catch { print("write-\(name)=\(error.localizedDescription)") }
        }
        config.set(\.gapInner, 9.5)
        config.set(\.gapOuter, 40.25)
        config.set(\.focusBorderWidth, 3.5)
        config.set(\.focusBorderRadius, 30.25)
        config.set(\.dimInactiveOpacity, 0.0)
        config.set(\.swipeGestureFingers, 5)
        await checkpoint("options")
        let color = config.debouncedBinding(\.focusBorderColor)
        color.wrappedValue = "#12345680"
        await checkpoint("colour")
        _ = await config.setPresetWidths([0.33333, 0.25, 0.66667, 0.33333], expected: config.options.presetColumnWidths).value
        await checkpoint("widths")
        for floating in WindowRule.Floating.allCases {
            printRuleResult(await config.saveRule(WindowRule(id: "diagnostic", titleMatch: .contains("Example [1]"), floating: floating, placement: .column(3))))
            await checkpoint("rule-\(floating.rawValue.lowercased())")
        }
        config.setCombos([KeyCombo(modifiers: [.ctrl, .alt], key: "h")], for: "window_focus_west")
        await checkpoint("shortcuts")
        _ = await config.setCombo(KeyCombo(modifiers: [.ctrl, .alt], key: "escape"), for: "window_focus_west", at: 1).value
        await checkpoint("shortcut-slot")
        let result = await config.reassignCombo(KeyCombo(modifiers: [.ctrl, .alt], key: "h"), for: "window_focus_west", at: 0, expected: config.bindingStrings).value
        print("reassign-result=\(result)")
        await checkpoint("reassign")
        printRuleResult(await config.deleteRule(id: "diagnostic"))
        await checkpoint("delete-rule")
        config.resetBindingsToDefaults()
        await checkpoint("reset-shortcuts")
        config.setCombos(ShortcutsMigration.oldDefaults["window_focus_west"] ?? [], for: "window_focus_west")
        await config.waitForPendingWrites()
        print("migration-result=\(await config.migrateBindings())")
        await checkpoint("migration")
        do { _ = try await config.resetToDefaults() }
        catch { print("reset-result=\(error.localizedDescription)") }
        await checkpoint("reset")
    }

    private static func diagnosticEngine(config: ConfigStore) -> EngineController? {
        let environment = ProcessInfo.processInfo.environment
        guard let wrapper = environment["OYM_ENGINE_PATH"], !wrapper.isEmpty,
              let service = environment["OYM_MACH_SERVICE"], service.hasPrefix("com.openyourmac.engine."), service.hasSuffix("test"),
              AppPaths.home.path.hasPrefix("/tmp/") || AppPaths.home.path.hasPrefix("/private/tmp/") else {
            print("engine-diagnostic-error=Requires a scratch HOME in /tmp, OYM_ENGINE_PATH IPC-only wrapper and test Mach service")
            return nil
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = EngineController()
        engine.configure(config: config, preferences: diagnosticPreferences)
        return engine
    }

    private static func diagnoseExternalQuit(config: ConfigStore) async {
        guard let engine = diagnosticEngine(config: config) else { return }
        defer { engine.stopForTermination() }
        let start = Date()
        engine.start()
        let deadline = start.addingTimeInterval(4)
        while engine.state.isBusy, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard engine.state.isRunning else { print("quit-check=failed start=\(engine.state)"); return }
        let before = (try? String(contentsOf: AppPaths.engineLog))?.components(separatedBy: "=== Window manager started ").count
        // Bypass engine.send(.quit), exactly as an external CLI or keyboard quit does.
        let quit = await ProcessRunner.run(AppPaths.engineBinary, arguments: ["send-cmd", "quit"], timeout: 2, environment: ProcessInfo.processInfo.environment)
        print("external-quit-status=\(quit.status) uptime=\(Date().timeIntervalSince(start))")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let after = (try? String(contentsOf: AppPaths.engineLog))?.components(separatedBy: "=== Window manager started ").count
        print("quit-final=\(engine.state) launches-unchanged=\(before == after)")
        print("quit-check=\(quit.status == 0 && engine.state == .stopped && before == after ? "pass" : "FAIL")")
    }

    private static func diagnoseCapture(config: ConfigStore, launchEngine: Bool = true) async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine: EngineController
        if launchEngine {
            guard let isolated = diagnosticEngine(config: config) else { return }
            engine = isolated
        } else { engine = EngineController() }
        defer { engine.stopForTermination() }
        if launchEngine {
            engine.start()
            let deadline = Date().addingTimeInterval(4)
            while engine.state.isBusy, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard engine.state.isRunning else { print("capture-error=\(engine.state)"); return }
        }
        let recorder = ShortcutsRecorder()
        var captured: KeyCombo?
        func begin() async {
            captured = nil
            recorder.begin(.init(actionID: "window_focus_west", index: 0), engine: engine) { _, combo in captured = combo }
            let readyDeadline = Date().addingTimeInterval(2)
            while !recorder.isReady && recorder.slot != nil, Date() < readyDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        // App-local events pass through the real local monitor. No system event is posted.
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                NSApplication.shared.sendEvent(event)
            }
        }
        await begin()
        key(53, [.control, .option])
        print("capture-modified-escape=\(captured?.configString ?? "none")")
        if let captured { _ = await config.setCombo(captured, for: "window_focus_west", at: 0).value }
        await begin()
        key(95, [.control, .option]) // JIS keypad comma is absent from the engine tables.
        print("capture-unsupported=\(captured == nil && recorder.isReady) prompt=\(recorder.prompt)")
        key(53, [])
        print("capture-plain-escape-cancelled=\(recorder.slot == nil && captured == nil)")
        await begin()
        key(27, [.control, .option])
        print("capture-minus=\(captured?.configString ?? "none")")
        recorder.cancel()
    }

    // MARK: Setup

    private static func diagnoseRestartCleanExit(config: ConfigStore) async {
        guard let engine = diagnosticEngine(config: config) else { return }
        defer { engine.stopForTermination() }
        engine.start()
        let startDeadline = Date().addingTimeInterval(4)
        while engine.state.isBusy, Date() < startDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard engine.state.isRunning else { print("restart-clean-error=\(engine.state)"); return }
        var outcomes: [EngineState] = []
        engine.restart { outcomes.append($0) }
        let deadline = Date().addingTimeInterval(4)
        while engine.state == .stopping, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        // The isolated harness sends SIGTERM to this IPC-only child. IPC-only
        // command receipts deliberately do not execute an engine quit command.
        print("restart-clean-waiting-for-exit")
        fflush(stdout)
        while engine.state.isBusy, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let stopped = engine.state == .stopped
        print("restart-clean-state=\(engine.state) outcomes=\(outcomes)")
        engine.start()
        let manualDeadline = Date().addingTimeInterval(4)
        while engine.state.isBusy, Date() < manualDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        print("restart-clean-check=\(stopped && outcomes == [.stopped] && engine.state.isRunning ? "pass" : "FAIL") callbacks=\(outcomes.count)")
    }

    private static func diagnoseRestart() async {
        let environment = ProcessInfo.processInfo.environment
        guard let wrapper = environment["OYM_ENGINE_PATH"], !wrapper.isEmpty,
              let service = environment["OYM_MACH_SERVICE"], service.hasPrefix("com.openyourmac.engine."), service.hasSuffix("test"),
              AppPaths.home.path.hasPrefix("/tmp/") || AppPaths.home.path.hasPrefix("/private/tmp/") else {
            print("restart-error=Requires a scratch HOME in /tmp, OYM_ENGINE_PATH IPC-only wrapper and test Mach service")
            return
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = AppState.shared
        guard state.permissions.isTrusted else {
            print("restart-error=Accessibility is unavailable; no permission prompt was requested")
            return
        }
        defer { state.engine.stopForTermination() }
        // Marking setup complete must not start management.
        state.completeOnboarding()
        print("after-onboarding=\(state.engine.state.label)")
        state.restartEngineFromUI()
        print("restart-immediate=\(String(describing: state.toasts.current?.kind)) \(state.toasts.current?.text ?? "none")")
        let deadline = Date().addingTimeInterval(12)
        while state.engine.state.isBusy, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        print("restart-final=\(state.engine.state) toast=\(String(describing: state.toasts.current?.kind)) \(state.toasts.current?.text ?? "none")")
        if state.engine.state.isRunning {
            let commands: [EngineCommand] = [.printState, .pinLeft, .pinRight, .showStrip]
                + ShortcutCatalog.actions(in: .jumpByNumber).map(\.command)
            for command in commands {
                print("ipc \(command)=\(await state.engine.send(command))")
            }
            state.restartEngineFromUI()
            print("replacement-immediate=\(state.toasts.current?.text ?? "none")")
            while state.engine.state.isBusy, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            print("replacement-final=\(state.engine.state) toast=\(state.toasts.current?.text ?? "none")")
            state.restartEngineFromUI()
            state.engine.stop()
            print("cancelled-toast=\(state.toasts.current?.text ?? "none")")
        }
    }

    /// Prints every setup check and the raw macOS preferences behind them.
    private static func diagnoseSetup(config: ConfigStore) {
        defer { withExtendedLifetime(config) {} }
        // AppKit must connect to the window server before querying effective Spaces.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let checker = MacSetupChecker()
        checker.configure(config: config)
        for check in checker.checks {
            print("\(check.id): \(check.state) — \(check.title)")
        }

        let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let trackpadKeys = ["TrackpadThreeFingerHorizSwipeGesture", "TrackpadFourFingerHorizSwipeGesture", "TrackpadThreeFingerDrag"]
        for domain in trackpadDomains {
            for key in trackpadKeys {
                printPreference(key, domain: domain)
            }
        }
        let currentHostKeys = ["com.apple.trackpad.threeFingerHorizSwipeGesture", "com.apple.trackpad.fourFingerHorizSwipeGesture", "com.apple.trackpad.threeFingerDragGesture"]
        for key in currentHostKeys {
            print("currentHost/\(key)=\(String(describing: MacSetupChecker.preference(key)))")
        }
        let otherKeys = [
            ("com.apple.dock", ["mru-spaces"]),
            ("com.apple.WindowManager", ["GloballyEnabled", "EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"]),
            ("com.apple.spaces", ["spans-displays"]),
        ]
        for (domain, keys) in otherKeys {
            for key in keys {
                printPreference(key, domain: domain)
            }
        }
    }

    private static func printPreference(_ key: String, domain: String) {
        print("\(domain)/\(key)=\(String(describing: MacSetupChecker.preference(key, domain: domain)))")
    }
}
