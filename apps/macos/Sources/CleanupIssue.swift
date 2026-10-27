import Foundation

enum CleanupIssue {
    static func message(_ reason: String?) -> String {
        switch reason {
        case "model-timeout": return L10n.text("整理等待超时，本次内容已保留。")
        case "model-max-tokens": return L10n.text("整理结果被截断，未插入不完整内容。")
        case "incomplete-output": return L10n.text("整理结果可能遗漏信息，请重试或修改。")
        case "review-invalid": return L10n.text("完整性审查未完成，本次草稿已保留。")
        case "no-api-key": return L10n.text("请先配置可用的整理模型。")
        default: return L10n.text("本次整理未通过检查，可重试或修改。")
        }
    }
}
