#!/usr/bin/env bash
# Copy one UTC day of HIP-4 outcome fills from Hydromancer Reservoir into our raw/ prefix.
set -euo pipefail

DAY="${1:?Usage: $0 YYYY-MM-DD}"

AWS_PROFILE="${AWS_PROFILE:-outcome}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
RESERVOIR_BUCKET="hydromancer-reservoir"
OWN_BUCKET="outcome-hip4-436535002811-436535002811-ap-northeast-1-an"

KEY="global/fills/outcome/all/date=${DAY}/fills.parquet"
SRC="s3://${RESERVOIR_BUCKET}/${KEY}"
DST="s3://${OWN_BUCKET}/raw/${KEY}"

export AWS_PROFILE AWS_REGION

echo "Source: ${SRC}"
echo "Dest:   ${DST}"

src_len="$(aws s3api head-object \
  --bucket "${RESERVOIR_BUCKET}" \
  --key "${KEY}" \
  --request-payer requester \
  --query ContentLength \
  --output text)"

echo "Source size: ${src_len} bytes"

aws s3 cp "${SRC}" "${DST}" \
  --request-payer requester \
  --copy-props none

dst_len="$(aws s3api head-object \
  --bucket "${OWN_BUCKET}" \
  --key "raw/${KEY}" \
  --query ContentLength \
  --output text)"

echo "Dest size:   ${dst_len} bytes"

if [[ "${src_len}" != "${dst_len}" ]]; then
  echo "ERROR: size mismatch" >&2
  exit 1
fi

echo "OK: ${DAY}"
