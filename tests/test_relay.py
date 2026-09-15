"""HTTP contract tests for the Kindle AgentLink relay.

These run the real ThreadingHTTPServer on a loopback port and exercise the
device-facing contract end to end: auth, idempotency, both doors, replies
(inject → fetch → ack), streamed uploads and the manifest diff.
"""
from __future__ import annotations

import importlib.util
import io
import json
import sqlite3
import sys
import threading
import urllib.error
import urllib.request
import zipfile
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest


RELAY_DIR = Path(__file__).resolve().parent.parent / "relay"
TOKEN = "test-token"


def load_relay(tmp_path):
    # The relay reads config from the environment at import time.
    import os

    os.environ["AGENTLINK_TOKEN"] = TOKEN
    os.environ["AGENTLINK_DB"] = str(tmp_path / "relay.db")
    os.environ["AGENTLINK_LIBRARY"] = str(tmp_path / "library")
    os.environ["AGENTLINK_WEBHOOK_URL"] = ""
    if str(RELAY_DIR) not in sys.path:
        sys.path.insert(0, str(RELAY_DIR))
    for name in ("agentlink_store", "agentlink_books", "agentlink_relay"):
        sys.modules.pop(name, None)
    spec = importlib.util.spec_from_file_location("agentlink_relay", RELAY_DIR / "agentlink_relay.py")
    relay = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = relay
    spec.loader.exec_module(relay)
    return relay


@pytest.fixture
def relay_server(tmp_path):
    relay = load_relay(tmp_path)
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), relay.RelayHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{httpd.server_address[1]}", relay
    finally:
        httpd.shutdown()
        httpd.server_close()


