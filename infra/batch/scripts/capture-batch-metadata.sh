#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
CONFIG_FILE="${BATCH_RUN_CONFIG:-$ROOT_DIR/run-config.env}"
source "$CONFIG_FILE"
AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE is required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
IAC_CMD="${IAC_CMD:-tofu}"
RUN_FILE="$ROOT_DIR/.run/current-run.json"
[[ -f "$RUN_FILE" ]] || { echo "No current run file: $RUN_FILE" >&2; exit 1; }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

run_id="$(jq -r '.run_id' "$RUN_FILE")"
mode="$(jq -r '.mode' "$RUN_FILE")"
worker_job_id="$(jq -r '.worker_job_id' "$RUN_FILE")"
reducer_job_id="$(jq -r '.reducer_job_id' "$RUN_FILE")"
array_size="$(jq -r '.array_size' "$RUN_FILE")"
mkdir -p "$PROJECT_ROOT/results"
summary_file="$PROJECT_ROOT/results/batch-${mode}-${run_id}-aws-placement-summary.json"
detail_file="$PROJECT_ROOT/results/batch-${mode}-${run_id}-aws-placement.json"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

worker_jobs_jsonl="$tmpdir/worker-jobs.jsonl"
: > "$worker_jobs_jsonl"

describe_job_ids() {
  if [[ "$#" -eq 0 ]]; then return 0; fi
  aws_cli batch describe-jobs --jobs "$@" | jq -c '.jobs[]'
}

ids=()
flush_ids() {
  if [[ "${#ids[@]}" -gt 0 ]]; then
    describe_job_ids "${ids[@]}" >> "$worker_jobs_jsonl"
    ids=()
  fi
}

if [[ "$array_size" -eq 1 ]]; then
  ids=("$worker_job_id")
  flush_ids
else
  for ((i = 0; i < array_size; i++)); do
    ids+=("${worker_job_id}:${i}")
    if [[ "${#ids[@]}" -ge 100 ]]; then flush_ids; fi
  done
  flush_ids
fi

jq -s '.' "$worker_jobs_jsonl" > "$tmpdir/worker-jobs.json"
aws_cli batch describe-jobs --jobs "$reducer_job_id" | jq '.jobs[0]' > "$tmpdir/reducer-job.json"

compute_environment="$($IAC_CMD -chdir="$ROOT_DIR" output -raw compute_environment 2>/dev/null || true)"
ecs_cluster_arn=""
if [[ -n "$compute_environment" ]]; then
  ecs_cluster_arn="$(aws_cli batch describe-compute-environments --compute-environments "$compute_environment" | jq -r '.computeEnvironments[0].ecsClusterArn // ""')"
fi

jq -r '.[] | .container.containerInstanceArn // empty' "$tmpdir/worker-jobs.json" > "$tmpdir/container-arns.txt"
jq -r '.container.containerInstanceArn // empty' "$tmpdir/reducer-job.json" >> "$tmpdir/container-arns.txt"
sort -u "$tmpdir/container-arns.txt" | sed '/^$/d' > "$tmpdir/container-arns-unique.txt"
: > "$tmpdir/container-instances.jsonl"

if [[ -n "$ecs_cluster_arn" && -s "$tmpdir/container-arns-unique.txt" ]]; then
  container_arns=()
  while IFS= read -r arn; do
    container_arns+=("$arn")
  done < "$tmpdir/container-arns-unique.txt"
  ids=()
  flush_container_ids() {
    if [[ "${#ids[@]}" -gt 0 ]]; then
      aws_cli ecs describe-container-instances --cluster "$ecs_cluster_arn" --container-instances "${ids[@]}" \
        | jq -c '.containerInstances[]' >> "$tmpdir/container-instances.jsonl"
      ids=()
    fi
  }
  for arn in "${container_arns[@]}"; do
    ids+=("$arn")
    if [[ "${#ids[@]}" -ge 100 ]]; then flush_container_ids; fi
  done
  flush_container_ids
fi
jq -s '.' "$tmpdir/container-instances.jsonl" > "$tmpdir/container-instances.json"

jq -r '.[].ec2InstanceId // empty' "$tmpdir/container-instances.json" | sort -u | sed '/^$/d' > "$tmpdir/ec2-ids.txt"
: > "$tmpdir/ec2-reservations.jsonl"
if [[ -s "$tmpdir/ec2-ids.txt" ]]; then
  ec2_ids=()
  while IFS= read -r ec2_id; do
    ec2_ids+=("$ec2_id")
  done < "$tmpdir/ec2-ids.txt"
  ids=()
  flush_ec2_ids() {
    if [[ "${#ids[@]}" -gt 0 ]]; then
      aws_cli ec2 describe-instances --instance-ids "${ids[@]}" \
        | jq -c '.Reservations[]' >> "$tmpdir/ec2-reservations.jsonl"
      ids=()
    fi
  }
  for id in "${ec2_ids[@]}"; do
    ids+=("$id")
    if [[ "${#ids[@]}" -ge 100 ]]; then flush_ec2_ids; fi
  done
  flush_ec2_ids
