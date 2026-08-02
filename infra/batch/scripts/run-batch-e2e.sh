#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_FILE="${BATCH_RUN_CONFIG:-$ROOT_DIR/run-config.env}"
RUN_DIR="$ROOT_DIR/.run"
START_EPOCH="$(date +%s)"
AUTO_YES=0
SKIP_INSTALL=0
KEEP_ON_FAILURE=0
DESTROYED=0
CURRENT_STEP="startup"
LOG_FILE=""

usage() {
  cat <<USAGE
Usage: $0 [--yes] [--skip-install] [--keep-on-failure]

Examples:
  ./scripts/run-batch-e2e.sh
  ./scripts/run-batch-e2e.sh --yes
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
MODE="full"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) AUTO_YES=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -f "$CONFIG_FILE" ]] || die "Missing config file: $CONFIG_FILE"
source "$CONFIG_FILE"

export PATH="$PROJECT_ROOT/.tools/bin:$PATH"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_DEFAULT_REGION="$AWS_REGION"
USER_IAC_CMD="${IAC_CMD:-}"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION
IAC_CMD=""

detect_iac_cmd() {
  if [[ -n "$USER_IAC_CMD" ]]; then IAC_CMD="$USER_IAC_CMD"; return; fi
  if [[ -x "$PROJECT_ROOT/.tools/bin/tofu" ]] && "$PROJECT_ROOT/.tools/bin/tofu" version >/dev/null 2>&1; then
    IAC_CMD="$PROJECT_ROOT/.tools/bin/tofu"
  elif command -v tofu >/dev/null 2>&1; then
    IAC_CMD="tofu"
  else
    IAC_CMD="terraform"
  fi
}

detect_iac_cmd
mkdir -p "$RUN_DIR" "$PROJECT_ROOT/results"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
IMAGE_TAG="$RUN_ID"
LOG_FILE="$RUN_DIR/${MODE}-${RUN_ID}.log"
STEP_TIMINGS_FILE="$RUN_DIR/${MODE}-${RUN_ID}-steps.tsv"
printf '%s\t%s\t%s\t%s\n' step start_epoch end_epoch duration_seconds > "$STEP_TIMINGS_FILE"
export MODE RUN_ID IMAGE_TAG IAC_CMD

log_block() {
  local label="$1"
  local message="$2"
  local line="$label: $message"
  {
    echo
    printf '=%.0s' {1..80}; echo
    printf '| %-76.76s |\n' "$line"
    printf '=%.0s' {1..80}; echo
  } | tee -a "$LOG_FILE"
}

record_step_timing() {
  local step="$1" start_epoch="$2" end_epoch="$3" duration
  duration=$((end_epoch - start_epoch))
  printf '%s\t%s\t%s\t%s\n' "$step" "$start_epoch" "$end_epoch" "$duration" >> "$STEP_TIMINGS_FILE"
  echo "Step duration: ${duration}s" | tee -a "$LOG_FILE"
}

run_logged() {
  CURRENT_STEP="$1"; shift
  local start_epoch end_epoch
  start_epoch="$(date +%s)"
  log_block "START" "$CURRENT_STEP"
  if ! "$@" 2>&1 | tee -a "$LOG_FILE"; then
    end_epoch="$(date +%s)"
    record_step_timing "$CURRENT_STEP" "$start_epoch" "$end_epoch"
    log_block "FAILED" "$CURRENT_STEP"
    diagnose_log
    exit 1
  fi
  end_epoch="$(date +%s)"
  record_step_timing "$CURRENT_STEP" "$start_epoch" "$end_epoch"
  log_block "DONE" "$CURRENT_STEP"
}

run_interactive() {
  CURRENT_STEP="$1"; shift
  local start_epoch end_epoch
  start_epoch="$(date +%s)"
  log_block "START" "$CURRENT_STEP"
  echo "Interactive command output is attached directly to the terminal." >> "$LOG_FILE"
  if ! "$@"; then
    end_epoch="$(date +%s)"
    record_step_timing "$CURRENT_STEP" "$start_epoch" "$end_epoch"
    log_block "FAILED" "$CURRENT_STEP"
    diagnose_log
    exit 1
  fi
  end_epoch="$(date +%s)"
  record_step_timing "$CURRENT_STEP" "$start_epoch" "$end_epoch"
  log_block "DONE" "$CURRENT_STEP"
}

