using System.Text.Json;
using Cali.Application.Plans;
using Cali.Domain.Catalog;
using Cali.Tests.Shared;

namespace Cali.UnitTests.Plans;

/// <summary>B1 (BE-002): plan validation, cursor, request hash (ADR-068) — no database.</summary>
public sealed class PlanTests
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);

    // fixtures/validation/business_rules.json catalog ids (aaaa…N).
    private static Guid Catalog(int n) => Guid.Parse($"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa{n}");

    private static readonly IReadOnlyDictionary<Guid, string> CatalogTypes = new Dictionary<Guid, string>
    {
        [Catalog(1)] = "static_hold",
        [Catalog(2)] = "reps",
        [Catalog(3)] = "reps",
        [Catalog(4)] = "static_hold",
        [Catalog(5)] = "reps",
        [Catalog(6)] = "static_hold",
        [Catalog(7)] = "distance",
        [Catalog(8)] = "duration",
        [Catalog(9)] = "load",
    };

    private static JsonElement Json(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    public static TheoryData<string> PlannedExerciseRuleCases()
    {
        var data = new TheoryData<string>();
        foreach (var c in BusinessRuleCases().Where(c => c.GetProperty("mutation").GetProperty("entityType").GetString() == "planned_exercise"))
        {
            data.Add(c.GetProperty("name").GetString()!);
        }

        return data;
    }

    private static IEnumerable<JsonElement> BusinessRuleCases()
    {
        var path = Path.Combine(RepoPaths.RepoRoot, "fixtures", "validation", "business_rules.json");
        return Json(File.ReadAllText(path)).GetProperty("cases").EnumerateArray();
    }

    [Theory]
    [MemberData(nameof(PlannedExerciseRuleCases))]
    public void Planned_exercise_business_rules_reject_at_the_fixture_field(string name)
    {
        // docs/06: direct writes and sync push share validation, so the sync fixtures apply here too.
        var c = BusinessRuleCases().Single(x => x.GetProperty("name").GetString() == name);
        var expect = c.GetProperty("expect");
        var input = c.GetProperty("mutation").GetProperty("payload").Deserialize<PlannedExerciseInput>(Web)!;
        var errors = new ValidationErrors();

        PlanValidator.ValidateExercise(input, CatalogTypes, prefix: "", errors).ShouldBeNull();

        expect.GetProperty("code").GetString().ShouldBe("validation_failed");
        errors.Fields.ShouldContain(expect.GetProperty("field").GetString()!);
    }

    [Fact]
    public void Business_rule_fixtures_cover_the_planned_exercise_rules()
    {
        PlannedExerciseRuleCases().Count.ShouldBeGreaterThanOrEqualTo(4);
    }

    [Fact]
    public void Target_kinds_match_catalog_exercise_types()
    {
        PlanValidator.TargetKinds.ToHashSet().SetEquals(ExerciseTypes.All).ShouldBeTrue();
    }

    [Theory]
    [InlineData(2, """{"repMax":8,"kind":"reps","repMin":5}""", """{"kind":"reps","repMin":5,"repMax":8}""")]
    [InlineData(9, """{"loadKg":12.50,"reps":5,"kind":"load"}""", """{"kind":"load","reps":5,"loadKg":12.5}""")]
    [InlineData(7, """{"kind":"distance","distanceMeters":5000}""", """{"kind":"distance","distanceMeters":5000}""")]
    [InlineData(7, """{"durationSeconds":1800,"kind":"distance","distanceMeters":5000}""", """{"kind":"distance","distanceMeters":5000,"durationSeconds":1800}""")]
    [InlineData(1, """{"kind":"static_hold","holdSeconds":12}""", """{"kind":"static_hold","holdSeconds":12}""")]
    public void Valid_targets_are_normalized(int catalog, string target, string expected)
    {
        var errors = new ValidationErrors();

        var normalized = PlanValidator.NormalizeTarget(Json(target), CatalogTypes[Catalog(catalog)], "", errors);

        errors.HasErrors.ShouldBeFalse(string.Join(", ", errors.Fields));
        normalized!.Value.GetRawText().ShouldBe(expected);
    }

    [Theory]
    [InlineData(2, """{"kind":"reps","repMin":5}""", "target.repMax")]
    [InlineData(2, """{"kind":"reps","repMin":0,"repMax":5}""", "target.repMin")]
    [InlineData(2, """{"kind":"reps","repMin":5,"repMax":8,"holdSeconds":3}""", "target.holdSeconds")]
    [InlineData(2, """{"kind":"reps","repMin":5,"repMin":6,"repMax":8}""", "target.repMin")]
    [InlineData(2, """{"kind":"reps","repMin":5.5,"repMax":8}""", "target.repMin")]
    [InlineData(9, """{"kind":"load","reps":5,"loadKg":10.125}""", "target.loadKg")]
    [InlineData(9, """{"kind":"load","reps":5,"loadKg":-1}""", "target.loadKg")]
    [InlineData(1, """{"kind":"hover","holdSeconds":3}""", "target.kind")]
    [InlineData(1, """[]""", "target")]
    public void Invalid_targets_report_the_offending_field(int catalog, string target, string field)
    {
        var errors = new ValidationErrors();

        PlanValidator.NormalizeTarget(Json(target), CatalogTypes[Catalog(catalog)], "", errors).ShouldBeNull();

        errors.Fields.ShouldContain(field);
    }

    [Fact]
    public void Unpublished_exercise_reference_is_rejected()
    {
        var input = new PlannedExerciseInput(Guid.NewGuid(), Guid.NewGuid(), 0, 3, Json("""{"kind":"reps","repMin":5,"repMax":8}"""), 90);
        var errors = new ValidationErrors();

        PlanValidator.ValidateExercise(input, CatalogTypes, "", errors).ShouldBeNull();

        errors.Fields.ShouldContain("exerciseId");
    }

    private static CreatePlanInput ValidPlan(Guid? planId = null, Guid? workoutId = null, Guid? exerciseId = null) => new(
        planId ?? Guid.NewGuid(), "Push day", null, null, null, null,
        [
            new PlannedWorkoutInput(workoutId ?? Guid.NewGuid(), 1, null, 0,
            [
                new PlannedExerciseInput(exerciseId ?? Guid.NewGuid(), Catalog(2), 0, 3, Json("""{"kind":"reps","repMin":5,"repMax":8}"""), 90),
            ]),
        ]);

    [Fact]
    public void Valid_create_applies_openapi_defaults()
    {
        var errors = new ValidationErrors();

        var plan = PlanValidator.ValidateCreate(ValidPlan(), CatalogTypes, errors);

        errors.HasErrors.ShouldBeFalse(string.Join(", ", errors.Fields));
        plan!.Kind.ShouldBe("weekly");
        plan.PrimaryDiscipline.ShouldBe("calisthenics");
        plan.Workouts.Single().Title.ShouldBe("");
        plan.Workouts.Single().Exercises.Single().Target.GetRawText().ShouldBe("""{"kind":"reps","repMin":5,"repMax":8}""");
    }

    [Fact]
    public void Duplicate_ids_within_the_request_are_rejected()
    {
        var shared = Guid.NewGuid();
        var errors = new ValidationErrors();

        PlanValidator.ValidateCreate(ValidPlan(planId: shared, exerciseId: shared), CatalogTypes, errors).ShouldBeNull();

        errors.Fields.ShouldContain("workouts[0].exercises[0].id");
    }

    [Fact]
    public void Event_plan_requires_an_event_date()
    {
        var errors = new ValidationErrors();

        PlanValidator.ValidateCreate(ValidPlan() with { Kind = "event" }, CatalogTypes, errors).ShouldBeNull();

        errors.Fields.ShouldBe(["eventDate"]);
    }

    [Theory]
    [InlineData(null, null, "title")]
    [InlineData("", null, "title")]
    [InlineData("ok", "yoga", "primaryDiscipline")]
    public void Plan_fields_are_validated(string? title, string? discipline, string field)
    {
        var errors = new ValidationErrors();

        PlanValidator.ValidateCreate(ValidPlan() with { Title = title, PrimaryDiscipline = discipline }, CatalogTypes, errors).ShouldBeNull();

        errors.Fields.ShouldContain(field);
    }

    [Fact]
    public void Missing_collections_and_null_items_are_reported_with_paths()
    {
        var errors = new ValidationErrors();
        var input = ValidPlan() with { Workouts = [null, new PlannedWorkoutInput(Guid.NewGuid(), 8, null, 0, null)] };

        PlanValidator.ValidateCreate(input, CatalogTypes, errors).ShouldBeNull();

        errors.Fields.ShouldBe(["workouts[0]", "workouts[1].weekday", "workouts[1].exercises"], ignoreOrder: true);
    }

    [Theory]
    [InlineData("abc", 3)]
    [InlineData("💪💪", 2)] // surrogate pairs count once
    [InlineData("a\u0000b", -1)] // NUL is not storable in PostgreSQL text
    public void Text_length_counts_code_points(string value, int expected)
    {
        PlanValidator.TextLength(value).ShouldBe(expected);
    }

    [Fact]
    public void Text_length_rejects_an_unpaired_surrogate()
    {
        // Not an InlineData case: theory-data serialization replaces lone surrogates with U+FFFD.
        PlanValidator.TextLength("a" + '\uD83D').ShouldBe(-1);
        PlanValidator.TextLength('\uDC00' + "a").ShouldBe(-1);
    }

    [Fact]
    public void Cursor_round_trips()
    {
        var cursor = new PlanCursor(new DateTime(2026, 11, 9, 1, 2, 3, DateTimeKind.Utc).AddTicks(4567), Guid.NewGuid());

        PlanCursor.TryDecode(cursor.Encode(), out var decoded).ShouldBeTrue();

        decoded.ShouldBe(cursor);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not base64!")]
    [InlineData("WyIyMDI2LTExLTA5VDAxOjAyOjAzIl0")] // ["2026-11-09T01:02:03"] — no id, no UTC kind
    public void Malformed_cursors_are_rejected(string value)
    {
        PlanCursor.TryDecode(value, out var decoded).ShouldBeFalse();
        decoded.ShouldBeNull();
    }

    [Fact]
    public void Oversized_cursor_is_rejected()
    {
        PlanCursor.TryDecode(new string('A', 513), out _).ShouldBeFalse();
    }

    [Fact]
    public void Request_hash_ignores_key_order_whitespace_and_decimal_trailing_zeros()
    {
        var a = PlanRequestHash.Compute(Json("""{"title":"A","workouts":[{"target":{"kind":"load","loadKg":12.50}}]}"""));
        var b = PlanRequestHash.Compute(Json("""
            { "workouts" : [ { "target" : { "loadKg" : 12.5, "kind" : "load" } } ], "title" : "A" }
            """));

        a.ShouldBe(b);
        a.ShouldMatch("^[0-9a-f]{64}$");
    }

    [Theory]
    [InlineData("""{"title":"B","workouts":[]}""")]
    [InlineData("""{"title":"A","workouts":[],"kind":"weekly"}""")]
    [InlineData("""{"title":"A","workouts":[{}]}""")]
    public void Request_hash_changes_with_content(string other)
    {
        PlanRequestHash.Compute(Json(other)).ShouldNotBe(PlanRequestHash.Compute(Json("""{"title":"A","workouts":[]}""")));
    }
}
