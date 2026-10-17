import SwiftUI

// MARK: - Episode Row

struct EpisodeRow: View {
    let item: MediaItem
    let isUpNext: Bool
    var isRemoteFocused: Bool = false
    let onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @State private var isHovered: Bool = false
    @State private var frameCaptureTick: Int = 0

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)) {
                thumbnailArea
                infoArea
                Spacer()
                watchState
            }
            .padding(MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode))
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isRemoteFocused ? 1.035 : 1.0)
        .shadow(
            color: Color.black.opacity(isRemoteFocused ? 0.6 : (isHovered ? 0.18 : 0.1)),
            radius: isRemoteFocused ? 22 : (isHovered ? 5 : 2),
            y: isRemoteFocused ? 12 : (isHovered ? 2 : 1)
        )
        .shadow(
            color: activeAccent.opacity(isRemoteFocused ? 0.5 : 0),
            radius: isRemoteFocused ? 24 : 0,
            y: 0
        )
        .zIndex(isRemoteFocused ? 1 : 0)
        .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: isRemoteFocused)
        .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .onReceive(NotificationCenter.default.publisher(for: .episodeFrameCaptured)) { note in
            guard let captured = note.userInfo?[EpisodeFrameCache.filePathKey] as? String,
                  captured == item.filePath else { return }
            frameCaptureTick &+= 1
        }
    }

    // MARK: - Thumbnail

    private var activeAccent: Color {
        kidsMode ? MarqueeTheme.kidsAccent : MarqueeTheme.accentSecondary
    }

    /// Resolved thumbnail path. Exact per-episode sidecars win first;
    /// otherwise a generated frame is preferred over generic season/show art.
    private var resolvedThumbPath: String? {
        // Reading frameCaptureTick keeps SwiftUI invalidating this view
        // when EpisodeFrameCache posts a fresh capture for our file.
        _ = frameCaptureTick
        if let localStill = item.localEpisodeStillPath {
            return localStill
        }
        if let framePath = EpisodeFrameCache.shared.cachedFramePath(
            forVideoAt: item.filePath,
            duration: item.duration
        ) {
            return framePath
        }
        return item.thumbBackdropPath
            ?? item.backdropImagePath
            ?? item.showThumbBackdropPath
            ?? item.thumbPosterPath
    }

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
                .fill(kidsMode ? MarqueeTheme.kidsSurface : MarqueeTheme.surfaceElevated)

            if let path = resolvedThumbPath {
                CachedImageView(path: path, contentMode: .fill)
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode), weight: .ultraLight))
                    .foregroundColor(MarqueeTheme.textTertiary.opacity(0.3))
            }

            if isRemoteFocused {
                Color.black.opacity(0.3)
                Image(systemName: "play.fill")
                    .font(.system(size: MarqueeTheme.scaled(20, leanBack: 30, isLeanBack: leanBackMode)))
                    .foregroundColor(.white)
            } else if isHovered {
                Color.white.opacity(0.045)
            }

            if item.hasProgress {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        let duration = item.duration ?? 0
                        let fraction = duration > 0
                            ? item.playbackPosition / duration
                            : 0
                        Rectangle()
                            .fill(activeAccent)
                            .frame(width: geo.size.width * fraction, height: 3)
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM))
    }

    private var thumbnailSize: CGSize {
        leanBackMode
            ? CGSize(width: 290, height: 163)
            : CGSize(width: 200, height: 112)
    }

    // MARK: - Info

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode)) {
            HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                Text("E\(item.episodeNumber ?? 0)")
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(activeAccent)

                if isUpNext {
                    Text("UP NEXT")
                        .font(.system(size: MarqueeTheme.scaled(9, leanBack: 13, isLeanBack: leanBackMode), weight: .bold))
                        .tracking(MarqueeTheme.scaled(0.8, leanBack: 1.1, isLeanBack: leanBackMode))
                        .foregroundColor(MarqueeTheme.accentPrimary)
                        .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(3, leanBack: 5, isLeanBack: leanBackMode))
                        .background(
                            Capsule().fill(MarqueeTheme.accentPrimary.opacity(0.2))
                        )
                }
            }

            Text(item.displayEpisodeTitle)
                .font(.system(size: MarqueeTheme.scaled(14, leanBack: 21, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textPrimary)
                .lineLimit(leanBackMode ? 2 : 1)

            if let runtime = item.displayRuntime {
                Text(runtime)
                    .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }
        }
    }

    // MARK: - Watch State

    private var watchState: some View {
        Group {
            if item.isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: MarqueeTheme.scaled(18, leanBack: 26, isLeanBack: leanBackMode)))
                    .foregroundColor(activeAccent.opacity(0.6))
            }
        }
        .padding(.trailing, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
    }

    // MARK: - Background

    private var rowBackground: some View {
        Group {
            if isRemoteFocused {
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(activeAccent.opacity(0.16))
            } else if isUpNext {
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.accentPrimary.opacity(0.08))
            } else if isHovered {
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(Color.white.opacity(0.018))
            } else {
                Color.clear
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                .strokeBorder(
                    activeAccent.opacity(isRemoteFocused ? 1.0 : 0),
                    lineWidth: isRemoteFocused ? 2.5 : 0
                )
        )
    }
}
