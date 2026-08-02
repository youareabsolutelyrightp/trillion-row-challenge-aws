#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

EXPECTED_HEADER = ["station", "min_measure", "max_measure", "mean_measure"]


def load(path: Path) -> dict[str, tuple[float, float, float]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != EXPECTED_HEADER:
            raise ValueError(
                f"{path}: expected header {EXPECTED_HEADER}, got {reader.fieldnames}"
            )

        rows: dict[str, tuple[float, float, float]] = {}
        previous: str | None = None
        for line_number, row in enumerate(reader, start=2):
            station = row["station"]
            if not station:
                raise ValueError(f"{path}:{line_number}: empty station")
            if previous is not None and station <= previous:
                raise ValueError(
                    f"{path}:{line_number}: stations are not strictly sorted"
                )
            previous = station

            values = tuple(
                float(row[name])
                for name in ("min_measure", "max_measure", "mean_measure")
            )
            if not all(math.isfinite(value) for value in values):
                raise ValueError(f"{path}:{line_number}: non-finite measurement")
            minimum, maximum, mean = values
            if minimum > maximum or mean < minimum or mean > maximum:
                raise ValueError(f"{path}:{line_number}: invalid aggregate ordering")
            rows[station] = values

    if not rows:
        raise ValueError(f"{path}: no data rows")
    return rows


def compare(
    candidate: dict[str, tuple[float, float, float]],
    reference: dict[str, tuple[float, float, float]],
    tolerance: float,
) -> None:
    if candidate.keys() != reference.keys():
        missing = sorted(reference.keys() - candidate.keys())[:5]
        extra = sorted(candidate.keys() - reference.keys())[:5]
        raise ValueError(f"station mismatch; missing={missing}, extra={extra}")

    for station, actual in candidate.items():
        expected = reference[station]
        if actual[0] != expected[0] or actual[1] != expected[1]:
            raise ValueError(f"{station}: min/max mismatch")
        if not math.isclose(actual[2], expected[2], rel_tol=tolerance, abs_tol=tolerance):
            raise ValueError(
                f"{station}: mean mismatch {actual[2]} != {expected[2]}"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--mean-tolerance", type=float, default=1e-9)
    parser.add_argument("--expected-stations", type=int)
    parser.add_argument("--metrics", type=Path)
    parser.add_argument("--expected-read-rows", type=int)
    args = parser.parse_args()

    candidate = load(args.candidate)
    if args.expected_stations is not None and len(candidate) != args.expected_stations:
        raise ValueError(
            f"expected {args.expected_stations} stations, got {len(candidate)}"
        )
    if (args.metrics is None) != (args.expected_read_rows is None):
        raise ValueError("--metrics and --expected-read-rows must be used together")
    if args.metrics is not None:
        metrics = json.loads(args.metrics.read_text(encoding="utf-8"))
        read_rows = int(metrics.get("read_rows", -1))
        if read_rows != args.expected_read_rows:
            raise ValueError(
                f"metrics read_rows={read_rows}, expected {args.expected_read_rows}"
            )
    if args.reference:
        compare(candidate, load(args.reference), args.mean_tolerance)
    print(f"Valid result: {len(candidate)} sorted stations")


if __name__ == "__main__":
    main()
