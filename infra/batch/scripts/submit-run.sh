#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE is required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MODE="${MODE:?MODE is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
IAC_CMD="${IAC_CMD:-tofu}"

job_queue="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw job_queue)"
worker_def="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw worker_job_definition)"
reducer_def="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw reducer_job_definition)"
output_bucket="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw output_bucket)"
array_size="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw array_size)"
file_count="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw file_count)"
compute_environment="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw compute_environment)"
submitted_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
submitted_at_epoch_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"

worker_overrides="$(jq -cn \
  --arg run_id "$RUN_ID" \
  --arg output_bucket "$output_bucket" \
  --arg region "$AWS_REGION" \
  --arg file_count "$file_count" \
  --arg array_size "$array_size" \
  '{environment:[
    {name:"RUN_ID",value:$run_id},
    {name:"OUTPUT_BUCKET",value:$output_bucket},
    {name:"AWS_REGION",value:$region},
    {name:"FILE_COUNT",value:$file_count},
    {name:"ARRAY_SIZE",value:$array_size},
    {name:"RUST_LOG",value:"info"}
  ]}')"

if [[ "$array_size" -eq 1 ]]; then
  worker_overrides="$(jq -cn \
    --arg run_id "$RUN_ID" \
    --arg output_bucket "$output_bucket" \
    --arg region "$AWS_REGION" \
    --arg file_count "$file_count" \
    --arg array_size "$array_size" \
    '{environment:[
      {name:"RUN_ID",value:$run_id},
      {name:"OUTPUT_BUCKET",value:$output_bucket},
      {name:"AWS_REGION",value:$region},
      {name:"FILE_COUNT",value:$file_count},
      {name:"ARRAY_SIZE",value:$array_size},
      {name:"SHARD_INDEX",value:"0"},
      {name:"RUST_LOG",value:"info"}
    ]}')"
  worker_json="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" batch submit-job \
    --job-name "1trc-${MODE}-worker-${RUN_ID}" \
    --job-queue "$job_queue" \
    --job-definition "$worker_def" \
    --container-overrides "$worker_overrides")"
else
  worker_json="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" batch submit-job \
    --job-name "1trc-${MODE}-workers-${RUN_ID}" \
    --job-queue "$job_queue" \
    --job-definition "$worker_def" \
    --array-properties "size=$array_size" \
    --container-overrides "$worker_overrides")"
fi
worker_job_id="$(jq -r '.jobId' <<<"$worker_json")"

reducer_overrides="$(jq -cn \
  --arg run_id "$RUN_ID" \
  --arg output_bucket "$output_bucket" \
  --arg region "$AWS_REGION" \
  --arg array_size "$array_size" \
  --arg mode "$MODE" \
  '{environment:[
    {name:"RUN_ID",value:$run_id},
    {name:"OUTPUT_BUCKET",value:$output_bucket},
    {name:"AWS_REGION",value:$region},
    {name:"ARRAY_SIZE",value:$array_size},
    {name:"MODE",value:$mode},
    {name:"RUST_LOG",value:"info"}
  ]}')"

reducer_json="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" batch submit-job \
  --job-name "1trc-${MODE}-reducer-${RUN_ID}" \
  --job-queue "$job_queue" \
  --job-definition "$reducer_def" \
  --depends-on "jobId=$worker_job_id" \
  --container-overrides "$reducer_overrides")"
reducer_job_id="$(jq -r '.jobId' <<<"$reducer_json")"

mkdir -p "$ROOT_DIR/.run"
cat > "$ROOT_DIR/.run/current-run.json" <<JSON
{
  "run_id": "$RUN_ID",
  "mode": "$MODE",
  "submitted_at_utc": "$submitted_at_utc",
  "submitted_at_epoch_ms": $submitted_at_epoch_ms,
  "worker_job_id": "$worker_job_id",
  "reducer_job_id": "$reducer_job_id",
  "job_queue": "$job_queue",
  "worker_job_definition": "$worker_def",
  "reducer_job_definition": "$reducer_def",
  "compute_environment": "$compute_environment",
  "output_bucket": "$output_bucket",
  "array_size": $array_size,
  "file_count": $file_count
}
JSON

echo "Worker job:       $worker_job_id"
echo "Reducer job:      $reducer_job_id"
echo "Run metadata:     $ROOT_DIR/.run/current-run.json"
