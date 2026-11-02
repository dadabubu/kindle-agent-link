#!/usr/bin/env python3
"""Unified test and validation runner for Kindle AgentLink candidate.

Invokes:
1. Actual LuaJIT 2.1 bytecode compilation across all shipped Lua modules.
2. Real pytest test suite (contract tests, ported Lua runtime tests under LuaJIT, relay tests).
3. Secret and privacy scanner.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run_step(title: str, cmd: list[str]) -> bool:
    print(f"=== {title} ===")
    res = subprocess.run(cmd, cwd=str(ROOT))
    if res.returncode == 0:
        print(f"[OK] {title}\n")
        return True
    else:
        print(f"[FAIL] {title} (exit code {res.returncode})\n")
        return False


def main() -> int:
    steps = [
        ("LuaJIT 2.1 Compilation Verification", [sys.executable, "scripts/parse-lua.py"]),
        ("Pytest Test Suite (Contracts, LuaJIT Runtime, Relay)", [sys.executable, "-m", "pytest", "tests/", "-v"]),
        ("Privacy & Secret Scan", [sys.executable, "scripts/privacy-scan.py"]),
    ]
    all_ok = True
    for title, cmd in steps:
        if not run_step(title, cmd):
            all_ok = False

    if all_ok:
        print("ALL VALIDATION CHECKS PASSED.")
        return 0
    print("VALIDATION FAILED.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
