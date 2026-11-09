using Cali.Application.Catalog;
using Cali.Application.Plans;
using Cali.Application.Identity;
using Cali.Application.Sync;
using Cali.Infrastructure.Persistence;
using Cali.Infrastructure.Persistence.Migrations;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;

namespace Cali.Infrastructure;

public static class DependencyInjection
{
    public const string ConnectionStringName = "Cali";

    public static IServiceCollection AddCaliInfrastructure(this IServiceCollection services)
    {
        // Resolved lazily from IConfiguration so hosts/tests can override settings after registration.
        services.AddSingleton(sp =>
        {
            var connectionString = sp.GetRequiredService<IConfiguration>().GetConnectionString(ConnectionStringName);
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new InvalidOperationException(
                    $"Connection string '{ConnectionStringName}' is not configured (env ConnectionStrings__{ConnectionStringName}).");
            }

            return NpgsqlDataSource.Create(connectionString);
        });

        services.AddOptions<MigrationOptions>().BindConfiguration(MigrationOptions.SectionName);
        services.AddSingleton<DatabaseMigrator>();
        services.AddScoped<IUserProfileReader, UserProfileReader>();
        services.AddScoped<IExerciseCatalogReader, ExerciseCatalogReader>();
        services.AddScoped<ICriteriaConfigReader, CriteriaConfigReader>();
        services.AddScoped<IPlanReader, PlanReader>();
        services.AddScoped<IPlanWriter, PlanWriter>();
        services.AddScoped<ISyncWriter, SyncWriter>();
        return services;
    }
}
