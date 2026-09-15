"""Kindle AgentLink relay — minimal self-hosted server.

Pure Python standard library. One bearer-token scope shared by the device
and your agent; run it behind TLS on infrastructure you control.

Endpoints (full contract: docs/http-contract.md):

    POST /agentlink/v1/reading-events      reading state ingest (idempotent)
    POST /agentlink/v1/excerpts            door events: door=deep | quick
    GET  /agentlink/v1/replies             cursor fetch; ?history=1&book_title=
    POST /agentlink/v1/replies/ack         Kindle read receipts
    POST /agentlink/v1/replies/inject      local backfill: store an agent reply
    POST /agentlink/v1/books/probe         present / missing / changed
    POST /agentlink/v1/books/upload        streamed EPUB (64 MiB cap)
    POST /agentlink/v1/books/manifest      directory diff

Configuration (environment variables, all optional):

    AGENTLINK_TOKEN       bearer token          (default: changeme-rotate-me)
    AGENTLINK_PORT        listen port           (default: 8765)
    AGENTLINK_DB          sqlite path           (default: ./agentlink.db)
    AGENTLINK_LIBRARY     book storage dir      (default: ./library)
    AGENTLINK_WEBHOOK_URL optional; every stored excerpt is POSTed here as
                          JSON so your agent can reply asynchronously. Reply
                          text can also be backfilled locally via
                          POST /agentlink/v1/replies/inject.

Usage:  python agentlink_relay.py [--config relay-config.json]
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import logging
import os
import shutil
import sys
import time
import urllib.request
import uuid
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentlink_books as books_mod  # noqa: E402
import agentlink_store as store  # noqa: E402

MAX_JSON_BYTES = 512 * 1024
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
MAX_ACK_BYTES = 4 * 1024
MAX_INJECT_BYTES = 64 * 1024
CHUNK_BYTES = 64 * 1024
WEBHOOK_TIMEOUT_SECONDS = 3

log = logging.getLogger("agentlink-relay")


class Config:
    def __init__(self) -> None:
        self.token = os.environ.get("AGENTLINK_TOKEN", "changeme-rotate-me")
        self.port = int(os.environ.get("AGENTLINK_PORT", "8765"))
        self.db = os.environ.get("AGENTLINK_DB", "agentlink.db")
        self.library = Path(os.environ.get("AGENTLINK_LIBRARY", "library"))
        self.webhook_url = os.environ.get("AGENTLINK_WEBHOOK_URL", "")

    def apply_file(self, path: str) -> None:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if "token" in data:
            self.token = str(data["token"])
        if "port" in data:
            self.port = int(data["port"])
        if "db" in data:
            self.db = str(data["db"])
        if "library" in data:
            self.library = Path(data["library"])
        if "agent_webhook_url" in data:
            self.webhook_url = str(data["agent_webhook_url"])


CONFIG = Config()


def _authorized(handler: BaseHTTPRequestHandler) -> bool:
    header = handler.headers.get("Authorization") or ""
    supplied = header[7:].strip() if header.startswith("Bearer ") else ""
    return bool(supplied) and hmac.compare_digest(supplied, CONFIG.token)


def _read_json(handler: BaseHTTPRequestHandler, cap: int) -> tuple[Any, str | None]:
    try:
        length = int(handler.headers.get("Content-Length", -1))
    except (TypeError, ValueError):
        return None, "bad request"
    if length < 0 or length > cap:
        return None, ("payload too large" if length > cap else "bad request")
    try:
        return json.loads(handler.rfile.read(length).decode("utf-8")), None
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, "bad request"


class RelayHandler(BaseHTTPRequestHandler):
    server_version = "AgentLinkRelay/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        log.info("%s - %s", self.client_address[0], fmt % args)

    def _json(self, status: int, body: Any) -> None:
        encoded = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    # --- GET -------------------------------------------------------------

    def do_GET(self) -> None:
        from urllib.parse import parse_qs, urlparse

        parsed = urlparse(self.path)
        if parsed.path != "/agentlink/v1/replies":
            self._json(404, {"error": "not found"})
            return
        if not _authorized(self):
            self._json(401, {"error": "unauthorized"})
            return
        query = parse_qs(parsed.query)
        after = int((query.get("after") or ["0"])[0])
        limit = min(int((query.get("limit") or ["5"])[0]), 20)
        if (query.get("history") or ["0"])[0] == "1":
            replies = store.reply_history(CONFIG.db, book_title=(query.get("book_title") or [""])[0], limit=limit)
        else:
            replies = store.replies_after(CONFIG.db, after=after, limit=limit)
        next_after = max((r["reply_id"] for r in replies), default=after)
        self._json(200, {"replies": replies, "next_after": next_after})

    # --- POST -------------------------------------------------------------

    def do_POST(self) -> None:
        path = self.path
        log.info("POST %s len=%s", path, self.headers.get("Content-Length"))
        if path == "/agentlink/v1/books/upload":
            # One-shot streamed request; close the socket afterwards so an
            # unread body (401/413) can never poison a kept-alive connection.
            self.close_connection = True
            self._handle_upload()
            return

        if not _authorized(self):
            self._json(401, {"error": "unauthorized"})
            return

        if path == "/agentlink/v1/reading-events":
            payload, err = _read_json(self, MAX_JSON_BYTES)
            if err:
                self._json(400 if err == "bad request" else 413, {"error": err})
                return
            status, body = handle_reading_event(payload, time.time())
            self._json(status, body)
        elif path == "/agentlink/v1/excerpts":
            payload, err = _read_json(self, MAX_JSON_BYTES)
            if err:
                self._json(400 if err == "bad request" else 413, {"error": err})
                return
            status, body = handle_excerpt(payload, time.time())
            self._json(status, body)
        elif path == "/agentlink/v1/replies/ack":
            payload, err = _read_json(self, MAX_ACK_BYTES)
            if err:
                self._json(400, {"error": err})
                return
            ids = payload.get("reply_ids") if isinstance(payload, dict) else None
            if not isinstance(ids, list):
                self._json(400, {"error": "reply_ids must be a list"})
                return
            acked = store.ack_replies(CONFIG.db, ids)
            self._json(200, {"acked": acked})
        elif path == "/agentlink/v1/replies/inject":
            payload, err = _read_json(self, MAX_INJECT_BYTES)
            if err:
                self._json(400, {"error": err})
                return
            if not isinstance(payload, dict) or not payload.get("source_event_id") or not payload.get("text"):
                self._json(400, {"error": "source_event_id and text required"})
                return
            reply_id, inserted = store.store_reply(
                CONFIG.db,
                source_event_id=str(payload["source_event_id"]),
                text=str(payload["text"]),
            )
            self._json(200 if not inserted else 201,
                       {"reply_id": reply_id, "status": "stored" if inserted else "duplicate"})
        elif path == "/agentlink/v1/books/probe":
            payload, err = _read_json(self, MAX_JSON_BYTES)
            if err:
                self._json(400, {"error": err})
                return
            status, body = handle_probe(payload)
            self._json(status, body)
        elif path == "/agentlink/v1/books/manifest":
            payload, err = _read_json(self, MAX_JSON_BYTES)
            if err:
                self._json(400, {"error": err})
                return
            status, body = handle_manifest(payload)
            self._json(status, body)
        else:
            self._json(404, {"error": "not found"})

    # --- streamed upload ----------------------------------------------------

    def _handle_upload(self) -> None:
        if not _authorized(self):
            self._json(401, {"error": "unauthorized"})
            return
        content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        if content_type != "application/octet-stream":
            self._json(415, {"error": "unsupported media type"})
            return
        try:
            content_length = int(self.headers.get("Content-Length", -1))
        except (TypeError, ValueError):
            content_length = -1
        if content_length <= 0:
            self._json(400, {"error": "invalid content length"})
            return
        if content_length > books_mod.MAX_UPLOAD_BYTES:
            self._json(413, {"error": "payload too large"})
            return

        def header(name: str) -> str | None:
            value = self.headers.get(name) or self.headers.get(name.lower())
            return str(value) if value else None

        library = CONFIG.library
        incoming = library / ".incoming"
        incoming.mkdir(parents=True, exist_ok=True)
        temp_path = incoming / f"{uuid.uuid4().hex}.part"
        digest = hashlib.sha256()
        remaining = content_length
        try:
            with open(temp_path, "wb") as sink:
                while remaining > 0:
                    chunk = self.rfile.read(min(CHUNK_BYTES, remaining))
                    if not chunk:
                        break
                    sink.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
            if remaining > 0:
                temp_path.unlink(missing_ok=True)
                self._json(400, {"error": "truncated upload"})
                return
            sha256 = digest.hexdigest()
            books_mod.ensure_books_table(CONFIG.db)
            import sqlite3

            with closing(sqlite3.connect(CONFIG.db)) as conn:
                row = conn.execute("SELECT id, title, author FROM books WHERE sha256 = ?", (sha256,)).fetchone()
            if row is not None:
                temp_path.unlink(missing_ok=True)
                self._json(200, {"status": "duplicate",
                                 "book": {"id": row[0], "sha256": sha256, "title": row[1], "author": row[2]}})
                return
            try:
                metadata = books_mod.read_epub_metadata(temp_path)
            except books_mod.InvalidBook as exc:
                temp_path.unlink(missing_ok=True)
                self._json(400, {"error": "invalid epub", "detail": str(exc)})
                return
            final_path = books_mod.unique_target(library, books_mod.safe_file_name(header("X-Agentlink-File-Name")), sha256)
            os.replace(temp_path, final_path)
            record = books_mod.register_file(CONFIG.db, final_path)
            self._json(201, {"status": "received", "upload_id": header("X-Agentlink-Upload-Id"),
                             "book": {"id": record["id"], "sha256": record["sha256"],
                                      "title": record["title"], "author": record["author"]}})
        except Exception as exc:  # noqa: BLE001 — keep the device contract
            temp_path.unlink(missing_ok=True)
            log.error("upload failed: %s", exc)
            self._json(500, {"error": "internal error"})


from contextlib import closing  # noqa: F401  (also used by the upload handler)


# --- handlers -----------------------------------------------------------------

def _envelope_clean(payload: dict[str, Any]) -> tuple[str | None, str | None]:
    """Validate the shared fields of one door event. Returns (error, door)."""
    if not isinstance(payload, dict):
        return "payload must be an object", None
    if not str(payload.get("event_id") or "").strip():
        return "event_id required", None
    door = payload.get("door")
    if door not in ("deep", "quick"):
        return "door must be deep or quick", None
    selection = payload.get("selection")
    if not isinstance(selection, dict) or not str(selection.get("text") or "").strip():
        return "selection.text required", None
    return None, door


def handle_excerpt(payload: Any, received_at: float) -> tuple[int, dict[str, Any]]:
    error, door = _envelope_clean(payload)
    if error:
        return 400, {"error": "bad request", "detail": error}
    event_id = str(payload["event_id"])
    row_id, inserted = store.store_excerpt(CONFIG.db, {**payload, "door": door}, received_at)
    if not inserted:
        return 200, {"status": "duplicate", "event_id": event_id}
    if CONFIG.webhook_url:
        try:
            forward_to_agent(event_id, door, payload)
        except Exception as exc:  # noqa: BLE001 — the excerpt is stored either way
            log.warning("agent webhook forward failed: %s", exc)
    return 202, {"status": "accepted", "event_id": event_id, "inbox_id": row_id, "door": door}


def forward_to_agent(event_id: str, door: str, payload: dict[str, Any]) -> None:
    """Best-effort POST of one door event to the configured agent webhook.

    The relay supplies no reading context of its own; agents that want
    no-spoiler context should fetch the book it registered and build it.
    See docs/agent-integration.md.
    """
    book = payload.get("book") if isinstance(payload.get("book"), dict) else {}
    position = payload.get("position") if isinstance(payload.get("position"), dict) else {}
    selection = payload.get("selection") if isinstance(payload.get("selection"), dict) else {}
    body = json.dumps({
        "event_id": event_id,
        "door": door,
        "book_title": str(book.get("title") or ""),
        "book_author": str(book.get("author") or ""),
        "progress": position.get("progress"),
        "reader_note": str(payload.get("note") or ""),
        "selection": str(selection.get("text") or ""),
    }, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        CONFIG.webhook_url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=WEBHOOK_TIMEOUT_SECONDS) as response:
        response.read()


def handle_reading_event(payload: Any, received_at: float) -> tuple[int, dict[str, Any]]:
    if not isinstance(payload, dict):
        return 400, {"error": "bad request"}
    event_id = str(payload.get("event_id") or "").strip()
    event = str(payload.get("event") or "").strip()
    if not event_id or event not in ("book_open", "progress", "chapter_changed", "reading_end"):
        return 400, {"error": "bad request"}
    inserted, state = store.store_reading_event(CONFIG.db, payload, received_at)
    return (202 if inserted else 200), {"status": state, "event_id": event_id}


def handle_probe(payload: Any) -> tuple[int, dict[str, Any]]:
    if not isinstance(payload, dict):
        return 400, {"error": "bad request"}
    book = payload.get("book") if isinstance(payload.get("book"), dict) else {}
    file_info = payload.get("file") if isinstance(payload.get("file"), dict) else None
    partial = file_info.get("partial_md5") if file_info else None
    size = file_info.get("size") if file_info else None
    if not isinstance(partial, str) or len(partial.strip()) != 32:
        return 400, {"error": "bad request", "detail": "file.partial_md5 must be 32-hex"}
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        return 400, {"error": "bad request", "detail": "file.size must be a positive integer"}
    clean = {
        "partial_md5": partial.strip().lower(),
        "size": size,
        "title": str(book.get("title") or "").strip() or None,
        "author": str(book.get("author") or "").strip() or None,
    }
    return 200, books_mod.probe(CONFIG.db, clean)


def handle_manifest(payload: Any) -> tuple[int, dict[str, Any]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("books"), list):
        return 400, {"error": "books must be a list"}
    clean_books = []
    for raw in payload["books"][:2000]:
        if not isinstance(raw, dict):
            continue
        partial = str(raw.get("partial_md5") or "").strip().lower()
        size = raw.get("size")
        path = str(raw.get("path") or "").strip()
        if len(partial) != 32 or isinstance(size, bool) or not isinstance(size, int) or size <= 0 or not path:
            continue
        clean_books.append({
            "path": path, "partial_md5": partial, "size": size,
            "title": str(raw.get("title") or "").strip() or None,
            "author": str(raw.get("author") or "").strip() or None,
        })
    return 200, books_mod.match_manifest(CONFIG.db, {"books": clean_books})


def main(argv: list[str] | None = None) -> int:
    arg_parser = argparse.ArgumentParser(description="Kindle AgentLink relay")
    arg_parser.add_argument("--config", help="JSON config file (see examples/)")
    args = arg_parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
    if args.config:
        CONFIG.apply_file(args.config)
    books_mod.ensure_books_table(CONFIG.db)
    server = ThreadingHTTPServer(("0.0.0.0", CONFIG.port), RelayHandler)
    log.info("AgentLink relay listening on port %d", CONFIG.port)
    log.info("library=%s db=%s webhook=%s", CONFIG.library, CONFIG.db, CONFIG.webhook_url or "(none)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
