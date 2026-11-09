using System.Globalization;
using Cali.Domain.Catalog;

namespace Cali.Application.Catalog;

public interface ICriteriaConfigReader
{
    /// <summary>The published version <paramref name="version"/>, or the latest one when null; null when not published.</summary>
    Task<CriteriaConfigVersion?> FindAsync(int? version, CancellationToken cancellationToken);

    /// <summary>The current indicator definition set (all rows, enabled or not).</summary>
    Task<IndicatorDefinitionSet> GetIndicatorSetAsync(CancellationToken cancellationToken);
}

/// <summary>Criteria config plus the current indicator set, served under one strong ETag (ADR-066).</summary>
public sealed record CriteriaConfigSnapshot(CriteriaConfigVersion Criteria, IndicatorDefinitionSet Indicators)
{
    /// <summary><c>"c{criteriaVersion}.i{indicatorSetVersion}"</c>, quoted as an HTTP entity tag.</summary>
    public string ETag => string.Create(CultureInfo.InvariantCulture, $"\"c{Criteria.Version}.i{Indicators.Version}\"");
}

/// <summary>Use case behind <c>GET /v1/criteria-config</c>.</summary>
public sealed class GetCriteriaConfig(ICriteriaConfigReader reader)
{
    /// <returns>The snapshot, or null when <paramref name="version"/> is not published.</returns>
    public async Task<CriteriaConfigSnapshot?> ExecuteAsync(int? version, CancellationToken cancellationToken)
    {
        var criteria = await reader.FindAsync(version, cancellationToken).ConfigureAwait(false);
        if (criteria is null)
        {
            return null;
        }

        var indicators = await reader.GetIndicatorSetAsync(cancellationToken).ConfigureAwait(false);
        return new CriteriaConfigSnapshot(criteria, indicators);
    }
}
