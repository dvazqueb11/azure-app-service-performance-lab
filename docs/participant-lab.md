# Participant lab — Session 8

**Diagnose and Remediate Azure App Service Performance Issues**

Work through this at your own pace, during or after the session. Expect 45–60 minutes
including deployment.

> This is a controlled educational simulation. It does not reproduce any customer's
> production architecture, and completing it does not validate any production environment.
> What you are practising is the **method**.

---

## The escalation

> *"Since this morning, our order history page is taking several seconds to load. The
> product catalog page is fine. Nothing was deployed. We think Azure App Service is having
> a problem — can you scale it up?"*

Your job is not to answer the question you were asked. It is to find out what is actually
happening.

Keep three questions in front of you:

1. What exactly is slow, for whom, and since when?
2. Is the platform unhealthy, or is the platform healthy and the application slow?
3. What evidence would change my mind?

---

## Step 0 — Prerequisites and deployment

You need: an Azure subscription, Azure CLI (`az login` done), .NET SDK 10, and PowerShell 7
or Bash.

```powershell
git clone <this-repo>
cd <this-repo>
./scripts/deploy.ps1 -ResourceGroup rg-perflab-<yourname> -Location eastus
```

```bash
./scripts/deploy.sh -g rg-perflab-<yourname> -l eastus
```

The script prints your site URL. Save it — every step below uses it.

```powershell
$site = 'https://app-perflab-xxxxx.azurewebsites.net'
```

Confirm the lab is in its starting state:

```powershell
Invoke-RestMethod "$site/api/lab/config"
# mode should be "Baseline" and telemetryEnabled should be true
```

> **Cost reminder:** the App Service Plan bills by the hour from creation until deletion.
> Jump to Step 8 as soon as you are finished.

---

## Step 1 — Reproduce the complaint, and measure it

**Do not open the portal yet.** Start where the customer is.

Open both endpoints in a browser:

- `$site/api/products` — returns immediately
- `$site/api/orders` — noticeably slow, consistently

Now replace the opinion with a number:

```powershell
./scripts/run-load.ps1 -Url $site -Label before
```

**Record your results:**

| Measurement | Your value |
|---|---|
| P50 (ms) | |
| P95 (ms) | |
| Requests per second | |
| Failures | |

Run the control endpoint too:

```powershell
./scripts/run-load.ps1 -Url $site -Path /api/products -Label control -DurationSeconds 30
```

**Question 1.1** — Same app, same instance, same moment. One route is slow and one is fast.
What does that already tell you about where the problem can and cannot be?

**Question 1.2** — Why measure a baseline *before* changing anything, rather than fixing
first and measuring afterwards?

---

## Step 2 — Is the platform unhealthy?

Azure portal → your App Service → **Metrics**. Add these, over the last 30 minutes:

- Average Response Time
- CPU Percentage
- Memory Percentage
- Http Server Errors (Http 5xx)
- Requests

**Record what you see:**

| Metric | High / Low / Flat | Your reading |
|---|---|---|
| Average Response Time | | |
| CPU Percentage | | |
| Memory Percentage | | |
| Http 5xx | | |
| Requests | | |

Also check **App Service → Health check** — the instance should be healthy throughout.

**Question 2.1** — Response time is high but CPU is low. Is the instance *working* hard, or
*waiting*? What is the difference, and which one does a bigger SKU fix?

**Question 2.2** — The customer asked you to scale up. Based only on the evidence so far,
what would scaling up change? What would it cost?

**Question 2.3** — Zero 5xx errors. Is "nothing is failing" good news, bad news, or just
information? What does it rule out?

---

## Step 3 — Where does the time actually go?

Azure portal → **Application Insights** → **Logs**. Run query 1 from
[`kql-queries.md`](kql-queries.md):

```kusto
requests
| where timestamp > ago(1h)
| summarize requests = count(), p50 = percentile(duration, 50), p95 = percentile(duration, 95), failures = countif(success == false) by name
| order by p95 desc
```

> Telemetry takes 2–5 minutes to appear. If a query is empty, widen the time range before
> assuming something is wrong.

**Question 3.1** — Which operations are slow, and which are fast? Does this match what you
measured from your own machine in Step 1?

Now run query 3 — the decisive one:

