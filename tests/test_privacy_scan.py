"""Focused behavioral tests for scripts/privacy-scan.py.

Verifies:
- Scanner and test files are not exempt from detection.
- External literal matching is case-insensitive and metacharacters are literal.
- Credential detection catches standard token shapes.
- No keyword-based bypasses exist.
- Configured missing or in-root denylist fails closed.
- Default output honestly labels generic-only coverage.
- Scanner never prints matching private values or credential contents.
- Version-control / cache directories and binary files are skipped.
- Public repo tree passes generic scan cleanly.
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCANNER_PATH = ROOT / "scripts" / "privacy-scan.py"

# Synthetic test tokens constructed dynamically so this test file itself
# does not contain static credential matches when scanned.
SAMPLE_SK = "sk-" + "abcdefghijklmnopqrstuvwxyz12345"
SAMPLE_GHP = "ghp_" + "abcdefghijklmnopqrstuvwxyz12345"
SAMPLE_SLACK = "xoxb-" + "abcdefghijklmnopqrstuvwxyz"
SAMPLE_BEARER = "Bearer " + "abcdefghijklmnopqrstuvwxyz012345"


@pytest.fixture(scope="module")
def scanner():
    spec = importlib.util.spec_from_file_location("privacy_scan", SCANNER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_scanner_and_test_files_not_exempt(scanner, tmp_path):
    """Scanner and test files themselves must not be exempt from detection."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()
    scripts_dir = mock_root / "scripts"
    scripts_dir.mkdir()
    tests_dir = mock_root / "tests"
    tests_dir.mkdir()

    scanner_file = scripts_dir / "privacy-scan.py"
    scanner_file.write_text(
        f'LEAK = "{SAMPLE_SK}"\n',
        encoding="utf-8",
    )

    contract_test_file = tests_dir / "test_plugin_contract.py"
    contract_test_file.write_text(
        f'GITHUB_SECRET = "{SAMPLE_GHP}"\n',
        encoding="utf-8",
    )

    clean_file = mock_root / "clean.py"
    clean_file.write_text("x = 42\n", encoding="utf-8")

    hits = scanner.findings(root=mock_root)
    assert len(hits) == 2

    hit_paths = {p.as_posix() for p, _, _ in hits}
    assert "scripts/privacy-scan.py" in hit_paths
    assert "tests/test_plugin_contract.py" in hit_paths
    for _, _, category in hits:
        assert category == "generic_credential"


def test_external_literal_matching_case_insensitive_and_metacharacters_literal(scanner, tmp_path):
    """External denylist matching must be case-insensitive and treat metacharacters literally."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()

    denylist_file = tmp_path / "denylist.txt"
    denylist_file.write_text(
        "# Comments and blank lines\n\n"
        "sample.example.invalid\n"
        "service[prod]+alpha*?\n"
        "target.secret-host\n",
        encoding="utf-8",
    )

    (mock_root / "upper.txt").write_text("HOST = 'SAMPLE.EXAMPLE.INVALID'\n", encoding="utf-8")
    (mock_root / "mixed.txt").write_text("HOST = 'sAmPlE.eXaMpLe.InVaLiD'\n", encoding="utf-8")
    (mock_root / "meta_literal.txt").write_text("TAG = 'service[prod]+alpha*?'\n", encoding="utf-8")
    (mock_root / "meta_regex_expanded.txt").write_text("TAG = 'serviceprod'\n", encoding="utf-8")
    (mock_root / "meta_wildcard.txt").write_text("TAG = 'targetXsecret-host'\n", encoding="utf-8")
    (mock_root / "meta_exact.txt").write_text("TAG = 'target.secret-host'\n", encoding="utf-8")

    hits = scanner.findings(root=mock_root, denylist_path=denylist_file)
    hit_paths = {p.as_posix() for p, _, _ in hits}

    assert "upper.txt" in hit_paths
    assert "mixed.txt" in hit_paths
    assert "meta_literal.txt" in hit_paths
    assert "meta_exact.txt" in hit_paths

    assert "meta_regex_expanded.txt" not in hit_paths
    assert "meta_wildcard.txt" not in hit_paths

    for _, _, category in hits:
        assert category == "private_literal"


def test_credential_detection(scanner, tmp_path):
    """Generic credential patterns must be caught and labeled as generic_credential."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()

    (mock_root / "c1.txt").write_text(f"OPENAI = '{SAMPLE_SK}'\n", encoding="utf-8")
    (mock_root / "c2.txt").write_text(f"GH = '{SAMPLE_GHP}'\n", encoding="utf-8")
    (mock_root / "c3.txt").write_text(f"SLACK = '{SAMPLE_SLACK}'\n", encoding="utf-8")
    (mock_root / "c4.txt").write_text(f"BEARER = '{SAMPLE_BEARER}'\n", encoding="utf-8")

    hits = scanner.findings(root=mock_root)
    assert len(hits) == 4
    for _, _, category in hits:
        assert category == "generic_credential"


