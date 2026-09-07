#!/usr/bin/env python3
"""Compatibility wrapper for the canonical Pure Dart HTML exporter."""

from pathlib import Path
import subprocess
import sys


def main() -> int:
    repository_root = Path(__file__).resolve().parent
    command = [
        "dart",
        "run",
        "tool/export_curator_html.dart",
        *sys.argv[1:],
    ]
    return subprocess.run(command, cwd=repository_root, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
