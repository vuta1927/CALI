using System.Buffers.Text;
using System.Text;
using Cali.Api.Endpoints;
using Cali.Application.Catalog;
using Cali.Domain.Catalog;
using Cali.Infrastructure.Persistence;

namespace Cali.UnitTests.Catalog;

public sealed class CatalogTests
{
    [Fact]
    public void Exercise_cursor_round_trips_and_is_url_safe()
    {
        var cursor = new ExerciseCursor("tuck-planche", Guid.NewGuid());

        var encoded = cursor.Encode();

        encoded.ShouldNotContain('+');
        encoded.ShouldNotContain('/');
        encoded.ShouldNotContain('=');
        ExerciseCursor.TryDecode(encoded, out var decoded).ShouldBeTrue();
        decoded.ShouldBe(cursor);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not base64 !")]
    [InlineData("""["ex-a"]""")]
    [InlineData("""["ex-a","not-a-guid"]""")]
    [InlineData("""["Bad Slug","00000000-0000-0000-0000-000000000001"]""")]
    [InlineData("""["ex-a","00000000-0000-0000-0000-000000000001","extra"]""")]
    [InlineData("""{"slug":"ex-a"}""")]
    [InlineData("""[1,2]""")]
    public void Exercise_cursor_rejects_values_it_did_not_issue(string payload)
    {
        // Payloads that are JSON get base64url-encoded so only the content is wrong.
        var raw = payload.StartsWith('[') || payload.StartsWith('{') ? Base64Url.EncodeToString(Encoding.UTF8.GetBytes(payload)) : payload;

        ExerciseCursor.TryDecode(raw, out var decoded).ShouldBeFalse();
        decoded.ShouldBeNull();
    }

    [Fact]
    public void Exercise_cursor_rejects_oversized_input()
    {
        ExerciseCursor.TryDecode(new string('A', 513), out _).ShouldBeFalse();
    }

    [Theory]
    [InlineData("static_hold", "hold")]
    [InlineData("reps", "reps")]
    [InlineData("timed_reps", "reps")]
    [InlineData("skill_attempt", "reps")]
    [InlineData("interval", "duration")]
    [InlineData("duration", "duration")]
    [InlineData("distance", "distance")]
    [InlineData("load", "load")]
    public void Measurement_type_is_derived_from_exercise_type_per_ADR_060(string type, string expected)
    {
        MeasurementTypes.ForExerciseType(type).ShouldBe(expected);
    }

    [Fact]
    public void Unknown_exercise_type_has_no_measurement_type()
    {
        Should.Throw<ArgumentOutOfRangeException>(() => MeasurementTypes.ForExerciseType("yoga"));
        ExerciseTypes.IsKnown("yoga").ShouldBeFalse();
    }

    [Theory]
    [InlineData("\"c1.i6\"", true)]
    [InlineData("W/\"c1.i6\"", true)]
    [InlineData("\"c0.i1\", \"c1.i6\"", true)]
    [InlineData("\"c0.i1\",\"c1.i6\"", true)]
    [InlineData(" * ", true)]
    [InlineData("\"c1.i5\"", false)]
    [InlineData("c1.i6", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void If_none_match_uses_weak_comparison_over_a_list(string? header, bool expected)
    {
        CatalogEndpoints.Matches(header, "\"c1.i6\"").ShouldBe(expected);
    }

    [Theory]
    [InlineData("100%", @"100\%")]
    [InlineData("a_b", @"a\_b")]
    [InlineData(@"c:\x", @"c:\\x")]
    [InlineData(@"\%_", @"\\\%\_")]
    [InlineData("plain", "plain")]
    public void Like_patterns_escape_metacharacters(string input, string expected)
    {
        ExerciseCatalogReader.EscapeLike(input).ShouldBe(expected);
    }

    [Theory]
    [InlineData("1.000", "1")]
    [InlineData("0.500", "0.5")]
    [InlineData("2.250", "2.25")]
    [InlineData("10.000", "10")]
    public void Indicator_step_drops_trailing_zeros(string stored, string wire)
    {
        var value = decimal.Parse(stored, System.Globalization.CultureInfo.InvariantCulture);

        CriteriaConfigReader.TrimScale(value).ToString(System.Globalization.CultureInfo.InvariantCulture).ShouldBe(wire);
    }
}
