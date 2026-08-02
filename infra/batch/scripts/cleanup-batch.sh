#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${BATCH_RUN_CONFIG:-$ROOT_DIR/run-config.env}"
source "$CONFIG_FILE"
AWS_PROFILE="${AWS_PROFILE:-1trc}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

if command -v tofu >/dev/null 2>&1; then
  IAC_CMD="tofu"
elif [[ -x "$ROOT_DIR/../../.tools/bin/tofu" ]]; then
  IAC_CMD="$ROOT_DIR/../../.tools/bin/tofu"
else
  echo "OpenTofu not found. Run $ROOT_DIR/../../scripts/bootstrap.sh --batch, then retry cleanup." >&2
  exit 1
fi

ensure_aws_login() {
  if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi
  echo "AWS credentials unavailable; refreshing SSO login for profile '$AWS_PROFILE'." >&2
  aws sso login --profile "$AWS_PROFILE" || true
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity >/dev/null
}

terminate_recorded_jobs() {
  [[ -f "$ROOT_DIR/.run/current-run.json" ]] || return 0
  worker_job_id="$(jq -r '.worker_job_id // empty' "$ROOT_DIR/.run/current-run.json")"
  reducer_job_id="$(jq -r '.reducer_job_id // empty' "$ROOT_DIR/.run/current-run.json")"
  for job_id in "$worker_job_id" "$reducer_job_id"; do
    if [[ -n "$job_id" ]]; then
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" batch terminate-job \
        --job-id "$job_id" \
        --reason "manual cleanup" >/dev/null 2>&1 || true
    fi
  done
}

run_destroy() {
  local attempt
  for attempt in 1 2 3; do
    ensure_aws_login || true
    if "$IAC_CMD" -chdir="$ROOT_DIR" destroy -auto-approve; then
      return 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
      echo "Destroy failed on attempt $attempt. Retrying after AWS credential refresh." >&2
      aws sso login --profile "$AWS_PROFILE" || true
      sleep 5
    fi
  done
  return 1
}

ensure_aws_login
terminate_recorded_jobs
run_destroy
