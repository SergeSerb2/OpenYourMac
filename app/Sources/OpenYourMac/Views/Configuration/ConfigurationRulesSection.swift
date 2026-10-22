import AppKit
import SwiftUI

struct ConfigurationRulesSection: View {
    @EnvironmentObject private var config: ConfigStore
    @State private var editor: ConfigurationRuleSelection?

    var body: some View {
        PageSection("Window Rules", caption: "Make an app's windows always float, or open at a fixed place in the strip") {
            Card(inset: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    if config.rules.isEmpty {
                        InfoNote(text: "Add rules to customize how specific apps behave", systemImage: "macwindow")
                            .padding(.vertical, 8)
                    }
                    ForEach(config.rules) { rule in
                        if rule.isHandEdited {
                            ConfigurationFileOnlyRow(keys: [rule.id == "(inline window rules)" ? "windows" : "windows.\(rule.id)"])
                        } else {
                            Button { editor = ConfigurationRuleSelection(rule: rule) } label: {
                                ConfigurationRuleRow(rule: rule)
                            }
                            .buttonStyle(TileButtonStyle())
                            .accessibilityLabel("Edit \(rule.displayName) rule")
                        }
                    }
                    Button { editor = ConfigurationRuleSelection(rule: nil) } label: {
                        Label("Add Window Rule", systemImage: "plus.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .sheet(item: $editor) { selection in
            WindowRuleEditorSheet(rule: selection.rule) { editor = nil }
        }
    }
}

private struct ConfigurationRuleSelection: Identifiable {
    var rule: WindowRule?
    var id: String { rule?.id ?? "new" }
}

private struct ConfigurationRuleRow: View {
    let rule: WindowRule

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            } else {
                IconDisc(systemImage: rule.id == "pip" ? "pip" : "macwindow", diameter: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.displayName)
                    .font(Theme.Font.rowTitleEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    Badge(text: rule.bundleID == nil ? "Any app" : (app?.name ?? rule.appName ?? rule.bundleID ?? "App"), systemImage: "app")
                    Badge(text: titleBadge, systemImage: "textformat")
                    Badge(text: rule.floating.rawValue, systemImage: rule.floating == .float ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.3x1")
                    if rule.floating != .float { Badge(text: placementBadge, systemImage: "rectangle.split.3x1") }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
    }

    private var app: ConfigurationRuleApp? {
        rule.bundleID.flatMap { ConfigurationRuleApp.resolve(bundleID: $0) }
    }

    private var titleBadge: String {
        switch rule.titleMatch {
        case .any: return "Any title"
        case .contains(let text): return text.isEmpty ? "Any title" : "Title contains \(text)"
        case .pattern: return "Custom title pattern"
        }
    }

    private var placementBadge: String {
        switch rule.placement {
        case .automatic: return "Automatic"
        case .start: return "Start of the strip"
        case .end: return "End of the strip"
        case .column(let index): return "Column \(index)"
        }
    }
}

struct ConfigurationRuleApp: Identifiable {
    var bundleID: String
    var name: String
    var icon: NSImage?
    var id: String { bundleID }

    static func resolve(bundleID: String) -> Self? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Self(bundleID: bundleID, name: displayName(at: url), icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    static func displayName(at url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static var running: [Self] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return Self(bundleID: id, name: app.localizedName ?? id, icon: app.icon)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
