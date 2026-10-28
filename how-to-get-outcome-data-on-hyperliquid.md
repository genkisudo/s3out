# How to get Outcome data on Hyperliquid

A worked test for the Outcome analytics project: copy one closed day of HIP-4 fills from Hydromancer Reservoir into our own S3 bucket, and the permission error that stopped the first copy.

Reservoir is Hydromancer's public archive of Hyperliquid history. Outcome markets are HIP-4 prediction markets, and their fills live in one Parquet file per UTC day:

```text
s3://hydromancer-reservoir/global/fills/outcome/all/date=YYYY-MM-DD/fills.parquet
```

The bucket is in `ap-northeast-1` and is requester-pays. There is no Hydromancer API key. AWS bills our account for the list and the read. Each UTC day is published the next morning, around 10:00–12:00 UTC, so "today" is not in the bucket yet.

This test uses the IAM profile `outcome` (user `outcome-analytics`), which can list and get objects only under the Outcome prefixes, and can write only to `raw/` and `landing/` in our bucket:

```text
s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an
```

## See which day is actually there

On 22 October 2026 we listed the HIP-4 fill days. This is one list request. It does not download a file.

```bash
aws s3 ls s3://hydromancer-reservoir/global/fills/outcome/all/ \
  --request-payer requester \
  --profile outcome \
  --region ap-northeast-1
```

`--profile outcome` selects the scoped user. `--request-payer requester` is required on every Reservoir call. Without it, S3 rejects the request before it returns any keys.

The newest folders were:

```text
PRE date=2026-10-17/
PRE date=2026-10-18/
PRE date=2026-10-19/
PRE date=2026-10-20/
PRE date=2026-10-21/
```

`date=2026-10-22/` was absent. The newest closed day, `2026-10-21`, is the sample.

## Read the size before copying

`head-object` returns the byte count and does not download the Parquet file.

```bash
aws s3api head-object \
  --bucket hydromancer-reservoir \
  --key global/fills/outcome/all/date=2026-10-21/fills.parquet \
  --request-payer requester \
  --profile outcome \
  --region ap-northeast-1 \
  --query ContentLength \
  --output text
```

