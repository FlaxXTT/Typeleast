namespace TypeLeast.Core;
public static class CleanupIssue {
 public static string Message(string? reason)=>L10n.T(reason switch {
  "model-timeout"=>"整理等待超时，本次内容已保留。",
  "model-max-tokens"=>"整理结果被截断，未插入不完整内容。",
  "incomplete-output"=>"整理结果可能遗漏信息，请重试或修改。",
  "review-invalid"=>"完整性审查未完成，本次草稿已保留。",
  "no-api-key"=>"请先配置可用的整理模型。",
  _=>"本次整理未通过检查，可重试或修改。"
 });
}
