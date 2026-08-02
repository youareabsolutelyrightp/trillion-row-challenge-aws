#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_FILE="${CLICKHOUSE_RUN_CONFIG:-$ROOT_DIR/run-config.env}"
VENV_DIR="$PROJECT_ROOT/.tools/venv"
PYTHON_BIN="${PYTHON_BIN:-$VENV_DIR/bin/python}"
RUN_DIR="$ROOT_DIR/.run"
START_EPOCH="$(date +%s)"
DESTROYED=0
KEEP_ON_FAILURE=0
SKIP_INSTALL=0
AUTO_YES=0
CURRENT_STEP="startup"
LOG_FILE=""

usage() {
  cat <<USAGE
Usage: $0 [--yes] [--skip-install] [--keep-on-failure]

Examples:
  ./scripts/run-clickhouse-e2e.sh
  ./scripts/run-clickhouse-e2e.sh --yes

Edit $CONFIG_FILE to choose the AWS profile, instance shape, count, market type,
TTL, ClickHouse version, and query thread count.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

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
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION PYTHON_BIN

IAC_CMD=""
detect_iac_cmd() {
  if [[ -n "$USER_IAC_CMD" ]]; then
    IAC_CMD="$USER_IAC_CMD"
    return
  fi
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
LOG_FILE="$RUN_DIR/${MODE}-$(date -u +%Y%m%dT%H%M%SZ).log"

log_block() {
  local label="$1"
  local message="$2"
  local line="$label: $message"
  {
    echo
    printf '=%.0s' {1..80}
    echo
    printf '| %-76.76s |\n' "$line"
    printf '=%.0s' {1..80}
    echo
  } | tee -a "$LOG_FILE"
}

print_output_summary() {
  local metrics_file="${1:-}"
  local result_file=""
  if [[ -n "$metrics_file" && -f "$metrics_file" ]] && command -v jq >/dev/null 2>&1; then
    result_file="$(jq -r '.result_file // empty' "$metrics_file" 2>/dev/null || true)"
  fi

  log_block "OUTPUT FILES" "$MODE run artifacts"
  {
    echo "Run log:      $LOG_FILE"
    if [[ -n "$result_file" ]]; then
      echo "Result CSV:   $result_file"
    else
      echo "Result CSV:   not created"
    fi
    if [[ -n "$metrics_file" && -f "$metrics_file" ]]; then
      echo "Metrics JSON: $metrics_file"
    else
      echo "Metrics JSON: not created"
    fi
  } | tee -a "$LOG_FILE"
}

latest_file_after() {
  local directory="$1"
  local pattern="$2"
  local start_epoch="$3"
  if [[ ! -x "$PYTHON_BIN" ]]; then
    return 0
  fi
  "$PYTHON_BIN" - "$directory" "$pattern" "$start_epoch" <<'PYFIND'
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
pattern = sys.argv[2]
start_epoch = float(sys.argv[3])
if not directory.exists():
    raise SystemExit(0)
files = [p for p in directory.glob(pattern) if p.is_file() and p.stat().st_mtime >= start_epoch]
if files:
    print(max(files, key=lambda p: p.stat().st_mtime))
PYFIND
}

diagnose_log() {
  local log_file="$1"
  echo "Failure happened during: $CURRENT_STEP" >&2
  echo "Run log: $log_file" >&2

  if grep -Eqi 'AccessDenied|UnauthorizedOperation|not authorized' "$log_file"; then
    echo "Likely cause: the AWS profile lacks permission to create/read one of EC2, VPC, IAM, SSM, EventBridge Scheduler, or S3 resources." >&2
  fi
  if grep -Eqi 'No valid credential sources|NoCredentials|Unable to locate credentials|ExpiredToken|TLS handshake timeout|GetRoleCredentials' "$log_file"; then
    echo "Likely cause: AWS credentials are missing, expired, or SSO credential refresh timed out. Re-run AWS SSO login for profile '$AWS_PROFILE'." >&2
  fi
  if grep -Eqi 'MaxSpotInstanceCountExceeded|VcpuLimitExceeded|InstanceLimitExceeded' "$log_file"; then
    echo "Likely cause: EC2 vCPU quota is below this config. Lower FULL_INSTANCE_COUNT or request a quota increase." >&2
  fi
  if grep -Eqi 'InsufficientInstanceCapacity|capacity-oversubscribed|instance-terminated-no-capacity|SpotInstanceTermination' "$log_file"; then
    echo "Likely cause: AWS Spot capacity was unavailable or interrupted. Retry, reduce node count, change AZ, or use on-demand." >&2
  fi
  if grep -Eqi 'Requester Pays LIST failed|Requester Pays access failed|AccessDenied.*requester|requester.*AccessDenied' "$log_file"; then
    echo "Likely cause: S3 Requester Pays access failed. The script sends the requester header; confirm the profile can read coiled-datasets-rp/1trc." >&2
  fi
  if [[ "$CURRENT_STEP" == *"format"* ]] && grep -qx 'terraform.tfvars' "$log_file"; then
    echo "Likely cause: generated terraform.tfvars was not formatted before fmt -check. Re-run with the updated runner." >&2
  fi
  if grep -Eqi 'Mismatch between input and plan variable value' "$log_file"; then
    echo "Likely cause: terraform.tfvars changed after planning. Re-run this script so it regenerates tfvars and the saved plan together." >&2
  fi
}

run_logged() {
  CURRENT_STEP="$1"
  shift
  log_block "START" "$CURRENT_STEP"
  if ! "$@" 2>&1 | tee -a "$LOG_FILE"; then
    log_block "FAILED" "$CURRENT_STEP"
    diagnose_log "$LOG_FILE"
    exit 1
  fi
  log_block "DONE" "$CURRENT_STEP"
}

run_interactive() {
  CURRENT_STEP="$1"
  shift
  log_block "START" "$CURRENT_STEP"
  {
    echo "Interactive command output is attached directly to the terminal."
    echo "This avoids corrupting AWS CLI prompts by piping them through tee."
  } >> "$LOG_FILE"
  if ! "$@"; then
    log_block "FAILED" "$CURRENT_STEP"
    diagnose_log "$LOG_FILE"
    exit 1
  fi
  log_block "DONE" "$CURRENT_STEP"
}

destroy_infrastructure() {
  CURRENT_STEP="destroy infrastructure"
  log_block "START" "$CURRENT_STEP"

  if ! aws_cli sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS credentials unavailable before destroy; refreshing SSO login for profile '$AWS_PROFILE'." | tee -a "$LOG_FILE"
    aws sso login --profile "$AWS_PROFILE" || true
  fi

  local attempt
  for attempt in 1 2; do
    if "$IAC_CMD" destroy -auto-approve 2>&1 | tee -a "$LOG_FILE"; then
      DESTROYED=1
      log_block "DONE" "$CURRENT_STEP"
      return 0
    fi
    if [[ "$attempt" -lt 2 ]]; then
      echo "Destroy failed on attempt $attempt. Refreshing AWS SSO credentials and retrying once." | tee -a "$LOG_FILE"
      aws sso login --profile "$AWS_PROFILE" || true
      sleep 5
    fi
  done

  log_block "FAILED" "$CURRENT_STEP"
  diagnose_log "$LOG_FILE"
  echo "AUTOMATIC DESTROY FAILED. Run immediately:" >&2
  echo "  cd $ROOT_DIR && $IAC_CMD destroy -auto-approve" >&2
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  cd "$ROOT_DIR"

  if [[ "$status" -ne 0 && "$KEEP_ON_FAILURE" -eq 1 ]]; then
    echo "Run failed and --keep-on-failure was set. Infrastructure may still be running." >&2
    echo "Destroy manually when finished debugging: cd $ROOT_DIR && $IAC_CMD destroy -auto-approve" >&2
    exit "$status"
  fi

  state_file="/tmp/1trc-state-list.$$"
  if [[ "$DESTROYED" -eq 0 ]] && "$IAC_CMD" state list >"$state_file" 2>/dev/null && [[ -s "$state_file" ]]; then
    destroy_infrastructure || status=1
  fi
  rm -f "$state_file"

  teardown_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  metrics_file="$(latest_file_after "$PROJECT_ROOT/results" "clickhouse-${MODE}-*.json" "$START_EPOCH")"
  if [[ -n "$metrics_file" && -f "$metrics_file" ]]; then
    "$PYTHON_BIN" "$PROJECT_ROOT/scripts/finalize-clickhouse-run.py" \
      "$metrics_file" --teardown-time "$teardown_time" 2>&1 | tee -a "$LOG_FILE" || status=1
  fi
  print_output_summary "$metrics_file"

  exit "$status"
}
trap cleanup EXIT INT TERM

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1. Run $PROJECT_ROOT/scripts/bootstrap.sh first."
}

aws_cli() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
}

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

