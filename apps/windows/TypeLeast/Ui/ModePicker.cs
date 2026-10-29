using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>The independent assistant action. No cleanup tiers.</summary>
internal static class ModePicker
{
    public static StackPanel Sidebar(AppHost host)
    {
        var list = new StackPanel { Margin = new Thickness(10, 0, 10, 0) };
        list.Children.Add(Theme.Secondary(L10n.T("需求助手"), () => host.ToggleAssistant()));
        void Update() => list.ToolTip = host.Phase == DictationPhase.Idle ? null : L10n.T("说完再切换");
        host.Changed += Update; Update();
        return list;
    }
}
