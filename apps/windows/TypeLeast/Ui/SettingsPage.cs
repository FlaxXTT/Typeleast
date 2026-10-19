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
    private readonly TextBlock llmStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock keyStatus = Theme.Text("", 12, Theme.Grey);
    private readonly TextBox baseUrl = Theme.Input("", 300);
    private readonly PasswordBox key = new() { Width = 220, Padding = new Thickness(6, 4, 6, 4), FontSize = 13 };
    private readonly TextBox model = Theme.Input("", 200);
    private readonly ComboBox modelList = Theme.Choice(160);
    private readonly TextBlock missing = Theme.Text("", 12, Theme.Warning);
    private bool busy;

    public UIElement View => root;

    public SettingsPage(AppHost host)
    {
        this.host = host;
        var s = host.Settings;
        root.Children.Add(Theme.Text(L10n.T("设置"), 22, bold: true));

        var uiLanguage = Theme.Choice(160);
        foreach (var (code, label) in new[] { ("system", L10n.T("跟随系统")), ("zh-Hans", "简体中文"), ("en", "English") })
            uiLanguage.Items.Add(new ComboBoxItem { Content = label, Tag = code });
        uiLanguage.SelectedIndex = Array.IndexOf(L10n.Choices, s.InterfaceLanguage);
        uiLanguage.SelectionChanged += (_, _) => {
            if (uiLanguage.SelectedItem is ComboBoxItem { Tag: string code }) { s.InterfaceLanguage = code; host.SaveSettings(); }
        };
        var dictationLanguage = Theme.Choice(160);
        var codes = new[] { "auto", "zh", "en", "yue", "ja", "ko" };
        var labels = new[] { L10n.T("自动识别"), L10n.T("中文"), "English", L10n.T("粤语"), "日本語", "한국어" };
        for (var i = 0; i < codes.Length; i++) dictationLanguage.Items.Add(new ComboBoxItem { Content = labels[i], Tag = codes[i] });
        dictationLanguage.SelectedIndex = Array.IndexOf(codes, s.Language);
        dictationLanguage.SelectionChanged += (_, _) => {
            if (dictationLanguage.SelectedItem is ComboBoxItem { Tag: string code }) { s.Language = code; host.SaveSettings(); }
        };
        root.Children.Add(Section(L10n.T("语言"),
            Theme.SettingRow(L10n.T("界面语言"), Theme.Text(L10n.T("重启应用后生效；不会改变听写或输出语言。"), 12, Theme.Grey), uiLanguage),
            Theme.SettingRow(L10n.T("听写语言"), Theme.Text(L10n.T("自动识别支持中文、英文、粤语、日语、韩语混说"), 12, Theme.Grey), dictationLanguage)));

        // ---- dictation
        var hotkey = Theme.Choice(160);
        foreach (DictationKey k in Enum.GetValues(typeof(DictationKey))) hotkey.Items.Add(new ComboBoxItem { Content = TapDetector.Label(k), Tag = k });
        hotkey.SelectedIndex = (int)s.Hotkey;
        hotkey.SelectionChanged += (_, _) => { if (hotkey.SelectedItem is ComboBoxItem { Tag: DictationKey k }) { s.Hotkey = k; host.SaveSettings(); } };

        var strength = Theme.Choice(160);
        strength.Items.Add(new ComboBoxItem { Content = L10n.T("Article 整理"), Tag = "prompt" });
        strength.Items.Add(new ComboBoxItem { Content = L10n.T("提示词模式"), Tag = "promptify" });
        strength.Items.Add(new ComboBoxItem { Content = L10n.T("原话转写"), Tag = "off" });
        strength.SelectedIndex = s.Strength switch { "promptify" => 1, "off" => 2, _ => 0 };
        strength.SelectionChanged += (_, _) => { if (strength.SelectedItem is ComboBoxItem { Tag: string v }) { s.Strength = v; host.SaveSettings(); } };

        var mic = Theme.Choice(220);
        mic.Items.Add(new ComboBoxItem { Content = L10n.T("系统默认麦克风"), Tag = -1 });
        var devices = Array.Empty<string>();
        try { devices = AudioRecorder.Devices().ToArray(); } catch (Exception) { }
        for (var i = 0; i < devices.Length; i++) mic.Items.Add(new ComboBoxItem { Content = devices[i], Tag = i });
        mic.SelectedIndex = s.MicrophoneDevice >= 0 && s.MicrophoneDevice < devices.Length ? s.MicrophoneDevice + 1 : 0;
        mic.SelectionChanged += (_, _) => { if (mic.SelectedItem is ComboBoxItem { Tag: int v }) { s.MicrophoneDevice = v; host.SaveSettings(); } };

        var restore = new CheckBox { IsChecked = s.RestoreClipboard, VerticalAlignment = VerticalAlignment.Center };
        restore.Click += (_, _) => { s.RestoreClipboard = restore.IsChecked == true; host.SaveSettings(); };
        var login = new CheckBox { IsChecked = s.LaunchAtLogin, VerticalAlignment = VerticalAlignment.Center };
        login.Click += (_, _) => { s.LaunchAtLogin = login.IsChecked == true; Autostart.Apply(s.LaunchAtLogin); host.SaveSettings(); };

        root.Children.Add(Section(L10n.T("听写"),
            Theme.SettingRow(L10n.T("快捷键"), Theme.Text(L10n.T("单独按一下开始，再按一下结束；录音时按 Esc 取消。右 Alt 在部分欧洲键盘上是 AltGr，这时换一个键。"), 12, Theme.Grey), hotkey),
            Theme.SettingRow(L10n.T("整理方式"), Theme.Text(L10n.T("Article 整理：去口水词、改通顺。提示词模式：改写成结构化提示词（角色、背景、任务、要求、语气与受众、输出格式），角色和格式会自动补全，事实不编造。原话转写：只去口水词。"), 12, Theme.Grey), strength),
            Theme.SettingRow(L10n.T("麦克风"), null, mic),
            Theme.SettingRow(L10n.T("粘贴后恢复剪贴板"), Theme.Text(L10n.T("粘贴完把你原来复制的文字放回剪贴板。"), 12, Theme.Grey), restore),
            Theme.SettingRow(L10n.T("开机自动启动"), null, login)));

        // ---- cleanup model
        var preset = Theme.Choice(220);
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

        root.Children.Add(Section(L10n.T("整理模型"),
            Theme.Text(L10n.T("用你自己的 API Key 调用大模型，把识别出的话整理成通顺的书面语。Key 只存在这台电脑的 Windows 凭据管理器里，只发给本机的 TypeLeast 服务。"), 12.5, Theme.Grey),
            Theme.SettingRow(L10n.T("服务商"), null, preset),
            Theme.SettingRow(L10n.T("接口地址"), Theme.Text(L10n.T("需要 https；本机服务可以用 http://127.0.0.1"), 12, Theme.Grey), baseUrl),
            Theme.SettingRow("API Key", keyStatus, Theme.Row(8, key, saveKey)),
            Theme.SettingRow(L10n.T("模型"), Theme.Text(L10n.T("填模型 ID，或者点「获取列表」"), 12, Theme.Grey), Theme.Row(8, model, modelList, fetch)),
            Theme.Row(10, test, llmStatus),
            missing));

        // ---- prompt mode's system prompt
        root.Children.Add(new PromptifyPanel(host).View);

        // ---- local service
        downloadButton = Theme.Primary(L10n.T("下载（约 241 MB）"), () => _ = host.DownloadModels());
        var mirror = Theme.Input(s.ModelMirror, 240, L10n.T("例如 https://hf-mirror.com"));
        mirror.LostFocus += (_, _) => { s.ModelMirror = mirror.Text.Trim(); host.SaveSettings(); };
        var chooseNode = Theme.Secondary(L10n.T("选择 Node.js…"), ChooseNode);
        root.Children.Add(Section(L10n.T("本地服务"),
            Theme.SettingRow(L10n.T("本地服务"), serviceStatus, Theme.Row(8, chooseNode, Theme.Secondary(L10n.T("重新启动"), host.RestartService))),
            Theme.SettingRow(L10n.T("语音模型（SenseVoice）"), speechStatus, Theme.Row(8, progress, downloadButton)),
            Theme.SettingRow(L10n.T("模型下载镜像（可选）"), Theme.Text(L10n.T("huggingface.co 下载慢或打不开时，填一个镜像地址，例如 https://hf-mirror.com。每个文件都会校验 SHA-256，镜像改不了内容。"), 12, Theme.Grey), mirror)));

        // ---- about
        var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "?";
        root.Children.Add(Section(L10n.T("关于"),
            Theme.SettingRow("TypeLeast " + version, Theme.Text(L10n.T("识别：SenseVoice（sherpa-onnx，本机）· 整理：你自己的模型"), 12, Theme.Grey),
                Theme.Secondary(L10n.T("打开数据文件夹"), () => Shell.Open(AppPaths.StateDirectory())))));

        LoadPreset();
    }

    private static Border Section(string title, params UIElement[] rows)
    {
        var stack = new StackPanel();
        stack.Children.Add(Theme.SectionTitle(title));
        foreach (var r in rows) stack.Children.Add(r);
        var card = Theme.Card(stack);
        card.Margin = new Thickness(0, 14, 0, 0);
        return card;
    }

    private void LoadPreset()
    {
        var s = host.Settings;
        baseUrl.Text = s.LlmBaseUrl;
        model.Text = s.LlmModel;
        modelList.Items.Clear();
        modelList.Visibility = Visibility.Collapsed;
        var stored = CredentialStore.Read(s.LlmPresetId) ?? "";
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
        if (s.Preset.NeedsKey && (CredentialStore.Read(s.LlmPresetId) ?? "").Length == 0) parts.Add(L10n.T("还没保存 Key"));
        if (s.LlmModel.Length == 0) parts.Add(L10n.T("还没填模型"));
        missing.Text = parts.Count == 0 ? "" : string.Join("、", parts) + L10n.T("。在此之前听写照常可用：只去掉口水词，不改写。");
    }

    private bool SaveKey(bool quiet)
    {
        var ok = CredentialStore.Write(host.Settings.LlmPresetId, key.Password);
        keyStatus.Text = ok ? (key.Password.Length > 0 ? L10n.T("已保存在 Windows 凭据管理器") : L10n.T("已删除")) : L10n.T("没能保存到凭据管理器");
        if (!quiet) host.SaveSettings();
        UpdateMissing();
        return ok;
    }

    /// <summary>The route as typed, with the key from the box (saved or not).</summary>
    private LlmRoute? DraftRoute()
    {
        var s = host.Settings;
        s.LlmBaseUrl = baseUrl.Text;
        s.LlmModel = model.Text;
        var k = key.Password.Length > 0 ? key.Password : CredentialStore.Read(s.LlmPresetId) ?? "";
        if (!LlmPreset.IsAllowedBaseUrl(s.LlmBaseUrl) || s.LlmModel.Length == 0 || (s.Preset.NeedsKey && k.Length == 0)) return null;
        return new LlmRoute(s.LlmBaseUrl, s.LlmModel, k);
    }

    private async Task FetchModels()
    {
        var s = host.Settings;
        s.LlmBaseUrl = baseUrl.Text;
        var k = key.Password.Length > 0 ? key.Password : CredentialStore.Read(s.LlmPresetId) ?? "";
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
        busy = true;
        Status(L10n.T("正在测试…"), true);
        try
        {
            var result = await host.Client.TestLlmAsync(route);
            if (result.Ok)
            {
                var saved = key.Password.Length == 0 || SaveKey(quiet: true);
                host.SaveSettings();
                Status(L10n.T("连接成功，用时 ") + (int)(result.Ms ?? 0) + L10n.T(" 毫秒") + (saved ? L10n.T("，Key 已保存") : L10n.T("，但 Key 没能保存"))
                    + (result.Code == "thinking" ? L10n.T("。这个模型会先思考再回答，整理会慢一些") : ""), saved);
                Log.Write("llm.test.ok", "connected");
            }
            else
            {
                Status(Messages.ExplainLlmCode(result.Code, result.Error), false);
                Log.Write("llm.test.fail", "code=" + (result.Code ?? "?"));
            }
        }
        catch (ServiceException e)
        {
            Status(e.ServiceUnavailable ? L10n.T("本地服务还没就绪（测试要经过它）。等首页显示就绪后再点一次") : L10n.T("失败：") + e.Message, false);
        }
        finally
        {
            busy = false;
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
        var svc = host.Service;
        serviceStatus.Text = host.ServiceSummary + (svc.NodeVersion is { } v && svc.NodePath is { } p ? " · Node.js " + v + "（" + p + "）" : "");
        serviceStatus.Foreground = svc.State == ServiceManager.Phase.Running ? Theme.Grey : Theme.Warning;
        var speech = host.Speech;
        var problem = Messages.SpeechProblem(speech);
        speechStatus.Text = problem.Length == 0 ? L10n.T("已就绪，识别完全在本机进行，音频不出这台电脑") : problem;
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
