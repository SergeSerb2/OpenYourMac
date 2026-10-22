import Foundation
import Darwin

/// Why the engine is not running.
enum EngineFailure: Equatable {
    /// macOS has not allowed OpenYourMac to control windows.
    case accessibilityMissing
    /// The config file could not be read. `message` is the engine's error, `line` when known.
    case configError(message: String, line: Int?)
    /// The engine binary is not in the bundle.
    case binaryMissing
    /// The engine kept exiting; auto-restart gave up. `lastLines` are the log tail.
    case crashed(lastLines: [String])
    /// Starting the process failed.
    case launchFailed(String)
    /// Another engine instance owns the Mach service.
    case alreadyRunning
}

enum EngineState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(EngineFailure)

    var isRunning: Bool { self == .running }
    var isBusy: Bool { self == .starting || self == .stopping }

    var label: String {
        switch self {
        case .stopped, .failed: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        }
    }
}

enum EngineClientError: Error, Equatable {
    case notRunning
    case connectionFailed(String)
    case rejected(String)

    var message: String {
        switch self {
        case .notRunning: return "The window manager is not running. Start it first."
        case .connectionFailed(let detail): return "Unable to connect to the window manager: \(detail)"
        case .rejected(let detail): return "Failed to send action: \(detail)"
        }
    }
}

/// Starts, stops, and supervises the engine process and sends it commands.
///
/// CONTRACT for views: observe `state` and `recentLog`; call `start()`,
/// `stop()`, `restart()`, `toggle()`, and `send(_:)`.
@MainActor
final class EngineController: ObservableObject {
    @Published private(set) var state: EngineState = .stopped
    @Published private(set) var recentLog: [String] = []
    @Published private(set) var engineVersion: String = "—"

    private weak var config: ConfigStore?
    private weak var preferences: Preferences?
    private weak var permissions: PermissionManager?
    private var process: Process?
    /// Used only by the bounded application-termination path.
    private var exitSignal: DispatchSemaphore?
    private var logHandle: FileHandle?
    private var logTimer: Timer?
    private var restartTask: Task<Void, Never>?
    private var startedAt = Date.distantPast
    private var crashes: [Date] = []
    /// Set while a `quit` command is in flight, so the exit is not treated as a crash.
    private var expectedQuit = false
    private var versionRequested = false
    private var stoppingOutcome: EngineState?
    private var restartAfterStop = false
    private var restartCompletion: ((EngineState) -> Void)?
    private var mainWindowVisible = false
    private var logStamp: (size: UInt64, modified: Date)?

    // MARK: Tuning

    /// A child that is still alive after this long counts as running.
    private static let startupGracePeriod: TimeInterval = 0.8
    private static let stopTimeout: TimeInterval = 3
    private static let killTimeout: TimeInterval = 0.5
    private static let maxRestarts = 3
    private static let crashWindow: TimeInterval = 60
    private static let logTailBytes: UInt64 = 128 * 1024
    private static let logTrimThreshold = 5 * 1024 * 1024
    private static let logTrimmedSize: UInt64 = 1024 * 1024
    private static let failureLogLines = 10
    private static let diagnosisLogLines = 20
    private static let startupFailureWindow: TimeInterval = 10
    private static let recentLogLines = 40
    private static let launchMarker = "=== Window manager started "

    init() {}

    func configure(config: ConfigStore, preferences: Preferences, permissions: PermissionManager? = nil) {
        self.config = config
        self.preferences = preferences
        self.permissions = permissions
        if !AppPaths.isSnapshot {
            readVersion()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !AppPaths.isSnapshot, process == nil, state != .stopping else { return }
        cancelRestart()
        crashes = []
        launch()
    }

    /// UI shutdown returns immediately. didExit completes the transition.
    func stop(failure: EngineFailure? = nil) {
        cancelRestart()
        finishRestart(with: failure.map { .failed($0) } ?? .stopped)
        restartAfterStop = false
        let outcome: EngineState = failure.map { .failed($0) } ?? .stopped
        guard let child = process else {
            transition(outcome)
            return
        }
        stoppingOutcome = outcome
        transition(.stopping)
        if child.isRunning {
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.stopTimeout) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        } else {
            didExit(child)
        }
    }

    /// NSApplication cannot await child termination after willTerminate returns.
    func stopForTermination() {
        cancelRestart()
        finishRestart(with: .stopped)
        restartAfterStop = false
        guard let child = process else { return }
        transition(.stopping)
        process = nil
        if child.isRunning {
            child.terminate()
            if exitSignal?.wait(timeout: .now() + Self.stopTimeout) == .timedOut, child.isRunning {
                Darwin.kill(child.processIdentifier, SIGKILL)
                _ = exitSignal?.wait(timeout: .now() + Self.killTimeout)
            }
        }
        stoppingOutcome = nil
        exitSignal = nil
        stopLogTimer()
        transition(.stopped)
        refreshLog()
        closeLogHandle()
    }

