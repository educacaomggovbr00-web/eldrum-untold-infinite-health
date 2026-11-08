#!/usr/bin/env bash
set -Eeuo pipefail

MODIFIED_ARCHIVE="\${1:-build/output/eldrum-untold-infinite-health.apks}"
ORIGINAL_ARCHIVE="\${2:?Pass the exact original split archive as the second argument}"
PACKAGE="com.gotterdammerung.untold"
RESULT_DIR="build/emulator-test"
TMP_DIR="\${RUNNER_TEMP:-/tmp}/eldrum-emulator-test"

mkdir -p "$RESULT_DIR" "$TMP_DIR"
exec > >(tee -a "$RESULT_DIR/runner-console.txt") 2>&1

finish() {
  local status=$?
  printf 'Script exit code: %s\n' "$status" | tee "$RESULT_DIR/script-exit-code.txt"
  exit "$status"
}
trap finish EXIT

echo "Eldrum startup diagnostics"
echo "UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Runner: $(uname -a)"
echo "Modified archive: $MODIFIED_ARCHIVE"
echo "Original archive: $ORIGINAL_ARCHIVE"

if ! adb get-state >/dev/null 2>&1; then
  echo "ADB device is unavailable."
  adb devices -l > "$RESULT_DIR/adb-devices.txt" 2>&1 || true
  exit 42
fi

adb devices -l > "$RESULT_DIR/adb-devices.txt" 2>&1 || true
adb logcat -G 16M >/dev/null 2>&1 || true
adb logcat -b all -c >/dev/null 2>&1 || true

{
  echo "=== getprop ==="
  adb shell getprop
  echo "=== Android version ==="
  adb shell getprop ro.build.version.release
  adb shell getprop ro.build.version.sdk
  echo "=== Device model ==="
  adb shell getprop ro.product.model
  echo "=== Supported ABIs ==="
  adb shell getprop ro.product.cpu.abilist
  echo "=== Primary ABI ==="
  adb shell getprop ro.product.cpu.abi
  echo "=== Kernel ==="
  adb shell uname -a
} > "$RESULT_DIR/device-info.txt" 2>&1 || true

extract_splits() {
  local archive="$1"
  local out="$2"
  mkdir -p "$out"
  python3 - "$archive" "$out" <<'PY'
from pathlib import Path
import sys
import zipfile

archive, out = Path(sys.argv[1]), Path(sys.argv[2])
if not archive.is_file():
    raise SystemExit(f"Archive not found: {archive}")

with zipfile.ZipFile(archive) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"APKS outer ZIP integrity failed: {bad}")
    entries = [n for n in z.namelist() if n.lower().endswith(".apk")]
    if len(entries) != 27:
        raise SystemExit(f"Expected 27 APK splits, found {len(entries)} in {archive.name}")
    used = set()
    for name in entries:
        target = out / Path(name).name
        if target.name in used:
            raise SystemExit(f"Duplicate APK basename: {target.name}")
        used.add(target.name)
        target.write_bytes(z.read(name))
    if "base.apk" not in used:
        raise SystemExit("Required base.apk is missing")
    print(f"Extracted {len(entries)} APK splits from {archive.name}")
    print("APK files:")
    for name in sorted(used):
        print(f" - {name}")
PY
}

