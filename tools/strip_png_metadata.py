#!/usr/bin/env python3
"""Remove PNG text/EXIF container metadata without re-encoding image pixels."""
import argparse
import pathlib
import struct
import zlib

METADATA = {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}


def strip(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Not a PNG")
    output, offset, removed, ended = bytearray(data[:8]), 8, 0, False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + length + 12
        if end > len(data):
            raise ValueError("Truncated PNG chunk")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        crc = struct.unpack(">I", data[end - 4:end])[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            raise ValueError("Invalid PNG checksum")
        if kind in METADATA:
            removed += 1
        else:
            output.extend(data[offset:end])
        offset = end
        if kind == b"IEND":
            ended = True
            break
    if not ended or offset != len(data):
        raise ValueError("Invalid PNG end/trailing data")
    return bytes(output), removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("png", type=pathlib.Path)
    args = parser.parse_args()
    data, removed = strip(args.png.read_bytes())
    if removed:
        temporary = args.png.with_suffix(".png.partial")
        temporary.write_bytes(data)
        temporary.replace(args.png)
    print(f"Removed {removed} metadata chunks; pixel/color chunks retained unchanged.")


if __name__ == "__main__":
    main()
