import AppKit
import ApplicationServices

/// Tracks the Accessibility permission. Polls every 5 seconds, and every
/// second while someone waits for the permission to be granted.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var isTranslocated = PermissionManager.bundleIsTranslocated
    /// Callbacks for `waitForGrant`, each run once.
    private var callbacks: [() -> Void] = []
    private var timer: Timer?
    private var activation: NSObjectProtocol?

    init() {
        guard !AppPaths.isSnapshot else { return }
        schedule(interval: 5)
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
        if let activation {
            NotificationCenter.default.removeObserver(activation)
        }
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
        isTranslocated = Self.bundleIsTranslocated
        if isTrusted, !callbacks.isEmpty {
            let waiting = callbacks
            callbacks = []
            schedule(interval: 5)
            waiting.forEach { $0() }
        }
    }

    /// Shows the macOS permission prompt.
    func request() {
        guard !AppPaths.isSnapshot else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openAccessibilitySettings() {
        guard !AppPaths.isSnapshot,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Clears a stale permission entry (for example after an update), then asks again.
    func repair() {
        guard !AppPaths.isSnapshot else { return }
        Task {
            let bundleID = Bundle.main.bundleIdentifier ?? AppPaths.bundleIdentifier
            _ = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: ["reset", "Accessibility", bundleID], timeout: 5)
            request()
            openAccessibilitySettings()
        }
    }

    /// Calls `onGranted` once the permission is granted, immediately if it already is.
    func waitForGrant(onGranted: @escaping () -> Void) {
        refresh()
        if isTrusted {
            onGranted()
            return
        }
        callbacks.append(onGranted)
        if !AppPaths.isSnapshot {
            schedule(interval: 1)
        }
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// macOS runs a quarantined app from a random read-only path until it is moved.
    nonisolated static var bundleIsTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }
}
