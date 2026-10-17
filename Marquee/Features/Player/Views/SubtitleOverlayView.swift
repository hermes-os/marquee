import SwiftUI

// MARK: - SubtitleOverlayView

struct SubtitleOverlayView: View {

    let entries: [SubtitleEntry]
    let currentTime: Double

    @ObservedObject private var settings = UserSettings.shared
    @Environment(\.leanBackMode) private var leanBackMode
    @ScaledMetric private var baseFontSize: CGFloat = 30
    @ScaledMetric private var baseLineSpacing: CGFloat = 5
    @ScaledMetric private var baseHorizontalPadding: CGFloat = 18
    @ScaledMetric private var baseVerticalPadding: CGFloat = 10
    @ScaledMetric private var baseBottomPadding: CGFloat = 80
    @ScaledMetric private var baseSidePadding: CGFloat = 48

    var body: some View {
        VStack {
            Spacer()

            if let activeEntry = findActiveEntry() {
                subtitleLabel(activeEntry.text)
            }
        }
        .padding(.bottom, baseBottomPadding * layoutScale)
        .padding(.horizontal, baseSidePadding * layoutScale)
        .allowsHitTesting(false)
    }

    // MARK: - Subtitle Label

    private func subtitleLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: baseFontSize * subtitleScale, weight: .semibold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(baseLineSpacing * subtitleScale)
            .padding(.horizontal, baseHorizontalPadding * subtitleScale)
            .padding(.vertical, baseVerticalPadding * subtitleScale)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.7))
            )
            .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
    }

    private var subtitleScale: CGFloat {
        let userScale = min(max(settings.subtitleScale, 0.8), 2.2)
        return CGFloat(userScale) * layoutScale
    }

    private var layoutScale: CGFloat {
        leanBackMode ? 1.15 : 1.0
    }

    // MARK: - Binary Search Lookup

    private func findActiveEntry() -> SubtitleEntry? {
        guard !entries.isEmpty else { return nil }

        var low = 0
        var high = entries.count - 1
        var candidate: SubtitleEntry?

        while low <= high {
            let mid = (low + high) / 2
            let entry = entries[mid]

            if entry.startTime <= currentTime {
                if entry.endTime > currentTime {
                    candidate = entry
                }
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return candidate
    }
}
