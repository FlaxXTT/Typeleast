import SwiftUI

struct OnboardingPracticeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController
    let demo: OnboardingDemo
    @State private var skillHovered = false

    var body: some View {
        VStack(spacing: 15) {
            Text(demo.title).font(Theme.sectionTitleFont)
            Keycap(label: demo.shortcutLabel(in: model.settings), large: true)
            Text(instruction)
                .font(InterfaceTypography.localized(14)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if demo == .selectionTranslation {
                Button(action: practice.selectExample) {
                    sample.background(practice.selectionHighlighted ? Theme.accent.opacity(0.16) : Theme.card,
                                      in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(FlatActionButtonStyle())
                .accessibilityAddTraits(practice.selectionHighlighted ? .isSelected : [])
            } else if demo.usesSpeech {
                sample
                PracticePill(practice: practice)
                    .font(InterfaceTypography.localized(13, weight: .medium))
                    .foregroundStyle(.white)
            }
            if practice.showingSkill {
                VStack(spacing: 5) {
                    Image(systemName: "circle.hexagongrid").font(.system(size: 22, weight: .medium))
                    Text(demo.sample).font(Theme.rowFont)
                }
                .frame(width: 100, height: 100)
                .background(Circle().fill(skillHovered ? Theme.selection : Theme.card))
                .overlay(Circle().strokeBorder(Theme.border))
                .onHover { skillHovered = $0 }
                .onDisappear { skillHovered = false }
                .accessibilityElement(children: .combine)
            }
            outputField
            Text(L10n.text("这是演示。示例只写在这个窗口。"))
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: 555)
    }

    private var instruction: String {
        if demo == .skill, demo.binding(in: model.settings).fnChord == .space {
            return L10n.text("按住 Fn 和空格打开 Harness EQ，移到想用的 Skill，再松开两键调用。")
        }
        return demo.instruction
    }

    private var sample: some View {
        Text(demo.sample).font(Theme.rowFont)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .multilineTextAlignment(.center)
    }

    private var outputField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(demo == .selectionTranslation ? L10n.text("翻译面板") : L10n.text("练习输入框"),
                  systemImage: demo == .selectionTranslation ? "character.bubble" : "text.cursor")
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            Text(practice.output.isEmpty ? L10n.text("示例结果会显示在这里。") : practice.output)
                .font(Theme.rowFont)
                .foregroundStyle(practice.output.isEmpty ? Theme.secondary : Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .accessibilityIdentifier("onboarding-demo-output")
    }
}

/// An inline SwiftUI capsule keeps the animated demo inside the guide's layout.
private struct PracticePill: View {
    @ObservedObject var practice: OnboardingPracticeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder var body: some View {
        switch practice.phase {
        case .idle, .starting:
            Button {
                if let shortcut = practice.mode?.shortcut { practice.handle(shortcut) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").accessibilityHidden(true)
                    Text(L10n.text(practice.complete ? "再试一次" : "开始练习"))
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(surface)
            }
            .buttonStyle(FlatActionButtonStyle())
        case .recording:
            HStack(spacing: 3) {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { _ in
                    HStack(spacing: 3) {
                        ForEach(0..<9) { index in
                            let width = 1 - abs(Double(index) - 4) * 0.16
                            let time = reduceMotion ? 0 : practice.elapsed
                            let wave = 0.45 + 0.55 * abs(sin(time * 6 - Double(index) * 0.55))
                            Capsule().fill(Color.white)
                                .frame(width: 2, height: 3 + CGFloat(wave * width) * 17)
                        }
                    }
                    .frame(width: 48, height: 24)
                    .accessibilityHidden(true)
                }
                Button(action: practice.stop) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(FlatActionButtonStyle(feedback: .fixed))
                .accessibilityLabel(L10n.text("结束录音"))
            }
            .padding(.leading, 10).padding(.trailing, 7)
            .frame(height: 34)
            .background(surface)
        case .thinking:
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
                HStack(spacing: 7) {
                    Text("Thinking")
                    HStack(spacing: 3) {
                        ForEach(0..<5) { index in
                            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                            Circle().fill(Color.white.opacity(0.85))
                                .frame(width: 3, height: 3)
                                .offset(y: CGFloat(sin(time * 6 - Double(index) * 0.65)) * 3)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(surface)
            }
        }
    }

    private var surface: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(nsColor: VoiceBarPalette.surfaceTop), Color(nsColor: VoiceBarPalette.surfaceBottom)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(Color(nsColor: VoiceBarPalette.edge), lineWidth: 0.5))
    }
}
