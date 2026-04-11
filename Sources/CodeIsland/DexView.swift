import SwiftUI
import CodeIslandCore

/// Dex — Codex mascot, redrawn to match the Codex cloud logo more closely.
/// Uses a soft blue cloud silhouette with a white `>_` prompt and lightweight status animation.
struct DexView: View {
    let status: AgentStatus
    var size: CGFloat = 27
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    private static let cloudTop = Color(red: 0.67, green: 0.70, blue: 1.00)
    private static let cloudMid = Color(red: 0.49, green: 0.57, blue: 0.99)
    private static let cloudBottom = Color(red: 0.23, green: 0.31, blue: 0.96)
    private static let cloudGlow = Color.white.opacity(0.24)
    private static let promptC = Color.white
    private static let promptDim = Color.white.opacity(0.35)
    private static let alertC = Color(red: 1.0, green: 0.72, blue: 0.18)
    private static let kbBase = Color(red: 0.18, green: 0.20, blue: 0.26)
    private static let kbKey = Color(red: 0.35, green: 0.39, blue: 0.49)
    private static let kbHi = Color.white

    var body: some View {
        ZStack {
            switch status {
            case .idle: sleepScene
            case .processing, .running: workScene
            case .waitingApproval, .waitingQuestion: alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    private struct V {
        let ox: CGFloat
        let oy: CGFloat
        let s: CGFloat
        let y0: CGFloat

        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 16, svgY0: CGFloat = 0) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }

        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0) * s, width: w * s, height: h * s)
        }

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + (y - y0) * s)
        }
    }

    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i - 1].0) / (keyframes[i].0 - keyframes[i - 1].0)
                return keyframes[i - 1].1 + (keyframes[i].1 - keyframes[i - 1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }

    private func transformedRect(
        _ v: V,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        dy: CGFloat,
        squashX: CGFloat = 1,
        squashY: CGFloat = 1,
        centerX: CGFloat = 8,
        centerY: CGFloat = 8.5
    ) -> CGRect {
        let nx = centerX + (x - centerX) * squashX
        let ny = centerY + (y - centerY) * squashY + dy
        return v.r(nx, ny, w * squashX, h * squashY)
    }

    private func cloudPath(_ v: V, dy: CGFloat, squashX: CGFloat = 1, squashY: CGFloat = 1) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: transformedRect(v, x: 3.3, y: 8.0, w: 9.4, h: 4.7, dy: dy, squashX: squashX, squashY: squashY),
            cornerSize: CGSize(width: 2.9 * v.s, height: 2.9 * v.s)
        )
        path.addEllipse(in: transformedRect(v, x: 1.2, y: 6.1, w: 5.0, h: 5.2, dy: dy, squashX: squashX, squashY: squashY))
        path.addEllipse(in: transformedRect(v, x: 3.15, y: 3.45, w: 4.8, h: 4.8, dy: dy, squashX: squashX, squashY: squashY))
        path.addEllipse(in: transformedRect(v, x: 5.95, y: 2.45, w: 4.1, h: 4.1, dy: dy, squashX: squashX, squashY: squashY))
        path.addEllipse(in: transformedRect(v, x: 8.05, y: 3.45, w: 4.8, h: 4.8, dy: dy, squashX: squashX, squashY: squashY))
        path.addEllipse(in: transformedRect(v, x: 9.8, y: 6.1, w: 5.0, h: 5.2, dy: dy, squashX: squashX, squashY: squashY))
        path.addEllipse(in: transformedRect(v, x: 4.25, y: 7.3, w: 7.5, h: 5.1, dy: dy, squashX: squashX, squashY: squashY))
        path.addEllipse(in: transformedRect(v, x: 3.9, y: 5.2, w: 8.2, h: 6.2, dy: dy, squashX: squashX, squashY: squashY))
        return path
    }

    private func drawCloud(_ c: GraphicsContext, v: V, dy: CGFloat, squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let path = cloudPath(v, dy: dy, squashX: squashX, squashY: squashY)
        let top = v.p(7.5, 2.5 + dy)
        let bottom = v.p(8.2, 13.8 + dy)
        c.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [Self.cloudTop, Self.cloudMid, Self.cloudBottom]),
                startPoint: top,
                endPoint: bottom
            )
        )

        let highlight = Path(ellipseIn: transformedRect(v, x: 4.95, y: 4.15, w: 4.2, h: 2.0, dy: dy, squashX: squashX, squashY: squashY))
        c.fill(highlight, with: .color(Self.cloudGlow))
    }

    private func drawPrompt(
        _ c: GraphicsContext,
        v: V,
        dy: CGFloat,
        color: Color,
        cursorOn: Bool,
        promptOpacity: Double = 1
    ) {
        let stroke = StrokeStyle(lineWidth: max(1.2, v.s * 1.15), lineCap: .round, lineJoin: .round)

        var chevron = Path()
        chevron.move(to: v.p(5.0, 7.5 + dy))
        chevron.addLine(to: v.p(6.9, 9.2 + dy))
        chevron.addLine(to: v.p(5.0, 10.9 + dy))
        c.stroke(chevron, with: .color(color.opacity(promptOpacity)), style: stroke)

        if cursorOn {
            var cursor = Path()
            cursor.move(to: v.p(9.0, 10.9 + dy))
            cursor.addLine(to: v.p(11.9, 10.9 + dy))
            c.stroke(cursor, with: .color(color.opacity(promptOpacity)), style: stroke)
        }
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat, y: CGFloat = 15.3, opacity: Double) {
        c.fill(
            Path(ellipseIn: v.r(8 - width / 2, y, width, 0.95)),
            with: .color(.black.opacity(opacity))
        )
    }

    private func drawKeyboard(_ c: GraphicsContext, v: V, flashIndex: Int?) {
        c.fill(Path(roundedRect: v.r(0.6, 12.6, 14.8, 2.8), cornerSize: CGSize(width: 1.1 * v.s, height: 1.1 * v.s)), with: .color(Self.kbBase))

        for row in 0..<2 {
            for col in 0..<5 {
                let keyRect = v.r(1.5 + CGFloat(col) * 2.5, 13.0 + CGFloat(row) * 0.95, 1.7, 0.45)
                c.fill(Path(roundedRect: keyRect, cornerSize: CGSize(width: 0.25 * v.s, height: 0.25 * v.s)), with: .color(Self.kbKey))
            }
        }

        if let flashIndex {
            let row = flashIndex / 5
            let col = flashIndex % 5
            let flashRect = v.r(1.5 + CGFloat(col) * 2.5, 13.0 + CGFloat(row) * 0.95, 1.7, 0.45)
            c.fill(Path(roundedRect: flashRect, cornerSize: CGSize(width: 0.25 * v.s, height: 0.25 * v.s)), with: .color(Self.kbHi.opacity(0.95)))
        }
    }

    private var sleepScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                sleepCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                floatingZs(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
        }
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.8 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                let baseOpacity = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOpacity : (1.0 - phase) * 3.5 * baseOpacity
                let xOff = size * CGFloat(0.10 + ci * 0.06 + sin(phase * .pi * 2) * 0.03)
                let yOff = -size * CGFloat(0.16 + phase * 0.38)

                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.0) / 4.0
        let float = sin(phase * .pi * 2) * 0.65
        let cursorPhase = t.truncatingRemainder(dividingBy: 1.2)
        let cursorOn = cursorPhase < 0.6

        return Canvas { c, sz in
            let v = V(sz)
            drawShadow(c, v: v, width: 7.0 + abs(float) * 0.25, opacity: 0.16)
            drawCloud(c, v: v, dy: float)
            drawPrompt(c, v: v, dy: float, color: Self.promptDim, cursorOn: cursorOn, promptOpacity: 1)
        }
    }

    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { timeline in
            workCanvas(t: timeline.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.42) * 0.95
        let cursorPhase = t.truncatingRemainder(dividingBy: 0.28)
        let cursorOn = cursorPhase < 0.14
        let keyPhase = Int(t / 0.09) % 10

        return Canvas { c, sz in
            let v = V(sz)
            drawShadow(c, v: v, width: 7.6 - abs(bounce) * 0.35, opacity: max(0.12, 0.28 - abs(bounce) * 0.04))
            drawKeyboard(c, v: v, flashIndex: keyPhase)
            drawCloud(c, v: v, dy: bounce)
            drawPrompt(c, v: v, dy: bounce, color: Self.promptC, cursorOn: cursorOn)
        }
    }

    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.alertC.opacity(alive ? 0.10 : 0))
                .frame(width: size * 0.82)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)

            TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
                alertCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.4)
        let pct = cycle / 3.4

        let jumpY = lerp([
            (0, 0), (0.04, 0), (0.10, -1.5), (0.16, 1.5),
            (0.20, -7), (0.26, 1.2), (0.30, -5.5), (0.36, 0.8),
            (0.42, -3.5), (0.50, 0.3), (0.62, 0), (1.0, 0),
        ], at: pct)
        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.025 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.018 : 1.0
        let shakeX: CGFloat = (pct > 0.12 && pct < 0.54) ? sin(pct * 90) * 0.55 : 0
        let flash = (pct > 0.04 && pct < 0.55) ? sin(pct * 26) * 0.5 + 0.5 : 0
        let promptColor = flash > 0.5 ? Self.alertC : Self.promptC
        let bangOpacity = lerp([
            (0, 0), (0.04, 1), (0.12, 1), (0.55, 1), (0.64, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.04, 1.25), (0.12, 1.0), (0.55, 1.0), (0.64, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz)
            drawShadow(c, v: v, width: 7.4 * (1.0 - abs(min(0, jumpY)) * 0.03), opacity: max(0.08, 0.30 - abs(min(0, jumpY)) * 0.03))
            c.translateBy(x: shakeX * v.s, y: 0)
            drawCloud(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawPrompt(c, v: v, dy: jumpY, color: promptColor, cursorOn: true)
            c.translateBy(x: -shakeX * v.s, y: 0)

            if bangOpacity > 0.01 {
                let body = Path(roundedRect: v.r(12.8, 3.6 + jumpY * 0.08, 1.15 * bangScale, 3.8 * bangScale), cornerSize: CGSize(width: 0.55 * v.s, height: 0.55 * v.s))
                let dot = Path(ellipseIn: v.r(12.85, 8.15 + jumpY * 0.08, 1.05 * bangScale, 1.05 * bangScale))
                c.fill(body, with: .color(Self.alertC.opacity(bangOpacity)))
                c.fill(dot, with: .color(Self.alertC.opacity(bangOpacity)))
            }
        }
    }
}
