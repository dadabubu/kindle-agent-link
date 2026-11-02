"""Executable runtime tests for ported Lua modules under LuaJIT 2.1."""
from __future__ import annotations

import json
from pathlib import Path
import pytest

try:
    import lupa.luajit21
except ImportError:
    lupa = None

ROOT = Path(__file__).resolve().parent.parent
KOPLUGIN = (ROOT / "koplugin").as_posix()


@pytest.fixture
def lua():
    if lupa is None:
        pytest.skip("lupa with LuaJIT 2.1 required for runtime tests")
    runtime = lupa.luajit21.LuaRuntime()
    # Configure package.path to resolve koplugin modules
    runtime.execute(
        """
        local base = ...
        package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

        -- On Windows, os.rename fails if destination already exists; shim to emulate POSIX atomic rename
        local orig_rename = os.rename
        os.rename = function(old, new)
            os.remove(new)
            return orig_rename(old, new)
        end
        """,
        KOPLUGIN,
    )
    return runtime


def test_native_topbar_insert_switch_cleanup(lua):
    """Test native topbar insert, switch tab callback, detach cleanup, and deactivation."""
    code = """
    local shown_index = nil
    local detach_called = false

    package.preload["ui/uimanager"] = function()
        return {
            show = function(...) end,
            close = function(...) end,
            scheduleIn = function(...) end,
            setDirty = function(...) end,
        }
    end

    local Topbar = require("agentlink.topbar")

    local menu = {
        tab_item_table = {
            { id = "native_tab_1", text = "Tab 1" }
        },
        setUpdateItemTable = function(self)
            self.tab_item_table = { { id = "native_tab_1", text = "Tab 1" } }
        end,
        onShowMenu = function(self, index, hidden)
            shown_index = index
            if not self.menu_container then
                self.menu_container = {
                    {
                        updateItems = function(this, ...) end,
                        bar = { switchToTab = function(this, idx) end },
                        item_group = { clear = function() end, getSize = function() return { h = 100 } end },
                        dimen = { copy = function() return { combine = function() end } end, w = 100, h = 100 },
                        bordersize = 1, padding = 1, width = 100,
                    }
                }
            end
            return true
        end,
        onTapCloseMenu = function(self) end,
        onCloseReaderMenu = function(self) end,
    }

    local function build_body(width, host)
        return {
            on_detach = function(self)
                detach_called = true
            end
        }
    end

    -- 1. Install topbar tab
    assert(Topbar.install(menu, build_body) == true, "install should return true")
    assert(#menu.tab_item_table == 2, "expected 2 tabs after install")
    assert(menu.tab_item_table[1].id == "agentlink_panel_topbar", "agentlink tab must be inserted at position 1")

    -- 2. Switch to tab
    assert(Topbar.show(menu) == true, "show should succeed")
    assert(shown_index == 1, "shown_index should match agentlink tab index 1")

    -- 3. Cleanup on menu close
    menu.menu_container = { { _agentlink_body = build_body(100, nil) } }
    menu:onCloseReaderMenu()
    assert(detach_called == true, "on_detach should be called on close")
    assert(menu.menu_container[1]._agentlink_body == nil, "body reference should be cleared")

    -- 4. Deactivate
    Topbar.deactivate(menu)
    assert(#menu.tab_item_table == 1, "agentlink tab removed after deactivate")
    assert(menu.tab_item_table[1].id == "native_tab_1", "native tab preserved")
    """
    lua.execute(code)


