namespace Cali.Application.Plans;

/// <summary>Decimal normalization shared by target canonicalization and the idempotency request hash.</summary>
internal static class DecimalText
{
    /// <summary>
    /// Same value with the smallest scale (<c>12.50</c> → <c>12.5</c>, <c>3.0</c> → <c>3</c>), so equal
    /// numbers written differently serialize identically.
    /// </summary>
    public static decimal Normalize(decimal value) => value / 1.0000000000000000000000000000m;
}
