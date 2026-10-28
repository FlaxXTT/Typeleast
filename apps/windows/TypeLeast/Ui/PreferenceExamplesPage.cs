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
    private readonly ManualDictionaryPage manual;
    private readonly StackPanel root = new(), content = new();
    private readonly ComboBox tabs = Theme.Choice(460);
    private readonly ComboBoxItem examplesTab = new();
    private readonly Dictionary<string,string> drafts = new();
    private long revision = -1;
    private int pendingCount;
    private string shownWords="",wordDraft="",heardDraft="",excludeDraft="";
    private Action? undo;
    public UIElement View => root;
    public DictionaryPage(AppHost host)
    {
        this.host = host; manual = new ManualDictionaryPage(host);
        examplesTab.Content=L10n.T("表达示例（{0}）",0); tabs.Items.Add(examplesTab); tabs.Items.Add(L10n.T("个人词汇")); tabs.Items.Add(L10n.T("排除与高级规则")); tabs.SelectedIndex=0;
        root.Children.Add(tabs); root.Children.Add(content);
        tabs.SelectionChanged += (_,_)=>Render(); Render();
    }
    public void Refresh()
    {
        if (revision != host.Preferences.Revision || shownWords!=JsonSerializer.Serialize(host.Settings.DictionaryEntries)) Render();
    }
    private void Render()
    {
        revision=host.Preferences.Revision; pendingCount=host.Preferences.Pending.Count;
        shownWords=JsonSerializer.Serialize(host.Settings.DictionaryEntries);
        examplesTab.Content=L10n.T("表达示例（{0}）",pendingCount);
        content.Children.Clear();
        if (tabs.SelectedIndex>0) { RenderRules(tabs.SelectedIndex==2); return; }
        content.Children.Add(Theme.Text(L10n.T("个人偏好"),28,bold:true));
        content.Children.Add(Theme.Text(L10n.T("让整理参考你确认过的表达。"),13,Theme.Grey));
        content.Children.Add(MarkerPicker(host));
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
                Theme.Text(L10n.T("识别原文"),12,Theme.Grey),Theme.Text(item.Raw,13),
                Details(item.AiText),Theme.Text(L10n.T("用户修改后"),12,Theme.Grey),editor,
                Theme.Text(L10n.T("确认后才保存并允许作为相关示例；不修改模型权重。待确认内容只保留在内存中。"),12,Theme.Grey),
                Theme.Row(8,accept,Theme.Secondary(L10n.T("忽略"),()=>{host.Preferences.Dismiss(item.Id);drafts.Remove(item.Id);Render();})))));
        }
        if (host.Preferences.Entries.Count==0 && pendingCount==0)
            content.Children.Add(Theme.Card(Theme.Stack(12,
                Theme.Text("✎",28,Theme.Grey),
                Theme.Text(L10n.T("还没有表达示例"),17,bold:true),
                Theme.Text(L10n.T("从历史记录中选择一次输出，填写并确认你的修改。"),13,Theme.Grey),
                Theme.Primary(L10n.T("前往历史"),()=>host.ShowWindow(MainWindow.Page.History)))));
        if(host.Preferences.Entries.Count>0)content.Children.Add(Theme.SectionTitle(L10n.T("已保存的示例")));
        foreach(var item in host.Preferences.Entries) {
            var toggle=Theme.Toggle(item.Enabled,enabled=>{host.Preferences.SetEnabled(item.Id,enabled);Render();});
            content.Children.Add(Theme.Card(Theme.Stack(10,
                Theme.Text(L10n.T("识别原文"),12,Theme.Grey),Theme.Text(item.Raw,13),
                Theme.Text(L10n.T("用户修改后"),12,Theme.Grey),Theme.Text(item.CorrectedText,13),Details(item.AiText),
                Theme.SettingRow(L10n.T("启用相关示例"),null,toggle),
                Theme.Secondary(L10n.T("删除"),()=>{host.Preferences.Remove(item.Id);Render();}))));
        }
        content.Children.Add(Theme.Card(new Expander {
            Header=L10n.T("资料如何使用"),
            Content=Theme.Stack(10,
                Theme.Text(L10n.T("仅在本机加密保存。只有相关且已确认、启用的短示例会随听写整理发给当前模型；涉及名称或数值变化的示例不作为自动替换依据。"),12,Theme.Grey),
                Theme.Text(L10n.T("已确认资料独立保存，清空历史不会删除；可在本页删除。"),12,Theme.Grey),
                Theme.Text(L10n.T("在历史中打开一条记录，选择「记录修改为偏好示例」，再填写最终修改。"),12,Theme.Grey))
        }));
    }
    private static Expander Details(string text) => new() { Header=L10n.T("处理结果（供对照）"),Content=Theme.Text(text,12,Theme.Grey) };
    private void RenderRules(bool advanced)
    {
        var preferences=host.Preferences;
        content.Children.Add(Theme.Text(L10n.T(advanced?"排除与高级规则":"个人词汇"),26,bold:true));
        content.Children.Add(Theme.Text(L10n.T(advanced?"不再参考会暂停所有来源对该词的推荐和替换，不禁止你当次说出它。扩展更新不会恢复这些影响。":"词汇只帮助理解，不强制替换。旧自动词汇保留为停用资料，需要你确认后才能参考。"),12,Theme.Grey));
        if(advanced) {
            var exclude=Theme.Input(excludeDraft,220);exclude.TextChanged+=(_,_)=>excludeDraft=exclude.Text;
            content.Children.Add(Theme.Row(8,exclude,Theme.Secondary(L10n.T("不再参考"),()=>{var word=excludeDraft;if(preferences.Exclude(word)){excludeDraft="";undo=()=>preferences.Restore(word);}Render();})));
            foreach(var term in preferences.Excluded.ToArray())content.Children.Add(Theme.Row(8,Theme.Text(term,13),Theme.Secondary(L10n.T("恢复参考"),()=>{preferences.Restore(term);undo=()=>preferences.Exclude(term);Render();})));
            content.Children.Add(Theme.Text(L10n.T("高级显式替换"),18,bold:true));
            content.Children.Add(Theme.Text(L10n.T("旧替换保留但默认停用，需逐条开启。当前明确改口、条件和事实校验优先；不会保证每次替换。"),12,Theme.Grey));
        }
        var spelling=Theme.Input(wordDraft,220);spelling.TextChanged+=(_,_)=>wordDraft=spelling.Text;
        var heard=Theme.Input(heardDraft,220);heard.TextChanged+=(_,_)=>heardDraft=heard.Text;
        if(advanced){content.Children.Add(Theme.Text(L10n.T("识别成"),12));content.Children.Add(heard);}
        content.Children.Add(Theme.Text(L10n.T(advanced?"正确写法":"新词"),12));content.Children.Add(spelling);
        content.Children.Add(Theme.Secondary(L10n.T(advanced?"保存为停用规则":"添加"),()=>{
            if(advanced&&(string.IsNullOrWhiteSpace(heardDraft)||heardDraft==wordDraft))return;
            if(WordEntry.Parse(wordDraft,advanced?heardDraft:"") is {} word && host.Dictionary.SaveWord(word)) {
                undo=()=>host.Dictionary.RemoveWord(word.Id);wordDraft="";heardDraft="";Render();
            }
        }));
        foreach(var word in host.Settings.DictionaryEntries.Where(x=>advanced?x.ReplacementHeard is not null:x.ReplacementHeard is null).ToArray()) {
            var toggle=Theme.Toggle(advanced?preferences.Replaces(word):preferences.References(word),value=>{
                var old=advanced?preferences.Replaces(word):preferences.References(word);
                if(advanced)preferences.SetRule(word,value);else preferences.SetReference(word.Id,value);
                undo=()=>{if(advanced)preferences.SetRule(word,old);else preferences.SetReference(word.Id,old);};Render();
            });
            toggle.IsEnabled=!preferences.IsExcluded(word.Word)&&(advanced?!preferences.IsExcluded(word.ReplacementHeard??""):!word.LocalOnly);
            content.Children.Add(Theme.Card(Theme.Stack(8,Theme.Text(advanced?word.ReplacementHeard+" → "+word.Word:word.Word,14),
                Theme.SettingRow(L10n.T(advanced?"启用本机替换":"作为相关参考"),null,toggle),
                Theme.Row(8,Theme.Secondary(L10n.T("不再参考"),()=>{preferences.Exclude(word.Word);undo=()=>preferences.Restore(word.Word);Render();}),
                    Theme.Secondary(L10n.T("删除"),()=>{host.Dictionary.RemoveWord(word.Id);undo=()=>host.Dictionary.SaveWord(word);Render();})))));
        }
        if(preferences.Problem is not null)content.Children.Add(Theme.Text(L10n.T("偏好资料无法保存或已达上限，原资料已保留。"),12,Theme.Warning));
        if(undo is not null)content.Children.Add(Theme.Secondary(L10n.T("撤销上次变更"),()=>{var action=undo;undo=null;action?.Invoke();Render();}));
        if(!advanced)content.Children.Add(new Expander {Header=L10n.T("导入与旧资料管理"),Content=new ManualDictionaryPage(host).View});
    }

    public static UIElement MarkerPicker(AppHost host)
    {
        var choice=Theme.Choice(400);choice.Width=double.NaN;choice.MaxWidth=400;choice.HorizontalAlignment=HorizontalAlignment.Stretch;choice.Items.Add(new ComboBoxItem {Content=L10n.T("关闭"),Tag=""});
        foreach(var id in ExplanationMarkers.VisibleIds)choice.Items.Add(new ComboBoxItem {Content=ExplanationMarkers.Label(id),Tag=id});
        choice.SelectedIndex=Array.IndexOf(ExplanationMarkers.VisibleIds,host.Settings.ExplanationMarkers)+1;
        choice.SelectionChanged+=(_,_)=>{ if(choice.SelectedItem is ComboBoxItem {Tag:string id}) {host.Settings.ExplanationMarkers=id;host.SaveSettings();} };
        return Theme.Card(Theme.Stack(8,Theme.Text(L10n.T("解释触发词"),14,bold:true),choice,
            Theme.Text(L10n.T("用于听写。标记内的内容只作本次解释，不写入结果，也不成为永久替换规则。也可直接说明名称或拼写。"),12,Theme.Grey)));
    }
}
