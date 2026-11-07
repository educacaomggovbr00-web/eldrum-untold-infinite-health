#!/usr/bin/env python3
"""Extract short, bounded code contexts for health-related reverse-engineering leads."""

from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build")
out = root / "reports" / "health-candidates.txt"
out.parent.mkdir(parents=True, exist_ok=True)

pattern = re.compile(
    r"UntoldCharacterMaxHealth|UntoldNpcMaxHealth|Resilience|"
    r"max.?health|current.?health|player.?hp|health|hit.?points?|"
    r"damage|stamina|life.?points?",
    re.IGNORECASE,
)
extensions = {".js", ".java", ".smali", ".xml", ".txt", ".kt", ".json"}
roots = [
    root / "decompiled",
    root / "jadx" / "sources",
    root / "apktool" / "smali",
    root / "raw-bundle-strings.txt",
]
max_hits = 220
hits = []

for base in roots:
    files = [base] if base.is_file() else (base.rglob("*") if base.exists() else [])
    for path in files:
        if not path.is_file() or path.suffix.lower() not in extensions and path.name != "raw-bundle-strings.txt":
            continue
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        matched = 0
        for index, line in enumerate(lines):
            if not pattern.search(line):
                continue
            matched += 1
            if len(hits) >= max_hits:
                break
            start = max(0, index - 1)
            end = min(len(lines), index + 2)
            context = []
            for row in lines[start:end]:
                clean = row.strip()
                if len(clean) > 420:
                    clean = clean[:420] + " … [truncated]"
                context.append(clean)
            relative = path.relative_to(root) if path.is_relative_to(root) else path
            hits.append((str(relative), index + 1, context))
        if len(hits) >= max_hits:
            break
    if len(hits) >= max_hits:
        break

with out.open("w", encoding="utf-8") as handle:
    handle.write("ELDRUM: UNTOLD — HEALTH/DAMAGE SEARCH LEADS\n")
    handle.write("These are search matches, not proof that a line controls the player character.\n\n")
    if not hits:
        handle.write("No candidate strings matched the current search patterns.\n")
    for filename, line_number, context in hits:
        handle.write(f"--- {filename}:{line_number} ---\n")
        for row in context:
            handle.write(row + "\n")
        handle.write("\n")
    handle.write(f"\nTotal candidate matches included: {len(hits)} (maximum {max_hits}).\n")

print(f"Candidate report written: {out} ({len(hits)} matches)")
