using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// The Home insights: four figures (字数, 节省时间, 速度, 口述时间), then active days and streaks above a
/// heatmap (a square per day, a column per week), on a lightly dotted panel with 分享 for the website
/// and GitHub links.
/// </summary>
internal static class ActivityView
{
    private const double Cell = 18;
    private const double Gap = 6;
    private const double DayColumn = 22;
    public const string Site = "https://typeleast.promptking.workers.dev";
    public const string GitHub = "https://github.com/FlaxXTT/Typeleast";

    private static Brush Tile => Theme.IsDark ? Theme.Hex("#262525") : Brushes.White;
    private static Brush Empty => Theme.IsDark ? Theme.Hex("#2C2B2B") : Theme.Hex("#F1F1EF");
    private static Brush Heat(int level) => Theme.Hex((Theme.IsDark
        ? new[] { "#26304F", "#34458A", "#4A63C9", "#6E8BF5" } : new[] { "#E6EBFD", "#C3CEF9", "#9BAEF3", "#4468EC" })[Math.Clamp(level - 1, 0, 3)]);

    public static UIElement Insights(ActivityLog log, (int Count, int Characters, double Seconds) stats, DateTime today)
    {
        var (_, chars, seconds) = stats;
        var saved = Math.Max(0, chars / 60.0 * 60 - seconds);
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
        grid.Children.Add(Figure(Count(chars), L10n.T("口述字数")));
        grid.Children.Add(Figure(Duration(saved), L10n.T("节省时间")));
        grid.Children.Add(Figure(new[] { ((seconds > 1 ? chars * 60 / seconds : 0).ToString("F0", CultureInfo.InvariantCulture), L10n.T("每分钟字数")) }, L10n.T("平均口述速度")));
        grid.Children.Add(Figure(Duration(seconds), L10n.T("总口述时间")));
        foreach (FrameworkElement tile in grid.Children) tile.Margin = new Thickness(0, 0, 14, 14);

        var share = Theme.Secondary("⇪ " + L10n.T("分享"), () => { });
        share.HorizontalAlignment = HorizontalAlignment.Right;
        share.ToolTip = L10n.T("分享官网和 GitHub 链接");
        var menu = new ContextMenu();
        void Add(string title, Action run) { var item = new MenuItem { Header = title }; item.Click += (_, _) => run(); menu.Items.Add(item); }
        Add(L10n.T("复制链接"), () => Paster.SetText("TypeLeast · " + Site + " · " + GitHub));
        Add(L10n.T("打开官网"), () => Shell.Open(Site));
        Add(L10n.T("打开 GitHub"), () => Shell.Open(GitHub));
        share.Click += (_, _) => { menu.PlacementTarget = share; menu.IsOpen = true; };

        var activity = Activity(log, today);
        activity.Margin = new Thickness(0, 0, 14, 0);
        var stack = Theme.Stack(0, share, grid, activity);
        share.Margin = new Thickness(0, 0, 14, 14);
        return new Border { CornerRadius = new CornerRadius(18), Padding = new Thickness(16, 16, 2, 16), Background = Dots(), Child = stack };
    }

    /// <summary>34.9K 字 / 3.5万 字: large counts are shortened.</summary>
    private static (string, string)[] Count(int value)
    {
        if (value < 10_000) return new[] { (value.ToString("N0", L10n.Culture), L10n.T("字")) };
        return L10n.Language == "en"
            ? new[] { ((value / 1000.0).ToString("F1", CultureInfo.InvariantCulture) + "K", L10n.T("字")) }
            : new[] { ((value / 10000.0).ToString("F1", CultureInfo.InvariantCulture), L10n.T("万") + L10n.T("字")) };
    }

    /// <summary>17 小时 47 分钟, 12 分钟, 40 秒.</summary>
    private static (string, string)[] Duration(double seconds)
    {
        var total = (int)Math.Round(seconds);
        if (total < 60) return new[] { (total.ToString(CultureInfo.InvariantCulture), L10n.T("秒")) };
        int hours = total / 3600, minutes = total % 3600 / 60;
        return hours == 0 ? new[] { (minutes.ToString(CultureInfo.InvariantCulture), L10n.T("分钟")) }
            : new[] { (hours.ToString(CultureInfo.InvariantCulture), L10n.T("小时")), (minutes.ToString(CultureInfo.InvariantCulture), L10n.T("分钟")) };
    }

