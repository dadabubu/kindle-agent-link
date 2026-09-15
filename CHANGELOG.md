# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
