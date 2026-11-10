using System.Globalization;
using System.Text.Json;
using Cali.Application.Plans;

namespace Cali.Application.Sync;

/// <summary>
/// Batch-level validation of <c>POST /v1/sync/push</c> (OpenAPI SyncPushRequest, <c>mutation_common</c>):
/// the root and every envelope. A failure here is a 400 for the whole batch; payload problems are not
/// checked here and become per-mutation receipts instead (ADR-069).
/// </summary>
public static class SyncPushRequestParser
{
    public const int MaxMutations = 100;

    private static readonly string[] Actions = [SyncActions.Upsert, SyncActions.Delete];

    public static SyncPushBatch? Parse(JsonElement root, ValidationErrors errors)
    {
        ArgumentNullException.ThrowIfNull(errors);
        if (root.ValueKind != JsonValueKind.Object)
        {
            errors.Add("$", "Must be a SyncPushRequest object.");
            return null;
        }

        var reader = new PayloadReader(root, errors);
        var deviceId = reader.Uuid("deviceId", null, required: true);
        var mutations = new List<SyncMutation>();
        if (reader.Raw("mutations") is not { } list)
        {
            errors.Add("mutations", PlanValidator.Required);
        }
        else if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() is < 1 or > MaxMutations)
        {
            errors.Add("mutations", string.Create(CultureInfo.InvariantCulture, $"Must be an array of 1 to {MaxMutations} mutations."));
        }
        else
        {
            var index = 0;
            foreach (var item in list.EnumerateArray())
            {
                if (ParseMutation(item, string.Create(CultureInfo.InvariantCulture, $"mutations[{index}]"), errors) is { } mutation)
                {
                    mutations.Add(mutation);
                }

                index++;
            }
        }

        reader.Finish();
        return errors.HasErrors || deviceId is null ? null : new SyncPushBatch(deviceId.Value, mutations);
    }

    private static SyncMutation? ParseMutation(JsonElement item, string path, ValidationErrors errors)
    {
        if (item.ValueKind != JsonValueKind.Object)
        {
            errors.Add(path, "Must be a SyncMutation object.");
            return null;
        }

        var local = new ValidationErrors();
        var reader = new PayloadReader(item, local);
        var mutationId = reader.Uuid("mutationId", null, required: true);
        var entityType = reader.Text("entityType", null, required: true, minLength: 1, maxLength: 64);
        var entityId = reader.Uuid("entityId", null, required: true);
        var action = reader.Enum("action", null, required: true, Actions);
        var baseVersion = reader.Integer("baseVersion", null, required: true, 0, long.MaxValue);
        var clientChangedAt = reader.DateTime("clientChangedAt", null, required: true);
        var payload = reader.Raw("payload");
        if (payload is null)
        {
            local.Add("payload", PlanValidator.Required);
        }
        else if (payload.Value.ValueKind != JsonValueKind.Object)
        {
            local.Add("payload", "Must be an object.");
        }

        reader.Finish();
        foreach (var (field, messages) in local.ToDictionary())
        {
            foreach (var message in messages)
            {
                errors.Add($"{path}.{field}", message);
            }
        }

        return local.HasErrors
            ? null
            : new SyncMutation(mutationId!.Value, entityType!, entityId!.Value, action!, baseVersion!.Value, clientChangedAt!.Value, payload!.Value.Clone());
    }
}