collect_case_state() {
  local label="$1"
  local out="$2"

  mkdir -p "$out"
  adb logcat -b all -d -v threadtime > "$out/logcat-all-buffers.txt" 2>&1 || true
  adb logcat -b crash -d -v threadtime > "$out/logcat-crash-buffer.txt" 2>&1 || true
  adb logcat -b events -d -v threadtime > "$out/logcat-events-buffer.txt" 2>&1 || true
  adb logcat -b system -d -v threadtime > "$out/logcat-system-buffer.txt" 2>&1 || true
  adb logcat -b main -d -v threadtime > "$out/logcat-main-buffer.txt" 2>&1 || true

  adb shell dumpsys activity activities > "$out/dumpsys-activity-activities.txt" 2>&1 || true
  adb shell dumpsys activity top > "$out/dumpsys-activity-top.txt" 2>&1 || true
  adb shell dumpsys package "$PACKAGE" > "$out/dumpsys-package.txt" 2>&1 || true
  adb shell dumpsys meminfo "$PACKAGE" > "$out/dumpsys-meminfo.txt" 2>&1 || true
  adb shell dumpsys dropbox --print data_app_crash > "$out/dropbox-data-app-crash.txt" 2>&1 || true
  adb shell dumpsys dropbox --print data_app_native_crash > "$out/dropbox-data-app-native-crash.txt" 2>&1 || true
  adb shell dumpsys dropbox --print system_app_crash > "$out/dropbox-system-app-crash.txt" 2>&1 || true
  adb shell ps -A > "$out/process-list.txt" 2>&1 || true
  adb shell getprop > "$out/getprop.txt" 2>&1 || true
  adb shell pm path "$PACKAGE" > "$out/installed-apk-paths.txt" 2>&1 || true
  adb shell ls -la /data/tombstones > "$out/tombstones-list-permission-check.txt" 2>&1 || true
  adb exec-out screencap -p > "$out/screenshot.png" 2> "$out/screenshot-stderr.txt" || true

  {
    echo "=== $label ==="
    echo "Captured UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "PID: $(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
    echo "Activity state:"
    cat "$out/dumpsys-activity-activities.txt"
  } > "$out/state-summary.txt" 2>&1 || true
}

run_case() {
  local label="$1"
  local archive_dir="$2"
  local out="$RESULT_DIR/$label"
  local seen_pid=0
  local pid=""

  mkdir -p "$out"
  echo "=== $label: clean install ===" | tee "$out/summary.txt"

  adb uninstall "$PACKAGE" > "$out/uninstall.txt" 2>&1 || true
  adb logcat -b all -c >/dev/null 2>&1 || true

  mapfile -t APK_FILES < <(find "$archive_dir" -maxdepth 1 -type f -name '*.apk' | sort)
  if [[ "\${#APK_FILES[@]}" -ne 27 ]]; then
    echo "Expected 27 split APK files, found \${#APK_FILES[@]}." | tee -a "$out/summary.txt"
    collect_case_state "$label" "$out"
    return 1
  fi

  if ! adb install-multiple -r -g "\${APK_FILES[@]}" > "$out/install.txt" 2>&1; then
    cat "$out/install.txt"
    echo "$label: INSTALL_FAILED" | tee -a "$out/summary.txt"
    collect_case_state "$label" "$out"
    return 1
  fi
  cat "$out/install.txt"

  adb shell pm path "$PACKAGE" > "$out/installed-apk-paths-before-launch.txt" 2>&1 || true
  adb shell dumpsys package "$PACKAGE" > "$out/package-before-launch.txt" 2>&1 || true

  adb shell log -t ELDRUM_DIAG "BEGIN_$label" >/dev/null 2>&1 || true
  adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > "$out/launch.txt" 2>&1 || true
  cat "$out/launch.txt"

  for attempt in $(seq 1 30); do
    pid="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$pid" ]]; then
      seen_pid=1
    elif [[ "$seen_pid" -eq 1 ]]; then
      break
    fi
    sleep 1
  done

  adb shell log -t ELDRUM_DIAG "END_$label" >/dev/null 2>&1 || true
  collect_case_state "$label" "$out"

  pid="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$pid" ]] && grep -Eiq "topResumedActivity=.*$PACKAGE|ResumedActivity:.*$PACKAGE|Resumed: ActivityRecord.*$PACKAGE|mResumedActivity:.*$PACKAGE" "$out/dumpsys-activity-activities.txt"; then
    echo "$label: LAUNCH_SURVIVED (PID $pid)" | tee -a "$out/summary.txt"
    return 0
  fi

  echo "$label: CRASHED_OR_EXITED (PID at end: \${pid:-none}; PID seen: $seen_pid)" | tee -a "$out/summary.txt"

  # A bugreport includes framework state and diagnostic buffers when Android permits it.
  if command -v timeout >/dev/null 2>&1; then
    timeout 120s adb bugreport "$out/bugreport.zip" > "$out/bugreport-command.txt" 2>&1 || true
  else
    adb bugreport "$out/bugreport.zip" > "$out/bugreport-command.txt" 2>&1 || true
  fi
  return 1
}

extract_splits "$ORIGINAL_ARCHIVE" "$TMP_DIR/original"
extract_splits "$MODIFIED_ARCHIVE" "$TMP_DIR/modified"

if run_case original "$TMP_DIR/original"; then
  ORIGINAL_RESULT="PASS"
else
  ORIGINAL_RESULT="FAIL"
fi

if run_case modified "$TMP_DIR/modified"; then
  MODIFIED_RESULT="PASS"
else
  MODIFIED_RESULT="FAIL"
fi

{
  echo "Emulator ABI: $(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
  echo "Original control: $ORIGINAL_RESULT"
  echo "Modified build: $MODIFIED_RESULT"
  if [[ "$ORIGINAL_RESULT" == "FAIL" && "$MODIFIED_RESULT" == "FAIL" ]]; then
    echo "Conclusion: both packages failed in this emulator environment; inspect installation and native crash logs before attributing the failure."
  elif [[ "$ORIGINAL_RESULT" == "PASS" && "$MODIFIED_RESULT" == "FAIL" ]]; then
    echo "Conclusion: original launched but modified did not; the modified package has a reproducible startup failure in this emulator."
  elif [[ "$MODIFIED_RESULT" == "PASS" ]]; then
    echo "Conclusion: modified package remained open in this emulator smoke test."
  else
    echo "Conclusion: original failed while modified passed; inspect ABI compatibility and logs."
  fi
  echo "IMPORTANT: x86_64 emulator results are diagnostic only and do not replace a test on the physical Moto G35 ARM64 device."
} | tee "$RESULT_DIR/summary.txt"

if [[ "$MODIFIED_RESULT" != "PASS" ]]; then
  exit 1
fi