def test_no_keyword_based_bypass(scanner, tmp_path):
    """Lines containing keyword identifiers like 'forbidden' must not bypass scanning."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()

    denylist_file = tmp_path / "denylist.txt"
    denylist_file.write_text("synthetic-private.example.invalid\n", encoding="utf-8")

    (mock_root / "k1.py").write_text(f"forbidden = '{SAMPLE_SK}'\n", encoding="utf-8")
    (mock_root / "k2.py").write_text("NAME_PATTERNS = ['synthetic-private.example.invalid']\n", encoding="utf-8")
    (mock_root / "k3.py").write_text(f"SECRET_PATTERNS = ['{SAMPLE_GHP}']\n", encoding="utf-8")
    (mock_root / "k4.py").write_text(f"_FRONT_MATTER = '{SAMPLE_BEARER}'\n", encoding="utf-8")
    (mock_root / "k5.py").write_text(f"tok = '{SAMPLE_SK}' # forbidden comment\n", encoding="utf-8")

    hits = scanner.findings(root=mock_root, denylist_path=denylist_file)
    assert len(hits) == 5
    hit_files = {p.as_posix() for p, _, _ in hits}
    assert hit_files == {"k1.py", "k2.py", "k3.py", "k4.py", "k5.py"}


def test_configured_missing_or_in_root_denylist_fails_closed(scanner, tmp_path, monkeypatch):
    """Configuring a missing file or an in-root denylist must fail closed."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()
    (mock_root / "clean.txt").write_text("hello\n", encoding="utf-8")

    missing_path = tmp_path / "non_existent_denylist.txt"
    in_root_path = mock_root / "denylist.txt"
    in_root_path.write_text("some-rule\n", encoding="utf-8")

    # Missing denylist passed explicitly
    with pytest.raises(ValueError):
        scanner.findings(root=mock_root, denylist_path=missing_path)

    # In-root denylist passed explicitly
    with pytest.raises(ValueError):
        scanner.findings(root=mock_root, denylist_path=in_root_path)

    # Missing denylist via environment variable
    monkeypatch.setenv("AGENTLINK_PRIVACY_DENYLIST_FILE", str(missing_path))
    with pytest.raises(ValueError):
        scanner.findings(root=mock_root)

    # In-root denylist via environment variable
    monkeypatch.setenv("AGENTLINK_PRIVACY_DENYLIST_FILE", str(in_root_path))
    with pytest.raises(ValueError):
        scanner.findings(root=mock_root)

    # CLI exits with error code 2 when missing or in-root
    res_missing = subprocess.run(
        [sys.executable, str(SCANNER_PATH), "--root", str(mock_root), "--denylist", str(missing_path)],
        capture_output=True,
        text=True,
    )
    assert res_missing.returncode == 2
    assert "error" in res_missing.stderr.lower()

    res_in_root = subprocess.run(
        [sys.executable, str(SCANNER_PATH), "--root", str(mock_root), "--denylist", str(in_root_path)],
        capture_output=True,
        text=True,
    )
    assert res_in_root.returncode == 2
    assert "error" in res_in_root.stderr.lower()


