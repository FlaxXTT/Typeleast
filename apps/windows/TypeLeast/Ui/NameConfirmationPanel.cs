using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>Non-modal; only explicit user action can release a held result.</summary>
internal static class NameConfirmationPanel
{
    public sealed record Choice(string Kind, string Text);
    public static Task<Choice> Show(string question, string raw, CancellationToken ct, string? kind = null)
    {
        var completion = new TaskCompletionSource<Choice>(TaskCreationOptions.RunContinuationsAsynchronously);
        var previous = Native.GetForegroundWindow();
        var editor = new TextBox { Text = raw, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MinHeight = 140, MaxLength = 32000, FontSize = 14 };
        var window = new Window { Title = L10n.T(kind == "explanation" ? "检查解释触发词" : "确认本次名称"), Width = 580, Height = 390,
            MinWidth = 480, MinHeight = 320, Background = Theme.Background, ShowActivated = false,
            Topmost = true, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        void Finish(string kind, string text = "")
        {
            if (kind == "edit" && string.IsNullOrWhiteSpace(text)) return;
            var ours = new WindowInteropHelper(window).Handle;
            var restore = Native.GetForegroundWindow() == ours;
            completion.TrySetResult(new(kind, text));
            window.Close();
            if (restore) Native.SetForegroundWindow(previous);
        }
        var row = Theme.Row(8,
            Theme.Primary(L10n.T("使用修改内容"), () => Finish("edit", editor.Text.Trim())),
            Theme.Secondary(L10n.T("继续口述"), () => Finish("supplement")),
            Theme.Secondary(L10n.T("保留原文"), () => Finish("original")),
            Theme.Secondary(L10n.T("取消"), () => Finish("cancel")));
        var content = Theme.Stack(12, Theme.Text(L10n.T(kind == "explanation" ? "开始词与结束词须成对出现。可继续口述补全，或编辑本次内容。" : "名称有歧义，请补充全称、用途或拼写。确认前不会粘贴。"), 14),
            Theme.Text(question, 13), editor, row);
        content.Margin = new Thickness(20);
        window.Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var registration = ct.Register(() => window.Dispatcher.InvokeAsync(() => window.Close()));
        window.Closed += (_, _) => { registration.Dispose();
            // Button actions set the result below, after Close returns.
            window.Dispatcher.InvokeAsync(() => completion.TrySetResult(new("cancel", ""))); };
        window.Show();
        if (ct.IsCancellationRequested) window.Close();
        return completion.Task;
    }
}
