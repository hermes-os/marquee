import SwiftUI

struct HeroArtworkReadinessTracker {
    private struct Entry {
        let path: String
        var state: CachedImageLoadState
    }

    private var entries: [String: Entry] = [:]

    mutating func receive(
        artworkID: String,
        path: String,
        state: CachedImageLoadState
    ) {
        switch state {
        case .loading:
            entries[artworkID] = Entry(path: path, state: .loading)
        case .ready, .terminalFallback:
            guard entries[artworkID]?.path == path else { return }
            entries[artworkID]?.state = state
        }
    }

    func state(artworkID: String, path: String?) -> CachedImageLoadState {
        guard let path else { return .terminalFallback }
        guard let entry = entries[artworkID],
              entry.path == path else { return .loading }
        return entry.state
    }

    func revealsHeroContent(artworkID: String, path: String?) -> Bool {
        let state = state(artworkID: artworkID, path: path)
        return state == .ready || state == .terminalFallback
    }
}

enum HeroArtworkLayoutPolicy {
    static let fallbackWordmark = "MARQUEE"
}

// MARK: - Hero Carousel (infinite sliding)

struct HeroCarousel: View {
    let spotlights: [HeroSpotlight]
    let onPlay: (MediaItem) -> Void
    var isRemoteFocused: Bool = false
    var focusedIndex: Int = 0
    var onFocusedIndexChange: (Int) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @State private var scrollPosition: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var timer: Timer?
    @State private var isHoveringCenter: Bool = false
    @State private var artworkReadiness = HeroArtworkReadinessTracker()

    private var cardCount: Int { spotlights.count }

    private var currentIndex: Int {
        guard cardCount > 0 else { return 0 }
        let raw = Int(round(scrollPosition)) % cardCount
        return raw < 0 ? raw + cardCount : raw
    }

    private func wrappedSpotlight(at logicalIndex: Int) -> HeroSpotlight {
        let wrapped = ((logicalIndex % cardCount) + cardCount) % cardCount
        return spotlights[wrapped]
    }

    private var visibleLogicalIndices: [Int] {
        // ±2, not ±1: the outer pair sits at zero opacity (distance 2 fades
        // to 0) but mounts early, so its artwork decodes and records
        // readiness before the card scrolls into view. Single-step
        // traversal therefore does not re-trip the first-paint reveal gate
        // — cards slide in with the hero spring uniformly, and the reveal
        // fade remains reserved for genuinely-undecoded first paints (a
        // multi-step indicator jump beyond the window can still hit it).
        // Mount/unmount churn also moves to the invisible edge, so no
        // window-edge fade artifacts.
        let center = Int(round(scrollPosition))
        return Array((center - 2)...(center + 2))
    }

