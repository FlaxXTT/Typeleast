using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// The Extensions page's state and actions. The service checks, stores and applies plugins;
/// this only asks it, and asks the official catalog through it only when the market tab is
/// opened or refreshed. Results arrive on the UI thread (the awaits resume there).
/// </summary>
internal sealed class PluginController(ServiceClient client, Func<string> sources)
{
    public PluginState State { get; private set; } = new();
    public PluginCatalog? Catalog { get; private set; }
    public bool CatalogLoading { get; private set; }
    public string? Message { get; private set; }
    public event Action? Changed;

    public IEnumerable<PluginSummary> Styles => State.Plugins.Where(p => p.IsStyle);
    public PluginSummary? SelectedStyle => State.Plugins.FirstOrDefault(p => p.Id == State.Style);

    private async Task Run(Func<Task<PluginState>> work)
    {
        try { Installed(await work()); Message = null; }
        catch (ServiceException e) { Message = PluginMessages.Describe(e); }
        Changed?.Invoke();
    }

    /// <summary>New installed state; the catalog's "installed" marks follow it.</summary>
    private void Installed(PluginState state)
    {
        State = state;
        if (Catalog is null) return;
        var versions = state.Plugins.ToDictionary(p => p.Id, p => p.Version);
        foreach (var entry in Catalog.Plugins) entry.InstalledVersion = versions.GetValueOrDefault(entry.Id);
    }

    public Task Refresh() => Run(() => client.GetPluginsAsync());

    /// <summary>The user opened the market tab or pressed refresh: one catalog read.</summary>
    public async Task OpenMarket()
    {
        if (CatalogLoading) return;
        CatalogLoading = true; Changed?.Invoke();
        try
        {
            Catalog = await client.GetPluginCatalogAsync(sources());
            Message = Catalog.Ok ? null : PluginMessages.Describe(Catalog.Code);
        }
        catch (ServiceException e) { Message = PluginMessages.Describe(e); }
        finally { CatalogLoading = false; Changed?.Invoke(); }
    }

    public async Task<PluginInspection?> Inspect(byte[] file)
    {
        try { var inspection = await client.InspectPluginAsync(file); Message = null; return inspection; }
        catch (ServiceException e) { Message = PluginMessages.Describe(e); Changed?.Invoke(); return null; }
    }

    /// <summary>Install exactly what the confirmation showed (its fingerprint); a changed plugin is refused.</summary>
    public Task InstallFile(byte[] file, bool enable, string digest) => Run(() => client.InstallPluginAsync(file, enable, digest));

    public async Task InstallFromCatalog(string id, bool enable, string digest)
    {
        await Run(() => client.InstallCatalogPluginAsync(id, enable, digest));
        // The catalog changed after the confirmation was shown: show the new content.
        if (Message == PluginMessages.Describe("plugin-changed")) await OpenMarket();
    }
    public Task SetEnabled(string id, bool enabled) => Run(() => client.SetPluginEnabledAsync(id, enabled));
    public Task SelectStyle(string? id) => Run(() => client.SelectStyleAsync(id));
    public Task Remove(string id) => Run(() => client.RemovePluginAsync(id));
}
