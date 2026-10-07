namespace PerfLab.Api;

/// <summary>
/// Behaviour switches for the lab. Bound from the "Lab" configuration section, which on
/// Azure App Service is supplied by the app settings Lab__Mode, Lab__OrderCount and
/// Lab__SimulatedLatencyMs.
/// </summary>
public sealed class LabOptions
{
    public const string SectionName = "Lab";

    /// <summary>Baseline reproduces the inefficient behaviour; Optimized is the remediated behaviour.</summary>
    public LabMode Mode { get; set; } = LabMode.Baseline;

    /// <summary>Number of orders returned by /api/orders when the caller does not specify a count.</summary>
    public int OrderCount { get; set; } = 25;

    /// <summary>Latency of a single simulated catalog lookup, in milliseconds.</summary>
    public int SimulatedLatencyMs { get; set; } = 60;

    /// <summary>Upper bound a caller may request through ?count= so the lab cannot be used as a stress tool.</summary>
    public int MaxOrderCount { get; set; } = 50;

    /// <summary>Lifetime of the catalog cache used by the optimized code path.</summary>
    public int CatalogCacheSeconds { get; set; } = 60;
}

public enum LabMode
{
    /// <summary>Per-item ("N+1") catalog lookups, executed serially, with no caching.</summary>
    Baseline = 0,

    /// <summary>One batched catalog lookup, cached for a short period.</summary>
    Optimized = 1
}
