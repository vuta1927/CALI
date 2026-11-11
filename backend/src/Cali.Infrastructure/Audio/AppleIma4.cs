using System.Buffers.Binary;

namespace Cali.Infrastructure.Audio;

/// <summary>
/// Apple IMA4 ADPCM (Core Audio format <c>ima4</c>), mono. Each packet is 34 bytes and holds 64 samples: a big-endian
/// 16-bit header whose upper 9 bits are the predictor and lower 7 bits the step index, then 32 bytes of 4-bit codes,
/// low nibble first. The decoder restarts from the header at every packet, so the encoder truncates its predictor the
/// same way at each packet start to stay in step with it.
/// </summary>
public static class AppleIma4
{
    public const int SamplesPerPacket = 64;
    public const int BytesPerPacket = 34;

    private static readonly int[] IndexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

    private static readonly int[] StepTable =
    [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ];

    /// <summary>Encodes <paramref name="samples"/>; the last packet is padded with silence.</summary>
    public static byte[] Encode(ReadOnlySpan<short> samples)
    {
        var packets = (samples.Length + SamplesPerPacket - 1) / SamplesPerPacket;
        var output = new byte[packets * BytesPerPacket];
        var predictor = 0;
        var index = 0;
        for (var p = 0; p < packets; p++)
        {
            var packet = output.AsSpan(p * BytesPerPacket, BytesPerPacket);
            predictor = (short)(predictor & 0xFF80);
            BinaryPrimitives.WriteUInt16BigEndian(packet, (ushort)((predictor & 0xFF80) | index));
            for (var i = 0; i < SamplesPerPacket; i++)
            {
                var s = p * SamplesPerPacket + i;
                var sample = s < samples.Length ? samples[s] : (short)0;
                var code = EncodeSample(sample, ref predictor, ref index);
                if ((i & 1) == 0)
                {
                    packet[2 + (i >> 1)] = (byte)code;
                }
                else
                {
                    packet[2 + (i >> 1)] |= (byte)(code << 4);
                }
            }
        }

        return output;
    }

    /// <summary>Decodes packets back to PCM (used by tests and to check an encoded file).</summary>
    public static short[] Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length % BytesPerPacket != 0)
        {
            throw new InvalidDataException("IMA4 data is not a whole number of packets.");
        }

        var packets = data.Length / BytesPerPacket;
        var output = new short[packets * SamplesPerPacket];
        for (var p = 0; p < packets; p++)
        {
            var packet = data.Slice(p * BytesPerPacket, BytesPerPacket);
            var header = BinaryPrimitives.ReadUInt16BigEndian(packet);
            int predictor = (short)(header & 0xFF80);
            var index = Math.Min(header & 0x7F, StepTable.Length - 1);
            for (var i = 0; i < SamplesPerPacket; i++)
            {
                var b = packet[2 + (i >> 1)];
                var code = (i & 1) == 0 ? b & 0x0F : b >> 4;
                output[p * SamplesPerPacket + i] = (short)DecodeCode(code, ref predictor, ref index);
            }
        }

        return output;
    }

    private static int EncodeSample(short sample, ref int predictor, ref int index)
    {
        var step = StepTable[index];
        var diff = sample - predictor;
        var code = 0;
        if (diff < 0)
        {
            code = 8;
            diff = -diff;
        }

        if (diff >= step)
        {
            code |= 4;
            diff -= step;
        }

        if (diff >= step >> 1)
        {
            code |= 2;
            diff -= step >> 1;
        }

        if (diff >= step >> 2)
        {
            code |= 1;
        }

        // Reconstruct exactly as the decoder does, so both sides keep the same state.
        DecodeCode(code, ref predictor, ref index);
        return code;
    }

    private static int DecodeCode(int code, ref int predictor, ref int index)
    {
        var step = StepTable[index];
        var delta = step >> 3;
        if ((code & 4) != 0)
        {
            delta += step;
        }

        if ((code & 2) != 0)
        {
            delta += step >> 1;
        }

        if ((code & 1) != 0)
        {
            delta += step >> 2;
        }

        predictor = Math.Clamp((code & 8) != 0 ? predictor - delta : predictor + delta, short.MinValue, short.MaxValue);
        index = Math.Clamp(index + IndexTable[code], 0, StepTable.Length - 1);
        return predictor;
    }
}
