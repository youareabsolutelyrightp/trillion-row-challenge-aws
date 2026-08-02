#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
export PATH="$PROJECT_ROOT/.tools/bin:$PATH"
REGION="${AWS_REGION:-us-east-1}"
TIMEOUT_SECONDS="${WAIT_CLUSTER_TIMEOUT_SECONDS:-1200}"

if [[ -x "$PROJECT_ROOT/.tools/bin/tofu" ]]; then
  IAC_CMD="${IAC_CMD:-$PROJECT_ROOT/.tools/bin/tofu}"
elif command -v tofu >/dev/null 2>&1; then
  IAC_CMD="${IAC_CMD:-tofu}"
else
  IAC_CMD="${IAC_CMD:-terraform}"
fi

wait_banner() {
  local message="$1"
  local line="WAITING: $message"
  echo
  printf '=%.0s' {1..80}
  echo
  printf '| %-76.76s |\n' "$line"
  printf '=%.0s' {1..80}
  echo
}

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

for command in aws "$IAC_CMD" jq base64; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ "$REGION" == "us-east-1" ]] || { echo "Refusing region $REGION." >&2; exit 1; }

instance_ids=()
while IFS= read -r instance_id; do
  instance_ids+=("$instance_id")
done < <("$IAC_CMD" -chdir="$ROOT_DIR" output -json instance_ids | jq -r '.[]')
leader="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw leader_instance_id)"
expected_count="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw instance_count)"
[[ "${#instance_ids[@]}" -eq "$expected_count" ]] || {
  echo "Expected $expected_count instances, got ${#instance_ids[@]}." >&2
  exit 1
}

wait_banner "EC2 status checks for ${instance_ids[*]}. Dots mean AWS is still initializing."
printf 'Checking EC2 instance and system status'
deadline=$((SECONDS + TIMEOUT_SECONDS))
last_notice=$SECONDS
ok_count=0
while (( SECONDS < deadline )); do
  ok_count="$(aws_cli ec2 describe-instance-status     --region "$REGION"     --include-all-instances     --instance-ids "${instance_ids[@]}"     --query 'length(InstanceStatuses[?InstanceStatus.Status==`ok` && SystemStatus.Status==`ok`])'     --output text 2>/dev/null || echo 0)"
  if [[ "$ok_count" == "$expected_count" ]]; then
    echo " OK ($ok_count/$expected_count)"
    break
  fi
  printf '.'
  if (( SECONDS - last_notice >= 60 )); then
    printf ' %s/%s OK after %ss
' "$ok_count" "$expected_count" "$SECONDS"
    printf 'Still waiting for EC2 status checks'
    last_notice=$SECONDS
  fi
  sleep 10
done
if [[ "$ok_count" != "$expected_count" ]]; then
  echo
  echo "EC2 status checks did not become OK before timeout." >&2
  aws_cli ec2 describe-instance-status --region "$REGION" --include-all-instances --instance-ids "${instance_ids[@]}" --output json >&2 || true
  exit 1
fi

wait_banner "SSM agent Online on all nodes. Dots mean SSM has not reported ready yet."
printf 'Checking SSM Online status'
deadline=$((SECONDS + TIMEOUT_SECONDS))
last_notice=$SECONDS
online_count=0
while (( SECONDS < deadline )); do
  online_count="$(aws_cli ssm describe-instance-information     --region "$REGION"     --filters "Key=InstanceIds,Values=$(IFS=,; echo "${instance_ids[*]}")"     --query 'length(InstanceInformationList[?PingStatus==`Online`])'     --output text 2>/dev/null || echo 0)"
  if [[ "$online_count" == "$expected_count" ]]; then
    echo " OK ($online_count/$expected_count)"
    break
  fi
  printf '.'
  if (( SECONDS - last_notice >= 60 )); then
    printf ' %s/%s online after %ss
' "$online_count" "$expected_count" "$SECONDS"
    printf 'Still waiting for SSM Online'
    last_notice=$SECONDS
  fi
  sleep 10
done
[[ "${online_count:-0}" == "$expected_count" ]] || { echo; echo "SSM did not become Online on all nodes." >&2; exit 1; }

wait_banner "ClickHouse bootstrap and cluster visibility from leader $leader."
sql="
SELECT count() AS hosts
FROM clusterAllReplicas('one_trc', 'system', 'one')
FORMAT TSV
"
sql_b64="$(printf '%s' "$sql" | base64 | tr -d '\n')"
remote_command="for i in \$(seq 1 180); do if test -f /var/lib/1trc-bootstrap-complete; then printf %s '$sql_b64' | base64 -d > /tmp/1trc-cluster-check.sql && hosts=\$(clickhouse-client < /tmp/1trc-cluster-check.sql 2>/tmp/1trc-cluster-check.err || true); if test "\$hosts" = '$expected_count'; then exit 0; fi; fi; sleep 5; done; tail -n 80 /var/log/1trc-bootstrap.log; cat /tmp/1trc-cluster-check.err 2>/dev/null; exit 1"
command_id="$(aws_cli ssm send-command   --region "$REGION"   --instance-ids "$leader"   --document-name AWS-RunShellScript   --comment "1TRC ClickHouse cluster readiness"   --parameters "$(jq -cn --arg c "$remote_command" '{commands:[$c], executionTimeout:["1200"]}')"   --timeout-seconds 1200   --query 'Command.CommandId'   --output text)"

printf 'Checking ClickHouse bootstrap via SSM command %s' "$command_id"
last_notice=$SECONDS
while true; do
  status="$(aws_cli ssm get-command-invocation --region "$REGION"     --command-id "$command_id" --instance-id "$leader" --query Status --output text 2>/dev/null || true)"
  case "$status" in
    Success)
      echo " OK"
      break
      ;;
    Pending|InProgress|Delayed|"")
      printf '.'
      if (( SECONDS - last_notice >= 60 )); then
        printf ' status=%s after %ss
' "${status:-Pending}" "$SECONDS"
        printf 'Still waiting for ClickHouse bootstrap'
        last_notice=$SECONDS
      fi
      sleep 5
      ;;
    *)
      echo
      aws_cli ssm get-command-invocation --region "$REGION"         --command-id "$command_id" --instance-id "$leader"         --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' --output json >&2
      exit 1
      ;;
  esac
done

echo "Cluster ready: $expected_count ClickHouse hosts visible."
