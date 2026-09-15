"""SQLite storage for the Kindle AgentLink relay.

One database file, four tables: raw reading events, excerpt (door) events,
agent replies, and registered books. Everything is standard library; the
relay is the only writer.
"""

from __future__ import annotations

import json
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Any


_SCHEMA = """
CREATE TABLE IF NOT EXISTS reading_events (
    id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL UNIQUE,
    event TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    received_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS reading_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    book_json TEXT,
    position_json TEXT,
    last_event TEXT,
    last_event_id TEXT,
    updated_at REAL
);
CREATE TABLE IF NOT EXISTS excerpts (
    id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL UNIQUE,
    door TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    received_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS replies (
    reply_id INTEGER PRIMARY KEY,
    source_event_id TEXT NOT NULL UNIQUE,
    text TEXT NOT NULL,
    created_at REAL NOT NULL,
    kindle_status TEXT NOT NULL DEFAULT 'pending',
    kindle_acked_at REAL
);
"""

_INGEST_SCHEMA = """
CREATE INDEX IF NOT EXISTS idx_replies_kindle ON replies(kindle_status, reply_id);
"""


def connect(db_path: str | Path) -> sqlite3.Connection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(_SCHEMA)
    conn.executescript(_INGEST_SCHEMA)
    return conn


def dump(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def store_reading_event(db_path: str | Path, event: dict[str, Any], received_at: float) -> tuple[bool, str]:
    """Durably accept one reading event and advance the derived state.
    Returns (inserted, state_string)."""
    with closing(connect(db_path)) as conn, conn:
        cursor = conn.execute(
            "INSERT OR IGNORE INTO reading_events (event_id, event, payload_json, received_at) VALUES (?, ?, ?, ?)",
            (event["event_id"], event["event"], dump(event), received_at),
        )
        inserted = cursor.rowcount == 1
        state = conn.execute("SELECT book_json, position_json FROM reading_state WHERE id = 1").fetchone()
        book = event.get("book") if isinstance(event.get("book"), dict) else (
            json.loads(state["book_json"]) if state and state["book_json"] else None)
        position = event.get("position") if isinstance(event.get("position"), dict) else (
            json.loads(state["position_json"]) if state and state["position_json"] else None)
        conn.execute(
            """
            INSERT INTO reading_state (id, book_json, position_json, last_event, last_event_id, updated_at)
            VALUES (1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                book_json = excluded.book_json,
                position_json = excluded.position_json,
                last_event = excluded.last_event,
                last_event_id = excluded.last_event_id,
                updated_at = excluded.updated_at
            """,
            (dump(book) if book else None, dump(position) if position else None,
             event["event"], event["event_id"], received_at),
        )
    return inserted, ("accepted" if inserted else "duplicate")


def store_excerpt(db_path: str | Path, excerpt: dict[str, Any], received_at: float) -> tuple[int, bool]:
    """Durably accept one door event. Returns (row_id, inserted)."""
    with closing(connect(db_path)) as conn, conn:
        cursor = conn.execute(
            "INSERT OR IGNORE INTO excerpts (event_id, door, payload_json, received_at) VALUES (?, ?, ?, ?)",
            (excerpt["event_id"], str(excerpt.get("door") or "deep"), dump(excerpt), received_at),
        )
        inserted = cursor.rowcount == 1
        row = conn.execute("SELECT id FROM excerpts WHERE event_id = ?", (excerpt["event_id"],)).fetchone()
    return int(row["id"]), inserted


def store_reply(db_path: str | Path, *, source_event_id: str, text: str, created_at: float | None = None) -> tuple[int, bool]:
    body = (text or "").strip()
    if not source_event_id.strip():
        raise ValueError("source_event_id required")
    if not body:
        raise ValueError("reply text required")
    with closing(connect(db_path)) as conn, conn:
        cursor = conn.execute(
            "INSERT OR IGNORE INTO replies (source_event_id, text, created_at) VALUES (?, ?, ?)",
            (source_event_id.strip(), body[:8000],
             float(time.time() if created_at is None else created_at)),
        )
        inserted = cursor.rowcount == 1
        row = conn.execute("SELECT reply_id FROM replies WHERE source_event_id = ?",
                           (source_event_id.strip(),)).fetchone()
    return int(row["reply_id"]), inserted


def replies_after(db_path: str | Path, after: int, limit: int) -> list[dict[str, Any]]:
    with closing(connect(db_path)) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT r.reply_id, r.source_event_id, r.text, r.created_at, r.kindle_status,
                   e.payload_json
            FROM replies r LEFT JOIN excerpts e ON e.event_id = r.source_event_id
            WHERE r.reply_id > ? ORDER BY r.reply_id ASC LIMIT ?
            """,
            (int(after), int(limit)),
        ).fetchall()
    return [_reply_card(row) for row in rows]


def reply_history(db_path: str | Path, book_title: str, limit: int) -> list[dict[str, Any]]:
    wanted = (book_title or "").strip()
    with closing(connect(db_path)) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT r.reply_id, r.source_event_id, r.text, r.created_at, r.kindle_status,
                   e.payload_json
            FROM replies r LEFT JOIN excerpts e ON e.event_id = r.source_event_id
            ORDER BY r.reply_id DESC LIMIT 400
            """,
        ).fetchall()
    cards = [_reply_card(row) for row in rows]
    if wanted:
        cards = [c for c in cards if c["book_title"] == wanted]
    return cards[: max(1, int(limit))]


def _reply_card(row: sqlite3.Row) -> dict[str, Any]:
    try:
        payload = json.loads(row["payload_json"] or "{}")
    except (TypeError, json.JSONDecodeError):
        payload = {}
    payload = payload if isinstance(payload, dict) else {}
    book = payload.get("book") if isinstance(payload.get("book"), dict) else {}
    position = payload.get("position") if isinstance(payload.get("position"), dict) else {}
    selection = payload.get("selection") if isinstance(payload.get("selection"), dict) else {}
    return {
        "reply_id": row["reply_id"],
        "source_event_id": row["source_event_id"],
        "text": row["text"],
        "created_at": row["created_at"],
        "kindle_status": row["kindle_status"],
        "question": str(payload.get("note") or "")[:2000],
        "selection": str(selection.get("text") or "")[:8000],
        "progress": position.get("progress"),
        "book_title": str(book.get("title") or ""),
    }


def ack_replies(db_path: str | Path, reply_ids: list[int]) -> int:
    if not reply_ids:
        return 0
    with closing(connect(db_path)) as conn, conn:
        cursor = conn.execute(
            f"""
            UPDATE replies SET kindle_status = 'acked', kindle_acked_at = ?
            WHERE reply_id IN ({",".join("?" * len(reply_ids))}) AND kindle_status = 'pending'
            """,
            (time.time(), *[int(i) for i in reply_ids]),
        )
        return cursor.rowcount


def get_excerpt(db_path: str | Path, event_id: str) -> dict[str, Any] | None:
    with closing(connect(db_path)) as conn:
        row = conn.execute("SELECT payload_json FROM excerpts WHERE event_id = ?",
                           (event_id,)).fetchone()
    if row is None:
        return None
    try:
        payload = json.loads(row["payload_json"])
    except (TypeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None
