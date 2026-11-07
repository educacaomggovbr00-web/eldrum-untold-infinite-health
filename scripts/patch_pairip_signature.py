#!/usr/bin/env python3
"""Pin PairIP's existing accepted signer digest to this build's signing certificate.

The game performs a SHA-256/Base64 comparison against this value at startup.
This updates only the expected signer digest; the runtime signature comparison
stays enabled. The replacement is kept inside the same DEX string-table sort slot.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import struct
import zlib

OLD = "3sz2NwrALzmFf9KAFXvqlW6wT3LCssbhnpwzVthF8iw="
TARGET_CLASS = "Lcom/pairip/SignatureCheck;"
EXPECTED_FIELDS = {
    "expectedLegacyUpgradedSignature",
    "expectedSignature",
    "expectedTestSignature",
}

def read_uleb(data: bytes, pos: int):
    value = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7
        if shift > 35:
            raise ValueError("Invalid ULEB128")

def read_string(data: bytes, off: int):
    utf16_len, pos = read_uleb(data, off)
    end = data.index(0, pos)
    return data[pos:end].decode("utf-8", "replace"), pos, end, utf16_len

def verify_target_fields(data: bytes, digest_index: int, strings, types):
    _, _, _, _, _, _, field_count, field_off, _, _, class_count, class_off = struct.unpack_from(
        "<12I", data, 56
    )
    fields = []
    for i in range(field_count):
        class_idx, type_idx, name_idx = struct.unpack_from("<HHI", data, field_off + i * 8)
        fields.append((types[class_idx], strings[name_idx]))

    refs = []
    for i in range(class_count):
        class_idx, _, _, _, _, _, class_data_off, static_values_off = struct.unpack_from(
            "<8I", data, class_off + i * 32
        )
        if not class_data_off or not static_values_off:
            continue
        class_name = types[class_idx]
        pos = class_data_off
        static_count, pos = read_uleb(data, pos)
        instance_count, pos = read_uleb(data, pos)
        direct_count, pos = read_uleb(data, pos)
        virtual_count, pos = read_uleb(data, pos)
        static_ids = []
        field_idx = 0
        for _ in range(static_count):
            diff, pos = read_uleb(data, pos)
            field_idx += diff
            _, pos = read_uleb(data, pos)  # access flags
            static_ids.append(field_idx)
        if class_name != TARGET_CLASS:
            continue
        value_count, value_pos = read_uleb(data, static_values_off)
        if value_count != len(static_ids):
            raise ValueError("Unexpected SignatureCheck static-value count")
        for i, field_id in enumerate(static_ids):
            value_header = data[value_pos]
            value_type = value_header & 0x1f
            arg = value_header >> 5
            value_pos += 1
            value = int.from_bytes(data[value_pos:value_pos + arg + 1], "little")
            value_pos += arg + 1
            if value_type == 0x17 and value == digest_index:
                refs.append(fields[field_id][1])
    if sorted(refs) != sorted(EXPECTED_FIELDS):
        raise ValueError(
            "Expected exactly the three PairIP signer fields to reference the pinned digest; "
            f"found {refs!r}"
        )

def patch(path: Path, new_digest: str):
    data = bytearray(path.read_bytes())
    if data[:4] != b"dex\n":
        raise ValueError(f"Not a DEX file: {path}")
    try:
        digest_bytes = base64.b64decode(new_digest, validate=True)
    except Exception as exc:
        raise ValueError("Signer digest is not valid Base64") from exc
    if len(digest_bytes) != 32 or len(new_digest) != len(OLD):
        raise ValueError("Signer digest must be SHA-256 encoded as 44 Base64 characters")

    string_count, string_off = struct.unpack_from("<II", data, 56)
    strings = []
    found = []
    positions = []
    for i in range(string_count):
        off = struct.unpack_from("<I", data, string_off + i * 4)[0]
        value, start, end, utf16_len = read_string(data, off)
        strings.append(value)
        positions.append((start, end, utf16_len))
        if value == OLD:
            found.append(i)
    if found != [970]:
        raise ValueError(f"Unexpected PairIP pinned digest references: {found!r}")
    index = found[0]
    previous = strings[index - 1]
    following = strings[index + 1]
    if previous != "0" or following != ":":
        raise ValueError("PairIP DEX string-table layout differs from the verified version")
    if not (previous < new_digest < following):
        raise ValueError(
            "Signer digest must begin with a digit to preserve DEX string_ids ordering; "
            "generate a different signing key"
        )
    start, end, utf16_len = positions[index]
    if utf16_len != len(OLD) or end - start != len(OLD):
        raise ValueError("Pinned digest string has an unexpected encoded length")
    verify_target_fields(data, index, strings, _types_from_dex(data, strings))
    data[start:end] = new_digest.encode("ascii")
    data[12:32] = hashlib.sha1(data[32:]).digest()
    struct.pack_into("<I", data, 8, zlib.adler32(data[12:]) & 0xffffffff)
    path.write_bytes(data)

    check = path.read_bytes()
    check_count, check_off = struct.unpack_from("<II", check, 56)
    new_positions = []
    for i in range(check_count):
        off = struct.unpack_from("<I", check, check_off + i * 4)[0]
        value, _, _, _ = read_string(check, off)
        if value == new_digest:
            new_positions.append(i)
    if new_positions != [index]:
        raise ValueError("Patched PairIP signer digest could not be read back")
    if check[12:32] != hashlib.sha1(check[32:]).digest():
        raise ValueError("DEX SHA-1 signature verification failed")
    if struct.unpack_from("<I", check, 8)[0] != (zlib.adler32(check[12:]) & 0xffffffff):
        raise ValueError("DEX Adler-32 checksum verification failed")
    return index

def _types_from_dex(data: bytes, strings):
    _, _, type_count, type_off = struct.unpack_from("<4I", data, 56)
    types = []
    for i in range(type_count):
        string_idx = struct.unpack_from("<I", data, type_off + i * 4)[0]
        types.append(strings[string_idx])
    return types

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dex", type=Path)
    parser.add_argument("signer_sha256_base64")
    args = parser.parse_args()
    index = patch(args.dex, args.signer_sha256_base64)
    print(
        "Updated PairIP SignatureCheck signer pin "
        f"in DEX string_id[{index}] to {args.signer_sha256_base64}"
    )
