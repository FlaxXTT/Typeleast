import SwiftUI

enum ExplanationMarkers: String, CaseIterable, Identifiable {
    case note, background, explanation, aside
    static var visible: [ExplanationMarkers] { [.note] }
    var id: String { rawValue }
    var words: (String, String) {
        if L10n.language == "en" {
            switch self {
            case .note: return ("side note", "back to text")
            case .background: return ("context note begins", "context note ends")
            case .explanation: return ("explanation begins", "explanation ends")
            case .aside: return ("aside begins", "aside ends")
            }
        }
        switch self {
        case .note: return ("备注", "说完了")
        case .background: return ("补充背景开始", "补充背景结束")
        case .explanation: return ("解释内容开始", "解释内容结束")
        case .aside: return ("旁注开始", "旁注结束")
        }
    }
    var label: String { L10n.text("开始：{0}；结束：{1}", words.0, words.1) }
}

struct ExplanationMarkerPicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.text("解释触发词"), selection: model.setting(\.explanationMarkers)) {
                Text(L10n.text("关闭")).tag("")
                ForEach(ExplanationMarkers.visible) { Text($0.label).tag($0.rawValue) }
            }
            Text(L10n.text("用于听写。标记内的内容只作本次解释，不写入结果，也不成为永久替换规则。也可直接说明名称或拼写。"))
                .font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
