#!/usr/bin/env bash
set -Eeuo pipefail

APK_PATH="${1:?Usage: analyze_apk.sh /path/to/app.apk [output-dir]}"
OUT_DIR="${2:-build}"
: "${APKTOOL_JAR:?APKTOOL_JAR is required}"
: "${JADX_BIN:?JADX_BIN is required}"
: "${HERMES_BIN:?HERMES_BIN is required}"

mkdir -p "$OUT_DIR/reports" "$OUT_DIR/unpacked" "$OUT_DIR/decompiled"
REPORT="$OUT_DIR/reports"
META="$REPORT/apk-metadata.txt"

{
  echo "APK file: $(basename "$APK_PATH")"
  echo "Size bytes: $(stat -c '%s' "$APK_PATH")"
  echo "SHA-256: $(sha256sum "$APK_PATH" | awk '{print $1}')"
  echo "ZIP integrity: OK"
  echo
  if [[ -n "${APKANALYZER_BIN:-}" ]] && command -v "$APKANALYZER_BIN" >/dev/null 2>&1; then
    echo "Application ID: $("$APKANALYZER_BIN" manifest application-id "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Version name: $("$APKANALYZER_BIN" manifest version-name "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Version code: $("$APKANALYZER_BIN" manifest version-code "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Min SDK: $("$APKANALYZER_BIN" manifest min-sdk "$APK_PATH" 2>/dev/null || echo unknown)"
    echo "Target SDK: $("$APKANALYZER_BIN" manifest target-sdk "$APK_PATH" 2>/dev/null || echo unknown)"
  else
    echo "apkanalyzer: not available"
  fi
} > "$META"

if [[ -n "${APKSIGNER_BIN:-}" ]] && command -v "$APKSIGNER_BIN" >/dev/null 2>&1; then
  "$APKSIGNER_BIN" verify --verbose --print-certs "$APK_PATH" \
    > "$REPORT/signature-and-certificates.txt" 2>&1 || true
fi

echo "[1/4] Apktool decode..."
if ! java -jar "$APKTOOL_JAR" d -f "$APK_PATH" -o "$OUT_DIR/apktool" \
  > "$REPORT/apktool.log" 2>&1; then
  tail -n 80 "$REPORT/apktool.log" || true
  echo "Apktool decode failed; see apktool.log" >> "$META"
fi

echo "[2/4] JADX decompile..."
if ! "$JADX_BIN" -d "$OUT_DIR/jadx" "$APK_PATH" \
  > "$REPORT/jadx.log" 2>&1; then
  echo "JADX exited with a non-zero status; partial output may still be useful." >> "$META"
fi

echo "[3/4] Extract APK assets and inspect Hermes bundles..."
unzip -q "$APK_PATH" -d "$OUT_DIR/unpacked"

mapfile -d '' BUNDLES < <(
  find "$OUT_DIR/unpacked" -type f \
    \( -name 'index.android.bundle' -o -name '*.hbc' -o -name '*.bundle' \) \
    -print0
)

printf 'Hermes candidates found: %s\n' "${#BUNDLES[@]}" >> "$META"

if (("${#BUNDLES[@]}" == 0)); then
  echo "No *.hbc, *.bundle or index.android.bundle file was found in the APK." \
    > "$REPORT/hermes-info.txt"
fi

INDEX=0
for BUNDLE in "${BUNDLES[@]}"; do
  INDEX=$((INDEX + 1))
  NAME="$(basename "$BUNDLE")"
  SAFE_NAME="$(printf '%s' "$NAME" | tr -cs 'A-Za-z0-9._-' '_')"
  INFO="$REPORT/hermes-${INDEX}-${SAFE_NAME}.txt"
  JS_OUT="$OUT_DIR/decompiled/${INDEX}-${SAFE_NAME}.js"

  {
    echo "Source: $BUNDLE"
    echo "Bytes: $(stat -c '%s' "$BUNDLE")"
    echo
    "$HERMES_BIN" info "$BUNDLE"
  } > "$INFO" 2>&1 || {
    echo "Hermes info failed for this candidate; it may not be Hermes bytecode." >> "$INFO"
    continue
  }

  strings -a "$BUNDLE" >> "$OUT_DIR/raw-bundle-strings.txt" || true

  # The first analysis already decompiled the full bundle. This pass targets
  # modules confirmed to contain Actor, Character, Npc, combat, and event dispatch.
  "$HERMES_BIN" modules "$BUNDLE" --limit 4000 \
    > "$REPORT/hermes-modules-${INDEX}.txt" 2>&1 || true
  "$HERMES_BIN" dump "$BUNDLE" --kind functions --json \
    > "$REPORT/hermes-functions-${INDEX}.json" 2>&1 || true

  if ! "$HERMES_BIN" decompile "$BUNDLE" \
      --modules 2017,2031,2052,2059,2202 --deep -o "$JS_OUT" \
    > "$REPORT/hermes-decompile-${INDEX}.log" 2>&1; then
    echo "Hermes decompilation failed; inspect the corresponding log." >> "$INFO"
  fi
done

echo "[4/4] Search likely player-health and damage references..."
python3 scripts/summarize_candidates.py "$OUT_DIR"

{
  echo
  echo "JADX source files: $(find "$OUT_DIR/jadx" -type f -name '*.java' 2>/dev/null | wc -l)"
  echo "Hermes decompiled files: $(find "$OUT_DIR/decompiled" -type f -name '*.js' 2>/dev/null | wc -l)"
  echo "Candidate report: health-candidates.txt"
} >> "$META"

echo "Analysis finished. Reports are in $REPORT"
