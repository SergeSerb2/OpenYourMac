import AppKit
import Combine

/// Checks GitHub Releases for a newer version, on request or once a day.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        var version: String
        var url: URL
    }

    @Published private(set) var isChecking = false
    @Published private(set) var available: Release?
    private var preferences: Preferences?
    private var timer: Timer?
    private var preferenceSubscription: AnyCancellable?

    deinit {
        timer?.invalidate()
    }

    func configure(preferences: Preferences) {
        self.preferences = preferences
        preferenceSubscription = preferences.$automaticallyCheckForUpdates
            .dropFirst()
            .sink { [weak self] enabled in
                DispatchQueue.main.async {
                    if enabled {
                        self?.startAutomaticChecks()
                    } else {
                        self?.stopAutomaticChecks()
                    }
                }
            }
    }

    /// A user-initiated check reports its result in an alert; an automatic one stays quiet.
    func checkNow(userInitiated: Bool) {
        guard !AppPaths.isSnapshot,
              !isChecking,
              let url = URL(string: "https://api.github.com/repos/\(AppPaths.repository)/releases/latest")
        else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let release = try await fetchNewerRelease(from: url)
                available = release
                preferences?.lastUpdateCheck = Date()
                if userInitiated {
                    presentResult(release)
                }
            } catch {
                // Count attempts too, to avoid repeated automatic requests while offline.
                preferences?.lastUpdateCheck = Date()
                if userInitiated {
                    showAlert("Could not check for updates", error.localizedDescription)
                }
            }
        }
    }

    func startAutomaticChecks() {
        guard !AppPaths.isSnapshot else { return }
        if preferences == nil {
            preferences = Preferences()
        }
        guard preferences?.automaticallyCheckForUpdates == true else { return }
        checkIfDue()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    /// Checks when the last check was at least a day ago.
    private func checkIfDue() {
        guard preferences?.automaticallyCheckForUpdates == true else { return }
        if Date().timeIntervalSince(preferences?.lastUpdateCheck ?? .distantPast) >= 86400 {
            checkNow(userInitiated: false)
        }
    }

    /// The latest release when it is newer than this app, or nil. A repository without releases (404) is not an error.
    private func fetchNewerRelease(from url: URL) async throws -> Release? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppPaths.appName)/\(AppPaths.appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError(message: "The update server returned an invalid response.")
        }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw IntegrationError(message: "The update server returned HTTP \(http.statusCode).")
        }
        struct Payload: Decodable {
            var tag_name: String
            var html_url: URL
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let latest = SemanticVersion(payload.tag_name), let current = SemanticVersion(AppPaths.appVersion) else {
            throw IntegrationError(message: "The release has an invalid version number.")
        }
        // Only offer release pages on github.com.
        guard current < latest, payload.html_url.scheme == "https", payload.html_url.host == "github.com" else {
            return nil
        }
        return Release(version: payload.tag_name, url: payload.html_url)
    }

    private func presentResult(_ release: Release?) {
        guard let release else {
            showAlert("You're up to date", "\(AppPaths.appName) \(AppPaths.appVersion) is the latest release.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(AppPaths.appName) \(release.version) is available"
        alert.informativeText = "Open the release page to download the update."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.url)
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// A `major.minor.patch[-prerelease][+build]` version, compared by SemVer precedence.
private struct SemanticVersion: Comparable {
    /// Always three numbers; missing minor and patch parts are 0.
    let numbers: [Int]
    let prerelease: [String]

    init?(_ string: String) {
        let raw = string.hasPrefix("v") ? String(string.dropFirst()) : string
        guard !raw.isEmpty, let withoutBuild = raw.split(separator: "+", maxSplits: 1).first else { return nil }
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        guard !parts.isEmpty else { return nil }
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.allSatisfy({ Int($0) != nil })
        else { return nil }
        numbers = components.compactMap { Int($0) } + Array(repeating: 0, count: 3 - components.count)
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers {
            return lhs.numbers.lexicographicallyPrecedes(rhs.numbers)
        }
        // A release sorts after its prereleases.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            // Numeric identifiers compare as numbers and sort before alphanumeric ones.
            if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
