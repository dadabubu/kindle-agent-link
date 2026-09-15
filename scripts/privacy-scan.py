#!/usr/bin/env python3
"""Secret and privacy scanner for the Kindle AgentLink candidate repo.

Scans every tracked-looking file for private names, real endpoints, paths
and credential shapes.

Exit code 0 = clean, 1 = findings. Usage:  python scripts/privacy-scan.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Files whose own text is a defensive word-list (the scanner itself and the
# contract test that bans these names) are exempt from self-matching.
SELF_FILES = {Path("scripts/privacy-scan.py"), Path("tests/test_plugin_contract.py")}

# Private names and infrastructure that must never appear in public files.
NAME_PATTERNS = [
    r"sample-private-agent",
    r"sample-private-reader",
    r"sample-private-host",
    r"\bhermes\b",
    r"sample-reader",
    r"sample-deep-label",
    r"sample-quick-label",
    r"relay\.example\.invalid",
    r"e:[/\\]+sampledata",
    r"sample-private-workspace",
]
# Credential shapes worth catching even without a known name.
SECRET_PATTERNS = [
    r"sk-[A-Za-z0-9]{20,}",
    r"ghp_[A-Za-z0-9]{20,}",
    r"xox[baprs]-[A-Za-z0-9-]{10,}",
    r"Bearer [A-Za-z0-9_\-\.]{24,}",
]
SKIP_SUFFIXES = {".db", ".db-wal", ".db-shm", ".epub", ".log", ".pyc"}
SKIP_DIRS = {"__pycache__", ".pytest_cache", ".git", "library", "staging", ".incoming"}


def findings() -> list[tuple[Path, int, str]]:
    out = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, PermissionError):
            continue
        if rel.as_posix() in {p.as_posix() for p in SELF_FILES}:
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            # Detector definitions (this scanner's word lists, contract tests
            # that ban these names) legitimately contain the words themselves.
            if re.search(r"NAME_PATTERNS|SECRET_PATTERNS|_FRONT_MATTER|forbidden", line, re.IGNORECASE):
                continue
            for pattern in NAME_PATTERNS + SECRET_PATTERNS:
                if re.search(pattern, line, re.IGNORECASE):
                    out.append((rel, line_no, f"{pattern!r} -> {line.strip()[:110]}"))
    return out


def main() -> int:
    hits = findings()
    if hits:
        print(f"PRIVACY/SECRET FINDINGS: {len(hits)}")
        for path, line_no, detail in hits:
            print(f"  {path}:{line_no}: {detail}")
        return 1
    print("privacy-scan: clean — no private names, endpoints, paths or credential shapes found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