diagnose_log() {
  echo "Failure happened during: $CURRENT_STEP" >&2
  echo "Run log: $LOG_FILE" >&2
  if grep -Eqi 'AccessDenied|UnauthorizedOperation|not authorized' "$LOG_FILE"; then
    echo "Likely cause: the AWS profile lacks permission for Batch, EC2, VPC, IAM, ECR, S3, or CloudWatch Logs." >&2
  fi
  if grep -Eqi 'NoCredentials|Unable to locate credentials|ExpiredToken' "$LOG_FILE"; then
    echo "Likely cause: AWS credentials are missing or expired. Re-run AWS SSO login for profile '$AWS_PROFILE'." >&2
  fi
  if grep -Eqi 'MaxSpotInstanceCountExceeded|VcpuLimitExceeded|InstanceLimitExceeded' "$LOG_FILE"; then
    echo "Likely cause: EC2 Spot vCPU quota is below this config. Lower FULL_MAX_VCPUS or request a quota increase." >&2
  fi
  if grep -Eqi 'CannotPullContainerError|pull image' "$LOG_FILE"; then
    echo "Likely cause: Batch could not pull the ECR image. Check build-and-push-image and ECR permissions." >&2
  fi
  if grep -Eqi 'NAT Gateway|aws_nat_gateway' "$LOG_FILE"; then
    echo "Plan guard caught a NAT Gateway. Do not proceed; this design must avoid NAT costs." >&2
  fi
  if grep -Eqi 'list of string required|var.instance_types' "$LOG_FILE"; then
    echo "Likely cause: generated terraform.tfvars wrote instance_types incorrectly. Pull the latest runner and retry." >&2
  fi
}

require_tool() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

tf_write_value() {
  local key="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    printf '%s = null\n' "$key"
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s = %s\n' "$key" "$value"
  else
    printf '%s = "%s"\n' "$key" "$value"
  fi
}

tf_write_string_list() {
  local key="$1"
  local value="$2"
  printf '%s = [%s]\n' "$key" "$(awk -v s="$value" 'BEGIN{n=split(s,a,","); for(i=1;i<=n;i++){gsub(/^ +| +$/,"",a[i]); if(a[i] != "") printf "%s\"%s\"", (printed++ ? ", " : ""), a[i]}}')"
}

select_mode_config() {
  INSTANCE_TYPES="${FULL_INSTANCE_TYPES:-c7g.4xlarge}"
  MAX_VCPUS="${FULL_MAX_VCPUS:-96}"
  ARRAY_SIZE="${FULL_ARRAY_SIZE:-120}"
  FILE_COUNT="${FULL_FILE_COUNT:-100000}"
  WORKER_VCPUS="${FULL_WORKER_VCPUS:-4}"
  WORKER_MEMORY_MIB="${FULL_WORKER_MEMORY_MIB:-4096}"
  WORKER_FILE_CONCURRENCY="${FULL_WORKER_FILE_CONCURRENCY:-12}"
  WORKER_TIMEOUT_SECONDS="${FULL_WORKER_TIMEOUT_SECONDS:-3600}"
  REDUCER_VCPUS="${FULL_REDUCER_VCPUS:-2}"
  REDUCER_MEMORY_MIB="${FULL_REDUCER_MEMORY_MIB:-4096}"
  REDUCER_TIMEOUT_SECONDS="${FULL_REDUCER_TIMEOUT_SECONDS:-900}"
  [[ "$AWS_REGION" == "us-east-1" ]] || die "AWS_REGION must be us-east-1 to avoid cross-region S3 transfer charges."
}

write_tfvars() {
  : > "$ROOT_DIR/terraform.tfvars"
  {
    tf_write_value aws_region "$AWS_REGION"
    tf_write_value aws_profile "$AWS_PROFILE"
    tf_write_value run_mode "$MODE"
    tf_write_string_list instance_types "$INSTANCE_TYPES"
    tf_write_value max_vcpus "$MAX_VCPUS"
    tf_write_value array_size "$ARRAY_SIZE"
    tf_write_value file_count "$FILE_COUNT"
    tf_write_value worker_vcpus "$WORKER_VCPUS"
    tf_write_value worker_memory_mib "$WORKER_MEMORY_MIB"
    tf_write_value worker_file_concurrency "$WORKER_FILE_CONCURRENCY"
    tf_write_value worker_timeout_seconds "$WORKER_TIMEOUT_SECONDS"
    tf_write_value reducer_vcpus "$REDUCER_VCPUS"
    tf_write_value reducer_memory_mib "$REDUCER_MEMORY_MIB"
    tf_write_value reducer_timeout_seconds "$REDUCER_TIMEOUT_SECONDS"
    tf_write_value image_tag "$IMAGE_TAG"
  } >> "$ROOT_DIR/terraform.tfvars"
  echo "Wrote $ROOT_DIR/terraform.tfvars from $CONFIG_FILE for mode=$MODE."
}

