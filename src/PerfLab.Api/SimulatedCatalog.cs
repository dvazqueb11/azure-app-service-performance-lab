using System.Diagnostics;
using Microsoft.Extensions.Options;

namespace PerfLab.Api;

/// <summary>
/// Stands in for a slow backing store (a database, a cache, or an internal service).
/// Nothing leaves the process: the latency is simulated with an asynchronous delay so the
/// lab stays deterministic, free, and independent of any external service.
///
/// Every lookup is reported as an OpenTelemetry client span, so Application Insights shows
/// it on the end-to-end transaction as a dependency call. That is what lets participants
/// see "one request, many dependency calls" in the portal.
/// </summary>
public sealed class SimulatedCatalog
{
    public static readonly ActivitySource ActivitySource = new("PerfLab.Api.Catalog");

    private static readonly string[] Categories =
    [
        "Outdoor", "Kitchen", "Office", "Audio", "Fitness", "Garden", "Travel", "Lighting"
    ];

    private readonly IOptionsMonitor<LabOptions> _options;

    public SimulatedCatalog(IOptionsMonitor<LabOptions> options) => _options = options;

    /// <summary>Inefficient access pattern: one round trip per product.</summary>
    public async Task<string> GetCategoryAsync(int productId, CancellationToken cancellationToken)
    {
        using var activity = ActivitySource.StartActivity("Catalog GetCategory", ActivityKind.Client);
        activity?.SetTag("catalog.operation", "GetCategory");
        activity?.SetTag("catalog.product_id", productId);
        activity?.SetTag("catalog.batch_size", 1);

        await Task.Delay(_options.CurrentValue.SimulatedLatencyMs, cancellationToken);
        return CategoryFor(productId);
    }

    /// <summary>Efficient access pattern: a single round trip for every product needed.</summary>
    public async Task<IReadOnlyDictionary<int, string>> GetCategoriesAsync(
        IReadOnlyCollection<int> productIds,
        CancellationToken cancellationToken)
    {
        using var activity = ActivitySource.StartActivity("Catalog GetCategories", ActivityKind.Client);
        activity?.SetTag("catalog.operation", "GetCategories");
        activity?.SetTag("catalog.batch_size", productIds.Count);

        await Task.Delay(_options.CurrentValue.SimulatedLatencyMs, cancellationToken);
        return productIds.Distinct().ToDictionary(id => id, CategoryFor);
    }

    private static string CategoryFor(int productId) => Categories[Math.Abs(productId) % Categories.Length];
}
