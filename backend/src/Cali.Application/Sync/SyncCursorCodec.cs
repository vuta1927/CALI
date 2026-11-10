using System.Buffers.Binary;
using System.Buffers.Text;
using System.Security.Cryptography;

namespace Cali.Application.Sync;

/// <summary>
/// Opaque, user-bound, tamper-evident position in a user's change feed (ADR-070).
/// Wire form: base64url of <c>version (1 byte) | seq (int64, big endian) | userId (16 bytes) | HMAC-SHA256</c>
/// over the first 25 bytes. A cursor only decodes for the user it was issued to, so replaying another
/// user's cursor is a decode failure rather than a read of that user's feed. <c>changeId</c> on a change
/// uses the same form, so any change id can be passed back as <c>cursor</c> to resume right after it.
/// </summary>
public sealed class SyncCursorCodec
{
    public const int MinKeyBytes = 32;

    private const byte Version = 1;
    private const int SeqOffset = 1;
    private const int UserOffset = SeqOffset + sizeof(long);
    private const int BodyLength = UserOffset + 16;
    private const int MacLength = 32;
    private const int TokenLength = BodyLength + MacLength;
    private const int MaxEncodedLength = 128;

    private readonly byte[] _key;

    public SyncCursorCodec(byte[] key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.Length < MinKeyBytes)
        {
            throw new ArgumentException($"The cursor signing key must be at least {MinKeyBytes} bytes.", nameof(key));
        }

        _key = (byte[])key.Clone();
    }

    /// <summary>The feed position "everything up to and including <paramref name="seq"/> was applied" (0 = nothing).</summary>
    public string Encode(Guid userId, long seq)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(seq);

        Span<byte> token = stackalloc byte[TokenLength];
        token[0] = Version;
        BinaryPrimitives.WriteInt64BigEndian(token.Slice(SeqOffset, sizeof(long)), seq);
        userId.TryWriteBytes(token.Slice(UserOffset, 16), bigEndian: true, out _);
        HMACSHA256.HashData(_key, token[..BodyLength], token[BodyLength..]);
        return Base64Url.EncodeToString(token);
    }

    /// <summary>False for anything that is not a cursor this server issued to <paramref name="userId"/>.</summary>
    public bool TryDecode(string? value, Guid userId, out long seq)
    {
        seq = 0;
        if (string.IsNullOrEmpty(value) || value.Length > MaxEncodedLength)
        {
            return false;
        }

        // TryDecodeFromChars only reports a short destination; invalid characters throw, so check them first.
        if (!Base64Url.IsValid(value))
        {
            return false;
        }

        Span<byte> token = stackalloc byte[TokenLength];
        if (!Base64Url.TryDecodeFromChars(value, token, out var written) || written != TokenLength || token[0] != Version)
        {
            return false;
        }

        Span<byte> expected = stackalloc byte[MacLength];
        HMACSHA256.HashData(_key, token[..BodyLength], expected);
        if (!CryptographicOperations.FixedTimeEquals(expected, token[BodyLength..]))
        {
            return false;
        }

        var decoded = BinaryPrimitives.ReadInt64BigEndian(token.Slice(SeqOffset, sizeof(long)));
        if (decoded < 0 || new Guid(token.Slice(UserOffset, 16), bigEndian: true) != userId)
        {
            return false;
        }

        seq = decoded;
        return true;
    }
}