ensure_aws_login() {
  [[ -n "$AWS_PROFILE" ]] || die "AWS_PROFILE is empty in $CONFIG_FILE."
  if aws_cli sts get-caller-identity >/dev/null 2>&1; then return; fi
  echo "AWS profile '$AWS_PROFILE' is not logged in or is not configured."
  if ! aws configure list-profiles | grep -Fxq "$AWS_PROFILE"; then
    if [[ -t 0 ]]; then
      echo "Opening interactive AWS SSO profile setup for '$AWS_PROFILE'."
      aws configure sso --profile "$AWS_PROFILE"
    else
      die "Profile '$AWS_PROFILE' does not exist. Run: aws configure sso --profile $AWS_PROFILE"
    fi
  fi
  echo "Opening AWS SSO login for '$AWS_PROFILE'."
  aws sso login --profile "$AWS_PROFILE" || true
  aws_cli sts get-caller-identity >/dev/null || die "AWS login failed for profile '$AWS_PROFILE'."
}

preflight() {
  identity_json="$(aws_cli sts get-caller-identity)"
  identity_arn="$(jq -r '.Arn' <<<"$identity_json")"
  account_id="$(jq -r '.Account' <<<"$identity_json")"
  echo "Using AWS identity: $identity_arn"
  [[ "$identity_arn" != arn:aws:iam::*:root ]] || die "Refusing AWS account root credentials."
  echo "Planned Batch shape: instance_types=[$INSTANCE_TYPES], max_vcpus=$MAX_VCPUS, array_size=$ARRAY_SIZE, worker=${WORKER_VCPUS}vCPU/${WORKER_MEMORY_MIB}MiB, file_concurrency=${WORKER_FILE_CONCURRENCY}"

  quota_json="$(aws_cli service-quotas list-service-quotas --service-code ec2 --output json || true)"
  if [[ -n "$quota_json" ]]; then
    quota_value="$(jq -r '.Quotas[] | select((.QuotaName | test("Standard")) and (.QuotaName | test("Spot"))) | .Value' <<<"$quota_json" | head -n 1)"
    if [[ -n "$quota_value" && "$quota_value" != "null" ]]; then
      awk -v quota="$quota_value" -v required="$MAX_VCPUS" 'BEGIN { exit !(quota + 0 >= required + 0) }' \
        || die "Standard Spot vCPU quota is $quota_value but this run needs $MAX_VCPUS."
      echo "Standard Spot vCPU quota OK: $quota_value >= $MAX_VCPUS"
    fi
  fi

  aws_cli s3api head-object --bucket coiled-datasets-rp --key 1trc/measurements-0.parquet --request-payer requester >/dev/null
  aws_cli s3api head-object --bucket coiled-datasets-rp --key 1trc/measurements-99999.parquet --request-payer requester >/dev/null
  echo "Requester Pays S3 preflight passed for account $account_id."
}

confirm_full_run() {
  [[ "$AUTO_YES" -eq 1 ]] && return 0
  cat <<WARNING

This will run a full 1TRC AWS Batch scan against requester-pays S3:
  shape:       [$INSTANCE_TYPES], max_vcpus=$MAX_VCPUS
  workers:     $ARRAY_SIZE shards, $WORKER_VCPUS vCPU each, file_concurrency=$WORKER_FILE_CONCURRENCY
  files:       $FILE_COUNT Parquet files

The script destroys infrastructure on exit, but this is still billable AWS work.
Type FULL to continue.
WARNING
  read -r answer
  [[ "$answer" == "FULL" ]] || die "Full run cancelled."
}

