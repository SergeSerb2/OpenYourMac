import SwiftUI

struct OnboardingStripIllustration: View {
    var height: CGFloat = 156
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var settled = false

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.tileFill)
                    HStack(spacing: 10) {
                        window(width: geometry.size.width * 0.34, focused: false, symbol: "doc.text")
                        window(width: geometry.size.width * 0.46, focused: true, symbol: "rectangle.split.2x1")
                        window(width: geometry.size.width * 0.34, focused: false, symbol: "text.alignleft")
                    }
                    .padding(.vertical, 12)
                    .offset(x: settled || reduceMotion || isSnapshot ? 0 : 24)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardStroke, lineWidth: 1))
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                Text("One screen. More room for your windows.")
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Windows sit side by side in a strip wider than your screen. The strip slides to keep the focused window on screen.")
        .onAppear {
            guard !reduceMotion, !isSnapshot else { return }
            withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 1.2)) { settled = true }
        }
    }

    private func window(width: CGFloat, focused: Bool, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(Theme.textTertiary.opacity(0.5)).frame(width: 4, height: 4) }
                Spacer()
            }
            .padding(9)
            CardDivider()
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(focused ? Theme.accent : Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .background(focused ? Theme.accentSofter : Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accent : Theme.cardStroke, lineWidth: focused ? 2 : 1))
    }
}
