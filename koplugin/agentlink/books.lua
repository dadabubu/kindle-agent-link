-- P3 book-library module for agentlink (2026-09-14, §docs/http-contract / §7.1 steps 3–8).
-- Owns: probing the current book against the agent's library, the "发送当前书给
-- Agent" action, the automatic probe after book_open, directory sync via a
-- light manifest, per-book pause, excluded directories, and the upload-timing
-- setting. Book bodies always go through the independent UploadQueue; this
-- module never touches the reading (P1) or dialog (P2) modules or their queues.

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Config = require("agentlink.config")
local Context = require("agentlink.context")

local Books = {}
Books.__index = Books

local AUTO_PROBE_DELAY_SECONDS = 4
local MAX_MANIFEST_ENTRIES = 2000
local SCAN_JOB_TIMEOUT_SECONDS = 300
local UPLOAD_WHEN_IMMEDIATE = "immediate"
local UPLOAD_WHEN_ON_CLOSE = "on_close"

function Books:new(opts)
    local o = {
        ui = opts.ui,
        net = opts.net,
        queue = opts.queue,
        settings = opts.settings,
        probe_in_flight = false,
        sync_in_flight = false,
        probed_this_session = nil,
    }
    setmetatable(o, Books)
    return o
end

-- --- settings ---------------------------------------------------------------

function Books:_setting(key, default)
    local value = self.settings:readSetting(key)
    if value == nil then return default end
    return value
end

function Books:_save(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Books:isPaused(partial_md5)
    local paused = self.settings:readSetting("paused_books") or {}
    return partial_md5 ~= nil and paused[partial_md5] == true
end

function Books:setPaused(partial_md5, paused)
    if not partial_md5 then return end
    local table_ = self.settings:readSetting("paused_books") or {}
    table_[partial_md5] = paused and true or nil
    self:_save("paused_books", table_)
end

function Books:isUploaded(partial_md5)
    local uploaded = self.settings:readSetting("uploaded_books") or {}
    return partial_md5 ~= nil and uploaded[partial_md5] ~= nil
end

function Books:markUploaded(partial_md5, receipt)
    if not partial_md5 then return end
    local uploaded = self.settings:readSetting("uploaded_books") or {}
    receipt = receipt or {}
    uploaded[partial_md5] = {
        sha256 = receipt.sha256,
        title = receipt.title,
        book_id = receipt.id,
        at = os.time(),
    }
    self:_save("uploaded_books", uploaded)
end

function Books:uploadWhen()
    local value = self:_setting("upload_when", UPLOAD_WHEN_IMMEDIATE)
    if value ~= UPLOAD_WHEN_ON_CLOSE then return UPLOAD_WHEN_IMMEDIATE end
    return value
end

function Books:autoProbeEnabled()
    return self:_setting("auto_probe", true) == true
end

-- --- current book -----------------------------------------------------------

function Books:_isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

function Books:currentBookInfo()
    local file = Context.documentFile(self.ui)
    if not file then return nil end
    local fingerprint = Context.fileFingerprint(file)
    if not fingerprint then return nil end
    local identity = Context.bookIdentity(self.ui) or {}
    local name = file:match("([^/]+)$") or file
    return {
        file = file,
        name = name,
        title = identity.title or name:gsub("%.[Ee][Pp][Uu][Bb]$", ""),
        author = identity.author,
        book_id = identity.book_id,
        size = fingerprint.size,
        mtime = fingerprint.mtime,
        partial_md5 = fingerprint.partial_md5,
    }
end

function Books:_transient(text, timeout)
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = timeout or 1.2,
        })
    end)
end

