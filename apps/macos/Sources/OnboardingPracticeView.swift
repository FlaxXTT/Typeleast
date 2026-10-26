import SwiftUI

struct OnboardingPracticeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("完成三组真实语音练习")).font(.headline)
                Text(L10n.text("需要真实识别和整理通过。练习只在此显示，不粘贴、不保存历史，也不加入正式偏好。"))
                    .font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                ExplanationMarkerPicker().disabled(practice.busy)
                Picker(L10n.text("练习"), selection: $practice.exercise) {
                    Text(L10n.text("1. 改口与条件")).tag(0)
                    Text(L10n.text("2. 解释与正文")).tag(1)
                    Text(L10n.text("3. 确认修改")).tag(2)
                }.disabled(practice.busy)
                if practice.exercise == 0 { Text(L10n.text("请读完示例句，或说出同样包含改口、数字和条件的内容。")).font(.caption).foregroundColor(Theme.secondary) }
                if practice.exercise == 1 { Text(L10n.text("请把开始词和结束词也读出来，解释不会出现在结果中。")).font(.caption).foregroundColor(Theme.secondary) }
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
                if practice.exercise == 2 && !practice.output.isEmpty {
                    Text(L10n.text("修改至少一处表达，再确认。此处只演示偏好确认，不保存练习资料。"))
                        .font(.system(size: 12)).foregroundColor(Theme.secondary)
                    TextEditor(text: $practice.revision).font(.system(size: 13)).frame(height: 80)
                    Button(L10n.text("确认修改")) { practice.confirmReview() }.buttonStyle(SecondaryButtonStyle()).disabled(practice.busy)
                }
                Text(L10n.text("已完成 {0} / 3", practice.progress.completed.count)).font(.system(size: 12, weight: .semibold))
            }.padding(.trailing, 8)
        }.frame(height: 340)
            .onAppear { practice.acceptsShortcut = true }
            .onDisappear { practice.acceptsShortcut = false; practice.cancel() }
    }
}
