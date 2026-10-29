namespace TypeLeast.Core;

/// <summary>
/// The two cue sounds, synthesised in memory as WAV files (no system sounds).
/// Start: two soft, mid notes rising (E5 then A5), the same as the Mac app's StartChime.
/// Stop: two soft, lower notes going down (B4 then E4), slower attack and no bright
/// partial, so it sounds rounder and duller than the start.
/// </summary>
public static class Chimes
{
    public const int SampleRate = 44100;

    public static byte[] Start() => Render(0.30, 0.09, 0.006, 0.08, (0.0, 659.3, 0.20), (0.07, 880.0, 0.22));

    public static byte[] Stop() => Render(0.30, 0.070, 0.008, 0.0, (0.0, 493.9, 0.34), (0.085, 329.6, 0.38));

    /// <param name="decay">Exponential decay time of each note, seconds.</param>
    /// <param name="attack">Linear attack, seconds.</param>
    /// <param name="octave">Level of the octave partial (brightness).</param>
    private static byte[] Render(double seconds, double decay, double attack, double octave, params (double Start, double Frequency, double Peak)[] notes)
    {
        var total = (int)(SampleRate * seconds);
        var pcm = new byte[total * 2];
        for (var i = 0; i < total; i++)
        {
            var t = (double)i / SampleRate;
            var v = 0.0;
            foreach (var (start, frequency, peak) in notes)
            {
                if (t < start) continue;
                var local = t - start;
                var envelope = Math.Min(1.0, local / attack) * Math.Exp(-local / decay);
                v += peak * envelope * (Math.Sin(2 * Math.PI * frequency * local) + octave * Math.Sin(4 * Math.PI * frequency * local));
            }
            v *= Math.Min(1.0, (total - i) / (SampleRate * 0.03)); // 30 ms fade-out: no click at the end
            BitConverter.TryWriteBytes(pcm.AsSpan(i * 2, 2), (short)(Math.Clamp(v, -1.0, 1.0) * short.MaxValue));
        }
        return Wav(pcm);
    }

    private static byte[] Wav(byte[] pcm)
    {
        using var stream = new MemoryStream();
        using var w = new BinaryWriter(stream);
        w.Write("RIFF"u8); w.Write(36 + pcm.Length); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(SampleRate); w.Write(SampleRate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(pcm.Length); w.Write(pcm);
        w.Flush();
        return stream.ToArray();
    }
}
