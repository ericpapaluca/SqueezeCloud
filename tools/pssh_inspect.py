#!/usr/bin/env python3
"""Inspect a Widevine PSSH box.

Reads the base64 PSSH that the SqueezeCloud plugin writes to
<cachedir>/scdrm/<trackId>_<preset>_<proto>.pssh (debug mode) and prints its
structure: the DRM system UUID, PSSH box version, any key IDs, and — for
Widevine — the fields inside the embedded protobuf (key_id, provider,
content_id).

This is a *read-only* decoder. It parses public manifest metadata and does not
contact any license server, generate a license challenge, or produce keys.

Usage:
    python3 pssh_inspect.py <file.pssh>          # read base64 from a file
    python3 pssh_inspect.py --b64 'AAAA...'      # base64 on the command line
    echo 'AAAA...' | python3 pssh_inspect.py     # base64 on stdin
"""

import argparse
import base64
import sys

# Known DRM system IDs (16-byte, hex).
SYSTEMS = {
    "edef8ba979d64acea3c827dcd51d21ed": "Widevine",
    "9a04f07998404286ab92e65be0885f95": "PlayReady",
    "1077efecc0b24d02ace33c1e52e2fb4b": "W3C Common (cenc)",
    "94ce86fb07ff4f43adb893d2fa968ca2": "FairPlay",
}
WIDEVINE_SYSTEM_ID = "edef8ba979d64acea3c827dcd51d21ed"


def read_b64() -> str:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", help="file containing the base64 PSSH")
    ap.add_argument("--b64", help="base64 PSSH string")
    args = ap.parse_args()

    if args.b64:
        return args.b64.strip()
    if args.path:
        with open(args.path, "r") as fh:
            return fh.read().strip()
    data = sys.stdin.read().strip()
    if not data:
        ap.error("no PSSH supplied (give a file, --b64, or pipe it on stdin)")
    return data


def hexfmt(b: bytes) -> str:
    return b.hex()


def uuid_dashed(hex16: str) -> str:
    if len(hex16) != 32:
        return hex16
    return "%s-%s-%s-%s-%s" % (hex16[0:8], hex16[8:12], hex16[12:16],
                               hex16[16:20], hex16[20:32])


def parse_pssh_box(raw: bytes):
    """Parse an ISO-BMFF 'pssh' box. Returns (system_hex, version, kids, data)."""
    if len(raw) < 32:
        raise ValueError("too short to be a pssh box (%d bytes)" % len(raw))
    size = int.from_bytes(raw[0:4], "big")
    box_type = raw[4:8]
    if box_type != b"pssh":
        raise ValueError("not a pssh box (type=%r)" % box_type)
    version = raw[8]
    # raw[9:12] = flags
    system_id = raw[12:28]
    off = 28

    kids = []
    if version > 0:
        kid_count = int.from_bytes(raw[off:off + 4], "big")
        off += 4
        for _ in range(kid_count):
            kids.append(raw[off:off + 16])
            off += 16

    data_size = int.from_bytes(raw[off:off + 4], "big")
    off += 4
    data = raw[off:off + data_size]
    return system_id.hex(), version, kids, data, size


def read_varint(buf: bytes, i: int):
    shift = 0
    result = 0
    while i < len(buf):
        b = buf[i]
        result |= (b & 0x7F) << shift
        i += 1
        if not (b & 0x80):
            return result, i
        shift += 7
    raise ValueError("truncated varint")


def parse_widevine_pb(data: bytes):
    """Minimal protobuf walk over WidevinePsshData.

    Fields of interest: 2 = key_id (repeated bytes), 3 = provider (string),
    4 = content_id (bytes), 1 = algorithm (varint), 6 = policy (string).
    """
    fields = {}
    i = 0
    while i < len(data):
        tag, i = read_varint(data, i)
        field_no = tag >> 3
        wire = tag & 0x07
        if wire == 0:  # varint
            val, i = read_varint(data, i)
            fields.setdefault(field_no, []).append(("varint", val))
        elif wire == 2:  # length-delimited
            length, i = read_varint(data, i)
            val = data[i:i + length]
            i += length
            fields.setdefault(field_no, []).append(("bytes", val))
        elif wire == 5:  # 32-bit
            val = data[i:i + 4]
            i += 4
            fields.setdefault(field_no, []).append(("i32", val))
        elif wire == 1:  # 64-bit
            val = data[i:i + 8]
            i += 8
            fields.setdefault(field_no, []).append(("i64", val))
        else:
            raise ValueError("unsupported wire type %d" % wire)
    return fields


def main():
    b64 = read_b64()
    try:
        raw = base64.b64decode(b64, validate=False)
    except Exception as e:
        sys.exit("could not base64-decode input: %s" % e)

    print("PSSH: %d bytes (base64 %d chars)" % (len(raw), len(b64)))
    try:
        system_hex, version, kids, data, size = parse_pssh_box(raw)
    except ValueError as e:
        sys.exit("not a valid PSSH box: %s" % e)

    name = SYSTEMS.get(system_hex, "unknown")
    print("box size field : %d" % size)
    print("version        : %d" % version)
    print("system id      : %s  (%s)" % (uuid_dashed(system_hex), name))
    if kids:
        print("box KIDs       :")
        for k in kids:
            print("    %s" % uuid_dashed(k.hex()))
    print("data           : %d bytes" % len(data))

    if system_hex != WIDEVINE_SYSTEM_ID:
        print("\n(not a Widevine PSSH — skipping protobuf decode)")
        return

    try:
        fields = parse_widevine_pb(data)
    except ValueError as e:
        sys.exit("could not parse Widevine protobuf: %s" % e)

    print("\nWidevine protobuf fields:")
    for f2 in fields.get(2, []):
        print("  key_id     : %s" % uuid_dashed(f2[1].hex()))
    for f1 in fields.get(1, []):
        print("  algorithm  : %s" % f1[1])
    for f3 in fields.get(3, []):
        try:
            print("  provider   : %s" % f3[1].decode("utf-8"))
        except UnicodeDecodeError:
            print("  provider   : %s (hex)" % f3[1].hex())
    for f4 in fields.get(4, []):
        payload = f4[1]
        try:
            print("  content_id : %s" % payload.decode("utf-8"))
        except UnicodeDecodeError:
            print("  content_id : %s (hex)" % payload.hex())
    for f6 in fields.get(6, []):
        try:
            print("  policy     : %s" % f6[1].decode("utf-8"))
        except UnicodeDecodeError:
            print("  policy     : %s (hex)" % f6[1].hex())

    other = sorted(k for k in fields if k not in (1, 2, 3, 4, 6))
    if other:
        print("  other fields present: %s" % ", ".join(str(k) for k in other))


if __name__ == "__main__":
    main()
