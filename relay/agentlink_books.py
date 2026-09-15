"""Book fingerprinting, registration and probe/manifest verdicts.

The device (KOReader) computes `partial_md5_checksum` for every opened
document: 1024-byte samples at offsets 0, 1 KiB, 4 KiB, 16 KiB, …
(1024 << 2i), stopping at EOF. This module reproduces that exactly, so the
device never hashes a whole book. Registered files also keep a full SHA-256
for integrity checks.

Pure standard library; owns the `books` table inside the relay database.
"""

from __future__ import annotations

import hashlib
import os
import posixpath
import re
import sqlite3
import time
import uuid
import zipfile
from contextlib import closing
from pathlib import Path
from typing import Any
from xml.etree import ElementTree

_SAMPLE_SIZE = 1024
_MAX_TITLE = 500
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
_NS_CONTAINER = "{urn:oasis:names:tc:opendocument:xmlns:container}"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS books (
    id INTEGER PRIMARY KEY,
    sha256 TEXT NOT NULL UNIQUE,
    partial_md5 TEXT NOT NULL,
    size INTEGER NOT NULL,
    title TEXT,
    author TEXT,
    title_key TEXT,
    author_key TEXT,
    file_path TEXT NOT NULL,
    format TEXT NOT NULL,
    registered_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_books_fingerprint ON books(partial_md5, size);
CREATE INDEX IF NOT EXISTS idx_books_title ON books(title_key, author_key);
"""


class InvalidBook(ValueError):
    """Raised when a file cannot be registered as a readable EPUB."""


def ensure_books_table(db_path: str | Path) -> None:
    with closing(sqlite3.connect(db_path)) as conn:
        conn.executescript(_SCHEMA)
        conn.commit()


def partial_md5(path: str | Path) -> str:
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        for i in range(-1, 11):
            offset = 0 if i == -1 else _SAMPLE_SIZE << (2 * i)
            handle.seek(offset)
            sample = handle.read(_SAMPLE_SIZE)
            if not sample:
                break
            digest.update(sample)
    return digest.hexdigest()


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_key(text: str | None) -> str | None:
    if not text:
        return None
    key = "".join(ch for ch in text.casefold() if ch.isalnum())
    return key or None


def read_epub_metadata(path: str | Path) -> dict[str, Any]:
    """Return {'title', 'author'} from the EPUB package; raise InvalidBook
    when the file is not a readable EPUB with a dc:title."""
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as exc:
        raise InvalidBook(f"not a readable EPUB archive: {exc}") from exc
    with archive:
        try:
            container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
        except (KeyError, ElementTree.ParseError) as exc:
            raise InvalidBook("EPUB container.xml missing or invalid") from exc
        rootfile = container.find(f".//{_NS_CONTAINER}rootfile")
        opf_path = rootfile.get("full-path") if rootfile is not None else None
        if not opf_path:
            raise InvalidBook("EPUB rootfile missing")
        try:
            opf = ElementTree.fromstring(archive.read(opf_path))
        except (KeyError, ElementTree.ParseError) as exc:
            raise InvalidBook("EPUB package document missing or invalid") from exc
    ns_dc = "{http://purl.org/dc/elements/1.1/}"
    title_node = opf.find(f".//{ns_dc}title")
    title = (title_node.text or "").strip() if title_node is not None else ""
    if not title:
        raise InvalidBook("EPUB has no dc:title")
    creator_node = opf.find(f".//{ns_dc}creator")
    author = (creator_node.text or "").strip() if creator_node is not None else ""
    return {"title": title[:_MAX_TITLE], "author": author[:_MAX_TITLE] or None}


def register_file(
    db_path: str | Path,
    file_path: str | Path,
    *,
    title: str | None = None,
    author: str | None = None,
    registered_at: float | None = None,
) -> dict[str, Any]:
    """Register one EPUB already on disk. Idempotent by SHA-256."""
    path = Path(file_path)
    if not path.is_file():
        raise InvalidBook(f"file not found: {path}")
    metadata = read_epub_metadata(path)
    final_title = (title or "").strip() or metadata["title"]
    final_author = (author or "").strip() or metadata["author"]
    fingerprint = {
        "sha256": sha256_file(path),
        "partial_md5": partial_md5(path),
        "size": path.stat().st_size,
    }
    ensure_books_table(db_path)
    with closing(sqlite3.connect(db_path)) as conn:
        conn.row_factory = sqlite3.Row
        existing = conn.execute("SELECT * FROM books WHERE sha256 = ?", (fingerprint["sha256"],)).fetchone()
        if existing is not None:
            record = dict(existing)
            record["created"] = False
            return record
        cursor = conn.execute(
            """
            INSERT INTO books (sha256, partial_md5, size, title, author, title_key, author_key,
                               file_path, format, registered_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                fingerprint["sha256"], fingerprint["partial_md5"], fingerprint["size"],
                final_title, final_author, normalize_key(final_title), normalize_key(final_author),
                str(path), "epub",
                float(time.time() if registered_at is None else registered_at),
            ),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM books WHERE id = ?", (cursor.lastrowid,)).fetchone()
    record = dict(row)
    record["created"] = True
    return record


def find_by_title(db_path: str | Path, title: str, author: str | None) -> dict[str, Any] | None:
    title_key = normalize_key(title)
    if not title_key or not Path(db_path).exists():
        return None
    ensure_books_table(db_path)
    with closing(sqlite3.connect(db_path)) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM books WHERE title_key = ? ORDER BY registered_at DESC, id DESC",
            (title_key,),
        ).fetchall()
        author_key = normalize_key(author)
        for row in rows:
            stored = row["author_key"]
            if author_key is None or stored is None or stored == author_key:
                return dict(row)
    return None


