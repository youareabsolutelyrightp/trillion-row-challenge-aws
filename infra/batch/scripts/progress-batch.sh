#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BATCH_RUN_CONFIG:-$ROOT_DIR/run-config.env}"
WATCH=0
INTERVAL=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--watch] [--interval SECONDS]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

source "$CONFIG_FILE"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE is required}"
RUN_FILE="$ROOT_DIR/.run/current-run.json"
[[ -f "$RUN_FILE" ]] || { echo "No current run file: $RUN_FILE" >&2; exit 1; }

render_once() {
  local worker_job_id reducer_job_id run_id
  worker_job_id="$(jq -r '.worker_job_id' "$RUN_FILE")"
  reducer_job_id="$(jq -r '.reducer_job_id' "$RUN_FILE")"
  run_id="$(jq -r '.run_id' "$RUN_FILE")"
  echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) run_id=$run_id ---"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" batch describe-jobs --jobs "$worker_job_id" "$reducer_job_id" \
    | jq -r '.jobs[] | [.jobName, .jobId, .status, (.arrayProperties.statusSummary // {} | tostring), (.startedAt // 0), (.stoppedAt // 0), (.statusReason // "")] | @tsv'
}

if [[ "$WATCH" -eq 1 ]]; then
  while true; do
    render_once
    sleep "$INTERVAL"
  done
else
  render_once
fi
