#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE_ARCHIVE="${1:?Usage: build_modified_split_package.sh source-splits.zip patch.hasm function-id output-dir hermes-decomp}"
HASM_PATH="${2:?HASM patch file is required}"
FUNCTION_ID="${3:?Target function ID is required}"
OUT_DIR="${4:-build/output}"
HERMES_BIN="${5:?hermes-decomp executable path is required}"

[[ "$FUNCTION_ID" =~ ^[0-9]+$ ]] || { echo "Invalid function ID: $FUNCTION_ID" >&2; exit 2; }
[[ -s "$HASM_PATH" ]] || { echo "Patch file missing or empty: $HASM_PATH" >&2; exit 2; }
[[ -s "$PACKAGE_ARCHIVE" ]] || { echo "Source split archive missing: $PACKAGE_ARCHIVE" >&2; exit 2; }
command -v apksigner >/dev/null
command -v zipalign >/dev/null
command -v apkanalyzer >/dev/null
command -v unzip >/dev/null
command -v zip >/dev/null

WORK_DIR="build/split-work"
EXTRACT_DIR="$WORK_DIR/source"
SIGNED_DIR="$OUT_DIR/splits"
mkdir -p "$EXTRACT_DIR" "$SIGNED_DIR" "$OUT_DIR"
unzip -tq "$PACKAGE_ARCHIVE"
unzip -q "$PACKAGE_ARCHIVE" -d "$EXTRACT_DIR"

