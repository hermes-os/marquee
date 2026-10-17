import SwiftUI

// MARK: - Bottom Fade View

struct BottomFadeView: View {
    var height: CGFloat = 80

    @Environment(\.kidsMode) private var kidsMode

    private var fadeColor: Color {
        kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background
    }

    var body: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}
