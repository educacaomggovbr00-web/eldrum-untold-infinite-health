#!/usr/bin/env bash
set -Eeuo pipefail

APK_PATH="${1:?Usage: build_modified_apk.sh original.apk patch.hasm function-id output-dir hermes-decomp}"
HASM_PATH="${2:?HASM patch file is required}"
FUNCTION_ID="${3:?Target function ID is required}"
OUT_DIR="${4:-build/output}"
HERMES_BIN="${5:?hermes-decomp executable path is required}"

[[ "$FUNCTION_ID" =~ ^[0-9]+$ ]] || { echo "Invalid function ID: $FUNCTION_ID" >&2; exit 2; }
[[ -s "$HASM_PATH" ]] || { echo "Patch file missing or empty: $HASM_PATH" >&2; exit 2; }

SOURCE_BUNDLE="build/unpacked/assets/index.android.bundle"
PATCHED_BUNDLE="build/patched/index.android.bundle"
UNALIGNED_APK="$OUT_DIR/eldrum-untold-infinite-health-unaligned.apk"
ALIGNED_APK="$OUT_DIR/eldrum-untold-infinite-health-aligned.apk"
FINAL_APK="$OUT_DIR/eldrum-untold-infinite-health.apk"

mkdir -p "$OUT_DIR" build/patched "$(dirname "$SOURCE_BUNDLE")"
if [[ ! -s "$SOURCE_BUNDLE" ]]; then
  echo "Extracting the original Hermes bundle directly for build-only workflow..."
  unzip -p "$APK_PATH" assets/index.android.bundle > "$SOURCE_BUNDLE"
fi
[[ -s "$SOURCE_BUNDLE" ]] || { echo "Original Hermes bundle not found in APK." >&2; exit 2; }

echo "[1/5] Patch only the confirmed player-health function..."
"$HERMES_BIN" patch-function "$SOURCE_BUNDLE" \
  --function "$FUNCTION_ID" --hasm "$HASM_PATH" -o "$PATCHED_BUNDLE"
"$HERMES_BIN" info "$PATCHED_BUNDLE" > "$OUT_DIR/patched-hermes-info.txt"
"$HERMES_BIN" emit-hasm "$PATCHED_BUNDLE" --function "$FUNCTION_ID" \
  -o "$OUT_DIR/function-$FUNCTION_ID-after-patch.hasm"

PATCHED_ASM="$OUT_DIR/function-$FUNCTION_ID-after-patch.hasm"
grep -F 'LoadConstString r11, "_id"' "$PATCHED_ASM" >/dev/null
grep -F 'GetByVal r12, r6, r11' "$PATCHED_ASM" >/dev/null
grep -F 'LoadConstString r13, "player"' "$PATCHED_ASM" >/dev/null
grep -F 'JStrictNotEqual L54, r12, r13' "$PATCHED_ASM" >/dev/null
grep -F 'JGreaterEqual L54, r9, r0' "$PATCHED_ASM" >/dev/null
echo "Player-only guard verified in patched function $FUNCTION_ID."

echo "[2/5] Replace only assets/index.android.bundle in a copy of the APK..."
python3 scripts/repack_apk.py \
  "$APK_PATH" "$PATCHED_BUNDLE" "$UNALIGNED_APK" \
  --asset-path assets/index.android.bundle

echo "[3/5] Align APK..."
zipalign -p -f 4 "$UNALIGNED_APK" "$ALIGNED_APK"
zipalign -c -v 4 "$ALIGNED_APK" > "$OUT_DIR/zipalign-check.txt"

echo "[4/5] Sign with an ephemeral local test key..."
KEYSTORE="$OUT_DIR/temporary-mod-signing.keystore"
KEY_PASS="$(openssl rand -hex 24)"
keytool -genkeypair -noprompt \
  -keystore "$KEYSTORE" \
  -storepass "$KEY_PASS" \
  -keypass "$KEY_PASS" \
  -alias eldrum-local-mod \
  -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=Eldrum Untold Local Mod"

apksigner sign \
  --ks "$KEYSTORE" \
  --ks-key-alias eldrum-local-mod \
  --ks-pass "pass:$KEY_PASS" \
  --key-pass "pass:$KEY_PASS" \
  --out "$FINAL_APK" \
  "$ALIGNED_APK"

echo "[5/5] Verify APK structure, package ID, and signature..."
unzip -tq "$FINAL_APK"
apksigner verify --verbose --print-certs "$FINAL_APK" \
  > "$OUT_DIR/signature-verification.txt"
apkanalyzer manifest application-id "$FINAL_APK" \
  > "$OUT_DIR/application-id.txt"

sha256sum "$FINAL_APK" > "$OUT_DIR/modified-apk-sha256.txt"
rm -f "$KEYSTORE" "$UNALIGNED_APK" "$ALIGNED_APK"

cat > "$OUT_DIR/INSTALL-NOTES.txt" <<'EOF'
This is a locally rebuilt and re-signed test APK.
Its signing certificate differs from the developer's original APK.
Android will not install it as an in-place update over the original signed app.
Back up game progress before uninstalling the original app.
Install only after reviewing the analysis and testing the patch.
EOF

echo "Modified APK created at: $FINAL_APK"
