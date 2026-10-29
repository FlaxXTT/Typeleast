namespace TypeLeast.Core;

/// <summary>
/// The two cue sounds, synthesised in memory as WAV files (no system sounds): a blunt "嘟嘟",
/// the same as the Mac app's StartChime. Start rises (G4 then C5), stop falls (C5 then G4).
/// Pure sine notes with a soft 12 ms attack and a short rounded decay, so they sound dull, not sharp.
/// </summary>
public static class Chimes
{
    public const int SampleRate = 44100;

    public static byte[] Start() => Render((0.0, 392.0), (0.11, 523.3));

    public static byte[] Stop() => Render((0.0, 523.3), (0.11, 392.0));

    private static byte[] Render(params (double Start, double Frequency)[] notes)
    {
        const double seconds = 0.26, length = 0.095, peak = 0.22;
        var total = (int)(SampleRate * seconds);
        var pcm = new byte[total * 2];
        for (var i = 0; i < total; i++)
        {
            var t = (double)i / SampleRate;
            var v = 0.0;
            foreach (var (start, frequency) in notes)
            {
                if (t < start || t >= start + length) continue;
                var local = t - start;
                var envelope = Math.Min(1.0, local / 0.012) * Math.Min(1.0, (length - local) / 0.025) * Math.Exp(-local / 0.12);
                v += peak * envelope * Math.Sin(2 * Math.PI * frequency * local);
            }
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
