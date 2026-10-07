#!/usr/bin/env python3
"""Apply a user's preferred IRE route to the generated local launcher roster.

Preferences are keyed by IRE model family and may only select a route IRE currently
lists for that family. The source cache remains untouched; this updates the launcher's
derived bundle, picker table, and local Top 20 CSV together.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import tempfile
from pathlib import Path


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def apply(bundle_path: Path, table_path: Path, csv_path: Path, preferences_path: Path) -> list[str]:
    preferences = json.loads(preferences_path.read_text(encoding="utf-8"))
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    if not isinstance(preferences, dict) or not isinstance(bundle.get("top20"), list):
        raise ValueError("preferences must map model families to InferHub route IDs")

    rows_by_name = {row.get("name"): row for row in bundle["top20"] if isinstance(row, dict)}
    updates: dict[str, str] = {}
    for name, route in preferences.items():
        if not isinstance(name, str) or not isinstance(route, str):
            raise ValueError("each provider preference must be a string family-to-route entry")
        row = rows_by_name.get(name)
        if row is None or route not in (row.get("ids") or []):
            raise ValueError(f"{route!r} is not a current IRE route for {name!r}")
        updates[name] = route
        ids = row["ids"]
        row["ids"] = [route] + [candidate for candidate in ids if candidate != route]

    table_lines = table_path.read_text(encoding="utf-8").splitlines()
    table_output = []
    found = set()
    for line in table_lines:
        fields = line.split("|")
        if len(fields) >= 4 and fields[1] in updates:
            fields[2] = updates[fields[1]]
            found.add(fields[1])
        table_output.append("|".join(fields))
    if found != set(updates):
        missing = ", ".join(sorted(set(updates) - found))
        raise ValueError(f"model table has no row for preferred family: {missing}")

    with csv_path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        fieldnames = reader.fieldnames
        csv_rows = list(reader)
    if not fieldnames or "model_family" not in fieldnames or "model_ids" not in fieldnames:
        raise ValueError("Top 20 CSV is missing its model-family route columns")
    for row in csv_rows:
        name = row.get("model_family")
        if name not in updates:
            continue
        ids = [value.strip() for value in (row.get("model_ids") or "").split(";") if value.strip()]
        route = updates[name]
        if route not in ids:
            raise ValueError(f"{route!r} is missing from the Top 20 CSV row for {name!r}")
        ordered = [route] + [candidate for candidate in ids if candidate != route]
        row["model_ids"] = "; ".join(ordered)

    from io import StringIO

    csv_output = StringIO(newline="")
    writer = csv.DictWriter(csv_output, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    writer.writerows(csv_rows)

    _atomic_write(bundle_path, json.dumps(bundle, indent=2, ensure_ascii=False) + "\n")
    _atomic_write(table_path, "\n".join(table_output) + "\n")
    _atomic_write(csv_path, csv_output.getvalue())
    return [f"{name} -> {route}" for name, route in sorted(updates.items())]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--table", required=True, type=Path)
    parser.add_argument("--top20-csv", required=True, type=Path)
    parser.add_argument("--preferences", required=True, type=Path)
    args = parser.parse_args()
    try:
        applied = apply(args.bundle, args.table, args.top20_csv, args.preferences)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"IRE provider preferences not applied: {exc}", file=sys.stderr)
        return 1
    for item in applied:
        print(f"IRE provider preference applied: {item}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