def test_quick_send_recovery_reply_polling_window(lua):
    """Test quick-send recovery starts reply polling window; empty result continues until match."""
    code = """
    local scheduled_tasks = {}

    table.insert(package.loaders, 2, function(modname)
        if not modname:find("^agentlink") then
            return function()
                local dummy = {
                    COLOR_GRAY = 1,
                    COLOR_BLACK = 0,
                    line = { medium = 1 },
                    screen = {
                        scaleBySize = function(self, x) return x or 1 end,
                        getWidth = function() return 600 end,
                        getHeight = function() return 800 end,
                    },
                    scaleBySize = function(self, x) return x or 1 end,
                    getFace = function() return "font" end,
                    show = function(...) end,
                    close = function(...) end,
                    scheduleIn = function(self, sec, fn)
                        table.insert(scheduled_tasks, { delay = sec, fn = fn })
                    end,
                    setDirty = function(...) end,
                    info = function() end,
                    warn = function() end,
                    getSettingsDir = function() return "/tmp" end,
                    mkdir = function() return true end,
                }
                dummy.__index = dummy
                function dummy:new(o) return setmetatable(o or {}, dummy) end
                return dummy
            end
        end
    end)

    package.preload["json"] = function()
        return {
            encode = function() return "{}" end,
            decode = function() return {} end,
        }
    end

    package.preload["agentlink.context"] = function()
        return {
            bookIdentity = function() return { title = "Sample Book" } end,
            newEventId = function() return "evt-test" end,
        }
    end

    local Dialog = require("agentlink.dialog")
    local fake_replies_payload = nil

    local dialog = Dialog:new{
        ui = {},
        queue = {
            _networkRadioOn = function() return true end,
        },
        net = {
            settings = {
                readSetting = function(self, k) return "http://fake" end,
            },
            requestJSONAsync = function(self, label, url, callback)
                callback(fake_replies_payload)
                return true
            end,
        },
    }

    -- 1. Offline delivery recovery triggers matching poll window
    dialog:onLightDelivered("light-target-456")
    assert(dialog.reply_fetch_expected_event_id == "light-target-456", "expected event id should be set")
    assert(dialog.reply_fetch_deadline ~= nil, "deadline must be set")
    assert(#scheduled_tasks == 1, "fetch task scheduled")
    assert(scheduled_tasks[1].delay == 3, "initial delay should be 3s")

    -- 2. First poll returns empty replies list: polling MUST CONTINUE, not stop
    fake_replies_payload = { replies = {} }
    local poll1 = table.remove(scheduled_tasks, 1)
    poll1.fn()

    assert(#scheduled_tasks == 1, "polling should continue after empty result")
    assert(scheduled_tasks[1].delay == 5, "refetch interval is 5s")
    assert(dialog.reply_fetch_expected_event_id == "light-target-456", "expected event id still tracked")

    -- 3. Next poll returns matching reply: polling window terminates
    fake_replies_payload = {
        replies = {
            {
                reply_id = 101,
                source_event_id = "light-target-456",
                text = "Recovered response",
            }
        }
    }
    local poll2 = table.remove(scheduled_tasks, 1)
    poll2.fn()

    assert(dialog.reply_fetch_expected_event_id == nil, "expected event id cleared on match")
    assert(dialog.reply_fetch_deadline == nil, "deadline cleared on match")
    assert(#scheduled_tasks == 0, "no further polling scheduled")
    """
    lua.execute(code)


def test_per_book_history_merge_and_cache_isolation(lua, tmp_path):
    """Test per-book history merge, deduplication, sorting and cache isolation between books."""
    storage_dir = (tmp_path / "settings").as_posix()
    (tmp_path / "settings" / "agentlink-history").mkdir(parents=True, exist_ok=True)

    def py_encode(obj):
        def convert(v):
            if hasattr(v, "keys"):
                keys = list(v.keys())
                if keys and all(isinstance(k, int) for k in keys) and min(keys) == 1 and max(keys) == len(keys):
                    return [convert(v[i]) for i in range(1, len(keys) + 1)]
                return {str(k): convert(val) for k, val in v.items()}
            elif isinstance(v, (list, tuple)):
                return [convert(x) for x in v]
            return v
        return json.dumps(convert(obj))

    def to_lua(val):
        if isinstance(val, dict):
            return lua.table_from({k: to_lua(v) for k, v in val.items()})
        elif isinstance(val, list):
            return lua.table_from([to_lua(x) for x in val])
        return val

    def py_decode(s):
        return to_lua(json.loads(s))

    code = """
    local storage_dir, py_encode, py_decode = ...

    package.preload["json"] = function()
        return {
            encode = function(tab) return py_encode(tab) end,
            decode = function(str) return py_decode(str) end,
        }
    end
    package.preload["datastorage"] = function()
        return { getSettingsDir = function() return storage_dir end }
    end
    package.preload["libs/libkoreader-lfs"] = function()
        return { mkdir = function() return true end }
    end

    local History = require("agentlink.history")
    local bookA = { title = "Alpha Book", book_id = "book_alpha" }
    local bookB = { title = "Beta Book", book_id = "book_beta" }

    -- Verify storage isolation
    assert(History.path(bookA) ~= History.path(bookB), "paths must be distinct")

    -- Add reply to Book A
    History.merge(bookA, {
        { reply_id = 11, book_title = "Alpha Book", text = "Ans A1", created_at = 100 }
    })

    -- Add reply to Book B
    History.merge(bookB, {
        { reply_id = 22, book_title = "Beta Book", text = "Ans B1", created_at = 200 }
    })

    -- Cache isolation: loading Book A gives only Book A
    local listA = History.load(bookA)
    assert(#listA == 1, "Book A should have 1 reply")
    assert(listA[1].reply_id == 11, "Book A reply id mismatch")

    local listB = History.load(bookB)
    assert(#listB == 1, "Book B should have 1 reply")
    assert(listB[1].reply_id == 22, "Book B reply id mismatch")

    -- Merge incoming duplicate and newer item into Book A
    History.merge(bookA, {
        { reply_id = 11, book_title = "Alpha Book", text = "Ans A1 duplicate", created_at = 100 },
        { reply_id = 33, book_title = "Alpha Book", text = "Ans A2", created_at = 300 },
    })

    local listA2 = History.load(bookA)
    assert(#listA2 == 2, "Book A should have 2 deduplicated replies")
    assert(listA2[1].reply_id == 33, "Newest reply first")
    assert(listA2[2].reply_id == 11, "Older reply second")

    -- Book B is completely unaffected
    local listB2 = History.load(bookB)
    assert(#listB2 == 1, "Book B remains isolated with 1 reply")
    assert(listB2[1].reply_id == 22, "Book B reply id preserved")
    """
    lua.execute(code, storage_dir, py_encode, py_decode)


