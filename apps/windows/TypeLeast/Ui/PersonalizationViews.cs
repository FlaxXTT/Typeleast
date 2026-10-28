using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;
namespace TypeLeast.Ui;

internal static class PersonalizationViews
{
    public static UIElement Details(AppHost host,HistoryEntry entry)
    {
        var content=Theme.Stack(8);
        if(entry.Personalization is not {} trace)return content;
        content.Children.Add(Theme.Text(L10n.T(trace.Disabled?"本次未使用个性化资料。":"以下是提供给模型的参考，不表示模型一定采用了它们。"),12,Theme.Grey));
        foreach(var reference in trace.References.Take(64)) {
            var row=Theme.Row(8,Theme.Text((reference.Kind=="example"?L10n.T("表达示例"):(reference.Word??reference.Label??reference.SourceId))+" · "+(reference.Source=="extension"?L10n.T("扩展")+": "+(string.IsNullOrEmpty(reference.Label)?reference.SourceId:reference.Label):L10n.T("个人偏好")),12));
            if(reference.Word is {} word)row.Children.Add(Theme.Secondary(L10n.T(host.Preferences.IsExcluded(word)?"恢复参考":"不再参考"),()=>{var saved=host.Preferences.Excluded.FirstOrDefault(x=>x.Normalize(System.Text.NormalizationForm.FormKC).Equals(word.Normalize(System.Text.NormalizationForm.FormKC),StringComparison.OrdinalIgnoreCase));if(saved is not null)host.Preferences.Restore(saved);else host.Preferences.Exclude(word);}));
            content.Children.Add(row);
        }
        if(trace.Restored)content.Children.Add(Theme.Text(L10n.T("本次替换已撤销，已粘贴到其他程序的内容未改动。"),12,Theme.Grey));
        foreach(var replacement in trace.Replacements)content.Children.Add(Theme.Text(replacement.Heard+" → "+replacement.Word,12));
        if(trace.Blocked.Count>0)content.Children.Add(Theme.Text(L10n.T("部分高级替换因本次表达或校验未执行。"),12,Theme.Grey));
        if(trace.BeforeReplacements is not null)content.Children.Add(Theme.Secondary(L10n.T("恢复替换前结果并复制"),()=>host.UndoReplacement(entry)));
        return new Expander {Header=L10n.T("本次参考与修改"),Content=content,Margin=new Thickness(0,8,0,0)};
    }
}
