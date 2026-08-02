#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
export PATH="$PROJECT_ROOT/.tools/bin:$PATH"
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
INTERVAL=15
WATCH=0
KILL=0
QUERY_ID=""

if [[ -x "$PROJECT_ROOT/.tools/bin/tofu" ]]; then
  IAC_CMD="${IAC_CMD:-$PROJECT_ROOT/.tools/bin/tofu}"
elif command -v tofu >/dev/null 2>&1; then
  IAC_CMD="${IAC_CMD:-tofu}"
else
  IAC_CMD="${IAC_CMD:-terraform}"
fi

usage() {
  cat <<USAGE
Usage: $0 [--watch] [--interval SECONDS] [--query-id QUERY_ID] [--kill]

Shows live ClickHouse query progress through SSM. Use --kill only when you have
confirmed the query is stuck or you intend to abort the billable run.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --query-id) QUERY_ID="$2"; shift 2 ;;
    --kill) KILL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for command in aws "$IAC_CMD" jq; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done

configure_aws_cli
[[ "$REGION" == "us-east-1" ]] || { echo "Refusing region $REGION." >&2; exit 1; }
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 5 ]] || { echo "Interval must be an integer >= 5." >&2; exit 1; }

leader="$($IAC_CMD -chdir="$ROOT_DIR" output -raw leader_instance_id)"

if [[ -z "$QUERY_ID" && -f "$ROOT_DIR/.run/current-query-id" ]]; then
  QUERY_ID="$(<"$ROOT_DIR/.run/current-query-id")"
fi

run_remote() {
  local remote_command="$1"
  local command_id status
  command_id="$(aws_cli ssm send-command \
    --region "$REGION" \
    --instance-ids "$leader" \
    --document-name AWS-RunShellScript \
    --comment "1TRC ClickHouse progress" \
    --parameters "$(jq -cn --arg c "$remote_command" '{commands:[$c]}')" \
    --timeout-seconds 60 \
    --query 'Command.CommandId' \
    --output text)"

  while true; do
    status="$(aws_cli ssm get-command-invocation --region "$REGION" \
      --command-id "$command_id" --instance-id "$leader" --query Status --output text 2>/dev/null || true)"
    case "$status" in
      Success) break ;;
      Pending|InProgress|Delayed|"") sleep 2 ;;
      *)
        aws_cli ssm get-command-invocation --region "$REGION" \
          --command-id "$command_id" --instance-id "$leader" \
          --query '{Status:Status,StandardError:StandardErrorContent}' --output json >&2
        return 1
        ;;
    esac
  done

  aws_cli ssm get-command-invocation --region "$REGION" \
    --command-id "$command_id" --instance-id "$leader" \
    --query StandardOutputContent --output text
}

if [[ -n "$QUERY_ID" ]]; then
  progress_filter="(query_id = '$QUERY_ID' OR initial_query_id = '$QUERY_ID')"
  kill_filter="(query_id = '$QUERY_ID' OR initial_query_id = '$QUERY_ID')"
else
  progress_filter="(query_id LIKE '1trc-%' OR initial_query_id LIKE '1trc-%')"
  kill_filter="(query_id LIKE '1trc-%' OR initial_query_id LIKE '1trc-%')"
fi

progress_sql="
SELECT
  now() AS sampled_at_utc,
  hostName() AS host,
  if(query_id = initial_query_id, 'initial', 'worker') AS query_role,
  round(elapsed, 1) AS elapsed_s,
  round(read_rows / 1000000000, 2) AS read_rows_billion,
  round(read_rows / 1000000000000 * 100, 2) AS pct_of_1t_rows,
  round(read_bytes / 1073741824, 2) AS read_gib,
  round(memory_usage / 1073741824, 2) AS memory_gib,
  query_id
FROM clusterAllReplicas('one_trc', 'system', 'processes')
WHERE $progress_filter
ORDER BY host, query_role, query_id
FORMAT TSVWithNames
"
kill_sql="
KILL QUERY ON CLUSTER one_trc
WHERE $kill_filter
SYNC
"

remote_sql_command() {
  local sql="$1"
  local multiquery_flag="${2:-}"
  local sql_b64
  sql_b64="$(printf '%s' "$sql" | base64 | tr -d '\n')"
  printf 'printf %%s %s | base64 -d > /tmp/1trc-progress.sql && clickhouse-client %s < /tmp/1trc-progress.sql' \
    "$(printf '%s' "$sql_b64" | sed "s/'/'\\''/g; s/^/'/; s/$/'/")" \
    "$multiquery_flag"
}

if [[ "$KILL" -eq 1 ]]; then
  echo "Sending KILL QUERY for ${QUERY_ID:-all 1trc queries} on cluster one_trc..." >&2
  run_remote "$(remote_sql_command "$kill_sql" "--multiquery")"
  exit 0
fi

while true; do
  echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) leader=$leader query_id=${QUERY_ID:-any 1trc-*} ---"
  run_remote "$(remote_sql_command "$progress_sql")"
  [[ "$WATCH" -eq 1 ]] || break
  sleep "$INTERVAL"
done
