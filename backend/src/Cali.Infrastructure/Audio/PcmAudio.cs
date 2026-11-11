using System.Buffers.Binary;

namespace Cali.Infrastructure.Audio;

/// <summary>Mono 16-bit linear PCM samples at <see cref="SampleRate"/> Hz.</summary>
public sealed record PcmAudio(int SampleRate, short[] Samples)
{
    public int DurationMs => (int)Math.Ceiling(Samples.Length * 1000.0 / SampleRate);
}

/// <summary>
/// Reads a RIFF/WAVE file with 16-bit integer PCM (format 1, or WAVE_FORMAT_EXTENSIBLE carrying PCM). Stereo or more is
/// mixed down to mono. Anything else is rejected rather than guessed: the TTS output format must be explicit.
/// </summary>
public static class WavReader
{
    public static PcmAudio Read(ReadOnlySpan<byte> wav)
    {
        if (wav.Length < 12 || !wav[..4].SequenceEqual("RIFF"u8) || !wav.Slice(8, 4).SequenceEqual("WAVE"u8))
        {
            throw new InvalidDataException("Not a RIFF/WAVE file.");
        }

        int? channels = null, sampleRate = null, bits = null;
        ReadOnlySpan<byte> data = default;
        var foundData = false;
        var offset = 12;
        while (offset + 8 <= wav.Length)
        {
            var id = wav.Slice(offset, 4);
            // Streaming encoders may write 0 or 0xFFFFFFFF as the data size; clamp to what is actually present.
            var declared = BinaryPrimitives.ReadUInt32LittleEndian(wav.Slice(offset + 4, 4));
            var body = offset + 8;
            var size = (int)Math.Min(declared, (uint)(wav.Length - body));
            if (id.SequenceEqual("fmt "u8))
            {
                if (size < 16)
                {
                    throw new InvalidDataException("WAVE fmt chunk is too short.");
                }

                var fmt = wav.Slice(body, size);
                var format = BinaryPrimitives.ReadUInt16LittleEndian(fmt);
                channels = BinaryPrimitives.ReadUInt16LittleEndian(fmt[2..]);
                sampleRate = (int)BinaryPrimitives.ReadUInt32LittleEndian(fmt[4..]);
                bits = BinaryPrimitives.ReadUInt16LittleEndian(fmt[14..]);
                var isPcm = format == 1
                    || (format == 0xFFFE && size >= 26 && BinaryPrimitives.ReadUInt16LittleEndian(fmt[24..]) == 1);
                if (!isPcm)
                {
                    throw new InvalidDataException($"WAVE format {format} is not integer PCM.");
                }
            }
            else if (id.SequenceEqual("data"u8))
            {
                data = wav.Slice(body, size);
                foundData = true;
                if (declared == 0 || declared == uint.MaxValue)
                {
                    data = wav[body..];
                }
            }

            if (foundData && channels is not null)
            {
                break;
            }

            // Chunks are word aligned.
            offset = body + size + (size & 1);
        }

        if (channels is not { } ch || sampleRate is not { } rate || bits is not { } bitDepth || !foundData)
        {
            throw new InvalidDataException("WAVE file has no fmt or data chunk.");
        }

        if (bitDepth != 16 || ch < 1 || rate < 8000 || rate > 192000)
        {
            throw new InvalidDataException($"Unsupported WAVE: {bitDepth}-bit, {ch} channel(s), {rate} Hz (need 16-bit PCM).");
        }

        var frames = data.Length / (2 * ch);
        var samples = new short[frames];
        for (var i = 0; i < frames; i++)
        {
            var sum = 0;
            for (var c = 0; c < ch; c++)
            {
                sum += BinaryPrimitives.ReadInt16LittleEndian(data.Slice((i * ch + c) * 2, 2));
            }

            samples[i] = (short)(sum / ch);
        }

        return new PcmAudio(rate, samples);
    }
}
