using Cali.Application.Sync;
using Microsoft.Extensions.Time.Testing;

namespace Cali.UnitTests.Sync;

/// <summary>B3 (BE-004): cursor codec and the pull use case (docs/08 section 4 and 7, ADR-070).</summary>
public sealed class PullTests
{
    private static readonly Guid UserA = Guid.Parse("a0000000-0000-4000-8000-000000000001");
    private static readonly Guid UserB = Guid.Parse("b0000000-0000-4000-8000-000000000002");
    private static readonly DateTimeOffset Now = new(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan Retention = TimeSpan.FromDays(180);

    private static byte[] Key(byte fill) => Enumerable.Repeat(fill, SyncCursorCodec.MinKeyBytes).ToArray();

    private static SyncCursorCodec Codec(byte fill = 7) => new(Key(fill));

    private sealed class FakeReader(IReadOnlyList<SyncChangeRecord> feed, SyncCursorState? state = null) : ISyncReader
    {
        public int StateCalls { get; private set; }

        public List<(long After, int Take)> Reads { get; } = [];

        public Task<SyncCursorState> GetCursorStateAsync(Guid userId, long seq, CancellationToken cancellationToken)
        {
            StateCalls++;
            return Task.FromResult(state ?? new SyncCursorState(feed.Count == 0 ? 0 : feed[^1].Seq, Now.UtcDateTime));
        }

        public Task<IReadOnlyList<SyncChangeRecord>> ReadChangesAsync(Guid userId, long afterSeq, int take, CancellationToken cancellationToken)
        {
            Reads.Add((afterSeq, take));
            return Task.FromResult<IReadOnlyList<SyncChangeRecord>>(feed.Where(c => c.Seq > afterSeq).Take(take).ToArray());
        }
    }

    private static List<SyncChangeRecord> Feed(int count) =>
        Enumerable.Range(1, count)
            .Select(n => new SyncChangeRecord(n, "body_measurement", Guid.NewGuid(), "upsert", 1, "{}"))
            .ToList();

    private static PullChanges UseCase(FakeReader reader, SyncCursorCodec? codec = null) =>
        new(reader, codec ?? Codec(), new SyncPullSettings(Retention), new FakeTimeProvider(Now));

    // ---- codec ------------------------------------------------------------------------------------

    [Theory]
    [InlineData(0L)]
    [InlineData(1L)]
    [InlineData(4_294_967_296L)]
    [InlineData(long.MaxValue)]
    public void A_cursor_round_trips_for_the_user_it_was_issued_to(long seq)
    {
        var codec = Codec();

        var token = codec.Encode(UserA, seq);

        codec.TryDecode(token, UserA, out var decoded).ShouldBeTrue();
        decoded.ShouldBe(seq);
    }

    [Fact]
    public void A_cursor_is_url_safe_fixed_length_and_deterministic()
    {
        var codec = Codec();

        var token = codec.Encode(UserA, 42);

        token.Length.ShouldBe(76);
        token.ShouldMatch("^[A-Za-z0-9_-]+$");
        codec.Encode(UserA, 42).ShouldBe(token);
        codec.Encode(UserA, 43).ShouldNotBe(token);
    }

    [Fact]
    public void Another_users_cursor_does_not_decode()
    {
        var codec = Codec();

        codec.TryDecode(codec.Encode(UserA, 5), UserB, out _).ShouldBeFalse();
    }

    [Fact]
    public void A_cursor_signed_with_another_key_does_not_decode()
    {
        Codec(8).TryDecode(Codec(7).Encode(UserA, 5), UserA, out _).ShouldBeFalse();
    }

    [Fact]
    public void An_altered_cursor_does_not_decode_whichever_character_changes()
    {
        var codec = Codec();
        var token = codec.Encode(UserA, 5);

        // 57 bytes encode to exactly 76 characters (no padding bits), so every character carries signed data.
        for (var i = 0; i < token.Length; i++)
        {
            var altered = string.Concat(token.AsSpan(0, i), token[i] == 'A' ? "B" : "A", token.AsSpan(i + 1));
            codec.TryDecode(altered, UserA, out _).ShouldBeFalse($"character {i}");
        }
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("12")]
    [InlineData("not a cursor")]
    [InlineData("AAAA")]
    public void Anything_that_is_not_a_cursor_does_not_decode(string? value)
    {
        Codec().TryDecode(value, UserA, out _).ShouldBeFalse();
    }

    [Fact]
    public void An_over_long_or_padded_cursor_does_not_decode()
    {
        var codec = Codec();
        var token = codec.Encode(UserA, 5);

        codec.TryDecode(token + token, UserA, out _).ShouldBeFalse();
        codec.TryDecode(new string('A', 129), UserA, out _).ShouldBeFalse();
        codec.TryDecode(token + "=", UserA, out _).ShouldBeFalse();
    }

    [Fact]
    public void The_codec_rejects_a_short_key_and_a_negative_sequence()
    {
        Should.Throw<ArgumentException>(() => new SyncCursorCodec(new byte[SyncCursorCodec.MinKeyBytes - 1]));
        Should.Throw<ArgumentOutOfRangeException>(() => Codec().Encode(UserA, -1));
    }

    // ---- use case ---------------------------------------------------------------------------------

    [Fact]
    public async Task The_initial_pull_starts_at_the_beginning_without_a_cursor_check()
    {
        var reader = new FakeReader(Feed(3));
        var codec = Codec();

        var result = await UseCase(reader, codec).ExecuteAsync(UserA, null, 100, CancellationToken.None);

        result.Status.ShouldBe(SyncPullStatus.Page);
        var page = result.Page!;
        page.Changes.Select(c => c.Record.Seq).ShouldBe([1, 2, 3]);
        page.HasMore.ShouldBeFalse();
        reader.StateCalls.ShouldBe(0);
        reader.Reads.ShouldBe([(0, 101)]);
        codec.TryDecode(page.NextCursor, UserA, out var next).ShouldBeTrue();
        next.ShouldBe(3);
    }

    [Fact]
    public async Task Each_change_id_is_a_cursor_for_that_change()
    {
        var codec = Codec();

        var page = (await UseCase(new FakeReader(Feed(3)), codec).ExecuteAsync(UserA, null, 100, CancellationToken.None)).Page!;

        foreach (var change in page.Changes)
        {
            codec.TryDecode(change.ChangeId, UserA, out var seq).ShouldBeTrue();
            seq.ShouldBe(change.Record.Seq);
        }
    }

    [Fact]
    public async Task A_full_page_reports_more_and_the_cursor_stops_at_the_last_returned_change()
    {
        var reader = new FakeReader(Feed(5));
        var codec = Codec();

        var page = (await UseCase(reader, codec).ExecuteAsync(UserA, null, 2, CancellationToken.None)).Page!;

        page.Changes.Select(c => c.Record.Seq).ShouldBe([1, 2]);
        page.HasMore.ShouldBeTrue();
        reader.Reads.ShouldBe([(0, 3)]);
        codec.TryDecode(page.NextCursor, UserA, out var next).ShouldBeTrue();
        next.ShouldBe(2);
    }

    [Fact]
    public async Task Following_the_cursors_visits_every_change_once_in_order()
    {
        var reader = new FakeReader(Feed(7));
        var useCase = UseCase(reader);
        var seen = new List<long>();
        string? cursor = null;
        var more = true;

        while (more)
        {
            var page = (await useCase.ExecuteAsync(UserA, cursor, 3, CancellationToken.None)).Page!;
            seen.AddRange(page.Changes.Select(c => c.Record.Seq));
            cursor = page.NextCursor;
            more = page.HasMore;
        }

        seen.ShouldBe([1, 2, 3, 4, 5, 6, 7]);
    }

    [Fact]
    public async Task An_empty_page_keeps_the_cursor_position()
    {
        var codec = Codec();
        var reader = new FakeReader(Feed(4));

        var page = (await UseCase(reader, codec).ExecuteAsync(UserA, codec.Encode(UserA, 4), 100, CancellationToken.None)).Page!;

        page.Changes.ShouldBeEmpty();
        page.HasMore.ShouldBeFalse();
        codec.TryDecode(page.NextCursor, UserA, out var next).ShouldBeTrue();
        next.ShouldBe(4);
    }

    [Fact]
    public async Task An_empty_feed_returns_the_initial_position()
    {
        var codec = Codec();

        var page = (await UseCase(new FakeReader([]), codec).ExecuteAsync(UserA, null, 100, CancellationToken.None)).Page!;

        page.Changes.ShouldBeEmpty();
        codec.TryDecode(page.NextCursor, UserA, out var next).ShouldBeTrue();
        next.ShouldBe(0);
    }

    [Fact]
    public async Task A_cursor_that_is_not_valid_for_the_caller_is_rejected_before_the_feed_is_read()
    {
        var codec = Codec();
        var reader = new FakeReader(Feed(3));
        var useCase = UseCase(reader, codec);

        foreach (var cursor in new[] { "garbage", codec.Encode(UserB, 1), Codec(9).Encode(UserA, 1), string.Empty })
        {
            var result = await useCase.ExecuteAsync(UserA, cursor, 100, CancellationToken.None);

            result.Status.ShouldBe(SyncPullStatus.InvalidCursor);
            result.Page.ShouldBeNull();
        }

        reader.StateCalls.ShouldBe(0);
        reader.Reads.ShouldBeEmpty();
    }

    [Theory]
    [InlineData(1, false)]
    [InlineData(179, false)]
    [InlineData(181, true)]
    [InlineData(1000, true)]
    public async Task A_cursor_expires_once_its_change_is_older_than_the_retention_window(int ageDays, bool expectedExpired)
    {
        var reader = new FakeReader(Feed(3), new SyncCursorState(3, Now.UtcDateTime - TimeSpan.FromDays(ageDays)));
        var codec = Codec();

        var result = await UseCase(reader, codec).ExecuteAsync(UserA, codec.Encode(UserA, 2), 100, CancellationToken.None);

        result.Status.ShouldBe(expectedExpired ? SyncPullStatus.CursorExpired : SyncPullStatus.Page);
        reader.Reads.Count.ShouldBe(expectedExpired ? 0 : 1);
    }

    [Fact]
    public async Task The_retention_window_boundary_is_inclusive()
    {
        var codec = Codec();

        var atBoundary = new FakeReader(Feed(3), new SyncCursorState(3, (Now - Retention).UtcDateTime));
        var justOutside = new FakeReader(Feed(3), new SyncCursorState(3, (Now - Retention - TimeSpan.FromSeconds(1)).UtcDateTime));

        (await UseCase(atBoundary, codec).ExecuteAsync(UserA, codec.Encode(UserA, 2), 100, CancellationToken.None))
            .Status.ShouldBe(SyncPullStatus.Page);
        (await UseCase(justOutside, codec).ExecuteAsync(UserA, codec.Encode(UserA, 2), 100, CancellationToken.None))
            .Status.ShouldBe(SyncPullStatus.CursorExpired);
    }

    [Fact]
    public async Task A_cursor_whose_change_is_gone_or_ahead_of_the_feed_needs_a_full_resync()
    {
        var codec = Codec();
        var missingRow = new FakeReader(Feed(3), new SyncCursorState(3, null));
        var aheadOfFeed = new FakeReader(Feed(3), new SyncCursorState(3, Now.UtcDateTime));

        (await UseCase(missingRow, codec).ExecuteAsync(UserA, codec.Encode(UserA, 2), 100, CancellationToken.None))
            .Status.ShouldBe(SyncPullStatus.CursorExpired);
        (await UseCase(aheadOfFeed, codec).ExecuteAsync(UserA, codec.Encode(UserA, 4), 100, CancellationToken.None))
            .Status.ShouldBe(SyncPullStatus.CursorExpired);
    }

    [Fact]
    public async Task The_initial_pull_is_never_expired_however_old_the_feed_is()
    {
        var reader = new FakeReader(Feed(3), new SyncCursorState(3, Now.UtcDateTime - TimeSpan.FromDays(1000)));

        var result = await UseCase(reader).ExecuteAsync(UserA, null, 100, CancellationToken.None);

        result.Status.ShouldBe(SyncPullStatus.Page);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(101)]
    public async Task A_limit_outside_1_to_100_is_a_caller_bug(int limit)
    {
        await Should.ThrowAsync<ArgumentOutOfRangeException>(
            () => UseCase(new FakeReader([])).ExecuteAsync(UserA, null, limit, CancellationToken.None));
    }
}
