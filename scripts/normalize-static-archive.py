#!/usr/bin/env python3
"""Rewrite a static archive with unique member names.

Apple's linker emits warnings when a .a archive contains multiple members with
the same name (for Ghostty 1.3.1 this happens with ext.o inside libghostty-fat.a).
This script extracts the archive members, renames duplicates deterministically,
and rebuilds the archive with libtool/ranlib so warning-free native gates stay
green.
"""

from __future__ import annotations

import collections
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

AR_MAGIC = b"!<arch>\n"


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_members(archive: Path) -> list[tuple[str, bytes]]:
    data = archive.read_bytes()
    if not data.startswith(AR_MAGIC):
        fail(f"{archive} is not an ar archive")

    members: list[tuple[str, bytes]] = []
    offset = len(AR_MAGIC)
    while offset < len(data):
        header = data[offset : offset + 60]
        if len(header) < 60:
            break

        name_field = header[:16].decode("utf-8", "replace")
        try:
            size = int(header[48:58].decode().strip())
        except ValueError as exc:
            fail(f"invalid archive member size at offset {offset}: {exc}")

        content_offset = offset + 60
        if name_field.startswith("#1/"):
            name_len = int(name_field[3:].strip())
            raw_name = data[content_offset : content_offset + name_len]
            name = raw_name.decode("utf-8", "replace").rstrip("\x00")
            body = data[content_offset + name_len : content_offset + size]
        else:
            name = name_field.rstrip().rstrip("/")
            body = data[content_offset : content_offset + size]

        if not name.startswith("__.SYMDEF"):
            members.append((name, body))

        offset += 60 + size
        if offset % 2:
            offset += 1

    return members


def write_normalized_archive(archive: Path, members: list[tuple[str, bytes]]) -> bool:
    counts = collections.Counter(name for name, _ in members)
    duplicate_names = sorted(name for name, count in counts.items() if count > 1)
    if not duplicate_names:
        print(f"{archive}: already normalized")
        return False

    print(f"{archive}: normalizing duplicate members: {', '.join(duplicate_names)}")

    with tempfile.TemporaryDirectory(prefix="normalize-static-archive-") as tmpdir_str:
        tmpdir = Path(tmpdir_str)
        object_paths: list[str] = []
        seen: dict[str, int] = {}

        for index, (name, body) in enumerate(members):
            duplicate_index = seen.get(name, 0)
            seen[name] = duplicate_index + 1

            stem, dot, suffix = name.partition(".")
            if duplicate_index == 0:
                out_name = f"{index:04d}_{name}"
            elif dot:
                out_name = f"{index:04d}_{stem}__dup{duplicate_index}.{suffix}"
            else:
                out_name = f"{index:04d}_{name}__dup{duplicate_index}"

            out_path = tmpdir / out_name
            out_path.write_bytes(body)
            object_paths.append(str(out_path))

        rebuilt = tmpdir / archive.name
        subprocess.run(["libtool", "-static", "-o", str(rebuilt), *object_paths], check=True)
        subprocess.run(["ranlib", str(rebuilt)], check=True)
        shutil.copy2(rebuilt, archive)

    return True


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: normalize-static-archive.py <path-to-static-archive>")

    archive = Path(sys.argv[1]).resolve()
    if not archive.is_file():
        fail(f"archive not found: {archive}")

    members = parse_members(archive)
    changed = write_normalized_archive(archive, members)
    if changed:
        print(f"{archive}: normalization complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
