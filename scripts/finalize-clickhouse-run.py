#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path


def parse_aws_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics", type=Path)
    parser.add_argument(
        "--teardown-time",
        required=True,
        help="UTC timestamp recorded after terraform destroy, for example 2026-06-14T12:34:56Z",
    )
    args = parser.parse_args()

    data = json.loads(args.metrics.read_text(encoding="utf-8"))
    launch = parse_aws_time(data["launch_time"])
    query_start = parse_aws_time(data["start_time"])
    query_end = parse_aws_time(data["end_time"])
    teardown = parse_aws_time(args.teardown_time)
    if not launch <= query_start <= query_end <= teardown:
        raise ValueError("timestamps are not in launch/query-start/query-end/teardown order")

    data.update(
        {
            "teardown_time": args.teardown_time,
            "provisioning_seconds": (query_start - launch).total_seconds(),
            "teardown_seconds": (teardown - query_end).total_seconds(),
            "end_to_end_seconds": (teardown - launch).total_seconds(),
        }
    )
    args.metrics.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"Finalized {args.metrics}")


if __name__ == "__main__":
    main()
