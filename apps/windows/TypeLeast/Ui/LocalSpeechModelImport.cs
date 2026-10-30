using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class LocalSpeechModelImport : Window
{
    private readonly AppHost host;
    private readonly TextBox name = Theme.Input("", 400);
    private readonly TextBlock folder = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock problem = Theme.Text("", 12, Theme.Grey);
    private readonly StackPanel mapping = Theme.Stack(6);
    private readonly ComboBox family = Theme.Choice(400);
    private readonly Dictionary<string, TextBox> fields = new();
    private string directory = "";
    private readonly Button submit;
    private static readonly Dictionary<string, Dictionary<string, string>> Templates = new() {
        ["qwen3-asr-0.6b"] = new() { ["convFrontend"] = "conv_frontend.onnx", ["encoder"] = "encoder.int8.onnx", ["decoder"] = "decoder.int8.onnx", ["tokenizer"] = "tokenizer" },
        ["sensevoice-small"] = new() { ["model"] = "model.int8.onnx", ["tokens"] = "tokens.txt" },
        ["fireredasr2-ctc"] = new() { ["model"] = "model.int8.onnx", ["tokens"] = "tokens.txt" },
        ["fun-asr-nano"] = new() { ["encoderAdaptor"] = "encoder_adaptor.int8.onnx", ["llm"] = "llm.int8.onnx", ["embedding"] = "embedding.int8.onnx", ["tokenizer"] = "Qwen3-0.6B" },
    };
    public LocalSpeechModelImport(AppHost host)
    {
        this.host = host; Title = L10n.T("导入本地模型"); Width = 600; Height = 620; Background = Theme.Background;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        foreach (var id in Templates.Keys) family.Items.Add(id);
        family.SelectionChanged += (_, _) => RenderMapping(); family.SelectedIndex = 0;
        var choose = Theme.Secondary(L10n.T("选择模型文件夹"), () => {
            var dialog = new Microsoft.Win32.OpenFolderDialog();
            if (dialog.ShowDialog(this) == true) { directory = dialog.FolderName; folder.Text = directory; }
        });
        submit = Theme.Primary(L10n.T("检查并配置"), Submit);
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = Theme.Stack(12,
            Theme.Text(L10n.T("仅支持现有适配器兼容的 ONNX。模型来自本地，未经官方审核；加载成功不代表文件安全。"), 12, Theme.Grey),
            Theme.Text(L10n.T("模型名称"), 13), name, Theme.Text(L10n.T("模型类型"), 13), family, choose, folder, mapping,
            Theme.Text(L10n.T("文件路径相对于所选目录。配置不调用整理模型。"), 12, Theme.Grey), problem, submit,
            Theme.Secondary(L10n.T("取消"), Close)), Padding = new Thickness(24) };
    }
    private void RenderMapping()
    {
        fields.Clear(); mapping.Children.Clear();
        if (family.SelectedItem is not string id) return;
        foreach (var pair in Templates[id]) {
            var input = Theme.Input("", 400); input.Text = pair.Value; fields[pair.Key] = input;
            mapping.Children.Add(Theme.Text(pair.Key, 12, Theme.Grey)); mapping.Children.Add(input);
        }
    }
    private async void Submit()
    {
        if (host.Phase != DictationPhase.Idle || string.IsNullOrWhiteSpace(name.Text) || directory.Length == 0 || family.SelectedItem is not string id) return;
        submit.IsEnabled = false;
        try {
            var value = new { name = name.Text, family = id, directory, files = fields.ToDictionary(p => p.Key, p => p.Value.Text) };
            await host.Client.LocalModelActionAsync("local/inspect", value);
            await host.Client.LocalModelActionAsync("local/register", value);
            await host.RefreshHealth(); Close();
        }
        // A timeout or a dropped connection must not escape this async void handler (and leave the button dead).
        catch (Exception e) when (e is ServiceException or System.Net.Http.HttpRequestException or OperationCanceledException or System.IO.IOException)
        { problem.Text = L10n.T("模型文件不兼容或路径无效。当前模型保留。"); submit.IsEnabled = true; }
    }
}