write_tfvars() {
  : > "$ROOT_DIR/terraform.tfvars"
  {
    tf_write_value aws_region "$AWS_REGION"
    tf_write_value aws_profile "$AWS_PROFILE"
    tf_write_value run_mode "$MODE"
    tf_write_value instance_type "$INSTANCE_TYPE"
    tf_write_value instance_count "$INSTANCE_COUNT"
    tf_write_value market_type "$MARKET_TYPE"
    tf_write_value max_runtime_minutes "$MAX_RUNTIME_MINUTES"
    tf_write_value root_volume_gib "$ROOT_VOLUME_GIB"
    tf_write_value clickhouse_version "$CLICKHOUSE_VERSION"
    tf_write_value spot_max_price "$SPOT_MAX_PRICE"
  } >> "$ROOT_DIR/terraform.tfvars"
}

write_tfvars_step() {
  write_tfvars
  echo "Wrote $ROOT_DIR/terraform.tfvars from $CONFIG_FILE for mode=$MODE."
}

ensure_aws_login() {
  [[ -n "$AWS_PROFILE" ]] || die "AWS_PROFILE is empty in $CONFIG_FILE."
  [[ "$AWS_REGION" == "us-east-1" ]] || die "AWS_REGION must be us-east-1 to avoid cross-region S3 transfer charges."

  if aws_cli sts get-caller-identity >/dev/null 2>&1; then
    return
  fi

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

preflight_identity_and_permissions() {
  identity_json="$(aws_cli sts get-caller-identity)"
  identity_arn="$(jq -r '.Arn' <<<"$identity_json")"
  account_id="$(jq -r '.Account' <<<"$identity_json")"
  echo "Using AWS identity: $identity_arn"
  [[ "$identity_arn" != arn:aws:iam::*:root ]] || die "Refusing AWS account root credentials. Use IAM Identity Center or an assumed IAM role."

  aws_cli ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" >/tmp/1trc-instance-type.json
  vcpus_per_instance="$(jq -r '.InstanceTypes[0].VCpuInfo.DefaultVCpus' /tmp/1trc-instance-type.json)"
  [[ "$vcpus_per_instance" =~ ^[0-9]+$ ]] || die "Could not determine vCPU count for $INSTANCE_TYPE."
  required_vcpus=$((vcpus_per_instance * INSTANCE_COUNT))
  echo "Planned EC2 shape: $INSTANCE_COUNT x $INSTANCE_TYPE = $required_vcpus vCPUs, market_type=$MARKET_TYPE"

  quota_json="$(aws_cli service-quotas list-service-quotas --service-code ec2 --output json || true)"
  if [[ -n "$quota_json" ]]; then
    if [[ "$MARKET_TYPE" == "spot" ]]; then
      quota_filter='(.QuotaName | test("Standard")) and (.QuotaName | test("Spot"))'
      quota_label="Standard Spot vCPU"
    else
      quota_filter='(.QuotaName | test("Running On-Demand Standard"))'
      quota_label="Running On-Demand Standard vCPU"
    fi
    quota_value="$(jq -r ".Quotas[] | select($quota_filter) | .Value" <<<"$quota_json" | head -n 1)"
    quota_code="$(jq -r ".Quotas[] | select($quota_filter) | .QuotaCode" <<<"$quota_json" | head -n 1)"
    if [[ -n "$quota_value" && "$quota_value" != "null" ]]; then
      awk -v quota="$quota_value" -v required="$required_vcpus" 'BEGIN { exit !(quota + 0 >= required + 0) }' || {
        die "$quota_label quota is $quota_value vCPUs, but this run needs $required_vcpus. Request an increase for quota $quota_code or reduce instance count."
      }
      echo "$quota_label quota OK: $quota_value >= $required_vcpus"
    else
      echo "Warning: could not find $quota_label quota automatically; continuing because Terraform will still enforce actual AWS limits."
    fi
  else
    echo "Warning: service-quotas list-service-quotas failed; continuing because Terraform will still enforce actual AWS limits."
  fi

  aws_cli s3api head-object --bucket coiled-datasets-rp --key 1trc/measurements-0.parquet --request-payer requester >/dev/null
  aws_cli s3api head-object --bucket coiled-datasets-rp --key 1trc/measurements-99999.parquet --request-payer requester >/dev/null

  echo "AWS preflight passed for account $account_id."
}

confirm_full_run() {
  if [[ "$AUTO_YES" -eq 1 ]]; then
    return 0
  fi

  cat <<WARNING

This will run a full 1TRC scan against requester-pays S3:
  mode:        full
  shape:       $INSTANCE_COUNT x $INSTANCE_TYPE
  market:      $MARKET_TYPE
  max runtime: $MAX_RUNTIME_MINUTES minutes

The script destroys infrastructure on exit and also creates an AWS Scheduler
termination fuse, but this is still billable AWS work. Type FULL to continue.
WARNING
  read -r answer
  [[ "$answer" == "FULL" ]] || die "Full run cancelled."
}

guard_plan() {
  local plan_file="$1"
  local plan_json="$RUN_DIR/${MODE}-plan.json"
  "$IAC_CMD" -chdir="$ROOT_DIR" show -json "$plan_file" > "$plan_json"

  local nat_count endpoint_count endpoint_type instance_creates scheduler_creates root_bad
  nat_count="$(jq '[.resource_changes[]? | select(.type == "aws_nat_gateway")] | length' "$plan_json")"
  endpoint_count="$(jq '[.resource_changes[]? | select(.type == "aws_vpc_endpoint" and (.change.actions | index("create")))] | length' "$plan_json")"
  endpoint_type="$(jq -r '[.resource_changes[]? | select(.type == "aws_vpc_endpoint") | .change.after.vpc_endpoint_type][0] // ""' "$plan_json")"
  instance_creates="$(jq '[.resource_changes[]? | select(.type == "aws_instance" and (.change.actions | index("create")))] | length' "$plan_json")"
  scheduler_creates="$(jq '[.resource_changes[]? | select(.type == "aws_scheduler_schedule" and (.change.actions | index("create")))] | length' "$plan_json")"
  root_bad="$(jq '[.resource_changes[]? | select(.type == "aws_instance") | select((.change.after.root_block_device[0].encrypted != true) or (.change.after.root_block_device[0].delete_on_termination != true))] | length' "$plan_json")"

  [[ "$nat_count" == 0 ]] || die "Plan contains an aws_nat_gateway. That would create avoidable hourly/NAT data charges."
  [[ "$endpoint_count" == 1 && "$endpoint_type" == "Gateway" ]] || die "Plan must create exactly one S3 Gateway VPC endpoint."
  [[ "$instance_creates" == "$INSTANCE_COUNT" ]] || die "Plan creates $instance_creates instances, expected $INSTANCE_COUNT."
  [[ "$scheduler_creates" == "$INSTANCE_COUNT" ]] || die "Plan creates $scheduler_creates termination schedules, expected $INSTANCE_COUNT."
  [[ "$root_bad" == 0 ]] || die "Plan has a root volume that is not encrypted or not delete-on-termination."

  echo "Plan guardrails passed: no NAT, S3 Gateway endpoint present, encrypted delete-on-termination roots, TTL schedules present."
}

select_mode_config() {
  INSTANCE_TYPE="${FULL_INSTANCE_TYPE:-c7g.2xlarge}"
  INSTANCE_COUNT="${FULL_INSTANCE_COUNT:-12}"
  MARKET_TYPE="${FULL_MARKET_TYPE:-spot}"
  MAX_RUNTIME_MINUTES="${FULL_MAX_RUNTIME_MINUTES:-45}"
  ROOT_VOLUME_GIB="${FULL_ROOT_VOLUME_GIB:-30}"
  MAX_THREADS="${FULL_MAX_THREADS:-128}"
  SPOT_MAX_PRICE="${FULL_SPOT_MAX_PRICE:-}"

  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ && "$INSTANCE_COUNT" -ge 1 ]] || die "instance count must be a positive integer."
  [[ "$MARKET_TYPE" == "spot" || "$MARKET_TYPE" == "on-demand" ]] || die "market type must be spot or on-demand."
}

