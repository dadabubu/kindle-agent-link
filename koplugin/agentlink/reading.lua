-- P1 reading-state module for agentlink (5.5 decoupling).
-- Owns the reading session state machine (book_open / throttled progress /
-- reading_end) and enqueues events on its own dedicated queue. The entry
-- file only forwards ReaderUI lifecycle hooks here.

local Context = require("agentlink.context")

local Reading = {}
Reading.__index = Reading

local PROGRESS_PAGE_INTERVAL = 5
-- Screen-off leak guard: a session that silently survived sleep (missed
-- Suspend event) must never bill an unbounded asleep window as reading.
local MAX_SESSION_SECONDS = 6 * 3600

function Reading:new(opts)
    local o = {
        ui = opts.ui,
        queue = opts.queue,
        session_started_at = nil,
        session_open_sent = false,
        session_active = false,
        session_suspended = false,
        session_book = nil,
        last_page_sent = nil,
    }
    setmetatable(o, Reading)
    return o
end

function Reading:buildReadingEvent(event_type, extra, page_hint)
    local book = Context.bookIdentity(self.ui)
    if not book then return nil end
    local event = {
        event_id = Context.newEventId(),
        event = event_type,
        book = book,
        position = Context.position(self.ui, page_hint),
        device_sent_at = tostring(os.time()),
    }
    if extra then
        for key, value in pairs(extra) do
            event[key] = value
        end
    end
    return event
end

function Reading:endSession()
    if not self.session_active then return true end
    if not self:ensureBookOpen() then return false end
    local duration = math.max(0, os.time() - (self.session_started_at or os.time()))
    -- Last line of defense against a missed Suspend event (Kindle auto-sleep
    -- paths): clip the counted duration so a session that crossed screen-off
    -- cannot bill the asleep time into reading_end.
    duration = math.min(duration, MAX_SESSION_SECONDS)
    local event = self:buildReadingEvent("reading_end", {
        duration_seconds = duration,
    })
    -- Book-switch guard: by the time a long-lived session is settled, the UI
    -- may already show the next book. Credit the session to the book it
    -- started with, never to whatever the UI happens to be holding now.
    if event and self.session_book then
        event.book = self.session_book
    end
    if not self.queue:sendOrQueue(event) then return false end
    self.session_active = false
    self.session_open_sent = false
    self.session_book = nil
    return true
end

function Reading:startSession()
    -- Book-switch guard: the same Reading instance survives across books.
    -- If a session is still active when a new book opens, settle the old
    -- session first so its dangling duration is not billed to the new book.
    if self.session_active then
        self:endSession()
    end
    self.session_started_at = os.time()
    self.session_open_sent = false
    self.session_active = true
    self.last_page_sent = nil
    self.last_chapter_index = nil
    self.session_book = Context.bookIdentity(self.ui)
    return self:ensureBookOpen()
end

function Reading:ensureBookOpen()
    if self.session_open_sent then return true end
    local event = self:buildReadingEvent("book_open")
    if not self.queue:sendOrQueue(event) then return false end
    self.session_open_sent = true
    return true
end

function Reading:onReaderReady()
    self.session_suspended = false
    self:startSession()
end

function Reading:onSuspend()
    if self:endSession() then
        self.session_suspended = true
    end
end

function Reading:onResume()
    -- Defensive re-arm: if a Suspend event was missed, the session silently
    -- survived screen-off and session_started_at still points at bedtime.
    -- While a session is alive, restart the clock on every wake regardless
    -- of session_suspended, so the asleep window is never billed.
    if self.session_active then
        self.session_started_at = os.time()
    end
    if not self.session_suspended then return false end
    self.session_suspended = false
    self:startSession()
    return true
end

-- P4 loop 1 (2026-09-14): top-level chapter table for crossing detection.
-- Prefer depth-1 entries so nested sub-sections do not fragment chapters;
-- books without depth marks fall back to the full flattened table.
function Reading:_chapterAtPage(page)
    local toc = self.ui and self.ui.toc
    if not toc or type(toc.toc) ~= "table" or #toc.toc == 0 then return nil end
    local entries = {}
    local has_top = false
    for _, item in ipairs(toc.toc) do
        if item.depth == nil or item.depth <= 1 then
            entries[#entries + 1] = item
            if item.depth == 1 then has_top = true end
        end
    end
    if not has_top then entries = toc.toc end
    local low, high, best, best_i = 1, #entries, nil, nil
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if (entries[mid].page or 0) <= page then
            best, best_i = entries[mid], mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    if not best then return nil end
    return best, best_i
end

-- Fired on every (throttle-free) page update; cheap binary search, and the
-- event goes out only when the top-level chapter actually changes. The very
-- first localization of a session never emits, so opening a book or waking
-- from sleep inside chapter 7 does not claim chapter 6 was just finished.
function Reading:_maybeChapterChanged(page)
    local entry, position_index = self:_chapterAtPage(page)
    if not entry then
        self.last_chapter_index = nil
        return
    end
    local index = position_index
    local previous = self.last_chapter_index
    if previous == index then return end
    self.last_chapter_index = index
    if previous == nil then return end
    local event = self:buildReadingEvent("chapter_changed", nil, page)
    if not event then return end
    event.position = event.position or {}
    event.position.chapter_uid = string.format("chapter:%d", index)
    event.position.chapter_title = tostring(entry.title or "")
    self.queue:sendOrQueue(event)
end

function Reading:onPageUpdate(page)
    page = tonumber(page)
    if not page then return end
    if not self:ensureBookOpen() then return end
    self:_maybeChapterChanged(page)
    if self.last_page_sent and math.abs(page - self.last_page_sent) < PROGRESS_PAGE_INTERVAL then
        return
    end
    self.last_page_sent = page
    local event = self:buildReadingEvent("progress", nil, page)
    self.queue:sendOrQueue(event)
end

function Reading:onCloseDocument()
    self:endSession()
    self.session_suspended = false
end

return Reading