guard_plan() {
  local plan_file="$1" plan_json="$RUN_DIR/${MODE}-plan.json"
  "$IAC_CMD" -chdir="$ROOT_DIR" show -json "$plan_file" > "$plan_json"
  nat_count="$(jq '[.resource_changes[]? | select(.type == "aws_nat_gateway")] | length' "$plan_json")"
  endpoint_count="$(jq '[.resource_changes[]? | select(.type == "aws_vpc_endpoint" and (.change.actions | index("create")))] | length' "$plan_json")"
  endpoint_type="$(jq -r '[.resource_changes[]? | select(.type == "aws_vpc_endpoint") | .change.after.vpc_endpoint_type][0] // ""' "$plan_json")"
  max_vcpus_after="$(jq -r '[.resource_changes[]? | select(.type == "aws_batch_compute_environment") | .change.after.compute_resources[0].max_vcpus][0] // 0' "$plan_json")"
  force_delete_ecr="$(jq -r '[.resource_changes[]? | select(.type == "aws_ecr_repository") | .change.after.force_delete][0] // false' "$plan_json")"
  [[ "$nat_count" == 0 ]] || die "Plan contains an aws_nat_gateway. That would create avoidable NAT charges."
  [[ "$endpoint_count" == 1 && "$endpoint_type" == "Gateway" ]] || die "Plan must create exactly one S3 Gateway VPC endpoint."
  [[ "$max_vcpus_after" -le "$MAX_VCPUS" ]] || die "Plan max_vcpus $max_vcpus_after exceeds configured $MAX_VCPUS."
  [[ "$force_delete_ecr" == "true" ]] || die "ECR repository must be force_delete=true for cleanup."
  echo "Plan guardrails passed: no NAT, S3 Gateway endpoint, bounded Batch max_vcpus, disposable ECR."
}

wait_for_reducer() {
  local reducer_job_id status reason
  reducer_job_id="$(jq -r '.reducer_job_id' "$ROOT_DIR/.run/current-run.json")"
  while true; do
    status="$(aws_cli batch describe-jobs --jobs "$reducer_job_id" | jq -r '.jobs[0].status')"
    reason="$(aws_cli batch describe-jobs --jobs "$reducer_job_id" | jq -r '.jobs[0].statusReason // ""')"
    printf 'Reducer status: %s %s\n' "$status" "$reason"
    case "$status" in
      SUCCEEDED) return 0 ;;
      FAILED) return 1 ;;
    esac
    sleep 30
  done
}

validate_local_result() {
  "$SCRIPT_DIR/fetch-results.sh"
  result_file="$(ls -t "$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}.csv" | head -n 1)"
  metrics_file="$(ls -t "$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}.json" | head -n 1)"
  python3 "$PROJECT_ROOT/scripts/validate-batch-results.py" --csv "$result_file" --metrics "$metrics_file"
}

finalize_batch_artifacts() {
  local teardown_start_epoch="$1" teardown_end_epoch="$2"
  local metrics_json="$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}.json"
  local placement_summary="$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}-aws-placement-summary.json"
  if [[ ! -f "$metrics_json" || ! -f "$placement_summary" ]]; then
    return 0
  fi
  python3 "$PROJECT_ROOT/scripts/finalize-batch-run.py" \
    "$metrics_json" \
    "$placement_summary" \
    --runner-start-epoch "$START_EPOCH" \
    --teardown-start-epoch "$teardown_start_epoch" \
    --teardown-end-epoch "$teardown_end_epoch"
}

