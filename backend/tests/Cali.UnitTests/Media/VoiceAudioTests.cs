using System.Buffers.Binary;
using Cali.Infrastructure.Audio;

namespace Cali.UnitTests.Media;

/// <summary>BE-007: WAV input, Apple IMA4 encoding and the CAF container used for voice cues (ADR-077).</summary>
public sealed class VoiceAudioTests
{
    private static short[] Sine(int sampleRate, double seconds, double hz = 440, double amplitude = 12000) =>
        Enumerable.Range(0, (int)(sampleRate * seconds))
            .Select(i => (short)Math.Round(amplitude * Math.Sin(2 * Math.PI * hz * i / sampleRate)))
            .ToArray();

    internal static byte[] Wav(int sampleRate, short[] samples, int channels = 1, ushort format = 1, ushort bits = 16, bool streamingSizes = false)
    {
        var dataBytes = samples.Length * channels * 2;
        var wav = new byte[44 + dataBytes];
        var s = wav.AsSpan();
        "RIFF"u8.CopyTo(s);
        BinaryPrimitives.WriteUInt32LittleEndian(s[4..], streamingSizes ? uint.MaxValue : (uint)(36 + dataBytes));
        "WAVE"u8.CopyTo(s[8..]);
        "fmt "u8.CopyTo(s[12..]);
        BinaryPrimitives.WriteUInt32LittleEndian(s[16..], 16);
        BinaryPrimitives.WriteUInt16LittleEndian(s[20..], format);
        BinaryPrimitives.WriteUInt16LittleEndian(s[22..], (ushort)channels);
        BinaryPrimitives.WriteUInt32LittleEndian(s[24..], (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(s[28..], (uint)(sampleRate * channels * 2));
        BinaryPrimitives.WriteUInt16LittleEndian(s[32..], (ushort)(channels * 2));
        BinaryPrimitives.WriteUInt16LittleEndian(s[34..], bits);
        "data"u8.CopyTo(s[36..]);
        BinaryPrimitives.WriteUInt32LittleEndian(s[40..], streamingSizes ? uint.MaxValue : (uint)dataBytes);
        for (var i = 0; i < samples.Length; i++)
        {
            for (var c = 0; c < channels; c++)
            {
                BinaryPrimitives.WriteInt16LittleEndian(s[(44 + (i * channels + c) * 2)..], samples[i]);
            }
        }

        return wav;
    }

    [Fact]
    public void Wav_reader_reads_mono_and_mixes_stereo_down()
    {
        var samples = new short[] { 0, 1000, -1000, short.MaxValue, short.MinValue };

        WavReader.Read(Wav(22050, samples)).ShouldBe(new PcmAudio(22050, samples), new PcmComparer());
        var stereo = WavReader.Read(Wav(48000, samples, channels: 2));
        stereo.SampleRate.ShouldBe(48000);
        stereo.Samples.ShouldBe(samples);
    }

    [Fact]
    public void Wav_reader_accepts_streaming_sizes()
    {
        var samples = Sine(16000, 0.1);

        WavReader.Read(Wav(16000, samples, streamingSizes: true)).Samples.ShouldBe(samples);
    }

    [Theory]
    [InlineData((ushort)3, (ushort)16)] // IEEE float
    [InlineData((ushort)1, (ushort)8)]
    [InlineData((ushort)1, (ushort)24)]
    public void Wav_reader_rejects_formats_it_would_have_to_guess(ushort format, ushort bits) =>
        Should.Throw<InvalidDataException>(() => WavReader.Read(Wav(22050, [1, 2, 3], format: format, bits: bits)));

    [Fact]
    public void Wav_reader_rejects_non_wave_data() =>
        Should.Throw<InvalidDataException>(() => WavReader.Read("ID3\u0004 not a wav file at all"u8.ToArray()));

    [Fact]
    public void Ima4_round_trip_keeps_speech_band_audio_recognisable()
    {
        var samples = Sine(22050, 1.0, hz: 440).Zip(Sine(22050, 1.0, hz: 1800, amplitude: 4000), (a, b) => (short)(a + b)).ToArray();

        var encoded = AppleIma4.Encode(samples);
        var decoded = AppleIma4.Decode(encoded);

        encoded.Length.ShouldBe((samples.Length + 63) / 64 * 34);
        decoded.Length.ShouldBeGreaterThanOrEqualTo(samples.Length);
        // ADPCM is lossy; a correct encoder/decoder pair gives a signal-to-noise ratio well above 20 dB on tones.
        double signal = 0, noise = 0;
        for (var i = 0; i < samples.Length; i++)
        {
            signal += (double)samples[i] * samples[i];
            noise += (double)(samples[i] - decoded[i]) * (samples[i] - decoded[i]);
        }

        (10 * Math.Log10(signal / noise)).ShouldBeGreaterThan(20);
        // Padding of the last packet is silence-ish, never noise.
        decoded.Skip(samples.Length).ShouldAllBe(s => Math.Abs((int)s) < 2000);
    }

    [Fact]
    public void Ima4_packet_header_carries_the_truncated_predictor_and_step_index()
    {
        var encoded = AppleIma4.Encode(Sine(22050, 0.01, amplitude: 20000));

        var second = BinaryPrimitives.ReadUInt16BigEndian(encoded.AsSpan(34, 2));
        (second & 0x7F).ShouldBeLessThanOrEqualTo(88);
        // First packet starts from silence.
        BinaryPrimitives.ReadUInt16BigEndian(encoded).ShouldBe((ushort)0);
    }

    [Fact]
    public void Caf_file_has_an_ima4_description_and_the_packets()
    {
        var audio = new PcmAudio(22050, Sine(22050, 0.5));

        var caf = CafWriter.WriteIma4(audio);
        var s = caf.AsSpan();

        s[..4].SequenceEqual("caff"u8).ShouldBeTrue();
        BinaryPrimitives.ReadUInt16BigEndian(s[4..]).ShouldBe((ushort)1);
        s.Slice(8, 4).SequenceEqual("desc"u8).ShouldBeTrue();
        BinaryPrimitives.ReadInt64BigEndian(s[12..]).ShouldBe(32);
        BinaryPrimitives.ReadDoubleBigEndian(s[20..]).ShouldBe(22050d);
        s.Slice(28, 4).SequenceEqual("ima4"u8).ShouldBeTrue();
        BinaryPrimitives.ReadUInt32BigEndian(s[36..]).ShouldBe(34u);
        BinaryPrimitives.ReadUInt32BigEndian(s[40..]).ShouldBe(64u);
        BinaryPrimitives.ReadUInt32BigEndian(s[44..]).ShouldBe(1u);
        s.Slice(52, 4).SequenceEqual("data"u8).ShouldBeTrue();
        var dataSize = BinaryPrimitives.ReadInt64BigEndian(s[56..]);
        dataSize.ShouldBe(caf.Length - 64); // edit count (4) + packets
        AppleIma4.Decode(s[68..]).Length.ShouldBe((audio.Samples.Length + 63) / 64 * 64);
        audio.DurationMs.ShouldBe(500);

        // Manual check on a Mac: CALI_CAF_OUT=/tmp/x.caf dotnet test ... then `afinfo /tmp/x.caf` and `afplay /tmp/x.caf`.
        if (Environment.GetEnvironmentVariable("CALI_CAF_OUT") is { Length: > 0 } path)
        {
            File.WriteAllBytes(path, caf);
        }
    }

    private sealed class PcmComparer : IEqualityComparer<PcmAudio>
    {
        public bool Equals(PcmAudio? x, PcmAudio? y) =>
            x is not null && y is not null && x.SampleRate == y.SampleRate && x.Samples.SequenceEqual(y.Samples);

        public int GetHashCode(PcmAudio obj) => obj.SampleRate;
    }
}
