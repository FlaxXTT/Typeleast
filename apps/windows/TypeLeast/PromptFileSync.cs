using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>The service reloads promptify.json before each prompt-mode request.</summary>
internal sealed class PromptFileSync : IDisposable
{
    private readonly ServiceClient client;
    private readonly string legacyPath;
    private readonly SemaphoreSlim gate = new(1, 1);
    public string FilePath { get; }
    public event Action<string, bool>? Status;

    public PromptFileSync(ServiceClient client, string stateDir)
    {
        this.client = client;
        FilePath = Path.Combine(stateDir, "promptify.json");
        legacyPath = PromptFile.PathIn(stateDir);
    }
    public void Start() { }
    public void ServiceReady() => _ = PrepareAsync();

    /// <summary>Import an older file only when it is newer; keep it intact for compatibility.</summary>
    public async Task PrepareAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (!File.Exists(legacyPath) || (File.Exists(FilePath) && File.GetLastWriteTimeUtc(legacyPath) <= File.GetLastWriteTimeUtc(FilePath))) return;
            if (new FileInfo(legacyPath).Length > 100_000) throw new InvalidDataException();
            var current = await client.GetPromptifyAsync();
            var wanted = PromptFile.OverrideFrom(await File.ReadAllTextAsync(legacyPath), current.Default);
            await client.SetPromptifyAsync(overrideText: wanted, restoreDefault: wanted is null);
        }
        catch (Exception e) when (e is ServiceException or IOException or UnauthorizedAccessException)
        { Status?.Invoke(L10n.T("提示词配置未能读取，原文件已保留。"), false); }
        finally { gate.Release(); }
    }

    public async Task OpenAsync()
    {
        await PrepareAsync();
        string? temp = null;
        try
        {
            var current = await client.GetPromptifyAsync();
            if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 100_000) throw new InvalidDataException();
            var existing = File.Exists(FilePath) ? await File.ReadAllTextAsync(FilePath) : null;
            var text = PromptConfiguration.Prepare(existing, current);
            temp = FilePath + ".tmp-" + Guid.NewGuid().ToString("N");
            await File.WriteAllTextAsync(temp, text, new UTF8Encoding(false));
            File.Move(temp, FilePath, overwrite: true);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe") { ArgumentList = { FilePath }, UseShellExecute = false });
            Status?.Invoke(L10n.T("保存配置文件后，下一次整理生效。"), true);
        }
        catch (Exception e) when (e is ServiceException or IOException or UnauthorizedAccessException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception)
        { Status?.Invoke(L10n.T("配置文件无法打开，原文件已保留。请检查格式和文件权限。"), false); }
        finally {
            try { if (temp is not null && File.Exists(temp)) File.Delete(temp); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log.Write("prompt.temp.cleanup", e.GetType().Name); }
        }
    }

    public async Task RestoreDefaultAsync()
    {
        try
        {
            await client.SetPromptifyAsync(restoreDefault: true);
            Status?.Invoke(L10n.T("已恢复默认提示词。"), true);
        }
        catch (ServiceException) { Status?.Invoke(L10n.T("保存失败，请重试。"), false); }
    }
    public void Dispose() { }
}
