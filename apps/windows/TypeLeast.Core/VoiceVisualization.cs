using System;
using System.Buffers.Binary;
using System.Collections.Generic;

namespace TypeLeast.Core;

public readonly record struct VoiceLevel(double Volume, double Signal, double Response, bool HasAudio)
{
    public static VoiceLevel Quiet => new(0, 0, 0.12, false);
}

public static class VoiceResponse
{
    public static double Height(double signal)
    {
        if (signal < 0.03) return 0.12 + signal / 0.03 * 0.18;
        if (signal < 0.10) return 0.36 + 0.42 * (signal - 0.03) / 0.07;
        var t = Math.Min(1, (signal - 0.10) / 0.90);
        return Math.Min(1, (0.55 + 0.40 * Math.Pow(t, 0.25)) * (t > 0.4 ? 1.4 : 1));
    }
}

/// <summary>2048-point Hann FFT, run on the capture callback. No UI-thread audio work.</summary>
public sealed class VoiceSpectrum
{
    private const int Size = 2048;
    private readonly double[] samples = new double[Size], window = new double[Size];
    private readonly double[] real = new double[Size], imaginary = new double[Size], spectrum = new double[Size / 2];
    private readonly double[] cosine = new double[Size / 2], sine = new double[Size / 2], recent = new double[3];
    private readonly int[] reversed = new int[Size];
    private readonly int firstBin, lastBin, hop;
    private readonly double magnitudeScale;
    private int write, count, sinceAnalysis, recentCount, recentIndex;
    private double noiseFloor;
    public VoiceLevel Latest { get; private set; } = VoiceLevel.Quiet;

    public VoiceSpectrum(double sampleRate)
    {
        firstBin = Math.Max(1, (int)Math.Ceiling(328 * Size / sampleRate));
        lastBin = Math.Min(Size / 2 - 1, (int)Math.Floor(3300 * Size / sampleRate));
        hop = Math.Max(1, (int)(sampleRate * 0.05));
        double sum = 0;
        for (var i = 0; i < Size; i++)
        {
            window[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (Size - 1));
            sum += window[i];
            var value = i; var reverse = 0;
            for (var bit = 0; bit < 11; bit++) { reverse = (reverse << 1) | (value & 1); value >>= 1; }
            reversed[i] = reverse;
        }
        magnitudeScale = 2 / sum;
        for (var i = 0; i < Size / 2; i++)
        {
            cosine[i] = Math.Cos(-2 * Math.PI * i / Size);
            sine[i] = Math.Sin(-2 * Math.PI * i / Size);
        }
    }

    public void Consume(ReadOnlySpan<byte> pcm)
    {
        for (var i = 0; i + 1 < pcm.Length; i += 2)
        {
            samples[write] = BinaryPrimitives.ReadInt16LittleEndian(pcm.Slice(i, 2)) / 32768.0;
            write = (write + 1) % Size;
            count = Math.Min(Size, count + 1);
            if (++sinceAnalysis >= hop && count == Size) { sinceAnalysis = 0; Analyse(); }
        }
        if (pcm.Length > 0) Latest = Latest with { HasAudio = true };
    }

    private void Analyse()
    {
        for (var i = 0; i < Size; i++)
        {
            real[reversed[i]] = samples[(write + i) % Size] * window[i];
            imaginary[i] = 0;
        }
        for (var size = 2; size <= Size; size *= 2)
        {
            var half = size / 2; var stride = Size / size;
            for (var start = 0; start < Size; start += size)
                for (var offset = 0; offset < half; offset++)
                {
                    var a = start + offset; var b = a + half; var twiddle = offset * stride;
                    var re = real[b] * cosine[twiddle] - imaginary[b] * sine[twiddle];
                    var im = real[b] * sine[twiddle] + imaginary[b] * cosine[twiddle];
                    real[b] = real[a] - re; imaginary[b] = imaginary[a] - im;
                    real[a] += re; imaginary[a] += im;
                }
        }
        double energy = 0;
        for (var bin = firstBin; bin <= lastBin; bin++)
        {
            var magnitude = Math.Sqrt(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) * magnitudeScale;
            spectrum[bin] = spectrum[bin] * 0.7 + magnitude * 0.3;
            var db = 20 * Math.Log10(Math.Max(1e-8, spectrum[bin]));
            energy += Math.Clamp((db + 100) / 70, 0, 1);
        }
        energy /= Math.Max(1, lastBin - firstBin + 1);
        recent[recentIndex] = energy;
        recentIndex = (recentIndex + 1) % recent.Length;
        recentCount = Math.Min(recent.Length, recentCount + 1);
        var volume = (recent[0] + recent[1] + recent[2]) / recentCount;
        var alpha = volume <= noiseFloor + 0.01 ? 0.06 : 0.002;
        noiseFloor = Math.Clamp(noiseFloor * (1 - alpha) + volume * alpha, 0, 0.35);
        var signal = Math.Max(0, volume - noiseFloor - 0.006);
        Latest = new VoiceLevel(volume, signal, VoiceResponse.Height(signal), true);
    }
}

