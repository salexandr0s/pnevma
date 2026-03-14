#!/usr/bin/env python3
"""Rewrite Ghostty's module map to avoid umbrella-header warnings in Xcode."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: normalize-ghostty-modulemap.py <module.modulemap>", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    original = path.read_text(encoding="utf-8")
    updated = original.replace('umbrella header "ghostty.h"', 'header "ghostty.h"')

    if original == updated:
        return 0

    path.write_text(updated, encoding="utf-8")
    print(f"normalized Ghostty module map at {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
