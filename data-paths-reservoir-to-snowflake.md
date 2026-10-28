# Two ways to get Reservoir data into Snowflake

Source: [Hydromancer Reservoir](https://docs.hydromancer.xyz/reservoir) (`s3://hydromancer-reservoir`, **requester pays**, `ap-northeast-1`). HIP-4 fills only: `global/fills/outcome/all/date=D/fills.parquet`.

---

## Comparison

| | **Path A — Your S3 bucket (this repo)** | **Path B — No your-S3 archive** |
|---|---|---|
| **Idea** | Land Parquet in **your** bucket, Snowflake reads it via storage integration + external stage | Skip a long-lived **your** bucket; load files into Snowflake without keeping a lake copy |
| **Reservoir → Snowflake direct** | No — still need AWS once with `RequestPayer` | **No** — Snowflake external stage cannot read requester-pays buckets ([why](./how-to-reservoir-to-snowflake.md)) |
| **How Reservoir is read** | `aws s3 cp` server-side into your bucket ([script](./scripts/copy-reservoir-outcome-fills-day.sh)) | AWS CLI (or SDK) **download** with `--request-payer requester`, then **upload** to a Snowflake **internal** stage (`PUT file://… @stage`) |
| **Snowflake setup** | `STORAGE INTEGRATION` + IAM role on **your** bucket + **external** stage | **Internal** stage (or user stage); no S3 integration for raw HIP-4 |
| **Raw replay / backfill** | Re-`COPY` from your S3; no extra Reservoir fees | Re-download from Reservoir (requester pays again) or re-`PUT` from local files |
| **Cost** | Small S3 storage + one Reservoir read per day copied | No your-S3 storage; repeated Reservoir GETs if you reload; ~26 MB/day per file |
| **Automation** | Prefect: copy → `COPY INTO` / Snowpipe on your prefix | Prefect: download → `PUT` → `COPY INTO` |
| **Fit for this project** | **Recommended** — matches [plan.md](./plan.md) Phase 1–2 | OK for experiments; weak for daily T+1 pipeline and blog “lake” narrative |

**Bottom line:** You cannot avoid **some** AWS client that sends `x-amz-request-payer: requester` when reading Hydromancer. Path A adds a cheap, reusable **your S3** layer; Path B goes straight to Snowflake tables and skips owning a raw bucket.

---

## Path A — Your S3 bucket (recommended)

```text
hydromancer-reservoir
        │  AWS CLI, --request-payer requester, --copy-props none
        ▼
s3://outcome-hip4-…/raw/global/fills/outcome/all/date=D/fills.parquet
        │  storage integration s3_outcome_int + external stage
        ▼
Snowflake RAW.fills_outcome_all  (COPY INTO)
```

Runbooks: [how-to-reservoir-to-snowflake.md](./how-to-reservoir-to-snowflake.md), [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md).

---

## Path B — No your-S3 archive (internal stage)

Use when you do **not** want Parquet sitting in your AWS bucket.

1. **Download one day** (requester pays; charges your AWS account, not Snowflake):

```bash
export AWS_PROFILE=outcome AWS_REGION=ap-northeast-1 DAY=2026-10-27
aws s3 cp \
  "s3://hydromancer-reservoir/global/fills/outcome/all/date=${DAY}/fills.parquet" \
  "./fills-${DAY}.parquet" \
  --request-payer requester
```

2. **Snowflake** — internal stage and load (worksheet; warehouse running):

```sql
USE DATABASE OUTCOME_ANALYTICS;
CREATE SCHEMA IF NOT EXISTS RAW;
USE SCHEMA RAW;

CREATE OR REPLACE STAGE stg_local_parquet
  FILE_FORMAT = (TYPE = PARQUET);

PUT file:///path/on/your/machine/fills-2026-10-27.parquet @stg_local_parquet;

-- create table (INFER_SCHEMA from @stg_local_parquet/... after PUT)
COPY INTO fills_outcome_all
FROM @stg_local_parquet
FILE_FORMAT = (TYPE = PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

Adjust `PUT` path to your laptop path. Snowflake’s `PUT` uploads into **Snowflake-managed** stage storage, not your S3 bucket.

**Not supported:** `CREATE STAGE` with `URL = 's3://hydromancer-reservoir/...'` and storage integration in **your** account — GETs lack requester-payer and Hydromancer will not grant your IAM role on their bucket.

---

## What this project uses

**Path A.** Storage integration `s3_outcome_int` is already created in Snowflake (see [snowflake-setup-status.md](./snowflake-setup-status.md)). Finish IAM role `snowflake-s3-outcome`, external stage, and `COPY INTO` from your landed `2026-10-27` object.