The result was `23433404` bytes, about 22.3 MB. That matches the expected size of one day of `global/fills/outcome/all` (the one-pager's planning figure is about 26 MB).

## Copy that one object into our bucket

The copy stays inside `ap-northeast-1`. The bytes do not come down to the laptop. The destination key keeps the Reservoir path under `raw/`, so the day and the dataset stay visible in the key.

```bash
aws s3 cp \
  s3://hydromancer-reservoir/global/fills/outcome/all/date=2026-10-21/fills.parquet \
  s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/all/date=2026-10-21/fills.parquet \
  --request-payer requester \
  --copy-props none \
  --profile outcome \
  --region ap-northeast-1
```

A successful run prints:

```text
copy: s3://hydromancer-reservoir/global/fills/outcome/all/date=2026-10-21/fills.parquet to s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/all/date=2026-10-21/fills.parquet
```

## The error on the first copy

The first copy used the same command without `--copy-props none` and failed:

```text
copy failed: s3://hydromancer-reservoir/global/fills/outcome/all/date=2026-10-21/fills.parquet to s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/all/date=2026-10-21/fills.parquet An error occurred (AccessDenied) when calling the GetObjectTagging operation: Access Denied
```

The file was readable. `head-object` had already returned its size, and the policy allows `s3:GetObject` on `global/fills/outcome/*`. The default `aws s3 cp` between two buckets also tries to copy object tags. That is a separate API call, `GetObjectTagging`, and the policy does not allow it. S3 refused the tag read, and the CLI aborted the copy before writing the Parquet file.

`--copy-props none` copies the object bytes only. It skips tags and the other source properties. The analytics copy needs the Parquet file, not Reservoir's tags, so the policy stays limited to `GetObject` and `GetObjectAttributes` on the source. We did not add `s3:GetObjectTagging`.

Use `--copy-props none` on later Reservoir copies and syncs with this profile. The default value of `--copy-props` is what triggers the tag read.

## Check that the whole file arrived

Read the size of the object in our bucket. This is our bucket, so the command has no `--request-payer`.

```bash
aws s3api head-object \
  --bucket outcome-hip4-436535002811-436535002811-ap-northeast-1-an \
  --key raw/global/fills/outcome/all/date=2026-10-21/fills.parquet \
  --profile outcome \
  --region ap-northeast-1 \
  --query ContentLength \
  --output text
```

The destination size was also `23433404`. The sample is complete.

The test object is:

```text
s3://outcome-hip4-436535002811-436535002811-ap-northeast-1-an/raw/global/fills/outcome/all/date=2026-10-21/fills.parquet
```

Same checks for the next day: list the prefix, take the newest `date=` folder, `head-object` it, copy that one key with `--request-payer requester` and `--copy-props none`, then confirm the destination length matches the source.

## How this file is already HIP-4 only

Hyperliquid's whole fill history is a different object, `global/fills/raw/date=D/fills.parquet`, about 640 MB a day. It mixes perps, spot, and HIP-4. We never listed or copied that prefix.

Reservoir already splits HIP-4 fills into their own path. The HIP-4 filter is the folder, not a `WHERE` clause:

```text
s3://hydromancer-reservoir/global/fills/outcome/all/date=D/fills.parquet
```

`builder_fills/` next to `all/` is the same HIP-4 day, limited to fills that carry a builder address. HIP-4 order books are a third path, `by_dex/hyperliquid/orderbook/1m/outcome/`. The IAM policy on `outcome-analytics` allows `s3:ListBucket` and `s3:GetObject` only under those Outcome prefixes, plus `global/snapshots/spot/`. A request for `global/fills/raw/` or for perp fills fails even with a valid key.

Inside `all/`, every row is a HIP-4 fill. The file carries `outcome_id` and `outcome_side`, which the perp and spot fill files do not. The side coin is `#<encoding>`, for example `#155630`. The market key is `outcome_id` (or `CAST(substr(coin, 2) AS BIGINT) // 10`) and the side is `outcome_side`.

For 2026-10-21 that file has 372,675 rows and is about 22.3 MB. `direction` splits them into trades and position changes:

| direction | rows |
|---|---|
| Buy | 185,336 |
| Sell | 162,252 |
| Merge Outcome | 10,330 |
| Settlement | 9,258 |
| Split Outcome | 2,736 |
| Negate Outcome | 2,234 |
| Merge Question | 529 |

Buy plus Sell is 347,588. Those rows split evenly into 173,794 taker rows (`crossed` true) and 173,794 resting rows (`crossed` false). Each match is stored twice. Trade counts and volume keep one side:

```sql
WHERE direction IN ('Buy', 'Sell')
  AND crossed
```

That trade-only rule is a filter inside the HIP-4 file. It is not how HIP-4 was separated from the rest of Hyperliquid.

This file is still every HIP-4 deployer, not Outcome's venue alone. Markets with `venue = 'out'` are the project scope. That venue filter is not applied at copy time. It belongs in one later model, `int_outcome_venue_filter`.

## Names on the 2026-10-21 fills file

`DESCRIBE` on the copied Parquet file returns these columns:

| column | type |
|---|---|
| `coin` | `VARCHAR` |
| `dex` | `VARCHAR` |
| `asset_class` | `VARCHAR` |
| `base_symbol` | `VARCHAR` |
| `quote_symbol` | `VARCHAR` |
| `price` | `DECIMAL(20,10)` |
| `size` | `DECIMAL(20,10)` |
| `side` | `VARCHAR` |
| `timestamp` | `TIMESTAMP WITH TIME ZONE` |
| `direction` | `VARCHAR` |
| `realized_pnl` | `DECIMAL(20,10)` |
| `tx_hash` | `VARCHAR` |
| `order_id` | `BIGINT` |
| `trade_id` | `BIGINT` |
| `fee` | `DECIMAL(20,10)` |
| `fee_token` | `VARCHAR` |
| `address` | `VARCHAR` |
| `crossed` | `BOOLEAN` |
| `start_position` | `DECIMAL(20,10)` |
| `client_order_id` | `VARCHAR` |
| `builder` | `VARCHAR` |
| `builder_fee` | `DECIMAL(20,10)` |
| `deployer_fee` | `DECIMAL(20,10)` |
| `priority_gas` | `DECIMAL(20,10)` |
| `twap_id` | `BIGINT` |
| `is_liquidation` | `BOOLEAN` |
| `liquidation_mark_px` | `DECIMAL(20,10)` |
| `liquidation_method` | `VARCHAR` |
| `outcome_id` | `UINTEGER` |
| `outcome_side` | `VARCHAR` |
| `date` | `DATE` |

There is no `venue` column and no `outcome_markets` table. `dex` is `hyperliquid` on all 372,675 rows. The HIP-4 columns added to the standard fill schema are `outcome_id` and `outcome_side`.

The market key matches the coin on every row. `CAST(substr(coin, 2) AS BIGINT) // 10` equals `outcome_id` for all 372,675 fills. The day has 573 distinct `outcome_id` values. `outcome_side` has two values:

| outcome_side | rows |
|---|---|
| `NO` | 182,651 |
| `YES` | 190,024 |

A fill's identity in later models is `outcome_id` plus `outcome_side`. A match's identity for trade counts is `trade_id` on the row where `crossed` is true. In DuckDB, alias that count as `row_count`. The name `rows` is reserved and fails in `ORDER BY`.