fi
jq -s '.' "$tmpdir/ec2-reservations.jsonl" > "$tmpdir/ec2-reservations.json"

captured_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg run_id "$run_id" \
  --arg mode "$mode" \
  --arg captured_at_utc "$captured_at_utc" \
  --arg worker_job_id "$worker_job_id" \
  --arg reducer_job_id "$reducer_job_id" \
  --arg compute_environment "$compute_environment" \
  --arg ecs_cluster_arn "$ecs_cluster_arn" \
  --slurpfile current_run "$RUN_FILE" \
  --slurpfile worker_jobs "$tmpdir/worker-jobs.json" \
  --slurpfile reducer_job "$tmpdir/reducer-job.json" \
  --slurpfile container_instances "$tmpdir/container-instances.json" \
  --slurpfile ec2_reservations "$tmpdir/ec2-reservations.json" \
  '{run_id:$run_id, mode:$mode, captured_at_utc:$captured_at_utc, worker_job_id:$worker_job_id, reducer_job_id:$reducer_job_id, compute_environment:$compute_environment, ecs_cluster_arn:$ecs_cluster_arn, current_run:$current_run[0], worker_jobs:$worker_jobs[0], reducer_job:$reducer_job[0], container_instances:$container_instances[0], ec2_reservations:$ec2_reservations[0]}' \
  > "$detail_file"

python3 - "$detail_file" "$summary_file" <<'INNERPY'
from __future__ import annotations

import json
import math
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

VCPUS_BY_SIZE = {
    "large": 2,
    "xlarge": 4,
    "2xlarge": 8,
    "4xlarge": 16,
    "8xlarge": 32,
    "12xlarge": 48,
    "16xlarge": 64,
}

def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None

def ms_to_seconds(value: int | float | None) -> float | None:
    if value in (None, 0):
        return None
    return float(value) / 1000.0

