#!/usr/bin/env python3
"""Rank Hermes functions by cross-references to the health model and export IDs."""

from pathlib import Path
import json
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build")
function_table_path = Path(sys.argv[2] if len(sys.argv) > 2 else root / "tmp" / "functions.json")
tmp = root / "tmp"
reports = root / "reports"
reports.mkdir(parents=True, exist_ok=True)

terms = ["health", "alive", "maxHealth", "changeHealth", "_id", "player"]
xref_sets = {}
for term in terms:
    path = tmp / f"xref-{term}.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        xref_sets[term] = {
            int(item["function_id"])
            for item in data.get("results", [])
            if item.get("function_id") is not None
        }
    except (OSError, ValueError, TypeError, KeyError):
        xref_sets[term] = set()

functions_data = json.loads(function_table_path.read_text(encoding="utf-8"))
if isinstance(functions_data, dict):
    functions_data = functions_data.get("functions", [])
functions = {
    int(item["id"]): item
    for item in functions_data
    if isinstance(item, dict) and item.get("id") is not None
}

# Actor.changeHealth's decompiled implementation uses all three state fields.
strong = xref_sets["health"] & xref_sets["alive"] & xref_sets["maxHealth"]
medium = (xref_sets["health"] & xref_sets["alive"]) | (
    xref_sets["health"] & xref_sets["maxHealth"]
)
weak = xref_sets["health"] | xref_sets["changeHealth"]

ranked = []
for fid in strong:
    ranked.append((fid, 100, "health+alive+maxHealth"))
for fid in medium - strong:
    ranked.append((fid, 60, "health+alive/maxHealth"))
for fid in weak - strong - medium:
    ranked.append((fid, 20, "health/changeHealth only"))

ranked.sort(key=lambda row: (-row[1], row[0]))
# Export up to 30 IDs so the workflow produces small, reviewable HASM files.
selected = ranked[:30]
(tmp / "selected-function-ids.txt").write_text(
    "".join(f"{fid}\n" for fid, _, _ in selected), encoding="utf-8"
)

out = reports / "health-candidates.txt"
with out.open("w", encoding="utf-8") as handle:
    handle.write("ELDRUM: UNTOLD — HBC 98 HEALTH FUNCTION CANDIDATES\n")
    handle.write("Ranked from string cross-references. Verify semantics in each HASM listing.\n\n")
    handle.write("Cross-reference counts:\n")
    for term in terms:
        handle.write(f"  {term}: {len(xref_sets[term])}\n")
    handle.write(f"\nStrong intersection (health AND alive AND maxHealth): {len(strong)}\n")
    handle.write(f"Candidate functions exported: {len(selected)}\n\n")
    for fid, score, reason in selected:
        item = functions.get(fid, {})
        name = item.get("name") or "<anonymous>"
        offset = item.get("offset", "?")
        size = item.get("size", "?")
        params = item.get("params", "?")
        frame = item.get("frame_size", "?")
        handle.write(
            f"ID {fid:5d} | score {score:3d} | {reason:28s} | "
            f"name={name!r} offset={offset} size={size} params={params} frame={frame}\n"
        )
    if not selected:
        handle.write("No matching functions were ranked. Inspect xref logs and HBC info.\n")

print(f"Wrote {out}; {len(selected)} function IDs selected.")
