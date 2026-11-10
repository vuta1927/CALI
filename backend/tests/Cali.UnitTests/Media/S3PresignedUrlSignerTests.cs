using System.Globalization;
using System.Text.RegularExpressions;
using Cali.Application.Catalog;
using Cali.Infrastructure.Media;

namespace Cali.UnitTests.Media;

/// <summary>B-slice BE-006: AWS SigV4 presigned GET for catalog media (ADR-072). No network involved.</summary>
public sealed partial class S3PresignedUrlSignerTests
{
    private const string Secret = "test-secret-access-key-0123456789";
    private static readonly DateTimeOffset Issued = new(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);

    private static S3StorageOptions Options(
        string endpoint = "https://store.example.com", string bucket = "cali-media", string region = "auto",
        string secret = Secret, int lifetimeSeconds = 900) => new()
        {
            Endpoint = new Uri(endpoint),
            Bucket = bucket,
            Region = region,
            AccessKeyId = "AKIATESTKEY",
            SecretAccessKey = secret,
            Lifetime = TimeSpan.FromSeconds(lifetimeSeconds),
        };

    private static S3PresignedUrlSigner Signer(S3StorageOptions? options = null) => new(options ?? Options());

    [Fact]
    public void Reproduces_the_signature_published_in_the_AWS_presigned_url_example()
    {
        // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html (GET /test.txt, 86400 s).
        var url = S3PresignedUrlSigner.Presign(
            "GET", new Uri("https://examplebucket.s3.amazonaws.com"), "/test.txt", "us-east-1",
            "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            new DateTimeOffset(2013, 5, 24, 0, 0, 0, TimeSpan.Zero), 86400);

        url.AbsoluteUri.ShouldBe(
            "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404");
    }

    [Fact]
    public void Issues_a_path_style_url_for_the_bucket_and_encodes_the_key_per_segment()
    {
        var signed = Signer(Options("http://localhost:9000")).Sign("media/ex 1/póster+a=b.webp", Issued);

        signed.ShouldNotBeNull();
        signed.Url.Scheme.ShouldBe("http");
        signed.Url.Authority.ShouldBe("localhost:9000");
        signed.Url.AbsolutePath.ShouldBe("/cali-media/media/ex%201/p%C3%B3ster%2Ba%3Db.webp");
        var query = signed.Url.Query;
        query.ShouldContain("X-Amz-Algorithm=AWS4-HMAC-SHA256");
        query.ShouldContain("X-Amz-Credential=AKIATESTKEY%2F20261109%2Fauto%2Fs3%2Faws4_request");
        query.ShouldContain("X-Amz-Date=20261109T120000Z");
        query.ShouldContain("X-Amz-Expires=900");
        query.ShouldContain("X-Amz-SignedHeaders=host");
        SignaturePattern().IsMatch(query).ShouldBeTrue(query);
        signed.ExpiresAt.ShouldBe(Issued.AddSeconds(900));
    }

    [Fact]
    public void The_url_never_contains_the_secret_or_the_bare_access_key_outside_the_credential_scope()
    {
        var signed = Signer().Sign("a/b.webp", Issued)!;

        signed.Url.OriginalString.ShouldNotContain(Secret);
        signed.Url.OriginalString.ShouldNotContain("X-Amz-Security-Token");
        // The only place the key id appears is the credential scope.
        Regex.Matches(signed.Url.OriginalString, "AKIATESTKEY").Count.ShouldBe(1);
    }

    [Fact]
    public void Is_deterministic_and_depends_on_key_secret_time_bucket_and_region()
    {
        var baseline = Signer().Sign("a/b.webp", Issued)!.Url.OriginalString;

        Signer().Sign("a/b.webp", Issued)!.Url.OriginalString.ShouldBe(baseline);
        Signer().Sign("a/c.webp", Issued)!.Url.OriginalString.ShouldNotBe(baseline);
        Signer().Sign("a/b.webp", Issued.AddSeconds(1))!.Url.OriginalString.ShouldNotBe(baseline);
        Signer(Options(secret: "another-secret-access-key-0123456789")).Sign("a/b.webp", Issued)!.Url.OriginalString.ShouldNotBe(baseline);
        Signer(Options(bucket: "other-bucket")).Sign("a/b.webp", Issued)!.Url.OriginalString.ShouldNotBe(baseline);
        Signer(Options(region: "eu-west-1")).Sign("a/b.webp", Issued)!.Url.OriginalString.ShouldNotBe(baseline);
        Signer(Options(lifetimeSeconds: 901)).Sign("a/b.webp", Issued)!.Url.OriginalString.ShouldNotBe(baseline);
    }

    [Fact]
    public void Signs_for_the_utc_instant_whatever_the_offset_and_truncates_to_whole_seconds()
    {
        var plus7 = new DateTimeOffset(2026, 11, 9, 19, 0, 0, 456, TimeSpan.FromHours(7));

        var signed = Signer().Sign("a/b.webp", plus7)!;

        signed.Url.Query.ShouldContain("X-Amz-Date=20261109T120000Z");
        signed.ExpiresAt.ShouldBe(Issued.AddSeconds(900)); // the signed expiry, not issued + 900.456 s
        signed.Url.OriginalString.ShouldBe(Signer().Sign("a/b.webp", Issued)!.Url.OriginalString);
    }

    [Fact]
    public void Omits_the_default_port_from_the_signed_host_and_keeps_a_custom_one()
    {
        Signer(Options("https://store.example.com:443")).Sign("a.webp", Issued)!.Url.Authority.ShouldBe("store.example.com");
        Signer(Options("https://store.example.com:8443")).Sign("a.webp", Issued)!.Url.Authority.ShouldBe("store.example.com:8443");
    }

    [Theory]
    [InlineData("object")]
    [InlineData("media/ex/preview.mp4")]
    [InlineData("ünï/ç.mp4")]
    [InlineData("media/a b/c~d_e-f.webp")]
    public void Signs_ordinary_keys(string key)
    {
        Signer().Sign(key, Issued).ShouldNotBeNull();
    }

    [Theory]
    [InlineData("")]
    [InlineData("/leading")]
    [InlineData("trailing/")]
    [InlineData("a//b")]
    [InlineData("a/./b")]
    [InlineData("a/../b")]
    [InlineData("..")]
    [InlineData("a\\b")]
    [InlineData("a\nb")]
    [InlineData("a\0b")]
    public void Never_signs_a_key_it_would_not_serve(string key)
    {
        Signer().Sign(key, Issued).ShouldBeNull();
        S3PresignedUrlSigner.IsSignableKey(key).ShouldBeFalse();
    }

    [Fact]
    public void Never_signs_a_key_that_is_not_valid_utf16()
    {
        // Built at run time: xUnit would turn a lone surrogate in InlineData into U+FFFD.
        var lone = "a" + char.ConvertFromUtf32(0x1F600)[0] + "b";

        Signer().Sign(lone, Issued).ShouldBeNull();
    }

    [Fact]
    public void Signs_a_key_of_1024_bytes_and_refuses_1025()
    {
        var atLimit = new string('k', 1024);
        Signer().Sign(atLimit, Issued).ShouldNotBeNull();
        Signer().Sign(atLimit + "k", Issued).ShouldBeNull();

        // 2 bytes per character: 513 characters are 1026 bytes.
        Signer().Sign(new string('é', 513), Issued).ShouldBeNull();
    }

    [Fact]
    public void Changing_a_signed_part_of_the_url_no_longer_matches_its_signature()
    {
        var original = Signer().Sign("a/b.webp", Issued)!.Url;
        RecomputedSignature(original).ShouldBe(SignatureOf(original));

        string[] tampered =
        [
            original.OriginalString.Replace("/a/b.webp", "/a/c.webp", StringComparison.Ordinal),
            original.OriginalString.Replace("X-Amz-Expires=900", "X-Amz-Expires=3600", StringComparison.Ordinal),
            original.OriginalString.Replace("20261109T120000Z", "20261109T130000Z", StringComparison.Ordinal),
            original.OriginalString.Replace("/cali-media/", "/other-bucket/", StringComparison.Ordinal),
        ];
        foreach (var url in tampered)
        {
            var uri = new Uri(url);
            uri.OriginalString.ShouldNotBe(original.OriginalString);
            RecomputedSignature(uri).ShouldNotBe(SignatureOf(uri), url);
        }
    }

    [Theory]
    [InlineData(60, true)]
    [InlineData(3600, true)]
    [InlineData(59, false)]
    [InlineData(3601, false)]
    public void The_lifetime_is_bounded_to_a_short_window(int seconds, bool accepted)
    {
        if (accepted)
        {
            Signer(Options(lifetimeSeconds: seconds)).Sign("a.webp", Issued)!.ExpiresAt.ShouldBe(Issued.AddSeconds(seconds));
        }
        else
        {
            Should.Throw<ArgumentException>(() => Signer(Options(lifetimeSeconds: seconds)));
        }
    }

    [Fact]
    public void Rejects_fractional_seconds_in_the_lifetime()
    {
        var options = Options();
        var fractional = new S3StorageOptions
        {
            Endpoint = options.Endpoint, Bucket = options.Bucket, Region = options.Region,
            AccessKeyId = options.AccessKeyId, SecretAccessKey = options.SecretAccessKey, Lifetime = TimeSpan.FromSeconds(90.5),
        };

        Should.Throw<ArgumentException>(() => new S3PresignedUrlSigner(fractional));
    }

    [Theory]
    [InlineData("https://store.example.com/some/path")]
    [InlineData("https://store.example.com/?x=1")]
    [InlineData("https://user:pass@store.example.com")]
    [InlineData("ftp://store.example.com")]
    public void Rejects_an_endpoint_that_is_not_a_plain_origin(string endpoint)
    {
        Should.Throw<ArgumentException>(() => Signer(Options(endpoint)));
    }

    [Theory]
    [InlineData("ab")]
    [InlineData("UPPER-case")]
    [InlineData("-leading")]
    [InlineData("has_underscore")]
    [InlineData("has space")]
    [InlineData("trailing-newline\n")]
    public void Rejects_an_invalid_bucket(string bucket)
    {
        Should.Throw<ArgumentException>(() => Signer(Options(bucket: bucket)));
        S3PresignedUrlSigner.IsValidBucket(bucket).ShouldBeFalse();
    }

    [Fact]
    public void Rejects_missing_credentials_and_never_prints_them_in_options_or_errors()
    {
        Should.Throw<ArgumentException>(() => Signer(Options(secret: " ")));

        var text = Options().ToString() ?? string.Empty;
        text.ShouldNotContain(Secret);

        var exception = Should.Throw<ArgumentException>(() => Signer(Options(bucket: "X")));
        exception.Message.ShouldNotContain(Secret);
    }

    [Fact]
    public void The_null_signer_issues_nothing()
    {
        new NoMediaUrlSigner().Sign("a/b.webp", Issued).ShouldBeNull();
    }

    // ---- helpers: re-derive the signature from the url's own parts, as a verifying store would ----

    private static string SignatureOf(Uri url) => Regex.Match(url.Query, "X-Amz-Signature=([0-9a-f]{64})").Groups[1].Value;

    private static string RecomputedSignature(Uri url)
    {
        var query = url.Query;
        var date = DateTimeOffset.ParseExact(
            Regex.Match(query, "X-Amz-Date=([0-9TZ]+)").Groups[1].Value, "yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal);
        var expires = int.Parse(Regex.Match(query, "X-Amz-Expires=(\\d+)").Groups[1].Value, CultureInfo.InvariantCulture);
        var origin = new Uri($"{url.Scheme}://{url.Authority}");
        var recomputed = S3PresignedUrlSigner.Presign("GET", origin, url.AbsolutePath, "auto", "AKIATESTKEY", Secret, date, expires);
        return SignatureOf(recomputed);
    }

    [GeneratedRegex("X-Amz-Signature=[0-9a-f]{64}$")]
    private static partial Regex SignaturePattern();
}
