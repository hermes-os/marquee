import SwiftUI

// MARK: - Transition Loading View

struct TransitionLoadingView: View {
    @State private var rotation: Angle = .zero
    @State private var logoGlow: Bool = false
    @State private var logoDepth: Bool = false

    private let goldLight = Color(red: 0xC9 / 255.0, green: 0xA8 / 255.0, blue: 0x4C / 255.0)
    private let goldMid = Color(red: 0xE8 / 255.0, green: 0xD0 / 255.0, blue: 0x8C / 255.0)
    private let goldDark = Color(red: 0xD4 / 255.0, green: 0xAF / 255.0, blue: 0x5C / 255.0)

    var body: some View {
        ZStack {
            MarqueeTheme.background.ignoresSafeArea()

            ZStack {
                Circle()
                    .stroke(MarqueeTheme.surfaceLayer, lineWidth: 3)
                    .frame(width: 160, height: 160)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [goldLight, goldMid, goldDark],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 160, height: 160)
                    .rotationEffect(rotation)

                Image("MarqueeLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .scaleEffect(logoDepth ? 1.15 : 0.85)
                    .opacity(logoDepth ? 1.0 : 0.7)
                    .shadow(
                        color: goldLight.opacity(logoDepth ? 0.7 : 0.1),
                        radius: logoDepth ? 24 : 6
                    )
                    .shadow(
                        color: Color.black.opacity(logoDepth ? 0.5 : 0.2),
                        radius: logoDepth ? 16 : 4,
                        y: logoDepth ? 8 : 2
                    )
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = .degrees(360)
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                logoGlow = true
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                logoDepth = true
            }
        }
    }
}
