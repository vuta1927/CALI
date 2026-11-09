using System.Globalization;
using Microsoft.Extensions.Primitives;

namespace Cali.Api.Endpoints;

/// <summary>Strict query-string parsing shared by list endpoints: a repeated parameter is a 400.</summary>
internal static class QueryParameters
{
    /// <summary>False when the parameter is repeated; <paramref name="value"/> is null when absent.</summary>
    public static bool TrySingle(IQueryCollection query, string name, out string? value)
    {
        var values = query.TryGetValue(name, out var v) ? v : StringValues.Empty;
        value = values.Count == 1 ? values[0] : null;
        return values.Count <= 1;
    }

    /// <summary>Optional <c>limit</c>: digits only, between 1 and <paramref name="max"/>.</summary>
    public static bool TryLimit(IQueryCollection query, int defaultLimit, int max, out int limit)
    {
        limit = defaultLimit;
        if (!TrySingle(query, "limit", out var raw))
        {
            return false;
        }

        if (raw is null)
        {
            return true;
        }

        return int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out limit) && limit >= 1 && limit <= max;
    }
}
