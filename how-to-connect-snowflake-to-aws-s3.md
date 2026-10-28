# Connect Snowflake to your AWS S3 bucket (Path A)

For **Path B** (no your-S3 archive, internal stage + `PUT`), see [data-paths-reservoir-to-snowflake.md](./data-paths-reservoir-to-snowflake.md).

**Progress:** [snowflake-setup-status.md](./snowflake-setup-status.md) — storage integration `s3_outcome_int` is created in Snowflake; IAM role still required before `LIST @stage`.

Snowflake cannot read Hydromancer Reservoir directly with **requester pays** on a normal external stage (no `RequestPayer` on `CREATE STAGE`). The path that matches this repo is:

1. **AWS CLI** — copy Parquet from Reservoir into **your** bucket (`--request-payer requester`, `--copy-props none`). See [how-to-get-outcome-data-on-hyperliquid.md](./how-to-get-outcome-data-on-hyperliquid.md).
2. **Storage integration** — let Snowflake assume an IAM role in your account and read only `raw/global/fills/outcome/` (HIP-4 Parquet you landed).
3. **External stage + load** — `COPY INTO` (prove it) or **Snowpipe** (optional; see [plan.md](./plan.md) Phase 2).

Known AWS values from your setup:

| Item | Value |
|---|---|
| AWS account | `436535002811` |
| CLI profile | `outcome` |
| Bucket | `outcome-hip4-436535002811-436535002811-ap-northeast-1-an` |
| Region | `ap-northeast-1` |
| Sample object | `raw/global/fills/outcome/all/date=2026-10-21/fills.parquet` |

---

## What you need from Snowflake

Before running AWS IAM steps, open **Snowflake** (Worksheets or SnowSQL) as a role that can create integrations (often `ACCOUNTADMIN` or a custom role with `CREATE INTEGRATION`).

You will also need:

- **Account identifier** — e.g. `xy12345.ap-northeast-1.aws` (Account → Account Details).
- **Database / schema** names for raw tables (examples below use `OUTCOME_ANALYTICS.RAW`).

---

## Step 1 — Storage integration (Snowflake)

**Status:** Created in this project as `s3_outcome_int` (see [snowflake-setup-status.md](./snowflake-setup-status.md)). Re-run only if you need to recreate it.

Pick an IAM role name in AWS (create the role in Step 2). Example role ARN:

```text
arn:aws:iam::436535002811:role/snowflake-s3-outcome
```

Run in Snowflake:

```sql
USE ROLE ACCOUNTADMIN;  -- or your admin role

CREATE OR REPLACE STORAGE INTEGRATION s3_outcome_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::436535002811:role/snowflake-s3-outcome'
  STORAGE_ALLOWED_LOCATIONS = (
    's3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/'
  )
  COMMENT = 'Read HIP-4 Parquet landed from Reservoir';
```

Get the trust values Snowflake will use to assume your role:

```sql
DESC STORAGE INTEGRATION s3_outcome_int;
```

Copy these two fields (names are stable in Snowflake docs):

- `STORAGE_AWS_IAM_USER_ARN` — Snowflake’s IAM user in **Snowflake’s** AWS account (put this in the role **trust policy**).
- `STORAGE_AWS_EXTERNAL_ID` — random id (required in the trust **condition**).

Grant the integration to the roles that will create stages and load data:

```sql
GRANT USAGE ON INTEGRATION s3_outcome_int TO ROLE SYSADMIN;
-- later: GRANT USAGE ON INTEGRATION s3_outcome_int TO ROLE <dbt_role>;
```

---

## Step 2 — IAM role in AWS (436535002811)

Create role `snowflake-s3-outcome` (Console: IAM → Roles → Create role → **Custom trust policy**, or CLI below).

Replace placeholders with the values from `DESC STORAGE INTEGRATION`:

**Trust policy** (`trust-snowflake.json`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "<STORAGE_AWS_IAM_USER_ARN from DESC INTEGRATION>"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID from DESC INTEGRATION>"
        }
      }
    }
  ]
}
```

**Permissions policy** (read-only on your landed data; no Reservoir bucket):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SnowflakeListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::outcome-hip4-436535002811-436535002811-ap-northeast-1-an",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["raw/global/fills/outcome/", "raw/global/fills/outcome/*"]
        }
      }
    },
    {
      "Sid": "SnowflakeGetObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/*"
    }
  ]
}
```

Example CLI (after saving the two JSON files locally):

