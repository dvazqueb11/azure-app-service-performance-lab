using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

// ---------------------------------------------------------------------------------------
// PerfLab.LoadGen - a deliberately small, local, closed-loop load generator.
//
// It runs entirely on the instructor's or participant's machine. No Azure Load Testing
// resource is deployed, so the lab stays low cost and has nothing extra to clean up.
// Concurrency and duration are capped so the tool cannot be pointed at something it
// should not be pointed at.
// ---------------------------------------------------------------------------------------

const int MaxConcurrency = 20;

var options = CommandLine.Parse(args);
if (options is null)
{
    CommandLine.PrintUsage();
    return 2;
}

var target = new Uri(options.BaseUrl.TrimEnd('/') + options.Path);

Console.WriteLine($"Target       : {target}");
Console.WriteLine($"Label        : {options.Label}");
Console.WriteLine($"Concurrency  : {options.Concurrency}");
Console.WriteLine($"Duration     : {options.DurationSeconds}s");
Console.WriteLine($"Warm-up      : {options.WarmupSeconds}s");
Console.WriteLine();

using var handler = new SocketsHttpHandler
{
    PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    MaxConnectionsPerServer = MaxConcurrency * 2,
    AutomaticDecompression = System.Net.DecompressionMethods.All
};
using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(100) };
http.DefaultRequestHeaders.UserAgent.ParseAdd("PerfLab-LoadGen/1.0");

// Warm-up: the first request after a deployment or restart pays cold-start cost. Measuring
// it would make the before/after comparison noisy, so it is excluded on purpose.
if (options.WarmupSeconds > 0)
{
    Console.WriteLine("Warming up...");
    var warmupEnd = DateTime.UtcNow.AddSeconds(options.WarmupSeconds);
    while (DateTime.UtcNow < warmupEnd)
    {
        try
        {
            using var response = await http.GetAsync(target);
            _ = await response.Content.ReadAsByteArrayAsync();
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            // Ignore: the site may still be starting.
        }
    }
}

var latencies = new List<double>(capacity: 4096);
var latencyLock = new object();
var statusCounts = new Dictionary<int, int>();
var failures = 0;
string? observedMode = null;
string? observedCatalogCalls = null;

Console.WriteLine("Running...");
using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(options.DurationSeconds));
var runStopwatch = Stopwatch.StartNew();

var workers = Enumerable.Range(0, options.Concurrency).Select(async workerId =>
{
    while (!cts.IsCancellationRequested)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            using var response = await http.GetAsync(target, cts.Token);
            _ = await response.Content.ReadAsByteArrayAsync(cts.Token);
            sw.Stop();

            if (response.Headers.TryGetValues("x-lab-mode", out var modeValues))
            {
                observedMode = modeValues.FirstOrDefault();
            }

            if (response.Headers.TryGetValues("x-lab-catalog-calls", out var callValues))
            {
                observedCatalogCalls = callValues.FirstOrDefault();
            }

            lock (latencyLock)
            {
                latencies.Add(sw.Elapsed.TotalMilliseconds);
                var code = (int)response.StatusCode;
                statusCounts[code] = statusCounts.GetValueOrDefault(code) + 1;
                if (code >= 400)
                {
                    failures++;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Expected when the run window closes.
        }
        catch (Exception ex)
        {
            sw.Stop();
            lock (latencyLock)
            {
                failures++;
                statusCounts[0] = statusCounts.GetValueOrDefault(0) + 1;
            }

            if (failures <= 3)
            {
                Console.WriteLine($"  request error: {ex.GetType().Name}: {ex.Message}");
            }
        }
    }
}).ToArray();

await Task.WhenAll(workers);
runStopwatch.Stop();

if (latencies.Count == 0)
{
    Console.WriteLine();
    Console.WriteLine("No successful samples were collected. Check the URL and that the app is running.");
    return 1;
}

latencies.Sort();
var summary = new Summary(
    Label: options.Label,
    Url: target.ToString(),
    Mode: observedMode ?? "unknown",
    CatalogCallsPerRequest: observedCatalogCalls ?? "unknown",
    Requests: latencies.Count,
    Failures: failures,
    DurationSeconds: Math.Round(runStopwatch.Elapsed.TotalSeconds, 1),
    RequestsPerSecond: Math.Round(latencies.Count / runStopwatch.Elapsed.TotalSeconds, 2),
    AverageMs: Math.Round(latencies.Average(), 1),
    P50Ms: Math.Round(Percentile(latencies, 50), 1),
    P95Ms: Math.Round(Percentile(latencies, 95), 1),
    P99Ms: Math.Round(Percentile(latencies, 99), 1),
    MaxMs: Math.Round(latencies[^1], 1),
    StatusCounts: statusCounts.ToDictionary(k => k.Key.ToString(CultureInfo.InvariantCulture), v => v.Value),
    TimestampUtc: DateTime.UtcNow);

