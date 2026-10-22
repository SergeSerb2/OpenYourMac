import SwiftUI

/// The OpenYourMac mark drawn in SwiftUI (same design as assets/icon.svg):
/// a periwinkle squircle with a focused window between two neighbours that
/// slide off the edges, and a small strip indicator underneath.
struct BrandMark: View {
    var size: CGFloat = 88

    var body: some View {
        let s = size / 824 // the SVG's squircle is 824 units wide
        ZStack {
            RoundedRectangle(cornerRadius: 186 * s, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0x8E / 255, green: 0xA2 / 255, blue: 1), location: 0),
                            .init(color: Theme.accent, location: 0.48),
                            .init(color: Color(red: 0x2D / 255, green: 0x2A / 255, blue: 0x9E / 255), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0.1, y: 0),
                        endPoint: UnitPoint(x: 0.9, y: 1)
                    )
                )
            RoundedRectangle(cornerRadius: 186 * s, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))

            Group {
                window(x: -82, width: 262, height: 356, radius: 40, opacity: 0.45, s: s)
                window(x: 644, width: 262, height: 356, radius: 40, opacity: 0.45, s: s)
                focusedWindow(s: s)
            }
            .clipShape(RoundedRectangle(cornerRadius: 186 * s, style: .continuous))

            stripIndicator(s: s)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.08, green: 0.06, blue: 0.35).opacity(0.35), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }

    /// A side window; `x` is its left edge in SVG units relative to the squircle.
    private func window(x: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, opacity: Double, s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius * s, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: width * s, height: height * s)
            .position(x: (x + width / 2) * s, y: (218 + height / 2) * s)
            .frame(width: size, height: size)
    }

    private func focusedWindow(s: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 50 * s, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(red: 0.90, green: 0.92, blue: 1)], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 14 * s) {
                ForEach([0.55, 0.35, 0.22], id: \.self) { alpha in
                    Circle().fill(Theme.accent.opacity(alpha)).frame(width: 26 * s, height: 26 * s)
                }
                Spacer()
            }
            .padding(.leading, 37 * s)
            .padding(.top, 30 * s)
        }
        .frame(width: 388 * s, height: 452 * s)
        .shadow(color: Color(red: 0.08, green: 0.06, blue: 0.35).opacity(0.4), radius: 22 * s, y: 18 * s)
        .position(x: (218 + 194) * s, y: (170 + 226) * s)
        .frame(width: size, height: size)
    }

    private func stripIndicator(s: CGFloat) -> some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.16)).frame(width: 280 * s, height: 44 * s)
            HStack(spacing: 12 * s) {
                Capsule().fill(Color.white.opacity(0.45)).frame(width: 44 * s, height: 14 * s)
                Capsule().fill(Color.white).frame(width: 120 * s, height: 14 * s)
                Capsule().fill(Color.white.opacity(0.45)).frame(width: 44 * s, height: 14 * s)
            }
        }
        .position(x: 412 * s, y: 704 * s)
        .frame(width: size, height: size)
    }
}
