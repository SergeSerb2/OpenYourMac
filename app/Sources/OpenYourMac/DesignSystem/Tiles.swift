import SwiftUI

/// Action tile: icon disc, title, subtitle, and the shortcut's key caps.
/// Used on the Actions page.
struct ActionTile: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var glyphs: [String] = []
    var tint: Color = Theme.accent
    var height: CGFloat = 144
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                IconDisc(systemImage: systemImage, diameter: 48, tint: tint)
                    .padding(.bottom, 10)
                Text(title)
                    .font(Theme.Font.tileTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.Font.tileSubtitle)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 3)
                if !glyphs.isEmpty {
                    KeyCapRow(glyphs: glyphs, size: 18, spacing: 4)
                        .padding(.top, 10)
                }
            }
            .multilineTextAlignment(.center)
            .padding(12)
        }
        .buttonStyle(TileButtonStyle())
        .frame(height: height)
        .help(subtitle)
    }
}

/// Smaller directional tile used in the Actions page focus pad (Up/Left/…).
struct CompactActionTile: View {
    let systemImage: String
    let title: String
    var glyphs: [String] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                IconDisc(systemImage: systemImage, diameter: 30)
                    .padding(.bottom, 6)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !glyphs.isEmpty {
                    KeyCapRow(glyphs: glyphs, size: 16, spacing: 3)
                        .padding(.top, 6)
                }
            }
            .padding(8)
        }
        .buttonStyle(TileButtonStyle())
    }
}

/// Text-only tile with a title and caption (Overview quick actions).
struct QuickActionTile: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
        }
        .buttonStyle(TileButtonStyle(flat: true))
        .frame(height: 64)
    }
}

/// Grid helper: equal-width columns that wrap.
struct TileGrid<Content: View>: View {
    var columns: Int
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
            spacing: spacing,
            content: content
        )
    }
}

// MARK: - Toasts

enum ToastKind: Equatable {
    case success, info, warning, error

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return Theme.success
        case .info: return Theme.accent
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let kind: ToastKind
    let text: String
}

/// Shows one message at a time and hides it after a few seconds.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var current: ToastMessage?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, kind: ToastKind = .info, duration: TimeInterval = 2.6) {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            current = ToastMessage(kind: kind, text: text)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.current = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.kind.systemImage)
                .foregroundStyle(message.kind.tint)
            Text(message.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}
