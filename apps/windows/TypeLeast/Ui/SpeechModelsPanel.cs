using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class SpeechModelsPanel
{
    public StackPanel View { get; } = new();
    private readonly AppHost host;
    private readonly Dictionary<string, (TextBlock state, Button action, Button cancel, ProgressBar progress)> rows = new();
    private string signature = "";
    private bool otherExpanded;
    private readonly TextBlock problem = Theme.Text("", 12, Theme.Grey);
    /// <summary>Shown first to someone who has not chosen yet: small and quick to download.</summary>
    private const string Recommended = "qwen3-asr-0.6b";
    public SpeechModelsPanel(AppHost host) { this.host = host; }

    public void Refresh()
    {
        if (host.SpeechCatalog is not { } catalog) return;
        var next = catalog.ActiveModelId + "|" + string.Join("|", catalog.Models.Select(m => m.Id + ":" + m.Registered));
        if (signature != next || View.Children.Count == 0) {
            signature = next; rows.Clear(); View.Children.Clear();
            View.Children.Add(Theme.SectionTitle(L10n.T("语音模型")));
            // One model up front: the one in use, or the recommended small one; the rest are one click away.
            var featured = catalog.Models.FirstOrDefault(m => m.Id == catalog.ActiveModelId && m.Installed) ?? catalog.Models.FirstOrDefault(m => m.Id == Recommended);
            if (featured is not null) AddRow(View, featured);
            var others = Theme.Stack(10);
            others.Children.Add(Theme.Text(L10n.T("自行下载兼容的 ONNX 文件，再选择目录配置。不会搬动或删除原文件。"), 12, Theme.Grey));
            others.Children.Add(Theme.Secondary(L10n.T("导入本地模型"), () => new LocalSpeechModelImport(host).Show()));
            foreach (var m in catalog.Models.Where(m => m.Id != featured?.Id)) AddRow(others, m);
            var busyInOthers = catalog.Operation is { Running: true } op && op.ModelId != featured?.Id;
            var expand = new Expander { Header = L10n.T("更多模型"), Content = others, Foreground = Theme.Ink, IsExpanded = otherExpanded || busyInOthers, Margin = new Thickness(0, 10, 0, 10) };
            expand.Expanded += (_, _) => otherExpanded = true; expand.Collapsed += (_, _) => otherExpanded = false;
            View.Children.Add(expand); View.Children.Add(problem);
        }
        foreach (var m in catalog.Models) {
            if (!rows.TryGetValue(m.Id, out var row)) continue;
            var selected = catalog.ActiveModelId == m.Id && host.Speech?.Ready == true;
            var primary = m.Category == "primary" || m.Id == "qwen3-asr-0.6b";
            var configured = primary || m.Registered || selected;
            var op = catalog.Operation?.ModelId == m.Id ? catalog.Operation : null;
            row.action.Content = selected ? L10n.T("使用中") : !configured ? L10n.T("一键配置") : !m.Installed && primary ? L10n.T("下载并使用") : L10n.T("使用");
            row.action.Visibility = configured || m.Installed ? Visibility.Visible : Visibility.Collapsed;
            row.action.IsEnabled = !selected && catalog.Operation?.Running != true && host.Phase == DictationPhase.Idle;
            row.state.Text = (m.Precision == "local" ? L10n.T("本地文件") : m.Precision == "fp16" ? L10n.T("FP16（前端 FP32）") : "INT8") + " · " + (m.ModelBytes / 1_000_000_000).ToString("F2", L10n.Culture) + " GB";
            if (m.Installed) row.state.Text += " · " + L10n.T("已下载");
            if (op?.Running == true) row.state.Text += " · " + L10n.T("等待或加载中…");
            if (op?.Phase == "error") row.state.Text += " · " + op.Problem;
            row.cancel.Visibility = op?.Running == true && op.Phase != "loading" ? Visibility.Visible : Visibility.Collapsed;
            row.progress.Visibility = op?.Phase == "downloading" ? Visibility.Visible : Visibility.Collapsed;
            row.progress.Value = op is { Total: > 0 } ? Math.Clamp(op.Received / op.Total, 0, 1) : 0;
        }
        problem.Text = catalog.Notice is not null ? L10n.T("所选模型不可用，请重新选择。") : "";
        if (catalog.Operation is { } pending && !catalog.Models.Any(m => m.Id == pending.ModelId))
            problem.Text = pending.Running ? L10n.T("等待或加载中…") : pending.Phase == "error" ? pending.Problem : L10n.T("配置完成。请在更多模型中选择使用。");
    }
    private void AddRow(StackPanel target, SpeechModelOption m)
    {
        var id = m.Id;
        var state = Theme.Text("", 12, Theme.Grey);
        var action = Theme.Secondary("", async () => {
            var current = host.SpeechCatalog?.Models.Find(x => x.Id == id);
            if (current is null) return;
            if (current.Category != "primary" && id != "qwen3-asr-0.6b" && !current.Registered && host.SpeechCatalog?.ActiveModelId != id)
                await LocalAction("register-known", id);
            else await host.ManageSpeechModel(id, (current.Category == "primary" || id == "qwen3-asr-0.6b") && (!current.Installed || host.SpeechCatalog?.Operation is { Error: "checksum-mismatch" } op && op.ModelId == id));
        });
        var cancel = Theme.Secondary(L10n.T("取消"), () => _ = host.ManageSpeechModel(id, cancel: true));
        var progress = new ProgressBar { Minimum = 0, Maximum = 1, Height = 5, Width = 150 };
        var tools = new WrapPanel();
        if (!string.IsNullOrEmpty(m.SourceUrl)) tools.Children.Add(Theme.Secondary(L10n.T("模型来源与下载"), () => Shell.Open(m.SourceUrl)));
        tools.Children.Add(progress); tools.Children.Add(cancel);
        if (m.Registered && host.SpeechCatalog?.ActiveModelId != id) tools.Children.Add(Theme.Secondary(L10n.T("移除登记"), () => _ = LocalAction("local/remove", id)));
        var card = Theme.Stack(6, Theme.SettingRow(m.Name + (id == Recommended ? " · " + L10n.T("推荐") : ""), null, action));
        if (m.Category == "primary" || id == "qwen3-asr-0.6b") card.Children.Add(Theme.Text(id.Contains("1.7b") ? L10n.T("多语种 · 中英混说 · 较大容量") : L10n.T("多语种 · 中英混说 · 较小体积"), 12, Theme.Grey));
        else card.Children.Add(Theme.Text(id switch { "sensevoice-small" => L10n.T("轻量 · 快速 · 五语种"), "fireredasr2-ctc" => L10n.T("中文 · 方言 · CTC"), "fun-asr-nano" => L10n.T("中英日 · 混说 · 口音"), _ => L10n.T("兼容导入 · 本地识别") }, 12, Theme.Grey));
        card.Children.Add(state); card.Children.Add(tools); target.Children.Add(Theme.Card(card));
        if (m.Precision == "fp16") card.Children.Add(Theme.Text(L10n.T("Mac 实测加载峰值约 12.5 GiB；不同环境会变化。"), 12, Theme.Grey));
        rows[id] = (state, action, cancel, progress);
    }
    private async System.Threading.Tasks.Task LocalAction(string path, string id)
    {
        if (host.Phase != DictationPhase.Idle) return;
        try { await host.Client.LocalModelActionAsync(path, new { modelId = id }); await host.RefreshHealth(); }
        catch (ServiceException) { problem.Text = L10n.T("模型操作失败，请重试。当前模型保留。"); }
    }
}
