import SwiftUI

/// Standard page: large title, subtitle, optional trailing accessory, then
/// sections, all in one vertical scroll view.
struct PageScaffold<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    var titleDot: Color? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String,
        titleDot: Color? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleDot = titleDot
        self.accessory = accessory
        self.content = content
    }

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotFixedViewport) private var snapshotFixedViewport

    var body: some View {
        if isSnapshot && !snapshotFixedViewport {
            stack.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) { stack }
        }
    }

    private var stack: some View {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            if let titleDot {
                                Circle().fill(titleDot).frame(width: 11, height: 11)
                            }
                            Text(title)
                                .font(Theme.Font.pageTitle)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        Text(subtitle)
                            .font(Theme.Font.pageSubtitle)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    accessory()
                        .padding(.top, 6)
                }
                .padding(.bottom, -4)
                content()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.pageTopPadding)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled group: heading + caption above a card (or any content).
struct PageSection<Content: View>: View {
    let title: String
    var caption: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        caption: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, caption: caption, systemImage: systemImage)
            content()
        }
    }
}

struct SectionHeader: View {
    let title: String
    var caption: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
            }
            if let caption {
                Text(caption)
                    .font(Theme.Font.sectionCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Bordered container used for every group of rows.
struct Card<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 4, leading: Theme.cardPadding, bottom: 4, trailing: Theme.cardPadding)
    var fill: Color = Theme.cardFill
    var stroke: Color = Theme.cardStroke
    @ViewBuilder var content: () -> Content

    init(
        padding: EdgeInsets = EdgeInsets(top: 4, leading: Theme.cardPadding, bottom: 4, trailing: Theme.cardPadding),
        fill: Color = Theme.cardFill,
        stroke: Color = Theme.cardStroke,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.fill = fill
        self.stroke = stroke
        self.content = content
    }

    /// Convenience for cards whose content wants even padding all round.
    init(inset: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.init(padding: EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset), content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        )
    }
}

/// Hairline between rows inside a card.
struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
    }
}

/// Lays out rows with dividers between them. Each element of `rows` is a row.
struct DividedRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder var row: (Data.Element) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                if index > 0 { CardDivider() }
                row(element)
            }
        }
    }
}

/// Title + subtitle stack used on the left side of setting rows.
struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    var emphasized = false
    var titleColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(emphasized ? Theme.Font.rowTitleEmphasis : Theme.Font.rowTitle)
                .foregroundStyle(titleColor ?? Theme.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small explanatory line with an info glyph, used at the bottom of cards.
struct InfoNote: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.textSecondary)
    }
}

/// Flow layout for chips (wraps to new lines). macOS 13+.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Break into lines first, then centre each item vertically in its line.
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                lines.append([])
                x = bounds.minX
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for line in lines where !line.isEmpty {
            let lineHeight = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in line {
                let origin = CGPoint(x: x, y: y + (lineHeight - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
