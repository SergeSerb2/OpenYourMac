import AppKit
import Combine
import Sparkle

/// A release found in the signed update feed.
struct AvailableUpdate: Equatable {
    let version: String
    let build: String
    let date: Date?
    let size: UInt64
    let isCritical: Bool

    init(version: String, build: String, date: Date? = nil, size: UInt64 = 0, isCritical: Bool = false) {
        self.version = version
        self.build = build
        self.date = date
        self.size = size
        self.isCritical = isCritical
    }

    init(_ item: SUAppcastItem) {
        self.init(
            version: item.displayVersionString,
            build: item.versionString,
            date: item.date,
            size: item.contentLength,
            isCritical: item.isCriticalUpdate
        )
    }

    var sizeLabel: String? {
        size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : nil
    }
}

/// What the app knows about updates right now. Drives the Settings card, the
/// Overview banner, the sidebar badge, and the menu bar item.
enum UpdatePhase: Equatable {
    /// No check has finished since launch.
    case idle
    case checking
    case upToDate
    /// A newer release exists. The user has not installed it yet.
    case available(AvailableUpdate)
    /// The user chose to install. Sparkle downloads, verifies, and extracts it.
    case installing(AvailableUpdate)
    /// Downloaded and verified. It installs when the app quits, or now on request.
    case readyToInstall(AvailableUpdate)
    case failed(String)

    var update: AvailableUpdate? {
        switch self {
        case .available(let update), .installing(let update), .readyToInstall(let update): return update
        default: return nil
        }
    }
}

/// Why Sparkle cannot replace this copy of the app.
enum UpdateLocationProblem: Equatable {
    /// The app runs from a mounted disk image.
    case diskImage
    /// macOS runs a quarantined copy from a random read-only path.
    case translocated

    var message: String {
        switch self {
        case .diskImage:
            return "\(AppPaths.appName) is running from the disk image. Drag it to Applications and open it from there to get updates."
        case .translocated:
            return "macOS opened \(AppPaths.appName) from a temporary location. Move it to Applications and open it again to get updates."
        }
    }

    static var current: UpdateLocationProblem? {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        return nil
    }
}

