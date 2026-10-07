# Instructor guide — Session 8

**Hands-on Lab: Diagnose and Remediate Azure App Service Performance Issues**

Duration: 60 minutes · Format: instructor-led demonstration with participant follow-along

---

## 1. The one idea

> An application can be slow on Azure App Service without App Service being the root cause.
> Engineers must begin with customer impact, correlate platform and application evidence,
> identify the inefficient application behaviour, remediate it, and prove the improvement
> using the same workload.

Everything in this session serves that sentence. If participants leave able to say it in
their own words and show the evidence that supports it, the session worked.

### Say this at the start, and mean it

> "This is a controlled simulation built for teaching. It is not a copy of anyone's
> production architecture, and nothing we do here validates anyone's production
> environment. What transfers is the **method**, not the numbers."

---

## 2. Before the session

### The day before (15 minutes)

```powershell
# 1. Confirm the lab still behaves correctly - no Azure needed
pwsh ./scripts/smoke-test.ps1

# 2. Deploy
./scripts/deploy.ps1 -ResourceGroup rg-perflab-demo -Location eastus -Sku B1

# 3. Prime the portal: run a short baseline so telemetry already exists
./scripts/run-load.ps1 -Url https://<site>.azurewebsites.net -Label dryrun -DurationSeconds 60
```

Then open, sign in to, and **leave open** these browser tabs:

| Tab | What |
|---|---|
| 1 | App Service → **Metrics** (Average Response Time, CPU Percentage, Requests, Http 5xx) |
| 2 | Application Insights → **Performance** |
| 3 | Application Insights → **Logs**, with the queries from `docs/kql-queries.md` pasted in and already run once |
| 4 | App Service → **Configuration** → Application settings |
| 5 | `OrderService.cs` in your editor |

Pre-running every query is the single most effective defence against portal latency during
a live session.

### Deploy-day decisions

| Decision | Recommendation |
|---|---|
| SKU | `B1` is enough. Use `S1` or `P0v3` only if the delivery is recorded or the room is large and everyone drives load at once |
| Region | Pick one close to the room; the load generator runs on your machine, so RTT is part of the measured latency |
| Who deploys | **You deploy once and demonstrate.** Participants can deploy into their own subscriptions afterwards using `docs/participant-lab.md` |
| Reset between back-to-back deliveries | `./scripts/reset.ps1 -ResourceGroup rg-perflab-demo` |

---

## 3. Runsheet (60 minutes)

| Time | Segment | Goal |
|---|---|---|
| 0:00–0:05 | Framing and the escalation | Everyone knows what "slow" means to the customer |
| 0:05–0:12 | Reproduce the complaint | A measured baseline, not an opinion |
| 0:12–0:22 | Platform evidence | Rule App Service in or out, with data |
| 0:22–0:35 | Application evidence | Find the inefficient behaviour |
| 0:35–0:42 | Name the root cause | Say it in one sentence, in the customer's language |
| 0:42–0:50 | Remediate | Apply the fix |
| 0:50–0:57 | Prove it | Same workload, measurably better |
| 0:57–1:00 | Close and cleanup | Transfer the method; delete the resource group |

---

### 0:00–0:05 — Framing and the escalation

Read the ticket out loud:

> "Since this morning, our order history page is taking several seconds to load. The
> product catalog page is fine. Nothing was deployed. We think Azure App Service is having
> a problem — can you scale it up?"

Ask the room: **what is the first thing you would do?** Collect answers, then point out
that "scale it up" is a proposed *solution* arriving before any *evidence*, and that the
rest of the hour is about not doing that.

Write three questions on the board and leave them there:

1. What exactly is slow, for whom, and since when?
2. Is the platform unhealthy, or is the platform healthy and the application slow?
3. What evidence would change my mind?

---

### 0:05–0:12 — Reproduce the complaint

Show the customer-visible symptom first. Open the site in a browser:

- `GET /api/products` → returns immediately
- `GET /api/orders` → visibly slow, every time

Then measure it instead of describing it:

```powershell
./scripts/run-load.ps1 -Url https://<site>.azurewebsites.net -Label before
```

