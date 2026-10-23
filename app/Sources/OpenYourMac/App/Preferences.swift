import Foundation

/// App-level preferences stored in UserDefaults (not in the engine config).
@MainActor
final class Preferences: ObservableObject {
    enum Key {
        static let startEngineAutomatically = "startEngineAutomatically"
        static let showWindowOnLaunch = "showWindowOnLaunch"
        static let showInDock = "showInDock"
        static let onboardingCompleted = "onboardingCompleted"
        static let macSetupIntroduced = "macSetupIntroduced"
        static let gettingStartedDismissed = "gettingStartedDismissed"
        static let detailedLogging = "detailedLogging"
        static let windowPositionSaved = "windowPositionSaved"
    }

    private let defaults: UserDefaults?
    private var volatileValues: [String: Any] = [:]

    @Published var startEngineAutomatically: Bool { didSet { set(startEngineAutomatically, forKey: Key.startEngineAutomatically) } }
    @Published var showWindowOnLaunch: Bool { didSet { set(showWindowOnLaunch, forKey: Key.showWindowOnLaunch) } }
    @Published var showInDock: Bool { didSet { set(showInDock, forKey: Key.showInDock) } }
    @Published var onboardingCompleted: Bool { didSet { set(onboardingCompleted, forKey: Key.onboardingCompleted) } }
    @Published var macSetupIntroduced: Bool { didSet { set(macSetupIntroduced, forKey: Key.macSetupIntroduced) } }
    @Published var gettingStartedDismissed: Bool { didSet { set(gettingStartedDismissed, forKey: Key.gettingStartedDismissed) } }
    @Published var detailedLogging: Bool { didSet { set(detailedLogging, forKey: Key.detailedLogging) } }

    var windowFrameSaved: Bool {
        get { defaults?.bool(forKey: Key.windowPositionSaved) ?? (volatileValues[Key.windowPositionSaved] as? Bool ?? false) }
        set { set(newValue, forKey: Key.windowPositionSaved) }
    }

    /// Snapshots never access a persistent preferences domain.
    init(defaults: UserDefaults? = AppPaths.isSnapshot ? nil : .standard) {
        self.defaults = defaults
        let initialValues: [String: Any] = [
            Key.startEngineAutomatically: true,
            Key.showWindowOnLaunch: true,
            Key.showInDock: true,
            Key.onboardingCompleted: false,
            Key.macSetupIntroduced: false,
            Key.gettingStartedDismissed: false,
            Key.detailedLogging: false,
        ]
        volatileValues = initialValues
        defaults?.register(defaults: initialValues)
        func flag(_ key: String) -> Bool { defaults?.bool(forKey: key) ?? (initialValues[key] as? Bool ?? false) }
        startEngineAutomatically = flag(Key.startEngineAutomatically)
        showWindowOnLaunch = flag(Key.showWindowOnLaunch)
        showInDock = flag(Key.showInDock)
        onboardingCompleted = flag(Key.onboardingCompleted)
        macSetupIntroduced = flag(Key.macSetupIntroduced)
        gettingStartedDismissed = flag(Key.gettingStartedDismissed)
        detailedLogging = flag(Key.detailedLogging)
    }

    private func set(_ value: Any?, forKey key: String) {
        if let defaults { defaults.set(value, forKey: key) }
        else { volatileValues[key] = value }
    }
}