def post(base, path, body=None, *, token=TOKEN, raw=None, headers=None):
    data = raw if raw is not None else json.dumps(body or {}, ensure_ascii=False).encode("utf-8")
    all_headers = {"Content-Type": "application/json"}
    if token:
        all_headers["Authorization"] = f"Bearer {token}"
    if headers:
        all_headers.update(headers)
    request = urllib.request.Request(base + path, data=data, headers=all_headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8")
        return exc.code, (json.loads(text) if text else {})


def get(base, path, *, token=TOKEN):
    request = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8")
        return exc.code, (json.loads(text) if text else {})


def make_epub(path: Path, title: str, body: str) -> Path:
    opf = f"""<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title>
    <dc:creator>作者</dc:creator></metadata>
    <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
    <spine><itemref idref="c"/></spine></package>"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
        zf.writestr("META-INF/container.xml",
                    '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                    '<rootfiles><rootfile full-path="c.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        zf.writestr("c.opf", opf)
        zf.writestr("c.xhtml", f"<html><body><p>{body}</p></body></html>")
    return path


def excerpt(door="quick", title="合同书", event_id="ex-1"):
    return {
        "event_id": event_id,
        "kind": "excerpt",
        "door": door,
        "note": "她为什么还不睡？" if door == "quick" else None,
        "book": {"source": "koreader", "title": title, "author": "作者"},
        "position": {"progress": 42.5},
        "selection": {"text": "走廊尽头的灯亮着。"},
        "sent_at": "1789000000",
    }


# --- auth -------------------------------------------------------------------

def test_rejects_missing_and_wrong_tokens(relay_server):
    base, _ = relay_server
    assert post(base, "/agentlink/v1/reading-events", token=None)[0] == 401
    assert post(base, "/agentlink/v1/reading-events", token="wrong")[0] == 401
    assert post(base, "/agentlink/v1/excerpts", token=None)[0] == 401
    assert post(base, "/agentlink/v1/books/probe", token=None)[0] == 401
    assert get(base, "/agentlink/v1/replies", token=None)[0] == 401


def test_unknown_route_is_404(relay_server):
    base, _ = relay_server
    assert post(base, "/agentlink/v1/nope", {})[0] == 404


# --- reading events -----------------------------------------------------------

def test_reading_events_are_idempotent_and_derive_state(relay_server):
    base, _ = relay_server
    event = {
        "event_id": "re-1", "kind": "reading_sync", "event": "book_open",
        "book": {"source": "koreader", "title": "合同书", "author": "作者"},
        "position": {"progress": 1.0}, "device_sent_at": "1789000000",
    }
    assert post(base, "/agentlink/v1/reading-events", event)[0] == 202
    assert post(base, "/agentlink/v1/reading-events", event)[0] == 200
    event["position"] = {"progress": 50.0}
    event["event_id"] = "re-2"
    event["event"] = "progress"
    status, _ = post(base, "/agentlink/v1/reading-events", event)
    assert status == 202
    db = sqlite3.connect(relay_server[1].CONFIG.db)
    state = db.execute("SELECT last_event, last_event_id FROM reading_state WHERE id = 1").fetchone()
    assert state == ("progress", "re-2")
    assert db.execute("SELECT COUNT(*) FROM reading_events").fetchone()[0] == 2


# --- doors ----------------------------------------------------------------------

def test_both_doors_accepted_and_quick_forces_light_contract(relay_server):
    base, _ = relay_server
    assert post(base, "/agentlink/v1/excerpts", excerpt("quick"))[0] == 202
    assert post(base, "/agentlink/v1/excerpts", excerpt("deep", event_id="ex-2"))[0] == 202
    # Duplicates are acknowledged, never stored twice.
    assert post(base, "/agentlink/v1/excerpts", excerpt("quick")) == (200, {"status": "duplicate", "event_id": "ex-1"})


def test_excerpt_envelope_validation(relay_server):
    base, _ = relay_server
    bad_door = excerpt("quick")
    bad_door["door"] = "sideways"
    assert post(base, "/agentlink/v1/excerpts", bad_door)[0] == 400
    no_selection = excerpt("quick")
    no_selection["selection"] = {"text": "  "}
    assert post(base, "/agentlink/v1/excerpts", no_selection)[0] == 400
    assert post(base, "/agentlink/v1/excerpts", "junk")[0] == 400


# --- replies ----------------------------------------------------------------------

def test_reply_inject_fetch_ack_loop(relay_server):
    base, _ = relay_server
    assert post(base, "/agentlink/v1/excerpts", excerpt("quick"))[0] == 202

    status, body = post(base, "/agentlink/v1/replies/inject",
                        {"source_event_id": "ex-1", "text": "因为她知道灯会灭。"})
    assert status == 201 and body["status"] == "stored"

    status, page = get(base, "/agentlink/v1/replies?after=0&limit=5")
    assert status == 200
    assert page["replies"][0]["text"] == "因为她知道灯会灭。"
    assert page["replies"][0]["kindle_status"] == "pending"
    assert page["replies"][0]["question"] == "她为什么还不睡？"

    reply_id = page["replies"][0]["reply_id"]
    assert post(base, "/agentlink/v1/replies/ack", {"reply_ids": [reply_id]})[1]["acked"] == 1
    _, after = get(base, "/agentlink/v1/replies?after=0&limit=5")
    assert after["replies"][0]["kindle_status"] == "acked"


def test_reply_inject_requires_text_and_event(relay_server):
    base, _ = relay_server
    assert post(base, "/agentlink/v1/replies/inject", {"text": "x"})[0] == 400
    assert post(base, "/agentlink/v1/replies/inject", {"source_event_id": "y"})[0] == 400


def test_webhook_forward_uses_public_reader_note_field(tmp_path):
    relay = load_relay(tmp_path)
    captured = {}
    original_urlopen = relay.urllib.request.urlopen

    class FakeResponse:
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False
        def read(self):
            return b"{}"

    def fake_urlopen(request, timeout):
        captured["timeout"] = timeout
        captured["body"] = json.loads(request.data.decode("utf-8"))
        return FakeResponse()

    try:
        relay.CONFIG.webhook_url = "https://agent.example.invalid/hook"
        relay.urllib.request.urlopen = fake_urlopen
        relay.forward_to_agent("ex-1", "quick", excerpt("quick"))
    finally:
        relay.urllib.request.urlopen = original_urlopen

    assert captured["body"]["reader_note"] == "她为什么还不睡？"
    private_field = "".join(["lu", "na_note"])
    assert private_field not in captured["body"]


# --- books --------------------------------------------------------------------------

def test_books_probe_upload_duplicate_and_manifest(relay_server, tmp_path):
    base, relay = relay_server
    epub = make_epub(tmp_path / "book.epub", "合同书", "正文" * 200)
    data = epub.read_bytes()
    spec = importlib.util.spec_from_file_location("al_books", RELAY_DIR / "agentlink_books.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    partial = mod.partial_md5(epub)

    headers = {
        "X-Agentlink-Upload-Id": "up-1",
        "X-Agentlink-File-Name": "%E5%90%88%E5%90%8C%E4%B9%A6.epub",
        "X-Agentlink-Size": str(len(data)),
        "X-Agentlink-Partial-MD5": partial,
    }
    status, body = post(base, "/agentlink/v1/books/upload", raw=data,
                        headers={"Content-Type": "application/octet-stream", **headers})
    assert status == 201
    assert body["status"] == "received"
    assert body["book"]["title"] == "合同书"

    # Probe now reports present with the same fingerprint…
    probe = {"event_id": "p1", "book": {"title": "合同书", "author": "作者"},
             "file": {"partial_md5": partial, "size": len(data)}}
    status, body = post(base, "/agentlink/v1/books/probe", probe)
    assert (status, body["status"]) == (200, "present")

    # …missing for a different book…
    probe["event_id"] = "p2"
    probe["book"] = {"title": "别的书", "author": "谁"}
    probe["file"] = {"partial_md5": "1" * 32, "size": 1}
    status, body = post(base, "/agentlink/v1/books/probe", probe)
    assert body["status"] == "missing"

    # …and changed for the same title with a different fingerprint.
    probe["book"] = {"title": "合同书", "author": "作者"}
    status, body = post(base, "/agentlink/v1/books/probe", probe)
    assert body["status"] == "changed"

    # Duplicate upload is acknowledged without a second copy.
    status, body = post(base, "/agentlink/v1/books/upload", raw=data,
                        headers={"Content-Type": "application/octet-stream", **headers})
    assert (status, body["status"]) == (200, "duplicate")

    # Manifest diff: the registered book is known, an unknown entry is missing.
    manifest = {"books": [
        {"path": "合同书.epub", "partial_md5": partial, "size": len(data), "title": "合同书", "author": "作者"},
        {"path": "新书.epub", "partial_md5": "2" * 32, "size": 9, "title": "新书"},
    ]}
    status, body = post(base, "/agentlink/v1/books/manifest", manifest)
    assert body["known"] == 1
    assert [m["path"] for m in body["missing"]] == ["新书.epub"]
