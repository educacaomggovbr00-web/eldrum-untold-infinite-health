#!/usr/bin/env python3
"""Preserve original ZIP CRC metadata for PairIP-sensitive APK entries.

The Hermes bundle and classes2.dex are patched, but PairIP checks ZIP CRC
metadata at runtime. This tool restores the source values in local headers and
the central directory after zipalign, and before apksigner signs the APK.
"""
from __future__ import annotations

import argparse
import struct
import zipfile
import zlib
from pathlib import Path

LOCAL_SIG = b"PK\x03\x04"
CENTRAL_SIG = b"PK\x01\x02"


def _name(raw: bytes, flags: int) -> str:
    return raw.decode("utf-8" if flags & 0x800 else "cp437")


def patch(apk: Path, crcs: dict[str, int]) -> None:
    with apk.open("r+b") as fp:
        endrec = zipfile._EndRecData(fp)
        if endrec is None:
            raise SystemExit(f"No ZIP end record found: {apk}")
        cd_offset = endrec[zipfile._ECD_OFFSET]
        cd_size = endrec[zipfile._ECD_SIZE]
        count = endrec[zipfile._ECD_ENTRIES_TOTAL]
        found: set[str] = set()

        with zipfile.ZipFile(apk, "r") as zf:
            for info in zf.infolist():
                if info.filename not in crcs:
                    continue
                fp.seek(info.header_offset)
                header = fp.read(30)
                if len(header) != 30 or header[:4] != LOCAL_SIG:
                    raise SystemExit(f"Invalid local ZIP header: {info.filename}")
                flags = struct.unpack_from("<H", header, 6)[0]
                name_len = struct.unpack_from("<H", header, 26)[0]
                raw_name = fp.read(name_len)
                if _name(raw_name, flags) != info.filename:
                    raise SystemExit(f"Local ZIP filename mismatch: {info.filename}")
                fp.seek(info.header_offset + 14)
                fp.write(struct.pack("<I", crcs[info.filename]))
                found.add(info.filename)
        if found != set(crcs):
            raise SystemExit("Missing local ZIP entries: " + ", ".join(sorted(set(crcs) - found)))

        position = cd_offset
        central_found: set[str] = set()
        for _ in range(count):
            fp.seek(position)
            fixed = fp.read(46)
            if len(fixed) != 46 or fixed[:4] != CENTRAL_SIG:
                raise SystemExit(f"Invalid central-directory record at {position}")
            flags = struct.unpack_from("<H", fixed, 8)[0]
            name_len, extra_len, comment_len = struct.unpack_from("<HHH", fixed, 28)
            raw_name = fp.read(name_len)
            entry_name = _name(raw_name, flags)
            if entry_name in crcs:
                fp.seek(position + 16)
                fp.write(struct.pack("<I", crcs[entry_name]))
                central_found.add(entry_name)
            position += 46 + name_len + extra_len + comment_len
        if central_found != set(crcs):
            raise SystemExit("Missing central ZIP entries: " + ", ".join(sorted(set(crcs) - central_found)))
        if position > cd_offset + cd_size:
            raise SystemExit("Central-directory size is inconsistent")


def verify(apk: Path, reference: Path, targets: list[str]) -> None:
    with zipfile.ZipFile(reference, "r") as original, zipfile.ZipFile(apk, "r") as patched:
        original_names = set(original.namelist())
        patched_names = set(patched.namelist())
        missing = original_names - patched_names - {"stamp-cert-sha256"}
        if missing:
            raise SystemExit("APK lost original entries: " + ", ".join(sorted(missing)))
        expected = {}
        for name in targets:
            if name not in original_names or name not in patched_names:
                raise SystemExit(f"Missing PairIP CRC target: {name}")
            expected[name] = original.getinfo(name).CRC
            if patched.getinfo(name).CRC != expected[name]:
                raise SystemExit(f"Original CRC metadata not retained: {name}")

        # Read/decompress every entry, but skip CRC comparison only for the
        # two intentionally modified payloads whose original CRC is retained.
        for info in patched.infolist():
            with patched.open(info, "r") as stream:
                stream._expected_crc = None
                payload = stream.read()
            if len(payload) != info.file_size:
                raise SystemExit(f"Uncompressed size mismatch: {info.filename}")
            actual = zlib.crc32(payload) & 0xFFFFFFFF
            if info.filename not in expected and actual != info.CRC:
                raise SystemExit(f"Unexpected CRC mismatch in untouched entry: {info.filename}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=Path)
    parser.add_argument("reference_apk", type=Path)
    parser.add_argument("--entry", action="append", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    with zipfile.ZipFile(args.reference_apk, "r") as original:
        crcs = {name: original.getinfo(name).CRC for name in args.entry}
    if args.verify:
        verify(args.apk, args.reference_apk, args.entry)
        print("PairIP ZIP CRC metadata and APK ZIP structure verified.")
    else:
        patch(args.apk, crcs)
        verify(args.apk, args.reference_apk, args.entry)
        for name, crc in crcs.items():
            print(f"Preserved original CRC {crc:08x}: {name}")


if __name__ == "__main__":
    main()
