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
    /// <summary>Inter for Latin text and Noto Sans SC for Chinese (both SIL OFL, embedded); characters
    /// outside the Chinese subset fall back to the system's Microsoft YaHei UI.</summary>
    public static readonly FontFamily Font = new(new Uri("pack://application:,,,/TypeLeast;component/"),
        "./Fonts/#Inter, ./Fonts/#Noto Sans SC, Microsoft YaHei UI, Segoe UI");
    /// <summary>Titles from 20 px up: Inter Display, drawn tighter for large sizes (as iOS switches to its Display face).</summary>
    public static readonly FontFamily DisplayFont = new(new Uri("pack://application:,,,/TypeLeast;component/"),
        "./Fonts/#Inter Display, ./Fonts/#Noto Sans SC, Microsoft YaHei UI, Segoe UI");
    private const double DisplaySize = 20;

    static Theme()
    {
        // Every window, tooltip and menu starts from the app font; their contents inherit it.
        foreach (var type in new[] { typeof(Window), typeof(ToolTip), typeof(ContextMenu) })
            Control.FontFamilyProperty.OverrideMetadata(type, new FrameworkPropertyMetadata(Font, FrameworkPropertyMetadataOptions.Inherits));
    }
    private sealed class PaletteColor : System.ComponentModel.INotifyPropertyChanged
    {
        private Color value;
        public Color Value { get => value; set { this.value = value; PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(nameof(Value))); } }
        public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    }
    private static readonly System.Collections.Generic.Dictionary<SolidColorBrush, PaletteColor> Colors = new();
    private static SolidColorBrush Token(string value)
    {
        var color = new PaletteColor { Value = (Color)ColorConverter.ConvertFromString(value) };
        var brush = new SolidColorBrush();
        System.Windows.Data.BindingOperations.SetBinding(brush, SolidColorBrush.ColorProperty, new System.Windows.Data.Binding(nameof(PaletteColor.Value)) { Source = color });
        Colors.Add(brush, color); return brush;
    }
    public static readonly SolidColorBrush Background = Token("#FFFFFF"), Sidebar = Token("#F6F6F5"), CardFill = Token("#F4F4F3"),
        Line = Token("#E7E7E5"), Ink = Token("#141313"), InkInverse = Token("#FFFFFF"), Grey = Token("#6E6D6B"),
        Tertiary = Token("#A3A29F"), Accent = Token("#3E9BE9"), Success = Token("#2E9E5B"), Warning = Token("#D9822B"),
        Selected = Token("#E9E9E7"), Pill = Token("#E61C1B1B");
    /// <summary>True while the dark palette is applied (read by the WinForms tray menu).</summary>
    public static bool IsDark { get; private set; }

    public static void Apply(string appearance)
    {
        var dark = appearance == "dark";
        if (appearance == "system")
        {
            try { dark = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int value && value == 0; } catch (System.Exception) { }
        }
        var tokens = new[] { Background, Sidebar, CardFill, Line, Ink, InkInverse, Grey, Tertiary, Accent, Success, Warning, Selected };
        var values = dark ? new[] { "#1C1B1B", "#151414", "#262525", "#333232", "#F4F3F3", "#141313", "#9C9B99", "#6E6D6B", "#62BBF3", "#4CC27A", "#F0A04B", "#2F2E2E" }
            : new[] { "#FFFFFF", "#F6F6F5", "#F4F4F3", "#E7E7E5", "#141313", "#FFFFFF", "#6E6D6B", "#A3A29F", "#3E9BE9", "#2E9E5B", "#D9822B", "#E9E9E7" };
        IsDark = dark;
        for (var i = 0; i < tokens.Length; i++) Colors[tokens[i]].Value = (Color)ColorConverter.ConvertFromString(values[i]);
        if (Application.Current is { } app)
        {
            app.Resources["TL.Ink"] = Ink; app.Resources["TL.Card"] = CardFill; app.Resources["TL.Line"] = Line;
            app.Resources["TL.Success"] = Success; app.Resources["TL.Tertiary"] = Tertiary; app.Resources["TL.Grey"] = Grey;
            if (app.Resources[typeof(System.Windows.Controls.Primitives.ScrollBar)] is null && ScrollBarStyle() is { } bar)
                app.Resources[typeof(System.Windows.Controls.Primitives.ScrollBar)] = bar;
            foreach (var type in new[] { typeof(TextBox), typeof(PasswordBox), typeof(ComboBox), typeof(ComboBoxItem), typeof(CheckBox) })
            {
                var style = new Style(type);
                style.Setters.Add(new Setter(Control.ForegroundProperty, new DynamicResourceExtension("TL.Ink"))); style.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension("TL.Card")));
                style.Setters.Add(new Setter(Control.BorderBrushProperty, new DynamicResourceExtension("TL.Line")));
                if (type == typeof(ComboBox)) style.Setters.Add(new Setter(Control.TemplateProperty, ComboTemplate()));
                app.Resources[type] = style;
            }
            app.Resources[SystemColors.WindowBrushKey] = CardFill; app.Resources[SystemColors.WindowTextBrushKey] = Ink;
            app.Resources[SystemColors.ControlBrushKey] = CardFill; app.Resources[SystemColors.ControlTextBrushKey] = Ink;
            app.Resources[SystemColors.HighlightBrushKey] = Selected; app.Resources[SystemColors.HighlightTextBrushKey] = Ink;
        }
    }

    public static SolidColorBrush Hex(string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return brush;
    }

    /// <summary>A thin rounded scrollbar in the palette: no arrow buttons, transparent track, darker while dragged.
    /// Null (the system scrollbar stays) if the markup cannot be loaded.</summary>
    internal static Style? ScrollBarStyle()
    {
        const string xaml = """
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ScrollBar">
  <Style.Resources>
    <Style x:Key="TL.Page" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <ControlTemplate x:Key="TL.Thumb" TargetType="Thumb">
      <Border x:Name="Bar" CornerRadius="3" Margin="2" Background="{DynamicResource TL.Tertiary}" Opacity="0.75"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bar" Property="Opacity" Value="1"/></Trigger>
        <Trigger Property="IsDragging" Value="True"><Setter TargetName="Bar" Property="Background" Value="{DynamicResource TL.Grey}"/><Setter TargetName="Bar" Property="Opacity" Value="1"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Style.Resources>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Width" Value="10"/>
  <Setter Property="MinWidth" Value="10"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Grid Background="Transparent" SnapsToDevicePixels="True">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource TL.Page}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource TL.Page}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
            <Track.Thumb><Thumb Template="{StaticResource TL.Thumb}"/></Track.Thumb>
          </Track>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property="Orientation" Value="Horizontal">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Height" Value="10"/>
      <Setter Property="MinHeight" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" SnapsToDevicePixels="True">
              <Track x:Name="PART_Track" IsDirectionReversed="False">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource TL.Page}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource TL.Page}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Template="{StaticResource TL.Thumb}"/></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Trigger>
  </Style.Triggers>
</Style>
""";
        try { return (Style)System.Windows.Markup.XamlReader.Parse(xaml); }
        catch (System.Exception) { Log.Write("theme.scrollbar.fail"); return null; }
    }

    private static ControlTemplate ComboTemplate()
    {
        var template = new ControlTemplate(typeof(ComboBox));
        var grid = new FrameworkElementFactory(typeof(Grid));
        var toggle = new FrameworkElementFactory(typeof(System.Windows.Controls.Primitives.ToggleButton));
        toggle.SetValue(UIElement.FocusableProperty, false);
        toggle.SetBinding(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty,
            new System.Windows.Data.Binding("IsDropDownOpen") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent, Mode = System.Windows.Data.BindingMode.TwoWay });
        toggle.SetBinding(Control.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        toggle.SetBinding(Control.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var buttonTemplate = new ControlTemplate(typeof(System.Windows.Controls.Primitives.ToggleButton));
        var border = new FrameworkElementFactory(typeof(Border)); border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.BorderThicknessProperty, new Thickness(1)); border.SetValue(Border.PaddingProperty, new Thickness(8, 5, 8, 5));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var dock = new FrameworkElementFactory(typeof(DockPanel));
        var arrow = new FrameworkElementFactory(typeof(TextBlock)); arrow.SetValue(TextBlock.TextProperty, "⌄"); arrow.SetValue(DockPanel.DockProperty, Dock.Right); arrow.SetValue(FrameworkElement.MarginProperty, new Thickness(8, 0, 0, 0));
        dock.AppendChild(arrow);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter)); presenter.SetBinding(ContentPresenter.ContentProperty,
            new System.Windows.Data.Binding("SelectionBoxItem") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(ComboBox), 1) });
        dock.AppendChild(presenter); border.AppendChild(dock); buttonTemplate.VisualTree = border; toggle.SetValue(Control.TemplateProperty, buttonTemplate);
        grid.AppendChild(toggle);
        var popup = new FrameworkElementFactory(typeof(System.Windows.Controls.Primitives.Popup)); popup.Name = "PART_Popup";
        popup.SetValue(System.Windows.Controls.Primitives.Popup.PlacementProperty, System.Windows.Controls.Primitives.PlacementMode.Bottom);
        popup.SetValue(System.Windows.Controls.Primitives.Popup.AllowsTransparencyProperty, true);
        popup.SetBinding(System.Windows.Controls.Primitives.Popup.IsOpenProperty, new System.Windows.Data.Binding("IsDropDownOpen") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var popupBorder = new FrameworkElementFactory(typeof(Border)); popupBorder.SetResourceReference(Border.BackgroundProperty, "TL.Card"); popupBorder.SetResourceReference(Border.BorderBrushProperty, "TL.Line");
        popupBorder.SetValue(Border.BorderThicknessProperty, new Thickness(1)); popupBorder.SetValue(FrameworkElement.MaxHeightProperty, 320.0);
        popupBorder.SetBinding(FrameworkElement.MinWidthProperty, new System.Windows.Data.Binding("ActualWidth") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var scroll = new FrameworkElementFactory(typeof(ScrollViewer)); scroll.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto);
        scroll.AppendChild(new FrameworkElementFactory(typeof(ItemsPresenter))); popupBorder.AppendChild(scroll); popup.AppendChild(popupBorder); grid.AppendChild(popup);
        template.VisualTree = grid; return template;
    }

    public static TextBlock Text(string text, double size = 13, Brush? color = null, bool bold = false, bool wrap = true)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = size >= DisplaySize ? DisplayFont : Font,
            FontSize = size,
            Foreground = color ?? Ink,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        // Large text is mostly titles and statistics: equal-width digits keep numbers from shifting.
        if (size >= DisplaySize) System.Windows.Documents.Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
        return block;
    }

    public static System.Windows.Controls.Border Card(UIElement child, double padding = 18)
    {
        return new System.Windows.Controls.Border
        {
            Background = CardFill,
            BorderBrush = Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
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

    public static WrapPanel Row(double spacing, params UIElement[] children)
    {
        var panel = new WrapPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < children.Length; i++)
        {
            if (children[i] is FrameworkElement fe && i > 0) fe.Margin = new Thickness(spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom);
            panel.Children.Add(children[i]);
        }
        return panel;
    }

    public static Button Primary(string text, Action onClick) => MakeButton(text, Ink, InkInverse, Ink, onClick);
    public static Button Secondary(string text, Action onClick) => MakeButton(text, CardFill, Ink, Line, onClick);

    private static Button MakeButton(string text, Brush background, Brush foreground, Brush border, Action onClick)
    {
        var template = new ControlTemplate(typeof(Button));
        var chrome = new FrameworkElementFactory(typeof(System.Windows.Controls.Border));
        chrome.SetValue(System.Windows.Controls.Border.CornerRadiusProperty, new CornerRadius(20));
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
            BorderBrush = Line, Background = CardFill, Foreground = Ink,
            VerticalContentAlignment = VerticalAlignment.Center,
            ToolTip = tooltip,
        };
    }

    public static ComboBox Choice(double width)
    {
        return new ComboBox { Background = CardFill, Foreground = Ink, BorderBrush = Line, Width = width, FontFamily = Font, FontSize = 13, Padding = new Thickness(6, 4, 6, 4) };
    }

    /// <summary>A settings line: title and detail on the left, controls on the right.</summary>
    public static Grid SettingRow(string title, TextBlock? detail, UIElement? trailing)
    {
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
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
            System.Windows.Automation.AutomationProperties.SetName(trailing, title);
            grid.SizeChanged += (_, _) => {
                // Control on the right, as on the Mac, while the title and note keep at least 260 px;
                // below that (a narrow window, a wide control) the control goes under the text.
                var stack = grid.ActualWidth - trailing.DesiredSize.Width - 16 < 260;
                if (trailing is FrameworkElement bound) bound.MaxWidth = System.Math.Max(120, grid.ActualWidth);
                Grid.SetColumn(trailing, stack ? 0 : 1);
                Grid.SetRow(trailing, stack ? 1 : 0);
                grid.ColumnDefinitions[1].Width = stack ? new GridLength(0) : GridLength.Auto;
                if (trailing is FrameworkElement element) {
                    element.HorizontalAlignment = stack ? HorizontalAlignment.Left : HorizontalAlignment.Right;
                    element.VerticalAlignment = stack ? VerticalAlignment.Top : VerticalAlignment.Center;
                    element.Margin = stack ? new Thickness(0, 6, 0, 0) : new Thickness(0);
                }
            };
        }
        return grid;
    }

    public static CheckBox Toggle(bool enabled, System.Action<bool> changed)
    {
        var toggle = new CheckBox { IsChecked = enabled, Width = 42, Height = 24, VerticalAlignment = VerticalAlignment.Center };
        var template = new ControlTemplate(typeof(CheckBox));
        var track = new FrameworkElementFactory(typeof(Border)); track.Name = "Track";
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(12)); track.SetResourceReference(Border.BackgroundProperty, "TL.Tertiary");
        var knob = new FrameworkElementFactory(typeof(Border)); knob.Name = "Knob";
        knob.SetValue(Border.CornerRadiusProperty, new CornerRadius(10)); knob.SetValue(Border.BackgroundProperty, Brushes.White);
        knob.SetValue(FrameworkElement.WidthProperty, 18.0); knob.SetValue(FrameworkElement.HeightProperty, 18.0);
        knob.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left); knob.SetValue(FrameworkElement.MarginProperty, new Thickness(3));
        track.AppendChild(knob); template.VisualTree = track;
        var on = new Trigger { Property = System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, new DynamicResourceExtension("TL.Success"), "Track"));
        on.Setters.Add(new Setter(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Right, "Knob")); template.Triggers.Add(on);
        toggle.Template = template; toggle.Click += (_, _) => changed(toggle.IsChecked == true); return toggle;
    }
    public static UIElement Keycaps(string label)
    {
        var row = new WrapPanel();
        foreach (var key in label.Split('+')) row.Children.Add(new Border { Background = Background, BorderBrush = Line, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(5), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0, 0, 4, 0), Child = Text(key.Trim(), 12, bold: true) });
        return row;
    }

    public static TextBlock SectionTitle(string text) =>
        new() { Text = text, FontFamily = Font, FontSize = 12, Foreground = Grey, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 6, 0, 8) };

    /// <summary>A check mark (done) or an empty circle.</summary>
    public static TextBlock Check(bool done) =>
        new() { Text = done ? "✔" : "○", FontSize = 15, Foreground = done ? Success : Tertiary, Width = 22, VerticalAlignment = VerticalAlignment.Center };
}
