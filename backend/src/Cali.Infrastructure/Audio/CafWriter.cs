using System.Buffers.Binary;

namespace Cali.Infrastructure.Audio;

/// <summary>
/// Writes a Core Audio Format file holding mono Apple IMA4 (ADR-077 <c>caf_ima4</c>): <c>caff</c> header, <c>desc</c>
/// chunk and <c>data</c> chunk. IMA4 is constant bit rate, so no packet table is needed; iOS plays the result with
/// AVAudioPlayer and as a UNNotificationSound.
/// </summary>
public static class CafWriter
{
    public static byte[] WriteIma4(PcmAudio audio)
    {
        ArgumentNullException.ThrowIfNull(audio);
        var packets = AppleIma4.Encode(audio.Samples);
        const int fileHeader = 8, descChunk = 12 + 32, dataHeader = 12 + 4;
        var output = new byte[fileHeader + descChunk + dataHeader + packets.Length];
        var span = output.AsSpan();

        "caff"u8.CopyTo(span);
        BinaryPrimitives.WriteUInt16BigEndian(span[4..], 1); // file version
        BinaryPrimitives.WriteUInt16BigEndian(span[6..], 0); // file flags

        var desc = span[fileHeader..];
        "desc"u8.CopyTo(desc);
        BinaryPrimitives.WriteInt64BigEndian(desc[4..], 32);
        BinaryPrimitives.WriteDoubleBigEndian(desc[12..], audio.SampleRate);
        "ima4"u8.CopyTo(desc[20..]);
        BinaryPrimitives.WriteUInt32BigEndian(desc[24..], 0); // format flags
        BinaryPrimitives.WriteUInt32BigEndian(desc[28..], AppleIma4.BytesPerPacket);
        BinaryPrimitives.WriteUInt32BigEndian(desc[32..], AppleIma4.SamplesPerPacket);
        BinaryPrimitives.WriteUInt32BigEndian(desc[36..], 1); // channels
        BinaryPrimitives.WriteUInt32BigEndian(desc[40..], 0); // bits per channel: 0 for compressed formats

        var data = span[(fileHeader + descChunk)..];
        "data"u8.CopyTo(data);
        BinaryPrimitives.WriteInt64BigEndian(data[4..], 4 + packets.Length);
        BinaryPrimitives.WriteUInt32BigEndian(data[12..], 0); // edit count
        packets.CopyTo(data[16..]);
        return output;
    }
}
