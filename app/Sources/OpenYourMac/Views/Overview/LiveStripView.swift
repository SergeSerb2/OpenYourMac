import AppKit
import SwiftUI

/// A live map of each display's strip: columns in order, the part on screen,
/// and the focused window. Click a column to focus it.
struct LiveStripView: View {
    @EnvironmentObject private var strip: StripMonitor
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !engine.state.isRunning {
                placeholder("The live map appears while the window manager runs.", symbol: "pause.circle")
            } else if !strip.hasLoaded {
                placeholder("Reading your strip…", symbol: nil)
            } else if strip.layouts.allSatisfy({ $0.columns.isEmpty && $0.floating.isEmpty }) {
                placeholder("No windows on the strip yet. Open a window to see it here.", symbol: "macwindow")
            } else {
                ForEach(strip.layouts) { layout in
                    StripLane(layout: layout, showsDisplayName: strip.layouts.count > 1)
                }
            }
        }
        .onAppear { strip.setViewing(true) }
        .onDisappear { strip.setViewing(false) }
    }

    private func placeholder(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                .strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}

/// One display: a track with the screen bracket and the columns.
private struct StripLane: View {
    let layout: StripLayout
    let showsDisplayName: Bool
    @EnvironmentObject private var strip: StripMonitor

    private let laneHeight: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if showsDisplayName {
                    Image(systemName: "display").font(.system(size: 10.5))
                    Text(layout.displayName).font(.system(size: 11, weight: .semibold))
                    Text("·")
                }
                Text("\(layout.columns.count) \(layout.columns.count == 1 ? "column" : "columns")")
                    .font(.system(size: 11))
                if layout.workspaceNumber > 1 {
                    Text("· Workspace \(layout.workspaceNumber)").font(.system(size: 11))
                }
                Spacer()
                if let offscreen = offscreenSummary {
                    Text(offscreen).font(.system(size: 11))
                }
            }
            .foregroundStyle(Theme.textSecondary)

            GeometryReader { proxy in
                let width = proxy.size.width
                let extent = layout.extent
                let span = extent.upperBound - extent.lowerBound
                let scale = width / span
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.tileFill)
                    // The part of the strip that is on screen.
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.accent.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        )
                        .frame(width: max(layout.viewport.width * scale, 8), height: laneHeight)
                        .offset(x: (layout.viewport.minX - extent.lowerBound) * scale)
                        .accessibilityHidden(true)
                    ForEach(layout.columns) { column in
                        ColumnTile(column: column) { strip.focus(column, in: layout) }
                            .frame(width: max(column.frame.width * scale - 4, 10), height: laneHeight - 12)
                            .offset(x: (column.frame.minX - extent.lowerBound) * scale + 2, y: 6)
                    }
                }
            }
            .frame(height: laneHeight)

            if !layout.floating.isEmpty {
                HStack(spacing: 6) {
                    Text("Floating")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(layout.floating) { window in
                        HStack(spacing: 5) {
                            AppIconView(bundleID: window.bundleID, size: 14)
                            Text(window.appName).font(.system(size: 11)).lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.tileFill))
                        .overlay(Capsule().strokeBorder(window.focused ? Theme.accent : .clear, lineWidth: 1.5))
                    }
                }
            }
        }
    }

    /// "2 off screen", counting columns that lie fully outside the display.
    private var offscreenSummary: String? {
        let count = layout.columns.filter { !$0.frame.intersects(layout.viewport.insetBy(dx: 2, dy: 0)) }.count
        return count > 0 ? "\(count) off screen" : nil
    }
}

/// A column: one tile, or a stack of tiles split top to bottom.
private struct ColumnTile: View {
    let column: StripLayout.Column
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ForEach(column.windows) { window in
                    WindowTile(window: window, compact: column.windows.count > 1)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(column.isFocused ? Theme.accent.opacity(0.22) : Theme.contentBackground.opacity(hovering ? 1 : 0.9))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(column.isFocused ? Theme.accent : Color.primary.opacity(hovering ? 0.22 : 0.10), lineWidth: column.isFocused ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(column.windows.map { "\($0.appName): \($0.title)" }.joined(separator: "\n"))
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Focuses this column")
    }

    private var accessibilityText: String {
        let names = column.windows.map(\.appName).joined(separator: ", ")
        return "Column \(column.number): \(names)\(column.isFocused ? ", focused" : "")"
    }
}

private struct WindowTile: View {
    let window: EngineSnapshot.Window
    let compact: Bool

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 64
            VStack(spacing: 4) {
                AppIconView(bundleID: window.bundleID, size: compact || narrow ? 22 : 32)
                if !narrow && !compact {
                    Text(window.appName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// The app's Finder icon, looked up once per bundle identifier.
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[bundleID] = icon
        return icon
    }
}