/// Sparkle owns scheduling, signature checks, installation, and relaunch.
/// This controller adds gentle reminders for a menu bar app, publishes the
/// update state for the app's own UI, and keeps the window manager's state
/// across an update relaunch.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheck: Date?
    /// True while a Sparkle window is on screen. The app shows its Dock icon then,
    /// so the update window is easy to find.
    @Published private(set) var isPresentingUpdateUI = false
    /// A scheduled update the user has not looked at yet. Shown as a badge.
    @Published private(set) var hasUnseenUpdate = false
    /// The version this launch replaced, when the app was just updated.
    @Published private(set) var updatedFrom: String?
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

    let locationProblem = AppPaths.isSnapshot ? nil : UpdateLocationProblem.current

    /// Called just before Sparkle quits the app to install and relaunch.
    var prepareForRelaunch: () -> Void = {}

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []

    enum Key {
        static let lastLaunchedBuild = "lastLaunchedBuild"
        static let lastLaunchedVersion = "lastLaunchedVersion"
        static let dismissedWhatsNew = "dismissedWhatsNewBuild"
        static let relaunchRestoreEngine = "updateRelaunchRestoreEngine"
        static let relaunchShowWindow = "updateRelaunchShowWindow"
    }

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
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }
            .store(in: &subscriptions)
        controller.startUpdater()
        lastUpdateCheck = updater.lastUpdateCheckDate
        if let problem = locationProblem {
            phase = .failed(problem.message)
        }
    }

    /// Checks now, or brings an update that is already in progress to the front.
    func checkForUpdates() {
        if let installNow {
            installNow()
            return
        }
        guard let controller, canCheckForUpdates else { return }
        hasUnseenUpdate = false
        controller.checkForUpdates(nil)
    }

    /// The menu and buttons use one action for "check", "show update", and "restart".
    var primaryActionTitle: String {
        switch phase {
        case .available(let update): return "Install \(update.version)…"
        case .readyToInstall: return "Restart to Update"
        case .installing: return "Show Progress…"
        case .checking: return "Checking…"
        default: return "Check for Updates…"
        }
    }

    var primaryActionEnabled: Bool {
        if case .readyToInstall = phase { return true }
        if case .checking = phase { return false }
        return canCheckForUpdates && locationProblem == nil
    }

    func dismissWhatsNew() {
        UserDefaults.standard.set(AppPaths.appBuild, forKey: Key.dismissedWhatsNew)
        updatedFrom = nil
    }

    /// Detects the first launch after an update. Call once, early in launch.
    func recordLaunch() {
        guard !AppPaths.isSnapshot else { return }
        let defaults = UserDefaults.standard
        let current = Int(AppPaths.appBuild) ?? 0
        if let previous = defaults.string(forKey: Key.lastLaunchedBuild).flatMap(Int.init), previous < current,
           defaults.string(forKey: Key.dismissedWhatsNew) != AppPaths.appBuild {
            updatedFrom = defaults.string(forKey: Key.lastLaunchedVersion) ?? "an earlier version"
        }
        defaults.set(AppPaths.appBuild, forKey: Key.lastLaunchedBuild)
        defaults.set(AppPaths.appVersion, forKey: Key.lastLaunchedVersion)
    }

    private func finishCheck() {
        lastUpdateCheck = controller?.updater.lastUpdateCheckDate ?? Date()
    }

    nonisolated private static func message(for error: Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return "Could not reach the update server. Check your internet connection and try again."
        }
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case Int(SUError.runningFromDiskImageError.rawValue): return UpdateLocationProblem.diskImage.message
            case Int(SUError.runningTranslocated.rawValue): return UpdateLocationProblem.translocated.message
            case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue):
                return "The update failed its signature check, so it was not installed."
            case Int(SUError.downloadError.rawValue):
                return "The update could not be downloaded. Try again later."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Snapshot previews

    /// Offscreen snapshots show each update state without network access.
    func setPreview(_ phase: UpdatePhase, lastCheck: Date? = nil, updatedFrom: String? = nil) {
        self.phase = phase
        lastUpdateCheck = lastCheck
        canCheckForUpdates = true
        hasUnseenUpdate = phase.update != nil
        self.updatedFrom = updatedFrom
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateChecker: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        MainActor.assumeIsolated {
            if phase.update == nil { phase = .checking }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = AvailableUpdate(item)
        MainActor.assumeIsolated {
            if case .readyToInstall = phase { return }
            phase = .available(update)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated {
            phase = .upToDate
            hasUnseenUpdate = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let update = AvailableUpdate(updateItem)
        MainActor.assumeIsolated {
            hasUnseenUpdate = false
            switch choice {
            case .install: phase = .installing(update)
            case .skip: phase = .upToDate
            case .dismiss: if case .installing = phase {} else { phase = .available(update) }
            @unknown default: break
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let update = AvailableUpdate(item)
        MainActor.assumeIsolated {
            installNow = immediateInstallHandler
            phase = .readyToInstall(update)
        }
        // The app offers "Restart to Update"; Sparkle still installs on quit.
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let code = (error as NSError).code
        let domain = (error as NSError).domain
        let message = Self.message(for: error)
        MainActor.assumeIsolated {
            guard domain == SUSparkleErrorDomain else {
                phase = .failed(message)
                return
            }
            switch code {
            case Int(SUError.noUpdateError.rawValue): phase = .upToDate
            case Int(SUError.installationCanceledError.rawValue), Int(SUError.installationAuthorizeLaterError.rawValue):
                if let update = phase.update { phase = .available(update) }
            default: phase = .failed(message)
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            if case .checking = phase { phase = .upToDate }
            finishCheck()
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { prepareForRelaunch() }
    }
}

// MARK: - Gentle reminders

extension UpdateChecker: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Near launch, Sparkle shows the update at once. Later, the app shows a badge
    /// instead of putting an alert in front of the user's work.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let found = AvailableUpdate(update)
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if phase.update == nil { phase = .available(found) }
            if handleShowingUpdate {
                isPresentingUpdateUI = true
            } else if !userInitiated {
                hasUnseenUpdate = true
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            hasUnseenUpdate = false
            isPresentingUpdateUI = true
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            isPresentingUpdateUI = false
        }
    }
}
