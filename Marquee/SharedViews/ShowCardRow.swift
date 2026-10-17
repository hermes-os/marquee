import SwiftUI

// MARK: - Show Card Row (horizontal scroll)

struct ShowCardRow: View {
    let title: String
    let showNames: [String]
    var totalCount: Int? = nil
    let posterForShow: (String) -> String?
    let upNextForShow: (String) -> String?
    let seasonCountForShow: (String) -> Int
    var focusedShowName: String? = nil
    let onSelectShow: (String) -> Void

    @Environment(\.leanBackMode) private var leanBackMode
    @ScaledMetric private var compactCardWidth: CGFloat = 150
    @ScaledMetric private var leanBackCardWidth: CGFloat = 225
    @ScaledMetric private var compactTitleSize: CGFloat = 20
    @ScaledMetric private var leanBackTitleSize: CGFloat = 28
    @ScaledMetric private var compactCountSize: CGFloat = 12
    @ScaledMetric private var leanBackCountSize: CGFloat = 16

    var body: some View {
        let cardWidth = leanBackMode ? leanBackCardWidth : compactCardWidth
        let cardGap = MarqueeTheme.cardGap(isLeanBack: leanBackMode)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: leanBackMode ? leanBackTitleSize : compactTitleSize, weight: .semibold))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Spacer()
                Text("\(displayCount) show\(displayCount == 1 ? "" : "s")")
                    .font(.system(size: leanBackMode ? leanBackCountSize : compactCountSize, weight: .medium))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }

            ArrowedScrollRow(
                ids: showNames,
                focusedID: focusedShowName,
                focusItemExtent: cardWidth,
                focusItemSpacing: cardGap,
                hoverArrowsEnabled: RemotePointerRegionPolicy.rowHoverControlsEnabled(
                    isKeyboardFocusActive: focusedShowName != nil
                )
            ) {
                LazyHStack(alignment: .top, spacing: cardGap) {
                    ForEach(showNames, id: \.self) { name in
                        ShowCard(
                            showName: name,
                            posterPath: posterForShow(name),
                            cardWidth: cardWidth,
                            upNextLabel: upNextForShow(name),
                            seasonCount: seasonCountForShow(name),
                            isRemoteFocused: name == focusedShowName,
                            onSelect: { onSelectShow(name) }
                        )
                        .id(name)
                    }
                }
            }
        }
    }

    private var displayCount: Int {
        totalCount ?? showNames.count
    }
}