select_mode_config

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  run_logged "install or reuse local requirements" "$PROJECT_ROOT/scripts/bootstrap.sh"
  detect_iac_cmd
fi

for command in aws "$IAC_CMD" jq gzip base64; do
  require_tool "$command"
done
[[ -x "$PYTHON_BIN" ]] || die "Missing project Python venv: $PYTHON_BIN. Run $PROJECT_ROOT/scripts/bootstrap.sh or remove --skip-install."

run_interactive "ensure AWS login" ensure_aws_login
run_logged "preflight AWS identity, quota, and region" preflight_identity_and_permissions
run_logged "confirm billable full run" confirm_full_run

if "$IAC_CMD" -chdir="$ROOT_DIR" state list 2>/dev/null | grep -q .; then
  die "OpenTofu state is not empty. Run destroy or inspect state before starting a new end-to-end run."
fi

run_logged "write generated OpenTofu variables" write_tfvars_step
run_logged "format generated OpenTofu variables" "$IAC_CMD" -chdir="$ROOT_DIR" fmt terraform.tfvars

plan_file="$RUN_DIR/${MODE}.tfplan"
run_logged "initialize OpenTofu" "$IAC_CMD" -chdir="$ROOT_DIR" init
run_logged "format check Terraform/OpenTofu files" "$IAC_CMD" -chdir="$ROOT_DIR" fmt -check -recursive
run_logged "validate OpenTofu configuration" "$IAC_CMD" -chdir="$ROOT_DIR" validate
run_logged "create saved OpenTofu plan" "$IAC_CMD" -chdir="$ROOT_DIR" plan -out="$plan_file"
CURRENT_STEP="verify saved plan cost guardrails"
guard_plan "$plan_file"
run_logged "apply saved OpenTofu plan" "$IAC_CMD" -chdir="$ROOT_DIR" apply "$plan_file"
run_logged "wait for EC2, SSM, and ClickHouse readiness" "$SCRIPT_DIR/wait-cluster-ready.sh"
run_logged "run ClickHouse full query" "$SCRIPT_DIR/run-query.sh" --max-threads "$MAX_THREADS"

latest_metrics="$(latest_file_after "$PROJECT_ROOT/results" 'clickhouse-full-*.json' "$START_EPOCH")"
if [[ -n "$latest_metrics" ]]; then
  label="${INSTANCE_COUNT}x${INSTANCE_TYPE}-${MARKET_TYPE}-threads${MAX_THREADS}"
  run_logged "save full-run comparison row" "$SCRIPT_DIR/save-comparison-run.sh" --label "$label" --metrics "$latest_metrics"
fi

log_block "DONE" "full query completed; automatic destroy will run now"
