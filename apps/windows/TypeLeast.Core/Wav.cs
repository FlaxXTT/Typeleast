namespace TypeLeast.Core;

/// <summary>The one WAV shape the service accepts: 16 kHz mono 16-bit PCM, 44-byte header.</summary>
public static class Wav
{
    public const int SampleRate = 16000;
    public const int HeaderBytes = 44;
    public const int BytesPerSecond = SampleRate * 2;

    public static byte[] FromPcm16(ReadOnlySpan<byte> pcm)
    {
        var data = pcm.Length - pcm.Length % 2;
        var wav = new byte[HeaderBytes + data];
        void Ascii(int at, string s) { for (var i = 0; i < 4; i++) wav[at + i] = (byte)s[i]; }
        void U32(int at, uint v) => BitConverter.TryWriteBytes(wav.AsSpan(at, 4), v);
        void U16(int at, ushort v) => BitConverter.TryWriteBytes(wav.AsSpan(at, 2), v);
        Ascii(0, "RIFF"); U32(4, (uint)(36 + data)); Ascii(8, "WAVE");
        Ascii(12, "fmt "); U32(16, 16); U16(20, 1); U16(22, 1);
        U32(24, SampleRate); U32(28, BytesPerSecond); U16(32, 2); U16(34, 16);
        Ascii(36, "data"); U32(40, (uint)data);
        pcm[..data].CopyTo(wav.AsSpan(HeaderBytes));
        return wav;
    }

    public static bool IsCanonical(ReadOnlySpan<byte> wav)
    {
        if (wav.Length < HeaderBytes) return false;
        static string Tag(ReadOnlySpan<byte> b) => System.Text.Encoding.ASCII.GetString(b);
        return Tag(wav[..4]) == "RIFF" && Tag(wav[8..12]) == "WAVE" && Tag(wav[12..16]) == "fmt " && Tag(wav[36..40]) == "data"
            && BitConverter.ToUInt16(wav[20..22]) == 1 && BitConverter.ToUInt16(wav[22..24]) == 1
            && BitConverter.ToUInt32(wav[24..28]) == SampleRate && BitConverter.ToUInt16(wav[34..36]) == 16
            && HeaderBytes + BitConverter.ToUInt32(wav[40..44]) == wav.Length;
    }

    public static double Seconds(int pcmBytes) => pcmBytes / (double)BytesPerSecond;

    /// <summary>Loudness of 16-bit samples, 0..1, for the level bars.</summary>
    public static double Level(ReadOnlySpan<byte> pcm)
    {
        var count = pcm.Length / 2;
        if (count == 0) return 0;
        double sum = 0;
        for (var i = 0; i < count; i++)
        {
            var s = BitConverter.ToInt16(pcm.Slice(i * 2, 2)) / 32768.0;
            sum += s * s;
        }
        var rms = Math.Sqrt(sum / count);
        return Math.Clamp(rms * 6, 0, 1);
    }
}
