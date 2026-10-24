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

        var enVariant = Theme.Choice(160);
        foreach (var (code, label) in new[] { ("us", L10n.T("美式")), ("gb", L10n.T("英式")) })
            enVariant.Items.Add(new ComboBoxItem { Content = label, Tag = code });
        enVariant.SelectedIndex = Array.IndexOf(AppSettings.EnVariants, s.EnVariant);
        enVariant.SelectionChanged += (_, _) => { if (enVariant.SelectedItem is ComboBoxItem { Tag: string v }) { s.EnVariant = v; host.SaveSettings(); } };

        var languageRows = new UIElement[]
        {
            Theme.SettingRow(L10n.T("听写语言"), Theme.Text(L10n.T("只能选当前模型支持的语言，其余自动识别。"), 12, Theme.Grey), dictationLanguage),
            Theme.SettingRow(L10n.T("翻译成"), Theme.Text(L10n.T("用翻译快捷键说的话会译成这种语言。需要先设置整理模型。"), 12, Theme.Grey), translateTarget),
            Theme.SettingRow(L10n.T("中文写法"), Theme.Text(L10n.T("中文输出用简体还是繁体（繁体会换成当地用语）。"), 12, Theme.Grey), zhVariant),
            Theme.SettingRow(L10n.T("英文拼写"), Theme.Text(L10n.T("输出的英文用美式还是英式拼写（color / colour）。"), 12, Theme.Grey), enVariant),
        };

        // ---- dictation
        var hotkey = Theme.Choice(160);
        foreach (DictationKey k in Enum.GetValues(typeof(DictationKey))) hotkey.Items.Add(new ComboBoxItem { Content = TapDetector.Label(k), Tag = k });
        hotkey.SelectedIndex = (int)s.Hotkey;
        // 翻译 has its own key, never the dictation key.
        var translateKey = Theme.Choice(160);
        translateKey.Items.Add(new ComboBoxItem { Content = L10n.T("关闭"), Tag = null });
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

        var mic = Theme.Choice(220);
        mic.Items.Add(new ComboBoxItem { Content = L10n.T("系统默认麦克风"), Tag = -1 });
        var devices = Array.Empty<string>();
        try { devices = AudioRecorder.Devices().ToArray(); } catch (Exception) { }
        for (var i = 0; i < devices.Length; i++) mic.Items.Add(new ComboBoxItem { Content = devices[i], Tag = i });
        mic.SelectedIndex = s.MicrophoneDevice >= 0 && s.MicrophoneDevice < devices.Length ? s.MicrophoneDevice + 1 : 0;
        mic.SelectionChanged += (_, _) => { if (mic.SelectedItem is ComboBoxItem { Tag: int v }) { s.MicrophoneDevice = v; host.SaveSettings(); } };

        var restore = Theme.Toggle(s.RestoreClipboard, value => { s.RestoreClipboard = value; host.SaveSettings(); });
        var login = Theme.Toggle(s.LaunchAtLogin, value => { s.LaunchAtLogin = value; if (host.SaveSettings()) Autostart.Apply(value); });
        var pasteKey = Theme.Choice(180);
        foreach (var code in new[] { "CtrlShiftV", "CtrlAltV", "off" }) pasteKey.Items.Add(new ComboBoxItem { Content = code == "off" ? L10n.T("关闭") : code == "CtrlShiftV" ? "Ctrl + Shift + V" : "Ctrl + Alt + V", Tag = code });
        pasteKey.SelectedIndex = s.PasteLastShortcut == "CtrlAltV" ? 1 : s.PasteLastShortcut == "off" ? 2 : 0;
        pasteKey.SelectionChanged += (_, _) => { if (pasteKey.SelectedItem is ComboBoxItem { Tag: string code }) { s.PasteLastShortcut = code; host.SaveSettings(); } };
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
            Theme.Text(L10n.T("用你自己的 API Key 整理文字。Key 只存在本机凭据管理器。"), 12.5, Theme.Grey),
            Theme.SettingRow(L10n.T("服务商"), null, preset),
            Theme.SettingRow(L10n.T("接口地址"), Theme.Text(L10n.T("需要 https 地址（本机可用 http://127.0.0.1）"), 12, Theme.Grey), baseUrl),
            Theme.SettingRow("API Key", keyStatus, Theme.Row(8, key, saveKey)),
            Theme.SettingRow(L10n.T("模型"), Theme.Text(L10n.T("填模型 ID，或者点「获取列表」"), 12, Theme.Grey), Theme.Row(8, model, modelList, fetch)),
            Theme.Row(10, test, llmStatus),
            missing);

        var insertion = Theme.Choice(200);
        var insertionCodes = new[] { "autoPaste", "clipboardOnly", "preview" };
        foreach (var label in new[] { "自动粘贴", "仅复制", "先预览" }) insertion.Items.Add(L10n.T(label));
        insertion.SelectedIndex = Array.IndexOf(insertionCodes, s.InsertionMode);
        insertion.SelectionChanged += (_, _) => { if (insertion.SelectedIndex >= 0) { s.InsertionMode = insertionCodes[insertion.SelectedIndex]; host.SaveSettings(); } };
        var appearance = Theme.Choice(180); var appearances = new[] { "system", "light", "dark" };
        foreach (var label in new[] { "跟随系统", "浅色", "深色" }) appearance.Items.Add(L10n.T(label));
        appearance.SelectedIndex = Array.IndexOf(appearances, s.Appearance);
        appearance.SelectionChanged += (_, _) => { if (appearance.SelectedIndex >= 0) { s.Appearance = appearances[appearance.SelectedIndex]; host.SaveSettings(); } };

        downloadButton = Theme.Primary(L10n.T("下载（约 241 MB）"), () => _ = host.DownloadModels());
        mirror.Text = s.ModelMirror;
        mirror.LostFocus += (_, _) => { s.ModelMirror = mirror.Text.Trim(); host.SaveSettings(); };
        var useMirror = Theme.Secondary(L10n.T("填入 hf-mirror.com"), () => { mirror.Text = s.ModelMirror = ModelMirror.Suggested; host.SaveSettings(); });
        var chooseNode = Theme.Secondary(L10n.T("选择 Node.js…"), ChooseNode);
        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "?";
        installUpdate = Theme.Primary(L10n.T("立即更新"), () => _ = RunUpdate());
        RefreshUpdateButton();
        if (host.Updates.Available is { } pending) updateStatus.Text = L10n.T("有新版本 {0}。", pending.Version);

        // Five tabs, each a few cards that put related settings together.
        AddTab(L10n.T("听写"),
            Section(L10n.T("快捷键"),
                Theme.SettingRow(L10n.T("听写快捷键"), Theme.Text(L10n.T("按一下开始，再按一下结束。右 Alt 在部分键盘上是 AltGr，可换键。"), 12, Theme.Grey), hotkey),
                Theme.SettingRow(L10n.T("翻译快捷键"), Theme.Text(L10n.T("必须与听写键不同。"), 12, Theme.Grey), translateKey),
                Theme.SettingRow(L10n.T("粘贴上一条"), Theme.Text(L10n.T("与其他应用冲突时可更换或关闭。"), 12, Theme.Grey), pasteKey),
                Theme.SettingRow(L10n.T("取消"), Theme.Text(L10n.T("录音和处理期间均可取消。"), 12, Theme.Grey), Theme.Keycaps("Esc"))),
            Section(L10n.T("语言"), languageRows),
            Section(L10n.T("麦克风与声音"),
                Theme.SettingRow(L10n.T("麦克风"), null, mic),
                Theme.SettingRow(L10n.T("麦克风测试"), Theme.Text(L10n.T("最长 15 秒，不识别也不保存。"), 12, Theme.Grey), Theme.Secondary(L10n.T("开始测试"), () => MicrophoneTestPanel.Show(host))),
                Theme.SettingRow(L10n.T("提示音"), Theme.Text(L10n.T("开始收音时响一声，听到再说话。"), 12, Theme.Grey), Theme.Toggle(s.PlaySounds, v => { s.PlaySounds = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("录音时静音其他声音"), Theme.Text(L10n.T("录音时静音正在播放的声音，结束后恢复"), 12, Theme.Grey), Theme.Toggle(s.MuteOtherAudio, v => { s.MuteOtherAudio = v; host.SaveSettings(); }))));
        AddTab(L10n.T("整理"),
            modelSection,
            Section(L10n.T("整理选项"),
                Theme.SettingRow(L10n.T("参考输入框内容"), Theme.Text(L10n.T("把光标附近的文字发给整理模型，帮它认对人名和术语。不读密码框。"), 12, Theme.Grey), Theme.Toggle(s.UseFieldContext, v => { s.UseFieldContext = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("自动学习更正"), Theme.Text(L10n.T("你在听写后改对的词会自动加进词典，可撤销。只在本机比对。"), 12, Theme.Grey), Theme.Toggle(s.LearnCorrections, v => { s.LearnCorrections = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("格式化编号列表"), Theme.Text(L10n.T("带编号的结果粘贴成列表；终端里用纯文本。"), 12, Theme.Grey), Theme.Toggle(s.FormattedLists, v => { s.FormattedLists = v; host.SaveSettings(); }))));
        AddTab(L10n.T("通用"),
            Section(L10n.T("插入"),
                Theme.SettingRow(L10n.T("插入方式"), Theme.Text(L10n.T("窗口变了或没权限时，只复制不粘贴。"), 12, Theme.Grey), insertion),
                Theme.SettingRow(L10n.T("粘贴后恢复剪贴板"), Theme.Text(L10n.T("粘贴完把你原来复制的内容放回剪贴板"), 12, Theme.Grey), restore)),
            Section(L10n.T("外观与启动"),
                Theme.SettingRow(L10n.T("界面语言"), Theme.Text(L10n.T("重启后生效，不影响听写语言。"), 12, Theme.Grey), uiLanguage),
                Theme.SettingRow(L10n.T("外观"), null, appearance),
                Theme.SettingRow(L10n.T("登录启动"), null, login),
                Theme.SettingRow(L10n.T("任务栏显示主窗口"), Theme.Text(L10n.T("关闭窗口后仍在托盘运行，从托盘菜单退出。"), 12, Theme.Grey), Theme.Toggle(s.ShowInTaskbar, v => { s.ShowInTaskbar = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("常驻小语音条"), null, Theme.Toggle(s.ShowIdleBar, v => { s.ShowIdleBar = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("新手引导"), null, Theme.Secondary(L10n.T("重新打开引导"), host.ShowOnboarding))));
        AddTab(L10n.T("隐私与权限"),
            Section(L10n.T("隐私与数据"),
                Theme.SettingRow(L10n.T("历史保留"), Theme.Text(L10n.T("不保存时，上一条结果只留到退出。"), 12, Theme.Grey), Controls.Retention(host)),
                Theme.SettingRow(L10n.T("保留录音用于重试"), Theme.Text(L10n.T("加密保存约 5 分钟，可用来重试；退出 App 时删除，异常退出则下次启动时删除。"), 12, Theme.Grey), Theme.Toggle(s.KeepAudio24h, v => { s.KeepAudio24h = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("删除全部数据记录"), null, Theme.Secondary(L10n.T("清空历史与活动"), () => { if (MessageBox.Show(L10n.T("删除全部历史、统计和录音？无法撤销。"), "TypeLeast", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK) host.ClearHistory(); }))),
            Section(L10n.T("权限"),
                Theme.SettingRow(L10n.T("麦克风"), microphoneStatus, Theme.Secondary(L10n.T("打开系统权限"), () => Shell.Open("ms-settings:privacy-microphone"))),
                Theme.SettingRow(L10n.T("键盘与跨进程插入"), keyboardStatus, Theme.Text(L10n.T("向管理员权限的窗口粘贴可能失败，这时请手动粘贴。"), 12, Theme.Grey))));
        AddTab(L10n.T("服务与更新"),
            Section(L10n.T("本地服务"),
                Theme.SettingRow(L10n.T("本地服务"), serviceStatus, Theme.Row(8, chooseNode, Theme.Secondary(L10n.T("重新启动"), host.RestartService))),
                Theme.SettingRow(L10n.T("当前识别模型"), speechStatus, Theme.Row(8, progress, downloadButton)),
                Theme.SettingRow(L10n.T("模型下载镜像（可选）"), Theme.Text(L10n.T("下载慢或失败时填镜像地址。文件都会校验，镜像改不了内容。"), 12, Theme.Grey), Theme.Row(8, mirror, useMirror))),
            speechModels.View,
            Section(L10n.T("版本与更新"),
                Theme.SettingRow("TypeLeast " + version, updateStatus,
                    Theme.Row(8, Theme.Secondary(L10n.T("检查更新"), () => _ = CheckUpdates()), installUpdate)),
                Theme.SettingRow(L10n.T("自动更新"), Theme.Text(L10n.T("启动和打开窗口时检查，空闲时自动安装并重新打开。"), 12, Theme.Grey),
                    Theme.Toggle(s.AutoUpdate, v => { s.AutoUpdate = v; host.SaveSettings(); })),
                Theme.SettingRow(L10n.T("更新下载源"), Theme.Text(L10n.T("GitHub 慢时自动换镜像。安装包都会校验，改过的不会安装。"), 12, Theme.Grey), UpdateSourceChoice(s)),
                Theme.SettingRow(L10n.T("数据文件夹"), Theme.Text(L10n.T("识别：本机模型（sherpa-onnx）· 整理：你自己的模型"), 12, Theme.Grey),
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
        foreach (var (code, label) in new[] { ("auto", "自动（GitHub 慢时换镜像）"), ("github", "只用 GitHub"), ("mirror", "优先镜像") })
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
        // Same as at launch: with 自动更新 on, a found update installs right away.
        if (host.Updates.Available is not null && host.Settings.AutoUpdate && Updater.IsInstalledCopy) await RunUpdate();
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
        keyStatus.Text = !s.Preset.NeedsKey ? L10n.T("本机服务不需要 Key") : stored.Length > 0 ? L10n.T("已保存在 Windows 凭据管理器") : L10n.T("粘贴 Key，再点保存或测试连接");
        llmStatus.Text = s.Preset.KeyPage.Length > 0 ? L10n.T("Key 在这里创建：") + s.Preset.KeyPage : "";
        llmStatus.Foreground = Theme.Grey;
        UpdateMissing();
    }

    private void UpdateMissing()
    {
        var s = host.Settings;
        var parts = new System.Collections.Generic.List<string>();
        if (!LlmPreset.IsAllowedBaseUrl(s.LlmBaseUrl)) parts.Add(L10n.T("接口地址不可用"));
        if (s.Preset.NeedsKey && (host.Credentials.Read(s.LlmPresetId) ?? "").Length == 0) parts.Add(L10n.T("还没保存 Key"));
        if (s.LlmModel.Length == 0) parts.Add(L10n.T("还没填模型"));
        missing.Text = parts.Count == 0 ? "" : string.Join("、", parts) + L10n.T("。现在也能听写，只是不整理。");
    }

    private bool SaveKey(bool quiet)
    {
        var ok = host.Credentials.Write(host.Settings.LlmPresetId, key.Password);
        keyStatus.Text = ok ? (key.Password.Length > 0 ? L10n.T("已保存在 Windows 凭据管理器") : L10n.T("已删除")) : L10n.T("没能保存到凭据管理器");
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
        if (route is null) { Status(L10n.T("先填好地址、Key 和模型"), false); return; }
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
                if (!routeSaved) { Status(L10n.T("测试成功，但没能保存，仍用原设置。"), false); return; }
                Status(L10n.T("连接成功，用时 ") + (int)(result.Ms ?? 0) + L10n.T(" 毫秒") + (saved ? L10n.T("，Key 已保存") : L10n.T("，但 Key 没能保存"))
                    + (result.Code == "thinking" ? L10n.T("。这个模型会先思考，整理会慢一些") : ""), saved);
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
            Status(e.ServiceUnavailable ? L10n.T("本地服务还没就绪，稍后再试") : L10n.T("失败：") + e.Message, false);
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
        keyboardStatus.Text = host.HotkeyReady switch { true => L10n.T("键盘钩子已注册"), false => L10n.T("键盘钩子注册失败，可使用托盘入口"), _ => L10n.T("键盘钩子尚未启动") };
        microphoneStatus.Text = host.MicrophoneReady switch { true => L10n.T("上次麦克风打开成功"), false => L10n.T("上次麦克风打开失败，请检查权限和设备"), _ => L10n.T("尚未测试；点击测试确认设备和权限") };
        speechModels.Refresh();
        refreshingLanguage = true;
        dictationLanguage.IsEnabled = host.Speech?.CanSetLanguage != false;
        foreach (ComboBoxItem item in dictationLanguage.Items) item.IsEnabled = host.Speech?.Languages?.Contains((string)item.Tag) != false;
        dictationLanguage.SelectedIndex = dictationLanguage.IsEnabled && host.Speech?.Languages?.Contains(host.Settings.Language) != false
            ? Array.IndexOf(new[] { "auto", "zh", "en", "yue", "ja", "ko" }, host.Settings.Language) : 0;
        refreshingLanguage = false;
        dictationLanguage.ToolTip = dictationLanguage.IsEnabled ? null : L10n.T("当前模型自动检测语言，不能强制指定。");
        var svc = host.Service;
        serviceStatus.Text = host.ServiceSummary + (svc.NodeVersion is { } v && svc.NodePath is { } p ? " · Node.js " + v + "（" + p + "）" : "");
        serviceStatus.Foreground = svc.State == ServiceManager.Phase.Running ? Theme.Grey : Theme.Warning;
        var speech = host.Speech;
        var problem = Messages.SpeechProblem(speech);
        speechStatus.Text = (speech?.ModelName ?? "SenseVoice Small") + " · " + (problem.Length == 0 ? L10n.T("已就绪，音频不出本机") : problem);
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
