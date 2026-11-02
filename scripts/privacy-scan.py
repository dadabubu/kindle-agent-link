#!/usr/bin/env python3
"""Secret and privacy scanner for the Kindle AgentLink candidate repository.

Scans tracked and exported source files for generic credential patterns and,
when configured via AGENTLINK_PRIVACY_DENYLIST_FILE, external literal private
identifiers loaded from outside the repository root.

Exit code 0 = clean, 1 = findings, 2 = configuration/usage error.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Generic credential patterns worth catching in open-source distributions.
CREDENTIAL_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"Bearer [A-Za-z0-9_\-\.]{24,}"),
]

CATEGORY_CREDENTIAL = "generic_credential"
CATEGORY_DENYLIST = "private_literal"

SKIP_SUFFIXES = {
    ".bin",
    ".db",
    ".db-shm",
    ".db-wal",
    ".dll",
    ".dylib",
    ".eot",
    ".epub",
    ".exe",
    ".gif",
    ".gz",
    ".ico",
    ".jpeg",
    ".jpg",

    ".pdf",
    ".png",
    ".pyc",
    ".so",
    ".tar",
    ".ttf",
    ".woff",
    ".woff2",
    ".zip",
}

SKIP_DIRS = {
    ".git",
    ".hg",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".svn",
    ".tox",
    ".venv",
    "__pycache__",
    "venv",
}


def _is_within_root(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def load_denylist(path: Path | str, root: Path) -> list[str]:
    """Load private literal match rules from an external UTF-8 file outside public root."""
    denylist_file = Path(path).resolve()
    root_resolved = Path(root).resolve()

    if _is_within_root(denylist_file, root_resolved):
        raise ValueError(
            f"Denylist file must be located outside public root: {denylist_file} (inside {root_resolved})"
        )
    if not denylist_file.is_file():
        raise ValueError(f"Denylist file not found or not a regular file: {denylist_file}")

    try:
        content = denylist_file.read_text(encoding="utf-8")
    except Exception as exc:
        raise ValueError(f"Failed to read denylist file {denylist_file}: {exc}") from exc

    literals: list[str] = []
    seen: set[str] = set()
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key = line.lower()
        if key not in seen:
            seen.add(key)
            literals.append(line)
    return literals


def scan(
    root: Path | str | None = None,
    denylist_path: Path | str | None = None,
) -> tuple[list[tuple[Path, int, str]], int | None]:
    """Scan root for generic credentials and optional external literal denylist matches.

    Returns:
        (findings, rule_count) where rule_count is None if no external denylist was configured.
    """
    root_path = Path(root).resolve() if root is not None else ROOT.resolve()
    if not root_path.is_dir():
        raise ValueError("Scan root must be an existing directory")

    configured_denylist = denylist_path
    if configured_denylist is None:
        env_val = os.environ.get("AGENTLINK_PRIVACY_DENYLIST_FILE", "").strip()
        if env_val:
            configured_denylist = env_val

    literals: list[str] = []
    rule_count: int | None = None
    if configured_denylist is not None:
        literals = load_denylist(configured_denylist, root_path)
        rule_count = len(literals)

    hits: list[tuple[Path, int, str]] = []

    for path in sorted(root_path.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(root_path)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if "\x00" in text:
            continue

        for line_no, line in enumerate(text.splitlines(), start=1):
            line_lower = line.lower()
            matched_categories: set[str] = set()

            for pattern in CREDENTIAL_PATTERNS:
                if pattern.search(line):
                    matched_categories.add(CATEGORY_CREDENTIAL)
                    break

            for literal in literals:
                if literal.lower() in line_lower:
                    matched_categories.add(CATEGORY_DENYLIST)
                    break

            for cat in sorted(matched_categories):
                hits.append((rel, line_no, cat))

    return hits, rule_count


def findings(
    root: Path | str | None = None,
    denylist_path: Path | str | None = None,
) -> list[tuple[Path, int, str]]:
    """Return findings as a list of (path, line_number, category)."""
    hits, _ = scan(root=root, denylist_path=denylist_path)
    return hits


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Secret and privacy scanner for the Kindle AgentLink repository."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Root directory to scan (default: repository root)",
    )
    parser.add_argument(
        "--denylist",
        type=Path,
        default=None,
        help="Path to external literal denylist file (default: AGENTLINK_PRIVACY_DENYLIST_FILE)",
    )
    args = parser.parse_args(argv)

    try:
        hits, rule_count = scan(root=args.root, denylist_path=args.denylist)
    except Exception as exc:
        print(f"privacy-scan error: {exc}", file=sys.stderr)
        return 2

    if hits:
        print(f"PRIVACY/SECRET FINDINGS: {len(hits)}")
        for path, line_no, category in hits:
            print(f"  {path.as_posix()}:{line_no}: {category}")
        return 1

    if rule_count is not None:
        print(
            f"privacy-scan: clean — 0 findings (generic credential checks + {rule_count} external private literal rules checked)."
        )
    else:
        print(
            "privacy-scan: clean — 0 findings (generic credential checks only; no external private denylist configured)."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