def verdict(conn: sqlite3.Connection, *, partial_md5_value: str, size: int,
            title: str | None, author: str | None) -> dict[str, Any]:
    """Classify one (fingerprint, size, title, author) against the library."""
    match = conn.execute(
        "SELECT * FROM books WHERE partial_md5 = ? AND size = ? ORDER BY id LIMIT 1",
        (partial_md5_value, size),
    ).fetchone()
    if match is not None:
        return {"status": "present", "book": _public(dict(match))}
    title_key = normalize_key(title)
    author_key = normalize_key(author)
    if title_key:
        for row in conn.execute(
            "SELECT * FROM books WHERE title_key = ? ORDER BY registered_at DESC, id DESC",
            (title_key,),
        ).fetchall():
            stored = row["author_key"]
            if author_key is None or stored is None or stored == author_key:
                return {"status": "changed", "book": _public(dict(row))}
    return {"status": "missing"}


def _public(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": record["id"],
        "sha256": record["sha256"],
        "title": record["title"],
        "author": record["author"],
    }


def probe(db_path: str | Path, clean: dict[str, Any]) -> dict[str, Any]:
    ensure_books_table(db_path)
    with closing(sqlite3.connect(db_path)) as conn:
        conn.row_factory = sqlite3.Row
        return verdict(
            conn,
            partial_md5_value=clean["partial_md5"],
            size=clean["size"],
            title=clean["title"],
            author=clean.get("author"),
        )


def match_manifest(db_path: str | Path, clean: dict[str, Any]) -> dict[str, Any]:
    ensure_books_table(db_path)
    missing: list[dict[str, Any]] = []
    changed: list[dict[str, Any]] = []
    known = 0
    with closing(sqlite3.connect(db_path)) as conn:
        conn.row_factory = sqlite3.Row
        for entry in clean["books"]:
            result = verdict(
                conn,
                partial_md5_value=entry["partial_md5"],
                size=entry["size"],
                title=entry.get("title"),
                author=entry.get("author"),
            )
            item = {"path": entry["path"], "partial_md5": entry["partial_md5"], "size": entry["size"]}
            if result["status"] == "present":
                known += 1
            elif result["status"] == "changed":
                item["book"] = result["book"]
                changed.append(item)
            else:
                missing.append(item)
    return {"known": known, "missing": missing, "changed": changed}


_RE_UNSAFE = re.compile(r"[\x00-\x1f\x7f/\\:*?\"<>|]+")


def safe_file_name(name: str | None) -> str:
    base = os.path.basename((name or "").replace("\\", "/")).strip()
    base = _RE_UNSAFE.sub("", base).strip(" .")
    stem, ext = os.path.splitext(base)
    if ext.lower() != ".epub":
        stem, ext = base, ".epub"
    stem = stem.strip(" .")
    if not stem:
        stem = "book-" + uuid.uuid4().hex[:8]
    return stem[:180] + ext


def unique_target(library_dir: Path, file_name: str, sha256: str) -> Path:
    target = library_dir / file_name
    if not target.exists():
        return target
    stem, ext = os.path.splitext(file_name)
    return library_dir / f"{stem}-{sha256[:8]}{ext}"
