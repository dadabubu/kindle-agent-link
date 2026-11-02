# Kindle AgentLink

Connect your Kindle to the Agent you already use.

Kindle AgentLink is a KOReader plugin plus a small self-hosted relay that
keeps an AI agent in sync with your reading: it reports reading progress,
lets you send highlights to your agent with two configurable doors (a quick
question and a deep discussion), delivers the agent's replies back to the
page you were reading, and transfers book files so your agent can read the
same edition you do.

```
Kindle (KOReader plugin)  ──HTTPS──▶  your relay  ──▶  your agent
      ◀── replies / unread badge ──        ◀── webhook or inject
```

## What it is

- **Reading state sync** — `book_open` / throttled `progress` /
  `chapter_changed` / `reading_end` events with atomic offline queueing and
  wake-from-sleep duration accounting fixes.
- **Two selection doors** — highlight anything and send it either as a
  *quick* question (fast, lightweight) or as a *deep* discussion (bounded
  no-spoiler context supplied by the relay/agent side). Door names and the
  agent's display name are configurable.
- **Asynchronous replies & offline history** — replies are stored server-side,
  surfaced as an unread badge on the reading footer and menus, delivered to
  the exact page position that was saved with the question, and cached locally
  per-book for offline reading.
- **Native dropdown control panel** — independent embedded TouchMenu topbar
  tab offering quick access to reply viewing (with badge), library sync, local
  queue status, Wi-Fi settings, and hardware frontlight brightness and warmth
  controls with quick toggle.
- **Network resilience & subprocess hygiene** — worker subprocess isolation
  with inherited socket cleanup, glibc resolver resets, dual DNS peer retry
  before TLS handshake, batch queue watchdog timeouts, and auto probe recovery.
- **Book transfer interface** — probe / upload / manifest endpoints with
  sampled-MD5 fingerprints, full SHA-256 verification and EPUB validation,
  so your agent reads the same edition you do.

## What it is not

AgentLink does **not** include an agent. It is the transport and contract
between a Kindle and whatever agent you already run (a hosted LLM, your own
webhook worker, anything that can speak HTTP). See
`docs/agent-integration.md` for the two integration styles.

## Repository layout

```
koplugin/              KOReader plugin (drop-in, Lua only)
relay/                 Minimal self-hosted relay (Python 3 standard library)
docs/                  HTTP contract, install and agent-integration guides
examples/              Example configurations
tests/                 Contract tests (plugin + relay)
scripts/privacy-scan   Secret/privacy scanner used before publishing
```

## Quick start

1. Copy `koplugin/` to your Kindle as `koreader/plugins/agentlink.koplugin/`.
2. Run the relay somewhere reachable: `python relay/agentlink_relay.py`.
3. In KOReader, set the plugin's token and relay URL (see
   `docs/koreader-install.md`).
4. Point your agent at the relay (see `docs/agent-integration.md`).

All endpoints, envelopes and status codes are specified in
`docs/http-contract.md`.

## Development and Testing

The KOReader plugin is pure Lua and has no external dependencies.
Running the development test suite requires `pytest` and `lupa` (for LuaJIT 2.1 execution):

```bash
uv run --with lupa --with pytest python scripts/run-tests.py
```

These development dependencies are only used for test execution and verification, not by the plugin or relay.

## Status

`0.1.0-dev` — local candidate. The HTTP contract is stable within this
repository; breaking changes will be listed in `CHANGELOG.md`.

## License

MIT — see `LICENSE`.
