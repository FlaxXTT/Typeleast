using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// Settings: dictation, the cleanup model (the user's own API key, kept in the
/// Windows Credential Manager), the local service and speech model, and about.
/// Inputs are built once; Refresh() only updates status lines, so typing is never
/// interrupted by a periodic update.
/// </summary>
internal sealed class SettingsPage : IPage
{
    private readonly AppHost host;
    private readonly StackPanel root = new();
    private readonly TextBlock serviceStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock speechStatus = Theme.Text("", 12, Theme.Grey);
    private readonly ProgressBar progress = new() { Width = 160, Height = 6, Minimum = 0, Maximum = 1, Visibility = Visibility.Collapsed };
    private readonly Button downloadButton;
    private readonly ComboBox preset = Theme.Choice(220);
    private readonly TextBlock settingsSaveStatus = Theme.Text("", 12, Theme.Warning);
    private readonly TextBlock llmStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock keyStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBox baseUrl = Theme.Input("", 300);
    private readonly PasswordBox key = new() { Width = 220, Padding = new Thickness(8, 5, 8, 5), FontSize = 13 };
    private readonly TextBox model = Theme.Input("", 200);
    private readonly ComboBox modelList = Theme.Choice(160);
    private readonly TextBlock keyboardStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock microphoneStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock updateStatus = Theme.Text("", 12, Theme.Grey);
    private Button installUpdate = null!;
    private readonly TextBlock missing = Theme.Text("", 12, Theme.Warning);
    private bool busy;
    private bool refreshingLanguage;
    private readonly SpeechModelsPanel speechModels;
    private readonly ComboBox dictationLanguage = Theme.Choice(160);
    private readonly TextBox mirror = Theme.Input("", 220, L10n.T("例如 https://hf-mirror.com"));

    private readonly DockPanel surface = new();
    public UIElement View => surface;