While it runs (60 seconds), make the point:

> "I now have a number. 'Slow' is an opinion. P95 is a fact, and it is the thing I will
> compare against after the fix — with the identical workload."

Expected baseline on B1: **P95 in the region of 1.5–2.5 seconds**, no failures.

Also run the control endpoint, because it is the first real piece of evidence:

```powershell
./scripts/run-load.ps1 -Url https://<site>.azurewebsites.net -Path /api/products -Label control -DurationSeconds 30
```

> "Same app, same instance, same plan, same minute. One route is slow and the other is
> not. Whatever is wrong is not something the whole platform is doing to us."

---

### 0:12–0:22 — Platform evidence

Tab 1, App Service → Metrics. Walk them through it deliberately:

| Metric | What you will see | What it rules out |
|---|---|---|
| Average Response Time | High | Confirms the complaint is real |
| CPU Percentage | Low | Not CPU-bound; scaling up buys nothing |
| Memory Percentage | Low, flat | Not a leak |
| Http 5xx | Zero | Nothing is failing |
| Requests | Steady | Throughput is limited by latency, not demand |

Then say the line the session exists for:

> **"High response time with low CPU means the request is waiting, not working. You cannot
> fix waiting by buying more CPU."**

Add the health check: App Service → Health check shows the instance healthy throughout.
The platform is doing its job correctly and slowly delivering a slow application.

Run query 7 from `docs/kql-queries.md` (`AppServiceHTTPLogs`) to confirm the platform's own
logs agree: requests arrive, return 200, and take a long time.

---

### 0:22–0:35 — Application evidence (the heart of the session)

Application Insights → **Performance**. Select `GET /api/orders`, then open an **end-to-end
transaction**. This is the moment to slow down and let the room look at it.

What they should notice without being told:

- A long bar for the request
- Underneath it, **many short dependency bars, one after another**
- Nearly the entire request duration is those bars
- No errors anywhere

Then quantify it with query 3 from `docs/kql-queries.md`:

```kusto
// ~25 dependency calls per request, almost all of the request duration
```

Ask the room: *"Each call takes about 60 milliseconds. Is 60 milliseconds slow?"*

No. **Twenty-five of them in a row is slow.** That reframing is the lesson.

Reinforce with query 4 (dependency totals) and query 5 (the application's own log line,
which reports mode, catalog call count and elapsed time per request).

---

### 0:35–0:42 — Name the root cause

Have a participant say it in one sentence. Then give them the version you want them to
take to a customer:

> "The order history endpoint queries the catalog once for every order on the page, one
> call after another, and caches nothing between requests. Each call is fast; twenty-five
> sequential calls are not. Response time scales with page size, not with load, which is
> why CPU is low and why adding instances would not have helped."

Make the distinction explicit:

| Symptom | Root cause |
|---|---|
| "The order page is slow" | A per-item ("N+1") access pattern executed serially, with no caching |

Then show the code. `OrderService.cs`, `BuildBaselineAsync` — roughly fifteen lines, a
`foreach` with an `await` inside it. Everyone in the room has written that loop.

> "This is not an exotic defect. It is the single most common performance bug in line-of-
> business applications, and it is invisible until you look at dependencies per request."

---

### 0:42–0:50 — Remediate

Show the fix first, in `BuildOptimizedAsync`:

1. Ask for **every** category the page needs in **one** call instead of N
2. Cache the result briefly so repeat requests make **zero** calls
3. Return exactly the same data

Then apply it:

```powershell
./scripts/set-mode.ps1 -ResourceGroup rg-perflab-demo -Mode Optimized
```

Say what you are doing and why it is honest:

> "In the real world this is a code change and a deployment. In this lab the fixed code is
> already deployed and selected by an app setting, so we do not spend ten minutes of a
> sixty-minute session watching a build. The code path that runs is genuinely different —
> you just read both versions."

Point out while it restarts (about 30–60 seconds): changing an app setting restarts the
app, which is a real-world consideration worth a sentence.

Also state what you are *not* doing:

