import SwiftUI

// MARK: - Marquee Logo (app icon play symbol)

struct MarqueeLogoView: View {
    let size: CGFloat

    private var gradient: LinearGradient {
        MarqueeTheme.titleGradient
    }

    var body: some View {
        ZStack {
            PlayShape()
                .stroke(gradient, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)

            PlayShape()
                .fill(gradient)
                .frame(width: size * 0.52, height: size * 0.52)

            ArcWave(startAngle: .degrees(-30), endAngle: .degrees(30))
                .stroke(gradient, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .frame(width: size * 0.55, height: size * 0.55)
                .offset(x: size * 0.42)

            ArcWave(startAngle: .degrees(-30), endAngle: .degrees(30))
                .stroke(gradient, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .frame(width: size * 0.8, height: size * 0.8)
                .offset(x: size * 0.55)
        }
        .frame(width: size * 1.6, height: size)
    }
}

// MARK: - Play Shape

struct PlayShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = w * 0.15

        var path = Path()
        let top = CGPoint(x: w * 0.15, y: 0)
        let right = CGPoint(x: w, y: h / 2)
        let bottom = CGPoint(x: w * 0.15, y: h)

        path.move(to: CGPoint(x: top.x + r, y: top.y))
        path.addLine(to: CGPoint(x: right.x - r, y: right.y - (h / 2 - r) * (h / 2) / (w * 0.85)))
        path.addQuadCurve(to: CGPoint(x: right.x - r, y: right.y + (h / 2 - r) * (h / 2) / (w * 0.85)),
                          control: right)
        path.addLine(to: CGPoint(x: bottom.x + r, y: bottom.y))
        path.addQuadCurve(to: CGPoint(x: top.x, y: bottom.y - r),
                          control: bottom)
        path.addLine(to: CGPoint(x: top.x, y: top.y + r))
        path.addQuadCurve(to: CGPoint(x: top.x + r, y: top.y),
                          control: top)

        return path
    }
}

// MARK: - Arc Wave

struct ArcWave: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}
