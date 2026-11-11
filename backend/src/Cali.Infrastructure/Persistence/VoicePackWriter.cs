using Cali.Application.VoicePublishing;
using Cali.Domain.Catalog;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>Publishes a voice pack (db/011): the version row and every cue in one transaction, as the insert guard requires.</summary>
public sealed class VoicePackWriter(NpgsqlDataSource dataSource) : IVoicePackWriter
{
    public async Task PublishAsync(VoicePack pack, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(pack);
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await using (var version = new NpgsqlCommand(
                "INSERT INTO voice_pack_versions (locale, version, published_at, voice) VALUES ($1, $2, $3, $4)", connection, transaction))
            {
                version.Parameters.Add(new() { Value = pack.Locale });
                version.Parameters.Add(new() { Value = pack.Version });
                version.Parameters.Add(new() { Value = pack.PublishedAt.UtcDateTime });
                version.Parameters.Add(new() { Value = pack.Voice });
                await version.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            }

            foreach (var cue in pack.Cues)
            {
                await using var insert = new NpgsqlCommand("""
                    INSERT INTO voice_cues (locale, version, cue_key, text, storage_key, format, sha256, byte_size, duration_ms)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                    """, connection, transaction);
                insert.Parameters.Add(new() { Value = pack.Locale });
                insert.Parameters.Add(new() { Value = pack.Version });
                insert.Parameters.Add(new() { Value = cue.Key });
                insert.Parameters.Add(new() { Value = cue.Text });
                insert.Parameters.Add(new() { Value = cue.StorageKey });
                insert.Parameters.Add(new() { Value = cue.Format });
                insert.Parameters.Add(new() { Value = cue.Sha256 });
                insert.Parameters.Add(new() { Value = cue.ByteSize });
                insert.Parameters.Add(new() { Value = cue.DurationMs });
                await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            }

            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation && e.TableName == "voice_pack_versions")
        {
            throw new VoicePackConflictException(pack.Locale, pack.Version);
        }
    }
}
