using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// Starts, watches and stops the TypeLeast local service (service/ in this
/// repository, shipped beside TypeLeast.exe together with node\node.exe). The
/// service gets --parent-pid, so it exits by itself when the app does, even after
/// a crash. Its first stdout line carries the port.
/// </summary>
internal sealed class ServiceManager
{
    public enum Phase { Stopped, NoNode, NoService, Starting, Running, Failed }

    public Phase State { get; private set; } = Phase.Stopped;
    public string Detail { get; private set; } = "";
    public string? NodePath { get; private set; }
    public string? NodeVersion { get; private set; }
    public int Port { get; private set; }
    /// <summary>Last lines the service wrote to stderr.</summary>
    public List<string> RecentLog { get; } = new();

    /// <summary>Raised on a background thread; the UI marshals it.</summary>
    public event Action? Changed;

    public string NodePathOverride { get; set; } = "";
    public string ModelMirror { get; set; } = "";

    private readonly ServiceClient client;
    private readonly object gate = new();
    private Process? process;
    private bool stopping;
    private int restartAttempts;

    public ServiceManager(ServiceClient client) => this.client = client;

    private void Set(Phase phase, string detail = "")
    {
        State = phase;
        Detail = detail;
        Changed?.Invoke();
    }

    public void Start() => Task.Run(StartCore);

    public void Restart()
    {
        Task.Run(async () =>
        {
            KillChild();
            NodePath = null;
            restartAttempts = 0;
            await Task.Delay(500);
            await StartCore();
        });
    }

    public void Stop() => KillChild();

    private void KillChild()
    {
        lock (gate)
        {
            stopping = true;
            try { if (process is { HasExited: false }) process.Kill(entireProcessTree: true); } catch (Exception) { }
            process = null;
        }
    }

    private async Task StartCore()
    {
        lock (gate)
        {
            stopping = false;
            if (process is { HasExited: false }) return;
        }

        // A service that already answers (started by hand, or a second copy) is used as is.
        if (client.DiscoverBaseUri())
        {
            try
            {
                var health = await client.HealthOnceAsync();
                if (health.Service == "typeleast")
                {
                    Port = client.LastPort ?? 0;
                    Set(Phase.Running);
                    return;
                }
            }
            catch (ServiceException) { }
        }

        var appDir = AppContext.BaseDirectory;
        var env = AppPaths.Environment();
        var serviceDir = ServiceLocator.ServiceDirectory(appDir, env, File.Exists);
        if (serviceDir is null)
        {
            Set(Phase.NoService, "TypeLeast 安装目录里缺少本地服务文件，请重新安装");
            return;
        }
        if (NodePath is null) FindNode(appDir, env);
        if (NodePath is null || !ServiceLocator.IsSupported(NodeVersion))
        {
            Set(Phase.NoNode, NodeVersion is null ? "没有找到 Node.js（需要 22 或更新）" : "Node.js 版本过低：" + NodeVersion + "，需要 22 或更新");
            NodePath = null;
            return;
        }

        var start = new ProcessStartInfo(NodePath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = serviceDir,
        };
        start.ArgumentList.Add(Path.Combine(serviceDir, "bin", "typeleast-service.mjs"));
        start.ArgumentList.Add("--parent-pid");
        start.ArgumentList.Add(Environment.ProcessId.ToString());
        if (ModelMirror.Length > 0) start.Environment["HF_ENDPOINT"] = ModelMirror;

        var p = new Process { StartInfo = start, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) =>
        {
            if (ServiceLocator.ParseReadyLine(e.Data) is { } port)
            {
                client.UsePort(port);
                Port = port;
                restartAttempts = 0;
                Set(Phase.Running);
            }
        };
        p.ErrorDataReceived += (_, e) =>
        {
            if (string.IsNullOrEmpty(e.Data)) return;
            lock (RecentLog)
            {
                RecentLog.Add(e.Data.Length > 300 ? e.Data[..300] : e.Data);
                if (RecentLog.Count > 20) RecentLog.RemoveAt(0);
            }
        };
        p.Exited += (_, _) => OnExit(p);
        try
        {
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            lock (gate) process = p;
            Log.Write("service.start", "node=" + NodeVersion);
            Set(Phase.Starting);
        }
        catch (Exception e)
        {
            Set(Phase.Failed, "无法启动 Node.js：" + e.Message);
        }
    }

    private void OnExit(Process p)
    {
        lock (gate)
        {
            if (process is not null && process != p) return;
            process = null;
            if (stopping) return;
        }
        var code = 0;
        try { code = p.ExitCode; } catch (Exception) { }
        Log.Write("service.exit", "code=" + code);
        restartAttempts++;
        if (ServiceLocator.RestartDelay(restartAttempts) is not { } delay)
        {
            string last;
            lock (RecentLog) last = RecentLog.LastOrDefault() ?? "退出码 " + code;
            Set(Phase.Failed, "本地服务反复退出：" + last);
            return;
        }
        Set(Phase.Starting);
        Task.Delay(TimeSpan.FromSeconds(delay)).ContinueWith(_ =>
        {
            if (!stopping) _ = StartCore();
        });
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
            using var p = Process.Start(new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            if (p is null) return null;
            var output = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(5000)) { try { p.Kill(); } catch (Exception) { } return null; }
            return p.ExitCode == 0 ? output.Result : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
