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


# Emit larger, function-oriented context for the Actor health model. This report
# stays small and deliberately excludes the full proprietary game bundle.
bundle_js = root / "decompiled" / "1-index.android.bundle.js"
actor_out = root / "reports" / "actor-health-context.txt"
if bundle_js.exists():
    lines = bundle_js.read_text(encoding="utf-8", errors="replace").splitlines()
    anchors = re.compile(
        r"\bclass Actor\b|\bcalculateDamageInfliction\b|\bchangeHealth\b|"
        r"\bhealthPercentage\b|\bmaxHealth\b|\balive\b",
        re.IGNORECASE,
    )
    indices = [i for i, line in enumerate(lines) if anchors.search(line)]
    windows = []
    for i in indices:
        start, end = max(0, i - 28), min(len(lines), i + 42)
        if windows and start <= windows[-1][1] + 3:
            windows[-1] = (windows[-1][0], max(windows[-1][1], end))
        else:
            windows.append((start, end))
    with actor_out.open("w", encoding="utf-8") as handle:
        handle.write("ELDRUM: UNTOLD — ACTOR / HEALTH IMPLEMENTATION CONTEXT\n")
        handle.write("Decompiled HBC 98 code context. Treat as a lead; verify against runtime behavior.\n\n")
        for start, end in windows[:40]:
            module_line = None
            for back in range(start, -1, -1):
                if lines[back].strip().startswith("// Module "):
                    module_line = lines[back].strip()
                    break
            handle.write(f"===== Lines {start + 1}-{end}; {module_line or 'module header not found'} =====\n")
            for line_no in range(start, end):
                line = lines[line_no].rstrip()
                if len(line) > 1500:
                    line = line[:1500] + " … [line truncated]"
                handle.write(f"{line_no + 1}: {line}\n")
            handle.write("\n")
        handle.write(f"Anchor matches: {len(indices)}; context windows: {min(len(windows), 40)}.\n")
    print(f"Actor context report written: {actor_out} ({len(indices)} anchors)")
else:
    actor_out.write_text("Decompiled bundle was not found; Actor context unavailable.\n", encoding="utf-8")
