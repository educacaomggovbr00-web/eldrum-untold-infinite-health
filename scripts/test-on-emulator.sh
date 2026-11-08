#!/usr/bin/env bash
set -Eeuo pipefail

MODIFIED_ARCHIVE="${1:-build/output/eldrum-untold-infinite-health.apks}"
ORIGINAL_ARCHIVE="${2:?Pass the exact original split archive as the second argument}"
PACKAGE="com.gotterdammerung.untold"
RESULT_DIR="build/emulator-test"
TMP_DIR="${RUNNER_TEMP:-/tmp}/eldrum-emulator-test"
mkdir -p "$RESULT_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
: > "$RESULT_DIR/summary.txt"

{
  echo "Emulator Android:"
  adb shell getprop ro.build.version.release | tr -d '\r'
  adb shell getprop ro.build.version.sdk | tr -d '\r'
  echo "ABIs: $(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
} | tee -a "$RESULT_DIR/summary.txt"

extract_splits() {
  local archive="$1"
  local out="$2"
  mkdir -p "$out"
  python3 - "$archive" "$out" <<'PY'
from pathlib import Path
import sys, zipfile
archive, out = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(archive) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"APKS archive ZIP integrity failed: {bad}")
    entries = [n for n in z.namelist() if n.lower().endswith(".apk")]
    if len(entries) != 27:
        raise SystemExit(f"Expected 27 split APKs, found {len(entries)} in {archive.name}")
    used = set()
    for name in entries:
        target = out / Path(name).name
        if target.name in used:
            raise SystemExit(f"Duplicate APK basename: {target.name}")
        used.add(target.name)
        target.write_bytes(z.read(name))
    if "base.apk" not in used or "split_config.arm64_v8a.apk" not in used:
        raise SystemExit("Required base.apk or ARM64 ABI split is missing")
    print(f"Extracted {len(entries)} APK splits from {archive.name}")
PY
}

run_case() {
  local label="$1"
  local archive_dir="$2"
  local log="$RESULT_DIR/$label-logcat.txt"
  local pid=""
  local alive=0
  local summary="$RESULT_DIR/$label-summary.txt"
  local launch="$RESULT_DIR/$label-launch.txt"

  echo "=== $label: clean install ===" | tee "$summary"
  adb uninstall "$PACKAGE" >/dev/null 2>&1 || true

  mapfile -t APKS < <(find "$archive_dir" -maxdepth 1 -type f -name '*.apk' | sort)
  if ! adb install-multiple -r -g "${APKS[@]}" 2>&1 | tee "$RESULT_DIR/$label-install.txt"; then
    echo "$label: INSTALL_FAILED" | tee -a "$summary"
    return 1
  fi
  adb shell pm path "$PACKAGE" > "$RESULT_DIR/$label-installed-paths.txt"
  adb logcat -c
  adb shell monkey -p "$PACKAGE" 1 2>&1 | tee "$launch"

  for attempt in $(seq 1 20); do
    pid="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$pid" ]]; then
      alive=1
    elif [[ "$alive" -eq 1 ]]; then
      break
    fi
    sleep 1
  done

  adb shell dumpsys activity activities > "$RESULT_DIR/$label-activities.txt" || true
  adb shell dumpsys package "$PACKAGE" > "$RESULT_DIR/$label-package.txt" || true
  adb logcat -d -v threadtime > "$log"
  grep -Ei "$PACKAGE|pairip|AndroidRuntime|FATAL EXCEPTION|Fatal signal|SIGSEGV|UnsatisfiedLinkError|dlopen failed|crash_dump64|Process .* has died" "$log" > "$RESULT_DIR/$label-relevant-logcat.txt" || true
  adb exec-out screencap -p > "$RESULT_DIR/$label-screenshot.png" || true

  pid="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$pid" ]] && grep -q "$PACKAGE" "$RESULT_DIR/$label-activities.txt"; then
    echo "$label: LAUNCH_SURVIVED (PID $pid)" | tee -a "$summary"
    return 0
  fi

  echo "$label: CRASHED_OR_EXITED (last PID: ${pid:-none})" | tee -a "$summary"
  return 1
}

extract_splits "$ORIGINAL_ARCHIVE" "$TMP_DIR/original"
extract_splits "$MODIFIED_ARCHIVE" "$TMP_DIR/modified"

echo "=== Baseline control: original unmodified APK set ==="
if run_case original "$TMP_DIR/original"; then
  ORIGINAL_RESULT="PASS"
else
  ORIGINAL_RESULT="FAIL"
fi

echo "=== Test: modified APK set ==="
if run_case modified "$TMP_DIR/modified"; then
  MODIFIED_RESULT="PASS"
else
  MODIFIED_RESULT="FAIL"
fi

{
  echo
  echo "Original control: $ORIGINAL_RESULT"
  echo "Modified build: $MODIFIED_RESULT"
  if [[ "$ORIGINAL_RESULT" == "FAIL" && "$MODIFIED_RESULT" == "FAIL" ]]; then
    echo "Conclusion: both packages fail on this translated ARM64 emulator; this environment cannot isolate the mod as the cause."
  elif [[ "$ORIGINAL_RESULT" == "PASS" && "$MODIFIED_RESULT" == "FAIL" ]]; then
    echo "Conclusion: original works on this emulator; modified build has a reproducible startup failure."
  elif [[ "$MODIFIED_RESULT" == "PASS" ]]; then
    echo "Conclusion: modified build remained open in the emulator smoke test."
  else
    echo "Conclusion: original failed but modified passed; review logs and emulator compatibility."
  fi
} | tee -a "$RESULT_DIR/summary.txt"

if [[ "$MODIFIED_RESULT" != "PASS" ]]; then
  exit 1
fi
