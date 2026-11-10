# CALI backend

ASP.NET Core (.NET 10) API and worker for the CALI training companion. The iOS app works fully offline;
this backend handles accounts, sync and AI jobs and is never needed during a workout.

```
backend/
  Cali.sln
  src/Cali.Api             minimal APIs, auth, ProblemDetails, health, rate limits, `migrate` command
  src/Cali.Worker          background worker (heartbeat skeleton; job processing lands with AI-001)
  src/Cali.Application     use cases + ports (ICurrentUser, IUserProfileReader)
  src/Cali.Domain          domain types
  src/Cali.Infrastructure  PostgreSQL (Npgsql + Dapper), DbUp migrations, dev-token minting
  tools/Cali.DevToken      CLI that mints Development-only JWTs
  tests/Cali.UnitTests
  tests/Cali.IntegrationTests   Testcontainers (postgres:16.15)
  tests/Cali.ContractTests      checks the API against ../contracts/openapi.yaml
```

The database schema lives in `../db/*.sql` and is the source of truth (contracts first; see `AGENTS.md`).
The OpenAPI contract is `../contracts/openapi.yaml`.

## Prerequisites

- .NET SDK 10.0.1xx (pinned by `global.json`, roll-forward `latestFeature`)
- Docker (Docker Desktop on Windows/macOS) for `docker compose` and the integration tests

## Run with Docker Compose

From the repository root:

```bash
cp .env.example .env          # set POSTGRES_PASSWORD; optionally CALI_DEV_TOKEN_SIGNING_KEY
docker compose up --build -d
curl -i http://localhost:8080/health/ready     # 200 when the API can reach PostgreSQL
docker compose down            # add -v to drop the database volume
```

The compose `api` service runs in `Development`, so it applies `db/*.sql` on startup, including the
Development-only seed `002_dev_catalog_seed.sql`. PostgreSQL is published on `127.0.0.1:55432`
(`CALI_DB_HOST_PORT`).

## Run the API locally (without Docker for the API)

```bash
docker compose up -d db
cd backend
dotnet user-secrets --project src/Cali.Api set "ConnectionStrings:Cali" \
  "Host=localhost;Port=55432;Database=cali;Username=cali;Password=<your POSTGRES_PASSWORD>"
dotnet run --project src/Cali.Api        # http://localhost:5080, Development
```

The API and `Cali.DevToken` share the user-secrets id `cali-backend-dev`. Secrets come from
user-secrets or environment variables only (`ConnectionStrings__Cali`, `Auth__DevTokens__SigningKey`,
`Sync__CursorSigningKey`); nothing secret is committed. `Sync__CursorSigningKey` signs sync pull cursors (base64,
at least 32 bytes, required outside Development; in Development it is derived from the dev token key when unset).
`Sync__ChangeLogRetentionDays` (default 180) is how long a pull cursor stays valid.

Catalog media URLs (BE-006, ADR-072) are signed against an S3-compatible bucket (Cloudflare R2, AWS S3, MinIO):
`Media__Storage__Endpoint` (origin only, `https` outside Development), `Media__Storage__Bucket`,
`Media__Storage__Region` (default `auto`; AWS S3 needs the bucket's region), `Media__Storage__AccessKeyId` and
`Media__Storage__SecretAccessKey` (secret; use a read-only credential for that bucket). All four are required outside
Development; in Development, setting none of them keeps `url: null`, and setting some but not all is an error.
`Media__UrlLifetimeSeconds` (default 900, 60..3600) is how long a signed URL works. For local work any S3-compatible
server on `http://localhost:<port>` works in Development (the integration tests use Scality CloudServer). Uploading
files and creating `exercise_media` rows is the ingestion tool, which does not exist yet.

## Migrations

DbUp applies `db/*.sql` in filename order, one transaction per script, journaled in `public.schema_versions`.
Scripts whose name contains `_dev_` (for example `002_dev_catalog_seed.sql`) run **only** in Development.

- Development: applied automatically at API startup (`Migrations:ApplyOnStartup=true` in
  `appsettings.Development.json`).
- Any other environment: never at startup. Run the explicit command:

  ```bash
  dotnet run --project src/Cali.Api -- migrate --environment Production
  # in the container image: dotnet Cali.Api.dll migrate
  ```

`Migrations:ScriptsPath` sets the scripts folder. If it is empty, the folder is found by walking up from
the content root to the repo `db/`. The image sets it to `/app/db`.

## Dev tokens (Development only)

Sign in with Apple is not implemented yet (`TODO(BE-005)`). Until then, Development uses locally minted
HS256 tokens from issuer `cali-dev-token`, audience `cali-api`. **The API trusts this issuer only when
`ASPNETCORE_ENVIRONMENT=Development`.** In every other environment those tokens get 401, even if a key
is configured.

```bash
cd backend
# 1. Create a signing key once and store it in user-secrets (shared with the API)
dotnet user-secrets --project src/Cali.Api set "Auth:DevTokens:SigningKey" \
  "$(dotnet run --project tools/Cali.DevToken -- new-key)"

# 2. Mint a token for a new user and insert the users row (--provision uses ConnectionStrings:Cali)
TOKEN=$(dotnet run --project tools/Cali.DevToken -- --provision --expires 8h)
# or for a specific user: -- --sub 8d1c3f8e-5b7a-4e0c-9a51-0f8a2c1d4b6e --expires 7d

# 3. Call the API
curl -i -H "Authorization: Bearer $TOKEN" http://localhost:5080/v1/me
```

With Docker Compose, put the key in `.env` as `CALI_DEV_TOKEN_SIGNING_KEY` and export it for the tool:
`export Auth__DevTokens__SigningKey=<same key>`. The tool writes only the token to stdout.
Lifetimes are capped at 30 days. The user id comes only from the token's `sub` claim.

## Endpoints

| Route | Auth | Notes |
|---|---|---|
| `GET /health/live` | anonymous | Process is up. No DB access. |
| `GET /health/ready` | anonymous | `SELECT 1` against PostgreSQL. Returns 200 or 503. |
| `GET /v1/me` | bearer | `UserProfile` from `users`; 404 `user_not_found` if the row is missing. |

Every other route requires authentication by default (fallback policy). Errors are
`application/problem+json` with `type`, `title`, `status`, a stable `code` and `traceId`. Request bodies,
`Authorization` headers and tokens are never logged.

Rate-limit policies `auth`, `sync` and `ai` are configured under `RateLimiting:*`. Endpoints attach them
with `.RequireRateLimiting(RateLimitPolicies.Sync)` and similar calls. Telemetry: `Telemetry:Exporter` = `none` |
`console` | `otlp`.

## Tests

```bash
cd backend
dotnet build Cali.sln
dotnet test Cali.sln                               # needs Docker for the integration tests
dotnet test tests/Cali.UnitTests                   # no Docker
dotnet test tests/Cali.ContractTests               # no Docker
```

The integration tests start `postgres:16.15` with Testcontainers and create a fresh database per test.
If the Testcontainers resource reaper image cannot be pulled (restricted networks), set
`TESTCONTAINERS_RYUK_DISABLED=true`. Containers are still disposed by the test fixture.

CI: `.github/workflows/backend.yml` (restore, build, test and a migrate-from-blank job).
