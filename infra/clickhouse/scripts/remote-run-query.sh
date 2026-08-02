#!/usr/bin/env bash
set -Eeuo pipefail

S3_URL="$1"
MAX_THREADS="$2"
RUN_MODE="$3"
EXPECTED_FILES="$4"
QUERY_ID="${5:-}"
QUERY_FILE="/tmp/1trc-aggregate.sql"
RESULT_FILE="/tmp/1trc-result.csv"
ERROR_FILE="/tmp/1trc-query.stderr"
if [[ -z "$QUERY_ID" ]]; then
  QUERY_ID="1trc-${RUN_MODE}-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
fi
printf '%s\n' "$QUERY_ID" > /tmp/1trc-current-query-id

if [[ ! -f /var/lib/1trc-bootstrap-complete ]]; then
  echo "Bootstrap is not complete." >&2
  exit 1
fi

start_epoch="$(date +%s)"
start_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! clickhouse-client \
  --query_id "$QUERY_ID" \
  --param_s3_url="$S3_URL" \
  --max_threads="$MAX_THREADS" \
  --queries-file "$QUERY_FILE" \
  --format CSVWithNames \
  > "$RESULT_FILE" 2> "$ERROR_FILE"; then
  tail -n 100 "$ERROR_FILE" >&2
  exit 1
fi

end_epoch="$(date +%s)"
end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
clickhouse-client --query "SYSTEM FLUSH LOGS" >/dev/null

query_log="$(clickhouse-client --format JSONEachRow --query "
  SELECT
    query_duration_ms,
    read_rows,
    read_bytes,
    result_rows,
    memory_usage AS peak_memory_bytes,
    ProfileEvents AS profile_events
  FROM system.query_log
  WHERE type = 'QueryFinish' AND query_id = '$QUERY_ID'
  ORDER BY event_time_microseconds DESC
  LIMIT 1
" 2>/dev/null || true)"

if [[ -z "$query_log" ]]; then
  query_log='{}'
fi

version="$(cat /var/lib/1trc-clickhouse-version)"
metrics="$(jq -cn \
  --arg implementation clickhouse \
  --arg run_mode "$RUN_MODE" \
  --arg query_id "$QUERY_ID" \
  --arg start_time "$start_time" \
  --arg end_time "$end_time" \
  --arg version "$version" \
  --argjson elapsed "$((end_epoch - start_epoch))" \
  --argjson files "$EXPECTED_FILES" \
  --argjson query_log "$query_log" \
  '{implementation:$implementation,run_mode:$run_mode,query_id:$query_id,
    start_time:$start_time,end_time:$end_time,query_seconds:$elapsed,
    files_processed_expected:$files,clickhouse_version:$version} + $query_log')"

echo "RESULT_GZIP_BASE64=$(gzip -c "$RESULT_FILE" | base64 | tr -d '\n')"
echo "METRICS_JSON_BASE64=$(printf '%s' "$metrics" | base64 | tr -d '\n')"
