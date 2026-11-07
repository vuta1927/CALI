using System.Diagnostics;
using Cali.Api.Errors;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Cali.UnitTests.Errors;

public sealed class ProblemDetailsEnricherTests
{
    [Theory]
    [InlineData(400, "bad_request")]
    [InlineData(401, "unauthorized")]
    [InlineData(403, "forbidden")]
    [InlineData(404, "not_found")]
    [InlineData(409, "conflict")]
    [InlineData(429, "rate_limited")]
    [InlineData(500, "internal_error")]
    [InlineData(503, "service_unavailable")]
    [InlineData(418, "http_418")]
    public void Adds_stable_code_for_status(int status, string expectedCode)
    {
        var problem = new ProblemDetails { Status = status };
        ProblemDetailsEnricher.Enrich(problem, new DefaultHttpContext());

        problem.Extensions["code"].ShouldBe(expectedCode);
    }

    [Fact]
    public void Fills_every_required_schema_member()
    {
        var http = new DefaultHttpContext { TraceIdentifier = "trace-123" };
        http.Response.StatusCode = 404;
        var problem = new ProblemDetails();

        ProblemDetailsEnricher.Enrich(problem, http);

        problem.Type.ShouldNotBeNullOrWhiteSpace();
        problem.Title.ShouldNotBeNullOrWhiteSpace();
        problem.Status.ShouldBe(404);
        problem.Extensions["code"].ShouldBe("not_found");
        problem.Extensions["traceId"].ShouldBe("trace-123");
    }

    [Fact]
    public void Keeps_explicit_code()
    {
        var problem = new ProblemDetails { Status = 401 };
        problem.Extensions["code"] = "invalid_token";

        ProblemDetailsEnricher.Enrich(problem, new DefaultHttpContext());

        problem.Extensions["code"].ShouldBe("invalid_token");
    }

    [Fact]
    public void Uses_current_activity_trace_id_when_present()
    {
        using var activity = new Activity("test").SetIdFormat(ActivityIdFormat.W3C).Start();
        var problem = new ProblemDetails { Status = 400 };

        ProblemDetailsEnricher.Enrich(problem, new DefaultHttpContext { TraceIdentifier = "fallback" });

        problem.Extensions["traceId"].ShouldBe(activity.TraceId.ToHexString());
    }

    [Fact]
    public void Strips_internal_details_from_server_errors()
    {
        var problem = new ProblemDetails { Status = 500, Detail = "NpgsqlException: password authentication failed" };
        problem.Extensions["exception"] = new { Message = "boom" };

        ProblemDetailsEnricher.Enrich(problem, new DefaultHttpContext());

        problem.Detail.ShouldBeNull();
        problem.Extensions.ContainsKey("exception").ShouldBeFalse();
    }
}
