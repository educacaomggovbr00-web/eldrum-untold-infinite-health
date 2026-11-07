#!/usr/bin/env bash
set -Eeuo pipefail

APK_PATH="${1:?Usage: analyze_apk.sh /path/to/app.apk [output-dir]}"
OUT_DIR="${2:-build}"
: "${APKTOOL_JAR:?APKTOOL_JAR is required}"
: "${JADX_BIN:?JADX_BIN is required}"
: "${HERMES_BIN:?HERMES_BIN is required}"

mkdir -p "$OUT_DIR/reports" "$OUT_DIR/unpacked" "$OUT_DIR/tmp" "$OUT_DIR/hasm"
REPORT="$OUT_DIR/reports"
META="$REPORT/apk-metadata.txt"
BUNDLE="$OUT_DIR/unpacked/assets/index.android.bundle"

{
  echo "APK file: $(basename "$APK_PATH")"
  echo "Size bytes: $(stat -c '%s' "$APK_PATH")"
  echo "SHA-256: $(sha256sum "$APK_PATH" | awk '{print $1}')"
  echo "ZIP integrity: OK"
  if [[ -n "${APKANALYZER_BIN:-}" ]] && command -v "$APKANALYZER_BIN" >/dev/null 2>&1; then
    echo "Application ID: $("$APKANALYZER_BIN" manifest application-id "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Version name: $("$APKANALYZER_BIN" manifest version-name "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Version code: $("$APKANALYZER_BIN" manifest version-code "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Min SDK: $("$APKANALYZER_BIN" manifest min-sdk "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Target SDK: $("$APKANALYZER_BIN" manifest target-sdk "$APK_PATH" 2>/dev/null || echo unknown)"
  fi
} > "$META"

if [[ -n "${APKSIGNER_BIN:-}" ]] && command -v "$APKSIGNER_BIN" >/dev/null 2>&1; then
  "$APKSIGNER_BIN" verify --verbose --print-certs "$APK_PATH" \
    > "$REPORT/signature-and-certificates.txt" 2>&1 || true
fi

echo "[1/5] Decode manifest/resources with Apktool..."
if ! java -jar "$APKTOOL_JAR" d -f "$APK_PATH" -o "$OUT_DIR/apktool" \
  > "$REPORT/apktool.log" 2>&1; then
  tail -n 60 "$REPORT/apktool.log" || true
  echo "Apktool decode had errors; see apktool.log" >> "$META"
fi

echo "[2/5] Inspect DEX with JADX..."
if ! "$JADX_BIN" -d "$OUT_DIR/jadx" "$APK_PATH" \
  > "$REPORT/jadx.log" 2>&1; then
  echo "JADX returned a non-zero status; partial output may be useful." >> "$META"
fi

echo "[3/5] Extract APK and identify Hermes bundle..."
unzip -q "$APK_PATH" -d "$OUT_DIR/unpacked"
if [[ ! -s "$BUNDLE" ]]; then
  find "$OUT_DIR/unpacked" -type f \( -name '*.hbc' -o -name '*.bundle' \) -print \
    > "$REPORT/bundle-candidates.txt"
  echo "Expected assets/index.android.bundle not found; inspect bundle-candidates.txt." >> "$META"
  exit 2
fi

{
  echo "Bundle path: assets/index.android.bundle"
  echo "Bundle bytes: $(stat -c '%s' "$BUNDLE")"
  "$HERMES_BIN" info "$BUNDLE"
} > "$REPORT/hermes-info.txt" 2>&1

echo "[4/5] Find bytecode functions referencing player-health properties..."
for TERM in health alive maxHealth changeHealth _id player; do
  "$HERMES_BIN" xref "$BUNDLE" --query "$TERM" --json \
    > "$OUT_DIR/tmp/xref-$TERM.json" 2> "$REPORT/xref-$TERM.log" || {
      echo "{\"query\":\"$TERM\",\"count\":0,\"results\":[]}" > "$OUT_DIR/tmp/xref-$TERM.json"
    }
done

"$HERMES_BIN" dump "$BUNDLE" --kind functions --json \
  > "$OUT_DIR/tmp/functions.json" 2> "$REPORT/functions-dump.log"

python3 scripts/summarize_candidates.py "$OUT_DIR" "$OUT_DIR/tmp/functions.json"

echo "[5/5] Export HASM for candidate functions..."
if [[ -s "$OUT_DIR/tmp/selected-function-ids.txt" ]]; then
  while IFS= read -r FUNCTION_ID; do
    [[ "$FUNCTION_ID" =~ ^[0-9]+$ ]] || continue
    "$HERMES_BIN" emit-hasm "$BUNDLE" --function "$FUNCTION_ID" \
      -o "$OUT_DIR/hasm/function-$FUNCTION_ID.hasm" \
      2> "$REPORT/emit-hasm-$FUNCTION_ID.log" || true
  done < "$OUT_DIR/tmp/selected-function-ids.txt"
else
  echo "No candidate function IDs selected; no HASM files exported." >> "$META"
fi

{
  echo
  echo "Hermes candidate function IDs: $(wc -l < "$OUT_DIR/tmp/selected-function-ids.txt" 2>/dev/null || echo 0)"
  echo "HASM exports: $(find "$OUT_DIR/hasm" -type f -name '*.hasm' 2>/dev/null | wc -l)"
  echo "Candidate report: health-candidates.txt"
} >> "$META"

cp "$OUT_DIR"/hasm/*.hasm "$REPORT/" 2>/dev/null || true
echo "Focused analysis finished. Reports are in $REPORT"
