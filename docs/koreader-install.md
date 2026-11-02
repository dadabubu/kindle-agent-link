# Installing the plugin on a KOReader device

## What you need

- A KOReader installation on your Kindle (or any KOReader-supported device).
- A reachable relay (see `relay/` and `docs/agent-integration.md`).
- The bearer token your relay uses.

## 1. Copy the plugin

Plug the Kindle into your computer (USB) and copy the `koplugin/` directory
of this repository into the device's KOReader plugin directory, named
`agentlink.koplugin`:

```
koreader/plugins/agentlink.koplugin/
├── _meta.lua
├── main.lua
└── agentlink/
    ├── books.lua
    ├── config.lua
    ├── context.lua
    ├── dialog.lua
    ├── dropdownbody.lua
    ├── history.lua
    ├── https_transport.lua
    ├── net.lua
    ├── panel.lua
    ├── queue.lua
    ├── reading.lua
    ├── subprocess_hygiene.lua
    ├── topbar.lua
    └── upload_queue.lua
```

Verify after copying: the file count and sizes should match this repository
(the deployment is a plain directory replace; keep a backup of any previous
version so you can roll back).

## 2. Restart KOReader

KOReader only loads plugins at startup. Re-open KOReader after copying.

## 3. Configure the plugin

Create or edit `koreader/settings/agentlink.lua` on the device:

```lua
return {
    token = "your-bearer-token",
    -- server_url / excerpt_url / replies_url / replies_ack_url /
    -- books_probe_url / books_upload_url / books_manifest_url
    -- all default to https://your-relay.example.com/agentlink/v1/...
    -- override any of them if your relay lives elsewhere, e.g.:
    -- server_url = "https://relay.example.org/agentlink/v1/reading-events",
    agent_name = "Agent",          -- how the agent is named on screen
    deep_entry_label = "与 Agent 深谈",   -- the discussion door
    quick_entry_label = "快问 Agent",     -- the quick-question door
}
```

Write settings atomically (write a temp file, then replace) — the device
filesystem does not like partial files.

## 4. Use it

- **Reading state** is automatic: opening a book, page turns (throttled),
  crossing chapters and closing the book all queue events and drain when
  the network is up.
- **Selection doors**: hold-select a passage → two entries appear
  (your configured deep and quick labels). The quick door asks for a
  one-line message; the deep door lets you add an optional note.
- **Replies & offline history**: an unread badge (`Agent·N`) appends to
  the reading footer; the top menu and dropdown panel carry the same counter.
  Open it to read, swipe between replies, return to the saved position. Replies
  are cached on-device (`koreader/settings/agentlink-history/`) for offline
  reading. Read receipts are ACKed asynchronously.
- **Dropdown control panel**: top menu → AgentLink tab (or menu item) opens the
  native embedded dropdown panel with quick actions: reply viewer with unread
  count badge, library sync, queue status display, Wi-Fi menu, and frontlight
  brightness/warmth sliders with quick on/off toggle.
- **Books**: top menu → Tools → your agent's library submenu (or through the
  control panel) — send the current book, sync a directory, pause per-book,
  exclude directories, and choose whether uploads happen during reading or
  after you close it.

## Queue layout on the device

Queued items live under `koreader/data/agentlink-queue/`, one atomic JSON
file per item, in `reading/`, `dialog/` and `upload/` sub-directories.
Offline items survive restarts and drain automatically when the network
returns. Legacy files queued by older versions in the queue root keep
draining too.
