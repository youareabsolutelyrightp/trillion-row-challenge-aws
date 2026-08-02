#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
export PATH="$PROJECT_ROOT/.tools/bin:$PATH"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_ROOT/.tools/venv/bin/python}"
REGION="${AWS_REGION:-us-east-1}"
LABEL=""
METRICS_FILE=""

usage() {
  cat <<USAGE
Usage: $0 --label LABEL [--metrics $PROJECT_ROOT/results/clickhouse-full-*.json]

Enriches a finished ClickHouse metrics JSON with EC2 instance network specs and
saves/updates:
  $PROJECT_ROOT/results/clickhouse-comparison-runs.jsonl
  $PROJECT_ROOT/results/clickhouse-comparison.md
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --metrics) METRICS_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n "$LABEL" ]] || { usage >&2; exit 2; }
[[ "$REGION" == "us-east-1" ]] || { echo "Refusing region $REGION." >&2; exit 1; }

if [[ -z "$METRICS_FILE" ]]; then
  METRICS_FILE="$(find "$PROJECT_ROOT/results" -maxdepth 1 -name 'clickhouse-full-[0-9]*T[0-9]*Z.json' -type f | sort | tail -n 1)"
fi
[[ -n "$METRICS_FILE" && -f "$METRICS_FILE" ]] || { echo "Metrics file not found." >&2; exit 1; }

for command in aws jq; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -x "$PYTHON_BIN" ]] || { echo "Missing project Python venv: $PYTHON_BIN. Run $PROJECT_ROOT/scripts/bootstrap.sh first." >&2; exit 1; }

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

AWS_PROFILE_OPTION=()
profile="${AWS_PROFILE:-$(tfvar_value aws_profile || true)}"
if [[ -n "$profile" && "$profile" != "null" ]]; then
  AWS_PROFILE_OPTION=(--profile "$profile")
fi
aws_cli() { aws "${AWS_PROFILE_OPTION[@]}" "$@"; }

instance_type="$(jq -r '.instance_type' "$METRICS_FILE")"
[[ -n "$instance_type" && "$instance_type" != "null" ]] || { echo "Metrics file lacks instance_type." >&2; exit 1; }

spec_file="$(mktemp)"
trap 'rm -f "$spec_file"' EXIT
aws_cli ec2 describe-instance-types \
  --region "$REGION" \
  --instance-types "$instance_type" \
  --query 'InstanceTypes[0].{VCpus:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB,NetworkPerformance:NetworkInfo.NetworkPerformance,PeakBandwidthInGbps:NetworkInfo.NetworkCards[0].PeakBandwidthInGbps,EnaSupport:NetworkInfo.EnaSupport,EfaSupported:NetworkInfo.EfaSupported}' \
  --output json > "$spec_file"

"$PYTHON_BIN" "$PROJECT_ROOT/scripts/save-clickhouse-comparison-run.py" \
  "$METRICS_FILE" \
  --label "$LABEL" \
  --instance-spec "$spec_file"
