import SwiftUI

struct OnboardingPracticeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("试说一句")).font(.headline)
                Text(L10n.text("读下面这句，中途改口。结果只在这里显示。"))
                    .font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Text(practice.sample).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(practice.phase == .recording ? L10n.text("停止并整理") : L10n.text("开始录音")) { practice.toggle() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(practice.phase == .thinking)
                    Button(L10n.text("取消")) { practice.cancel() }.buttonStyle(SecondaryButtonStyle()).disabled(!practice.busy)
                }
                Text(practice.status).font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if !practice.raw.isEmpty {
                    Text(L10n.text("识别原文")).font(.caption)
                    Text(practice.raw).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !practice.output.isEmpty {
                    Text(L10n.text("整理结果")).font(.caption)
                    Text(practice.output).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.trailing, 8)
        }.frame(height: 340)
            .onAppear { practice.acceptsShortcut = true }
            .onDisappear { practice.acceptsShortcut = false; practice.cancel() }
    }
}
