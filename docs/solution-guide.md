# Solution guide — Session 8

Answers to every question in [`participant-lab.md`](participant-lab.md), plus the reasoning
behind them.

> Observed values below come from a B1 Linux plan with `Lab__OrderCount=25` and
> `Lab__SimulatedLatencyMs=60`, driven by the local load generator with 5 concurrent
> callers for 60 seconds. Your numbers will differ with region, round-trip time, SKU and
> client. The **shape** of the result is what matters, not the exact values.

---

## The short version

| | |
|---|---|
| **Symptom** | `GET /api/orders` takes seconds; every other route is fast |
| **Platform verdict** | Healthy. Low CPU, low memory, zero 5xx, health check green, no restarts |
| **Root cause** | The endpoint performs one catalog lookup **per order on the page**, serially, and caches nothing between requests |
| **Why CPU was low** | The request spends its time **waiting** on dependency calls, not computing |
| **Fix** | One batched lookup for all orders on the page, plus a short-lived cache |
| **Result** | P95 falls from ~2.3 s to ~0.08 s; catalog calls per request fall from 25 to ~0 — same SKU, same instance count, same data returned |

---

## Step 1 — Reproduce the complaint

Representative baseline:

| Measurement | Typical value |
|---|---|
| P50 | ~1,800 ms |
| P95 | ~2,300 ms |
| Requests per second | ~2.7 |
| Failures | 0 |
| `/api/products` P95 (control) | ~60 ms |

**1.1 — One route slow, one route fast, same app and instance.**
It rules out anything that would affect the whole worker equally: the plan being too small,
a saturated instance, a platform outage, a networking problem on the front end, TLS
overhead, cold start. A shared cause would slow *every* route. The problem is specific to
what `/api/orders` does that `/api/products` does not — which means it is in the
application's own work, not underneath it.

**1.2 — Why measure first.**
Three reasons. You cannot prove an improvement without a baseline captured under the same
conditions. "Slow" is unfalsifiable; P95 is not. And a measured baseline protects you from
the most common failure mode in performance work: changing several things at once and
claiming credit for whichever one you liked best.

---

## Step 2 — Is the platform unhealthy?

| Metric | Reading | Meaning |
|---|---|---|
| Average Response Time | High (seconds) | The complaint is real |
| CPU Percentage | Low (typically under 10%) | Not CPU-bound |
| Memory Percentage | Low, flat | Not a leak, not GC pressure |
| Http 5xx | Zero | Nothing is erroring |
| Requests | Steady | Throughput is limited by latency, not demand |
| Health check | Healthy throughout | No instance replacement, no restarts |

**2.1 — Working versus waiting.**
A CPU-bound request *consumes* processor time: CPU percentage rises with load. A
latency-bound request *awaits* something external, releasing its thread while it waits — the
clock runs but the CPU stays idle. Here the CPU is idle, so the request is waiting.

A bigger SKU gives you more CPU and memory. Neither shortens a wait. Scaling up would cost
more and change the customer-visible symptom approximately not at all. This is the central
point of the session.

**2.2 — What scaling up would change.**
Latency per request: essentially nothing. Billing: increased, immediately and indefinitely.
It would also end the investigation prematurely, leaving a defect in production that would
resurface the moment the page size grew.

**2.3 — Zero 5xx is information, not comfort.**
It rules out crashes, unhandled exceptions, request timeouts, worker recycling and
dependency failures. It confirms the application is doing its work correctly — just slowly.
Availability monitoring alone would have shown this service as 100% healthy, which is
exactly why latency belongs in your alerting, not just error rate.

---

## Step 3 — Where the time goes

Query 1 output:

| name | requests | p50 | p95 |
|---|---|---|---|
| `GET /api/orders` | ~160 | ~1,800 ms | ~2,300 ms |
| `GET /api/products` | ~250 | ~5 ms | ~15 ms |
| `GET /health` | ~60 | ~2 ms | ~8 ms |

Query 3 output:

| Measurement | Typical value |
|---|---|
| Average dependency calls per request | **25** |
| Average request duration | ~1,800 ms |
| Percent of request spent in dependencies | **~97%** |

**3.1 — Does it match your own measurement?**
It should, and checking is the habit worth building. Client-side measurement includes
network round-trip and TLS; server-side telemetry does not. If they disagree by a lot, the
difference itself is the next clue — here they agree, so the time is being spent on the
server, inside the application.

**3.2 — Twenty-five dependency calls per page view.**
Exactly one per order returned. That one-to-one relationship between items on the page and
calls to the backing store is the fingerprint of an **N+1 access pattern**.

**3.3 — A single call takes ~60 ms.**
That is not a problem. If someone showed you a 60 ms query in isolation you would approve
it in code review without hesitation. The defect is invisible at the level of one call and
obvious at the level of one request. This is why "dependency calls per request" deserves to
be a metric you look at routinely.

---

## Step 4 — One request, in detail

**4.1 — Shape of the waterfall.**
The dependency spans are laid out **sequentially**: each one starts only after the previous
one ends, forming a staircase that spans nearly the whole request bar. Parallel calls would
overlap vertically and finish near the start of the request. Serial execution is visible
directly in the timeline — no inference needed.

**4.2 — Would parallelising fix it?**
It would *improve* the number and *hide* the defect. Twenty-five concurrent calls would
return in roughly the time of one, so latency would drop — but you would still be making 25
calls per page view. You would have moved the cost onto the backing store: 25× the
connections, 25× the query load, multiplied by every concurrent user. It typically fails
later, harder, and under exactly the load you most wanted it to survive.

Make **fewer** calls. Then, if necessary, make them faster.