function Books:_notice(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

-- --- probe ------------------------------------------------------------------

function Books:buildProbePayload(info)
    return {
        event_id = Context.newEventId(),
        book = {
            source = "koreader",
            book_id = info.book_id,
            title = info.title,
            author = info.author,
        },
        file = {
            name = info.name,
            size = info.size,
            mtime = info.mtime,
            partial_md5 = info.partial_md5,
        },
    }
end

function Books:probeCurrentBook(callback)
    local info = self:currentBookInfo()
    if not info then
        callback(nil, nil)
        return false
    end
    if self.probe_in_flight then return false end
    local url = self.settings:readSetting("books_probe_url") or Config.DEFAULT_BOOKS_PROBE_URL
    local payload = self:buildProbePayload(info)
    self.probe_in_flight = true
    local started = self.net:startAsync("books-probe", function()
        return self.net:requestJSONPost(url, payload)
    end, function(result)
        self.probe_in_flight = false
        callback(result and result.ok and result.value or nil, info)
    end)
    if not started then
        self.probe_in_flight = false
        callback(nil, info)
    end
    return started
end

-- --- queueing ---------------------------------------------------------------

function Books:_buildTask(info)
    return {
        upload_id = Context.newEventId(),
        file_path = info.file,
        file_name = info.name,
        size = info.size,
        partial_md5 = info.partial_md5,
        title = info.title,
        author = info.author,
        queued_at = os.time(),
        attempts = 0,
    }
end

function Books:_queueBook(info, announce)
    if self.queue:hasTaskFor(info.partial_md5) then
        if announce then self:_transient("已在发送队列中") end
        return false
    end
    if not self.queue:enqueue(self:_buildTask(info)) then
        self:_notice("保存失败，请重试")
        return false
    end
    if announce then self:_transient("已加入发送队列") end
    if self:uploadWhen() == UPLOAD_WHEN_IMMEDIATE then
        self.queue:scheduleDrainIfConnected(0.5)
    end
    return true
end

-- §docs/http-contract: the manual door. Probe first so an already-registered book is
-- linked instantly instead of re-uploaded (§7.2 first item); offline or
-- unknown verdicts still queue the file so the request is never lost.
function Books:sendCurrentBook()
    local info = self:currentBookInfo()
    if not info then
        self:_notice("没有打开的书")
        return
    end
    if not self:_isEpub(info.file) then
        self:_notice("目前只支持 EPUB")
        return
    end
    if self:isUploaded(info.partial_md5) then
        self:_transient("…已经有…")
        return
    end
    if self.queue:hasTaskFor(info.partial_md5) then
        self:_transient("已在发送队列中")
        return
    end
    self:probeCurrentBook(function(verdict, probed)
        probed = probed or info
        if verdict and verdict.status == "present" then
            self:markUploaded(probed.partial_md5, verdict.book)
            self:_transient("…已经有…")
            return
        end
        self:_queueBook(probed, true)
    end)
end

-- --- lifecycle ---------------------------------------------------------------

-- §docs/http-contract: after book_open, probe once per session and queue only the
-- current file when it is missing. Delayed so the open itself stays snappy.
function Books:onReaderReady()
    self.probed_this_session = nil
    if not self:autoProbeEnabled() then return end
    UIManager:scheduleIn(AUTO_PROBE_DELAY_SECONDS, function()
        self:_autoProbe()
    end)
end

function Books:_autoProbe()
    local info = self:currentBookInfo()
    if not info or not self:_isEpub(info.file) then return end
    if self.probed_this_session == info.partial_md5 then return end
    self.probed_this_session = info.partial_md5
    if self:isPaused(info.partial_md5) then return end
    if self:isUploaded(info.partial_md5) then return end
    if self.queue:hasTaskFor(info.partial_md5) then return end
    self:probeCurrentBook(function(verdict, probed)
        if not verdict then return end -- offline: stay quiet, manual send still works
        probed = probed or info
        if verdict.status == "present" then
            self:markUploaded(probed.partial_md5, verdict.book)
            return
        end
        if self:_queueBook(probed, false) then
            self:_transient(string.format("《%s》已加入发送队列", probed.title or probed.name))
        end
    end)
end

-- §docs/http-contract hook: when the reader finds uploads disturb page turns, the timing
-- setting moves the actual transfer to document close.
function Books:onCloseDocument()
    if self:uploadWhen() == UPLOAD_WHEN_ON_CLOSE and self.queue:pendingCount() > 0 then
        self.queue:scheduleDrainIfConnected(1.0)
    end
end

function Books:onUploadResult(task, outcome)
    local title = task.title or task.file_name or "这本书"
    if outcome.status == "sent" then
        self:markUploaded(task.partial_md5, outcome.book)
        self:_transient(string.format("《%s》已发给 %s", title, self:agentName()))
    elseif outcome.status == "duplicate" then
        self:markUploaded(task.partial_md5, outcome.book)
        self:_transient(string.format("%s 已经有《%s》了", self:agentName(), title))
    elseif outcome.status == "failed" then
        self:_notice(string.format("《%s》发送失败：%s", title, tostring(outcome.reason or "未知原因")), 4)
    end
end

-- --- directory sync -----------------------------------------------------------

-- Runs inside the subprocess. Skips hidden entries, KOReader `.sdr` sidecars,
-- excluded directories and anything that is not an .epub file.
function Books:_scanDirectory(root)
    local excluded = self.settings:readSetting("excluded_dirs") or {}
    local entries = {}
    local function is_excluded(path)
        for _, prefix in ipairs(excluded) do
            if prefix ~= "" and path:sub(1, #prefix) == prefix then return true end
        end
        return false
    end
    local function walk(dir)
        if #entries >= MAX_MANIFEST_ENTRIES then return end
        if is_excluded(dir) then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    walk(path)
                elseif mode == "file" and name:lower():match("%.epub$") and not name:match("^~%$") then
                    local fingerprint = Context.fileFingerprint(path)
                    if fingerprint then
                        entries[#entries + 1] = {
                            path = path,
                            name = name,
                            size = fingerprint.size,
                            mtime = fingerprint.mtime,
                            partial_md5 = fingerprint.partial_md5,
                            title = (name:gsub("%.[Ee][Pp][Uu][Bb]$", "")),
                        }
                    end
                end
                if #entries >= MAX_MANIFEST_ENTRIES then return end
            end
        end
    end
    walk(root)
    return entries
end

-- Directory sync: scan the configured directories, send a
-- light manifest, and queue only what the receiver reports as missing or
-- changed. Paused, already-uploaded and already-queued books are skipped.
function Books:syncDirectory()
    if self.sync_in_flight then return end
    local dirs = self.settings:readSetting("sync_dirs") or {}
    if #dirs == 0 then
        self:_askSyncDirectory()
        return
    end
    local url = self.settings:readSetting("books_manifest_url") or Config.DEFAULT_BOOKS_MANIFEST_URL
    self.sync_in_flight = true
    self:_transient("正在扫描书库…", 2)
    local started = self.net:startAsync("books-sync", function()
        local entries = {}
        for _, root in ipairs(dirs) do
            for _, entry in ipairs(self:_scanDirectory(root)) do
                if #entries >= MAX_MANIFEST_ENTRIES then break end
                entries[#entries + 1] = entry
            end
        end
        local payload = {
            event_id = Context.newEventId(),
            root = table.concat(dirs, ";"),
            books = {},
        }
        for _, entry in ipairs(entries) do
            payload.books[#payload.books + 1] = {
                path = entry.path,
                size = entry.size,
                mtime = entry.mtime,
                partial_md5 = entry.partial_md5,
                title = entry.title,
            }
        end
        local response = self.net:requestJSONPost(url, payload)
        return { entries = entries, response = response }
    end, function(result)
        self.sync_in_flight = false
        local value = result and result.ok and result.value or nil
        if not value or type(value.response) ~= "table" then
            self:_notice("同步失败：暂时联系不上 " .. self:agentName())
            return
        end
        local by_path = {}
        for _, entry in ipairs(value.entries or {}) do by_path[entry.path] = entry end
        local queued, skipped = 0, 0
        local function consider(list)
            for _, item in ipairs(list or {}) do
                local entry = by_path[item.path]
                if entry then
                    if self:isPaused(entry.partial_md5)
                            or self:isUploaded(entry.partial_md5)
                            or self.queue:hasTaskFor(entry.partial_md5) then
                        skipped = skipped + 1
                    elseif self.queue:enqueue(self:_buildTask{
                        file = entry.path,
                        name = entry.name,
                        size = entry.size,
                        partial_md5 = entry.partial_md5,
                        title = entry.title,
                    }) then
                        queued = queued + 1
                    end
                end
            end
        end
        consider(value.response.missing)
        consider(value.response.changed)
        if queued > 0 and self:uploadWhen() == UPLOAD_WHEN_IMMEDIATE then
            self.queue:scheduleDrainIfConnected(0.5)
        end
        self:_notice(string.format(
            "%s 已有 %d 本，新加入待传 %d 本，跳过 %d 本",
            self:agentName(), tonumber(value.response.known) or 0, queued, skipped
        ), 4)
    end)
    if started then
        self.net:setJobTimeout("books-sync", SCAN_JOB_TIMEOUT_SECONDS)
    else
        self.sync_in_flight = false
        self:_notice("同步失败，请重试")
    end
end

function Books:_defaultDirectory()
    local file = Context.documentFile(self.ui)
    if file then
        local dir = file:match("^(.*)/[^/]+$")
        if dir and dir ~= "" then return dir end
    end
    return "/mnt/us/books"
end

function Books:_askSyncDirectory()
    local dirs = self.settings:readSetting("sync_dirs") or {}
    local dialog
    dialog = InputDialog:new{
        title = "与 " .. self:agentName() .. " 同步的目录",
        input = dirs[1] or self:_defaultDirectory(),
        input_hint = "/mnt/us/books",
        description = "只扫描这个目录（含子目录）里的 EPUB。",
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "保存并同步",
                    is_enter_default = true,
                    callback = function()
                        local path = util.trim(dialog:getInputValue() or "")
                        UIManager:close(dialog)
                        if path == "" then return end
                        path = path:gsub("/+$", "")
                        if lfs.attributes(path, "mode") ~= "directory" then
                            self:_notice("找不到这个目录：" .. path)
                            return
                        end
                        self:_save("sync_dirs", { path })
                        self:syncDirectory()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- §docs/http-contract: excluded directories. Entering an existing entry removes it.
function Books:_askExcludedDirectory()
    local excluded = self.settings:readSetting("excluded_dirs") or {}
    local dialog
    dialog = InputDialog:new{
        title = "排除目录",
        input = "",
        input_hint = "/mnt/us/books/杂志",
        description = #excluded > 0
            and ("当前排除：\n" .. table.concat(excluded, "\n") .. "\n\n再次输入同一目录即移除。")
            or "输入不希望同步的目录路径。",
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "确定",
                    is_enter_default = true,
                    callback = function()
                        local path = util.trim(dialog:getInputValue() or "")
                        UIManager:close(dialog)
                        if path == "" then return end
                        path = path:gsub("/+$", "")
                        local kept, removed = {}, false
                        for _, existing in ipairs(excluded) do
                            if existing == path then removed = true else kept[#kept + 1] = existing end
                        end
                        if not removed then kept[#kept + 1] = path end
                        self:_save("excluded_dirs", kept)
                        self:_transient(removed and "已取消排除" or "已加入排除目录")
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- --- menu -----------------------------------------------------------------------

function Books:menuItems()
    return {
        {
            text = "发送当前书给 " .. self:agentName(),
            callback = function() self:sendCurrentBook() end,
        },
        {
            text_func = function()
                local pending = self.queue:pendingCount()
                if pending > 0 then
                    return string.format("与 %s 同步书库（待传 %d 本）", self:agentName(), pending)
                end
                return "与 " .. self:agentName() .. " 同步书库"
            end,
            callback = function() self:syncDirectory() end,
            separator = true,
        },
        {
            text = "暂停同步当前书",
            checked_func = function()
                local info = self:currentBookInfo()
                return info ~= nil and self:isPaused(info.partial_md5)
            end,
            callback = function()
                local info = self:currentBookInfo()
                if not info then return end
                local paused = not self:isPaused(info.partial_md5)
                self:setPaused(info.partial_md5, paused)
                self:_transient(paused and "这本书不再自动同步" or "这本书恢复自动同步")
            end,
        },
        {
            text = "打开书时自动检查",
            checked_func = function() return self:autoProbeEnabled() end,
            callback = function() self:_save("auto_probe", not self:autoProbeEnabled()) end,
        },
        {
            text = "上传时机",
            sub_item_table = {
                {
                    text = "阅读中立即上传",
                    checked_func = function() return self:uploadWhen() == UPLOAD_WHEN_IMMEDIATE end,
                    callback = function() self:_save("upload_when", UPLOAD_WHEN_IMMEDIATE) end,
                },
                {
                    text = "退出阅读后再上传",
                    checked_func = function() return self:uploadWhen() == UPLOAD_WHEN_ON_CLOSE end,
                    callback = function() self:_save("upload_when", UPLOAD_WHEN_ON_CLOSE) end,
                },
            },
            separator = true,
        },
        {
            text_func = function()
                local dirs = self.settings:readSetting("sync_dirs") or {}
                return dirs[1] and ("同步目录：" .. dirs[1]) or "同步目录…"
            end,
            callback = function() self:_askSyncDirectory() end,
        },
        {
            text_func = function()
                local excluded = self.settings:readSetting("excluded_dirs") or {}
                return #excluded > 0 and string.format("排除目录（%d）…", #excluded) or "排除目录…"
            end,
            callback = function() self:_askExcludedDirectory() end,
        },
        {
            text_func = function()
                return string.format("待传队列：%d 本", self.queue:pendingCount())
            end,
            enabled_func = function() return self.queue:pendingCount() > 0 end,
            callback = function()
                self.queue:scheduleDrainIfConnected(0.1)
                self:_transient("开始发送")
            end,
        },
    }
end

return Books
