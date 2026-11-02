import AppKit
import Combine

/// The engine's `query state` JSON. Field names follow `engine/src/types/state.rs`.
struct EngineSnapshot: Decodable, Equatable {
    struct Frame: Decodable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct Window: Decodable, Equatable, Identifiable {
        var windowID: Int
        var bundleID: String
        var appName: String
        var title: String
        var focused: Bool
        var floating: Bool
        var displayID: UInt32?
        var frame: Frame?
        var visible: Bool

        var id: Int { windowID }

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id", bundleID = "bundle_id", appName = "app_name"
            case title, focused, floating, displayID = "display_id", frame, visible
        }
    }

    struct Workspace: Decodable, Equatable {
        var number: Int
        var nativeWorkspaceID: UInt64
        var active: Bool
        var windows: [Window]

        enum CodingKeys: String, CodingKey {
            case number, nativeWorkspaceID = "native_workspace_id", active, windows
        }
    }

    var virtualWorkspaces: [Workspace]

    enum CodingKeys: String, CodingKey {
        case virtualWorkspaces = "virtual_workspaces"
    }
}

/// One display's strip, ready to draw: columns left to right, the visible
/// part of the strip, and windows that float above it.
struct StripLayout: Equatable, Identifiable {
    struct Column: Equatable, Identifiable {
        /// Top to bottom. Several windows mean a stack.
        var windows: [EngineSnapshot.Window]
        var frame: CGRect
        /// 1-based position used by `window focus <n>`.
        var number: Int

        var id: Int { windows.first?.windowID ?? number }
        var isFocused: Bool { windows.contains(where: \.focused) }
    }

    var displayID: UInt32
    var displayName: String
    /// The display in global top-left coordinates.
    var viewport: CGRect
    var columns: [Column]
    var floating: [EngineSnapshot.Window]
    var workspaceNumber: Int

    var id: UInt32 { displayID }

    /// The horizontal span that holds the screen and every column.
    var extent: ClosedRange<CGFloat> {
        let lower = min(viewport.minX, columns.map(\.frame.minX).min() ?? viewport.minX)
        let upper = max(viewport.maxX, columns.map(\.frame.maxX).max() ?? viewport.maxX)
        return lower...max(upper, lower + 1)
    }

    /// Builds one layout per display from the active workspaces.
    static func layouts(from snapshot: EngineSnapshot) -> [StripLayout] {
        var result: [StripLayout] = []
        for workspace in snapshot.virtualWorkspaces where workspace.active {
            let byDisplay = Dictionary(grouping: workspace.windows.filter { $0.displayID != nil && $0.frame != nil }) { $0.displayID! }
            for (displayID, windows) in byDisplay {
                let tiled = windows.filter { !$0.floating }.sorted { ($0.frame!.x, $0.frame!.y) < ($1.frame!.x, $1.frame!.y) }
                var columns: [Column] = []
                for window in tiled {
                    let rect = window.frame!.rect
                    if let last = columns.last, abs(last.frame.minX - rect.minX) < 4 {
                        columns[columns.count - 1].windows.append(window)
                        columns[columns.count - 1].frame = last.frame.union(rect)
                    } else {
                        columns.append(Column(windows: [window], frame: rect, number: columns.count + 1))
                    }
                }
                let viewport = CGDisplayBounds(displayID)
                result.append(StripLayout(
                    displayID: displayID,
                    displayName: Self.name(of: displayID),
                    viewport: viewport.isEmpty ? (columns.first?.frame ?? .zero) : viewport,
                    columns: columns,
                    floating: windows.filter(\.floating),
                    workspaceNumber: workspace.number
                ))
            }
        }
        return result.sorted { $0.viewport.minX < $1.viewport.minX }
    }

    private static func name(of displayID: UInt32) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.localizedName ?? "Display"
    }
}

/// Asks the running engine for its layout about once a second, only while
/// someone is looking at the live map.
@MainActor
final class StripMonitor: ObservableObject {
    @Published private(set) var layouts: [StripLayout] = []
    /// True after the first answer, so the view can tell "empty" from "loading".
    @Published private(set) var hasLoaded = false

    private weak var engine: EngineController?
    private var viewers = 0
    private var windowVisible = false
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    func configure(engine: EngineController) {
        self.engine = engine
        engine.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePolling() }
            }
            .store(in: &subscriptions)
    }

    /// Views call this on appear and disappear. Polling runs while one is visible.
    func setViewing(_ viewing: Bool) {
        viewers = max(0, viewers + (viewing ? 1 : -1))
        updatePolling()
    }

    /// Polling stops while the main window is hidden or covered.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updatePolling()
    }

    /// Asks again at once, for example after the user focuses a column.
    func refreshSoon() {
        guard task != nil else { return }
        Task { await refresh() }
    }

    /// Focuses a column from the map.
    func focus(_ column: StripLayout.Column, in layout: StripLayout) {
        guard let engine else { return }
        let isLast = column.number == layout.columns.count
        let command: EngineCommand? = isLast ? .focus(.last) : (column.number <= 8 ? .focus(index: column.number) : nil)
        Task {
            if let command {
                await engine.send(command)
            } else if let bundleID = column.windows.first?.bundleID {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await refresh()
        }
    }

    func setPreview(_ layouts: [StripLayout]) {
        self.layouts = layouts
        hasLoaded = true
    }

    private func updatePolling() {
        guard !AppPaths.isSnapshot else { return }
        let shouldPoll = viewers > 0 && windowVisible && engine?.state.isRunning == true
        if shouldPoll, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
        } else if !shouldPoll, let running = task {
            running.cancel()
            task = nil
            if engine?.state.isRunning != true {
                layouts = []
                hasLoaded = false
            }
        }
    }

    private func refresh() async {
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        let result = await ProcessRunner.run(AppPaths.engineBinary, arguments: ["query", "state", "--json"], timeout: 2, environment: environment)
        guard result.status == 0,
              let start = result.output.firstIndex(of: "{"),
              let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: Data(result.output[start...].utf8))
        else { return }
        let next = StripLayout.layouts(from: snapshot)
        if next != layouts { layouts = next }
        hasLoaded = true
    }
}
