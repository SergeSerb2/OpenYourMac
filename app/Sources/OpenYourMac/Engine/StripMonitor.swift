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
        /// 1-based strip column. Engines before this field omit it.
        var column: Int? = nil

        var id: Int { windowID }

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id", bundleID = "bundle_id", appName = "app_name"
            case title, focused, floating, displayID = "display_id", frame, visible, column
        }
    }

    struct Workspace: Decodable, Equatable {
        var number: Int
        var nativeWorkspaceID: UInt64
        var active: Bool
        /// Shown on its display now. Engines before this field omit it.
        var visible: Bool?
        /// The display that owns the strip. Engines before this field omit it.
        var displayID: UInt32?
        var windows: [Window]

        enum CodingKeys: String, CodingKey {
            case number, nativeWorkspaceID = "native_workspace_id", active, visible
            case displayID = "display_id", windows
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
    /// Every virtual workspace on this display's Space, for the switcher.
    var workspaces: [WorkspaceSummary] = []
    /// True for the display with keyboard focus.
    var isActive = false

    /// Any window on this display's current workspace, tiled or floating.
    var anyWindow: EngineSnapshot.Window? { columns.first?.windows.first ?? floating.first }

    /// The engine switches workspaces on the active display. Another display
    /// can be reached only through one of its windows.
    var canSwitchWorkspace: Bool { isActive || anyWindow != nil }

    struct WorkspaceSummary: Equatable, Identifiable {
        var number: Int
        var windowCount: Int
        var id: Int { number }
    }

    var id: UInt32 { displayID }

    /// The horizontal span that holds the screen and every column.
    var extent: ClosedRange<CGFloat> {
        let lower = min(viewport.minX, columns.map(\.frame.minX).min() ?? viewport.minX)
        let upper = max(viewport.maxX, columns.map(\.frame.maxX).max() ?? viewport.maxX)
        return lower...max(upper, lower + 1)
    }

    /// Builds one layout per display from the workspace each display shows.
    static func layouts(from snapshot: EngineSnapshot) -> [StripLayout] {
        // Every display shows one workspace. `active` marks only the one with
        // keyboard focus, so use `visible` as well when the engine reports it.
        var result: [UInt32: StripLayout] = [:]
        for workspace in snapshot.virtualWorkspaces where workspace.active || workspace.visible == true {
            let placed = workspace.windows.filter { $0.displayID != nil && $0.frame != nil }
            // A workspace belongs to one display. Parked windows can sit on a
            // neighbour, so trust the engine's owner; older engines fall back
            // to the display most of its windows are on.
            let counts = Dictionary(grouping: placed) { $0.displayID! }.mapValues(\.count)
            guard let displayID = workspace.displayID ?? counts.max(by: { $0.value < $1.value })?.key else { continue }
            if result[displayID] != nil, !workspace.active { continue }
            let viewport = CGDisplayBounds(displayID)
            let tiled = placed.filter { !$0.floating }
            let columns = tiled.allSatisfy({ $0.column != nil })
                ? logicalColumns(tiled, viewport: viewport)
                : columnsByFrame(tiled)
            result[displayID] = StripLayout(
                displayID: displayID,
                displayName: Self.name(of: displayID),
                viewport: viewport.isEmpty ? (columns.first?.frame ?? .zero) : viewport,
                columns: columns,
                floating: placed.filter { $0.floating && $0.bundleID != AppPaths.bundleIdentifier },
                workspaceNumber: workspace.number,
                workspaces: snapshot.virtualWorkspaces
                    .filter { $0.nativeWorkspaceID == workspace.nativeWorkspaceID }
                    .map { sibling in
                        WorkspaceSummary(
                            number: sibling.number,
                            windowCount: sibling.windows.filter { $0.bundleID != AppPaths.bundleIdentifier }.count
                        )
                    }
                    .sorted { $0.number < $1.number },
                isActive: workspace.active
            )
        }
        return result.values.sorted { $0.viewport.minX < $1.viewport.minX }
    }

    /// Places columns by strip order. Off-screen windows are parked at a display
    /// edge, so only a column that is fully on screen gives a true position.
    /// The others are laid out from it with their real widths.
    private static func logicalColumns(_ windows: [EngineSnapshot.Window], viewport: CGRect) -> [Column] {
        let grouped = Dictionary(grouping: windows) { $0.column ?? 0 }
        let keys = grouped.keys.sorted()
        let ordered = keys.map { key in
            grouped[key]!.sorted { $0.frame!.y < $1.frame!.y }
        }
        guard !ordered.isEmpty else { return [] }
        let widths = ordered.map { column in column.map { $0.frame!.width }.max() ?? 0 }
        // A parked window shows only a sliver. A column counts as on screen
        // when most of it, or most of the screen, shows it.
        let visibleWidths = ordered.map { column in
            column.map { $0.frame!.rect.intersection(viewport).width }.max() ?? 0
        }
        let onScreen = ordered.indices.map { index in
            visibleWidths[index] >= min(widths[index], viewport.width) * 0.6
        }
        let anchor = ordered.indices.first { onScreen[$0] && ordered[$0].contains(where: \.focused) }
            ?? ordered.indices.filter { onScreen[$0] }.max { visibleWidths[$0] < visibleWidths[$1] }
        // The gap between two neighbouring on-screen columns, when there are two.
        let gap = ordered.indices.dropLast().first { onScreen[$0] && onScreen[$0 + 1] }
            .map { ordered[$0 + 1][0].frame!.x - (ordered[$0][0].frame!.x + widths[$0]) }
            .map { min(max($0, 0), 64) } ?? 8
        var xs = Array(repeating: 0.0, count: ordered.count)
        let start = anchor ?? 0
        xs[start] = anchor.map { ordered[$0][0].frame!.x } ?? viewport.minX
        for index in stride(from: start + 1, to: ordered.count, by: 1) {
            xs[index] = xs[index - 1] + widths[index - 1] + gap
        }
        for index in stride(from: start - 1, through: 0, by: -1) {
            xs[index] = xs[index + 1] - widths[index] - gap
        }
        return ordered.enumerated().map { index, column in
            let top = column.map { $0.frame!.y }.min() ?? viewport.minY
            let bottom = column.map { $0.frame!.y + $0.frame!.height }.max() ?? viewport.maxY
            return Column(
                windows: column,
                frame: CGRect(x: xs[index], y: top, width: widths[index], height: bottom - top),
                number: keys[index]
            )
        }
    }

    /// Older engines: group windows that share a left edge.
    private static func columnsByFrame(_ windows: [EngineSnapshot.Window]) -> [Column] {
        let tiled = windows.sorted { ($0.frame!.x, $0.frame!.y) < ($1.frame!.x, $1.frame!.y) }
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
        return columns
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
    /// `OpenYourMacEngine subscribe --json`, while the map is visible.
    private var events: EngineEventStream?
    private var eventRefresh: DispatchWorkItem?

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

    /// Asks once now, even when no map is visible (the menu bar menu uses this).
    func refreshSoon() {
        guard !AppPaths.isSnapshot, engine?.state.isRunning == true else { return }
        Task { await refresh() }
    }

    /// Focuses a column from the map or the menu by its top window's ID, so
    /// the right window gets focus on any display, even while this app's own
    /// floating window is focused. Engines without `focuswindow` use the
    /// column number on the active display instead.
    func focus(_ column: StripLayout.Column, in layout: StripLayout) {
        guard let engine, let window = column.windows.first else { return }
        let isLast = column.number == layout.columns.map(\.number).max()
        Task {
            if case .failure = await engine.send(.focusWindow(window.windowID)) {
                if isLast {
                    await engine.send(.focus(.last))
                } else if column.number <= 8 {
                    await engine.send(.focus(index: column.number))
                } else if case .success = await engine.send(.focus(index: 8)) {
                    for _ in 0..<(column.number - 8) {
                        guard case .success = await engine.send(.focus(.east)) else { break }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await refresh()
        }
    }

    /// Shows another virtual workspace on a display. The engine switches the
    /// active display, so focus a window on another display first.
    func showWorkspace(_ number: Int, in layout: StripLayout) {
        guard let engine, number != layout.workspaceNumber, layout.canSwitchWorkspace else { return }
        Task {
            // The engine switches the active display's workspace. To reach
            // another display, focus one of its windows first.
            if !layout.isActive, let window = layout.anyWindow {
                guard case .success = await engine.send(.focusWindow(window.windowID)) else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if case .failure(let error) = await engine.send(EngineCommand(["window", "virtualnum", String(number)])) {
                NSLog("Could not switch workspace: %@", error.message)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await refresh()
        }
    }

    func setPreview(_ layouts: [StripLayout]) {
        self.layouts = layouts
        hasLoaded = true
    }

    /// While a map is visible, engine events trigger a query right away. A slow
    /// poll covers missed events, and a faster one runs if events are unavailable.
    private func updatePolling() {
        guard !AppPaths.isSnapshot else { return }
        let shouldPoll = viewers > 0 && windowVisible && engine?.state.isRunning == true
        if shouldPoll, task == nil {
            events = EngineEventStream { [weak self] in
                MainActor.assumeIsolated { self?.scheduleEventRefresh() }
            }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    let streaming = self?.events?.isRunning == true
                    try? await Task.sleep(nanoseconds: streaming ? 5_000_000_000 : 1_200_000_000)
                }
            }
        } else if !shouldPoll, let running = task {
            running.cancel()
            task = nil
            events?.stop()
            events = nil
            eventRefresh?.cancel()
            eventRefresh = nil
            if engine?.state.isRunning != true {
                layouts = []
                hasLoaded = false
            }
        }
    }

    /// Several events arrive together during one change; query once after them.
    private func scheduleEventRefresh() {
        guard task != nil else { return }
        eventRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { await self?.refresh() }
        }
        eventRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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

/// Runs `OpenYourMacEngine subscribe --json` and calls `onEvent` on the main
/// queue for each event line. The stream ends when the engine stops.
private final class EngineEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var buffer = Data()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning
    }

    init(onEvent: @escaping @Sendable () -> Void) {
        let pipe = Pipe()
        process.executableURL = AppPaths.engineBinary
        process.arguments = ["subscribe", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.buffer.append(data)
            var lines = 0
            while let newline = self.buffer.firstIndex(of: 10) {
                self.buffer.removeSubrange(...newline)
                lines += 1
            }
            // Keep memory bounded if a line never ends.
            if self.buffer.count > 1 << 20 { self.buffer.removeAll() }
            self.lock.unlock()
            if lines > 0 { DispatchQueue.main.async(execute: onEvent) }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [process] in
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    deinit { stop() }
}
