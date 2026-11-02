#!/usr/bin/env python3
"""Lua syntax verification using actual LuaJIT 2.1 compilation via lupa."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import lupa.luajit21
except ImportError:
    print(
        "Error: lupa with LuaJIT 2.1 is required.\n"
        "Run via: uv run --with lupa --with pytest python scripts/parse-lua.py",
        file=sys.stderr,
    )
    sys.exit(1)


def main() -> int:
    lua = lupa.luajit21.LuaRuntime()

    # Self-test: prove that actual LuaJIT compiler rejects invalid syntax
    invalid_snippet = "local x = )"
    try:
        lua.compile(invalid_snippet)
        print(f"FAIL: LuaJIT failed to reject invalid snippet: {invalid_snippet!r}")
        return 1
    except Exception as exc:
        print(f"Self-test: successfully rejected invalid syntax {invalid_snippet!r} ({type(exc).__name__})")

    root = Path(__file__).resolve().parent.parent / "koplugin"
    all_ok = True
    lua_files = sorted(root.rglob("*.lua"))

    if not lua_files:
        print(f"ERROR: No Lua files found under {root}")
        return 1

    for f in lua_files:
        rel = f.relative_to(root)
        code = f.read_text(encoding="utf-8")
        try:
            lua.compile(code)
            print(f"  {rel}: valid LuaJIT bytecode")
        except Exception as exc:
            print(f"  {rel}: COMPILATION ERROR: {exc}")
            all_ok = False

    if all_ok:
        print(f"parse-lua: all {len(lua_files)} shipped Lua files compiled successfully under LuaJIT 2.1.")
        return 0
    print("parse-lua: compilation errors found.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
