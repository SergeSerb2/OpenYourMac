import Foundation

/// Every file location the app uses, in one place.
enum AppPaths {
    static var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }

    static let appName = "OpenYourMac"
    static let bundleIdentifier = "com.openyourmac.OpenYourMac"
    static let urlScheme = "openyourmac"
    static let cliName = "openyourmac"
    static let engineBinaryName = "OpenYourMacEngine"

    /// The home folder. Honours `$HOME` so tests can point the app at a scratch folder.
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.config/openyourmac/openyourmac.toml`
    static var configFile: URL {
        home.appendingPathComponent(".config/openyourmac/openyourmac.toml")
    }

    /// `~/Library/Logs/OpenYourMac/`
    static var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
    }

    /// `~/Library/Logs/OpenYourMac/engine.log`
    static var engineLog: URL { logDirectory.appendingPathComponent("engine.log") }

    /// Mach service the engine listens on. The app never talks to it
    /// directly; it runs `OpenYourMacEngine send-cmd …`.
    static let engineMachService = "com.openyourmac.engine"

    /// `~/.local/bin/openyourmac`
    static var cliLink: URL { home.appendingPathComponent(".local/bin/\(cliName)") }

    // MARK: Bundle resources

    static var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    /// The bundled engine, or an explicit development/diagnostic override.
    /// Missing bundle resources never fall back to an unrelated installed engine.
    static var engineBinary: URL {
        if let override = ProcessInfo.processInfo.environment["OYM_ENGINE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return resources.appendingPathComponent(engineBinaryName)
    }

    static var defaultConfigTemplate: URL? {
        let url = resources.appendingPathComponent("default-config.toml")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var cliScript: URL { resources.appendingPathComponent("openyourmac-cli") }
    static var raycastFolder: URL { resources.appendingPathComponent("raycast", isDirectory: true) }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// `owner/repo` used for update checks and issue links.
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "OYMUpdateRepository") as? String ?? "SergeSerb2/OpenYourMac"
    }

    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var issuesURL: URL { URL(string: "https://github.com/\(repository)/issues/new")! }
    static var setupGuideURL: URL { URL(string: "https://github.com/\(repository)/blob/main/docs/setup.md")! }
    static let paneruURL = URL(string: "https://github.com/karinushka/paneru")!

    /// Shortens a path under the home folder to `~/…` for display.
    static func abbreviated(_ url: URL) -> String {
        let path = url.path
        let homePath = home.path
        return path.hasPrefix(homePath) ? "~" + path.dropFirst(homePath.count) : path
    }
}
