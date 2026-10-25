using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal static class PreviewPanel
{
    public static Task<string?> Show(string text, CancellationToken ct)
    {
        var completion = new TaskCompletionSource<string?>();
        var editor = new TextBox { Text = text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 160,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontSize = 14, Margin = new Thickness(0, 0, 0, 14) };
        var window = new Window { Title = L10n.T("预览"), Width = 540, Height = 360, MinWidth = 360, MinHeight = 280,
            Background = Theme.Background, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        var content = Theme.Stack(12, editor, Theme.Row(8,
            Theme.Primary(L10n.T("插入"), () => { completion.TrySetResult(editor.Text); window.Close(); }),
            Theme.Secondary(L10n.T("取消"), () => window.Close())));
        content.Margin = new Thickness(24); window.Content = content;
        var registration = ct.Register(() => window.Dispatcher.InvokeAsync(() => window.Close()));
        window.Closed += (_, _) => { registration.Dispose(); completion.TrySetResult(null); };
        window.Show(); editor.Focus();
        if (ct.IsCancellationRequested) window.Close();
        return completion.Task;
    }
}
