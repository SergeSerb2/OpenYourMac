import Foundation
import Darwin

/// Short-lived engine/tool invocations, off the main actor. A temporary capture
/// file avoids full-pipe deadlocks and descendants keeping a pipe open forever.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Runs `executable` and returns its exit status and combined output.
    /// A timeout returns status -1 with "Command timed out." before the output.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 2, environment: [String: String]? = nil) async -> Result {
        let invocation = Invocation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                invocation.start(executable, arguments: arguments, timeout: timeout, environment: environment, continuation: continuation)
            }
        } onCancel: {
            invocation.cancel()
        }
    }

    /// The first line number mentioned in an error message, if any.
    static func errorLine(_ text: String) -> Int? {
        let patterns = [#"(?i)line\s+(\d+)"#, #"(?m)^\s*(\d+)\s*\|"#, #":(\d+):\d+"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let line = Int(text[range])
            else { continue }
            return line
        }
        return nil
    }

    /// All process and capture-file access is serialised on a Dispatch queue.
    /// The awaiting task suspends; cancellation also terminates check-config.
    private final class Invocation: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.openyourmac.process", qos: .utility)
        private let captureFile = FileManager.default.temporaryDirectory.appendingPathComponent("oym-process-\(UUID().uuidString)")
        private var process: Process?
        private var handle: FileHandle?
        private var continuation: CheckedContinuation<Result, Never>?
        private var cancelled = false
        private var timedOut = false

        func start(_ executable: URL, arguments: [String], timeout: TimeInterval, environment: [String: String]?, continuation: CheckedContinuation<Result, Never>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !self.cancelled else {
                    self.finish(status: -1, message: "Command cancelled.")
                    return
                }
                do {
                    _ = FileManager.default.createFile(atPath: self.captureFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let handle = try FileHandle(forWritingTo: self.captureFile)
                    self.handle = handle
                    let child = Process()
                    child.executableURL = executable
                    child.arguments = arguments
                    child.environment = environment
                    child.standardInput = FileHandle.nullDevice
                    child.standardOutput = handle
                    child.standardError = handle
                    child.terminationHandler = { child in
                        self.queue.async { self.finish(status: child.terminationStatus) }
                    }
                    self.process = child
                    try child.run()
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self, self.continuation != nil else { return }
                        self.timedOut = true
                        self.terminate()
                    }
                } catch {
                    self.finish(status: -1, message: error.localizedDescription)
                }
            }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                self.terminate()
            }
        }

        private func terminate() {
            guard let child = process, child.isRunning else { return }
            child.terminate()
            queue.asyncAfter(deadline: .now() + 0.2) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }

        private func finish(status: Int32, message: String? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            process?.terminationHandler = nil
            process = nil
            try? handle?.close()
            handle = nil
            let data = (try? Data(contentsOf: captureFile)) ?? Data()
            let output = String(decoding: data.suffix(128 * 1024), as: UTF8.self)
            try? FileManager.default.removeItem(at: captureFile)
            let prefix = message ?? (timedOut ? "Command timed out." : (cancelled ? "Command cancelled." : ""))
            continuation.resume(returning: Result(status: prefix.isEmpty ? status : -1, output: prefix.isEmpty ? output : prefix + "\n" + output))
        }
    }
}
