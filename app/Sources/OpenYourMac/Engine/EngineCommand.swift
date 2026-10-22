import Foundation

/// A command for the running engine, as the argument vector that follows
/// `OpenYourMacEngine send-cmd` (for example `["window", "focus", "east"]`).
///
/// Binding names map one-to-one: `window_focus_east` ⇄ `window focus east`.
struct EngineCommand: Hashable, CustomStringConvertible {
    let arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    init(bindingName: String) {
        self.arguments = bindingName.split(separator: "_").map(String.init)
    }

    var bindingName: String { arguments.joined(separator: "_") }
    var description: String { arguments.joined(separator: " ") }

    // MARK: Common commands

    enum Direction: String, CaseIterable {
        case west, east, north, south, first, last
    }

    static func focus(_ d: Direction) -> EngineCommand { EngineCommand(["window", "focus", d.rawValue]) }
    static func swap(_ d: Direction) -> EngineCommand { EngineCommand(["window", "swap", d.rawValue]) }
    static func focus(index: Int) -> EngineCommand { EngineCommand(["window", "focus", String(index)]) }
    static func swap(index: Int) -> EngineCommand { EngineCommand(["window", "swap", String(index)]) }

    static let center = EngineCommand(["window", "center"])
    static let resize = EngineCommand(["window", "resize"])
    static let fullWidth = EngineCommand(["window", "fullwidth"])
    static let wider = EngineCommand(["window", "wider"])
    static let narrower = EngineCommand(["window", "narrower"])
    static let taller = EngineCommand(["window", "taller"])
    static let shorter = EngineCommand(["window", "shorter"])
    static let equalize = EngineCommand(["window", "equalize"])
    static let stack = EngineCommand(["window", "stack"])
    static let unstack = EngineCommand(["window", "unstack"])
    static let consumeEast = EngineCommand(["window", "consume", "east"])
    static let expelWest = EngineCommand(["window", "expel", "west"])
    static let tabbed = EngineCommand(["window", "tabbed"])
    static let manage = EngineCommand(["window", "manage"])
    static let nextDisplay = EngineCommand(["window", "nextdisplay"])
    static let pinLeft = EngineCommand(["window", "pin", "left"])
    static let pinRight = EngineCommand(["window", "pin", "right"])
    static let showStrip = EngineCommand(["strip", "show"])
    static let printState = EngineCommand(["printstate"])
    static let quit = EngineCommand(["quit"])
    static let pauseBindings = EngineCommand(["bindings", "pause"])
    static let resumeBindings = EngineCommand(["bindings", "resume"])

    // MARK: URL scheme allow-list

    /// Window operations reachable through `openyourmac://window/...`.
    /// Anything not in this set is ignored; nothing from a URL reaches the engine unchecked.
    static let urlAllowList: Set<EngineCommand> = {
        var set: Set<EngineCommand> = [
            EngineCommand(["window", "consume", "west"]), EngineCommand(["window", "expel", "east"]),
            center, resize, fullWidth, wider, narrower, taller, shorter, equalize,
            stack, unstack, consumeEast, expelWest, tabbed, manage, nextDisplay, pinLeft, pinRight,
        ]
        for d in Direction.allCases {
            set.insert(focus(d))
            set.insert(swap(d))
        }
        return set
    }()

    /// Maps the path of `openyourmac://window/<op>[/<arg>]` to a command, or nil if not allowed.
    /// `pathComponents` excludes the host, e.g. `["focus", "east"]` for `openyourmac://window/focus/east`.
    static func fromURLPath(_ pathComponents: [String]) -> EngineCommand? {
        let parts = pathComponents.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 2 else { return nil }
        let command = EngineCommand(["window"] + parts)
        return urlAllowList.contains(command) ? command : nil
    }
}
