using System;
using System.Threading.Tasks;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// The bundled 「技术术语」 pack's switch on the Dictionary page. The service stores and applies
/// the pack; this only asks it. Results arrive on the UI thread (the awaits resume there).
/// </summary>
internal sealed class PluginController(ServiceClient client)
{
    public PluginState State { get; private set; } = new();
    /// <summary>Bumped when a change fails, so views redraw from the real state.</summary>
    public int Revision { get; private set; }
    public string? Message { get; private set; }
    public event Action? Changed;

    private async Task Run(Func<Task<PluginState>> work)
    {
        try { State = await work(); Message = null; }
        // A refused change leaves the state as it was; the revision makes the page redraw anyway, so a
        // switch the user flipped goes back to what is really installed.
        catch (ServiceException e) { Message = PluginMessages.Describe(e); Revision++; }
        Changed?.Invoke();
    }

    public Task Refresh() => Run(() => client.GetPluginsAsync());
    public Task SetEnabled(string id, bool enabled) => Run(() => client.SetPluginEnabledAsync(id, enabled));
}
