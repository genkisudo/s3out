# Phase 3 plan — dbt and Iceberg in Snowflake (not started)

> **Do not implement yet.** Finish [plan.md](./plan.md) Phase 2 (Snowflake raw load) first. This doc is design notes for later.

Target stack (from [README](./README.md)): **Reservoir → your S3 (Parquet raw) → Snowflake → dbt → Iceberg marts**, orchestrated with Prefect.

Domain models (`dim_outcome`, `fct_trades`, …) are defined in [outcome-analytics-one-pager.md](./outcome-analytics-one-pager.md).

---

## Layering: what is Iceberg vs what stays Parquet

| Layer | Format | Where | Purpose |
|---|---|---|---|
| **Raw** | Parquet (unchanged) | Your S3 `raw/global/fills/outcome/all/date=D/fills.parquet` | Immutable Hydromancer copy; cheap replay without Reservoir fees |
| **Bronze** | Snowflake table (regular or Iceberg) | Snowflake | Typed daily loads from `@stage`; partition key `date` |
| **Silver / gold** | **Iceberg** (recommended) | Snowflake-managed **or** your S3 via external volume | dbt models: staging → `int_outcome_venue_filter` → marts |

**Do not** convert raw Reservoir files to Iceberg on ingest unless you have a specific need. Keep **one Parquet object per day** on S3; let Snowflake and dbt build Iceberg for **modeled** tables.

