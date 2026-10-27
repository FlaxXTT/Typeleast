using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class DictionaryPage : IPage
{
    private readonly AppHost host;

    private readonly StackPanel root = new(), content = new();
    private readonly Dictionary<string,string> drafts = new();
    private long revision = -1;
    private int pendingCount;
    public UIElement View => root;
    public DictionaryPage(AppHost host)
    {
        this.host = host;
        root.Children.Add(content); Render();
    }
    public void Refresh()
    {
        if (revision != host.Preferences.Revision) Render();
    }
    private void Render()
    {
        revision=host.Preferences.Revision; pendingCount=host.Preferences.Pending.Count;
        content.Children.Clear();

        content.Children.Add(Theme.Text(L10n.T("偏好示例"),28,bold:true));
        content.Children.Add(Theme.Text(L10n.T("保存真实识别与用户确认的修改，不自动训练模型。"),13,Theme.Grey));
        content.Children.Add(MarkerPicker(host));
        content.Children.Add(Theme.Text(L10n.T("仅在本机加密保存。只有相关且已确认、启用的短示例会随自然整理或 AI 整理发给当前模型；涉及名称或数值变化的示例不作为自动替换依据。"),12,Theme.Grey));
        content.Children.Add(Theme.Text(L10n.T("已确认资料独立保存，清空历史不会删除；可在本页删除。"),12,Theme.Grey));
        if (host.Preferences.Problem is not null) content.Children.Add(Theme.Text(L10n.T("偏好资料无法保存或已达上限，原资料已保留。"),12,Theme.Warning));
        if (pendingCount>0) content.Children.Add(Theme.SectionTitle(L10n.T("待确认的修改")));
        foreach (var item in host.Preferences.Pending.ToArray()) {
            var editor = new TextBox { Text=drafts.GetValueOrDefault(item.Id,item.CorrectedText), AcceptsReturn=true,
                TextWrapping=TextWrapping.Wrap, MaxLength=4000, MinHeight=100, MaxHeight=180,
                VerticalScrollBarVisibility=ScrollBarVisibility.Auto, FontSize=14 };
            var accept=Theme.Primary(L10n.T("确认并启用"),()=>{
                var candidate=new PreferenceExample { Id=item.Id,HistoryId=item.HistoryId,Raw=item.Raw,AiText=item.AiText,CorrectedText=editor.Text.Trim(),CreatedAt=item.CreatedAt };
                if (host.Preferences.Confirm(candidate)) drafts.Remove(item.Id); Render();
            });
            void Update() { drafts[item.Id]=editor.Text; accept.IsEnabled=!string.IsNullOrWhiteSpace(editor.Text) && editor.Text!=item.AiText; }
            editor.TextChanged+=(_,_)=>Update(); Update();
            content.Children.Add(Theme.Card(Theme.Stack(10,
                Theme.Text(L10n.T("AI 整理前（识别原文）"),12,Theme.Grey),Theme.Text(item.Raw,13),
                Details(item.AiText),Theme.Text(L10n.T("用户修改后"),12,Theme.Grey),editor,
                Theme.Text(L10n.T("确认后才保存并允许作为相关示例；不修改模型权重。待确认内容只保留在内存中。"),12,Theme.Grey),
                Theme.Row(8,accept,Theme.Secondary(L10n.T("忽略"),()=>{host.Preferences.Dismiss(item.Id);drafts.Remove(item.Id);Render();})))));
        }
        if (host.Preferences.Entries.Count==0 && pendingCount==0)
            content.Children.Add(Theme.Text(L10n.T("在历史中选择一条整理记录，点击「记录偏好」，再填写最终修改。"),13,Theme.Grey));
        foreach(var item in host.Preferences.Entries) {
            var toggle=Theme.Toggle(item.Enabled,enabled=>{host.Preferences.SetEnabled(item.Id,enabled);Render();});
            content.Children.Add(Theme.Card(Theme.Stack(10,
                Theme.Text(L10n.T("AI 整理前（识别原文）"),12,Theme.Grey),Theme.Text(item.Raw,13),
                Theme.Text(L10n.T("用户修改后"),12,Theme.Grey),Theme.Text(item.CorrectedText,13),Details(item.AiText),
                Theme.SettingRow(L10n.T("启用相关示例"),null,toggle),
                Theme.Secondary(L10n.T("删除"),()=>{host.Preferences.Remove(item.Id);Render();}))));
        }
    }
    private static Expander Details(string text) => new() { Header=L10n.T("处理结果（供对照）"),Content=Theme.Text(text,12,Theme.Grey) };
    public static UIElement MarkerPicker(AppHost host)
    {
        var choice=Theme.Choice(400);choice.Width=double.NaN;choice.MaxWidth=400;choice.HorizontalAlignment=HorizontalAlignment.Stretch;choice.Items.Add(new ComboBoxItem {Content=L10n.T("关闭"),Tag=""});
        foreach(var id in ExplanationMarkers.VisibleIds)choice.Items.Add(new ComboBoxItem {Content=ExplanationMarkers.Label(id),Tag=id});
        choice.SelectedIndex=Array.IndexOf(ExplanationMarkers.VisibleIds,host.Settings.ExplanationMarkers)+1;
        choice.SelectionChanged+=(_,_)=>{ if(choice.SelectedItem is ComboBoxItem {Tag:string id}) {host.Settings.ExplanationMarkers=id;host.SaveSettings();} };
        return Theme.Card(Theme.Stack(8,Theme.Text(L10n.T("解释触发词"),14,bold:true),choice,
            Theme.Text(L10n.T("仅用于 AI 整理。开始词与结束词之间的内容只作本次解释，不写入结果，也不成为永久替换规则。"),12,Theme.Grey)));
    }
}
