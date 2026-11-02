# Kindle AgentLink KOReader Plugin

A KOReader plugin connecting your reading on Kindle to your self-hosted AI agent relay.

## Installation

1. Copy this folder (`agentlink.koplugin`) to your KOReader plugins directory:
   `koreader/plugins/agentlink.koplugin`
2. Create or configure your settings file on the device at:
   `koreader/settings/agentlink.lua`
   (Example configuration is provided in the repository under `examples/koplugin-settings.example.lua`).
3. Restart KOReader.

## Features

- **Reading State Synchronization**: Tracks `book_open`, progress, chapter changes, and reading sessions.
- **Two Selection Doors**: Send highlighted text as a quick question or a deep discussion.
- **Replies & Offline History**: View agent answers on the page where asked, or review past Q&A per-book while offline.
- **Native Dropdown Control Panel**: Embedded in KOReader's top TouchMenu bar with quick access to replies, library sync, queue status, Wi-Fi, and frontlight brightness/warmth controls.
- **Book Transfer**: Probe and sync books with your agent library.

## License

This plugin is licensed under the MIT License. See `LICENSE` for details.
