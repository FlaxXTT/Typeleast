using System;
using System.Collections.Generic;
using System.IO;
using NAudio.Wave;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// Records the microphone straight into the service's format (16 kHz mono 16-bit;
/// the Windows wave mapper converts), keeps it in memory, and reports a level for
/// the waveform. Nothing is written to disk.
/// </summary>
internal sealed class AudioRecorder
{
    public const int MaxSeconds = 120;
    private WaveInEvent? wave;
    private readonly MemoryStream buffer = new();
    private readonly object gate = new();

    /// <summary>Latest loudness, 0..1.</summary>
    public double Level { get; private set; }
    public bool IsRecording => wave is not null;
    /// <summary>True once the device has delivered its first audio for this recording.</summary>
    public bool HasAudio { get; private set; }
    /// <summary>Raised (on a background thread) when the first audio arrives: the moment speech is really captured.</summary>
    public event Action? AudioStarted;
    /// <summary>Raised (on a background thread) when the 120 s ceiling is reached.</summary>
    public event Action? LimitReached;
    public event Action? RecordingFailed;

    /// <summary>Input devices by index, as Windows names them.</summary>
    public static List<string> Devices()
    {
        var list = new List<string>();
        for (var i = 0; i < WaveInEvent.DeviceCount; i++) list.Add(WaveInEvent.GetCapabilities(i).ProductName);
        return list;
    }

    /// <exception cref="InvalidOperationException">when the microphone cannot be opened (privacy setting, no device).</exception>
    public void Start(int device)
    {
        lock (gate) buffer.SetLength(0);
        Level = 0;
        HasAudio = false;
        var limitSignalled = false;
        var w = new WaveInEvent
        {
            DeviceNumber = device >= 0 && device < WaveInEvent.DeviceCount ? device : -1,
            WaveFormat = new WaveFormat(Wav.SampleRate, 16, 1),
            // Short buffers: the first audio (and the "speak now" cue) comes sooner after the device opens.
            BufferMilliseconds = 30,
            NumberOfBuffers = 6,
        };
        w.DataAvailable += (_, e) =>
        {
            var chunk = e.Buffer.AsSpan(0, e.BytesRecorded);
            Level = Wav.Level(chunk);
            bool full;
            bool first;
            lock (gate)
            {
                if (wave != w) return;
                first = !HasAudio && e.BytesRecorded > 0;
                if (first) HasAudio = true;
                var remaining = (int)Math.Max(0, (long)MaxSeconds * Wav.BytesPerSecond - buffer.Length);
                buffer.Write(chunk[..Math.Min(remaining, chunk.Length)]);
                full = !limitSignalled && buffer.Length >= (long)MaxSeconds * Wav.BytesPerSecond;
                if (full) limitSignalled = true;
            }
            if (first) AudioStarted?.Invoke();
            if (full) LimitReached?.Invoke();
        };
        w.RecordingStopped += (_, e) => { if (e.Exception is not null && wave == w) RecordingFailed?.Invoke(); };
        try
        {
            wave = w;
            w.StartRecording();
        }
        catch (Exception e)
        {
            w.Dispose();
            wave = null;
            throw new InvalidOperationException(e.Message, e);
        }
    }

    /// <summary>Stop and return the recording as a canonical WAV.</summary>
    public (byte[] Wav, double Seconds) Stop()
    {
        var w = wave;
        wave = null;
        if (w is not null)
        {
            try { w.StopRecording(); } catch (Exception) { }
            w.Dispose();
        }
        byte[] pcm;
        lock (gate)
        {
            pcm = buffer.ToArray();
            if (buffer.TryGetBuffer(out var stored)) stored.AsSpan().Clear();
            buffer.SetLength(0);
        }
        Level = 0;
        HasAudio = false;
        var wav = Wav.FromPcm16(pcm);
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(pcm);
        return (wav, Wav.Seconds(pcm.Length));
    }

    public void Cancel() { var stopped = Stop(); System.Security.Cryptography.CryptographicOperations.ZeroMemory(stopped.Wav); }
}
