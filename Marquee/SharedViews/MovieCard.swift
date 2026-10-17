import SwiftUI

// MARK: - Movie Card

struct MovieCard: View {
    let item: MediaItem
    var cardWidth: CGFloat? = nil
    var isRemoteFocused: Bool = false
    var focusAccent: Color? = nil
    let onSelect: () -> Void

    var body: some View {
        UniversalPosterCard(
            title: item.browseTitle,
            posterPath: item.isEpisode ? item.gridShowPosterPath : item.gridPosterPath,
            cardWidth: cardWidth,
            fallbackBadge: item.isEpisode ? item.episodeLabel : item.formatBadge,
            fallbackSystemImage: item.isEpisode ? "tv.fill" : "film.fill",
            primaryMetadata: primaryMetadata,
            highlightMetadata: item.isEpisode ? item.displayEpisodeTitle : nil,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: item.isEpisode ? "Open episode details" : "Open movie details",
            isRemoteFocused: isRemoteFocused,
            focusAccent: focusAccent,
            onSelect: onSelect
        )
    }

    private var accessibilityLabel: String {
        var parts = [item.browseTitle]
        if item.isEpisode {
            parts.append(item.episodeLabel)
            parts.append(item.displayEpisodeTitle)
        } else {
            if let year = item.displayYear { parts.append(year) }
            if let runtime = item.displayRuntime { parts.append(runtime) }
        }
        if item.hasProgress {
            parts.append("In progress")
        } else if item.isWatched {
            parts.append("Watched")
        }
        return parts.joined(separator: ", ")
    }

    private var primaryMetadata: String? {
        if item.isEpisode {
            return item.episodeLabel
        }
        let metadata = [item.displayYear, item.displayRuntime]
            .compactMap { $0 }
            .joined(separator: " ")
        return metadata.isEmpty ? nil : metadata
    }
}

// MARK: - Universal Poster Card

enum UniversalPosterCardArtworkLayout {
    static let frameAspectRatio: CGFloat = 2.0 / 3.0

    static func frameHeight(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return width / frameAspectRatio
    }
}

enum UniversalPosterCardLabelLayout {
    static let titleLineCapacity = 2
    static let metadataLineCapacity = 2

    static func reservedHeight(
        titleLineHeight: CGFloat,
        metadataLineHeight: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        guard titleLineHeight.isFinite,
              metadataLineHeight.isFinite,
              spacing.isFinite,
              titleLineHeight > 0,
              metadataLineHeight > 0,
              spacing >= 0 else {
            return 0
        }
        return CGFloat(titleLineCapacity) * titleLineHeight
            + CGFloat(metadataLineCapacity) * metadataLineHeight
            + 2 * spacing
    }

    static func scaledLineHeight(
        fontSize: CGFloat,
        baseFontSize: CGFloat,
        baseLineHeight: CGFloat
    ) -> CGFloat {
        guard fontSize.isFinite,
              baseFontSize.isFinite,
              baseLineHeight.isFinite,
              fontSize > 0,
              baseFontSize > 0,
              baseLineHeight > 0 else {
            return 0
        }
        return fontSize * (baseLineHeight / baseFontSize)
    }
}

struct UniversalPosterCard: View {
    let title: String
    let posterPath: String?
    var cardWidth: CGFloat? = nil
    var fallbackBadge: String?
    var fallbackSystemImage: String = "film.fill"
    var primaryMetadata: String?
    var highlightMetadata: String?
    var highlightColor: Color = MarqueeTheme.accentSecondary
    var accessibilityLabel: String
    var accessibilityHint: String
    var isRemoteFocused: Bool = false
    var focusAccent: Color? = nil
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @ScaledMetric private var compactTitleSize: CGFloat = 13
    @ScaledMetric private var leanBackTitleSize: CGFloat = 18
    @ScaledMetric private var compactMetaSize: CGFloat = 11
    @ScaledMetric private var leanBackMetaSize: CGFloat = 15
    @ScaledMetric private var compactLabelSpacing: CGFloat = 2
    @ScaledMetric private var leanBackLabelSpacing: CGFloat = 4
    @State private var isHovered: Bool = false

