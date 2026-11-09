using Cali.Application.Catalog;
using Cali.Domain.Catalog;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>Reads <c>criteria_config_versions</c> (db/008) and <c>indicator_definitions</c> (db/005).</summary>
public sealed class CriteriaConfigReader(NpgsqlDataSource dataSource) : ICriteriaConfigReader
{
    private const string CriteriaSql = """
        SELECT version AS Version, published_at AS PublishedAt, document::text AS DocumentJson
        FROM criteria_config_versions
        WHERE CAST(@version AS integer) IS NULL OR version = @version
        ORDER BY version DESC
        LIMIT 1
        """;

    private const string IndicatorsSql = """
        SELECT id AS Id, version AS Version, kind AS Kind, label AS Label, unit AS Unit, step AS Step,
               aggregation AS Aggregation, measurement_types AS MeasurementTypes, enabled AS Enabled,
               updated_at AS UpdatedAt
        FROM indicator_definitions
        ORDER BY id
        """;

    public async Task<CriteriaConfigVersion?> FindAsync(int? version, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var row = await connection.QuerySingleOrDefaultAsync<CriteriaRow>(
            new CommandDefinition(CriteriaSql, new { version }, cancellationToken: cancellationToken)).ConfigureAwait(false);
        return row is null ? null : new CriteriaConfigVersion(row.Version, Utc(row.PublishedAt), row.DocumentJson);
    }

    public async Task<IndicatorDefinitionSet> GetIndicatorSetAsync(CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var rows = (await connection.QueryAsync<IndicatorRow>(
            new CommandDefinition(IndicatorsSql, cancellationToken: cancellationToken)).ConfigureAwait(false)).AsList();
        if (rows.Count == 0)
        {
            // db/005 seeds the set and rows are never deleted; an empty table is a broken deployment.
            throw new InvalidOperationException("indicator_definitions is empty.");
        }

        var indicators = rows.Select(r => new IndicatorDefinition(
            r.Id, r.Version, r.Kind, r.Label, r.Unit, TrimScale(r.Step), r.Aggregation, r.MeasurementTypes, r.Enabled)).ToArray();
        return new IndicatorDefinitionSet(rows.Sum(r => r.Version), Utc(rows.Max(r => r.UpdatedAt)), indicators);
    }

    // numeric(12,3) arrives as 1.000; drop trailing zeros so the wire matches the bundled config ("step": 1).
    internal static decimal TrimScale(decimal value) => value / 1.000000000000000000000000000000000m;

    private static DateTimeOffset Utc(DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));

    private sealed class CriteriaRow
    {
        public int Version { get; init; }
        public DateTime PublishedAt { get; init; }
        public string DocumentJson { get; init; } = "{}";
    }

    private sealed class IndicatorRow
    {
        public string Id { get; init; } = string.Empty;
        public int Version { get; init; }
        public string Kind { get; init; } = string.Empty;
        public string Label { get; init; } = string.Empty;
        public string Unit { get; init; } = string.Empty;
        public decimal Step { get; init; }
        public string Aggregation { get; init; } = string.Empty;
        public string[] MeasurementTypes { get; init; } = [];
        public bool Enabled { get; init; }
        public DateTime UpdatedAt { get; init; }
    }
}
