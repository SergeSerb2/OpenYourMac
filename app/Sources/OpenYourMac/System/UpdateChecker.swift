import AppKit
import Combine
import Sparkle

/// Sparkle owns update scheduling, signature checks, installation, and relaunch.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheck: Date?
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []

    /// Start only during normal application launch. Diagnostics never create an updater.
    func start() {
        guard !AppPaths.isSnapshot, controller == nil else { return }
        // Preserve an existing opt-out when migrating from the release-page checker.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
           let previous = defaults.object(forKey: "automaticallyCheckForUpdates") as? Bool {
            defaults.set(previous, forKey: "SUEnableAutomaticChecks")
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }
            .store(in: &subscriptions)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
