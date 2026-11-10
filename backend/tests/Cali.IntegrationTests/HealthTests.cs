using System.Net;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;

namespace Cali.IntegrationTests;

[Collection(PostgresCollection.Name)]
public sealed class HealthTests(PostgresFixture postgres)
{
    [Fact]
    public async Task Ready_returns_200_when_database_is_up()
    {
        await using var factory = new CaliApiFactory("Production", AuthTestConfig.With(new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = postgres.AdminConnectionString,
        }));
        using var client = factory.CreateClient();

        var response = await client.GetAsync(new Uri("/health/ready", UriKind.Relative));

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Ready_returns_503_when_database_is_unreachable_while_live_stays_200()
    {
        // Nothing listens on port 1: the database is unreachable.
        await using var factory = new CaliApiFactory("Production", AuthTestConfig.With(new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = "Host=127.0.0.1;Port=1;Database=cali;Username=cali;Password=unused;Timeout=2",
        }));
        using var client = factory.CreateClient();

        (await client.GetAsync(new Uri("/health/ready", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.ServiceUnavailable);
        (await client.GetAsync(new Uri("/health/live", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Ready_returns_503_after_the_database_container_stops()
    {
        await using var container = new Testcontainers.PostgreSql.PostgreSqlBuilder(PostgresFixture.Image).Build();
        await container.StartAsync();
        await using var factory = new CaliApiFactory("Production", AuthTestConfig.With(new Dictionary<string, string?>
        {
            // Pooling off so the check opens a fresh physical connection each time.
            ["ConnectionStrings:Cali"] = container.GetConnectionString() + ";Pooling=false;Timeout=2",
        }));
        using var client = factory.CreateClient();
        (await client.GetAsync(new Uri("/health/ready", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.OK);

        await container.StopAsync();

        (await client.GetAsync(new Uri("/health/ready", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.ServiceUnavailable);
        (await client.GetAsync(new Uri("/health/live", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.OK);
    }
}
