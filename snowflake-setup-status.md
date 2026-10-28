# Snowflake setup status (Phase 2)

Track what is done in **your** Snowflake account vs **AWS** vs **S3 landing**. Do not commit `snow.md` or `trust-snowflake.json` (they contain integration trust values).

---

## Completed in Snowflake

Run as `ACCOUNTADMIN` (or equivalent):

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE STORAGE INTEGRATION s3_outcome_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::436535002811:role/snowflake-s3-outcome'
  STORAGE_ALLOWED_LOCATIONS = (
    's3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/'
  )
  COMMENT = 'Read HIP-4 Parquet landed from Reservoir';

DESC STORAGE INTEGRATION s3_outcome_int;
```

**Integration name:** `s3_outcome_int`  
**Allowed prefix:** `s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/`  
**IAM role ARN (must exist in AWS account 436535002811):** `arn:aws:iam::436535002811:role/snowflake-s3-outcome`

After `DESC`, save locally (not in git):

- `STORAGE_AWS_IAM_USER_ARN` — Snowflake’s user; goes in the role **trust policy**
- `STORAGE_AWS_EXTERNAL_ID` — goes in the trust **condition**

Example local file: `snow.md` (gitignored).

---

## Completed on AWS (landing)

| Item | Status |
|---|---|
| HIP-4 day copied to your bucket | Done — e.g. `date=2026-10-27/fills.parquet` (27,783,980 bytes) |
| Profile for Reservoir + bucket writes | `outcome` (`outcome-analytics`) |
| IAM role `snowflake-s3-outcome` | **Blocked** — CLI user `test` (`main`) lacks `iam:CreateRole`; create role in **Console** as admin or use an admin AWS profile |

Trust and S3 read policy templates (gitignored when filled): `trust-snowflake.json`, `snowflake-s3-read.json` in repo root.

---

## Not done yet (Path A — next commands)

Run in order after the IAM role exists:

```sql
GRANT USAGE ON INTEGRATION s3_outcome_int TO ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS OUTCOME_ANALYTICS;
CREATE SCHEMA IF NOT EXISTS OUTCOME_ANALYTICS.RAW;
USE DATABASE OUTCOME_ANALYTICS;
USE SCHEMA RAW;

CREATE OR REPLACE STAGE stg_s3_raw
  STORAGE_INTEGRATION = s3_outcome_int
  URL = 's3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/'
  FILE_FORMAT = (TYPE = PARQUET);

LIST @stg_s3_raw/all/date=2026-10-27/;
```

Then table + load: [how-to-connect-snowflake-to-aws-s3.md](./how-to-connect-snowflake-to-aws-s3.md) Step 4 (use `2026-10-27` in paths).

---

## Path B (no your-S3 archive)

If you skip the external stage entirely, use internal stage + `PUT` after CLI download. See [data-paths-reservoir-to-snowflake.md](./data-paths-reservoir-to-snowflake.md).

---

## Related docs

- [Two paths: with vs without your S3](./data-paths-reservoir-to-snowflake.md)
- [Phase checklist](./plan.md)
- [Connect Snowflake to your bucket](./how-to-connect-snowflake-to-aws-s3.md)
