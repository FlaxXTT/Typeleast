using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// Keeps the service's prompt-mode prompt in step with promptify-system.md: the user
/// opens the file from Settings, edits it in Notepad and saves; the next dictation in
/// prompt mode uses it. Deleting the file restores the default. A missing file at start
/// changes nothing, so a replacement saved by an older version stays in effect.
/// </summary>
internal sealed class PromptFileSync : IDisposable
{
    private readonly ServiceClient client;
    private readonly DispatcherTimer debounce = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private FileSystemWatcher? watcher;
    private bool deleted;

    public string FilePath { get; }
    /// <summary>The last outcome, for Settings: (message, ok).</summary>
    public event Action<string, bool>? Status;

    public PromptFileSync(ServiceClient client, string stateDir)
    {
        this.client = client;
        FilePath = PromptFile.PathIn(stateDir);
        debounce.Tick += async (_, _) => { debounce.Stop(); await Push(); };
    }

    public void Start()
    {
        try
        {
            watcher = new FileSystemWatcher(Path.GetDirectoryName(FilePath)!, PromptFile.FileName) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size };
            watcher.Changed += (_, _) => Later(false);
            watcher.Created += (_, _) => Later(false);
            watcher.Renamed += (_, _) => Later(false);
            watcher.Deleted += (_, _) => Later(true);
            watcher.EnableRaisingEvents = true;
        }
        catch (Exception e) { Log.Write("prompt.watch.fail", e.GetType().Name); }
        if (File.Exists(FilePath)) debounce.Start();
    }

    /// <summary>Called whenever the service (re)starts, so a change saved while it was down is not lost.</summary>
    public void ServiceReady() { if (File.Exists(FilePath)) Later(false); }

    private void Later(bool wasDeleted)
    {
        debounce.Dispatcher.InvokeAsync(() => { deleted = wasDeleted; debounce.Stop(); debounce.Start(); });
    }

    private async Task Push()
    {
        try
        {
            var current = await client.GetPromptifyAsync();
            var text = File.Exists(FilePath) ? await ReadShared() : null;
            if (text is null && !deleted) return;
            var wanted = PromptFile.OverrideFrom(text, current.Default);
            if (wanted == current.Override) return;
            if (wanted is null) await client.SetPromptifyAsync(restoreDefault: true);
            else await client.SetPromptifyAsync(overrideText: wanted);
            Status?.Invoke(wanted is null ? L10n.T("已使用默认提示词。") : L10n.T("已读取提示词文件，下一次整理生效。"), true);
        }
        catch (ServiceException e) { Status?.Invoke(L10n.T("提示词文件未能应用：") + e.Message, false); }
        catch (IOException) { Status?.Invoke(L10n.T("提示词文件暂时无法读取，保存后会再试。"), false); }
        catch (UnauthorizedAccessException) { Status?.Invoke(L10n.T("提示词文件暂时无法读取，保存后会再试。"), false); }
    }

    /// <summary>Create the file with the prompt now in effect (if needed) and open it in Notepad.</summary>
    public async Task OpenAsync()
    {
        try
        {
            if (!File.Exists(FilePath))
            {
                var current = await client.GetPromptifyAsync();
                await File.WriteAllTextAsync(FilePath, PromptFile.Initial(current.Override, current.Default), new System.Text.UTF8Encoding(false));
            }
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe") { ArgumentList = { FilePath }, UseShellExecute = false });
        }
        catch (ServiceException) { Status?.Invoke(L10n.T("本地服务还没就绪，就绪后再打开。"), false); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { Status?.Invoke(L10n.T("无法打开提示词文件。"), false); }
    }

    /// <summary>Remove the file and the replacement: the default prompt again.</summary>
    public async Task RestoreDefaultAsync()
    {
        try
        {
            if (File.Exists(FilePath)) File.Delete(FilePath);
            await client.SetPromptifyAsync(restoreDefault: true);
            Status?.Invoke(L10n.T("已恢复默认提示词。"), true);
        }
        catch (ServiceException e) { Status?.Invoke(L10n.T("保存失败：") + e.Message, false); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Status?.Invoke(L10n.T("无法删除提示词文件。"), false); }
    }

    /// <summary>Notepad may still hold the file for a moment after saving.</summary>
    private async Task<string> ReadShared()
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                using var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream);
                return await reader.ReadToEndAsync();
            }
            catch (IOException) when (attempt < 5) { await Task.Delay(100); }
        }
    }

    public void Dispose() { debounce.Stop(); watcher?.Dispose(); }
}
