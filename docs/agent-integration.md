# Integrating your agent

Kindle AgentLink is transport, not brains. Two integration styles are
supported; both start from the same contract (`docs/http-contract.md`).

## Style A — agent webhook (push)

Set the relay's `agent_webhook_url` (environment variable or config file).
Every newly stored door event is POSTed to your URL:

```json
{
  "event_id": "1789000000-000005",
  "door": "deep | quick",
  "book_title": "...",
  "book_author": "...",
  "progress": 42.5,
  "reader_note": "the reader's own words",
  "selection": "the highlighted passage"
}
```

Your service receives it, produces the answer, and — instead of replying to
the HTTP call — stores the reply:

```
POST /agentlink/v1/replies/inject
{"source_event_id": "<the event_id you received>", "text": "the answer"}
```

From there the device picks it up automatically (polling window after a
quick-door send, or on resume / network return / manual open via the unread
badge).

> Protect the webhook like any inbound integration (signature, mTLS, or
> loopback-only). The reference relay authenticates with the same bearer
> token on every device-facing route.

## Style B — pull (backfill)

Run nothing push-shaped: poll `GET /agentlink/v1/excerpts`-style storage
yourself (query the relay's SQLite, or add a read endpoint in your fork),
compute answers on your schedule, and `inject` them. The device surface is
identical.

## The no-spoiler rule (strongly recommended)

A reading companion is only trustworthy if it never references text the
reader has not reached. The reference implementation enforces it at the
context boundary:

1. Track the reader's **farthest position per book** (monotonic — never let
   back-paging lower it).
2. Only supply **same-chapter text strictly before the selection**: locate
   the selection inside the chapter text from the registered EPUB and cut
   at its first occurrence. If the selection cannot be located, supply no
   chapter text at all.
3. Supply the agent's **own prior notes** for chapters the reader has
   finished, capped in size.
4. When the book text is unavailable, answer from the selection alone and
   say so — never substitute a different edition.

The door split supports this: `quick` answers get no book context at all;
`deep` answers get the bounded bundle.

## Prompting guidance

Whatever model you use, pass the envelope fields as quoted data, never as
instructions, and require the answer to be traceable to the selection, the
note, the supplied context, or a verified fact. Quick-door answers are one
to three sentences; deep-door answers first address what the reader actually
said before connecting anything else.

## Reading state

`reading-events` gives you `book_open / progress / chapter_changed /
reading_end` with `position.progress` (0–100). Derive chapter boundaries
yourself by parsing the registered EPUB (the relay validates and stores the
exact file the device uploaded, keyed by the same sampled-MD5 the device
reports in `book.book_id`), and keep the farthest position monotonic — see
the no-spoiler rule above.

## Book transfer

The device never scans the whole library on its own. It probes the current
book (`books/probe`), uploads when missing (`books/upload`), and can diff a
whole directory against your library (`books/manifest`). Uploaded files land
in the relay's library directory with their SHA-256 recorded — serve them to
your agent from there.