    func restart(completion: ((EngineState) -> Void)? = nil) {
        guard !AppPaths.isSnapshot else { return }
        stop()
        restartCompletion = completion
        if process == nil { start() }
        else { restartAfterStop = true }
    }

    private func finishRestart(with outcome: EngineState) {
        let completion = restartCompletion
        restartCompletion = nil
        completion?(outcome)
    }

    func toggle() {
        if state.isRunning || state == .starting {
            stop()
        } else {
            start()
        }
    }

    private func launch() {
        guard process == nil, !AppPaths.isSnapshot else { return }
        permissions?.refresh()
        guard permissions?.isTrusted != false else {
            transition(.failed(.accessibilityMissing))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: AppPaths.engineBinary.path) else {
            transition(.failed(.binaryMissing))
            return
        }
        do {
            let handle = try openLogForLaunch()
            let child = Process()
            let done = DispatchSemaphore(value: 0)
            child.executableURL = AppPaths.engineBinary
            child.arguments = ["launch"]
            child.environment = launchEnvironment()
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = handle
            child.standardError = handle
            child.terminationHandler = { [weak self] child in
                done.signal()
                Task { @MainActor [weak self] in self?.didExit(child) }
            }
            process = child
            exitSignal = done
            expectedQuit = false
            stoppingOutcome = nil
            startedAt = Date()
            transition(.starting)
            try child.run()
            readVersion()
            scheduleLogTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupGracePeriod) { [weak self, weak child] in
                guard let self, let child, self.process === child else { return }
                self.tick()
            }
        } catch {
            process = nil
            exitSignal = nil
            closeLogHandle()
            transition(.failed(.launchFailed(error.localizedDescription)))
        }
    }

    /// Opens the engine log for appending, writes the launch header, and keeps the handle.
    private func openLogForLaunch() throws -> FileHandle {
        try FileManager.default.createDirectory(at: AppPaths.logDirectory, withIntermediateDirectories: true)
        trimLog()
        let descriptor = Darwin.open(AppPaths.engineLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        logHandle = handle
        let date = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: Data("\n\(Self.launchMarker)\(date) (OpenYourMac \(AppPaths.appVersion)) ===\n".utf8))
        return handle
    }

    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["OYM_ASSUME_APP_AX"] = "1"
        environment["OPENYOURMAC_CONFIG"] = configPath
        environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: "RUST_LOG")
        return environment
    }

    private var configPath: String { (config?.fileURL ?? AppPaths.configFile).path }

    private func cancelRestart() {
        restartTask?.cancel()
        restartTask = nil
    }

    // MARK: Commands

    @discardableResult
    func send(_ command: EngineCommand) async -> Result<Void, EngineClientError> {
        guard state.isRunning else { return .failure(.notRunning) }
        let isQuit = command == .quit
        if isQuit {
            expectedQuit = true
        }
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["OPENYOURMAC_CONFIG"] = configPath
        let result = await ProcessRunner.run(AppPaths.engineBinary, arguments: ["send-cmd"] + command.arguments, timeout: 2, environment: environment)
        if result.status != 0 {
            if isQuit {
                expectedQuit = false
            }
            return .failure(.connectionFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(())
    }

    func setPreviewState(_ newState: EngineState) { state = newState }

    func setDetailedLogging(_ on: Bool) {
        config?.set(\.detailedLogging, on)
        preferences?.detailedLogging = config?.options.detailedLogging ?? on
    }

    // MARK: Supervision

    private func tick() {
        refreshLog()
        if state == .starting, let child = process, child.isRunning, Date().timeIntervalSince(startedAt) >= Self.startupGracePeriod {
            transition(.running)
        }
        trimLog()
    }

    private func didExit(_ child: Process) {
        guard process === child else { return }
        refreshLog()
        let lines = launchLogLines()
        process = nil
        exitSignal = nil
        stopLogTimer()
        closeLogHandle()
        let uptime = Date().timeIntervalSince(startedAt)
        let failure = uptime <= Self.startupFailureWindow ? Self.diagnoseFailure(from: Array(lines.suffix(Self.diagnosisLogLines))) : nil

        if let outcome = stoppingOutcome {
            stoppingOutcome = nil
            let restart = restartAfterStop
            transition(outcome)
            restartAfterStop = false
            if restart { start() }
            return
        }

        if expectedQuit {
            transition(.stopped)
            return
        }
        if child.terminationReason == .exit, child.terminationStatus == 0 {
            transition(.stopped)
            return
        }
        if let failure {
            transition(.failed(failure))
            return
        }
        crashes = crashes.filter { Date().timeIntervalSince($0) < Self.crashWindow }
        crashes.append(Date())
        guard crashes.count <= Self.maxRestarts else {
            transition(.failed(.crashed(lastLines: Array(lines.suffix(Self.failureLogLines)))))
            return
        }
        scheduleRestart(afterExitStatus: child.terminationStatus)
    }

    /// Restarts after 1, 2, then 4 seconds.
    private func scheduleRestart(afterExitStatus status: Int32) {
        let delay = pow(2.0, Double(crashes.count - 1))
        appendLog("[OpenYourMac] Unexpected exit status \(status); restart \(crashes.count)/\(Self.maxRestarts) in \(Int(delay)) s")
        transition(.starting)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    /// Recognises failures that a restart cannot fix from the engine's output.
    private static func diagnoseFailure(from lines: [String]) -> EngineFailure? {
        let text = lines.joined(separator: "\n")
        let lower = text.lowercased()
        let accessibilityPhrases = ["required", "missing", "not trusted", "not granted", "denied"]
        let configPhrases = [
            "toml parse", "config error", "configuration error", "invalid type", "unknown field", "unknown variant",
            "missing field", "too many dashes", "invalid modifier", "regex parse error", "duplicate key", "invalid key",
        ]
        let alreadyRunningPhrases = ["already running", "already-running", "address already in use", "another instance"]

        if lower.contains("accessibility") && accessibilityPhrases.contains(where: lower.contains) {
            return .accessibilityMissing
        }
        if configPhrases.contains(where: lower.contains) {
            return .configError(message: lines.suffix(failureLogLines).joined(separator: "\n"), line: ProcessRunner.errorLine(text))
        }
        if alreadyRunningPhrases.contains(where: lower.contains) {
            return .alreadyRunning
        }
        if lower.contains("display has separate spaces") || lower.contains("displays have separate spaces") {
            // Preserve EngineFailure's exhaustive public API.
            return .launchFailed("Turn on ‘Displays have separate Spaces’ in Desktop & Dock, then log out and back in.")
        }
        return nil
    }

    private func transition(_ next: EngineState) {
        state = next
        switch next {
        case .running, .failed: finishRestart(with: next)
        case .stopped where !restartAfterStop: finishRestart(with: next)
        default: break
        }
        var line = "[OpenYourMac] State: \(next.label)"
        if case .failed(let reason) = next {
            line += " (\(reason))"
        }
        appendLog(line)
    }

    // MARK: Log

    func setMainWindowVisible(_ visible: Bool) {
        guard mainWindowVisible != visible else { return }
        mainWindowVisible = visible
        if process != nil { scheduleLogTimer() }
    }

    private func scheduleLogTimer() {
        stopLogTimer()
        let timer = Timer(timeInterval: mainWindowVisible ? 1 : 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        logTimer = timer
    }

    private func stopLogTimer() {
        logTimer?.invalidate()
        logTimer = nil
    }

    private func closeLogHandle() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func appendLog(_ line: String) {
        guard !AppPaths.isSnapshot else { return }
        let data = Data((line + "\n").utf8)
        if let logHandle {
            try? logHandle.write(contentsOf: data)
        } else if let handle = try? FileHandle(forWritingTo: AppPaths.engineLog) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// The last 128 KB of the log.
    private func logTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: AppPaths.engineLog) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > Self.logTailBytes ? end - Self.logTailBytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Engine output since the last launch, without colour codes, app notes, or detail lines.
    private func launchLogLines() -> [String] {
        let all = logTail().components(separatedBy: .newlines)
        let start = all.lastIndex { $0.hasPrefix(Self.launchMarker) }.map { $0 + 1 } ?? 0
        return all.dropFirst(start)
            .suffix(Self.diagnosisLogLines)
            .map { $0.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("[OpenYourMac]") && !$0.contains("] [detail] ") }
    }

    private func refreshLog() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.engineLog.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return }
        let stamp = (size.uint64Value, modified)
        if let logStamp, logStamp == stamp { return }
        logStamp = stamp
        let lines = logTail().components(separatedBy: .newlines).filter { !$0.isEmpty }
        let recent = Array(lines.suffix(Self.recentLogLines))
        if recent != recentLog { recentLog = recent }
    }

    /// Cuts a log over 5 MB down to its last 1 MB, starting at a line boundary.
    private func trimLog() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: AppPaths.engineLog.path)[.size] as? NSNumber,
              size.intValue > Self.logTrimThreshold,
              let handle = try? FileHandle(forUpdating: AppPaths.engineLog)
        else { return }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end - Self.logTrimmedSize)
            var tail = try handle.readToEnd() ?? Data()
            if let newline = tail.firstIndex(of: 10) {
                tail = tail.suffix(from: tail.index(after: newline))
            }
            // Keep the inode: the child still writes through its O_APPEND descriptor.
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tail)
            try handle.truncate(atOffset: UInt64(tail.count))
        } catch {
            // Logging must not stop supervision.
        }
    }

    private func readVersion() {
        guard !versionRequested, !AppPaths.isSnapshot, FileManager.default.isExecutableFile(atPath: AppPaths.engineBinary.path) else { return }
        versionRequested = true
        Task { [weak self] in
            let result = await ProcessRunner.run(AppPaths.engineBinary, arguments: ["--version"])
            if result.status == 0 {
                self?.engineVersion = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
