# HTTP Contract

All endpoints live under `/agentlink/v1/` on your relay. Authentication is
one bearer token shared by the device and your agent:

```
Authorization: Bearer <token>
```

JSON bodies are UTF-8. Uploads are raw `application/octet-stream`. Every
response is a JSON object.

## Reading events

### `POST /agentlink/v1/reading-events`

Ingest one reading-state event. Idempotent by `event_id`: the first delivery
returns `202 {"status": "accepted", "event_id": "..."}`, repeats return
`200 {"status": "duplicate", ...}`.

Envelope (all fields bounded text unless noted):

```json
{
  "event_id": "1789000000-000001",
  "kind": "reading_sync",
  "event": "book_open | progress | chapter_changed | reading_end",
  "book": {"source": "koreader", "book_id": "<partial md5>", "title": "...", "author": "..."},
  "position": {"progress": 39.09, "page": 249, "chapter_uid": "chapter:18", "chapter_title": "..."},
  "duration_seconds": 1800,          // reading_end only
  "device_sent_at": "1789000000"
}
```

Notes:

- `progress` is a percentage, 0–100, one decimal place, sampled at most once
  per 5 page turns.
- Back-paging never lowers the farthest reading boundary on the agent side;
  the device only reports where the reader currently is.
- Invalid event types or oversized bodies: `400`. Missing auth: `401`.

## Selection doors

### `POST /agentlink/v1/excerpts`

One endpoint, two doors. Idempotent by `event_id` (`202 accepted` /
`200 duplicate`).

```json
{
  "event_id": "1789000000-000005",
  "kind": "excerpt",
  "door": "deep | quick",
  "note": "the reader's own words (deep: optional; quick: required)",
  "selection": {"text": "the highlighted passage"},
  "book": {"title": "...", "author": "...", "book_id": "..."},
  "position": {"progress": 42.5},
  "sent_at": "1789000000"
}
```

Contract semantics:

- `door=quick` is the lightweight exchange — the note is the message.
- `door=deep` is the discussion — the selection is required, the note is
  optional.
- `400` when `door` is missing/unknown, `selection.text` is blank, or the
  body is not JSON.
- What the agent receives and how context is bounded is an agent-side
  decision; see `docs/agent-integration.md` for the recommended no-spoiler
  rule (text strictly before the selection in the same chapter).

## Replies

Replies are stored server-side and pulled by the device.

### `GET /agentlink/v1/replies?after=<reply_id>&limit=<n>`

Device fetch. Returns

```json
{"replies": [{"reply_id": 14, "source_event_id": "1789000000-000005",
              "text": "...", "created_at": 1789000097, "kindle_status": "pending",
              "question": "...", "selection": "...", "progress": 42.5,
              "book_title": "..."}],
 "next_after": 14}
```

`kindle_status` is `pending` until an ack arrives.

### `POST /agentlink/v1/replies/ack`

```json
{"reply_ids": [14]}
```

Marks replies read on the device (`{"acked": <n>}`). Read state never
deletes history.

### `POST /agentlink/v1/replies/inject` — relay-local extension

Backfill one agent reply without going through the webhook:

```json
{"source_event_id": "1789000000-000005", "text": "the agent's answer"}
```

Returns `201 {"status": "stored", "reply_id": ...}` or `200 duplicate`.
This endpoint is part of the reference relay, not of the device contract;
hosted deployments may replace it with their own queue.

### Agent webhook (optional relay configuration)

If `agent_webhook_url` is configured, every newly stored excerpt is also
POSTed to it as JSON:

```json
{"event_id": "...", "door": "deep | quick", "book_title": "...",
 "book_author": "...", "progress": 42.5, "reader_note": "...",
 "selection": "..."}
```

The forward is best-effort with a 3-second timeout; a failed forward never
removes the stored excerpt. The relay itself supplies **no** reading
context — agents fetch the registered book (below) and build bounded
context themselves.

## Books

Fingerprints use KOReader's sampled MD5 (1024-byte samples at offsets 0,
1 KiB, 4 KiB, 16 KiB … `1024 << 2i`, stopping at EOF), so the device never
hashes a whole book. The relay stores the full SHA-256 of registered files.

### `POST /agentlink/v1/books/probe`

```json
{"event_id": "...", "book": {"title": "...", "author": "..."},
 "file": {"partial_md5": "<32 hex>", "size": 10948239}}
```

Verdicts: `present` (same sampled MD5 and size), `changed` (same normalized
title, different fingerprint), `missing`. Returns
`{"status": "...", "book": {"id", "sha256", "title", "author"}}` where a
book matched.

### `POST /agentlink/v1/books/upload`

Raw EPUB bytes, `Content-Type: application/octet-stream`, headers:

```
X-Agentlink-Upload-Id:  <device event id, for tracing>
X-Agentlink-File-Name:  <URL-encoded file name>
X-Agentlink-Size:       <declared byte size>
X-Agentlink-Partial-MD5:<declared sampled MD5>
```

Streaming ingest with a 64 MiB cap. `201 received` (with the registered
book), `200 duplicate` (same SHA-256 already registered — never a second
copy), `400 invalid epub | truncated upload | fingerprint mismatch`,
`413 payload too large`. The connection is closed after every upload.

### `POST /agentlink/v1/books/manifest`

```json
{"books": [{"path": "sub/book.epub", "size": 123, "mtime": 1789000000,
            "partial_md5": "<32 hex>", "title": "...", "author": "..."}]}
```

Returns only what the device must act on:

```json
{"known": 3, "missing": [{"path", "partial_md5", "size"}],
 "changed": [{"path", "partial_md5", "size", "book": {...}}], "invalid": 0}
```

## Error model

`401` unauthorized · `400` malformed envelope · `404` unknown route ·
`413` body over the per-endpoint cap · `415` wrong upload media type ·
`500` relay fault. Device-side queues retry anything that is not a
permanent `4xx` rejection of the file itself.
