#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/results"
export PATH="$PROJECT_ROOT/.tools/bin:$PATH"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_ROOT/.tools/venv/bin/python}"
MODE="full"
MAX_THREADS=""
SSM_EXECUTION_TIMEOUT_SECONDS="${SSM_EXECUTION_TIMEOUT_SECONDS:-14400}"
REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE_OPTION=()

tfvar_value() {
  local key="$1"
  local file="$ROOT_DIR/terraform.tfvars"
  [[ -f "$file" ]] || return 1
  awk -F= -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$file"
}

configure_aws_cli() {
  local profile="${AWS_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    profile="$(tfvar_value aws_profile || true)"
  fi
  if [[ -n "$profile" && "$profile" != "null" ]]; then
    AWS_PROFILE_OPTION=(--profile "$profile")
  fi
}

aws_cli() {
  aws "${AWS_PROFILE_OPTION[@]}" "$@"
}

base64_encode_file_one_line() {
  base64 < "$1" | tr -d '\n'
}

base64_decode_stdin() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}
if [[ -x "$PROJECT_ROOT/.tools/bin/tofu" ]]; then
  IAC_CMD="${IAC_CMD:-$PROJECT_ROOT/.tools/bin/tofu}"
elif command -v tofu >/dev/null 2>&1; then
  IAC_CMD="${IAC_CMD:-tofu}"
else
  IAC_CMD="${IAC_CMD:-terraform}"
fi

usage() {
  echo "Usage: $0 [--max-threads N]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-threads) MAX_THREADS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for command in aws "$IAC_CMD" jq base64 gzip; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -x "$PYTHON_BIN" ]] || { echo "Missing project Python venv: $PYTHON_BIN. Run $PROJECT_ROOT/scripts/bootstrap.sh first." >&2; exit 1; }

configure_aws_cli
[[ "$REGION" == "us-east-1" ]] || { echo "Refusing non-dataset region: $REGION" >&2; exit 1; }
tf_mode="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw run_mode)"
leader="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw leader_instance_id)"
instance_type="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw instance_type)"
instance_count="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw instance_count)"
market_type="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw market_type 2>/dev/null || echo spot)"
availability_zone="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw availability_zone)"
launch_time="$(aws_cli ec2 describe-instances --region "$REGION" \
  --instance-ids "$leader" \
  --query 'Reservations[0].Instances[0].LaunchTime' --output text)"

[[ "$tf_mode" == "full" ]] || { echo "Terraform was not applied in full mode." >&2; exit 1; }
s3_url="https://coiled-datasets-rp.s3.us-east-1.amazonaws.com/1trc/measurements-*.parquet"
expected_files=100000
: "${MAX_THREADS:=128}"

mkdir -p "$RESULTS_DIR" "$ROOT_DIR/.run"
query_id="1trc-${MODE}-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
printf '%s\n' "$query_id" > "$ROOT_DIR/.run/current-query-id"
sql_b64="$(base64_encode_file_one_line "$ROOT_DIR/sql/aggregate.sql")"
runner_b64="$(base64_encode_file_one_line "$SCRIPT_DIR/remote-run-query.sh")"

commands_json="$(jq -cn \
  --arg sql "$sql_b64" \
  --arg runner "$runner_b64" \
  --arg url "$s3_url" \
  --arg threads "$MAX_THREADS" \
  --arg mode "$MODE" \
  --arg files "$expected_files" \
  --arg query_id "$query_id" \
  --arg execution_timeout "$SSM_EXECUTION_TIMEOUT_SECONDS" \
  '{commands:[
    ("printf %s " + ($sql|@sh) + " | base64 -d > /tmp/1trc-aggregate.sql"),
    ("printf %s " + ($runner|@sh) + " | base64 -d > /tmp/1trc-run-query.sh"),
    "chmod 700 /tmp/1trc-run-query.sh",
    ("/tmp/1trc-run-query.sh " + ($url|@sh) + " " + ($threads|@sh) + " " + ($mode|@sh) + " " + ($files|@sh) + " " + ($query_id|@sh))
  ], executionTimeout:[$execution_timeout]}')"

echo "Submitting $MODE query to $leader. Query ID: $query_id. Dataset URL: $s3_url"
command_id="$(aws_cli ssm send-command \
  --region "$REGION" \
  --instance-ids "$leader" \
  --document-name AWS-RunShellScript \
  --comment "1TRC ClickHouse $MODE query" \
  --parameters "$commands_json" \
  --timeout-seconds 14400 \
  --query 'Command.CommandId' \
  --output text)"

while true; do
  status="$(aws_cli ssm get-command-invocation --region "$REGION" \
    --command-id "$command_id" --instance-id "$leader" --query Status --output text)"
  case "$status" in
    Success) break ;;
    Pending|InProgress|Delayed) sleep 10 ;;
    *)
      aws_cli ssm get-command-invocation --region "$REGION" \
        --command-id "$command_id" --instance-id "$leader" \
        --query '{Status:Status,StandardError:StandardErrorContent}' --output json >&2
      exit 1
      ;;
  esac
done

output="$(aws_cli ssm get-command-invocation --region "$REGION" \
  --command-id "$command_id" --instance-id "$leader" \
  --query StandardOutputContent --output text)"
result_b64="$(printf '%s\n' "$output" | sed -n 's/^RESULT_GZIP_BASE64=//p')"
metrics_b64="$(printf '%s\n' "$output" | sed -n 's/^METRICS_JSON_BASE64=//p')"
[[ -n "$result_b64" && -n "$metrics_b64" ]] || {
  echo "SSM output was missing result markers, possibly due to output truncation." >&2
  exit 1
}

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_file="$RESULTS_DIR/clickhouse-${MODE}-${run_stamp}.csv"
metrics_file="$RESULTS_DIR/clickhouse-${MODE}-${run_stamp}.json"
result_file_public="results/$(basename "$result_file")"
printf '%s' "$result_b64" | base64_decode_stdin | gzip -d > "$result_file"
remote_metrics="$(printf '%s' "$metrics_b64" | base64_decode_stdin)"

jq -n \
  --argjson remote "$remote_metrics" \
  --arg aws_region "$REGION" \
  --arg availability_zone "$availability_zone" \
  --arg instance_type "$instance_type" \
  --argjson instance_count "$instance_count" \
  --arg pricing_mode "$market_type" \
  --arg launch_time "$launch_time" \
  --arg result_file "$result_file_public" \
  '$remote + {aws_region:$aws_region,availability_zone:$availability_zone,
    instance_type:$instance_type,instance_count:$instance_count,
    pricing_mode:$pricing_mode,launch_time:$launch_time,result_file:$result_file,
    git_commit:"unavailable",provisioning_seconds:null,data_copy_seconds:0,
    teardown_seconds:null,end_to_end_seconds:null,
    estimated_s3_request_cost_usd:null,estimated_compute_cost_usd:null,
    estimated_storage_cost_usd:null,estimated_data_transfer_or_nat_cost_usd:0,
    total_estimated_cost_usd:null}' > "$metrics_file"

"$PYTHON_BIN" "$PROJECT_ROOT/scripts/validate-results.py" "$result_file" \
  --expected-stations 412 \
  --metrics "$metrics_file" \
  --expected-read-rows 1000000000000
"$PYTHON_BIN" "$PROJECT_ROOT/scripts/summarize-clickhouse-metrics.py" "$metrics_file"
echo "Result:  $result_file"
echo "Metrics: $metrics_file"