/// <summary>Microphone-driven centre impulses, delayed propagation and time-based decay.</summary>
public sealed class VoiceWaveform
{
    public const int Count = 10;
    private sealed class Impulse
    {
        public double Due, Centre, Height;
        public int Applied;
    }
    private readonly double[] heights = new double[Count], opacities = new double[Count], ages = new double[Count];
    private readonly double[] drawnHeights = new double[Count], drawnOpacities = new double[Count];
    private readonly List<Impulse> impulses = new();
    private double time, injectionTime, capturedFor, currentHeight = 2;
    private ulong randomState = 0x746970656C656173;
    public double Height(int index) => heights[index];
    public double Opacity(int index) => opacities[index];

    public VoiceWaveform() => Reset();
    public void Reset()
    {
        Array.Fill(heights, 2); Array.Fill(opacities, 0.5); Array.Fill(drawnHeights, 2); Array.Fill(drawnOpacities, 0.5); Array.Clear(ages); impulses.Clear();
        time = injectionTime = capturedFor = 0; currentHeight = 2; randomState = 0x746970656C656173;
    }
    private double Random()
    {
        randomState = unchecked(randomState * 6364136223846793005UL + 1442695040888963407UL);
        return (randomState >> 11) / 9007199254740992.0;
    }
    public bool Advance(VoiceLevel level, double delta, bool reduceMotion)
    {
        var dt = Math.Clamp(delta, 0, 0.1);
        time += dt;
        capturedFor = level.HasAudio ? capturedFor + dt : 0;
        const double centre = (Count - 1) / 2.0;
        var active = level.HasAudio && level.Signal > 0.003;
        var target = active ? 2 + 16 * level.Response : 2;
        currentHeight += (target - currentHeight) * (1 - Math.Pow(0.15, dt * 60));
        var dirty = false;
        for (var i = 0; i < Count; i++)
        {
            var distance = Math.Abs(i - centre);
            opacities[i] = level.HasAudio ? 0.5 + 0.5 * Math.Clamp((capturedFor - distance * 0.05) / 0.12, 0, 1) : 0.5;
            if (reduceMotion) heights[i] = active ? 2 + (target - 2) * Math.Max(0.25, 1 - distance / (centre + 0.5) * 0.7) : 2;
            else
            {
                ages[i] += dt;
                var release = 0.15 + distance / (centre + 0.5) * 0.06;
                heights[i] = 2 + (heights[i] - 2) * Math.Exp(-dt / release);
                if (ages[i] > 1.1 || heights[i] < 2.05) heights[i] = 2;
            }
        }
        if (reduceMotion) impulses.Clear();
        else
        {
            injectionTime += dt;
            if (injectionTime >= 0.05)
            {
                injectionTime %= 0.05;
                if (active)
                {
                    var variation = level.Signal < 0.03 ? 0.02 : level.Signal < 0.10 ? 0.10 : 0.15;
                    var height = Math.Clamp(currentHeight + (Random() * 2 - 1) * variation * 16, 2, 20);
                    for (var i = Count / 2 - 1; i <= Count / 2; i++)
                    {
                        dirty |= Math.Abs(heights[i] - Math.Max(heights[i], currentHeight)) >= 0.05;
                        heights[i] = Math.Max(heights[i], currentHeight); ages[i] = 0;
                    }
                    if (level.Signal >= 0.07 && Random() < Math.Min(0.8, level.Signal * 2))
                        impulses.Add(new Impulse { Due = time + 0.08, Centre = centre + (Random() * 2 - 1) * Math.Min(Count * 0.15, 3), Height = height });
                }
            }
            foreach (var impulse in impulses)
                for (var i = 0; i < Count; i++)
                {
                    var bit = 1 << i;
                    if ((impulse.Applied & bit) != 0) continue;
                    var distance = Math.Abs(i - impulse.Centre);
                    if (time < impulse.Due + distance * 0.014) continue;
                    var decay = Math.Max(0.12, 1 - distance / (centre + 0.5) * 0.70);
                    var height = Math.Clamp(impulse.Height * decay * (0.9 + Random() * 0.2), 2, 20);
                    heights[i] = Math.Max(height, heights[i] * 0.3 + height * 0.7);
                    ages[i] = 0; impulse.Applied |= bit; dirty = true;
                }
            impulses.RemoveAll(impulse => impulse.Applied == (1 << Count) - 1);
        }
        for (var i = 0; i < Count; i++)
            dirty |= Math.Abs(drawnHeights[i] - heights[i]) >= 0.05 || Math.Abs(drawnOpacities[i] - opacities[i]) >= 0.01;
        if (dirty) { Array.Copy(heights, drawnHeights, Count); Array.Copy(opacities, drawnOpacities, Count); }
        return dirty;
    }
}
