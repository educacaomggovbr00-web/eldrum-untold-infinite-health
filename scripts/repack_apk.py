#!/usr/bin/env python3
"""Replace assets in an APK copy while preserving ZIP entry metadata."""
from pathlib import Path
import argparse
import hashlib
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("original_apk", type=Path)
parser.add_argument("replacement_asset", type=Path)
parser.add_argument("output_apk", type=Path)
parser.add_argument("--asset-path", default="assets/index.android.bundle")
parser.add_argument(
    "--pairip-dex-patch",
    type=Path,
    help="Patched classes2.dex whose PairIP signer pin matches the local build key",
)
args = parser.parse_args()

if not args.original_apk.is_file() or not args.replacement_asset.is_file():
    parser.error("original APK and replacement asset must exist")

replacements = {
    args.asset_path: args.replacement_asset.read_bytes(),
}
if args.pairip_dex_patch is not None:
    if not args.pairip_dex_patch.is_file():
        parser.error(f"PairIP DEX patch does not exist: {args.pairip_dex_patch}")
    replacements["classes2.dex"] = args.pairip_dex_patch.read_bytes()

replaced = set()
count = 0
with zipfile.ZipFile(args.original_apk, "r") as src:
    missing = set(replacements) - set(src.namelist())
    if missing:
        raise SystemExit("APK is missing required replacement entries: " + ", ".join(sorted(missing)))
    with zipfile.ZipFile(args.output_apk, "w") as dst:
        dst.comment = src.comment
        for info in src.infolist():
            data = replacements.get(info.filename)
            if data is None:
                data = src.read(info.filename)
            else:
                replaced.add(info.filename)
            dst.writestr(info, data)
            count += 1

if replaced != set(replacements):
    raise SystemExit("Not all requested APK replacements were written")

with zipfile.ZipFile(args.output_apk, "r") as result:
    bad = result.testzip()
    if bad:
        raise SystemExit(f"ZIP integrity check failed at {bad}")
    for name, expected in replacements.items():
        if result.read(name) != expected:
            raise SystemExit(f"Repacked APK does not contain the exact replacement for {name}")

print(f"Repacked {count} entries; replaced {', '.join(sorted(replacements))}")
for name, data in replacements.items():
    print(f"{name} SHA-256: {hashlib.sha256(data).hexdigest()}")
