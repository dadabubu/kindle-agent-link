"""Contract tests for the Kindle AgentLink KOReader plugin.

Text-level contracts, same style the project uses everywhere: the plugin is
Lua and runs on e-ink hardware, so the tests pin the load-bearing strings and
shapes instead of executing them. Run:  pytest tests/ -q
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "koplugin"
MAIN = PLUGIN / "main.lua"
MODULES = PLUGIN / "agentlink"
CONFIG = MODULES / "config.lua"
CONTEXT = MODULES / "context.lua"
NET = MODULES / "net.lua"
QUEUE = MODULES / "queue.lua"
READING = MODULES / "reading.lua"
DIALOG = MODULES / "dialog.lua"
BOOKS = MODULES / "books.lua"
UPLOAD_QUEUE = MODULES / "upload_queue.lua"

ALL_LUA = (MAIN, CONFIG, CONTEXT, NET, QUEUE, READING, DIALOG, BOOKS, UPLOAD_QUEUE)


def source(path: Path) -> str:
    assert path.is_file(), f"missing file: {path}"
    return path.read_text(encoding="utf-8")


def all_source() -> str:
    return "\n".join(source(p) for p in ALL_LUA)


def test_entry_file_is_lifecycle_and_wiring_only():
    text = source(MAIN)
    for hook in ("function AgentLink:init()", "function AgentLink:onReaderReady()",
                 "function AgentLink:onSuspend()", "function AgentLink:onResume()",
                 "function AgentLink:onCloseDocument()", "function AgentLink:onNetworkConnected()",
                 "function AgentLink:addToMainMenu(menu_items)", "function AgentLink:addToHighlightDialog()"):
        assert hook in text
    for forbidden in ('require("ssl.https")', "ltn12.source.string", "function AgentLink:drainQueue",
                      "function AgentLink:postJSON", "lfs.dir(", "partialMD5"):
        assert forbidden not in text, f"entry file still owns: {forbidden}"


def test_config_defaults_are_placeholders_and_names_configurable():
    text = source(CONFIG)
    assert "https://your-relay.example.com/agentlink/v1/" in text
    assert 'Config.DEFAULT_AGENT_NAME = "Agent"' in text
    assert 'Config.DEFAULT_DEEP_LABEL' in text
    assert 'Config.DEFAULT_QUICK_LABEL' in text
    assert "sample-private-host" not in all_source().lower()


def test_reading_events_use_the_contract_envelope():
    reading = source(READING)
    assert 'buildReadingEvent("book_open")' in reading
    assert 'buildReadingEvent("progress"' in reading
    assert 'buildReadingEvent("reading_end"' in reading
    assert "PROGRESS_PAGE_INTERVAL" in reading
    assert "device_sent_at = tostring(os.time())" in reading
    assert "kind = \"reading_sync\"" not in reading  # relay tags the kind on ingest


def test_doors_share_one_endpoint_and_carry_a_door_field():
    dialog = source(DIALOG)
    assert 'buildDoorEvent("deep", note, selected_text)' in dialog
    assert 'buildDoorEvent("quick", text, selected_text)' in dialog
    assert 'kind = "excerpt"' in dialog
    builder = dialog.split("function Dialog:buildDoorEvent(door, note, selected_text)", 1)[1].split(
        "\nfunction Dialog:", 1)[0]
    assert 'door = door' in builder
    net = source(NET)
    post = net.split("function Net:postJSON(payload)", 1)[1].split("\nfunction Net:", 1)[0]
    assert 'payload.kind == "reading_sync"' in post  # everything else → excerpt endpoint


def test_door_labels_and_agent_name_come_from_settings():
    dialog = source(DIALOG)
    assert "function Dialog:agentName()" in dialog
    assert "function Dialog:deepLabel()" in dialog
    assert "function Dialog:quickLabel()" in dialog
    assert '"agent_name"' in dialog
    assert '"deep_entry_label"' in dialog
    assert '"quick_entry_label"' in dialog


def test_reply_window_waits_for_the_matching_source_event():
    dialog = source(DIALOG)
    assert "function Dialog:startReplyFetchWindow(event_id)" in dialog
    fetch = dialog.split("function Dialog:fetchAndShowReplies(callback)", 1)[1].split(
        "function Dialog:startReplyFetchWindow", 1
    )[0]
    assert "reply.source_event_id == self.reply_fetch_expected_event_id" in fetch
    assert "callback(true, matched_expected)" in fetch
    window = dialog.split("function Dialog:scheduleReplyFetch(delay)", 1)[1].split(
        "function Dialog:_footerUnreadText", 1
    )[0]
    assert "if matched_expected then" in window
    assert "self:scheduleReplyFetch(5)" in window
    assert "REPLY_FETCH_WINDOW_SECONDS" in dialog


def test_queues_are_atomic_and_single_flight():
    queue = source(QUEUE)
    assert 'io.open(tmp_path, "w")' in queue
    assert "os.rename(tmp_path, final_path)" in queue
    assert "self.draining = false" in queue
    assert "self.drain_scheduled = false" in queue
    assert "function Queue:scheduleDrainIfConnected(delay)" in queue


def test_uploads_are_an_independent_channel_with_agentlink_headers():
    upload = source(UPLOAD_QUEUE)
    assert "self.net:uploadFile(" in upload
    assert 'self.net:startAsync("upload-drain"' in upload
    assert "postJSON" not in upload
    for header in ("X-Agentlink-Upload-Id", "X-Agentlink-File-Name", "X-Agentlink-Size", "X-Agentlink-Partial-MD5"):
        assert header in upload
    net = source(NET)
    assert "ltn12.source.file(" in net
    assert '"application/octet-stream"' in net
    assert "MAX_UPLOADS_PER_PASS = 1" in upload


def test_books_are_fingerprinted_with_koreader_sampling():
    context = source(CONTEXT)
    assert "util.partialMD5" in context
    assert "function Context.fileFingerprint(path)" in context
    books = source(BOOKS)
    assert "function Books:probeCurrentBook(callback)" in books
    assert "function Books:sendCurrentBook()" in books
    assert "function Books:syncDirectory()" in books


def test_footer_and_menu_badges_use_the_configured_agent_name():
    dialog = source(DIALOG)
    assert 'string.format("%s·%d", self:agentName(), self.unread_count)' in dialog
    main = source(MAIN)
    assert 'string.format("%s（%d）", agent_name, unread)' in main


def test_reply_fetch_backs_off_after_network_failure_then_resets():
    dialog = source(DIALOG)
    # the delay ladder is exactly 10/30/60/120, one attempt per failure
    assert "REPLY_FETCH_BACKOFF_DELAYS = { 10, 30, 60, 120 }" in dialog
    fetch = dialog.split("function Dialog:fetchAndShowReplies(callback)", 1)[1].split(
        "function Dialog:startReplyFetchWindow", 1
    )[0]
    # nil payload from the network layer is signalled as a transport
    # failure, not folded into an empty mailbox
    assert "callback(false, nil, true)" in fetch
    window = dialog.split("function Dialog:scheduleReplyFetch(delay)", 1)[1].split(
        "function Dialog:_footerUnreadText", 1
    )[0]
    assert "if network_failed then" in window
    assert "self:_scheduleReplyFetchBackoff()" in window
    # any success (data or empty) clears the counter
    assert "self.reply_fetch_backoff_attempts = 0" in window
    # single-flight mutexes stay authoritative on every scheduling path
    assert (
        "if self.reply_fetch_scheduled or self.reply_fetch_in_flight then return end"
        in dialog
    )


def test_reading_resume_restarts_clock_and_resume_is_unconditional():
    reading = source(READING)
    resume = reading.split("function Reading:onResume()", 1)[1].split(
        "function Reading:_chapterAtPage", 1
    )[0]
    # a live session re-arms its clock on wake even if Suspend never fired
    assert "if self.session_active then" in resume
    assert "self.session_started_at = os.time()" in resume
    end_session = reading.split("function Reading:endSession()", 1)[1].split(
        "function Reading:startSession", 1
    )[0]
    # duration fuse against a session that silently crossed screen-off
    assert "math.min(duration, MAX_SESSION_SECONDS)" in end_session
    assert "MAX_SESSION_SECONDS = 6 * 3600" in reading
    main = source(MAIN)
    on_resume = main.split("function AgentLink:onResume()", 1)[1].split(
        "function AgentLink:onPageUpdate", 1
    )[0]
    assert "if self.reading:onResume() then" not in on_resume
    assert "self.dialog:scheduleReplyFetch(1.5)" in on_resume
    assert "[agentlink] wifi not ready on resume, ensuring..." in main
    assert 'require("ui/network/manager")' in main


def test_no_private_names_anywhere():
    text = all_source().lower()
    for forbidden in ("sample-private-agent", "sample-private-reader", "sample-private-host", "hermes", "sample-reader",
                      "sample-deep-label", "sample-quick-label", "sample-private-endpoint", "e:/sampledata"):
        assert forbidden not in text, f"private name leaked: {forbidden}"