    var body: some View {
        let isActive = isRemoteFocused || isHovered

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                posterFrame
                titleArea(isActive: isActive)
                    .frame(height: labelBlockHeight, alignment: .topLeading)
            }
            .frame(width: normalizedCardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var posterFrame: some View {
        if isRemoteFocused {
            structuralPosterFrame(isFocused: true)
        } else {
            structuralPosterFrame(isFocused: false)
        }
    }

    @ViewBuilder
    private func structuralPosterFrame(isFocused: Bool) -> some View {
        posterSizingSurface(isFocused: isFocused)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
            .focusChrome(
                isFocused,
                cornerRadius: cardCornerRadius,
                accent: focusAccent,
                focusScale: FocusChromeMetrics.posterFocusScale,
                raisesZIndex: true
            )
            .padding(.top, MarqueeTheme.focusChromePosterTopPadding(isLeanBack: leanBackMode))
            .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: isHovered)
    }

    @ViewBuilder
    private func posterSizingSurface(isFocused: Bool) -> some View {
        if let cardWidth = normalizedCardWidth {
            posterSurface(isFocused: isFocused)
                .frame(
                    width: cardWidth,
                    height: UniversalPosterCardArtworkLayout.frameHeight(forWidth: cardWidth)
                )
                .clipped()
        } else {
            Color.clear
                .aspectRatio(UniversalPosterCardArtworkLayout.frameAspectRatio, contentMode: .fit)
                .overlay {
                    posterSurface(isFocused: isFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }
    }

    private var normalizedCardWidth: CGFloat? {
        guard let cardWidth,
              cardWidth.isFinite,
              cardWidth > 0 else {
            return nil
        }
        return cardWidth
    }

    private func posterSurface(isFocused: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .fill(kidsMode ? MarqueeTheme.kidsSurface : MarqueeTheme.surfaceElevated)

            PosterFallbackArtwork(
                title: title,
                badge: fallbackBadge,
                systemImage: fallbackSystemImage
            )

            if let path = posterPath {
                CachedImageView(
                    path: path,
                    contentMode: .fill,
                    thumbnailPixelSize: posterThumbnailSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }

            if isFocused {
                Color.black.opacity(0.28)
                focusIcon
            } else if isHovered {
                Color.white.opacity(0.045)
            }
        }
    }

    private var focusIcon: some View {
        Circle()
            .fill(Color.black.opacity(0.52))
            .frame(
                width: MarqueeTheme.scaled(44, leanBack: 64, isLeanBack: leanBackMode),
                height: MarqueeTheme.scaled(44, leanBack: 64, isLeanBack: leanBackMode)
            )
            .overlay(
                Image(systemName: "chevron.right")
                    .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(.white.opacity(0.94))
                    .offset(x: 1)
            )
    }

    private func titleArea(isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: labelSpacing) {
            Text(title)
                .font(.system(size: leanBackMode ? leanBackTitleSize : compactTitleSize, weight: .medium))
                .foregroundColor(isActive ? MarqueeTheme.textPrimary : MarqueeTheme.textSecondary)
                .lineLimit(2)

            if let primaryMetadata, !primaryMetadata.isEmpty {
                Text(primaryMetadata)
                    .font(.system(size: leanBackMode ? leanBackMetaSize : compactMetaSize))
                    .foregroundColor(MarqueeTheme.textTertiary)
                    .lineLimit(1)
            }

            if let highlightMetadata, !highlightMetadata.isEmpty {
                Text(highlightMetadata)
                    .font(.system(size: leanBackMode ? leanBackMetaSize : compactMetaSize, weight: .semibold))
                    .foregroundColor(highlightColor)
                    .lineLimit(1)
            }
        }
    }

    private var cardCornerRadius: CGFloat {
        kidsMode ? MarqueeTheme.kidsCornerRadiusMD : MarqueeTheme.cornerRadiusMD
    }

    private var labelBlockHeight: CGFloat {
        let titleSize = leanBackMode ? leanBackTitleSize : compactTitleSize
        let metadataSize = leanBackMode ? leanBackMetaSize : compactMetaSize
        return UniversalPosterCardLabelLayout.reservedHeight(
            titleLineHeight: UniversalPosterCardLabelLayout.scaledLineHeight(
                fontSize: titleSize,
                baseFontSize: leanBackMode ? 18 : 13,
                baseLineHeight: leanBackMode ? 22 : 16
            ),
            metadataLineHeight: UniversalPosterCardLabelLayout.scaledLineHeight(
                fontSize: metadataSize,
                baseFontSize: leanBackMode ? 15 : 11,
                baseLineHeight: leanBackMode ? 18 : 13
            ),
            spacing: labelSpacing
        )
    }

    private var labelSpacing: CGFloat {
        leanBackMode ? leanBackLabelSpacing : compactLabelSpacing
    }

    private var posterThumbnailSize: CGSize {
        leanBackMode
            ? ArtworkCache.leanBackPosterThumbnailPixelSize
            : ArtworkCache.gridPosterThumbnailPixelSize
    }
}

// MARK: - Artwork Fallback

struct PosterFallbackArtwork: View {
    let title: String
    var badge: String?
    var systemImage: String = "film.fill"

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    (kidsMode ? MarqueeTheme.kidsSurface : MarqueeTheme.surfaceLayer).opacity(0.96),
                    MarqueeTheme.accentPrimary.opacity(kidsMode ? 0.30 : 0.22),
                    MarqueeTheme.surfaceElevated.opacity(0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: systemImage)
                .font(.system(size: MarqueeTheme.scaled(34, leanBack: 52, isLeanBack: leanBackMode), weight: .ultraLight))
                .foregroundColor(MarqueeTheme.textTertiary.opacity(0.24))

            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(6, leanBack: 9, isLeanBack: leanBackMode)) {
                Spacer()

                if let badge, !badge.isEmpty {
                    Text(badge.uppercased())
                        .font(.system(size: MarqueeTheme.scaled(9, leanBack: 13, isLeanBack: leanBackMode), weight: .bold, design: .monospaced))
                        .foregroundColor((kidsMode ? MarqueeTheme.kidsAccent : MarqueeTheme.accentSecondary).opacity(0.78))
                }

                Text(title)
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(MarqueeTheme.textPrimary.opacity(0.92))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

// MARK: - Media Item Row (horizontal scroll)

struct MediaItemRow: View {
    let title: String
    let items: [MediaItem]
    var totalCount: Int? = nil
    var focusedItemID: MediaItem.ID? = nil
    var focusScrollMode: RemoteHorizontalFocusScrollPolicy.Mode = .standard
    let onSelect: (MediaItem) -> Void

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
                Text("\(displayCount) title\(displayCount == 1 ? "" : "s")")
                    .font(.system(size: leanBackMode ? leanBackCountSize : compactCountSize, weight: .medium))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }

            ArrowedScrollRow(
                ids: items.map(\.id),
                focusedID: focusedItemID,
                focusItemExtent: cardWidth,
                focusItemSpacing: cardGap,
                focusScrollMode: focusScrollMode,
                hoverArrowsEnabled: RemotePointerRegionPolicy.rowHoverControlsEnabled(
                    isKeyboardFocusActive: focusedItemID != nil
                )
            ) {
                LazyHStack(alignment: .top, spacing: cardGap) {
                    ForEach(items) { item in
                        MovieCard(
                            item: item,
                            cardWidth: cardWidth,
                            isRemoteFocused: item.id == focusedItemID
                        ) {
                            onSelect(item)
                        }
                        .id(item.id)
                    }
                }
            }
        }
    }

    private var displayCount: Int {
        totalCount ?? items.count
    }
}
