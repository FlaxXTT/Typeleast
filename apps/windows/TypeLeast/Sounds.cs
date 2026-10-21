using System;
using System.IO;
using System.Media;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>The start and stop cues, made once in memory (Chimes) and played without blocking.</summary>
internal static class Sounds
{
    private static readonly Lazy<SoundPlayer?> start = new(() => Load(Chimes.Start()));
    private static readonly Lazy<SoundPlayer?> stop = new(() => Load(Chimes.Stop()));

    public static void Start() => Play(start.Value);
    public static void Stop() => Play(stop.Value);

    private static SoundPlayer? Load(byte[] wav)
    {
        try { var player = new SoundPlayer(new MemoryStream(wav)); player.Load(); return player; }
        catch (Exception e) { Log.Write("sound.load.fail", e.GetType().Name); return null; }
    }

    private static void Play(SoundPlayer? player)
    {
        try { player?.Play(); }
        catch (Exception e) { Log.Write("sound.play.fail", e.GetType().Name); }
    }
}
