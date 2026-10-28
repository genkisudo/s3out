# Outcome analytics — execution plan

**Scope now:** land HIP-4 data and make it queryable in Snowflake. **Not in scope yet:** dbt models, Iceberg marts, venue filter logic, Prefect production flows, Cortex.

Product context: [outcome-analytics-one-pager.md](./outcome-analytics-one-pager.md).

---

## Target architecture (full picture)

```text
Phase 1–2 (now)
  hydromancer-reservoir  ──AWS CLI──►  your S3 raw/…/outcome/all/
                                              │
                                              ▼
                                         Snowflake RAW (Parquet loads)

Phase 3+ (later)
  Snowflake RAW  ──dbt──►  Iceberg staging / marts  ──►  Cortex, BI
         ▲
         └── Prefect schedules copy + load (+ dbt when ready)
```

Hydromancer cannot load straight into Snowflake ([requester pays](./how-to-reservoir-to-snowflake.md)). Your S3 bucket stays required for Phase 1–2.

**Data scope:** HIP-4 only — `global/fills/outcome/all/date=D/fills.parquet`. Not `global/fills/raw/`.

---

## Phase 0 — Done / documented

| Item | Status |
|---|---|
| IAM user `outcome-analytics`, profile `outcome` | Done |
| Own bucket `outcome-hip4-…-ap-northeast-1-an` | Done |
| Test copy one day from Reservoir | [how-to-get-outcome-data-on-hyperliquid.md](./how-to-get-outcome-data-on-hyperliquid.md) |
| Copy script | [scripts/copy-reservoir-outcome-fills-day.sh](./scripts/copy-reservoir-outcome-fills-day.sh) |

**Exit:** One full day under `raw/global/fills/outcome/all/date=…/fills.parquet`, source and dest byte sizes match.

---

## Phase 1 — AWS landing (ongoing)

**Goal:** Reliable daily (or backfill) copies from Reservoir without touching Snowflake.

| Step | Action |
|---|---|
| 1.1 | List newest `date=` under `global/fills/outcome/all/` (`--request-payer requester`) |
| 1.2 | Copy partition with `--copy-props none` |
| 1.3 | Optional: AWS budget alarm on account `436535002811` |

**Docs:** [how-to-reservoir-to-snowflake.md](./how-to-reservoir-to-snowflake.md)

**Exit:** You can add any historical `date=D` to `raw/` on demand; no accidental `fills/raw/` paths.

---

## Phase 2 — Snowflake ingest (next)

**Goal:** AWS account linked to Snowflake; Parquet in **your** S3 loaded into a **raw** table (regular table, not Iceberg).

| Step | Action |
|---|---|
| 2.1 | `CREATE STORAGE INTEGRATION` scoped to `raw/global/fills/outcome/` |
| 2.2 | IAM role `snowflake-s3-outcome` (trust from `DESC INTEGRATION`) |
| 2.3 | External stage on that prefix |
| 2.4 | `LIST @stage` succeeds |
| 2.5 | `COPY INTO` one day; row count sanity vs [sample day stats](./how-to-get-outcome-data-on-hyperliquid.md) |
| 2.6 | Optional later: Snowpipe on `ObjectCreated` under same prefix |
| 2.7 | Optional: `load_manifest` table (date, key, row_count, loaded_at) for idempotency |

**Docs:** [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md)

**Not yet:** external volume for Iceberg, dbt project, marts schema design beyond one-pager names.

**Exit:** `SELECT COUNT(*), date FROM raw.fills_outcome_all GROUP BY date` works for at least one partition; integration documented.

**Open inputs needed:**

- Snowflake account identifier and region
- AWS profile that can create IAM roles
- Database/schema names (default plan: `OUTCOME_ANALYTICS.RAW`)

---

## Phase 3 — Modeling (deferred)

**Goal:** dbt on Snowflake; Iceberg for modeled layers; Outcome venue filter in `int_outcome_venue_filter`.

| Step | Action |
|---|---|
| 3.1 | Confirm Iceberg enabled on Snowflake account |
| 3.2 | Choose Iceberg storage: `SNOWFLAKE_MANAGED` vs S3 external volume |
| 3.3 | dbt-snowflake project, sources on raw table |
| 3.4 | Staging → intermediate → marts per one-pager |
| 3.5 | Tests (uniqueness, price 0–1, trade grain) |

**Plan only (no implementation yet):** [how-to-model-iceberg-in-snowflake.md](./how-to-model-iceberg-in-snowflake.md)

**Exit:** Daily `dbt run` + tests green; documented venue filter method.

---

## Phase 4 — Orchestration & consumption (deferred)

| Step | Action |
|---|---|
| 4.1 | Prefect: T+1 copy (after Reservoir publish ~10–12 UTC) → Snowflake load |
| 4.2 | Backfill flow by date range |
| 4.3 | Cortex / BI on marts |

---

## Decisions already made

| Decision | Choice |
|---|---|
| Source | Hydromancer Reservoir, HIP-4 `outcome/all` only |
| Reservoir → Snowflake | Two-hop via **your** S3 + AWS CLI |
| Reservoir read tool | AWS CLI (requester pays), not Snowflake stage on `hydromancer-reservoir` |
| Raw format on S3 | Parquet as delivered |
| Warehouse | Snowflake (not DuckDB laptop path from one-pager v1) |
| Modeled format (later) | Iceberg in Snowflake via dbt |

## Decisions still open

| Question | Blocks |
|---|---|
| Snowflake account id / region | Phase 2 SQL and region alignment |
| Snowpipe vs manual `COPY` for daily load | Phase 2 automation design |
| Outcome-only venue filter method | Phase 3 `int_outcome_venue_filter` |
| Iceberg `SNOWFLAKE_MANAGED` vs own S3 `iceberg/` prefix | Phase 3 external volume work |

---

## Doc index

| Phase | Document |
|---|---|
| 0–1 | [how-to-get-outcome-data-on-hyperliquid.md](./how-to-get-outcome-data-on-hyperliquid.md), [how-to-reservoir-to-snowflake.md](./how-to-reservoir-to-snowflake.md) |
| 2 | [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md) |
| 3 (plan) | [how-to-model-iceberg-in-snowflake.md](./how-to-model-iceberg-in-snowflake.md) |
| Domain | [outcome-analytics-one-pager.md](./outcome-analytics-one-pager.md), [schema.md](./schema.md) |
| Overview | [README.md](./README.md) |
