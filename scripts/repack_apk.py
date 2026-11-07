#!/usr/bin/env python3
"""Replace one asset in an APK copy while preserving ZIP entry metadata."""

from pathlib import Path
import argparse
import hashlib
import sys
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("original_apk", type=Path)
parser.add_argument("replacement_asset", type=Path)
parser.add_argument("output_apk", type=Path)
parser.add_argument("--asset-path", default="assets/index.android.bundle")
args = parser.parse_args()

if not args.original_apk.is_file() or not args.replacement_asset.is_file():
    parser.error("original APK and replacement asset must exist")

replacement = args.replacement_asset.read_bytes()
replaced = False
count = 0

with zipfile.ZipFile(args.original_apk, "r") as src:
    if args.asset_path not in src.namelist():
        raise SystemExit(f"APK does not contain {args.asset_path!r}")
    with zipfile.ZipFile(args.output_apk, "w") as dst:
        dst.comment = src.comment
        for info in src.infolist():
            data = replacement if info.filename == args.asset_path else src.read(info.filename)
            if info.filename == args.asset_path:
                replaced = True
            dst.writestr(info, data)
            count += 1

if not replaced:
    raise SystemExit("Asset replacement did not occur")

with zipfile.ZipFile(args.output_apk, "r") as result:
    bad = result.testzip()
    if bad:
        raise SystemExit(f"ZIP integrity check failed at {bad}")
    if result.read(args.asset_path) != replacement:
        raise SystemExit("Repacked APK does not contain the exact patched bundle")

print(f"Repacked {count} entries; replaced {args.asset_path}")
print(f"Patched asset SHA-256: {hashlib.sha256(replacement).hexdigest()}")
