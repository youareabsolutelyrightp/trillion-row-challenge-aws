#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

GIB = 1024**3
PROJECT_ROOT = Path(__file__).resolve().parents[1]


def number(value: Any, default: float = 0.0) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    return default


def load_json(path: Path | None) -> dict[str, Any]:
    if not path:
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return ""
    if isinstance(value, int):
        return f"{value:,}"
    if isinstance(value, float):
        return f"{value:,.{digits}f}"
    return str(value)


def public_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return path.name


def build_row(metrics_path: Path, label: str, instance_spec: dict[str, Any]) -> dict[str, Any]:
    data = json.loads(metrics_path.read_text(encoding="utf-8"))
    derived = data.get("derived_metrics") or {}
    events = data.get("profile_events") or {}

    query_seconds = number(data.get("query_duration_ms")) / 1000.0
    if query_seconds <= 0:
        query_seconds = number(data.get("query_seconds"))

    read_rows = number(data.get("read_rows"))
    read_bytes = number(data.get("read_bytes"))
    instance_count = int(number(data.get("instance_count")))
    total_vcpus = derived.get("total_vcpus")
    if total_vcpus is not None:
        total_vcpus = int(total_vcpus)
    vcpus_per_instance = instance_spec.get("VCpus")
    if total_vcpus is None and vcpus_per_instance and instance_count:
        total_vcpus = int(vcpus_per_instance) * instance_count

    peak_network = instance_spec.get("PeakBandwidthInGbps")
    cluster_peak_network = None
    if isinstance(peak_network, (int, float)) and instance_count:
        cluster_peak_network = float(peak_network) * instance_count

    node_hours = instance_count * query_seconds / 3600 if query_seconds and instance_count else None
    vcpu_hours = total_vcpus * query_seconds / 3600 if query_seconds and total_vcpus else None
    avg_gib_s = read_bytes / GIB / query_seconds if query_seconds else None
    avg_gbps = read_bytes * 8 / 1_000_000_000 / query_seconds if query_seconds else None

    row = {
        "label": label,
        "metrics_file": public_path(metrics_path),
        "query_id": data.get("query_id"),
        "run_mode": data.get("run_mode"),
        "clickhouse_version": data.get("clickhouse_version"),
        "aws_region": data.get("aws_region"),
        "availability_zone": data.get("availability_zone"),
        "instance_type": data.get("instance_type"),
        "instance_count": instance_count,
        "vcpus_per_instance": vcpus_per_instance,
        "total_vcpus": total_vcpus,
        "network_performance": instance_spec.get("NetworkPerformance"),
        "network_peak_gbps_per_instance": peak_network,
        "cluster_peak_network_gbps": cluster_peak_network,
        "query_seconds": query_seconds,
        "query_minutes": query_seconds / 60 if query_seconds else None,
        "node_hours_query_only": node_hours,
        "vcpu_hours_query_only": vcpu_hours,
        "read_rows_billion": read_rows / 1_000_000_000 if read_rows else None,
        "read_gib_clickhouse_reported": read_bytes / GIB if read_bytes else None,
        "avg_s3_read_gib_per_second_clickhouse_reported": avg_gib_s,
        "avg_s3_read_gbps_clickhouse_reported": avg_gbps,
        "avg_s3_read_gbps_per_node": avg_gbps / instance_count if avg_gbps and instance_count else None,
        "avg_s3_read_gbps_per_vcpu": avg_gbps / total_vcpus if avg_gbps and total_vcpus else None,
        "rows_per_vcpu_second": derived.get("rows_per_vcpu_second"),
        "mib_per_vcpu_second": derived.get("mib_per_vcpu_second"),
        "s3_read_requests_per_file": derived.get("s3_read_requests_per_file"),
        "s3_head_requests_per_file": derived.get("s3_head_requests_per_file"),
        "s3_read_wait_share_of_realtime": derived.get("s3_read_wait_share_of_realtime"),
        "network_receive_share_of_realtime": derived.get("network_receive_share_of_realtime"),
        "cpu_wait_share_of_realtime": derived.get("cpu_wait_share_of_realtime"),
        "real_time_microseconds": events.get("RealTimeMicroseconds"),
        "network_receive_elapsed_microseconds": events.get("NetworkReceiveElapsedMicroseconds"),
        "s3_read_microseconds": events.get("S3ReadMicroseconds"),
    }
    return row


def write_outputs(row: dict[str, Any], jsonl_path: Path, markdown_path: Path) -> None:
    jsonl_path.parent.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    if jsonl_path.exists():
        for line in jsonl_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))

    rows = [existing for existing in rows if existing.get("label") != row.get("label")]
    rows.append(row)
    jsonl_path.write_text("\n".join(json.dumps(r, sort_keys=True) for r in rows) + "\n", encoding="utf-8")

    headers = [
        "label",
        "shape",
        "vCPUs",
        "network",
        "query min",
        "node-hours",
        "vCPU-hours",
        "rows B",
        "read GiB/s",
        "read Gb/s",
        "Gb/s/node",
        "rows/vCPU-s",
        "S3 GET/file",
        "S3 wait share",
    ]
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for r in rows:
        shape = f"{r.get('instance_count')} x {r.get('instance_type')}"
        network = r.get("network_performance") or ""
        peak = r.get("network_peak_gbps_per_instance")
        if peak is not None:
            network = f"{network} ({fmt(peak)} Gb/s each)"
        values = [
            r.get("label"),
            shape,
            r.get("total_vcpus"),
            network,
            fmt(r.get("query_minutes")),
            fmt(r.get("node_hours_query_only"), 3),
            fmt(r.get("vcpu_hours_query_only"), 2),
            fmt(r.get("read_rows_billion")),
            fmt(r.get("avg_s3_read_gib_per_second_clickhouse_reported"), 3),
            fmt(r.get("avg_s3_read_gbps_clickhouse_reported"), 2),
            fmt(r.get("avg_s3_read_gbps_per_node"), 2),
            fmt(r.get("rows_per_vcpu_second"), 0),
            fmt(r.get("s3_read_requests_per_file"), 2),
            fmt(r.get("s3_read_wait_share_of_realtime"), 3),
        ]
        lines.append("| " + " | ".join(str(v) if v is not None else "" for v in values) + " |")

    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics", type=Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--instance-spec", type=Path)
    parser.add_argument("--jsonl", type=Path, default=PROJECT_ROOT / "results/clickhouse-comparison-runs.jsonl")
    parser.add_argument("--markdown", type=Path, default=PROJECT_ROOT / "results/clickhouse-comparison.md")
    args = parser.parse_args()

    row = build_row(args.metrics, args.label, load_json(args.instance_spec))
    write_outputs(row, args.jsonl, args.markdown)
    print(json.dumps(row, indent=2, sort_keys=True))
    print(f"Saved JSONL: {args.jsonl}")
    print(f"Saved Markdown: {args.markdown}")


if __name__ == "__main__":
    main()
