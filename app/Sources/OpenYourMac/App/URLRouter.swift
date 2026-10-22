import AppKit
import OSLog

/// Routes only typed, allow-listed commands. Background URLs never prompt.
@MainActor
final class URLRouter {
    private let state: AppState
    /// True once any openyourmac:// URL arrived; the launch reads it to stay quiet.
    private(set) var handledLaunchURL = false
    private(set) var handledLifecycleLaunchURL = false
    private var ready = false
    /// URLs that arrived before launch finished.
    private var pending: [URL] = []
    private let logger = Logger(subsystem: AppPaths.bundleIdentifier, category: "URLRouter")

    init(state: AppState) {
        self.state = state
    }

    func finishLaunching() {
        ready = true
        let queued = pending
        pending = []
        for url in queued {
            route(url)
        }
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == AppPaths.urlScheme else { return }
        handledLaunchURL = true
        let parts = routeParts(url)
        if !ready, url.user == nil, url.password == nil, url.port == nil,
           parts.count == 1, ["start", "stop", "restart", "toggle"].contains(parts[0]) {
            handledLifecycleLaunchURL = true
        }
        if ready {
            route(url)
        } else {
            pending.append(url)
        }
    }

    private func route(_ url: URL) {
        // The query and fragment never form command arguments.
        guard url.user == nil, url.password == nil, url.port == nil else {
            reject()
            return
        }
        // Accept both openyourmac://window/focus/west and openyourmac:window/focus/west.
        let parts = routeParts(url)
        guard let verb = parts.first else {
            reject()
            return
        }
        state.permissions.refresh()
        switch verb {
        case "start", "stop", "restart", "toggle":
            guard parts.count == 1 else {
                reject()
                return
            }
            performLifecycle(verb)
        case "window":
            guard let command = EngineCommand.fromURLPath(Array(parts.dropFirst())) else {
                reject()
                return
            }
            Task {
                let deadline = Date().addingTimeInterval(5)
                while !state.engine.state.isRunning, state.engine.state.isBusy, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                }
                guard state.engine.state.isRunning else {
                    logger.notice("Dropped URL command: the window manager did not become ready within 5 seconds")
                    return
                }
                if case .failure(let error) = await state.engine.send(command) {
                    logger.error("URL command failed: \(error.message, privacy: .public)")
                }
            }
        default:
            reject()
        }
    }

    /// Stopping is always allowed; starting needs the Accessibility permission.
    private func performLifecycle(_ verb: String) {
        guard verb == "stop" || state.preferences.onboardingCompleted else { return }
        let engine = state.engine
        let canStart = state.permissions.isTrusted && state.preferences.onboardingCompleted
        switch verb {
        case "stop":
            engine.stop()
        case "start":
            if canStart {
                engine.start()
            }
        case "restart":
            if canStart {
                engine.restart()
            }
        case "toggle":
            if engine.state.isRunning || engine.state == .starting {
                engine.stop()
            } else if canStart {
                engine.start()
            }
        default:
            break
        }
    }

    private func routeParts(_ url: URL) -> [String] {
        var parts = url.path.split(separator: "/").map(String.init)
        if let host = url.host, !host.isEmpty { parts.insert(host, at: 0) }
        return parts
    }

    private func reject() {
        logger.notice("Ignored an unsupported OpenYourMac URL")
    }
}
