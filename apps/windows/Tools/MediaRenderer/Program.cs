using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using TypeLeast;
using TypeLeast.Core;
using TypeLeast.Ui;

sealed class FakeKeys : ICredentialStore
{
    public string? Read(string account) => account == "deepseek" ? "sk-demo-not-real" : null;
    public bool Write(string account, string value) => true;
}

// Program.cs (MediaRenderer) - renders the README and website images from the real WPF
// views with fictional sample data, in an isolated profile: home, history and settings in
// light and dark, and the recording bar's frames (speech, thinking, result). The ready state
// is filled in by reflection because no local service runs here. "only-pages" skips the frames.
class P
{
    const double Dpi = 192;
    static void Save(FrameworkElement e, string path, double w, double h)
    {
        e.Measure(new Size(w, h)); e.Arrange(new Rect(new Size(w, h))); e.UpdateLayout();
        var bmp = new RenderTargetBitmap((int)(w * Dpi / 96), (int)(h * Dpi / 96), Dpi, Dpi, PixelFormats.Pbgra32);
        bmp.Render(e);
        var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(bmp));
        using var f = File.Create(path); enc.Save(f);
    }

    static void Seed(AppHost host)
    {
        var now = DateTimeOffset.Now;
        var samples = new (string App, string Raw, string Text, int MinutesAgo)[]
        {
            ("WeChat.exe", "嗯那个周三的会我们改到下午三点吧然后记得把报告带上", "周三的会改到下午三点，记得带上报告。", 6),
            ("chrome.exe", "帮我写一封邮件给李老师说一下我下周请假两天嗯原因是家里有事", "李老师您好：我下周需要请假两天，因为家里有事。谢谢理解！", 42),
            ("Code.exe", "这个函数的返回值应该是一个列表而不是字典就是说要改一下", "这个函数的返回值应该是列表，而不是字典，需要修改。", 95),
            ("WINWORD.EXE", "第一点是成本第二点是时间第三点是人手", "1. 成本\n2. 时间\n3. 人手", 180),
            ("notepad.exe", "明天早上八点半提醒我给客户回电话", "明天早上 8:30 提醒我给客户回电话。", 60 * 26),
        };
        System.Array.Reverse(samples);
        foreach (var (app, raw, text, ago) in samples)
            host.History.Add(new HistoryEntry { App = app, Raw = raw, Text = text, Seconds = raw.Length / 4.5, Inserted = true, Time = now.AddMinutes(-ago),
                Request = new HistoryRequest("auto", "prompt", null, null) });
        var random = new Random(3);
        for (var day = 0; day < 140; day++)
        {
            if (random.NextDouble() < 0.35) continue;
            for (var n = random.Next(1, 9); n > 0; n--) host.Activity.Record(random.Next(12, 90), DateTime.Now.Date.AddDays(-day).AddHours(10));
        }
        foreach (var (word, heard) in new[] { ("DeepSeek", "德普西克"), ("TypeLeast", ""), ("SenseVoice", ""), ("王小明", "王晓明") })
            if (WordEntry.Parse(word, heard) is { } entry) host.Settings.DictionaryEntries.Add(entry);
        host.Settings.LlmPresetId = "deepseek"; host.Settings.LlmModel = "deepseek-flash";
        host.SaveSettings();
        // Screenshots show the ready state; no service runs in this renderer.
        void SetPrivate(object target, string name, object value) =>
            target.GetType().GetProperty(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(target, value);
        SetPrivate(host, "Health", new HealthResponse { Ok = true, Service = "typeleast", Speech = new SpeechStatus { Ready = true, Phase = "ready", ModelName = "SenseVoice Small" } });
        SetPrivate(host, "MicrophoneReady", (bool?)true);
        SetPrivate(host.Service, "State", ServiceManager.Phase.Running);
    }

    static FrameworkElement Page(AppHost host, MainWindow.Page page)
    {
        var window = new MainWindow(host);
        window.ShowPage(page);
        var content = (FrameworkElement)window.Content; window.Content = null;
        return content;
    }

    /// <summary>The update window in each step, light and dark (design review).</summary>
    static void RenderUpdateWindow(string dir)
    {
        foreach (var mode in new[] { "light", "dark" })
        {
            Theme.Apply(mode);
            foreach (var (name, stage, received, total, source) in new (string, UpdateStage, long, long?, string)[]
            {
                ("download-start", UpdateStage.Downloading, 3L << 20, 78L << 20, "GitHub"),
                ("download-mirror", UpdateStage.Downloading, 49L << 20, 78L << 20, "ghfast.top"),
                ("verifying", UpdateStage.Verifying, 0, null, "ghfast.top"),
                ("installing", UpdateStage.Installing, 0, null, "GitHub"),
            })
            {
                var window = new UpdateProgressWindow();
                window.SetVersion("1.19.0", "• " + L10n.T("自然整理") + " / " + L10n.T("AI 整理") + "\n• " + L10n.T("提示词 Beta"));
                window.Report(stage, received, total, source);
                var content = (FrameworkElement)window.Content; window.Content = null;
                var card = new Border { Background = Theme.CardFill, Child = content };
                card.Measure(new Size(360, double.PositiveInfinity));
                Save(card, Path.Combine(dir, $"update-{name}-{mode}-{L10n.Language}.png"), 360, card.DesiredSize.Height);
            }
            // The offer that comes before any download: 立即更新 or 稍后.
            var release = new WindowsReleaseInfo("1.20.1", "v1.20.1", "", Summary: "• " + L10n.T("自然整理") + "\n• " + L10n.T("来自镜像"));
            var offer = new UpdateOfferWindow(release, "1.20.0", installedCopy: true);
            var offerContent = (FrameworkElement)offer.Content; offer.Content = null;
            var offerCard = new Border { Background = Theme.Background, Child = offerContent };
            offerCard.Measure(new Size(440, double.PositiveInfinity));
            Save(offerCard, Path.Combine(dir, $"update-offer-{mode}-{L10n.Language}.png"), 440, offerCard.DesiredSize.Height);
        }
    }

    static void RenderSpeechModels(AppHost host, string dir, string language)
    {
        var catalog = new SpeechModelCatalog { ActiveModelId = "qwen3-asr-0.6b", Models = new() {
            new() { Id = "qwen3-asr-0.6b", Name = "Qwen3-ASR-0.6B", ModelBytes = 990000000, SourceUrl = "https://example.com/model", Category = "primary", Precision = "int8", Installed = true, Downloadable = true },
            new() { Id = "qwen3-asr-1.7b-fp16", Name = "Qwen3-ASR-1.7B", ModelBytes = 4731171333, SourceUrl = "https://example.com/model", Category = "primary", Precision = "fp16", Downloadable = true },
            new() { Id = "sensevoice-small", Name = "SenseVoice Small", ModelBytes = 240000000, SourceUrl = "https://example.com/model", Category = "other", Precision = "int8", Installed = true },
        } };
        host.GetType().GetProperty("SpeechCatalog")!.SetValue(host, catalog);
        foreach (var mode in new[] { "light", "dark" }) {
            Theme.Apply(mode);
            var panel = new SpeechModelsPanel(host); panel.Refresh();
            var notes = new List<string>();
            void Gather(DependencyObject node) {
                if (node is TextBlock text) notes.Add(text.Text);
                foreach (var child in LogicalTreeHelper.GetChildren(node)) if (child is DependencyObject d) Gather(d);
            }
            Gather(panel.View);
            if (!notes.Any(t => t.Contains("4.73 GB") && t.Contains("FP16"))) throw new InvalidOperationException("Model precision and size must be present in the actual UI tree.");
            Save(new Border { Background = Theme.Background, Padding = new Thickness(20), Child = panel.View },
                Path.Combine(dir, $"speech-models-{mode}-{language}.png"), 500, 700);
        }
    }

    // Exercise the real controller composition with fake credentials and an isolated profile.
    static void CheckControllers(AppHost host)
    {
        var checks = 0;
        void Check(bool ok, string name) { if (!ok) throw new InvalidOperationException(name); checks++; }
        Check(host.Phase == DictationPhase.Idle, "initial recording phase");
        host.EndMicrophoneTest();
        Check(!host.IsMicrophoneTesting, "ending an idle microphone test opens no device");
        host.Cancel();
        Check(host.Phase == DictationPhase.Idle, "cancel idle remains idle");
        // Cleanup has one mode: an old tier selection no longer changes it.
        var mode = host.Settings.Strength;
        host.SetStrength("concise");
        Check(host.Settings.Strength == mode, "a tier selection does not change the single mode");
        var beta = new BetaController(new ServiceClient(), () => { });
        var options = new DictationOptions("zh", "promptbeta", null, null, null, "clipboardOnly", false);
        var first = new DictateResponse { Beta = new BetaInfo { SessionId = "round1" } };
        Check(beta.Show(first, options, new IntPtr(123), "original.exe", null, "F8"), "first Beta round");
        var next = new DictateResponse { Beta = new BetaInfo { SessionId = "round2" } };
        beta.Show(next, options, new IntPtr(456), "followup.exe", null, "F8");
        Check(beta.Window == new IntPtr(123) && beta.App == "original.exe", "followup keeps original destination");
        Check(beta.Session == "round2", "session advances");
        beta.Clear();
        Check(beta.Session is null && beta.Options is null && beta.Field is null, "completion clears session");
        Check(!beta.Show(new DictateResponse(), options, IntPtr.Zero, "", null, "F8"), "ordinary result opens no Beta session");
        beta.Show(first, options, new IntPtr(789), "new.exe", null, "F8");
        Check(beta.Window == new IntPtr(789) && beta.App == "new.exe", "new conversation has new destination");
        beta.Clear();
        Console.WriteLine($"CONTROLLER CHECKS: {checks} passed");
    }

    static void RenderDictionary(AppHost host,string dir,string language)
    {
        host.Settings.OnboardingDone=true;host.Settings.PracticeGateRequired=false;
        host.Settings.DictionaryEntries.Clear();
        host.Settings.DictionaryEntries.Add(WordEntry.Parse("Acme")!);host.Settings.DictionaryEntries.Add(WordEntry.Parse("Kubernetes","库伯内蒂斯")!);
        host.Settings.DictionaryEntries.Add(WordEntry.Parse("LegacyTerm","","auto")!);
        foreach(var appearance in new[]{"light","dark"}) {
            Theme.Apply(appearance);
            var page=new DictionaryPage(host);page.Refresh();
            var scroll=new ScrollViewer {Content=page.View,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Padding=new Thickness(20),Background=Theme.Background};
            Save(scroll,Path.Combine(dir,$"dictionary-{appearance}-{language}.png"),880,740);
            scroll.Content=null;
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        var dir = args[0];
        Environment.SetEnvironmentVariable("TYPELEAST_HOME", Path.Combine(dir, "controller-state"));
        var app = new Application();
        var host = new AppHost(app, new FakeKeys());
        L10n.Configure("zh-Hans");
        CheckControllers(host);
        if (args.Length > 1 && args[1] == "update-only")
        {
            foreach (var language in new[] { "zh-Hans", "en" })
            {
                L10n.Configure(language);
                RenderUpdateWindow(dir);
                RenderSpeechModels(host, dir, language);
                RenderDictionary(host,dir,language);
                foreach (var mode in new[] { "light", "dark" })
                foreach (var strength in new[] { "prompt", "concise" })
                {
                    host.SetStrength(strength); Theme.Apply(mode);
                    var picker = new Border { Background = Theme.Sidebar, Padding = new Thickness(0, 12, 0, 12), Child = ModePicker.Sidebar(host) };
                    picker.Measure(new Size(214, double.PositiveInfinity));
                    Save(picker, Path.Combine(dir, $"modes-{strength}-{mode}-{language}.png"), 214, picker.DesiredSize.Height);
                }
            }
            return 0;
        }
        Seed(host);
        foreach (var mode in new[] { "light", "dark" })
        {
            Theme.Apply(mode);
            Save(Page(host, MainWindow.Page.Home), Path.Combine(dir, $"home-{mode}.png"), 940, 640);
            Save(Page(host, MainWindow.Page.History), Path.Combine(dir, $"history-{mode}.png"), 940, 640);
            typeof(SettingsPage).GetField("lastTab", BindingFlags.NonPublic | BindingFlags.Static)!.SetValue(null, 1);
            var settings = Page(host, MainWindow.Page.Settings);
            Save(settings, Path.Combine(dir, $"settings-{mode}.png"), 940, 640);
        }
        if (args.Length > 1) return 0;
        // Recording bar animation: speech, thinking, result, on a neutral background.
        Theme.Apply("light");
        var pill = new PillView(() => { }, () => { });
        var stage = new Grid { Background = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF7)) };
        stage.Children.Add(pill); pill.HorizontalAlignment = HorizontalAlignment.Center; pill.VerticalAlignment = VerticalAlignment.Center;
        var level = new AudioLevel();
        var frame = 0;
        void Shot() => Save(stage, Path.Combine(dir, $"bar-{frame++:D3}.png"), 360, 90);
        pill.SetRecording("");
        const double dt = 1 / 25.0;
        for (var i = 0; i < 8; i++) { pill.Advance(0, null, false, dt); Shot(); }
        var speech = new Random(11);
        for (var i = 0; i < 70; i++)
        {
            var t = i * dt;
            // syllables: bursts of about 0.18 s with short pauses, louder in the middle of the phrase
            var syllable = 0.55 + 0.45 * Math.Abs(Math.Sin(t * Math.PI / 0.18));
            var phrase = t < 1.3 || t > 1.6 ? 1.0 : 0.15;
            var db = -58 + 30 * syllable * phrase + speech.NextDouble() * 4;
            pill.Advance(level.Next(6 * Math.Pow(10, db / 20), dt), null, true, dt); Shot();
        }
        pill.SetThinking(null);
        for (var i = 0; i < 30; i++) { pill.Advance(0, null, true, dt); Shot(); }
        pill.SetResult("已粘贴", false);
        for (var i = 0; i < 25; i++) Shot();
        Console.WriteLine("frames " + frame);
        return 0;
    }
}
