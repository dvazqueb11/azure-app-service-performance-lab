# Cost drivers and cleanup

## No prices are published here

Azure prices vary by region, currency, subscription type, agreement and time. Any number
written into a repository is wrong somewhere, or wrong eventually. Use the official
sources instead:

- [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
- [App Service pricing](https://azure.microsoft.com/pricing/details/app-service/linux/)
- [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/) (covers both Log Analytics and Application Insights)
- `az vm list-sizes`-style dynamic pricing via the [Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)

What this document does instead is name **what you are billed for** and **what has already
been done to keep it small**.

---

## What drives cost in this lab

| Cost driver | Billed on | Guardrail already applied |
|---|---|---|
| **App Service Plan** | Per hour, from creation until deletion, regardless of traffic | One instance, no autoscale, lowest practical SKU (B1) as the default |
| **Log Analytics ingestion** | Per GB ingested | `workspaceCapping.dailyQuotaGb = 1` as a hard daily cap; short test runs |
| **Log Analytics retention** | Per GB per month beyond the included period | Retention set to the 30-day minimum |
| **Application Insights** | Ingestion is billed through the linked Log Analytics workspace | `Telemetry__SamplingRatio` app setting, adjustable down from `1.0` |
| **Load generation** | — | None. The load generator runs on your own machine; no Azure Load Testing resource is deployed |
| **Egress** | Per GB outbound | Responses are small JSON payloads; runs are 60 seconds by default |

The App Service Plan is the dominant cost, and it accrues **by the hour whether or not the
lab is being used**. Deleting the resource group is therefore the single most effective
cost control in this repository.

---

## Reducing cost further

| Lever | How |
|---|---|
| Shorter plan lifetime | Deploy at the start of the session, delete at the end. Redeploying takes about 5 minutes |
| Lower telemetry volume | Set `Telemetry__SamplingRatio` to `0.5` or `0.25` in `infra/main.parameters.json` before deploying |
| Shorter load runs | `-DurationSeconds 30` on `run-load.ps1`. Thirty seconds is enough to see the pattern |
| Tighter ingestion cap | Lower `logDailyQuotaGb`. Note that hitting the cap stops ingestion for the rest of the UTC day, which would break a live session — do not set it below 1 for an instructor delivery |
| Smaller retention | 30 days is already the minimum |

Do **not** reduce cost by moving to a Free or Shared App Service tier. Those tiers lack
Always On and apply quota-based throttling, which introduces behaviour the lab would then
have to explain and explain away.

---

## Cleanup

Every resource is created inside one resource group. Deleting that group removes all
billable resources.

```powershell
./scripts/cleanup.ps1 -ResourceGroup rg-perflab-demo
```

```bash
./scripts/cleanup.sh -g rg-perflab-demo
```

The script lists what will be deleted and asks you to type the resource group name before
proceeding. Use `-Force` / `-f` to skip the prompt, and `-NoWait` / `-w` to return
immediately while deletion continues in the background.

### Verify it is gone

```bash
az group exists --name rg-perflab-demo        # expect: false
```

If you used `--no-wait`, deletion can take several minutes. Re-run the check until it
returns `false`.

### Between two sessions on the same day

Use `reset.ps1` / `reset.sh` instead of deleting and redeploying. It returns the app to
Baseline mode, restarts it to clear the in-memory cache, and deletes local result files.

```powershell
./scripts/reset.ps1 -ResourceGroup rg-perflab-demo
```

Telemetry already ingested into Application Insights is **not** deleted — that is by
design, and it is cheaper and faster than recreating the workspace. Scope portal views to
the new time range when you repeat the session.

---

## Cleanup checklist for instructors

- [ ] `az group exists --name <rg>` returns `false`
- [ ] No lab resource group remains in the subscription (`az group list -o table`)
- [ ] Participants who deployed into their **own** subscriptions have run cleanup too —
      say this out loud at the end of the session, and put it on the last slide
- [ ] Local `artifacts/` and `results/` folders removed if you do not want them
      (`reset.ps1` handles `results/`)
