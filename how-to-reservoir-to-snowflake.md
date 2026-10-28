# Reservoir (requester-pays S3) → Snowflake

[Hydromancer Reservoir](https://docs.hydromancer.xyz/reservoir) is public Hyperliquid history on S3: **no API key**, **requester pays**, **daily updates**, bucket `hydromancer-reservoir` in **`ap-northeast-1`**.

Snowflake **cannot** point an external stage at that bucket and load directly. Standard `CREATE STAGE` / `COPY INTO` do not send `x-amz-request-payer: requester`, which [requester-pays buckets require](https://docs.aws.amazon.com/AmazonS3/latest/userguide/RequesterPaysBuckets.html). Snowflake only supports requester pays in separate products (e.g. OpenFlow’s S3 processors), not in the usual warehouse stage path.

**Working pattern for this project:** land files in **your** S3 bucket with the AWS CLI, then let Snowflake read **your** bucket via a [storage integration](./how-to-connect-snowflake-to-aws-s3.md).

## Scope: HIP-4 only (not all of Hyperliquid)

| You want | Reservoir path | Do not use |
|---|---|---|
| HIP-4 fills only | `global/fills/outcome/all/date=D/fills.parquet` | `global/fills/raw/` (~640 MB/day, perps + spot + HIP-4 mixed) |
| HIP-4 order books (optional) | `by_dex/hyperliquid/orderbook/1m/outcome/date=D/` | Perp/orderbook paths under other prefixes |
| HIP-4 builder-tagged fills (optional) | `global/fills/outcome/builder_fills/date=D/fills.parquet` | Same as `all/` for most trade metrics |

The word **`all`** in `outcome/all` means *all HIP-4 deployers on Hyperliquid*, not “all Hyperliquid trades.” Every row is still HIP-4 (`outcome_id`, `outcome_side`). It is **not** limited to Outcome.xyz’s venue; that filter happens later in dbt (`int_outcome_venue_filter`) because the Parquet file has no `venue` column.

Your IAM user `outcome-analytics` is already scoped to these Outcome/HIP-4 prefixes (and spot snapshots). It **cannot** read `global/fills/raw/` even if you typo the path.

**Minimum pipeline for Snowflake:** copy only `global/fills/outcome/all/` — one Parquet file per UTC day (~26 MB). Scripts and stage paths in this repo use that prefix only.

```text
hydromancer-reservoir (requester pays)
        │  aws s3 cp, same region, --request-payer requester
        ▼
your bucket …/raw/…  (you own it, no requester pays)
        │  storage integration + external stage + COPY / Snowpipe
        ▼
Snowflake tables
```

---

## Optional add-ons (still HIP-4, not required for v1)

| Reservoir prefix | Size | When to add |
|---|---|---|
| `global/fills/outcome/builder_fills/date=D/fills.parquet` | smaller | Builder-specific analysis |
| `by_dex/hyperliquid/orderbook/1m/outcome/date=D/` | ~20 KB/file | Spread / depth marts |
| `global/snapshots/spot/date=D/` | varies | Wallet token balances (HIP-4 `+` tokens unverified) |

Paths and column notes: [outcome-analytics-one-pager.md](./outcome-analytics-one-pager.md), [how-to-get-outcome-data-on-hyperliquid.md](./how-to-get-outcome-data-on-hyperliquid.md).

---

## Hop 1 — Copy one day into your bucket (AWS CLI)

Use profile `outcome`, region `ap-northeast-1`, and **always**:

- `--request-payer requester` on every Reservoir call
- `--copy-props none` on cross-bucket copy (avoids `GetObjectTagging` denied by your IAM policy)

```bash
export AWS_PROFILE=outcome
export AWS_REGION=ap-northeast-1
export DAY=2026-10-27   # newest closed partition; list prefix to pick

SRC="s3://hydromancer-reservoir/global/fills/outcome/all/date=${DAY}/fills.parquet"
DST="s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/all/date=${DAY}/fills.parquet"

aws s3 ls "s3://hydromancer-reservoir/global/fills/outcome/all/" --request-payer requester

aws s3 cp "$SRC" "$DST" --request-payer requester --copy-props none
```

Or run [scripts/copy-reservoir-outcome-fills-day.sh](./scripts/copy-reservoir-outcome-fills-day.sh) with the date argument.

Confirm size matches:

```bash
aws s3api head-object --bucket hydromancer-reservoir \
  --key "global/fills/outcome/all/date=${DAY}/fills.parquet" \
  --request-payer requester --query ContentLength --output text

aws s3api head-object --bucket outcome-hip4-436535002811-436535002811-ap-northeast-1-an \
  --key "raw/global/fills/outcome/all/date=${DAY}/fills.parquet" \
  --query ContentLength --output text
```

Reservoir is **T+1** (each UTC day appears the next morning ~10:00–12:00 UTC). See [Reservoir docs](https://docs.hydromancer.xyz/reservoir).

---

## Hop 2 — Wire Snowflake to your bucket

Follow [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md):

1. `CREATE STORAGE INTEGRATION` with `STORAGE_ALLOWED_LOCATIONS` on `raw/global/fills/outcome/`  
2. IAM role trust using `DESC INTEGRATION` (`STORAGE_AWS_IAM_USER_ARN`, `STORAGE_AWS_EXTERNAL_ID`)  
3. `CREATE STAGE` on `s3://…/raw/global/fills/outcome/` (same prefix as integration)  
4. `LIST @stage/...` then `COPY INTO` (Snowpipe later if you want auto-ingest on new keys)

Example load after the stage exists:

```sql
COPY INTO fills_outcome_all
FROM @stg_s3_raw/all/date=2026-10-27/
FILE_FORMAT = (TYPE = PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

---

## Cost and region

- **Requester pays** on Hop 1: your AWS account pays S3 GET and data transfer for reads from Reservoir (HIP-4 daily file is ~26 MB; full history is a few GB total for this prefix — see one-pager).
- **Hop 1 copy** stays in `ap-northeast-1` (server-side); bytes do not need to pass through your laptop.
- **Hop 2**: Snowflake reads your bucket; keep Snowflake on **AWS** and prefer an account region close to `ap-northeast-1` to limit cross-region transfer.

---

## What not to do

| Approach | Why it fails or hurts |
|---|---|
| External stage URL = `s3://hydromancer-reservoir/...` | No requester-payer on stage; access denied or wrong billing model |
| DuckDB/httpfs `REQUESTER_PAYS` straight into Snowflake | Different stack; still not Snowflake-native load |
| Sync all of `global/fills/raw/` | ~640 MB/day, mostly irrelevant to HIP-4 Outcome analytics |

---

## Checklist

- [ ] Reservoir day copied to `…/raw/global/fills/outcome/all/date=D/fills.parquet`
- [ ] Snowflake storage integration + IAM role (AWS not connected yet → do this next)
- [ ] `LIST @stg_s3_raw/...` succeeds
- [ ] `COPY INTO` for one `date=D` partition
- [ ] (Later) Prefect or Snowpipe for daily T+1 partitions
