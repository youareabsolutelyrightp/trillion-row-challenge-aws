#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

VCPUS_BY_SIZE = {
    "large": 2,
    "xlarge": 4,
    "2xlarge": 8,
    "4xlarge": 16,
    "8xlarge": 32,
    "12xlarge": 48,
    "16xlarge": 64,
    "metal": 64,
}


def instance_vcpus(instance_type: str) -> int | None:
    size = instance_type.split(".", 1)[1] if "." in instance_type else instance_type
    return VCPUS_BY_SIZE.get(size)


def event(events: dict[str, object], key: str) -> float:
    value = events.get(key, 0)
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics", type=Path)
    args = parser.parse_args()

    data = json.loads(args.metrics.read_text(encoding="utf-8"))
    events = data.get("profile_events") or {}
    query_seconds = float(data.get("query_duration_ms", 0)) / 1000.0
    if query_seconds <= 0:
        query_seconds = float(data.get("query_seconds", 0))

    read_rows = float(data.get("read_rows", 0))
    read_bytes = float(data.get("read_bytes", 0))
    instance_count = int(data.get("instance_count", 0) or 0)
    vcpus_per_instance = instance_vcpus(str(data.get("instance_type", "")))
    total_vcpus = vcpus_per_instance * instance_count if vcpus_per_instance else None
    files_expected = float(data.get("files_processed_expected", 0) or 0)

    real_us = event(events, "RealTimeMicroseconds")
    user_us = event(events, "UserTimeMicroseconds")
    system_us = event(events, "SystemTimeMicroseconds")
    cpu_wait_us = event(events, "OSCPUWaitMicroseconds")
    s3_us = event(events, "S3ReadMicroseconds")
    network_receive_us = event(events, "NetworkReceiveElapsedMicroseconds")
    s3_read_requests = event(events, "S3ReadRequestsCount")
    s3_head = event(events, "S3HeadObject")
    listed = event(events, "ObjectStorageListedObjects")

    derived = {
        "query_rows_per_second": round(read_rows / query_seconds, 3) if query_seconds else None,
        "query_mib_per_second": round(read_bytes / 1024 / 1024 / query_seconds, 3) if query_seconds else None,
        "query_gib_per_second": round(read_bytes / 1024 / 1024 / 1024 / query_seconds, 6) if query_seconds else None,
        "s3_read_requests_per_file": round(s3_read_requests / files_expected, 6) if files_expected else None,
        "s3_head_requests_per_file": round(s3_head / files_expected, 6) if files_expected else None,
        "listed_objects_per_expected_file": round(listed / files_expected, 6) if files_expected else None,
        "s3_read_wait_share_of_realtime": round(s3_us / real_us, 6) if real_us else None,
        "network_receive_share_of_realtime": round(network_receive_us / real_us, 6) if real_us else None,
        "cpu_wait_share_of_realtime": round(cpu_wait_us / real_us, 6) if real_us else None,
        "cpu_user_system_share_of_realtime": round((user_us + system_us) / real_us, 6) if real_us else None,
        "total_vcpus": total_vcpus,
        "vcpu_seconds_for_query": round(total_vcpus * query_seconds, 3) if total_vcpus else None,
        "rows_per_vcpu_second": round(read_rows / (total_vcpus * query_seconds), 3) if total_vcpus and query_seconds else None,
        "mib_per_vcpu_second": round(read_bytes / 1024 / 1024 / (total_vcpus * query_seconds), 6) if total_vcpus and query_seconds else None,
    }

    data["derived_metrics"] = derived
    args.metrics.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(derived, indent=2))


if __name__ == "__main__":
    main()
