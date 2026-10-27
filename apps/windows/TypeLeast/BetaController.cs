using System;
using System.Threading.Tasks;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>Owns the Beta conversation and its original destination, independently of recording.</summary>
internal sealed class BetaController
{
    private readonly ServiceClient client;
    private readonly Action finish;
    private readonly Action? resume;
    private BetaPanel? panel;
    public string? Session { get; private set; }
    public IntPtr Window { get; private set; }
    public string App { get; private set; } = "";
    public FieldTarget? Field { get; private set; }
    public DictationOptions? Options { get; private set; }

    public BetaController(ServiceClient client, Action finish, Action? resume = null) { this.client = client; this.finish = finish; this.resume = resume; }
    public bool Show(DictateResponse result, DictationOptions options, IntPtr window, string app,
                     FieldTarget? field, string hotkey)
    {
        if (result.Beta?.SessionId is not { } id) return false;
        if (Session is null) { Window = window; App = app; Field = field; }
        Session = id;
        Options = options;
        panel ??= new BetaPanel(finish, Drop, resume);
        panel.ShowQuestions(result.Beta, hotkey);
        return true;
    }
    public void SetBusy(string text) => panel?.SetBusy(text);
    public void Resume() => panel?.Resume();
    public void Hide() => panel?.Hide();
    public void Clear() { Session = null; Options = null; Field = null; panel?.Hide(); }
    public void Drop()
    {
        if (Session is not { } id) return;
        var app = App;
        var route = Options?.Route;
        Clear();
        _ = Task.Run(async () => { try { await client.BetaAsync(id, skip: false, app, route); } catch (ServiceException) { } });
    }
}