mapfile -d '' APK_FILES < <(find "$EXTRACT_DIR" -type f -iname '*.apk' -print0 | sort -z)
if (( ${#APK_FILES[@]} < 2 )); then
  echo "::error::The supplied archive contains fewer than two APK files. This app is delivered as split APKs. Upload a ZIP/APKM containing the base APK and every config split (arm64_v8a, language, density, etc.), not just com.gotterdammerung.untold.apk."
  exit 20
fi

BASE_APK=""
APP_ID="com.gotterdammerung.untold"
for candidate in "${APK_FILES[@]}"; do
  candidate_id="$(apkanalyzer manifest application-id "$candidate" 2>/dev/null || true)"
  if [[ "$candidate_id" != "$APP_ID" ]]; then
    echo "::error::Unexpected package ID in $(basename "$candidate"): '$candidate_id' (expected $APP_ID)."
    exit 21
  fi
  if unzip -Z1 "$candidate" | grep -Fxq 'assets/index.android.bundle'; then
    if [[ -n "$BASE_APK" ]]; then
      echo "::error::More than one APK contains assets/index.android.bundle; refusing ambiguous patch target."
      exit 22
    fi
    BASE_APK="$candidate"
  fi
done

if [[ -z "$BASE_APK" ]]; then
  echo "::error::No base APK containing assets/index.android.bundle was found. The split archive is incomplete or is not the expected Eldrum package."
  exit 23
fi

echo "Input archive SHA-256:"
sha256sum "$PACKAGE_ARCHIVE"
echo "Found ${#APK_FILES[@]} APK splits. Base APK: $(basename "$BASE_APK")"

ORIGINAL_BUNDLE="$WORK_DIR/index.android.bundle"
PATCHED_BUNDLE="$WORK_DIR/index.android.bundle.patched"
unzip -p "$BASE_APK" assets/index.android.bundle > "$ORIGINAL_BUNDLE"
[[ -s "$ORIGINAL_BUNDLE" ]] || { echo "Base APK has an empty Hermes bundle." >&2; exit 24; }

echo "[1/6] Patch the selected player-health function..."
"$HERMES_BIN" patch-function "$ORIGINAL_BUNDLE" \
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
echo "Player-only guard verified in function $FUNCTION_ID."

echo "[2/6] Prepare one shared signing key for every split..."
KEYSTORE="$WORK_DIR/temporary-mod-signing.keystore"
KEY_PASS="$(openssl rand -hex 24)"
keytool -genkeypair -noprompt \
  -keystore "$KEYSTORE" -storepass "$KEY_PASS" -keypass "$KEY_PASS" \
  -alias eldrum-local-mod -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=Eldrum Untold Local Mod"

CERT_SHA=""
: > "$OUT_DIR/splits-manifest.txt"
{
  echo "Package: $APP_ID"
  echo "Source archive: $(basename "$PACKAGE_ARCHIVE")"
  echo "Source archive SHA-256: $(sha256sum "$PACKAGE_ARCHIVE" | awk '{print $1}')"
  echo "Patched Hermes function: $FUNCTION_ID"
  echo "APK split count: ${#APK_FILES[@]}"
  echo "All splits are re-signed with one shared local test certificate."
} >> "$OUT_DIR/splits-manifest.txt"

echo "[3/6] Patch the base split and retain all other split contents..."
for source_apk in "${APK_FILES[@]}"; do
  filename="$(basename "$source_apk")"
  work_apk="$WORK_DIR/$filename"
  if [[ "$source_apk" == "$BASE_APK" ]]; then
    python3 scripts/repack_apk.py "$source_apk" "$PATCHED_BUNDLE" "$work_apk" \
      --asset-path assets/index.android.bundle
  else
    cp "$source_apk" "$work_apk"
  fi

  echo "[4/6] Align and sign $filename..."
  aligned="$WORK_DIR/aligned-$filename"
  signed="$SIGNED_DIR/$filename"
  zipalign -p -f 4 "$work_apk" "$aligned"
  zipalign -c -v 4 "$aligned" > "$WORK_DIR/zipalign-$filename.txt"
  apksigner sign --ks "$KEYSTORE" --ks-key-alias eldrum-local-mod \
    --ks-pass "pass:$KEY_PASS" --key-pass "pass:$KEY_PASS" \
    --out "$signed" "$aligned"
  unzip -tq "$signed"
  apksigner verify --verbose --print-certs "$signed" > "$WORK_DIR/signature-$filename.txt"
  this_cert="$(awk '/Signer #1 certificate SHA-256 digest:/ {print $NF; exit}' "$WORK_DIR/signature-$filename.txt")"
  [[ -n "$this_cert" ]] || { echo "Could not read signer certificate from $filename" >&2; exit 25; }
  if [[ -z "$CERT_SHA" ]]; then
    CERT_SHA="$this_cert"
  elif [[ "$CERT_SHA" != "$this_cert" ]]; then
    echo "::error::Split APKs were not signed by the same certificate."
    exit 26
  fi
  signed_id="$(apkanalyzer manifest application-id "$signed")"
  [[ "$signed_id" == "$APP_ID" ]] || { echo "Package ID changed in $filename" >&2; exit 27; }
  echo "$filename | package=$signed_id | signer_sha256=$this_cert" >> "$OUT_DIR/splits-manifest.txt"
done

echo "[5/6] Verify the complete split set..."
SIGNED_COUNT="$(find "$SIGNED_DIR" -maxdepth 1 -type f -iname '*.apk' | wc -l)"
[[ "$SIGNED_COUNT" -eq "${#APK_FILES[@]}" ]] || { echo "Expected ${#APK_FILES[@]} signed splits, found $SIGNED_COUNT" >&2; exit 28; }
BASE_NAME="$(basename "$BASE_APK")"
[[ -s "$SIGNED_DIR/$BASE_NAME" ]] || { echo "Signed base APK missing" >&2; exit 29; }

cat > "$OUT_DIR/INSTALL-NOTES.txt" <<EOF
Eldrum: Untold - experimental player-only infinite-health split package

This output contains $SIGNED_COUNT APK split files. Do not install only the base APK.
Extract the ZIP, open SAI or InstallWithOptions, select ALL .apk files from the splits folder
in one installation session, then confirm. Do not select manifest.json or icon files.

Every split is signed with the same temporary local test certificate. This package cannot
update the developer-signed original app. Back up game progress before uninstalling the
original. The bytecode patch passed static checks, but gameplay still requires device testing.
EOF

echo "Package ID: $APP_ID" > "$OUT_DIR/application-id.txt"
echo "Shared signer certificate SHA-256: $CERT_SHA" > "$OUT_DIR/signature-verification.txt"
sha256sum "$SIGNED_DIR"/*.apk > "$OUT_DIR/modified-splits-sha256.txt"

echo "[6/6] Create a ZIP containing every signed split..."
(
  cd "$SIGNED_DIR"
  zip -q -j "$OLDPWD/$OUT_DIR/eldrum-untold-infinite-health-splits.zip" ./*.apk
)

rm -f "$KEYSTORE"
echo "Signed split set ready: $OUT_DIR/eldrum-untold-infinite-health-splits.zip"
echo "Signed APK files: $SIGNED_COUNT"
