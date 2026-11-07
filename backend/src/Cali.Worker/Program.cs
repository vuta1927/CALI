using Cali.Worker;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddOptions<HeartbeatOptions>().BindConfiguration(HeartbeatOptions.SectionName);
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(20));
builder.Services.AddHostedService<HeartbeatWorker>();

await builder.Build().RunAsync().ConfigureAwait(false);
