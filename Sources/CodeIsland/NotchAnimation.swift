import SwiftUI

enum NotchAnimation {
    /// 展开面板：微弹，有少许回弹感
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// 收起面板：临界阻尼，无过冲（防止 NotchPanelShape 底边露出刘海）
    static let close = Animation.spring(response: 0.38, dampingFraction: 1.0)
    /// 通知弹出：快速弹跳，用于 completion/approval 自动展开
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.65)
    /// 卡片快速消场：临界阻尼、短时长。用于 permission/question/completion 按钮
    /// 回调触发的卡片退出，避免与入场/离场 transition 的插值互相抢占。
    static let card = Animation.spring(response: 0.28, dampingFraction: 1.0)
    /// 微交互：hover 状态变化、按钮高亮等
    static let micro = Animation.easeOut(duration: 0.12)
}

// MARK: - Lift + Fade transition

private struct LiftFadeModifier: ViewModifier {
    let yOffset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .offset(y: yOffset)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// Short upward lift + fade, used when dismissing the chat panel.
    static var liftFadeUp: AnyTransition {
        .modifier(
            active: LiftFadeModifier(yOffset: -22, opacity: 0),
            identity: LiftFadeModifier(yOffset: 0, opacity: 1)
        )
    }
}

// MARK: - MorphText — blur morph on text change

/// Text that briefly blurs when its content changes, creating a smooth "morph" effect.
struct MorphText: View {
    let text: String
    var font: Font = .system(size: 12)
    var color: Color = .white
    var lineLimit: Int? = 1

    @State private var displayed: String
    @State private var blur: CGFloat = 0
    @State private var generation = 0

    init(text: String, font: Font = .system(size: 12), color: Color = .white, lineLimit: Int? = 1) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        _displayed = State(initialValue: text)
    }

    var body: some View {
        Text(displayed)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .blur(radius: blur * 4)
            .opacity(1 - blur * 0.15)
            .compositingGroup()
            .onChange(of: text) { _, newText in
                guard newText != displayed else { return }
                generation += 1
                let gen = generation
                withAnimation(.easeOut(duration: 0.1)) { blur = 1 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard gen == generation else { return }
                    displayed = newText
                    withAnimation(.easeOut(duration: 0.15)) { blur = 0 }
                }
            }
    }
}
