using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.Extensions.Options;
using OpenTelemetry.Trace;
using PerfLab.Api;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOptions<LabOptions>()
    .Bind(builder.Configuration.GetSection(LabOptions.SectionName))
    .Validate(o => o.OrderCount > 0 && o.OrderCount <= o.MaxOrderCount, "Lab:OrderCount must be between 1 and Lab:MaxOrderCount.")
    .Validate(o => o.SimulatedLatencyMs is >= 0 and <= 500, "Lab:SimulatedLatencyMs must be between 0 and 500.")
    .ValidateOnStart();

builder.Services.AddMemoryCache();
builder.Services.AddSingleton<SimulatedCatalog>();
builder.Services.AddSingleton<OrderService>();

// Current, supported instrumentation: the Azure Monitor OpenTelemetry Distro.
// It is only wired up when a connection string is present, so the app still runs locally
// with no Azure resources at all.
var connectionString = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
if (!string.IsNullOrWhiteSpace(connectionString))
{
    var samplingRatio = builder.Configuration.GetValue("Telemetry:SamplingRatio", 1.0f);

    builder.Services
        .AddOpenTelemetry()
        .UseAzureMonitor(options =>
        {
            options.ConnectionString = connectionString;
            options.SamplingRatio = samplingRatio;
        })
        .WithTracing(tracing => tracing.AddSource(SimulatedCatalog.ActivitySource.Name));
}

var app = builder.Build();

// --------------------------------------------------------------------------------------
// GET /health - App Service health check probe.
// Fast, no simulated dependency, no CPU work, no configuration disclosure.
// --------------------------------------------------------------------------------------
app.MapGet("/health", () => Results.Json(new { status = "Healthy" }))
   .WithName("Health");

// --------------------------------------------------------------------------------------
// GET /api/products - healthy control endpoint.
// Proves that not every route is affected, which is how participants learn that a slow
// application is not the same thing as a slow platform.
// --------------------------------------------------------------------------------------
app.MapGet("/api/products", () => Results.Json(new
{
    count = CatalogData.Products.Count,
    products = CatalogData.Products
})).WithName("Products");

// --------------------------------------------------------------------------------------
// GET /api/orders - the endpoint under investigation.
// Behaviour is driven by the Lab:Mode app setting: Baseline (defect) or Optimized (fix).
// --------------------------------------------------------------------------------------
app.MapGet("/api/orders", async (
    OrderService orders,
    IOptionsMonitor<LabOptions> options,
    HttpContext context,
    CancellationToken cancellationToken,
    int? count) =>
{
    var settings = options.CurrentValue;
    var requested = count ?? settings.OrderCount;

    if (requested < 1 || requested > settings.MaxOrderCount)
    {
        return Results.Problem(
            title: "Invalid count",
            detail: $"count must be between 1 and {settings.MaxOrderCount}.",
            statusCode: StatusCodes.Status400BadRequest);
    }

    var response = await orders.GetOrdersAsync(requested, cancellationToken);

    // Surfaced as response headers so the load generator can prove the change without
    // parsing the body, and so participants can see the fix in browser dev tools.
    context.Response.Headers["x-lab-mode"] = response.Mode;
    context.Response.Headers["x-lab-catalog-calls"] = response.CatalogCalls.ToString();

    return Results.Json(response);
}).WithName("Orders");

// --------------------------------------------------------------------------------------
// GET /api/lab/config - non-sensitive echo of the lab switches.
// Used by the deployment and validation scripts to confirm which mode is live.
// --------------------------------------------------------------------------------------
app.MapGet("/api/lab/config", (IOptionsMonitor<LabOptions> options) =>
{
    var settings = options.CurrentValue;
    return Results.Json(new
    {
        mode = settings.Mode.ToString(),
        orderCount = settings.OrderCount,
        maxOrderCount = settings.MaxOrderCount,
        simulatedLatencyMs = settings.SimulatedLatencyMs,
        catalogCacheSeconds = settings.CatalogCacheSeconds,
        telemetryEnabled = !string.IsNullOrWhiteSpace(connectionString),
        runtime = $".NET {Environment.Version}"
    });
}).WithName("LabConfig");

app.Run();

internal static class CatalogData
{
    public static IReadOnlyList<object> Products { get; } =
    [
        new { id = 101, name = "Contoso Trail Bottle", category = "Outdoor", price = 18.50m },
        new { id = 102, name = "Fabrikam Desk Lamp", category = "Lighting", price = 42.00m },
        new { id = 103, name = "Contoso Travel Mug", category = "Kitchen", price = 24.75m },
        new { id = 104, name = "Fabrikam Noise Cut Headset", category = "Audio", price = 96.00m },
        new { id = 105, name = "Contoso Yoga Mat", category = "Fitness", price = 31.25m }
    ];
}