    public SettingsPage(AppHost host)
    {
        this.host = host;
        speechModels = new SpeechModelsPanel(host);
        var s = host.Settings;
        root.Children.Add(Theme.Text(L10n.T("设置"), 28, bold: true));
        root.Children.Add(settingsSaveStatus);

        var uiLanguage = Theme.Choice(160);
        foreach (var (code, label) in new[] { ("system", L10n.T("跟随系统")), ("zh-Hans", "简体中文"), ("en", "English") })
            uiLanguage.Items.Add(new ComboBoxItem { Content = label, Tag = code });
        uiLanguage.SelectedIndex = Array.IndexOf(L10n.Choices, s.InterfaceLanguage);
        uiLanguage.SelectionChanged += (_, _) => {
            if (uiLanguage.SelectedItem is ComboBoxItem { Tag: string code }) { s.InterfaceLanguage = code; host.SaveSettings(); }
        };

        var codes = new[] { "auto", "zh", "en", "yue", "ja", "ko" };
        var labels = new[] { L10n.T("自动识别"), L10n.T("中文"), "English", L10n.T("粤语"), "日本語", "한국어" };
        for (var i = 0; i < codes.Length; i++) dictationLanguage.Items.Add(new ComboBoxItem { Content = labels[i], Tag = codes[i] });
        dictationLanguage.SelectedIndex = Array.IndexOf(codes, s.Language);
        dictationLanguage.SelectionChanged += (_, _) => {
            if (!refreshingLanguage && host.Speech?.CanSetLanguage != false && dictationLanguage.SelectedItem is ComboBoxItem { Tag: string code }) { s.Language = code; host.SaveSettings(); }
        };
        var translateTarget = Theme.Choice(160);
        var targetLabels = new[] { "English", L10n.T("中文"), "日本語", "한국어", "Français", "Deutsch", "Español", "Português", "Italiano", "Русский" };
        for (var i = 0; i < AppSettings.TranslateTargets.Length; i++)
            translateTarget.Items.Add(new ComboBoxItem { Content = targetLabels[i], Tag = AppSettings.TranslateTargets[i] });
        translateTarget.SelectedIndex = Array.IndexOf(AppSettings.TranslateTargets, s.TranslateTarget);
        translateTarget.SelectionChanged += (_, _) => { if (translateTarget.SelectedItem is ComboBoxItem { Tag: string v }) { s.TranslateTarget = v; host.SaveSettings(); } };

        var zhVariant = Theme.Choice(160);
        foreach (var (code, label) in new[] { ("hans", L10n.T("简体")), ("tw", L10n.T("繁体（台湾）")), ("hk", L10n.T("繁体（香港）")) })
            zhVariant.Items.Add(new ComboBoxItem { Content = label, Tag = code });
        zhVariant.SelectedIndex = Array.IndexOf(AppSettings.ZhVariants, s.ZhVariant);
        zhVariant.SelectionChanged += (_, _) => { if (zhVariant.SelectedItem is ComboBoxItem { Tag: string v }) { s.ZhVariant = v; host.SaveSettings(); } };

        var languageRows = new UIElement[]
        {
            Theme.SettingRow(L10n.T("听写语言"), null, dictationLanguage),
            Theme.SettingRow(L10n.T("翻译成"), null, translateTarget),
            Theme.SettingRow(L10n.T("中文字形"), null, zhVariant),
        };

        // ---- dictation
        var hotkey = Theme.Choice(160);
        foreach (DictationKey k in Enum.GetValues(typeof(DictationKey))) hotkey.Items.Add(new ComboBoxItem { Content = TapDetector.Label(k), Tag = k });
        hotkey.SelectedIndex = (int)s.Hotkey;
        // 翻译 has its own key, never the dictation key.
        var translateKey = Theme.Choice(160);
        translateKey.Items.Add(new ComboBoxItem { Content = L10n.T("关"), Tag = null });
        foreach (DictationKey k in Enum.GetValues(typeof(DictationKey))) translateKey.Items.Add(new ComboBoxItem { Content = TapDetector.Label(k), Tag = k });
        void SyncTranslateKey()
        {
            foreach (ComboBoxItem item in translateKey.Items) item.IsEnabled = item.Tag is not DictationKey k || k != s.Hotkey;
            translateKey.SelectedIndex = s.TranslateHotkey is { } t ? (int)t + 1 : 0;
        }
        SyncTranslateKey();
        translateKey.SelectionChanged += (_, _) =>
        {
            if (translateKey.SelectedItem is not ComboBoxItem item) return;
            var chosen = item.Tag as DictationKey?;
            if (chosen == s.TranslateHotkey) return;
            s.TranslateHotkey = chosen;
            host.SaveSettings();
        };
        hotkey.SelectionChanged += (_, _) =>
        {
            if (hotkey.SelectedItem is not ComboBoxItem { Tag: DictationKey k }) return;
            s.Hotkey = k;
            if (s.TranslateHotkey == k) s.TranslateHotkey = null;
            host.SaveSettings();
            SyncTranslateKey();
        };

        var assistantKey = Theme.Choice(160);
        assistantKey.Items.Add(new ComboBoxItem { Content = L10n.T("关"), Tag = null });
        foreach (DictationKey k in Enum.GetValues(typeof(DictationKey))) assistantKey.Items.Add(new ComboBoxItem { Content = TapDetector.Label(k), Tag = k });
        void SyncAssistantKey() {
            foreach (ComboBoxItem item in assistantKey.Items) item.IsEnabled = item.Tag is not DictationKey k || (k != s.Hotkey && k != s.TranslateHotkey);
            assistantKey.SelectedIndex = s.AssistantHotkey is { } key ? (int)key + 1 : 0;
        }
        SyncAssistantKey();
        assistantKey.SelectionChanged += (_, _) => {
            if (assistantKey.SelectedItem is not ComboBoxItem item) return;
            if (item.Tag is DictationKey key && (key == s.Hotkey || key == s.TranslateHotkey)) { SyncAssistantKey(); return; }
            s.AssistantHotkey = item.Tag as DictationKey?; host.SaveSettings();
        };
        hotkey.SelectionChanged += (_, _) => { if (s.AssistantHotkey == s.Hotkey) s.AssistantHotkey = null; SyncAssistantKey(); };
        translateKey.SelectionChanged += (_, _) => { if (s.AssistantHotkey == s.TranslateHotkey) s.AssistantHotkey = null; SyncAssistantKey(); };

        var mic = Theme.Choice(220);
        mic.Items.Add(new ComboBoxItem { Content = L10n.T("系统默认麦克风"), Tag = -1 });
        var devices = Array.Empty<string>();
        try { devices = AudioRecorder.Devices().ToArray(); } catch (Exception) { }
        for (var i = 0; i < devices.Length; i++) mic.Items.Add(new ComboBoxItem { Content = devices[i], Tag = i });
        mic.SelectedIndex = s.MicrophoneDevice >= 0 && s.MicrophoneDevice < devices.Length ? s.MicrophoneDevice + 1 : 0;
        mic.SelectionChanged += (_, _) => { if (mic.SelectedItem is ComboBoxItem { Tag: int v }) { s.MicrophoneDevice = v; host.SaveSettings(); } };

        var login = Theme.Toggle(s.LaunchAtLogin, value => { s.LaunchAtLogin = value; if (host.SaveSettings()) Autostart.Apply(value); });
        var pasteKey = Theme.Choice(180);
        foreach (var code in new[] { "CtrlShiftAltV", "CtrlShiftV", "CtrlAltV", "off" })
            pasteKey.Items.Add(new ComboBoxItem { Content = code switch { "off" => L10n.T("关"), "CtrlShiftAltV" => "Ctrl + Shift + Alt + V", "CtrlShiftV" => "Ctrl + Shift + V", _ => "Ctrl + Alt + V" }, Tag = code });
        pasteKey.SelectedIndex = s.PasteLastShortcut switch { "CtrlShiftV" => 1, "CtrlAltV" => 2, "off" => 3, _ => 0 };
        pasteKey.SelectionChanged += (_, _) => { if (pasteKey.SelectedItem is ComboBoxItem { Tag: string code }) { s.PasteLastShortcut = code; s.PasteShortcutDefaults = 1; host.SaveSettings(); } };
        // ---- cleanup model
        foreach (var p in LlmPreset.All) preset.Items.Add(new ComboBoxItem { Content = p.Name, Tag = p.Id });
        preset.SelectedIndex = Math.Max(0, LlmPreset.All.ToList().FindIndex(p => p.Id == s.LlmPresetId));
        preset.SelectionChanged += (_, _) =>
        {
            if (preset.SelectedItem is ComboBoxItem { Tag: string id })
            {
                s.LlmPresetId = id;
                host.SaveSettings();
                LoadPreset();
            }
        };
        baseUrl.LostFocus += (_, _) => { s.LlmBaseUrl = baseUrl.Text; host.SaveSettings(); UpdateMissing(); };
        model.LostFocus += (_, _) => { s.LlmModel = model.Text; host.SaveSettings(); UpdateMissing(); };
        modelList.SelectionChanged += (_, _) =>
        {
            if (modelList.SelectedItem is string id) { model.Text = id; s.LlmModel = id; host.SaveSettings(); UpdateMissing(); }
        };
        var saveKey = Theme.Secondary(L10n.T("保存"), () => SaveKey(quiet: false));
        var fetch = Theme.Secondary(L10n.T("获取列表"), () => _ = FetchModels());
        var test = Theme.Primary(L10n.T("测试连接"), () => _ = Test());

        var modelSection = Section(L10n.T("整理模型"),
            Theme.SettingRow(L10n.T("服务商"), null, preset),
            Theme.SettingRow(L10n.T("接口地址"), Theme.Text(L10n.T("需要 https（本机可用 http://127.0.0.1）"), 12, Theme.Grey), baseUrl),
            Theme.SettingRow("API Key", keyStatus, Theme.Row(8, key, saveKey)),
            Theme.SettingRow(L10n.T("模型"), Theme.Text(L10n.T("填模型 ID，或点「获取列表」"), 12, Theme.Grey), Theme.Row(8, model, modelList, fetch)),
            Theme.Row(10, test, llmStatus),
            missing);

        var appearance = Theme.Choice(180); var appearances = new[] { "system", "light", "dark" };
        foreach (var label in new[] { "跟随系统", "浅色", "深色" }) appearance.Items.Add(L10n.T(label));
        appearance.SelectedIndex = Array.IndexOf(appearances, s.Appearance);
        appearance.SelectionChanged += (_, _) => { if (appearance.SelectedIndex >= 0) { s.Appearance = appearances[appearance.SelectedIndex]; host.SaveSettings(); } };

        downloadButton = Theme.Primary(L10n.T("选择语音模型"), () => _ = host.DownloadModels());
        mirror.Text = s.ModelMirror;
        mirror.LostFocus += (_, _) => { s.ModelMirror = mirror.Text.Trim(); host.SaveSettings(); };
        var useMirror = Theme.Secondary(L10n.T("使用 hf-mirror.com"), () => { mirror.Text = s.ModelMirror = ModelMirror.Suggested; host.SaveSettings(); });
        var chooseNode = Theme.Secondary(L10n.T("选择 Node.js…"), ChooseNode);
        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "?";
        installUpdate = Theme.Primary(L10n.T("立即更新"), () => _ = RunUpdate());
        RefreshUpdateButton();
        if (host.Updates.Available is { } pending) updateStatus.Text = L10n.T("有新版本 {0}。", pending.Version);

        // Five tabs, each a few cards that put related settings together.
        AddTab(L10n.T("听写"),
            Section(L10n.T("快捷键"),
                Theme.SettingRow(L10n.T("听写快捷键"), Theme.Text(L10n.T("按一下开始，再按一下结束。右 Alt 在部分键盘上是 AltGr，请换键。"), 12, Theme.Grey), hotkey),
                Theme.SettingRow(L10n.T("翻译快捷键"), Theme.Text(L10n.T("不能与听写键相同。"), 12, Theme.Grey), translateKey),
                Theme.SettingRow(L10n.T("需求助手"), Theme.Text(L10n.T("多轮补充需求，主动生成完整提示词。"), 12, Theme.Grey), assistantKey),
                Theme.SettingRow(L10n.T("粘贴上一条"), null, pasteKey),
                Theme.SettingRow(L10n.T("取消"), null, Theme.Keycaps("Esc"))),
            Section(L10n.T("语言"), languageRows),
            Section(L10n.T("麦克风与声音"),
                Theme.SettingRow(L10n.T("麦克风"), null, mic),
                Theme.SettingRow(L10n.T("麦克风测试"), null, Theme.Secondary(L10n.T("开始测试"), () => MicrophoneTestPanel.Show(host))),
                Theme.SettingRow(L10n.T("提示音"), null, Theme.Toggle(s.PlaySounds, v => { s.PlaySounds = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("听写时静音"), null, Theme.Toggle(s.MuteOtherAudio, v => { s.MuteOtherAudio = v; host.SaveSettings(); }))));
        AddTab(L10n.T("整理"),
            modelSection,
            Section(L10n.T("整理选项"),
                Theme.SettingRow(L10n.T("参考输入框内容"), null, Theme.Toggle(s.UseFieldContext, v => { s.UseFieldContext = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("自动加词"), Theme.Text(L10n.T("粘贴后你改过的词加入词典。"), 12, Theme.Grey), Theme.Toggle(s.LearnCorrections, v => { s.LearnCorrections = v; if (host.SaveSettings() && !v) host.Dictionary.StopWatching(); }))));
        AddTab(L10n.T("通用"),
            Section(L10n.T("外观与启动"),
                Theme.SettingRow(L10n.T("界面语言"), Theme.Text(L10n.T("重启后生效。"), 12, Theme.Grey), uiLanguage),
                Theme.SettingRow(L10n.T("外观"), null, appearance),
                Theme.SettingRow(L10n.T("登录时启动"), null, login),
                Theme.SettingRow(L10n.T("任务栏显示主窗口"), null, Theme.Toggle(s.ShowInTaskbar, v => { s.ShowInTaskbar = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("语音条"), null, Theme.Toggle(s.ShowIdleBar, v => { s.ShowIdleBar = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("新手引导"), null, Theme.Secondary(L10n.T("打开新手引导"), host.ShowOnboarding))));
        AddTab(L10n.T("隐私与权限"),
            Section(L10n.T("隐私与数据"),
                Theme.SettingRow(L10n.T("历史保留"), null, Controls.Retention(host)),
                Theme.SettingRow(L10n.T("保留录音 5 分钟"), null, Theme.Toggle(s.KeepAudio24h, v => { s.KeepAudio24h = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("删除全部记录"), null, Theme.Secondary(L10n.T("清空历史与活动"), () => { if (MessageBox.Show(L10n.T("删除全部历史、统计和录音？无法撤销。"), "TypeLeast", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK) host.ClearHistory(); }))),
            Section(L10n.T("权限"),
                Theme.SettingRow(L10n.T("麦克风"), microphoneStatus, Theme.Secondary(L10n.T("打开系统权限"), () => Shell.Open("ms-settings:privacy-microphone"))),
                Theme.SettingRow(L10n.T("键盘与插入"), keyboardStatus, Theme.Text(L10n.T("在管理员窗口中粘贴可能失败，请手动粘贴。"), 12, Theme.Grey))));
        AddTab(L10n.T("服务与更新"),
            Section(L10n.T("本地服务"),
                Theme.SettingRow(L10n.T("本地服务"), serviceStatus, Theme.Row(8, chooseNode, Theme.Secondary(L10n.T("重新启动"), host.RestartService))),
                Theme.SettingRow(L10n.T("当前识别模型"), speechStatus, Theme.Row(8, progress, downloadButton)),
                Theme.SettingRow(L10n.T("模型下载镜像（可选）"), null, Theme.Row(8, mirror, useMirror))),
            speechModels.View,
            Section(L10n.T("版本与更新"),
                Theme.SettingRow("TypeLeast " + version, updateStatus,
                    Theme.Row(8, Theme.Secondary(L10n.T("检查更新"), () => _ = CheckUpdates()), installUpdate)),
                Theme.SettingRow(L10n.T("更新提醒"), null,
                    Theme.Toggle(s.AutoUpdate, v => { s.AutoUpdate = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("下载源"), null, UpdateSourceChoice(s)),
                Theme.SettingRow(L10n.T("数据文件夹"), Theme.Text(L10n.T("识别：本机（sherpa-onnx）· 整理：你的模型"), 12, Theme.Grey),
                    Theme.Secondary(L10n.T("打开数据文件夹"), () => Shell.Open(AppPaths.StateDirectory())))));
        DockPanel.SetDock(root, Dock.Top); surface.Children.Add(root);
        DockPanel.SetDock(tabBar, Dock.Top); surface.Children.Add(tabBar);
        surface.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = tabContent });
        ShowTab(Math.Clamp(lastTab, 0, tabs.Count - 1));
        LoadPreset();
    }
    private ComboBox UpdateSourceChoice(AppSettings s)
    {
        var choice = Theme.Choice(220);
        foreach (var (code, label) in new[] { ("auto", "自动（GitHub 慢时用镜像）"), ("github", "只用 GitHub"), ("mirror", "镜像优先") })
            choice.Items.Add(new ComboBoxItem { Content = L10n.T(label), Tag = code });
        choice.SelectedIndex = Math.Max(0, Array.IndexOf(UpdateSources.Modes, s.UpdateSource));
        choice.SelectionChanged += (_, _) => { if (choice.SelectedItem is ComboBoxItem { Tag: string code }) { s.UpdateSource = code; host.SaveSettings(); } };
        return choice;
    }

    private async Task CheckUpdates()
    {
        updateStatus.Text = L10n.T("正在检查…");
        updateStatus.Text = await host.Updates.Check();
        RefreshUpdateButton();
    }

    private async Task RunUpdate()
    {
        updateStatus.Text = L10n.T("正在下载并校验更新…");
        var error = await host.Updates.Install();
        if (error is not null) updateStatus.Text = error;
    }

    /// <summary>"立即更新" for the installed copy, "下载新版本" for a portable one; hidden when up to date.</summary>
    private void RefreshUpdateButton()
    {
        installUpdate.Visibility = host.Updates.Available is null ? Visibility.Collapsed : Visibility.Visible;
        installUpdate.Content = Updater.IsInstalledCopy ? L10n.T("立即更新") : L10n.T("下载新版本");
        installUpdate.IsEnabled = !host.Updates.Updating;
    }

    private readonly WrapPanel tabBar = new() { Margin = new Thickness(0, 14, 0, 0) };
    private readonly StackPanel tabContent = new();
    private readonly System.Collections.Generic.List<(Button Button, UIElement[] Cards)> tabs = new();
    private static int lastTab;

    private void AddTab(string title, params UIElement[] cards)
    {
        var index = tabs.Count;
        var button = Theme.PillButton(title, () => ShowTab(index));
        tabs.Add((button, cards));
        tabBar.Children.Add(button);
    }

    /// <summary>Show one tab (0 听写, 1 整理, 2 通用, 3 隐私与权限, 4 服务与更新).</summary>
    public void SelectTab(int index) => ShowTab(Math.Clamp(index, 0, tabs.Count - 1));

    private void ShowTab(int index)
    {
        lastTab = index;
        tabContent.Children.Clear();
        foreach (var card in tabs[index].Cards) tabContent.Children.Add(card);
        for (var i = 0; i < tabs.Count; i++)
        {
            Theme.SetPillSelected(tabs[i].Button, i == index);
        }
    }

    private static UIElement Spacer(double height) => new Border { Height = height };

    private static Border Section(string title, params UIElement[] rows)
    {
        var stack = new StackPanel();
        stack.Children.Add(Theme.SectionTitle(title));
        foreach (var r in rows) stack.Children.Add(r);
        var card = Theme.Card(stack);
        card.Margin = new Thickness(0, 14, 0, 0);
        return card;
    }

    private void SetBusyControls(bool value)
    { preset.IsEnabled = !value; baseUrl.IsEnabled = !value; model.IsEnabled = !value; modelList.IsEnabled = !value; key.IsEnabled = !value && host.Settings.Preset.NeedsKey; }

    private void LoadPreset()
    {
        var s = host.Settings;
        baseUrl.Text = s.LlmBaseUrl;
        model.Text = s.LlmModel;
        modelList.Items.Clear();
        modelList.Visibility = Visibility.Collapsed;
        var stored = host.Credentials.Read(s.LlmPresetId) ?? "";
        key.Password = stored;
        key.IsEnabled = s.Preset.NeedsKey;
        keyStatus.Text = !s.Preset.NeedsKey ? L10n.T("本机服务不需要 Key") : stored.Length > 0 ? L10n.T("已存入 Windows 凭据管理器") : L10n.T("粘贴 Key，再保存或测试。");
        llmStatus.Text = s.Preset.KeyPage.Length > 0 ? L10n.T("在这里创建 Key：") + s.Preset.KeyPage : "";
        llmStatus.Foreground = Theme.Grey;
        UpdateMissing();
    }

    private void UpdateMissing()
    {
        var s = host.Settings;
        var parts = new System.Collections.Generic.List<string>();
        if (!LlmPreset.IsAllowedBaseUrl(s.LlmBaseUrl)) parts.Add(L10n.T("接口地址无效"));
        if (s.Preset.NeedsKey && (host.Credentials.Read(s.LlmPresetId) ?? "").Length == 0) parts.Add(L10n.T("Key 未保存"));
        if (s.LlmModel.Length == 0) parts.Add(L10n.T("没有模型"));
        missing.Text = parts.Count == 0 ? "" : string.Join("、", parts) + L10n.T("。可以听写，但不整理。");
    }

    private bool SaveKey(bool quiet)
    {
        var ok = host.Credentials.Write(host.Settings.LlmPresetId, key.Password);
        keyStatus.Text = ok ? (key.Password.Length > 0 ? L10n.T("已存入 Windows 凭据管理器") : L10n.T("已删除")) : L10n.T("无法存入凭据管理器");
        if (!quiet) host.SaveSettings();
        UpdateMissing();
        return ok;
    }

    /// <summary>The route as typed, with the key from the box (saved or not).</summary>
    private LlmRoute? DraftRoute()
    {
        var s = host.Settings;
        var url = baseUrl.Text.Trim(); var id = model.Text.Trim();
        var k = key.Password.Length > 0 ? key.Password : host.Credentials.Read(s.LlmPresetId) ?? "";
        if (!LlmPreset.IsAllowedBaseUrl(url) || id.Length == 0 || (s.Preset.NeedsKey && k.Length == 0)) return null;
        return new LlmRoute(url, id, k);
    }

    private async Task FetchModels()
    {
        var s = host.Settings;
        s.LlmBaseUrl = baseUrl.Text;
        var k = key.Password.Length > 0 ? key.Password : host.Credentials.Read(s.LlmPresetId) ?? "";
        if (!LlmPreset.IsAllowedBaseUrl(s.LlmBaseUrl)) { Status(L10n.T("接口地址需要 https"), false); return; }
        Status(L10n.T("正在获取…"), true);
        try
        {
            var ids = await ServiceClient.ListModelsAsync(new LlmRoute(s.LlmBaseUrl, "", k));
            modelList.Items.Clear();
            foreach (var id in ids) modelList.Items.Add(id);
            modelList.Visibility = ids.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            Status(ids.Count > 0 ? L10n.T("共 ") + ids.Count + L10n.T(" 个模型，在右边选择") : L10n.T("服务商没有返回模型列表，请手动填写"), ids.Count > 0);
        }
        catch (ServiceException e)
        {
            Status(e.Status is { } st ? Messages.ExplainLlmCode("HTTP_" + st, null) : L10n.T("连不上服务商：") + e.Message + L10n.T("。请检查网络或代理"), false);
        }
    }

    private async Task Test()
    {
        if (busy) return;
        var route = DraftRoute();
        if (route is null) { Status(L10n.T("请先填好地址、Key 和模型"), false); return; }
        busy = true; SetBusyControls(true);
        Status(L10n.T("正在测试…"), true);
        try
        {
            var result = await host.Client.TestLlmAsync(route);
            Log.Write("operation.complete", new DiagnosticEvent("connection-test", "complete", result.Code, result.Ms).Format());
            if (result.Ok)
            {
                var saved = key.Password.Length == 0 || SaveKey(quiet: true);
                host.Settings.LlmBaseUrl = route.BaseUrl; host.Settings.LlmModel = route.Model;
                var routeSaved = host.SaveSettings();
                if (!routeSaved) { Status(L10n.T("测试成功，但保存失败，仍用原设置。"), false); return; }
                Status(L10n.T("连接成功，用时 ") + (int)(result.Ms ?? 0) + L10n.T(" 毫秒") + (saved ? L10n.T("，Key 已保存") : L10n.T("，但 Key 未保存"))
                    + (result.Code == "thinking" ? L10n.T("。此模型先思考，整理较慢") : ""), saved);
                Log.Write("llm.test.ok", "connected");
            }
            else
            {
                Status(Messages.ExplainLlmCode(result.Code, result.Error), false);
                Log.Write("llm.test.fail", "code=" + DiagnosticEvent.SafeReason(result.Code));
            }
        }
        catch (ServiceException e)
        {
            Status(e.ServiceUnavailable ? L10n.T("本地服务未就绪，请稍后重试") : L10n.T("失败：") + e.Message, false);
        }
        finally
        {
            busy = false; SetBusyControls(false);
            UpdateMissing();
        }
    }

    private void Status(string text, bool ok)
    {
        llmStatus.Text = text;
        llmStatus.Foreground = ok ? Theme.Success : Theme.Warning;
    }

    private void ChooseNode()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = L10n.T("选择 node.exe"), Filter = "node.exe|node.exe", CheckFileExists = true };
        if (dialog.ShowDialog() == true)
        {
            host.Settings.NodePath = dialog.FileName;
            host.SaveSettings();
            host.RestartService();
        }
    }

    public void Refresh()
    {
        // The mirror may have been filled in from a failed download's hint.
        if (!mirror.IsKeyboardFocusWithin && mirror.Text != host.Settings.ModelMirror) mirror.Text = host.Settings.ModelMirror;
        settingsSaveStatus.Text = host.SettingsSaveError ?? "";
        keyboardStatus.Text = host.HotkeyReady switch { true => L10n.T("键盘钩子已注册"), false => L10n.T("键盘钩子注册失败，请用托盘菜单"), _ => L10n.T("键盘钩子未启动") };
        microphoneStatus.Text = host.MicrophoneReady switch { true => L10n.T("上次麦克风已打开"), false => L10n.T("上次麦克风没打开。请检查权限和设备。"), _ => L10n.T("未测试。请点「测试」。") };
        speechModels.Refresh();
        refreshingLanguage = true;
        dictationLanguage.IsEnabled = host.Speech?.CanSetLanguage != false;
        foreach (ComboBoxItem item in dictationLanguage.Items) item.IsEnabled = host.Speech?.Languages?.Contains((string)item.Tag) != false;
        dictationLanguage.SelectedIndex = dictationLanguage.IsEnabled && host.Speech?.Languages?.Contains(host.Settings.Language) != false
            ? Array.IndexOf(new[] { "auto", "zh", "en", "yue", "ja", "ko" }, host.Settings.Language) : 0;
        refreshingLanguage = false;
        dictationLanguage.ToolTip = dictationLanguage.IsEnabled ? null : "";
        var svc = host.Service;
        serviceStatus.Text = host.ServiceSummary + (svc.NodeVersion is { } v && svc.NodePath is { } p ? " · Node.js " + v + "（" + p + "）" : "");
        serviceStatus.Foreground = svc.State == ServiceManager.Phase.Running ? Theme.Grey : Theme.Warning;
        var speech = host.Speech;
        var problem = Messages.SpeechProblem(speech);
        speechStatus.Text = (speech?.DisplayName ?? L10n.T("未选择语音模型")) + " · " + (problem.Length == 0 ? L10n.T("就绪，音频不出本机") : problem);
        if (speech?.DownloadFraction is { } f)
        {
            progress.Visibility = Visibility.Visible;
            progress.Value = f;
        }
        else
        {
            progress.Visibility = Visibility.Collapsed;
        }
        downloadButton.Visibility = speech is { ModelsMissing: true } or { Phase: "error" } ? Visibility.Visible : Visibility.Collapsed;
    }
}
