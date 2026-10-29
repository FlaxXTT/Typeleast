namespace TypeLeast.Core;

/// <summary>
/// The two cue sounds, synthesised in memory as WAV files (no system sounds): a soft "登登", the same
/// as the Mac app's StartChime. Start rises (G4 then C5), stop falls (G4 then D4). Near-pure sine notes
/// with an 8 ms attack and a natural exponential tail (no hard cut-off), quiet, about 0.46 s in all.
/// </summary>
public static class Chimes
{
    public const int SampleRate = 44100;

    public static byte[] Start() => Render((0.0, 392.0, 0.045, 0.13), (0.13, 523.3, 0.085, 0.15));

    public static byte[] Stop() => Render((0.0, 392.0, 0.045, 0.13), (0.13, 293.7, 0.085, 0.16));

    private static byte[] Render(params (double Start, double Frequency, double Decay, double Peak)[] notes)
    {
        var total = (int)(SampleRate * 0.46);
        var pcm = new byte[total * 2];
        for (var i = 0; i < total; i++)
        {
            var t = (double)i / SampleRate;
            var v = 0.0;
            foreach (var (start, frequency, decay, peak) in notes)
            {
                if (t < start) continue;
                var local = t - start;
                var envelope = Math.Min(1.0, local / 0.008) * Math.Exp(-local / decay);
                v += peak * envelope * (Math.Sin(2 * Math.PI * frequency * local) + 0.02 * Math.Sin(6 * Math.PI * frequency * local));
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
