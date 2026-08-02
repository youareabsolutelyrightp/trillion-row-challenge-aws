#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_FILE="${BATCH_RUN_CONFIG:-$ROOT_DIR/run-config.env}"
source "$CONFIG_FILE"
AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE is required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RUN_FILE="$ROOT_DIR/.run/current-run.json"
[[ -f "$RUN_FILE" ]] || { echo "No current run file: $RUN_FILE" >&2; exit 1; }

run_id="$(jq -r '.run_id' "$RUN_FILE")"
mode="$(jq -r '.mode' "$RUN_FILE")"
bucket="$(jq -r '.output_bucket' "$RUN_FILE")"
mkdir -p "$PROJECT_ROOT/results"
result_file="$PROJECT_ROOT/results/batch-${mode}-${run_id}.csv"
metrics_file="$PROJECT_ROOT/results/batch-${mode}-${run_id}.json"

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3 cp "s3://$bucket/runs/$run_id/final/result.csv" "$result_file"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3 cp "s3://$bucket/runs/$run_id/final/metrics.json" "$metrics_file"

echo "Result CSV:   $result_file"
echo "Metrics JSON: $metrics_file"
