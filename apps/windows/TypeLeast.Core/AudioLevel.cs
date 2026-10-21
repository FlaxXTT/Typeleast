namespace TypeLeast.Core;

/// <summary>
/// Turns the recorder's level (RMS × 6, clamped) into what the waveform shows.
/// Many Windows microphones deliver quiet speech (around −40 to −30 dBFS, no automatic
/// gain), so a fixed scale drew small bars. The display therefore follows the loudest
/// recent speech: normal speech fills the bar, a gate keeps room noise flat. This only
/// changes the picture; the recording itself is untouched.
/// </summary>
public sealed class AudioLevel
{
    private const double FloorDb = -55, CeilingDb = -20, Gate = 0.12, MinPeak = 0.35;
    private double peak = MinPeak;

    /// <summary>0..1 on a decibel scale: 0 = −55 dBFS or less, 1 = −20 dBFS or more.</summary>
    public static double Loudness(double level)
    {
        var rms = level / 6;
        if (!(rms > 0)) return 0;
        return Math.Clamp((20 * Math.Log10(rms) - FloorDb) / (CeilingDb - FloorDb), 0, 1);
    }

    /// <summary>Display height 0..1 for a frame <paramref name="dt"/> seconds after the last.</summary>
    public double Next(double level, double dt = 1 / 30.0)
    {
        var gated = Math.Max(0, Loudness(level) - Gate) / (1 - Gate);
        // The reference rises at once with louder speech and relaxes over a few seconds (time constant 6 s).
        peak = Math.Max(MinPeak, Math.Max(gated, peak * Math.Exp(-dt / 6)));
        return Math.Min(1, gated / peak);
    }

    public void Reset() => peak = MinPeak;
}