def test_default_result_accurately_labels_coverage(tmp_path, monkeypatch):
    """Clean default scans must honestly report generic-only coverage and not claim private checks."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()
    (mock_root / "safe.txt").write_text("all clear\n", encoding="utf-8")

    monkeypatch.delenv("AGENTLINK_PRIVACY_DENYLIST_FILE", raising=False)

    # Default run: no denylist
    res = subprocess.run(
        [sys.executable, str(SCANNER_PATH), "--root", str(mock_root)],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0
    assert "generic credential checks only; no external private denylist configured" in res.stdout
    assert "private names" not in res.stdout.lower()

    # External denylist with 3 rules (and comments/blank lines)
    denylist = tmp_path / "denylist.txt"
    denylist.write_text(
        "# Heading comment\n\nrule-alpha\nrule-beta\n\n# Sub-comment\nrule-gamma\n\n",
        encoding="utf-8",
    )
    res_external = subprocess.run(
        [sys.executable, str(SCANNER_PATH), "--root", str(mock_root), "--denylist", str(denylist)],
        capture_output=True,
        text=True,
    )
    assert res_external.returncode == 0
    assert "3 external private literal rules checked" in res_external.stdout
    # Rule names must not be leaked into stdout
    assert "rule-alpha" not in res_external.stdout
    assert "rule-beta" not in res_external.stdout
    assert "rule-gamma" not in res_external.stdout


def test_scanner_never_prints_matching_private_values(scanner, tmp_path):
    """Scanner findings and CLI output must never print matched private text or credentials."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()

    secret_literal = "synthetic-secret-never-print-987654"
    credential_token = SAMPLE_SK

    denylist = tmp_path / "denylist.txt"
    denylist.write_text(f"{secret_literal}\n", encoding="utf-8")

    target_file = mock_root / "leaks.py"
    target_file.write_text(
        f"SECRET_VAR = '{secret_literal}'\nAPI_KEY = '{credential_token}'\n",
        encoding="utf-8",
    )

    hits = scanner.findings(root=mock_root, denylist_path=denylist)
    assert len(hits) == 2

    # In Python API findings
    for path, line_no, category in hits:
        assert secret_literal not in str(path)
        assert secret_literal not in str(category)
        assert credential_token not in str(path)
        assert credential_token not in str(category)

    # In CLI execution
    res = subprocess.run(
        [sys.executable, str(SCANNER_PATH), "--root", str(mock_root), "--denylist", str(denylist)],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 1
    output = res.stdout + res.stderr
    assert secret_literal not in output
    assert credential_token not in output

    # Output should only show relative path, line, and category
    assert "leaks.py:1: private_literal" in res.stdout
    assert "leaks.py:2: generic_credential" in res.stdout


def test_binary_and_cache_directories_ignored(scanner, tmp_path):
    """Cache and version-control dirs and binary files must be skipped."""
    mock_root = tmp_path / "repo"
    mock_root.mkdir()

    git_dir = mock_root / ".git"
    git_dir.mkdir()
    (git_dir / "config").write_text(f"{SAMPLE_SK}\n", encoding="utf-8")

    cache_dir = mock_root / "__pycache__"
    cache_dir.mkdir()
    (cache_dir / "mod.pyc").write_text(f"{SAMPLE_SK}\n", encoding="utf-8")

    (mock_root / "sample.db").write_text(f"{SAMPLE_SK}\n", encoding="utf-8")
    (mock_root / "binary.bin").write_bytes(f"\x00{SAMPLE_SK}\x00".encode("utf-8"))

    hits = scanner.findings(root=mock_root)
    assert hits == []


def test_invalid_scan_root_fails_closed(scanner, tmp_path):
    missing = tmp_path / "missing"
    with pytest.raises(ValueError):
        scanner.findings(root=missing)
    regular_file = tmp_path / "file.txt"
    regular_file.write_text("content", encoding="utf-8")
    with pytest.raises(ValueError):
        scanner.findings(root=regular_file)


def test_text_log_files_are_scanned(scanner, tmp_path):
    (tmp_path / "trace.log").write_text(SAMPLE_SK, encoding="utf-8")
    hits = scanner.findings(root=tmp_path)
    assert [(p.as_posix(), category) for p, _, category in hits] == [
        ("trace.log", "generic_credential")
    ]


def test_unreadable_text_files_do_not_report_clean(scanner, tmp_path, monkeypatch):
    target = tmp_path / "unreadable.txt"
    target.write_text("content", encoding="utf-8")
    original_read = Path.read_text

    def guarded_read(path, *args, **kwargs):
        if path == target:
            raise PermissionError("synthetic unreadable source")
        return original_read(path, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", guarded_read)
    with pytest.raises(PermissionError):
        scanner.findings(root=tmp_path)


def test_public_repo_tree_is_clean(scanner, monkeypatch):
    """The clean public repository tree must pass the scanner without an external denylist."""
    monkeypatch.delenv("AGENTLINK_PRIVACY_DENYLIST_FILE", raising=False)
    hits = scanner.findings(root=ROOT)
    assert hits == []

    res = subprocess.run(
        [sys.executable, str(SCANNER_PATH)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0
    assert "clean — 0 findings" in res.stdout
