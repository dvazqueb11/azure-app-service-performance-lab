# KQL queries for the investigation

Run these in **Application Insights → Logs** (or in the Log Analytics workspace, where the
App Service platform logs also land).

Telemetry ingestion is not instant. Allow roughly **2–5 minutes** after a load run before
expecting complete data. If a query returns nothing, widen the time range before assuming
something is broken.

---

## 1. Start with customer impact: which route is slow?

```kusto
requests
| where timestamp > ago(1h)
| summarize
    requests = count(),
    p50 = percentile(duration, 50),
    p95 = percentile(duration, 95),
    p99 = percentile(duration, 99),
    failures = countif(success == false)
  by name
| order by p95 desc
```

Expected during the baseline run: `GET /api/orders` shows seconds, `GET /api/products` and
`GET /health` stay in milliseconds. One slow route and several fast routes is the first
piece of evidence that the platform is not the common factor.

---

## 2. Is it getting worse over time, or is it constant?

```kusto
requests
| where timestamp > ago(1h)
| where name has "/api/orders"
| summarize p95 = percentile(duration, 95), requests = count() by bin(timestamp, 1m)
| render timechart
```

A flat line under steady load points at a fixed per-request cost, not at resource
exhaustion building up.

---

## 3. Where does the time actually go? Requests versus dependencies

```kusto
let window = 1h;
requests
| where timestamp > ago(window)
| where name has "/api/orders"
| project operation_Id, requestDuration = duration, timestamp
| join kind=inner (
    dependencies
    | where timestamp > ago(window)
    | summarize dependencyCalls = count(), dependencyMs = sum(duration) by operation_Id
) on operation_Id
| summarize
    requests = count(),
    avgDependencyCallsPerRequest = avg(dependencyCalls),
    avgRequestMs = avg(requestDuration),
    avgDependencyMs = avg(dependencyMs)
| extend percentOfRequestSpentInDependencies = round(100.0 * avgDependencyMs / avgRequestMs, 1)
```

This is the decisive query. In baseline mode it shows roughly **25 dependency calls per
request** and nearly all of the request duration spent inside them.

---

## 4. Which dependency, and how expensive is each call?

```kusto
dependencies
| where timestamp > ago(1h)
| summarize calls = count(), avgMs = avg(duration), totalMs = sum(duration) by name, type, target
| order by totalMs desc
```

Each individual call is small. The total is large because there are many of them. That
distinction is the lesson: the fix is to make *fewer* calls, not *faster* ones.

---

## 5. Confirm the application's own view

```kusto
traces
| where timestamp > ago(1h)
| where message has "orders in"
| project timestamp, message, severityLevel
| order by timestamp desc
| take 50
```

The application logs the mode, the catalog call count and the elapsed time for every
request, so the application view and the dependency view can be checked against each other.

---

## 6. Split request performance by lab mode (the before/after proof)

```kusto
requests
| where timestamp > ago(2h)
| where name has "/api/orders"
| extend mode = tostring(customDimensions["lab.mode"]),
         catalogCalls = toint(customDimensions["lab.catalog_calls"])
| summarize
    requests = count(),
    p50 = percentile(duration, 50),
    p95 = percentile(duration, 95),
    avgCatalogCalls = avg(catalogCalls)
  by mode
| order by p95 desc
```

One table, two rows, same workload, same code path, same instance count. This is the
evidence to show a customer.

---

## 7. Was the platform ever the problem?

```kusto
AppServiceHTTPLogs
| where TimeGenerated > ago(1h)
| summarize
    requests = count(),
    avgLatencyMs = avg(TimeTaken),
    serverErrors = countif(ScStatus >= 500)
  by bin(TimeGenerated, 5m), CsUriStem
| order by TimeGenerated asc
```

The platform HTTP logs agree with the application telemetry: requests are arriving,
being served, and returning HTTP 200 — slowly. No 5xx, no rejections, no restarts.

Pair this with the platform metrics in **App Service → Metrics**:

| Metric | Baseline expectation | What it tells you |
|---|---|---|
| Average Response Time | High (seconds) | Customers are right: it is slow |
| CPU Percentage | Low | The instance is not CPU bound |
| Memory Percentage | Low and flat | Not a memory leak |
| Http 5xx | Zero | Nothing is failing, just waiting |
| Requests | Steady | Throughput is limited by latency, not by load |

High response time with low CPU is the signature of a request that is **waiting**, not
**working**.

---

## 8. Did anything actually fail?

```kusto
exceptions
| where timestamp > ago(1h)
| summarize count() by type, outerMessage
| order by count_ desc
```

Expected result: empty. A slow application is not a failing application, and a clean
exception list is itself a finding worth stating out loud.