```kusto
let window = 1h;
requests
| where timestamp > ago(window)
| where name has "/api/orders"
| project operation_Id, requestDuration = duration
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

**Record:**

| Measurement | Your value |
|---|---|
| Average dependency calls per request | |
| Average request duration (ms) | |
| Percent of request spent in dependencies | |

**Question 3.2** — How many dependency calls does **one** page view make?

**Question 3.3** — Run query 4. How long does a **single** dependency call take? Is that
number, on its own, a problem?

---

## Step 4 — See it on one request

Application Insights → **Performance** → select `GET /api/orders` → open an **end-to-end
transaction detail**.

**Question 4.1** — Describe the shape of the waterfall. Are the dependency calls running at
the same time, or one after another? How can you tell?

**Question 4.2** — If those calls ran in parallel instead of serially, would that fix the
problem, improve it, or hide it? What would happen to the backing store?

---

## Step 5 — State the root cause

Write it in **one sentence**, in language you would use with a customer. Avoid jargon;
avoid blaming "the database"; be specific about the behaviour.

> **Root cause:**
>
> ______________________________________________________________________

Then fill in this table:

| | Your answer |
|---|---|
| Symptom the customer reported | |
| Component that is slow | |
| Component that is *not* at fault | |
| Specific inefficient behaviour | |
| Why CPU stayed low | |
| Why more instances would not help a single request | |

Now read [`src/PerfLab.Api/OrderService.cs`](../src/PerfLab.Api/OrderService.cs), method
`BuildBaselineAsync`. Does the code match the conclusion you reached from telemetry alone?

---

## Step 6 — Remediate

Read `BuildOptimizedAsync` in the same file before applying anything. Note three things:

1. It asks for every category the page needs in **one** call instead of N
2. It caches the result briefly, so repeat requests make **zero** calls
3. It returns **exactly the same data**

Apply the fix:

```powershell
./scripts/set-mode.ps1 -ResourceGroup rg-perflab-<yourname> -Mode Optimized
```

The app restarts, which takes 30–60 seconds. The script waits until the running app
reports the new mode.

**Question 6.1** — You did not change the SKU, the instance count, or any platform setting.
Why is that the right call here?

**Question 6.2** — Which part of the fix matters more: batching or caching? Justify your
answer. (Hint: imagine removing each one separately.)

---

## Step 7 — Prove the improvement

Run the **identical** workload against the **identical** infrastructure:

```powershell
./scripts/run-load.ps1 -Url $site -Label after
```

The script prints a before/after comparison automatically.

**Record:**

| Measurement | Before | After | Change |
|---|---|---|---|
| P50 (ms) | | | |
| P95 (ms) | | | |
| Requests per second | | | |
| Catalog calls per request | | | |

Confirm it in the portal with query 6, which splits request performance by `lab.mode`:

```kusto
requests
| where timestamp > ago(2h)
| where name has "/api/orders"
| extend mode = tostring(customDimensions["lab.mode"]),
         catalogCalls = toint(customDimensions["lab.catalog_calls"])
| summarize requests = count(), p50 = percentile(duration, 50), p95 = percentile(duration, 95), avgCatalogCalls = avg(catalogCalls) by mode
```

**Question 7.1** — Check CPU Percentage in App Service → Metrics again. What is it doing
now, and what does that confirm about the original diagnosis?

**Question 7.2** — Why does running the *same* workload matter? What would a sceptical
reviewer say if you changed the load parameters between the two runs?

**Question 7.3** — Write the two-sentence update you would send to the customer who opened
the ticket. Lead with impact, not with internals.

---

## Step 8 — Clean up (do not skip this)

```powershell
./scripts/cleanup.ps1 -ResourceGroup rg-perflab-<yourname>
```

```bash
./scripts/cleanup.sh -g rg-perflab-<yourname>
```

Verify:

```bash
az group exists --name rg-perflab-<yourname>   # expect: false
```

The App Service Plan bills by the hour until the resource group is gone.

---

## Going further (optional)

| Experiment | How | What to look for |
|---|---|---|
| Make the symptom worse | Set app setting `Lab__OrderCount=50`, re-run baseline | Response time scales with page size, not with load. That is the signature of an N+1 pattern |
| Make the dependency faster instead of making fewer calls | Set `Lab__SimulatedLatencyMs=20` in Baseline mode | Still slow. "Optimise the query" is the wrong fix when the problem is the number of queries |
| Watch the cache expire | In Optimized mode, wait 60+ seconds idle, then send one request | One catalog call, then zero again. Bounded staleness as a deliberate trade-off |
| Test under more concurrency | `-Concurrency 10` | Baseline throughput collapses; optimized barely notices |

Return to Baseline at any time with `./scripts/reset.ps1 -ResourceGroup rg-perflab-<yourname>`.

Answers are in [`solution-guide.md`](solution-guide.md) — try the questions first.