def test_reading_time_accounting_book_switch_and_resume(lua):
    """Test reading duration accounting on book switch and silent sleep wake (onResume clock re-arm)."""
    code = """
    local simulated_time = 1000
    local current_book = "Book 1"

    package.preload["agentlink.context"] = function()
        return {
            bookIdentity = function() return { title = current_book } end,
            position = function() return { progress = 0.5 } end,
            newEventId = function() return "evt-" .. simulated_time end,
        }
    end

    os.time = function() return simulated_time end

    local sent_events = {}
    local mock_queue = {
        sendOrQueue = function(self, evt)
            table.insert(sent_events, evt)
            return true
        end,
    }

    local Reading = require("agentlink.reading")
    local reading = Reading:new{ ui = {}, queue = mock_queue }

    -- 1. Start Book 1 at t=1000
    reading:startSession()
    assert(reading.session_active == true, "session active")
    assert(sent_events[1].event == "book_open", "book_open emitted")

    -- 2. 300 seconds later, switch to Book 2
    simulated_time = 1300
    current_book = "Book 2"
    reading:startSession() -- Opening new book ends previous session

    assert(sent_events[2].event == "reading_end", "reading_end sent for previous book")
    assert(sent_events[2].duration_seconds == 300, "duration should be exactly 300s")
    assert(sent_events[2].book.title == "Book 1", "duration credited to Book 1")
    assert(sent_events[3].event == "book_open", "book_open sent for Book 2")
    assert(sent_events[3].book.title == "Book 2", "Book 2 book_open")

    -- 3. Sleep silently (missed Suspend hook), wake 8 hours later
    simulated_time = 30000
    reading:onResume() -- Wake: re-arms session_started_at so sleep time is not billed

    assert(reading.session_started_at == 30000, "session clock re-armed to wake time")

    -- Read for 90 seconds, then close
    simulated_time = 30090
    reading:onCloseDocument()

    assert(sent_events[4].event == "reading_end", "reading_end sent on document close")
    assert(sent_events[4].duration_seconds == 90, "duration billed is only active 90s, not sleep hours")
    assert(sent_events[4].book.title == "Book 2", "credited to Book 2")
    """
    lua.execute(code)


def test_batch_watchdog_timeout_scaling(lua, tmp_path):
    """Test batch watchdog timeout dynamically scales to MAX_DRAIN_PER_PASS * timeout."""
    queue_dir = (tmp_path / "queue").as_posix()
    (tmp_path / "queue").mkdir(parents=True, exist_ok=True)
    (tmp_path / "queue" / "task1.json").write_text('{"event_id":"task1"}')

    code = """
    local queue_dir = ...

    local set_timeout_label = nil
    local set_timeout_val = nil
    local started_label = nil

    package.preload["ui/uimanager"] = function() return { scheduleIn = function() end } end
    package.preload["logger"] = function() return { info = function() end, warn = function() end } end
    package.preload["ui/network/manager"] = function() return { isWifiOn = function() return true end } end
    package.preload["json"] = function() return { encode = function() return "{}" end, decode = function() return {} end } end
    package.preload["libs/libkoreader-lfs"] = function()
        return {
            dir = function()
                local files = { "task1.json" }
                local idx = 0
                return function()
                    idx = idx + 1
                    return files[idx]
                end
            end
        }
    end

    local mock_net = {
        DEFAULT_JOB_TIMEOUT_SECONDS = 20,
        startAsync = function(self, label, task, cb)
            started_label = label
            return true
        end,
        setJobTimeout = function(self, label, timeout)
            set_timeout_label = label
            set_timeout_val = timeout
        end,
    }

    local Queue = require("agentlink.queue")
    local queue = Queue:new{
        name = "test_channel",
        dir = queue_dir,
        net = mock_net,
    }

    queue:drain()

    assert(started_label == "queue-drain-test_channel", "drain job label mismatch")
    assert(set_timeout_label == "queue-drain-test_channel", "setJobTimeout label mismatch")
    -- MAX_DRAIN_PER_PASS (10) * DEFAULT_JOB_TIMEOUT_SECONDS (20) = 200
    assert(set_timeout_val == 200, "watchdog timeout must scale to 200s, got: " .. tostring(set_timeout_val))
    """
    lua.execute(code, queue_dir)