- Not scaling up the SKU
- Not scaling out instances
- Not enabling autoscale
- Not changing the platform in any way

---

### 0:50–0:57 — Prove it

The identical workload, against the identical infrastructure:

```powershell
./scripts/run-load.ps1 -Url https://<site>.azurewebsites.net -Label after
```

The script prints a before/after comparison automatically when both result files exist.
Expected: **P95 drops from seconds to tens of milliseconds**, throughput rises sharply,
catalog calls per request drop from 25 to 0.

Then confirm it in the portal with query 6 — one table, two rows, split by `lab.mode`:

| mode | requests | p50 | p95 | avgCatalogCalls |
|---|---|---|---|---|
| Baseline | … | ~1.8 s | ~2.3 s | 25 |
| Optimized | … | ~0.05 s | ~0.1 s | ~0 |

And the closing observation about the platform metrics:

> "CPU is still low. It was never the problem. Same plan, same instance count, same SKU —
> and the customer-visible symptom is gone."

---

### 0:57–1:00 — Close and cleanup

Three takeaways, in this order:

1. **Start with customer impact**, and turn "slow" into a measured baseline before touching anything.
2. **Separate platform health from application behaviour.** High response time with low CPU means waiting, not working.
3. **Prove the fix with the same workload.** A fix you cannot measure is a story, not an outcome.

Then delete everything, on camera:

```powershell
./scripts/cleanup.ps1 -ResourceGroup rg-perflab-demo
```

Tell participants who deployed into their own subscriptions to do the same. Put it on the
final slide.

---

## 4. Contingencies

| Problem | What to do |
|---|---|
| **Portal telemetry has not appeared** | Expected: ingestion takes 2–5 minutes. Switch to the pre-run tabs from your dry run and narrate those. Never stand in silence waiting for a chart |
| **Portal is slow or a blade will not load** | Fall back to `docs/kql-queries.md` in the Logs blade, or to the load generator output, which is local and instant |
| **The baseline looks fast** | Check `/api/lab/config` reports `Baseline`. If it reports `Optimized`, run `./scripts/reset.ps1`. Also confirm the warm-up finished — the first request after a restart includes cold start |
| **The site returns 503 right after deployment** | Cold start. Hit `/health` a few times and wait up to 2 minutes |
| **Corporate network blocks the load generator** | Reduce `-Concurrency` to 2, or generate load by refreshing `/api/orders` in a browser. The pattern is visible even from a single caller |
| **Deployment fails on resource naming** | Names derive from `uniqueString(resourceGroup().id)`. Use a different resource group name and redeploy |
| **Wrong region or quota error** | Try another region: `-Location westeurope`. The lab has no region-specific dependencies |
| **You are behind schedule** | Drop the control-endpoint load run (0:05–0:12) and the `AppServiceHTTPLogs` query (0:12–0:22). Never drop the before/after proof |
| **Someone asks about autoscale** | Good question, straight answer: autoscale would add instances that are each equally slow per request. Latency per request would not improve. The session deliberately does not enable it |

---

## 5. Questions you should expect

**"Would scaling out have helped at all?"**
It would raise throughput under concurrency, but it would not reduce the latency of a
single request, which is what the customer is complaining about. And you would pay for it
forever. Fix the access pattern first; scale for real demand second.

**"Is the cache the real fix?"**
No — batching is. The cache is a second-order improvement. Remove the cache and you still
go from 25 calls to 1 per request. Say this explicitly, because teams often reach for a
cache to hide an access-pattern problem rather than fix it.

**"Isn't caching risky for stale data?"**
Yes, and that is an engineering trade-off to make deliberately: bound the lifetime (here,
60 seconds), cache only what tolerates staleness, and be explicit about it in review.

**"How would we have caught this before production?"**
Dependency-calls-per-request is a reviewable number. Load test the realistic page size, not
one record. Watch the ratio of dependency time to request time in pre-production telemetry.

**"Does this prove our environment has the same problem?"**
No. This is a simulation. What transfers is the method: impact first, platform versus
application, dependencies per request, fix, prove.
