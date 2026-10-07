using System.Diagnostics;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace PerfLab.Api;

public sealed record OrderSummary(int OrderId, string Customer, int ProductId, string ProductCategory, decimal Total);

public sealed record OrdersResponse(string Mode, int Count, int CatalogCalls, long ElapsedMs, IReadOnlyList<OrderSummary> Orders);

/// <summary>
/// The whole lesson of the lab lives in this file.
///
/// Both code paths return exactly the same orders. Only the way they talk to the catalog
/// differs, which is why the "before" and "after" runs of the identical workload can be
/// compared directly.
/// </summary>
public sealed class OrderService
{
    private const string CatalogCacheKey = "catalog:categories";

    private readonly SimulatedCatalog _catalog;
    private readonly IMemoryCache _cache;
    private readonly IOptionsMonitor<LabOptions> _options;
    private readonly ILogger<OrderService> _logger;

    public OrderService(
        SimulatedCatalog catalog,
        IMemoryCache cache,
        IOptionsMonitor<LabOptions> options,
        ILogger<OrderService> logger)
    {
        _catalog = catalog;
        _cache = cache;
        _options = options;
        _logger = logger;
    }

    public async Task<OrdersResponse> GetOrdersAsync(int count, CancellationToken cancellationToken)
    {
        var options = _options.CurrentValue;
        var stopwatch = Stopwatch.StartNew();

        var orders = BuildOrders(count);

        var (summaries, catalogCalls) = options.Mode == LabMode.Optimized
            ? await BuildOptimizedAsync(orders, cancellationToken)
            : await BuildBaselineAsync(orders, cancellationToken);

        stopwatch.Stop();

        Activity.Current?.SetTag("lab.mode", options.Mode.ToString());
        Activity.Current?.SetTag("lab.order_count", summaries.Count);
        Activity.Current?.SetTag("lab.catalog_calls", catalogCalls);

        _logger.LogInformation(
            "Returned {OrderCount} orders in {Mode} mode using {CatalogCalls} catalog call(s) in {ElapsedMs} ms.",
            summaries.Count, options.Mode, catalogCalls, stopwatch.ElapsedMilliseconds);

        return new OrdersResponse(
            options.Mode.ToString(),
            summaries.Count,
            catalogCalls,
            stopwatch.ElapsedMilliseconds,
            summaries);
    }

    // BEFORE (the defect): one catalog round trip per order, executed one after another,
    // and nothing is cached between requests. Response time grows linearly with the page
    // size while CPU stays almost idle - the request is waiting, not working.
    private async Task<(IReadOnlyList<OrderSummary> Orders, int CatalogCalls)> BuildBaselineAsync(
        IReadOnlyList<Order> orders,
        CancellationToken cancellationToken)
    {
        var summaries = new List<OrderSummary>(orders.Count);
        var catalogCalls = 0;

        foreach (var order in orders)
        {
            var category = await _catalog.GetCategoryAsync(order.ProductId, cancellationToken);
            catalogCalls++;
            summaries.Add(new OrderSummary(order.OrderId, order.Customer, order.ProductId, category, order.Total));
        }

        return (summaries, catalogCalls);
    }

    // AFTER (the fix): request every category the page needs in a single call, and keep the
    // result in memory for a short, bounded period. Same response, one round trip instead of N.
    private async Task<(IReadOnlyList<OrderSummary> Orders, int CatalogCalls)> BuildOptimizedAsync(
        IReadOnlyList<Order> orders,
        CancellationToken cancellationToken)
    {
        var productIds = orders.Select(o => o.ProductId).Distinct().ToArray();
        var catalogCalls = 0;

        if (!_cache.TryGetValue(CatalogCacheKey, out Dictionary<int, string>? categories) || categories is null)
        {
            var fetched = await _catalog.GetCategoriesAsync(productIds, cancellationToken);
            catalogCalls = 1;
            categories = new Dictionary<int, string>(fetched);

            _cache.Set(
                CatalogCacheKey,
                categories,
                TimeSpan.FromSeconds(Math.Max(1, _options.CurrentValue.CatalogCacheSeconds)));
        }
        else
        {
            var missing = productIds.Where(id => !categories.ContainsKey(id)).ToArray();
            if (missing.Length > 0)
            {
                var fetched = await _catalog.GetCategoriesAsync(missing, cancellationToken);
                catalogCalls = 1;
                categories = new Dictionary<int, string>(categories);
                foreach (var pair in fetched)
                {
                    categories[pair.Key] = pair.Value;
                }

                _cache.Set(
                    CatalogCacheKey,
                    categories,
                    TimeSpan.FromSeconds(Math.Max(1, _options.CurrentValue.CatalogCacheSeconds)));
            }
        }

        var summaries = orders
            .Select(o => new OrderSummary(o.OrderId, o.Customer, o.ProductId, categories[o.ProductId], o.Total))
            .ToList();

        return (summaries, catalogCalls);
    }

    /// <summary>Deterministic, fictional order data. No external call, no randomness.</summary>
    private static IReadOnlyList<Order> BuildOrders(int count)
    {
        var orders = new List<Order>(count);
        for (var i = 1; i <= count; i++)
        {
            orders.Add(new Order(
                OrderId: 1000 + i,
                Customer: $"Contoso Customer {i:00}",
                ProductId: 100 + (i % 20),
                Total: 19.99m + i));
        }

        return orders;
    }

    private sealed record Order(int OrderId, string Customer, int ProductId, decimal Total);
}
