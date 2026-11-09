namespace Cali.Domain.Catalog;

/// <summary>
/// A published, immutable criteria config version (<c>criteria_config_versions</c>, CON-008).
/// <see cref="DocumentJson"/> is the stored <c>{supportedTypes, criteria}</c> object.
/// </summary>
public sealed record CriteriaConfigVersion(int Version, DateTimeOffset PublishedAt, string DocumentJson);

/// <summary>
/// The current indicator definition set (ADR-058). <see cref="Version"/> = sum of the row versions,
/// <see cref="PublishedAt"/> = latest row <c>updated_at</c>.
/// </summary>
public sealed record IndicatorDefinitionSet(int Version, DateTimeOffset PublishedAt, IReadOnlyList<IndicatorDefinition> Indicators);

public sealed record IndicatorDefinition(
    string Id,
    int Version,
    string Kind,
    string Label,
    string Unit,
    decimal Step,
    string Aggregation,
    IReadOnlyList<string> MeasurementTypes,
    bool Enabled);
