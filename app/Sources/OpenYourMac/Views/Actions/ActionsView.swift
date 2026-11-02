import AppKit
import SwiftUI

struct ActionsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var engine: EngineController
    @EnvironmentObject private var frontmost: FrontmostAppTracker
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var confirmsQuit = false
    @State private var query = ""

    var body: some View {
        PageScaffold(
            title: "Window Actions",
            subtitle: "Everything the shortcuts do, one click away. Each tile shows its shortcut.",
            accessory: { SearchField(prompt: "Find an action", text: $query) }
        ) {
            targetBanner
            if !query.isEmpty {
                searchResults
            } else {
                allSections
            }
        }
        .alert("Quit the window manager?", isPresented: $confirmsQuit) {
            Button("Quit Window Manager", role: .destructive) { send(.quit) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Window management will stop. You can start it again from Overview or the menu bar.")
        }
    }

    @ViewBuilder private var searchResults: some View {
        let matches = (ShortcutGroup.allCases.flatMap { ActionsTileCatalog.tiles(in: $0) } + [ActionsTileCatalog.printState])
            .filter { tile in
                let action = ShortcutCatalog.action(tile.command.bindingName)
                let keys = config.combos(for: tile.command.bindingName).map(\.displayString)
                return action?.matches(query, keys: keys + [tile.title, tile.subtitle])
                    ?? tile.title.localizedCaseInsensitiveContains(query)
            }
        if matches.isEmpty {
            EmptySearchResult(query: query)
        } else {
            PageSection("Results", caption: "\(matches.count) \(matches.count == 1 ? "action" : "actions")") {
                Card(inset: 16) {
                    TileGrid(columns: 4, spacing: 12) {
                        ForEach(matches) { tile($0) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var allSections: some View {
            PageSection("Focus", caption: ShortcutGroup.focus.caption) {
                focusPad
                TileGrid(columns: 3, spacing: 12) {
                    ForEach(ActionsTileCatalog.tiles(in: .focus).filter { !ActionsTileCatalog.focusPadCommands.contains($0.command) }) { tile($0) }
                }
            }
            ForEach(ShortcutGroup.allCases.filter { $0 != .focus && $0 != .other }) { group in
                if group == .jumpByNumber {
                    PageSection(group.title, caption: group.caption) { jumpPad }
                } else {
                    actionSection(group, columns: group == .moveWindow ? 3 : 4)
                }
            }
            PageSection("System", caption: "Troubleshooting and stopping") {
                Card(inset: 16) {
                    TileGrid(columns: 2, spacing: 12) {
                        tile(ActionsTileCatalog.printState)
                        ForEach(ActionsTileCatalog.tiles(in: .other)) { tile($0) }
                    }
                    InfoNote(text: "Print State writes what the window manager sees to its log, for troubleshooting.")
                        .padding(.top, 16)
                }
            }
    }

    /// Columns 1–8 and the last column, for focus and for moving the window.
    private var jumpPad: some View {
        Card(inset: 16) {
            VStack(alignment: .leading, spacing: 12) {
                numberRow(title: "Focus column", symbol: "scope", command: { EngineCommand.focus(index: $0) }, last: .focus(.last))
                CardDivider()
                numberRow(title: "Move window to", symbol: "arrow.left.arrow.right", command: { EngineCommand.swap(index: $0) }, last: .swap(.last))
            }
        }
    }

    private func numberRow(title: String, symbol: String, command: @escaping (Int) -> EngineCommand, last: EngineCommand) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(1...8, id: \.self) { number in
                    numberKey("\(number)", command: command(number))
                }
                numberKey("Last", command: last)
            }
        }
    }

    private func numberKey(_ label: String, command: EngineCommand) -> some View {
        let keys = glyphs(for: command)
        return Button { send(command) } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: label.count > 1 ? 11.5 : 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(keys.joined())
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(TileButtonStyle())
        .help(ShortcutCatalog.action(command.bindingName).map { "\($0.title): \($0.subtitle)" } ?? command.description)
        .accessibilityLabel(ShortcutCatalog.action(command.bindingName)?.title ?? command.description)
    }

    private var targetBanner: some View {
        Card(inset: 12) {
            HStack(spacing: 8) {
                targetIcon
                Text(bannerText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var targetIcon: some View {
        if !snapshotHasNoTarget, let bundleID = frontmost.lastBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.badge")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private var bannerText: String {
        if !engine.state.isRunning || snapshotIsStopped { return "The window manager is stopped. Start it to use these actions." }
        if !snapshotHasNoTarget, let name = frontmost.lastAppName {
            return "Actions apply to the last window you used (\(name))."
        }
        return "Click a window in another app first. These actions apply to the last window you used, never to this one."
    }

    // Debug snapshots accept OYM_ACTIONS_STATE=empty or stopped, without
    // changing the tracker or engine state.
    private var snapshotHasNoTarget: Bool {
        #if DEBUG
        return isSnapshot && ProcessInfo.processInfo.environment["OYM_ACTIONS_STATE"] == "empty"
        #else
        return false
        #endif
    }

    private var snapshotIsStopped: Bool {
        #if DEBUG
        return isSnapshot && ProcessInfo.processInfo.environment["OYM_ACTIONS_STATE"] == "stopped"
        #else
        return false
        #endif
    }

    private var focusPad: some View {
        Card(inset: 16) {
            HStack(spacing: 12) {
                tile(ActionsTileCatalog.first)
                VStack(spacing: 8) {
                    compact("Up", symbol: "arrow.up", command: .focus(.north))
                    HStack(spacing: 8) {
                        compact("Left", symbol: "arrow.left", command: .focus(.west))
                        compact("Right", symbol: "arrow.right", command: .focus(.east))
                    }
                    compact("Down", symbol: "arrow.down", command: .focus(.south))
                }
                .frame(maxWidth: .infinity)
                tile(ActionsTileCatalog.last)
            }
        }
    }

    private func actionSection(_ group: ShortcutGroup, columns: Int) -> some View {
        PageSection(group.title, caption: group.caption) {
            Card(inset: 16) {
                TileGrid(columns: columns, spacing: 12) {
                    ForEach(ActionsTileCatalog.tiles(in: group)) { tile($0) }
                }
            }
        }
    }

    private func compact(_ title: String, symbol: String, command: EngineCommand) -> some View {
        CompactActionTile(systemImage: symbol, title: title, glyphs: glyphs(for: command)) { send(command) }
            .frame(height: 88)
            .frame(maxWidth: .infinity)
    }

    private func tile(_ item: ActionsTile) -> some View {
        ActionTile(
            systemImage: item.symbol, title: item.title, subtitle: item.subtitle,
            glyphs: glyphs(for: item.command), tint: item.command == .quit ? Theme.danger : Theme.accent
        ) {
            if item.command == .quit, engine.state.isRunning {
                confirmsQuit = true
            } else {
                send(item.command)
            }
        }
    }

    private func glyphs(for command: EngineCommand) -> [String] {
        config.combos(for: command.bindingName).first?.glyphs ?? []
    }

    private func send(_ command: EngineCommand) {
        guard !isSnapshot else { return }
        state.performFromActionsPage(command)
    }
}

extension AppState {
    /// Restore the target app before asking the engine to use its focused window.
    func performFromActionsPage(_ command: EngineCommand) {
        guard engine.state.isRunning else {
            toasts.show("The window manager is stopped. Start it to use these actions.", kind: .warning)
            return
        }
        guard let bundleID = frontmost.lastBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: {
                  !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
              }) else {
            toasts.show("Click a window in another app first, then come back and try again.", kind: .warning)
            return
        }
        let activated: Bool
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
            activated = app.activate(from: .current, options: [])
        } else {
            activated = app.activate(options: [.activateIgnoringOtherApps])
        }
        guard activated else {
            toasts.show("Click a window in another app first, then come back and try again.", kind: .warning)
            return
        }
        Task {
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !app.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                toasts.show("Click a window in another app first, then come back and try again.", kind: .warning)
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                toasts.show("Click a window in another app first, then come back and try again.", kind: .warning)
                return
            }
            perform(command, successMessage: "Action sent")
        }
    }

    /// The base perform method has no completion result; only toast after a successful send.
    private func perform(_ command: EngineCommand, successMessage: String) {
        guard engine.state.isRunning else {
            toasts.show("The window manager is stopped. Start it to use these actions.", kind: .warning)
            return
        }
        Task {
            switch await engine.send(command) {
            case .success:
                toasts.show(successMessage, kind: .success, duration: 1.5)
            case .failure(let error):
                toasts.show(error.message, kind: .error)
            }
        }
    }
}
