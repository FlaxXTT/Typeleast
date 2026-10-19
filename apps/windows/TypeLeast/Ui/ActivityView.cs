using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>The home heatmap (活动): a square per day, a column per week, darker for busier days.</summary>
internal static class ActivityView
{
    private const double Cell = 11;
    private const double Gap = 3;
    private const int Weeks = 26;
    private static readonly double[] Opacity = { 0, 0.3, 0.5, 0.75, 1 };

    public static UIElement Build(ActivityLog log, DateTime today)
    {
        var (current, longest) = log.Streaks(today);
        var header = Theme.Row(16,
            Theme.Text(L10n.T("活动"), 14, bold: true, wrap: false),
            Theme.Text(L10n.T("活跃天数") + " " + log.ActiveDays + " " + L10n.T("天"), 12, Theme.Grey, wrap: false),
            Theme.Text(L10n.T("当前连续") + " " + current + " " + L10n.T("天"), 12, Theme.Grey, wrap: false),
            Theme.Text(L10n.T("最长连续") + " " + longest + " " + L10n.T("天"), 12, Theme.Grey, wrap: false));

        var canvas = new Canvas { Width = Weeks * (Cell + Gap), Height = 7 * (Cell + Gap), HorizontalAlignment = HorizontalAlignment.Left };
        // Columns start on Monday; the last column is the current week.
        var monday = today.Date.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        var first = monday.AddDays(-7 * (Weeks - 1));
        for (var column = 0; column < Weeks; column++)
        {
            for (var row = 0; row < 7; row++)
            {
                var date = first.AddDays(column * 7 + row);
                if (date > today.Date) continue;
                var day = log.Day(date);
                var square = Square(ActivityLog.Level(day.Dictations));
                square.ToolTip = date.ToString("M", L10n.Culture) + " · " + (day.Dictations == 0
                    ? L10n.T("没有活动")
                    : L10n.T("{0} 次 · {1} 字", day.Dictations, day.Words));
                Canvas.SetLeft(square, column * (Cell + Gap));
                Canvas.SetTop(square, row * (Cell + Gap));
                canvas.Children.Add(square);
            }
        }

        var legend = Theme.Row(4, Theme.Text(L10n.T("更少"), 11, Theme.Tertiary, wrap: false));
        for (var level = 0; level < 5; level++) legend.Children.Add(Square(level));
        legend.Children.Add(Theme.Text(L10n.T("更多"), 11, Theme.Tertiary, wrap: false));
        return Theme.Stack(10, header, canvas, legend);
    }

    private static Rectangle Square(int level) => new()
    {
        Width = Cell,
        Height = Cell,
        RadiusX = 2.5,
        RadiusY = 2.5,
        Fill = level == 0 ? Theme.Line : new SolidColorBrush(((SolidColorBrush)Theme.Accent).Color) { Opacity = Opacity[Math.Min(4, level)] },
    };
}