    private var slideAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : MarqueeTheme.heroCarouselAnimation
    }

    private var heroHeight: CGFloat {
        MarqueeTheme.scaled(420, leanBack: 520, isLeanBack: leanBackMode)
    }

    private var cardHeight: CGFloat {
        MarqueeTheme.scaled(390, leanBack: 500, isLeanBack: leanBackMode)
    }

    var body: some View {
        if spotlights.isEmpty {
            emptyHero
        } else {
            carouselContent
        }
    }

    // MARK: - Empty Hero

    private var emptyHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG)
                .fill(MarqueeTheme.surfaceElevated)
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: MarqueeTheme.scaled(36, leanBack: 52, isLeanBack: leanBackMode), weight: .ultraLight))
                    .foregroundColor(MarqueeTheme.textTertiary.opacity(0.35))
                Text("Add movies to your library to see spotlights")
                    .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }
        }
        .frame(height: heroHeight)
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
    }

    // MARK: - Carousel Content

    private var carouselContent: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let cardWidth = totalWidth * (leanBackMode ? 0.76 : 0.72)
            let cardSpacing = cardWidth * (leanBackMode ? 0.86 : 0.82)
            let effectivePosition = scrollPosition + dragOffset / cardSpacing

            ZStack {
                RadialGradient(
                    colors: [
                        MarqueeTheme.accentPrimary.opacity(0.08),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 40,
                    endRadius: MarqueeTheme.scaled(400, leanBack: 560, isLeanBack: leanBackMode)
                )

                ForEach(visibleLogicalIndices, id: \.self) { logicalIndex in
                    let spotlight = wrappedSpotlight(at: logicalIndex)
                    let fractionalOffset = CGFloat(logicalIndex) - effectivePosition
                    let xOffset = fractionalOffset * cardSpacing
                    let distance = abs(fractionalOffset)
                    let scale = max(0.82, 1.0 - distance * 0.12)
                    let opacity = max(0.0, 1.0 - distance * 0.5)
                    let isCenter = distance < 0.5

                    // One structural branch for every card: an if/else on
                    // isCenter gives the center card a different view
                    // identity, so crossing the threshold tears the card
                    // down and re-inserts it — rendering as a fade that
                    // masks the hero spring and remounting the artwork
                    // (which re-trips the first-paint reveal gate). The tap
                    // gesture is attached unconditionally and no-ops on the
                    // center card; inner buttons keep gesture priority.
                    positionedHeroCard(
                        spotlight: spotlight,
                        width: cardWidth,
                        isCenter: isCenter,
                        scale: scale,
                        opacity: opacity,
                        xOffset: xOffset
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isCenter else { return }
                        let delta = logicalIndex - Int(round(scrollPosition))
                        advance(by: delta)
                    }
                }

                // Edge fades
                HStack {
                    LinearGradient(
                        colors: [
                            (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).opacity(0.9),
                            Color.clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: (totalWidth - cardWidth) / 2 + 30)
                    Spacer()
                    LinearGradient(
                        colors: [
                            Color.clear,
                            (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).opacity(0.9),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: (totalWidth - cardWidth) / 2 + 30)
                }
                .zIndex(2)
                .allowsHitTesting(false)

                if cardCount > 1 {
                    HStack {
                        carouselArrow(direction: .left)
                        Spacer()
                        carouselArrow(direction: .right)
                    }
                    .padding(.horizontal, MarqueeTheme.scaled(16, leanBack: 28, isLeanBack: leanBackMode))
                    .zIndex(3)

                    VStack {
                        Spacer()
                        HStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                            ForEach(0..<cardCount, id: \.self) { index in
                                Circle()
                                    .fill(index == currentIndex
                                        ? MarqueeTheme.accentSecondary
                                        : MarqueeTheme.textTertiary.opacity(0.4))
                                    .frame(
                                        width: index == currentIndex
                                            ? MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode)
                                            : MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode),
                                        height: index == currentIndex
                                            ? MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode)
                                            : MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)
                                    )
                                    .animation(MarqueeTheme.motion(MarqueeTheme.heroIndicatorAnimation, reduceMotion: reduceMotion), value: currentIndex)
                                    .onTapGesture {
                                        navigateTo(index: index)
                                    }
                            }
                        }
                        .padding(.bottom, MarqueeTheme.scaled(14, leanBack: 24, isLeanBack: leanBackMode))
                        .zIndex(3)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let threshold: CGFloat = 40
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        if value.translation.width < -threshold || velocity < -200 {
                            dragOffset = 0
                            advance(by: 1)
                        } else if value.translation.width > threshold || velocity > 200 {
                            dragOffset = 0
                            advance(by: -1)
                        } else {
                            withAnimation(slideAnimation) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .animation(slideAnimation, value: scrollPosition)
        }
        .frame(height: heroHeight)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: spotlights.count) { _ in
            scrollPosition = 0
            dragOffset = 0
            onFocusedIndexChange(0)
        }
        .onChange(of: focusedIndex) { index in
            guard isRemoteFocused, cardCount > 0 else { return }
            navigateTo(index: min(max(index, 0), cardCount - 1))
        }
        .onChange(of: currentIndex) { index in
            onFocusedIndexChange(index)
        }
        .onChange(of: isRemoteFocused) { focused in
            if focused {
                timer?.invalidate()
            } else {
                startTimer()
            }
        }
    }

    // MARK: - Hero Card

    private func positionedHeroCard(
        spotlight: HeroSpotlight,
        width: CGFloat,
        isCenter: Bool,
        scale: CGFloat,
        opacity: Double,
        xOffset: CGFloat
    ) -> some View {
        heroCard(spotlight: spotlight, width: width, isCenter: isCenter)
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: xOffset)
            .zIndex(isCenter ? 1 : 0)
    }

    private func heroCard(spotlight: HeroSpotlight, width: CGFloat, isCenter: Bool) -> some View {
        let showHover = isCenter && (isHoveringCenter || isRemoteFocused)
        let backdropPath = spotlight.item.displayBackdropPath
        let artworkID = spotlight.item.id.uuidString
        let revealsHeroContent = artworkReadiness.revealsHeroContent(
            artworkID: artworkID,
            path: backdropPath
        )

        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG)
                .fill(MarqueeTheme.surfaceElevated)
                .overlay {
                    VStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                        Image(systemName: "film.stack")
                            .font(.system(size: MarqueeTheme.scaled(26, leanBack: 38, isLeanBack: leanBackMode), weight: .ultraLight))
                            .foregroundColor(MarqueeTheme.textTertiary.opacity(0.22))
                        Text(HeroArtworkLayoutPolicy.fallbackWordmark)
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .semibold))
                            .tracking(MarqueeTheme.scaled(3, leanBack: 4, isLeanBack: leanBackMode))
                            .foregroundColor(MarqueeTheme.accentSecondary.opacity(0.28))
                    }
                }

            Group {
            if let posterPath = spotlight.item.displayPosterPath {
                CachedImageView(
                    path: posterPath,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.gridPosterThumbnailPixelSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0
                )
                .frame(width: width, height: cardHeight)
                .scaleEffect(1.18)
                .blur(radius: 12)
                .saturation(1.12)
                .contrast(1.08)
                .opacity(0.5)
                .clipped()
            }

            if let path = spotlight.item.displayBackdropPath {
                CachedImageView(
                    path: path,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.homeHeroBackdropThumbnailPixelSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0,
                    onLoadStateChange: { state in
                        guard spotlights.first(where: { $0.item.id == spotlight.item.id })?
                            .item.displayBackdropPath == path else { return }
                        var nextReadiness = artworkReadiness
                        nextReadiness.receive(
                            artworkID: artworkID,
                            path: path,
                            state: state
                        )
                        artworkReadiness = nextReadiness
                    }
                )
                    .id("\(artworkID)-\(path)")
                    .frame(width: width, height: cardHeight)
                    .clipped()
            }

            Color.black.opacity(0.18)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.3),
                    Color.black.opacity(showHover ? 0.9 : 0.85),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack {
                HStack {
                    HStack(spacing: MarqueeTheme.scaled(5, leanBack: 8, isLeanBack: leanBackMode)) {
                        Image(systemName: spotlight.icon)
                            .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .semibold))
                        Text(spotlight.category.uppercased())
                            .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .bold))
                            .tracking(MarqueeTheme.scaled(1.2, leanBack: 1.6, isLeanBack: leanBackMode))
                    }
                    .foregroundColor(MarqueeTheme.accentSecondary)
                    .padding(.horizontal, MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(5, leanBack: 8, isLeanBack: leanBackMode))
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.6))
                    )
                    Spacer()
                }
                .padding(MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
                Spacer()
            }

            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                Text(spotlight.item.displayTitle)
                    .font(.system(size: MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                    if let year = spotlight.item.displayYear {
                        Text(year)
                    }
                    if let runtime = spotlight.item.displayRuntime {
                        Text(runtime)
                    }
                    Text(spotlight.item.formatBadge)
                        .font(.system(size: MarqueeTheme.scaled(11, leanBack: 15, isLeanBack: leanBackMode), weight: .semibold, design: .monospaced))
                        .foregroundColor(MarqueeTheme.accentSecondary.opacity(0.8))
                }
                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)

                if isCenter {
                    Button {
                        onPlay(spotlight.item)
                    } label: {
                        HStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                            Image(systemName: "play.fill")
                                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)))
                            Text("Watch Now")
                                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, MarqueeTheme.scaled(18, leanBack: 26, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode))
                        .background(
                            Capsule().fill(MarqueeTheme.accentPrimary)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Watch \(spotlight.item.displayTitle)")
                    .accessibilityHint("Start playback")
                    .padding(.top, MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode))
                }
            }
            .padding(MarqueeTheme.scaled(20, leanBack: 32, isLeanBack: leanBackMode))
            }
            .opacity(revealsHeroContent ? 1 : 0)
            .animation(
                MarqueeTheme.motion(MarqueeTheme.selectionFadeAnimation, reduceMotion: reduceMotion),
                value: revealsHeroContent
            )
        }
        .frame(width: width, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG))
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG)
                .strokeBorder(
                    showHover ? MarqueeTheme.structuralFocus.opacity(isRemoteFocused ? 0.9 : 0.4) : Color.clear,
                    lineWidth: isRemoteFocused && isCenter ? 3 : 1.5
                )
        )
        .scaleEffect(isRemoteFocused && isCenter ? 1.025 : 1)
        .shadow(
            color: showHover
                ? MarqueeTheme.structuralFocus.opacity(isRemoteFocused ? 0.36 : 0.0)
                : Color.black.opacity(0.3),
            radius: showHover ? (isRemoteFocused ? 26 : 16) : 6,
            y: showHover ? 8 : 3
        )
        .shadow(
            color: Color.black.opacity(showHover ? 0.62 : 0.3),
            radius: showHover ? 18 : 6,
            y: showHover ? 10 : 3
        )
        .onHover { hovering in
            guard isCenter else { return }
            withAnimation(MarqueeTheme.motion(MarqueeTheme.heroIndicatorAnimation, reduceMotion: reduceMotion)) {
                isHoveringCenter = hovering
            }
        }
    }

    // MARK: - Navigation

    enum ArrowDirection { case left, right }

    private func advance(by delta: Int) {
        guard cardCount > 1 else { return }
        withAnimation(slideAnimation) {
            scrollPosition += CGFloat(delta)
        }
        restartTimer()
    }

    private func navigateTo(index: Int) {
        guard cardCount > 0 else { return }
        let nearest = Int(round(scrollPosition))
        let currentWrapped = ((nearest % cardCount) + cardCount) % cardCount
        var delta = index - currentWrapped
        if delta > cardCount / 2 { delta -= cardCount }
        if delta < -cardCount / 2 { delta += cardCount }
        advance(by: delta)
    }

    private func carouselArrow(direction: ArrowDirection) -> some View {
        Button(action: {
            advance(by: direction == .left ? -1 : 1)
        }) {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(.white)
                .frame(
                    width: MarqueeTheme.scaled(36, leanBack: 58, isLeanBack: leanBackMode),
                    height: MarqueeTheme.scaled(36, leanBack: 58, isLeanBack: leanBackMode)
                )
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction == .left ? "Previous spotlight" : "Next spotlight")
    }

    // MARK: - Auto-Cycle Timer

    private func startTimer() {
        timer?.invalidate()
        guard cardCount > 1, !reduceMotion, !isRemoteFocused else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            advance(by: 1)
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        startTimer()
    }
}
