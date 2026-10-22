import AppKit
import SwiftUI
import Combine

/// Owns the local event monitors for exactly one capture session.
@MainActor
final class ShortcutsRecorder: ObservableObject {
    struct Slot: Equatable {
        let actionID: String
        let index: Int
    }

    @Published private(set) var slot: Slot?
    @Published private(set) var prompt = "Press keys…"
    @Published private(set) var error: String?
    @Published private(set) var isReady = false
    private var sessionID = UUID()
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var capture: ((Slot, KeyCombo) -> Void)?
    private var engine: EngineController?
    private var commandTask: Task<Void, Never>?
    private var pauseTimer: Timer?
    private var stateSubscription: AnyCancellable?

    func begin(_ slot: Slot, engine: EngineController, capture: @escaping (Slot, KeyCombo) -> Void) {
        cancel()
        self.slot = slot
        self.capture = capture
        error = nil
        isReady = false
        sessionID = UUID()
        let session = sessionID
        switch engine.state {
        case .starting, .stopping:
            fail("Wait for the window manager to finish starting or stopping, then try again.")
            return
        case .failed(.alreadyRunning):
            fail("Another window manager instance is running. Stop it before recording shortcuts.")
            return
        case .running:
            self.engine = engine
            pauseBindings(engine: engine, session: session)
        case .stopped, .failed:
            ready()
        }
        stateSubscription = engine.$state.dropFirst().sink { [weak self] _ in
            self?.fail("The window manager state changed. Start recording again.")
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.cancel() }
            return event
        }
    }

    private func pauseBindings(engine: EngineController, session: UUID) {
        setPrompt("Pausing shortcuts…")
        enqueue(.pauseBindings, engine: engine) { [weak self] result in
            guard let self, self.sessionID == session, self.slot != nil else { return }
            switch result {
            case .success:
                self.ready()
            case .failure(let failure): self.fail(failure.message)
            }
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.slot != nil, let engine = self.engine else { return }
                let session = self.sessionID
                self.isReady = false
                self.setPrompt("Renewing shortcut pause…")
                self.enqueue(.pauseBindings, engine: engine) { [weak self] result in
                    guard let self, self.sessionID == session, self.slot != nil else { return }
                    switch result {
                    case .success: self.isReady = true; self.setPrompt("Press keys…")
                    case .failure(let failure): self.fail(failure.message)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func ready() {
        isReady = true
        setPrompt("Press keys…")
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.receive(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func fail(_ message: String) {
        error = "Shortcut recording stopped: \(message)"
        cancel()
        announce(error!)
    }

    private func setPrompt(_ message: String) {
        guard prompt != message else { return }
        prompt = message
        announce(message)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func cancel() {
        guard slot != nil else { return }
        slot = nil
        sessionID = UUID()
        isReady = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        stateSubscription = nil
        capture = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        if let engine { enqueue(.resumeBindings, engine: engine) }
        engine = nil
    }

    private func receive(_ event: NSEvent) -> Bool {
        guard let slot else { return false }
        guard isReady else { return true }
        if event.type == .flagsChanged {
            let flags = event.modifierFlags
            let held: String = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "Fn")]
                .filter { flags.contains($0.0) }.map { $0.1 }.joined()
            setPrompt(held.isEmpty ? "Press keys…" : "\(held) Press keys…")
            return true
        }
        if event.keyCode == 53, event.modifierFlags.intersection([.control, .option, .shift, .command, .function]).isEmpty, event.modifierFlags.rawValue & 0x100 == 0 {
            cancel()
            return true
        }
        guard !event.isARepeat else { return true }
        guard let combo = KeyCombo(event: event) else {
            setPrompt("Unsupported key")
            return true
        }
        let isFunctionKey = combo.key.hasPrefix("f") && Int(combo.key.dropFirst()).map { (1...20).contains($0) } == true
        guard !combo.modifiers.isEmpty || isFunctionKey else {
            setPrompt("Add ⌘, ⌥, ⌃, ⇧ or Fn")
            return true
        }
        let handler = capture
        cancel()
        handler?(slot, combo)
        return true
    }

    /// A quick cancel/restart must not let an older pause arrive after a resume.
    private func enqueue(_ command: EngineCommand, engine: EngineController, completion: ((Result<Void, EngineClientError>) -> Void)? = nil) {
        let previous = commandTask
        commandTask = Task {
            await previous?.value
            let result = await engine.send(command)
            completion?(result)
        }
    }

    deinit {
        pauseTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let engine {
            let previous = commandTask
            Task {
                await previous?.value
                _ = await engine.send(.resumeBindings)
            }
        }
    }
}
