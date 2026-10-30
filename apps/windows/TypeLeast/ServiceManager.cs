using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using TypeLeast.Core;

namespace TypeLeast;

internal sealed class ServiceManager
{
    public enum Phase { Stopped, NoNode, NoService, Starting, Running, Failed }
    public Phase State { get; private set; } = Phase.Stopped;
    public string Detail { get; private set; } = "";
    public string? NodePath { get; private set; }
    public string? NodeVersion { get; private set; }
    public int Port { get; private set; }
    public List<string> RecentLog { get; } = new();
    public event Action? Changed;
    public string NodePathOverride { get; set; } = "";
    public string ModelMirror { get; set; } = "";
    private readonly ServiceClient client;
    private readonly object gate = new();
    private readonly SemaphoreSlim starts = new(1);
    private readonly RestartPolicy recovery = new();
    private Process? process;
    private CancellationTokenSource lifetime = new();
    private bool stopped;
    public ServiceManager(ServiceClient client) => this.client = client;
    private void Set(Phase phase, string detail = "") { State = phase; Detail = detail; Changed?.Invoke(); }
    public void Start()
    {
        lock (gate) { if (stopped) return; _ = StartCore(lifetime.Token); }
    }
    public void Restart()
    {
        Stop();
        lock (gate)
        {
            stopped = false; lifetime = new(); recovery.Reset(); NodePath = null;
            _ = StartCore(lifetime.Token);
        }
    }
    public void Stop()
    {
        lock (gate)
        {
            stopped = true; lifetime.Cancel();
            var old = process; process = null;
            try { if (old is { HasExited: false }) old.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            Port = 0; client.InvalidatePort(); Set(Phase.Stopped);
        }
    }
    private async Task StartCore(CancellationToken ct)
    {
        try
        {
            await starts.WaitAsync(ct);
            try
            {
                ct.ThrowIfCancellationRequested();
                lock (gate) { if (process is { HasExited: false }) return; }
                // Always our own child: a service already listening could be anyone's, and the
                // app proves the identity of the one it talks to (ServiceClient.ProofKey).
                var appDir = AppContext.BaseDirectory;
                var env = AppPaths.Environment();
                var serviceDir = ServiceLocator.ServiceDirectory(appDir, env, File.Exists);
                if (serviceDir is null) { Set(Phase.NoService, L10n.T("缺少本地服务文件，请重新安装")); return; }
                if (NodePath is null) FindNode(appDir, env);
                ct.ThrowIfCancellationRequested();
                if (NodePath is null || !ServiceLocator.IsSupported(NodeVersion)) { Set(Phase.NoNode, L10n.T("找不到 Node.js（需要 22 或更新）")); NodePath = null; return; }
                var start = new ProcessStartInfo(NodePath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, WorkingDirectory = serviceDir };
                start.ArgumentList.Add("--expose-gc"); start.ArgumentList.Add(Path.Combine(serviceDir, "bin", "typeleast-service.mjs"));
                start.ArgumentList.Add("--parent-pid"); start.ArgumentList.Add(Environment.ProcessId.ToString());
                // The identity secret goes through stdin, not the command line or the environment.
                start.ArgumentList.Add("--auth-stdin");
                var secret = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
                client.ProofKey = secret;
                foreach (var key in ServiceLocator.UnsafeServiceVariables(new List<string>(start.Environment.Keys))) start.Environment.Remove(key);
                if (ModelMirror.Length > 0) start.Environment["HF_ENDPOINT"] = ModelMirror;
                var p = new Process { StartInfo = start, EnableRaisingEvents = true };
                var uptime = Stopwatch.StartNew();
                p.OutputDataReceived += (_, e) =>
                {
                    lock (gate)
                    {
                        if (ct.IsCancellationRequested || process != p) return;
                        if (ServiceLocator.ParseReadyLine(e.Data) is { } port) { client.UsePort(port); Port = port; Set(Phase.Running); }
                    }
                };
                // stderr may contain provider content: retain no arbitrary child output.
                p.ErrorDataReceived += (_, e) => { };
                p.Exited += (_, _) => OnExit(p, uptime, ct);
                lock (gate)
                {
                    ct.ThrowIfCancellationRequested();
                    process = p; Set(Phase.Starting);
                    try { p.Start(); p.StandardInput.WriteLine(secret); p.StandardInput.Close(); p.BeginOutputReadLine(); p.BeginErrorReadLine(); }
                    catch { process = null; p.Dispose(); throw; }
                }
                Log.Write("service.start");
            }
            finally { starts.Release(); }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception e)
        {
            if (!ct.IsCancellationRequested) { Log.Write("service.start.fail", e.GetType().Name); Set(Phase.Failed, L10n.T("本地服务启动失败。请检查 Node 和安装文件。")); }
        }
    }
    private void OnExit(Process p, Stopwatch uptime, CancellationToken ct)
    {
        double? delay;
        lock (gate)
        {
            if (process != p || ct.IsCancellationRequested) { p.Dispose(); return; }
            process = null; Port = 0; client.InvalidatePort();
            delay = recovery.Next(uptime.Elapsed);
            Set(delay is null ? Phase.Failed : Phase.Starting, delay is null ? L10n.T("本地服务反复退出。请重试或重新安装。") : "");
        }
        p.Dispose(); Log.Write("service.exit");
        if (delay is not null) _ = RestartAfter(delay.Value, ct);
    }
    private async Task RestartAfter(double seconds, CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(seconds), ct); await StartCore(ct); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    }

    private void FindNode(string appDir, IDictionary<string, string?> env)
    {
        var candidates = new List<string>();
        if (NodePathOverride.Length > 0) candidates.Add(NodePathOverride);
        candidates.AddRange(ServiceLocator.NodeCandidates(appDir, env, SubFolders));
        string? tooOldPath = null, tooOldVersion = null;
        foreach (var path in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(path)) continue;
            var version = Run(path, "--version");
            if (version is null) continue;
            if (ServiceLocator.IsSupported(version))
            {
                NodePath = path;
                NodeVersion = version.Trim();
                return;
            }
            tooOldPath ??= path;
            tooOldVersion ??= version.Trim();
        }
        NodePath = tooOldPath;
        NodeVersion = tooOldVersion;
    }

    private static IEnumerable<string> SubFolders(string dir)
    {
        try { return Directory.EnumerateDirectories(dir).Select(d => Path.GetFileName(d) ?? "").ToList(); }
        catch (Exception) { return Array.Empty<string>(); }
    }

    /// <summary>Run a short command, returning stdout, or null on failure or after 5 s.</summary>
    private static string? Run(string exe, string args)
    {
        try
        {
            var start = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var key in ServiceLocator.UnsafeServiceVariables(new List<string>(start.Environment.Keys))) start.Environment.Remove(key);
            using var p = Process.Start(start);
            if (p is null) return null;
            var output = p.StandardOutput.ReadToEndAsync();
            // stderr is read too: a full, unread stderr pipe would block the process until the timeout.
            _ = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(5000)) { try { p.Kill(); } catch (Exception) { } return null; }
            return p.ExitCode == 0 ? output.Result : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
