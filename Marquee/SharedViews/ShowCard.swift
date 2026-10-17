import SwiftUI

// MARK: - Show Card

struct ShowCard: View {
    let showName: String
    let posterPath: String?
    var cardWidth: CGFloat? = nil
    let upNextLabel: String?
    let seasonCount: Int
    var isRemoteFocused: Bool = false
    var focusAccent: Color? = nil
    let onSelect: () -> Void

    var body: some View {
        UniversalPosterCard(
            title: showName,
            posterPath: posterPath,
            cardWidth: cardWidth,
            fallbackBadge: seasonLabel,
            fallbackSystemImage: "tv.fill",
            primaryMetadata: seasonLabel,
            highlightMetadata: upNextLabel,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: "Open show details",
            isRemoteFocused: isRemoteFocused,
            focusAccent: focusAccent,
            onSelect: onSelect
        )
    }

    private var seasonLabel: String {
        "\(seasonCount) Season\(seasonCount == 1 ? "" : "s")"
    }

    private var accessibilityLabel: String {
        var parts = [showName, seasonLabel.lowercased()]
        if let upNextLabel {
            parts.append("Up next \(upNextLabel)")
        }
        return parts.joined(separator: ", ")
    }
}
