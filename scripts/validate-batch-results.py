#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

EXPECTED_HEADER = ["station", "min_measure", "max_measure", "mean_measure"]
FULL_ROWS = 1_000_000_000_000
FULL_STATIONS = 412


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True, type=Path)
    parser.add_argument("--metrics", required=True, type=Path)
    args = parser.parse_args()

    with args.csv.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != EXPECTED_HEADER:
            raise SystemExit(f"expected header {EXPECTED_HEADER}, got {reader.fieldnames}")
        previous = None
        rows = 0
        for line_number, row in enumerate(reader, start=2):
            station = row["station"]
            if not station:
                raise SystemExit(f"line {line_number}: empty station")
            if previous is not None and station <= previous:
                raise SystemExit(f"line {line_number}: stations are not strictly sorted")
            previous = station
            values = [float(row[name]) for name in ("min_measure", "max_measure", "mean_measure")]
            if not all(math.isfinite(v) for v in values):
                raise SystemExit(f"line {line_number}: non-finite value")
            mn, mx, mean = values
            if mn > mean or mean > mx:
                raise SystemExit(f"line {line_number}: invalid min/mean/max ordering")
            rows += 1
    if rows == 0:
        raise SystemExit("no result rows")

    metrics = json.loads(args.metrics.read_text())
    if metrics.get("partials_expected") != metrics.get("partials_found"):
        raise SystemExit("missing partial files according to reducer metrics")
    if rows != FULL_STATIONS:
        raise SystemExit(f"full output has {rows} stations, expected {FULL_STATIONS}")
    if int(metrics.get("rows_reduced", -1)) != FULL_ROWS:
        raise SystemExit(f"full metrics rows_reduced={metrics.get('rows_reduced')}, expected {FULL_ROWS}")
    print(f"Valid Batch full result: {rows} sorted stations")


if __name__ == "__main__":
    main()
