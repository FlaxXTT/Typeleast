using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class SpeechModelsPanel
{
    public StackPanel View { get; } = new();
    private readonly AppHost host;
    private readonly Dictionary<string, (TextBlock state, Button action, Button cancel, ProgressBar progress)> rows = new();
    public SpeechModelsPanel(AppHost host) { this.host = host; }

    private static string Detail(string id) => id switch {
        "fireredasr2-ctc" => L10n.T("偏向中文与方言，也支持英文；自动检测语言。"),
        "fun-asr-nano" => L10n.T("适合中英混合听写，也支持日语。"),
        "qwen3-asr-0.6b" => L10n.T("多语言识别；体积和资源需求高于默认模型。"),
        _ => L10n.T("默认模型；体积小、响应快，支持中文、英文、粤语、日语和韩语。"),
    };
    public void Refresh()
    {
        if (host.SpeechCatalog is not { } catalog) return;
        if (rows.Count == 0) {
            View.Children.Add(Theme.SectionTitle(L10n.T("识别模型")));
            foreach (var model in catalog.Models) {
                var id = model.Id;
                var state = Theme.Text("", 12, Theme.Grey);
                var action = Theme.Secondary("", async () => {
                    var current = host.SpeechCatalog?.Models.Find(m => m.Id == id);
                    var badHash = host.SpeechCatalog?.Operation is { Error: "checksum-mismatch" } op && op.ModelId == id;
                    await host.ManageSpeechModel(id, current?.Installed != true || badHash);
                });
                var cancel = Theme.Secondary(L10n.T("取消下载"), async () => await host.ManageSpeechModel(id, cancel: true));
                var progress = new ProgressBar { Minimum = 0, Maximum = 1, Height = 5, Width = 150 };
                var source = Theme.Secondary(L10n.T("模型来源与下载链接"), () => Shell.Open(model.SourceUrl));
                var tools = new WrapPanel { Orientation = Orientation.Horizontal };
                foreach (var control in new FrameworkElement[] { source, progress, cancel }) {
                    control.Margin = new Thickness(0, 0, 8, 6);
                    tools.Children.Add(control);
                }
                var row = Theme.Stack(6,
                    Theme.SettingRow(model.Name, Theme.Text(Detail(id), 12, Theme.Grey), action),
                    state, tools);
                View.Children.Add(Theme.Card(row, 12));
                rows[id] = (state, action, cancel, progress);
            }
        }
        foreach (var model in catalog.Models) {
            if (!rows.TryGetValue(model.Id, out var row)) continue;
            var op = catalog.Operation?.ModelId == model.Id ? catalog.Operation : null;
            var selected = catalog.ActiveModelId == model.Id && host.Speech?.Ready == true;
            row.action.Content = selected ? L10n.T("正在使用") : !model.Installed || op?.Error == "checksum-mismatch" ? L10n.T("下载并启用") : L10n.T("使用");
            row.action.IsEnabled = !selected && catalog.Operation?.Running != true && host.Phase == DictationPhase.Idle;
            var status = model.ModelBytes / 1_000_000_000.0;
            row.state.Text = status.ToString("F2", L10n.Culture) + " GB · " + (model.Installed ? L10n.T("已下载") : L10n.T("未下载"));
            if (op?.Running == true) row.state.Text += " · " + (op.Phase == "downloading" ? L10n.T("正在下载…") : L10n.T("等待或加载中…"));
            if (op?.Phase == "error") row.state.Text += " · " + op.Problem;
            if (op?.Phase == "cancelled") row.state.Text += " · " + L10n.T("下载已取消，已校验的文件可复用。");
            if (catalog.Notice is not null && selected) row.state.Text += " · " + L10n.T("原选择的模型不可用，正在尝试默认模型。");
            row.cancel.Visibility = op?.Running == true && op.Phase != "loading" ? Visibility.Visible : Visibility.Collapsed;
            row.cancel.Content = op?.Phase == "downloading" ? L10n.T("取消下载") : L10n.T("取消");
            row.progress.Visibility = op?.Phase == "downloading" && op.Total > 0 ? Visibility.Visible : Visibility.Collapsed;
            row.progress.Value = op is { Total: > 0 } ? Math.Clamp(op.Received / op.Total, 0, 1) : 0;
        }
    }
}
