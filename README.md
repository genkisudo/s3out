# Outcome analytics (s3out)

End-to-end analytics: **HIP-4 Reservoir → your S3 → Snowflake → (later) dbt / Iceberg / Prefect / Cortex.**

**Current focus:** Phase 1–2 only — landing and Snowflake raw load. **No modeling yet.**

→ **[plan.md](./plan.md)** — phased checklist and what’s deferred

## Phase 1–2 (now)

- [Reservoir → your S3](./how-to-reservoir-to-snowflake.md) (Hydromancer requester-pays; HIP-4 `outcome/all` only)
- [Connect Snowflake to your AWS bucket](./how-to-connect-snowflake-to-aws-s3.md) (storage integration + `COPY INTO` raw)
- [Copy one day with AWS CLI](./how-to-get-outcome-data-on-hyperliquid.md) — [Reservoir](https://docs.hydromancer.xyz/reservoir)

```text
Reservoir (requester pays)  ──AWS CLI──►  your S3 raw/global/fills/outcome/…
                                                │
                                                ▼
                                           Snowflake RAW  ← Phase 2 stops here
```

## Phase 3+ (planned, not started)

- dbt, Iceberg marts, venue filter, Prefect, Cortex — see [plan.md](./plan.md) and [future modeling notes](./how-to-model-iceberg-in-snowflake.md)

### Source bucket: `s3://hydromancer-reservoir` (requester pays)


```mermaid
flowchart LR
    A["Hydromancer S3<br/>requester pays"]
    A2["Your S3 raw<br/>HIP-4 Parquet"]
    B["Snowflake RAW<br/>Phase 2"]
    C["dbt + Iceberg<br/>Phase 3 planned"]
    D["Cortex / BI<br/>Phase 4 planned"]
    F["Prefect<br/>Phase 4 planned"]

    A -->|"AWS CLI"| A2
    A2 -->|"COPY / Snowpipe"| B
    B -.->|"later"| C
    C -.-> D
    F -.->|"later"| A2
    F -.->|"later"| B
```
