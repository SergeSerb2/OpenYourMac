import AppKit
import ServiceManagement

struct IntegrationError: LocalizedError {
    var message: String

    var errorDescription: String? { message }
}

// MARK: - Launch at login

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?
    private var observer: NSObjectProtocol?

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    var isRegistered: Bool { isEnabled || requiresApproval }

    init() {
        refresh()
        if !AppPaths.isSnapshot {
            // The user can change login items in System Settings while the app runs.
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        #if DEBUG
        if AppPaths.isSnapshot, ProcessInfo.processInfo.environment["OYM_LOGIN_ITEM_STATE"] == "approval" {
            status = .requiresApproval
            return
        }
        #endif
        status = SMAppService.mainApp.status
    }

    func openSettings() {
        guard !AppPaths.isSnapshot else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func setEnabled(_ enabled: Bool) {
        guard !AppPaths.isSnapshot else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            let change = enabled ? "add \(AppPaths.appName) to" : "remove \(AppPaths.appName) from"
            lastError = "Could not \(change) your login items: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: - Command-line tool

/// Manages the `~/.local/bin/openyourmac` symlink to the bundled CLI script.
@MainActor
final class CLIInstaller: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// A symlink to another file; the associated value is its destination.
        case pointsElsewhere(String)
        /// A regular file that the app never replaces.
        case blocked
    }

    @Published private(set) var status: Status = .notInstalled

    init() {
        refresh()
    }

    func refresh() {
        let link = AppPaths.cliLink
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let isOurs = resolved.path == AppPaths.cliScript.resolvingSymlinksInPath().path
            status = isOurs ? .installed : .pointsElsewhere(destination)
        } else {
            status = FileManager.default.fileExists(atPath: link.path) ? .blocked : .notInstalled
        }
    }

    func install(replaceExisting: Bool = false) throws {
        guard !PermissionManager.bundleIsTranslocated else {
            throw IntegrationError(message: "Move \(AppPaths.appName) to Applications and open it there before installing the command-line tool.")
        }
        refresh()
        if status == .blocked {
            throw IntegrationError(message: "A different file already exists at ~/.local/bin/openyourmac. Move it away, then try again.")
        }
        if case .pointsElsewhere = status, !replaceExisting {
            throw IntegrationError(message: "A link to another tool already exists at ~/.local/bin/openyourmac. Confirm replacement first.")
        }
        guard FileManager.default.fileExists(atPath: AppPaths.cliScript.path) else {
            throw IntegrationError(message: "The command-line tool is missing from this copy of \(AppPaths.appName). Reinstall the app and try again.")
        }
        do {
            let fileManager = FileManager.default
            let link = AppPaths.cliLink
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Only a confirmed foreign symlink can be replaced; never remove a file.
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: AppPaths.cliScript)
            refresh()
        } catch {
            refresh()
            throw IntegrationError(message: "Could not install the command-line tool: \(error.localizedDescription)")
        }
    }
}

// MARK: - Raycast

enum RaycastExporter {
    /// Copies into a new folder, preserving every existing export and user file.
    static func export(to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: AppPaths.raycastFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IntegrationError(message: "The Raycast scripts are missing from this copy of \(AppPaths.appName). Reinstall the app and try again.")
        }
        var target = destination.appendingPathComponent("\(AppPaths.appName) Raycast", isDirectory: true)
        // A UUID also avoids following an existing or dangling symlink.
        if (try? fileManager.attributesOfItem(atPath: target.path)) != nil {
            target = destination.appendingPathComponent("\(AppPaths.appName) Raycast \(UUID().uuidString)", isDirectory: true)
        }
        let staging = destination.appendingPathComponent(".oym-raycast-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            // copyItem preserves POSIX permissions, including script executable bits.
            try fileManager.copyItem(at: AppPaths.raycastFolder, to: staging)
            try fileManager.moveItem(at: staging, to: target)
            return target
        } catch {
            throw IntegrationError(message: "Could not export the Raycast scripts: \(error.localizedDescription)")
        }
    }
}