---

## Step 5 — Root cause

> **The order history endpoint queries the catalog once for every order on the page, one
> call after another, and caches nothing between requests. Each individual call is fast;
> twenty-five sequential calls are not. Response time scales with page size rather than
> with load, which is why CPU stayed low and why adding instances would not have improved a
> single request.**

| | Answer |
|---|---|
| Symptom the customer reported | The order history page takes several seconds to load |
| Component that is slow | The application's order history endpoint |
| Component that is *not* at fault | Azure App Service — the platform served every request successfully, with low CPU and no errors |
| Specific inefficient behaviour | One catalog lookup per order (N+1), executed serially, with no caching between requests |
| Why CPU stayed low | The thread was released while awaiting each call; the request waited rather than computed |
| Why more instances would not help | Instance count affects concurrency, not the duration of a single request. Each instance would be equally slow per request |

The code, in [`OrderService.cs`](../src/PerfLab.Api/OrderService.cs):

```csharp
foreach (var order in orders)
{
    var category = await _catalog.GetCategoryAsync(order.ProductId, cancellationToken);
    summaries.Add(new OrderSummary(..., category, ...));
}
```

An `await` inside a `foreach`. Correct, readable, well-named, and the most common
performance defect in line-of-business applications.

---

## Step 6 — Remediation

```csharp
var productIds = orders.Select(o => o.ProductId).Distinct().ToArray();

if (!_cache.TryGetValue(CatalogCacheKey, out Dictionary<int, string>? categories))
{
    categories = new(await _catalog.GetCategoriesAsync(productIds, cancellationToken));
    _cache.Set(CatalogCacheKey, categories, TimeSpan.FromSeconds(60));
}

var summaries = orders.Select(o => new OrderSummary(..., categories[o.ProductId], ...)).ToList();
```

Three properties worth stating explicitly:

1. **Identical output.** Same orders, same categories, same JSON. The smoke test asserts
   this, because a "fix" that quietly returns less data is not a fix.
2. **One call instead of N.** 25 → 1 on a cache miss.
3. **Zero calls on a cache hit.** 1 → 0 for the next 60 seconds.

**6.1 — Why not change the SKU or instance count.**
Because the evidence did not point there. Scaling is a response to *resource exhaustion*,
and nothing was exhausted. Scaling to mask an application defect raises cost permanently,
leaves the defect in place, and guarantees the problem returns as data volume grows. Fix
the access pattern; scale later for real demand, with evidence.

**6.2 — Batching or caching: which matters more?**

**Batching.** Remove the cache and every request still drops from 25 calls to 1 — a ~25×
reduction in work and roughly the same latency improvement. Remove the batching and keep
the cache and the first request after every expiry still makes 25 serial calls, so the
defect is merely intermittent, which is worse to diagnose than a defect that is constant.

The general rule: **a cache is not a fix for an inefficient access pattern.** Fix the
pattern first; add caching afterwards as a deliberate trade-off against staleness.

---

## Step 7 — Proof

Representative before/after, same workload, same infrastructure:

| Measurement | Before (Baseline) | After (Optimized) | Change |
|---|---|---|---|
| P50 | ~1,800 ms | ~45 ms | ~40× faster |
| P95 | ~2,300 ms | ~80 ms | ~28× faster |
| Requests per second | ~2.7 | ~95 | ~35× higher |
| Catalog calls per request | 25 | ~0 | eliminated |
| Failures | 0 | 0 | unchanged |
| App Service Plan SKU | B1 | B1 | **unchanged** |
| Instance count | 1 | 1 | **unchanged** |

**7.1 — CPU after the fix.**
Still low. It never was the constraint. The only thing that changed is how much time each
request spends waiting — which confirms the original diagnosis rather than merely being
consistent with it. If CPU had been the bottleneck, removing the waiting would have pushed
CPU up, not left it flat.

**7.2 — Why the same workload matters.**
Because otherwise the comparison proves nothing. Change the concurrency, the duration, the
page size or the client location and a reviewer can reasonably attribute the improvement to
the measurement rather than to the fix. Identical workload, identical infrastructure, one
variable changed — that is the difference between evidence and a story.

Also exclude warm-up from both runs, as the load generator does by default. A cold start
counted in only one of the two runs would be a measurement artefact masquerading as a
result.

**7.3 — The customer update.**

> "The slowdown on the order history page was caused by the page requesting catalog details
> once for every order it displayed, one request at a time, instead of requesting them
> together. We have changed that to a single batched lookup with short-lived caching, and
> the page now loads in well under a tenth of a second — around 25 times faster — with no
> change to your App Service plan or cost."

Lead with impact. Name the behaviour, not the file. State the result as the customer
experiences it. Say explicitly that it cost nothing extra, because that is the part they
will repeat to their own management.

---

## What transfers to real environments

The lab is a simulation. The method is not.

1. **Begin with customer impact.** Reproduce it and measure it before touching anything.
2. **Separate platform health from application behaviour.** High response time with low CPU
   means waiting, not working — and waiting is almost never fixed by buying more compute.
3. **Count dependency calls per request.** It is the fastest way to find N+1 patterns, and
   almost nobody looks at it until something is already on fire.
4. **Prefer fewer calls over faster calls.** Parallelising an N+1 pattern moves the cost; it
   does not remove it.
5. **Treat caching as a trade-off, not a fix.** Bound the staleness and say so out loud.
6. **Prove the improvement with the identical workload.** A fix you cannot measure is a
   claim, not an outcome.
7. **Alert on latency, not just availability.** This service was 100% available and badly
   broken from the customer's point of view, for the entire incident.