```bash
aws iam create-role \
  --role-name snowflake-s3-outcome \
  --assume-role-policy-document file://trust-snowflake.json \
  --profile main

aws iam put-role-policy \
  --role-name snowflake-s3-outcome \
  --policy-name snowflake-s3-outcome-read \
  --policy-document file://snowflake-s3-read.json \
  --profile main
```

Use whichever AWS profile can create IAM roles (`main` vs `outcome` — IAM is usually on an admin profile, not the scoped `outcome-analytics` user). User `test` on profile `main` in account `436535002811` currently gets **AccessDenied** on `iam:CreateRole`; use the **IAM Console** as admin or an admin profile ([snowflake-setup-status.md](./snowflake-setup-status.md)).

---

## Step 3 — External stage (Snowflake)

```sql
USE DATABASE OUTCOME_ANALYTICS;
CREATE SCHEMA IF NOT EXISTS RAW;
USE SCHEMA RAW;

CREATE OR REPLACE STAGE stg_s3_raw
  STORAGE_INTEGRATION = s3_outcome_int
  URL = 's3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/'
  FILE_FORMAT = (TYPE = PARQUET);

GRANT USAGE ON STAGE stg_s3_raw TO ROLE SYSADMIN;
```

List files (checks integration + IAM in one step):

```sql
LIST @stg_s3_raw/all/;
```

If `LIST` fails with access denied, re-check trust policy external ID, role ARN on the integration, and S3 prefix conditions.

---

## Step 4 — First load (COPY INTO)

Infer columns from one day, then load:

```sql
CREATE OR REPLACE TABLE fills_outcome_all (
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@stg_s3_raw/all/date=2026-10-21/fills.parquet',
        FILE_FORMAT => '(TYPE = PARQUET)'
      )
    )
  )
);

COPY INTO fills_outcome_all
FROM @stg_s3_raw/all/date=2026-10-21/
FILE_FORMAT = (TYPE = PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'ABORT_STATEMENT';

SELECT COUNT(*), MIN(date), MAX(date) FROM fills_outcome_all;
```

Expected row count for that file is about **372,675** (see [how-to-get-outcome-data-on-hyperliquid.md](./how-to-get-outcome-data-on-hyperliquid.md)).

---

## Step 5 — Snowpipe (optional, for README architecture)

Do this after `LIST` and one successful `COPY` work.

1. **S3 event notification** — send `s3:ObjectCreated:*` on prefix `raw/global/fills/outcome/all/` to an **SQS** queue (Snowflake docs: [Automating Snowpipe for Amazon S3](https://docs.snowflake.com/en/user-guide/data-load-snowpipe-auto-s3)).
2. **Snowflake notification integration** — `CREATE NOTIFICATION INTEGRATION` + `DESC` to wire SQS trust (similar pattern to storage integration).
3. **Pipe** — e.g. `CREATE PIPE ... AUTO_INGEST = TRUE AS COPY INTO ...`.

Snowpipe needs extra IAM on the same role (or a dedicated role): `sqs:ReceiveMessage`, `sqs:DeleteMessage`, and bucket notification permissions. Many teams start with **Prefect + COPY** per partition date, then add Snowpipe once the daily key layout is stable.

---

## Separation of duties (two AWS identities)

| Identity | Purpose |
|---|---|
| `outcome-analytics` (`--profile outcome`) | List/get **Reservoir** (requester pays), **put** objects under `raw/` and `landing/` in **your** bucket |
| `snowflake-s3-outcome` IAM role | **Read-only** on `raw/global/fills/outcome/*` for Snowflake loads only |

Snowflake never needs Reservoir credentials or `GetObjectTagging` on Hydromancer.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Snowflake `LIST @stage` access denied | Trust policy external ID / wrong `STORAGE_AWS_IAM_USER_ARN`, or S3 policy missing prefix |
| Integration created but stage still fails | `STORAGE_ALLOWED_LOCATIONS` must include the stage URL prefix exactly |
| Reservoir copy fails on tags | Add `--copy-props none` on `aws s3 cp` |
| Large unexpected AWS bill | Never sync `global/fills/raw/` (~640 MB/day); stay on `global/fills/outcome/all/` |

---

## Checklist

- [ ] At least one Parquet file in `s3://…/raw/global/fills/outcome/all/date=…/`
- [ ] `CREATE STORAGE INTEGRATION` + `DESC` in Snowflake
- [ ] IAM role `snowflake-s3-outcome` with trust + read policy
- [ ] `CREATE STAGE` + successful `LIST @stg_s3_raw/...`
- [ ] `COPY INTO` one partition day
- [ ] (Later) Snowpipe or Prefect-scheduled `COPY` for T+1 days
