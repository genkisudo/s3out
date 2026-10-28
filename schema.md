# HIP-4 outcome fills schema

Columns from `global/fills/outcome/all/date=D/fills.parquet`, confirmed on the copied 2026-10-21 file ([how-to-get-outcome-data-on-hyperliquid.md](./how-to-get-outcome-data-on-hyperliquid.md)). Types below are as reported by DuckDB `DESCRIBE` on Parquet; Snowflake `INFER_SCHEMA` may map `UBIGINT`/`UINTEGER` to `NUMBER`.

| column | type |
|---|---|
| `coin` | `VARCHAR` |
| `dex` | `VARCHAR` |
| `asset_class` | `VARCHAR` |
| `base_symbol` | `VARCHAR` |
| `quote_symbol` | `VARCHAR` |
| `price` | `DECIMAL` |
| `size` | `DECIMAL` |
| `side` | `VARCHAR` |
| `timestamp` | `TIMESTAMP WITH TIME ZONE` |
| `direction` | `VARCHAR` |
| `realized_pnl` | `DECIMAL` |
| `tx_hash` | `VARCHAR` |
| `order_id` | `UBIGINT` |
| `trade_id` | `UBIGINT` |
| `fee` | `DECIMAL` |
| `fee_token` | `VARCHAR` |
| `address` | `VARCHAR` |
| `crossed` | `BOOLEAN` |
| `start_position` | `DECIMAL` |
| `client_order_id` | `VARCHAR` |
| `builder` | `VARCHAR` |
| `builder_fee` | `DECIMAL` |
| `deployer_fee` | `DECIMAL` |
| `priority_gas` | `DECIMAL` |
| `twap_id` | `UBIGINT` |
| `is_liquidation` | `BOOLEAN` |
| `liquidation_mark_px` | `DECIMAL` |
| `liquidation_method` | `VARCHAR` |
| `outcome_id` | `UINTEGER` |
| `outcome_side` | `VARCHAR` |
| `date` | `DATE` |

There is no `venue` column. HIP-4-specific fields are `outcome_id` and `outcome_side`.
