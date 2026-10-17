import SwiftUI

// MARK: - Section Header

struct SectionHeader: View {
    let title: String

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        Text(kidsMode ? title : title.uppercased())
            .font(.system(size: titleSize, weight: .bold))
            .foregroundColor(kidsMode ? MarqueeTheme.kidsAccent : MarqueeTheme.textSecondary)
            .tracking(kidsMode ? 0 : 1.5)
    }

    private var titleSize: CGFloat {
        if kidsMode {
            return MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode)
        }
        return MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode)
    }
}
