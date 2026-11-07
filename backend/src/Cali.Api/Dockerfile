# syntax=docker/dockerfile:1
# Build context: repository root (needs backend/ and db/).
#   docker build -f backend/src/Cali.Api/Dockerfile -t cali-api .

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first for layer caching.
COPY backend/global.json backend/Directory.Build.props backend/Directory.Packages.props backend/
COPY backend/src/Cali.Domain/Cali.Domain.csproj backend/src/Cali.Domain/
COPY backend/src/Cali.Application/Cali.Application.csproj backend/src/Cali.Application/
COPY backend/src/Cali.Infrastructure/Cali.Infrastructure.csproj backend/src/Cali.Infrastructure/
COPY backend/src/Cali.Api/Cali.Api.csproj backend/src/Cali.Api/
RUN dotnet restore backend/src/Cali.Api/Cali.Api.csproj

COPY backend/src/ backend/src/
RUN dotnet publish backend/src/Cali.Api/Cali.Api.csproj -c Release -o /app/publish --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish ./
# Migration scripts ship with the image; `dotnet Cali.Api.dll migrate` applies them.
COPY db/*.sql /app/db/
ENV ASPNETCORE_HTTP_PORTS=8080 \
    Migrations__ScriptsPath=/app/db \
    DOTNET_gcServer=0
EXPOSE 8080
# Built-in non-root user of the .NET images.
USER $APP_UID
ENTRYPOINT ["dotnet", "Cali.Api.dll"]
