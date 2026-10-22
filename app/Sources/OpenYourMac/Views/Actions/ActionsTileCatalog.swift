import Foundation

struct ActionsTile: Identifiable {
    let title: String
    let subtitle: String
    let symbol: String
    let command: EngineCommand
    var id: String { command.bindingName }
}

enum ActionsTileCatalog {
    /// Presentation overrides do not decide coverage: every catalog action gets a tile.
    static func tiles(in group: ShortcutGroup) -> [ActionsTile] {
        ShortcutCatalog.actions(in: group).map { action in
            presentation[action.id] ?? ActionsTile(
                title: action.title, subtitle: action.subtitle,
                symbol: group == .jumpByNumber ? "number.square" : "rectangle.3.offgrid",
                command: action.command
            )
        }
    }

    static let focusPadCommands: Set<EngineCommand> = [
        .focus(.west), .focus(.east), .focus(.north), .focus(.south), first.command, last.command,
    ]

    private static let presentation: [String: ActionsTile] = {
        let extras = [
            ActionsTile(title: "Show Strip", subtitle: "Show the strip minimap", symbol: "rectangle.3.offgrid", command: .showStrip),
            ActionsTile(title: "Pin Left", subtitle: "Pin or unpin at left edge", symbol: "pin", command: .pinLeft),
            ActionsTile(title: "Pin Right", subtitle: "Pin or unpin at right edge", symbol: "pin", command: .pinRight),
        ]
        return Dictionary(uniqueKeysWithValues: (move + size + columns + displays + extras + [first, last, quit]).map { ($0.id, $0) })
    }()

    static let first = ActionsTile(title: "First", subtitle: "Jump to start", symbol: "arrow.left.to.line", command: .focus(.first))
    static let last = ActionsTile(title: "Last", subtitle: "Jump to end", symbol: "arrow.right.to.line", command: .focus(.last))

    static let move: [ActionsTile] = [
        ActionsTile(title: "Move Left", subtitle: "One place left", symbol: "arrow.left.square", command: .swap(.west)),
        ActionsTile(title: "Move Right", subtitle: "One place right", symbol: "arrow.right.square", command: .swap(.east)),
        ActionsTile(title: "Move to First", subtitle: "Start of the strip", symbol: "arrow.left.to.line.compact", command: .swap(.first)),
        ActionsTile(title: "Move to Last", subtitle: "End of the strip", symbol: "arrow.right.to.line.compact", command: .swap(.last)),
        ActionsTile(title: "Move Up", subtitle: "Up in its column", symbol: "arrow.up.square", command: .swap(.north)),
        ActionsTile(title: "Move Down", subtitle: "Down in its column", symbol: "arrow.down.square", command: .swap(.south)),
    ]

    static let size: [ActionsTile] = [
        ActionsTile(title: "Center", subtitle: "Middle of the screen", symbol: "arrow.down.forward.and.arrow.up.backward", command: .center),
        ActionsTile(title: "Resize", subtitle: "Cycle widths", symbol: "arrow.left.and.right", command: .resize),
        ActionsTile(title: "Full Width", subtitle: "Screen wide, or back", symbol: "arrow.left.and.right.square", command: .fullWidth),
        ActionsTile(title: "Wider", subtitle: "Grow column", symbol: "arrow.left.and.line.vertical.and.arrow.right", command: .wider),
        ActionsTile(title: "Narrower", subtitle: "Shrink column", symbol: "arrow.right.and.line.vertical.and.arrow.left", command: .narrower),
        ActionsTile(title: "Taller", subtitle: "In a stack", symbol: "arrow.up.and.line.horizontal.and.arrow.down", command: .taller),
        ActionsTile(title: "Shorter", subtitle: "In a stack", symbol: "arrow.down.and.line.horizontal.and.arrow.up", command: .shorter),
        ActionsTile(title: "Equal Heights", subtitle: "Even out a stack", symbol: "equal.square", command: .equalize),
    ]

    static let columns: [ActionsTile] = [
        ActionsTile(title: "Stack Left", subtitle: "Into left column", symbol: "square.stack.3d.down.right", command: .stack),
        ActionsTile(title: "Unstack", subtitle: "Own column again", symbol: "square.stack.3d.up", command: .unstack),
        ActionsTile(title: "Stack Right", subtitle: "Into right column", symbol: "arrow.right.to.line.compact", command: .consumeEast),
        ActionsTile(title: "Unstack Left", subtitle: "Out to the left", symbol: "arrow.left.to.line.compact", command: .expelWest),
        ActionsTile(title: "Tabs", subtitle: "One window at a time", symbol: "rectangle.stack", command: .tabbed),
    ]

    static let displays: [ActionsTile] = [
        ActionsTile(title: "Float / Unfloat", subtitle: "Out of the strip, or back", symbol: "square.on.square.dashed", command: .manage),
        ActionsTile(title: "Next Display", subtitle: "Send to next display", symbol: "rectangle.on.rectangle", command: .nextDisplay),
    ]

    static let printState = ActionsTile(title: "Print State", subtitle: "Details to the log", symbol: "doc.text.magnifyingglass", command: .printState)
    static let quit = ActionsTile(title: "Quit Window Manager", subtitle: "Stop managing windows", symbol: "power", command: .quit)
}