Snowflake docs: [Create an Iceberg table](https://docs.snowflake.com/en/user-guide/tables-iceberg-create), [Configure an external volume](https://docs.snowflake.com/en/user-guide/tables-iceberg-configure-external-volume). dbt: [Snowflake Iceberg support](https://docs.getdbt.com/docs/build/iceberg/adapters/snowflake-iceberg-support).

---

## Choose where Iceberg files live

### Option A — `SNOWFLAKE_MANAGED` (simplest to start)

Iceberg metadata and data files are stored by Snowflake. No extra S3 prefix for Iceberg. Best for **learning, Cortex, and dbt** without operating lake files.

dbt (v1.12+ set flag, or dbt v2 default):

```yaml
# dbt_project.yml
flags:
  snowflake_managed_iceberg_default: true
```

```sql
{{ config(
    materialized='table',
    table_format='iceberg',
) }}
select * from {{ ref('stg_fills_outcome') }}
```

Equivalent SQL:

```sql
CREATE ICEBERG TABLE outcome_analytics.marts.fct_trades
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'SNOWFLAKE_MANAGED'
  AS SELECT ...;
```

### Option B — Iceberg on **your** S3 (open lakehouse)

Same bucket as raw, **different prefix** (e.g. `iceberg/`). You create an **external volume**; dbt sets `external_volume` and `base_location_root`.

Use this when you want Iceberg files readable outside Snowflake (Spark, Trino, etc.) or a single AWS account footprint for all artifacts.

Requires [external volume + IAM](https://docs.snowflake.com/en/user-guide/tables-iceberg-configure-external-volume) in addition to the [storage integration](./how-to-connect-snowflake-to-aws-s3.md) used for **loading Parquet** from `raw/`.

**Recommendation:** start with **Option A** for marts; keep **raw Parquet on S3**. Move marts to Option B later if you need cross-engine access.

---

## End-to-end flow

```text
hydromancer-reservoir
        │  AWS CLI (--request-payer requester)
        ▼
your S3  raw/.../date=D/fills.parquet
        │  storage integration + @stage + COPY INTO (or Snowpipe)
        ▼
Snowflake  RAW.FILLS_OUTCOME_ALL  (regular table OK for bronze)
        │  dbt
        ▼
Snowflake  Iceberg: STG → INT → MARTS
```

1. Connect AWS → Snowflake for **raw Parquet only**: [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md).
2. Load each UTC day incrementally into a bronze table keyed by `date`.
3. Run dbt to build **Iceberg** silver/gold models.

---

## Snowflake objects (suggested layout)

```text
OUTCOME_ANALYTICS
├── RAW
│   ├── fills_outcome_all          -- COPY FROM @stage (Parquet → rows)
│   └── load_manifest              -- date, s3_key, row_count, loaded_at
├── STAGING                        -- dbt: stg_fills_outcome (view or iceberg table)
├── INTERMEDIATE                   -- int_outcome_venue_filter, int_trades_taker, ...
└── MARTS                          -- dim_outcome, fct_trades, ... (Iceberg)
```

---

## Bronze load (not Iceberg yet)

After `CREATE STAGE` works:

Use `INFER_SCHEMA` + `USING TEMPLATE` as in [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md) Step 4, then:

```sql
COPY INTO raw.fills_outcome_all
FROM @stg_s3_raw/all/date=2026-10-27/
FILE_FORMAT = (TYPE = PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

INSERT INTO raw.load_manifest
SELECT
  '2026-10-27'::date,
  'raw/global/fills/outcome/all/date=2026-10-27/fills.parquet',
  (SELECT COUNT(*) FROM raw.fills_outcome_all WHERE date = '2026-10-27'),
  CURRENT_TIMESTAMP();
```

Use **merge by `date`** for idempotent daily loads (delete partition or `MERGE` on natural key + `date`).

---

## dbt project sketch

```yaml
# dbt_project.yml
name: outcome_analytics
profile: outcome_snowflake

model-paths: ["models"]
target-path: "target"

vars:
  trade_directions: ["Buy", "Sell"]

models:
  outcome_analytics:
    staging:
      +schema: staging
    intermediate:
      +schema: intermediate
    marts:
      +schema: marts
      +materialized: table
      +table_format: iceberg
      # Option A: rely on snowflake_managed_iceberg_default
      # Option B: +external_volume: outcome_s3_vol
      #           +base_location_root: iceberg
```

**Staging** (`models/staging/stg_fills_outcome.sql`):

```sql
{{ config(materialized='view') }}

select
  *,
  cast(substr(coin, 2) as bigint) div 10 as outcome_id_derived
from {{ source('raw', 'fills_outcome_all') }}
where outcome_id_derived = outcome_id  -- sanity; optional test
```

**Trades mart** (`models/marts/fct_trades.sql`):

```sql
{{ config(
    materialized='incremental',
    table_format='iceberg',
    unique_key='trade_id',
    incremental_strategy='merge',
) }}

select
  trade_id,
  outcome_id,
  outcome_side,
  price,
  size,
  side,
  crossed,
  timestamp,
  date
from {{ ref('stg_fills_outcome') }}
where direction in ('Buy', 'Sell')
  and crossed
{% if is_incremental() %}
  and date > (select coalesce(max(date), '1900-01-01') from {{ this }})
{% endif %}
```

**Venue filter** (placeholder until method chosen):

```sql
-- models/intermediate/int_outcome_venue_filter.sql
{{ config(materialized='table', table_format='iceberg') }}

select distinct outcome_id
from {{ ref('stg_fills_outcome') }}
where 1 = 0  -- replace with Outcome-only logic (deployer list, sitemap, etc.)
```

Wire `ref('int_outcome_venue_filter')` into marts with an `inner join` on `outcome_id`.

---

## External volume on your bucket (Option B only)

After raw load integration works, create a volume for Iceberg writes (separate Snowflake object; IAM similar to storage integration):

```sql
CREATE EXTERNAL VOLUME outcome_s3_vol
  STORAGE_LOCATIONS =
    (
      (
        NAME = 'apne1'
        STORAGE_PROVIDER = 'S3'
        STORAGE_BASE_URL = 's3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/iceberg/'
        STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::436535002811:role/snowflake-s3-outcome'
      )
    )
  ALLOW_WRITES = TRUE;
```

IAM must allow **read/write/list** on `iceberg/*`, not only read on `raw/*`. You can extend the same role or split roles.

dbt mart config:

```sql
{{ config(
    materialized='table',
    table_format='iceberg',
    external_volume='outcome_s3_vol',
    base_location_root='outcome_analytics',
) }}
```

---

## Prefect orchestration (daily)

1. Task: `copy-reservoir-outcome-fills-day.sh` for `D-1`.
2. Task: Snowflake `COPY INTO` / merge for that `date`.
3. Task: `dbt run --select stg_fills_outcome+` (or tag `daily`).
4. Task: `dbt test`.

Record each partition in `raw.load_manifest` for backfill idempotency.

---

## Prerequisites checklist

- [ ] Snowflake account with **Iceberg tables** enabled (check with account admin; region on AWS).
- [ ] Warehouse running for `CREATE ICEBERG TABLE` and dbt runs.
- [ ] Raw path working: [how-to-reservoir-to-snowflake.md](./how-to-reservoir-to-snowflake.md).
- [ ] dbt-snowflake **1.12+** (Iceberg) or **2.x** for managed Iceberg defaults.
- [ ] Decide **Option A** vs **B** for mart storage before creating many models.

---

## Cortex

Iceberg marts in Snowflake are ordinary tables for SQL and Cortex Agents once dbt tests pass. Point agents at `MARTS` schema and document grain (`fct_trades` = one row per taker match, etc.).
