#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_time(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics", type=Path)
    parser.add_argument("placement_summary", type=Path)
    parser.add_argument("--runner-start-epoch", type=int, required=True)
    parser.add_argument("--teardown-start-epoch", type=int, required=True)
    parser.add_argument("--teardown-end-epoch", type=int, required=True)
    args = parser.parse_args()

    if not args.runner_start_epoch <= args.teardown_start_epoch <= args.teardown_end_epoch:
        raise ValueError("timestamps are not in runner-start/teardown-start/teardown-end order")

    metrics = read_json(args.metrics)
    placement = read_json(args.placement_summary)
    worker_span = (metrics.get("worker_metrics") or {}).get("worker_phase_span_seconds")
    reducer_seconds = metrics.get("reducer_seconds")
    application_seconds = None
    if isinstance(worker_span, (int, float)) and isinstance(reducer_seconds, (int, float)):
        application_seconds = worker_span + reducer_seconds

    teardown_completed = datetime.fromtimestamp(args.teardown_end_epoch, timezone.utc)
    reducer_stopped = parse_time(placement.get("reducer_stopped_at_utc"))
    post_processing_and_teardown_seconds = None
    if reducer_stopped is not None and reducer_stopped <= teardown_completed:
        post_processing_and_teardown_seconds = (teardown_completed - reducer_stopped).total_seconds()

    execution = {
        "application_processing_seconds": application_seconds,
        "continuous_processing_seconds": placement.get("continuous_processing_seconds"),
        "reducer_application_seconds": reducer_seconds,
        "worker_application_span_seconds": worker_span,
        "worker_to_reducer_handoff_seconds": placement.get("worker_to_reducer_handoff_seconds"),
    }
    lifecycle = {
        "infrastructure_teardown_seconds": args.teardown_end_epoch - args.teardown_start_epoch,
        "post_processing_and_teardown_seconds": post_processing_and_teardown_seconds,
        "runner_end_to_end_seconds": args.teardown_end_epoch - args.runner_start_epoch,
        "runner_started_at_utc": utc_time(args.runner_start_epoch),
        "teardown_completed_at_utc": utc_time(args.teardown_end_epoch),
        "teardown_started_at_utc": utc_time(args.teardown_start_epoch),
        "timing_resolution_seconds": 1,
    }

    metrics["aws_execution_timing"] = execution
    metrics["runner_lifecycle"] = lifecycle
    placement["application_processing_seconds"] = application_seconds
    placement["runner_lifecycle"] = lifecycle
    write_json(args.metrics, metrics)
    write_json(args.placement_summary, placement)
    print(f"Finalized {args.metrics}")
    print(f"Finalized {args.placement_summary}")


if __name__ == "__main__":
    main()
