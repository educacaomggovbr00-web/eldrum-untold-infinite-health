#!/usr/bin/env bash
set -Eeuo pipefail

APKS_ARCHIVE="${1:-build/output/eldrum-untold-infinite-health.apks}"
PACKAGE="com.gotterdammerung.untold"
RESULT_DIR="build/emulator-test"
SPLIT_DIR="$RESULT_DIR/splits"

mkdir -p "$RESULT_DIR" "$SPLIT_DIR"
test -s "$APKS_ARCHIVE"

echo "=== Emulator details ===" | tee "$RESULT_DIR/summary.txt"
adb shell getprop ro.build.version.release | tr -d '\r' | tee -a "$RESULT_DIR/summary.txt"
adb shell getprop ro.build.version.sdk | tr -d '\r' | tee -a "$RESULT_DIR/summary.txt"
adb shell getprop ro.product.cpu.abilist | tr -d '\r' | tee -a "$RESULT_DIR/summary.txt"

echo "=== Extract all split APKs ==="
python3 - "$APKS_ARCHIVE" "$SPLIT_DIR" <<'PY'
from pathlib import Path
import sys, zipfile
archive, out = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(archive) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"APKS archive ZIP integrity failed: {bad}")
    entries = [n for n in z.namelist() if n.lower().endswith(".apk")]
    if len(entries) != 27:
        raise SystemExit(f"Expected exactly 27 split APKs, found {len(entries)}")
    used = set()
    for name in entries:
        target = out / Path(name).name
        if target.name in used:
            raise SystemExit(f"Duplicate APK basename: {target.name}")
        used.add(target.name)
        target.write_bytes(z.read(name))
    if "base.apk" not in used or "split_config.arm64_v8a.apk" not in used:
        raise SystemExit("Required base.apk or ARM64 ABI split is missing")
    print(f"Extracted {len(entries)} APK splits")
PY

echo "=== Install complete split set ==="
mapfile -t APKS < <(find "$SPLIT_DIR" -maxdepth 1 -type f -name '*.apk' | sort)
adb install-multiple -r -g "${APKS[@]}" 2>&1 | tee "$RESULT_DIR/install.txt"
adb shell pm path "$PACKAGE" | tee "$RESULT_DIR/installed-paths.txt"

echo "=== Launch game ==="
adb logcat -c
adb shell monkey -p "$PACKAGE" 1 2>&1 | tee "$RESULT_DIR/launch.txt"

ALIVE=0
for attempt in $(seq 1 15); do
  PID="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$PID" ]]; then
    ALIVE=1
    echo "Game process is alive at check $attempt (PID $PID)." | tee -a "$RESULT_DIR/summary.txt"
  else
    echo "Game process not running at check $attempt." | tee -a "$RESULT_DIR/summary.txt"
  fi
  sleep 2
done

adb shell dumpsys activity activities > "$RESULT_DIR/activities.txt" || true
adb shell dumpsys package "$PACKAGE" > "$RESULT_DIR/package-dump.txt" || true
adb logcat -d -v threadtime > "$RESULT_DIR/logcat.txt"
adb exec-out screencap -p > "$RESULT_DIR/screenshot.png" || true

if [[ "$ALIVE" -ne 1 ]] || ! adb shell pidof "$PACKAGE" >/dev/null 2>&1; then
  echo "FAIL: Eldrum did not remain running after launch." | tee -a "$RESULT_DIR/summary.txt"
  grep -Ei "$PACKAGE|pairip|AndroidRuntime|FATAL EXCEPTION|Fatal signal|UnsatisfiedLinkError|dlopen failed" "$RESULT_DIR/logcat.txt" > "$RESULT_DIR/relevant-logcat.txt" || true
  exit 1
fi

echo "PASS: Eldrum process remained alive during the 30-second smoke test." | tee -a "$RESULT_DIR/summary.txt"
