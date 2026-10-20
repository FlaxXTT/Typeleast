using System;
using System.Collections.Generic;
using NAudio.CoreAudioApi;

namespace TypeLeast;

/// <summary>Mute existing render sessions only; restore only sessions still in our muted state.</summary>
internal sealed class AudioDucking : IDisposable
{
    private readonly List<SimpleAudioVolume> muted = new();
    private MMDeviceEnumerator? enumerator;
    private MMDevice? device;
    public void Start()
    {
        Dispose();
        try
        {
            enumerator = new MMDeviceEnumerator(); device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var sessions = device.AudioSessionManager.Sessions;
            for (var i = 0; i < sessions.Count; i++)
            {
                var session = sessions[i];
                if (session.GetProcessID == Environment.ProcessId) continue;
                var volume = session.SimpleAudioVolume;
                if (!volume.Mute) { volume.Mute = true; muted.Add(volume); }
            }
        }
        catch (Exception) { Dispose(); Log.Write("audio.mute.fail"); }
    }
    public void Dispose()
    {
        foreach (var volume in muted) { try { if (volume.Mute) volume.Mute = false; } catch (Exception) { } }
        muted.Clear(); device?.Dispose(); enumerator?.Dispose(); device = null; enumerator = null;
    }
}