def seconds_to_utc(value: float | None) -> str | None:
    if value is None:
        return None
    return datetime.fromtimestamp(value, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

def job_vcpus(job: dict) -> float:
    container = job.get("container") or {}
    for item in container.get("resourceRequirements") or []:
        if item.get("type") == "VCPU":
            try:
                return float(item.get("value"))
            except (TypeError, ValueError):
                pass
    try:
        return float(container.get("vcpus") or 0)
    except (TypeError, ValueError):
        return 0.0

def durations(jobs: list[dict]) -> list[float]:
    values = []
    for job in jobs:
        start = ms_to_seconds(job.get("startedAt"))
        stop = ms_to_seconds(job.get("stoppedAt"))
        if start is not None and stop is not None and stop >= start:
            values.append(stop - start)
    return values

def queues(jobs: list[dict]) -> list[float]:
    values = []
    for job in jobs:
        created = ms_to_seconds(job.get("createdAt"))
        start = ms_to_seconds(job.get("startedAt"))
        if created is not None and start is not None and start >= created:
            values.append(start - created)
    return values

def stats(values: list[float]) -> dict | None:
    if not values:
        return None
    values = sorted(values)
    def pct(p: float) -> float:
        index = max(0, min(len(values) - 1, math.ceil(len(values) * p) - 1))
        return values[index]
    total = sum(values)
    return {
        "count": len(values),
        "min": values[0],
        "p50": pct(0.50),
        "p95": pct(0.95),
        "max": values[-1],
        "avg": total / len(values),
        "sum": total,
    }

def instance_vcpus(instance_type: str) -> int | None:
    size = instance_type.split(".", 1)[-1]
    return VCPUS_BY_SIZE.get(size)

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
detail = json.loads(input_path.read_text())
worker_jobs = [job for job in detail.get("worker_jobs", []) if job]
reducer_job = detail.get("reducer_job") or {}
all_jobs = worker_jobs + ([reducer_job] if reducer_job else [])
created = [ms_to_seconds(job.get("createdAt")) for job in all_jobs]
started = [ms_to_seconds(job.get("startedAt")) for job in all_jobs]
stopped = [ms_to_seconds(job.get("stoppedAt")) for job in all_jobs]
created = [v for v in created if v is not None]
started = [v for v in started if v is not None]
stopped = [v for v in stopped if v is not None]
worker_started = [ms_to_seconds(job.get("startedAt")) for job in worker_jobs]
worker_stopped = [ms_to_seconds(job.get("stoppedAt")) for job in worker_jobs]
worker_started = [v for v in worker_started if v is not None]
worker_stopped = [v for v in worker_stopped if v is not None]
worker_runtimes = durations(worker_jobs)
worker_queues = queues(worker_jobs)
reducer_runtime = durations([reducer_job])
reducer_queue = queues([reducer_job])
reducer_vcpus = job_vcpus(reducer_job) if reducer_job else 0.0
worker_first_started = min(worker_started) if worker_started else None
worker_last_stopped = max(worker_stopped) if worker_stopped else None
reducer_started = ms_to_seconds(reducer_job.get("startedAt"))
reducer_stopped = ms_to_seconds(reducer_job.get("stoppedAt"))
continuous_processing_seconds = None
if worker_first_started is not None and reducer_stopped is not None and reducer_stopped >= worker_first_started:
    continuous_processing_seconds = reducer_stopped - worker_first_started
worker_to_reducer_handoff_seconds = None
if worker_last_stopped is not None and reducer_started is not None and reducer_started >= worker_last_stopped:
    worker_to_reducer_handoff_seconds = reducer_started - worker_last_stopped
worker_vcpu_seconds = 0.0
for job in worker_jobs:
    start = ms_to_seconds(job.get("startedAt"))
    stop = ms_to_seconds(job.get("stoppedAt"))
    if start is not None and stop is not None and stop >= start:
        worker_vcpu_seconds += (stop - start) * job_vcpus(job)
reducer_vcpu_seconds = (reducer_runtime[0] * reducer_vcpus) if reducer_runtime else 0.0

instances = []
for reservation in detail.get("ec2_reservations", []) or []:
    for instance in reservation.get("Instances", []) or []:
        instance_type = instance.get("InstanceType")
        launch_time = parse_dt(instance.get("LaunchTime"))
        captured_at = parse_dt(detail.get("captured_at_utc")) or datetime.now(timezone.utc)
        running_seconds_at_capture = None
        if launch_time is not None:
            running_seconds_at_capture = max(0.0, (captured_at - launch_time).total_seconds())
        vcpus = instance_vcpus(instance_type or "")
        instances.append({
            "instance_id": instance.get("InstanceId"),
            "instance_type": instance_type,
            "availability_zone": (instance.get("Placement") or {}).get("AvailabilityZone"),
            "private_ip": instance.get("PrivateIpAddress"),
            "lifecycle": instance.get("InstanceLifecycle") or "on-demand",
            "launch_time": instance.get("LaunchTime"),
            "state": (instance.get("State") or {}).get("Name"),
            "vcpus_estimated": vcpus,
            "running_seconds_at_capture": running_seconds_at_capture,
            "vcpu_seconds_at_capture_estimated": (running_seconds_at_capture * vcpus) if running_seconds_at_capture is not None and vcpus else None,
        })

mix_counter = Counter(item["instance_type"] for item in instances if item.get("instance_type"))
az_counter = Counter(item["availability_zone"] for item in instances if item.get("availability_zone"))
mix = []
for instance_type, count in sorted(mix_counter.items()):
    vcpus = instance_vcpus(instance_type) or 0
    mix.append({"instance_type": instance_type, "count": count, "vcpus_each_estimated": vcpus, "total_vcpus_estimated": count * vcpus})

summary = {
    "run_id": detail.get("run_id"),
    "mode": detail.get("mode"),
    "captured_at_utc": detail.get("captured_at_utc"),
    "worker_parent_job_id": detail.get("worker_job_id"),
    "reducer_job_id": detail.get("reducer_job_id"),
    "worker_jobs_described": len(worker_jobs),
    "job_status_counts": dict(Counter(job.get("status") for job in all_jobs)),
    "worker_status_counts": dict(Counter(job.get("status") for job in worker_jobs)),
    "end_to_end_job_seconds": (max(stopped) - min(created)) if created and stopped else None,
    "first_job_queue_seconds": (min(started) - min(created)) if created and started else None,
    "worker_wall_seconds": (max(worker_stopped) - min(worker_started)) if worker_started and worker_stopped else None,
    "continuous_processing_seconds": continuous_processing_seconds,
    "worker_to_reducer_handoff_seconds": worker_to_reducer_handoff_seconds,
    "worker_first_started_at_utc": seconds_to_utc(worker_first_started),
    "worker_last_stopped_at_utc": seconds_to_utc(worker_last_stopped),
    "reducer_started_at_utc": seconds_to_utc(reducer_started),
    "reducer_stopped_at_utc": seconds_to_utc(reducer_stopped),
    "worker_runtime_seconds": stats(worker_runtimes),
    "worker_queue_seconds": stats(worker_queues),
    "reducer_runtime_seconds": reducer_runtime[0] if reducer_runtime else None,
    "reducer_queue_seconds": reducer_queue[0] if reducer_queue else None,
    "job_vcpu_seconds_estimated": {
        "workers": worker_vcpu_seconds,
        "reducer": reducer_vcpu_seconds,
        "total": worker_vcpu_seconds + reducer_vcpu_seconds,
    },
    "ec2_instances_seen": len(instances),
    "instance_mix": mix,
    "availability_zone_counts": dict(sorted(az_counter.items())),
    "instance_vcpu_seconds_at_capture_estimated": sum(item["vcpu_seconds_at_capture_estimated"] or 0 for item in instances),
    "instances": instances,
}
output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
INNERPY

echo "AWS placement detail:  $detail_file"
echo "AWS placement summary: $summary_file"
