using System.Text.Json;
using Cali.Api.Endpoints;
using Cali.Application.Catalog;
using Cali.Domain.Catalog;

namespace Cali.UnitTests.Catalog;

/// <summary>BE-007 (CON-010): voice pack locale rule, ETag and wire mapping.</summary>
public sealed class VoicePackTests
{
    private static readonly VoicePack Pack = new("vi-VN", 3, DateTimeOffset.Parse("2026-11-11T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture), "Giọng thử",
    [
        new VoiceCue("rest.done", "Hết giờ nghỉ. Vào set tiếp theo.", "voice/vi-VN/v3/rest.done.caf", "caf_ima4", new string('a', 64), 12000, 1800),
        new VoiceCue("hold.done", "Đủ thời gian. Có thể thả.", "voice/vi-VN/v3/hold.done.caf", "caf_ima4", new string('b', 64), 11000, 1600),
    ]);

    [Theory]
    [InlineData("vi-VN", true)]
    [InlineData("fil-PH", true)]
    [InlineData("vi", false)]
    [InlineData("vi-vn", false)]
    [InlineData("vi_VN", false)]
    [InlineData("vi-VN ", false)]
    public void Locale_follows_the_openapi_pattern(string locale, bool valid) =>
        GetVoicePack.IsLocale(locale).ShouldBe(valid);

    [Fact]
    public void Etag_is_strong_and_names_locale_and_version() =>
        GetVoicePack.ETag(Pack).ShouldBe("\"vi-VN.v3\"");

    [Fact]
    public void Response_signs_every_cue_at_one_instant_and_never_carries_the_storage_key()
    {
        var issuedAt = DateTimeOffset.UnixEpoch.AddDays(20000);
        var signer = new FakeSigner();

        var response = VoicePackResponse.From(Pack, signer, issuedAt);
        var json = JsonSerializer.Serialize(response, new JsonSerializerOptions(JsonSerializerDefaults.Web));

        signer.Keys.ShouldBe(["voice/vi-VN/v3/rest.done.caf", "voice/vi-VN/v3/hold.done.caf"]);
        response.Cues.Select(c => c.Audio.ExpiresAt).Distinct().ShouldBe([issuedAt.AddMinutes(15)]);
        json.ShouldNotContain("storageKey");
        json.ShouldContain("\"url\":\"https://signed.example/");
    }

    [Fact]
    public void Response_keeps_null_url_when_the_signer_declines()
    {
        var response = VoicePackResponse.From(Pack, new NoMediaUrlSigner(), DateTimeOffset.UnixEpoch);
        var json = JsonSerializer.Serialize(response, new JsonSerializerOptions(JsonSerializerDefaults.Web));

        response.Cues.ShouldAllBe(c => c.Audio.Url == null && c.Audio.ExpiresAt == null);
        // OpenAPI requires both members, as null.
        json.ShouldContain("\"url\":null");
        json.ShouldContain("\"expiresAt\":null");
    }

    private sealed class FakeSigner : IMediaUrlSigner
    {
        public List<string> Keys { get; } = [];

        public SignedMediaUrl? Sign(string storageKey, DateTimeOffset issuedAt)
        {
            Keys.Add(storageKey);
            return new SignedMediaUrl(new Uri($"https://signed.example/{Keys.Count}"), issuedAt.AddMinutes(15));
        }
    }
}
