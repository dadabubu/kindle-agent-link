# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026-11-02]

### Added

- Native KOReader dropdown control panel: independent embedded TouchMenu
  dropdown tab providing quick access to reply viewing (with badge), library
  sync actions, local sync queue status, Wi-Fi menu, and hardware frontlight
  brightness/warmth controls with instant toggle.
- Per-book offline reply history cached device-side under `agentlink-history/`
  with automatic cache-first display and online merge.
- Standalone network subprocess hygiene: glibc resolver reset (`__res_init`)
  and sweep/closure of leaked inherited socket descriptors before task execution.
- Owned TLS transport connection recovery: dual DNS peer retry before TLS
  handshake without hostname/SNI compromise, preserving stock LuaSec config.
- Queue drain batch watchdog scaling: timeout dynamically accounts for
  multi-request serial execution (`MAX_DRAIN_PER_PASS * timeout`).
- Automatic book probe recovery: exponential retry ladder (5/15/30s) with
  generation fencing to prevent stale probe races across document switches.

### Changed

- Reading-duration accounting corrections: session duration is reliably finalized
  and credited to the correct book upon document switches, and session clocks
  are defensively re-armed on wake/resume from sleep so asleep windows are
  never counted as active reading.
- Offline backfill & network recovery: quick questions delivered from offline
  queue trigger reply polling upon delivery, and queue drains automatically
  resume on network reconnection.

## [0.1.0-dev] - unreleased

### Added

- KOReader plugin: reading-state sync (`book_open`, throttled `progress`,
  `chapter_changed`, `reading_end`) with atomic offline queueing and
  per-channel drain budgets.
- Two configurable selection doors: `quick` (lightweight question) and
  `deep` (discussion with bounded pre-selection context supplied by the
  relay/agent side).
- Async replies: cursor-based fetch, unread badge on the reading footer and
  menus, per-card read state, async ACK, and return-to-saved-position.
- Book transfer interface: `books/probe` (present / missing / changed),
  streamed `books/upload` with SHA-256 and EPUB validation, and directory
  `books/manifest` for incremental sync.
- Minimal self-hosted relay (Python standard library only) with an
  agent webhook forwarder and a local reply-inject endpoint.
- HTTP contract documentation, install guide and agent integration guide.
