using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace TypeLeast.Ui;

/// <summary>
/// The Typeless-like look, built in code: warm light background, white cards with
/// soft borders, black primary buttons, quiet grey secondary text.
/// </summary>
internal static class Theme
{
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI");
    public static readonly Brush Background = Hex("#F7F7F5");
    public static readonly Brush Sidebar = Hex("#EFEEEA");
    public static readonly Brush CardFill = Hex("#FFFFFF");
    public static readonly Brush Line = Hex("#E6E4DF");
    public static readonly Brush Ink = Hex("#1A1A1A");
    public static readonly Brush Secondary = Hex("#6B6B6B");
    public static readonly Brush Tertiary = Hex("#A3A3A3");
    public static readonly Brush Accent = Hex("#5B5BD6");
    public static readonly Brush Success = Hex("#2E9D5B");
    public static readonly Brush Warning = Hex("#C27A12");
    public static readonly Brush Selected = Hex("#E4E2DC");
    public static readonly Brush Pill = Hex("#1C1C1E");

    public static SolidColorBrush Hex(string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return brush;
    }

    public static TextBlock Text(string text, double size = 13, Brush? color = null, bool bold = false, bool wrap = true)
    {
        return new TextBlock
        {
            Text = text,
            FontFamily = Font,
            FontSize = size,
            Foreground = color ?? Ink,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
    }

    public static System.Windows.Controls.Border Card(UIElement child, double padding = 18)
    {
        return new System.Windows.Controls.Border
        {
            Background = CardFill,
            BorderBrush = Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(padding),
            Child = child,
            Margin = new Thickness(0, 0, 0, 14),
        };
    }

    public static StackPanel Stack(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel();
        for (var i = 0; i < children.Length; i++)
        {
            if (children[i] is FrameworkElement fe && i > 0) fe.Margin = new Thickness(fe.Margin.Left, spacing, fe.Margin.Right, fe.Margin.Bottom);
            panel.Children.Add(children[i]);
        }
        return panel;
    }

    public static StackPanel Row(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < children.Length; i++)
        {
            if (children[i] is FrameworkElement fe && i > 0) fe.Margin = new Thickness(spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
            panel.Children.Add(children[i]);
        }
        return panel;
    }

    public static Button Primary(string text, Action onClick) => MakeButton(text, Ink, Hex("#FFFFFF"), Ink, onClick);
    public static Button Secondary(string text, Action onClick) => MakeButton(text, CardFill, Ink, Line, onClick);

    private static Button MakeButton(string text, Brush background, Brush foreground, Brush border, Action onClick)
    {
        var template = new ControlTemplate(typeof(Button));
        var chrome = new FrameworkElementFactory(typeof(System.Windows.Controls.Border));
        chrome.SetValue(System.Windows.Controls.Border.CornerRadiusProperty, new CornerRadius(8));
        chrome.SetBinding(System.Windows.Controls.Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        chrome.SetBinding(System.Windows.Controls.Border.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        chrome.SetValue(System.Windows.Controls.Border.BorderThicknessProperty, new Thickness(1));
        chrome.SetValue(System.Windows.Controls.Border.PaddingProperty, new Thickness(14, 6, 14, 6));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetBinding(ContentPresenter.HorizontalAlignmentProperty, new System.Windows.Data.Binding("HorizontalContentAlignment") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        chrome.AppendChild(content);
        template.VisualTree = chrome;

        var button = new Button
        {
            Content = text,
            Template = template,
            Background = background,
            Foreground = foreground,
            BorderBrush = border,
            FontFamily = Font,
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        button.Click += (_, _) => onClick();
        button.MouseEnter += (_, _) => button.Opacity = 0.82;
        button.MouseLeave += (_, _) => button.Opacity = button.IsEnabled ? 1 : 0.45;
        button.IsEnabledChanged += (_, _) => button.Opacity = button.IsEnabled ? 1 : 0.45;
        return button;
    }

    public static TextBox Input(string text, double width, string? tooltip = null)
    {
        return new TextBox
        {
            Text = text,
            Width = width,
            FontFamily = Font,
            FontSize = 13,
            Padding = new Thickness(6, 4, 6, 4),
            BorderBrush = Line,
            VerticalContentAlignment = VerticalAlignment.Center,
            ToolTip = tooltip,
        };
    }

    public static ComboBox Choice(double width)
    {
        return new ComboBox { Width = width, FontFamily = Font, FontSize = 13, Padding = new Thickness(6, 4, 6, 4) };
    }

    /// <summary>A settings line: title and detail on the left, controls on the right.</summary>
    public static Grid SettingRow(string title, TextBlock? detail, UIElement? trailing)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        left.Children.Add(Text(title, 13.5, bold: true));
        if (detail is not null)
        {
            detail.Margin = new Thickness(0, 2, 0, 0);
            left.Children.Add(detail);
        }
        grid.Children.Add(left);
        if (trailing is not null)
        {
            Grid.SetColumn(trailing, 1);
            grid.Children.Add(trailing);
        }
        return grid;
    }

    public static TextBlock SectionTitle(string text) =>
        new() { Text = text, FontFamily = Font, FontSize = 12, Foreground = Secondary, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 6, 0, 8) };

    /// <summary>A check mark (done) or an empty circle.</summary>
    public static TextBlock Check(bool done) =>
        new() { Text = done ? "✔" : "○", FontSize = 15, Foreground = done ? Success : Tertiary, Width = 22, VerticalAlignment = VerticalAlignment.Center };
}
