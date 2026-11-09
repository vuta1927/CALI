namespace Cali.Application.Plans;

/// <summary>
/// Field errors keyed by JSON path (for example <c>workouts[0].exercises[1].target.repMax</c>), in the
/// order they were found. Serialized as the <c>errors</c> member of a <c>validation_failed</c> problem.
/// </summary>
public sealed class ValidationErrors
{
    private readonly Dictionary<string, List<string>> errors = new(StringComparer.Ordinal);

    public bool HasErrors => errors.Count > 0;

    public IEnumerable<string> Fields => errors.Keys;

    public void Add(string field, string message)
    {
        if (!errors.TryGetValue(field, out var messages))
        {
            messages = [];
            errors.Add(field, messages);
        }

        messages.Add(message);
    }

    public IReadOnlyDictionary<string, string[]> ToDictionary() =>
        errors.ToDictionary(e => e.Key, e => e.Value.ToArray(), StringComparer.Ordinal);
}