Console.WriteLine();
Console.WriteLine("==================== RESULT ====================");
Console.WriteLine($" Label                  : {summary.Label}");
Console.WriteLine($" Reported mode          : {summary.Mode}");
Console.WriteLine($" Catalog calls/request  : {summary.CatalogCallsPerRequest}");
Console.WriteLine($" Requests               : {summary.Requests} ({summary.RequestsPerSecond} req/s)");
Console.WriteLine($" Failures               : {summary.Failures}");
Console.WriteLine($" Average                : {summary.AverageMs} ms");
Console.WriteLine($" P50 / P95 / P99        : {summary.P50Ms} / {summary.P95Ms} / {summary.P99Ms} ms");
Console.WriteLine($" Max                    : {summary.MaxMs} ms");
Console.WriteLine($" Status codes           : {string.Join(", ", summary.StatusCounts.Select(s => $"{s.Key}={s.Value}"))}");
Console.WriteLine("================================================");

if (!string.IsNullOrWhiteSpace(options.OutputPath))
{
    var json = JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = true });
    var fullPath = Path.GetFullPath(options.OutputPath);
    Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
    await File.WriteAllTextAsync(fullPath, json);
    Console.WriteLine($"Saved results to {fullPath}");
}

return failures > 0 ? 1 : 0;

static double Percentile(List<double> sorted, double percentile)
{
    if (sorted.Count == 1)
    {
        return sorted[0];
    }

    var rank = percentile / 100d * (sorted.Count - 1);
    var low = (int)Math.Floor(rank);
    var high = (int)Math.Ceiling(rank);
    return sorted[low] + ((sorted[high] - sorted[low]) * (rank - low));
}

internal sealed record Summary(
    string Label,
    string Url,
    string Mode,
    string CatalogCallsPerRequest,
    int Requests,
    int Failures,
    double DurationSeconds,
    double RequestsPerSecond,
    double AverageMs,
    double P50Ms,
    double P95Ms,
    double P99Ms,
    double MaxMs,
    Dictionary<string, int> StatusCounts,
    DateTime TimestampUtc);

internal sealed record LoadOptions(
    string BaseUrl,
    string Path,
    int Concurrency,
    int DurationSeconds,
    int WarmupSeconds,
    string Label,
    string? OutputPath);

internal static class CommandLine
{
    public static LoadOptions? Parse(string[] args)
    {
        string? baseUrl = null;
        var path = "/api/orders";
        var concurrency = 5;
        var duration = 60;
        var warmup = 10;
        string? label = null;
        string? output = null;

        for (var i = 0; i < args.Length; i++)
        {
            var current = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"Missing value for {current}");

            switch (current.ToLowerInvariant())
            {
                case "--url":
                case "-u":
                    baseUrl = Next();
                    break;
                case "--path":
                case "-p":
                    path = Next();
                    break;
                case "--concurrency":
                case "-c":
                    concurrency = int.Parse(Next(), CultureInfo.InvariantCulture);
                    break;
                case "--duration":
                case "-d":
                    duration = int.Parse(Next(), CultureInfo.InvariantCulture);
                    break;
                case "--warmup":
                case "-w":
                    warmup = int.Parse(Next(), CultureInfo.InvariantCulture);
                    break;
                case "--label":
                case "-l":
                    label = Next();
                    break;
                case "--out":
                case "-o":
                    output = Next();
                    break;
                case "--help":
                case "-h":
                    return null;
                default:
                    Console.WriteLine($"Unknown argument: {current}");
                    return null;
            }
        }

        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            Console.WriteLine("--url is required.");
            return null;
        }

        if (!baseUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !baseUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            baseUrl = "https://" + baseUrl;
        }

        if (!path.StartsWith('/'))
        {
            path = "/" + path;
        }

        concurrency = Math.Clamp(concurrency, 1, 20);
        duration = Math.Clamp(duration, 5, 600);
        warmup = Math.Clamp(warmup, 0, 120);

        return new LoadOptions(baseUrl, path, concurrency, duration, warmup, label ?? "run", output);
    }

    public static void PrintUsage()
    {
        Console.WriteLine("""
            PerfLab local load generator

            Usage:
              dotnet run --project loadgen/PerfLab.LoadGen -- --url <site-url> [options]

            Options:
              -u, --url          Required. Base URL, for example https://app-perflab-abc123.azurewebsites.net
              -p, --path         Path to call. Default: /api/orders
              -c, --concurrency  Parallel callers, 1-20. Default: 5
              -d, --duration     Measurement window in seconds, 5-600. Default: 60
              -w, --warmup       Warm-up seconds excluded from results, 0-120. Default: 10
              -l, --label        Label recorded in the output, for example before or after
              -o, --out          Optional path for a JSON result file

            Examples:
              dotnet run --project loadgen/PerfLab.LoadGen -- -u https://site.azurewebsites.net -l before -o results/before.json
              dotnet run --project loadgen/PerfLab.LoadGen -- -u https://site.azurewebsites.net -p /api/products -l control
            """);
    }
}
