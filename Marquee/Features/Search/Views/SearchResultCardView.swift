import SwiftUI

struct SearchResultsGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SearchResultsGridWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SearchResultsGridWidthPreferenceKey.self,
                value: proxy.size.width
            )
        }
    }
}

// MARK: - Search Result Card View

struct SearchResultCardView: View {
    let posterPath: String?
    let title: String
    let subtitle: String
    let matchType: BrowseSearchMatchType
    let matchDetail: String?
    let isRemoteFocused: Bool
    var fallbackSystemImage: String = "film.fill"
    let onSelect: () -> Void

    var body: some View {
        UniversalPosterCard(
            title: title,
            posterPath: posterPath,
            fallbackBadge: subtitle.isEmpty ? nil : subtitle,
            fallbackSystemImage: fallbackSystemImage,
            primaryMetadata: subtitle.isEmpty ? nil : subtitle,
            highlightMetadata: matchDetail,
            highlightColor: matchLabelColor,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: "Open details",
            isRemoteFocused: isRemoteFocused,
            onSelect: onSelect
        )
    }

    private var matchLabelColor: Color {
        switch matchType {
        case .title:
            return MarqueeTheme.textTertiary
        case .collection, .director, .genre, .overview, .fileName:
            return MarqueeTheme.accentSecondary
        case .cast, .keyword:
            return MarqueeTheme.accentBright
        }
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let matchDetail {
            parts.append(matchDetail)
        }
        return parts.joined(separator: ", ")
    }
}