destroy_infrastructure() {
  CURRENT_STEP="destroy Batch infrastructure"
  local teardown_start_epoch teardown_end_epoch
  log_block "START" "$CURRENT_STEP"

  if ! aws_cli sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS credentials unavailable before destroy; refreshing SSO login for profile '$AWS_PROFILE'." | tee -a "$LOG_FILE"
    aws sso login --profile "$AWS_PROFILE" || true
  fi

  teardown_start_epoch="$(date +%s)"
  local attempt
  for attempt in 1 2; do
    if "$IAC_CMD" -chdir="$ROOT_DIR" destroy -auto-approve 2>&1 | tee -a "$LOG_FILE"; then
      teardown_end_epoch="$(date +%s)"
      record_step_timing "$CURRENT_STEP" "$teardown_start_epoch" "$teardown_end_epoch"
      DESTROYED=1
      if ! finalize_batch_artifacts "$teardown_start_epoch" "$teardown_end_epoch" 2>&1 | tee -a "$LOG_FILE"; then
        log_block "FAILED" "finalize Batch lifecycle metrics"
        return 1
      fi
      log_block "DONE" "$CURRENT_STEP"
      return 0
    fi
    if [[ "$attempt" -lt 2 ]]; then
      echo "Destroy failed on attempt $attempt. Refreshing AWS SSO credentials and retrying once." | tee -a "$LOG_FILE"
      aws sso login --profile "$AWS_PROFILE" || true
      sleep 5
    fi
  done

  teardown_end_epoch="$(date +%s)"
  record_step_timing "$CURRENT_STEP" "$teardown_start_epoch" "$teardown_end_epoch"
  log_block "FAILED" "$CURRENT_STEP"
  diagnose_log
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  cd "$ROOT_DIR"
  if [[ "$status" -ne 0 && "$KEEP_ON_FAILURE" -eq 1 ]]; then
    echo "Run failed and --keep-on-failure was set. Infrastructure may still be running." >&2
    exit "$status"
  fi
  if [[ "$DESTROYED" -eq 0 ]] && "$IAC_CMD" -chdir="$ROOT_DIR" state list >/tmp/1trc-batch-state.$$ 2>/dev/null && [[ -s /tmp/1trc-batch-state.$$ ]]; then
    destroy_infrastructure || status=1
  fi
  rm -f /tmp/1trc-batch-state.$$
  local result_csv="$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}.csv"
  local metrics_json="$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}.json"
  local placement_json="$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}-aws-placement.json"
  local placement_summary="$PROJECT_ROOT/results/batch-${MODE}-${RUN_ID}-aws-placement-summary.json"
  log_block "OUTPUT FILES" "$MODE run artifacts"
  echo "Run log:      $LOG_FILE" | tee -a "$LOG_FILE"
  if [[ -f "$result_csv" ]]; then
    echo "Result CSV:   $result_csv" | tee -a "$LOG_FILE"
  else
    echo "Result CSV:   not created" | tee -a "$LOG_FILE"
  fi
  if [[ -f "$metrics_json" ]]; then
    echo "Metrics JSON: $metrics_json" | tee -a "$LOG_FILE"
  else
    echo "Metrics JSON: not created" | tee -a "$LOG_FILE"
  fi
  if [[ -f "$placement_summary" ]]; then
    echo "AWS placement summary: $placement_summary" | tee -a "$LOG_FILE"
  else
    echo "AWS placement summary: not created" | tee -a "$LOG_FILE"
  fi
  if [[ -f "$placement_json" ]]; then
    echo "AWS placement detail:  $placement_json" | tee -a "$LOG_FILE"
  else
    echo "AWS placement detail:  not created" | tee -a "$LOG_FILE"
  fi
  echo "Step timings: $STEP_TIMINGS_FILE" | tee -a "$LOG_FILE"
  exit "$status"
}
trap cleanup EXIT INT TERM

select_mode_config
if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  run_logged "install or reuse local requirements" "$PROJECT_ROOT/scripts/bootstrap.sh" --batch
  detect_iac_cmd
fi
for command in aws "$IAC_CMD" jq docker; do require_tool "$command"; done

run_interactive "ensure AWS login" ensure_aws_login
run_logged "preflight AWS identity, quota, and requester-pays access" preflight
run_logged "confirm billable full run" confirm_full_run
if "$IAC_CMD" -chdir="$ROOT_DIR" state list 2>/dev/null | grep -q .; then
  die "OpenTofu state is not empty. Run ./scripts/cleanup-batch.sh or inspect state before starting."
fi
run_logged "write generated OpenTofu variables" write_tfvars
run_logged "initialize OpenTofu" "$IAC_CMD" -chdir="$ROOT_DIR" init
run_logged "format generated OpenTofu variables" "$IAC_CMD" -chdir="$ROOT_DIR" fmt terraform.tfvars
run_logged "format check Terraform/OpenTofu files" "$IAC_CMD" -chdir="$ROOT_DIR" fmt -check -recursive
run_logged "validate OpenTofu configuration" "$IAC_CMD" -chdir="$ROOT_DIR" validate
plan_file="$RUN_DIR/${MODE}.tfplan"
run_logged "create saved OpenTofu plan" "$IAC_CMD" -chdir="$ROOT_DIR" plan -out="$plan_file"
CURRENT_STEP="verify saved plan cost guardrails"
guard_plan "$plan_file"
run_logged "apply saved OpenTofu plan" "$IAC_CMD" -chdir="$ROOT_DIR" apply "$plan_file"
run_logged "build and push ARM64 Batch image" "$SCRIPT_DIR/build-and-push-image.sh"
run_logged "submit worker array and reducer jobs" "$SCRIPT_DIR/submit-run.sh"
run_logged "wait for reducer job" wait_for_reducer
run_logged "capture AWS Batch placement and job timing" "$SCRIPT_DIR/capture-batch-metadata.sh"
run_logged "fetch and validate Batch result" validate_local_result
log_block "DONE" "$MODE Batch run completed; automatic destroy will run now"