    private static Border Figure((string Value, string Unit)[] parts, string label)
    {
        var line = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var (value, unit) in parts)
        {
            line.Children.Add(new TextBlock { Text = value, FontSize = 30, FontWeight = FontWeights.Bold, Foreground = Theme.Ink, FontFamily = Theme.Font, VerticalAlignment = VerticalAlignment.Bottom });
            line.Children.Add(new TextBlock { Text = unit, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Theme.Ink, FontFamily = Theme.Font, Margin = new Thickness(4, 0, 10, 6), VerticalAlignment = VerticalAlignment.Bottom });
        }
        return new Border { Background = Tile, CornerRadius = new CornerRadius(16), Padding = new Thickness(20, 18, 20, 18),
            Child = Theme.Stack(6, line, Theme.Text(label, 13, Theme.Grey)) };
    }

    /// <summary>A faint grid of dots behind the insights.</summary>
    private static Brush Dots()
    {
        var dot = new GeometryDrawing(Theme.IsDark ? Theme.Hex("#343333") : Theme.Hex("#DCDCD9"), null, new EllipseGeometry(new Point(6, 6), 0.9, 0.9));
        var background = new GeometryDrawing(Theme.IsDark ? Theme.Hex("#1F1E1E") : Theme.Hex("#F7F7F6"), null, new RectangleGeometry(new Rect(0, 0, 12, 12)));
        return new DrawingBrush(new DrawingGroup { Children = { background, dot } })
            { TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 12, 12), ViewportUnits = BrushMappingMode.Absolute, Stretch = Stretch.None };
    }

    private static Border Activity(ActivityLog log, DateTime today)
    {
        var (current, longest) = log.Streaks(today);
        var figures = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3 };
        foreach (var (value, label) in new[] { (log.ActiveDays, L10n.T("活跃天数")), (current, L10n.T("当前连续天数")), (longest, L10n.T("最长连续天数")) })
        {
            var line = Theme.Row(4, new TextBlock { Text = value.ToString(CultureInfo.InvariantCulture), FontSize = 30, FontWeight = FontWeights.Bold, Foreground = Theme.Ink, FontFamily = Theme.Font },
                new TextBlock { Text = L10n.T("天"), FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Theme.Ink, FontFamily = Theme.Font, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 6) });
            figures.Children.Add(Theme.Stack(6, line, Theme.Text(label, 13, Theme.Grey)));
        }
        var content = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var weeks = 0;
        content.SizeChanged += (_, _) =>
        {
            var count = Math.Clamp((int)((content.ActualWidth - DayColumn + Gap) / (Cell + Gap)), 8, 53);
            if (count == weeks) return; weeks = count; content.Content = Grid(log, today, count);
        };
        content.Content = Grid(log, today, 20);
        var legend = Theme.Row(6, Theme.Text(L10n.T("更少"), 12, Theme.Grey, wrap: false));
        for (var level = 1; level < 5; level++) legend.Children.Add(Square(level));
        legend.Children.Add(Theme.Text(L10n.T("更多"), 12, Theme.Grey, wrap: false));
        return new Border { Background = Tile, CornerRadius = new CornerRadius(16), Padding = new Thickness(20),
            Child = Theme.Stack(18, figures, content, legend) };
    }

    private static UIElement Grid(ActivityLog log, DateTime today, int weeks)
    {
        var step = Cell + Gap;
        var canvas = new Canvas { Width = DayColumn + weeks * step, Height = 7 * step + 18, HorizontalAlignment = HorizontalAlignment.Left };
        // Rows start on Monday; the last column is the current week.
        var monday = today.Date.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        var first = monday.AddDays(-7 * (weeks - 1));
        var names = L10n.Language == "en" ? new[] { "M", "T", "W", "T", "F", "S", "S" } : new[] { "一", "二", "三", "四", "五", "六", "日" };
        for (var row = 0; row < 7; row++)
        {
            var name = Theme.Text(names[row], 11, Theme.Grey, wrap: false);
            Canvas.SetLeft(name, 2); Canvas.SetTop(name, row * step + 1); canvas.Children.Add(name);
        }
        for (var column = 0; column < weeks; column++)
        {
            var weekStart = first.AddDays(column * 7);
            var x = DayColumn + column * step;
            for (var row = 0; row < 7; row++)
            {
                var date = weekStart.AddDays(row);
                FrameworkElement square;
                if (date > today.Date) square = new Rectangle { Width = Cell, Height = Cell, RadiusX = 5, RadiusY = 5, Stroke = Theme.Line, StrokeThickness = 1 };
                else
                {
                    var day = log.Day(date);
                    square = Square(ActivityLog.Level(day.Dictations));
                    square.ToolTip = date.ToString("M", L10n.Culture) + " · " + (day.Dictations == 0
                        ? L10n.T("没有活动") : L10n.T("{0} 次 · {1} 字", day.Dictations, day.Words));
                }
                Canvas.SetLeft(square, x); Canvas.SetTop(square, row * step); canvas.Children.Add(square);
            }
            if (Enumerable.Range(0, 7).Any(d => weekStart.AddDays(d).Day == 1))
            {
                var month = Theme.Text(weekStart.AddDays(6).ToString("MMM", L10n.Culture), 11, Theme.Grey, wrap: false);
                Canvas.SetLeft(month, x); Canvas.SetTop(month, 7 * step); canvas.Children.Add(month);
            }
        }
        return canvas;
    }

    private static Rectangle Square(int level) => new()
    {
        Width = Cell, Height = Cell, RadiusX = 5, RadiusY = 5,
        Fill = level == 0 ? Empty : Heat(level),
    };
}
