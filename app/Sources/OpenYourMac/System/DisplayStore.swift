import AppKit
import CoreGraphics

/// Connected displays and whether OpenYourMac manages each one. Unmanaged
/// displays are listed by UUID in the config's `ignored_displays`.
@MainActor
final class DisplayStore: ObservableObject {
    @Published private(set) var displays: [ConnectedDisplay] = []
    private weak var config: ConfigStore?
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        if !AppPaths.isSnapshot {
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
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

    func configure(config: ConfigStore) {
        self.config = config
    }

    /// Same CFUUIDCreateString representation as engine/manager/display.rs.
    static func identity(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }

    /// Lists connected displays, main display first. Uses the online list so a
    /// sleeping display stays listed; mirror copies are skipped.
    func refresh() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        displays = ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .compactMap { id in
                guard let uuid = Self.identity(for: id) else { return nil }
                let screen = NSScreen.screens.first { $0.displayID == id }
                return ConnectedDisplay(
                    id: uuid,
                    name: screen?.localizedName ?? "Display",
                    pixelWidth: CGDisplayPixelsWide(id),
                    pixelHeight: CGDisplayPixelsHigh(id),
                    isMain: id == CGMainDisplayID()
                )
            }
            .sorted { $0.isMain && !$1.isMain }
    }

    // MARK: Management

    func isManaged(_ display: ConnectedDisplay) -> Bool { isManaged(display.id) }

    func isManaged(_ id: String) -> Bool {
        let ignored = config?.options.ignoredDisplays ?? []
        return !ignored.contains { Self.entry($0, matches: id) }
    }

    func setManaged(_ display: ConnectedDisplay, _ managed: Bool) { setManaged(display.id, managed) }

    func setManaged(_ id: String, _ managed: Bool) {
        guard let config else { return }
        var ignored = config.options.ignoredDisplays.filter { !Self.entry($0, matches: id) }
        if !managed {
            ignored.append(id)
        }
        config.set(\.ignoredDisplays, ignored)
    }

    /// Hand-edited entries may differ in case or surrounding whitespace.
    static func entry(_ entry: String, matches id: String) -> Bool {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(id.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

extension NSScreen {
    /// The Core Graphics display ID behind this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
