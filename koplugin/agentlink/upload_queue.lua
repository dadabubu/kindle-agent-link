-- P3 upload channel for agentlink (2026-09-14, §http-contract / §http-contract).
-- Whole-book transfers get their own persistent task directory, their own
-- single-flight markers and their own retry budget. This channel never
-- touches the small JSON event queue: a stuck or failing upload cannot delay
-- reading events or dialog replies, and vice versa.
--
-- One task file per book (`<upload_id>.json`, written atomically). Each drain
-- pass transfers at most one book inside the low-priority subprocess
-- executor; the UI thread only reads the small JSON result back.

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local Config = require("agentlink.config")

local UploadQueue = {}
UploadQueue.__index = UploadQueue

local MAX_UPLOADS_PER_PASS = 1
local MAX_ATTEMPTS = 12
local UPLOAD_JOB_TIMEOUT_SECONDS = 660

function UploadQueue:new(opts)
    local o = {
        dir = opts.dir,
        net = opts.net,
        settings = opts.settings,
        on_result = opts.on_result,
        draining = false,
        drain_scheduled = false,
        drain_requested = false,
    }
    setmetatable(o, UploadQueue)
    return o
end

function UploadQueue:_taskPaths(upload_id)
    local final_path = self.dir .. "/" .. upload_id .. ".json"
    return final_path .. ".tmp", final_path
end

function UploadQueue:_writeTask(task)
    local body = JSON.encode(task)
    local tmp_path, final_path = self:_taskPaths(task.upload_id)
    local file, err = io.open(tmp_path, "w")
    if not file then
        logger.warn("[agentlink] upload task open failed:", err)
        return false
    end
    local ok, write_err = file:write(body)
    file:flush()
    file:close()
    if not ok then
        os.remove(tmp_path)
        logger.warn("[agentlink] upload task write failed:", write_err)
        return false
    end
    if not os.rename(tmp_path, final_path) then
        os.remove(tmp_path)
        logger.warn("[agentlink] upload task rename failed")
        return false
    end
    return true
end

function UploadQueue:_tasks()
    local names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, self.dir)
    if not ok then return {} end
    for name in iter, dir_obj do
        if name:match("%.json$") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local tasks = {}
    for _, name in ipairs(names) do
        local path = self.dir .. "/" .. name
        local file = io.open(path, "r")
        if file then
            local body = file:read("*a")
            file:close()
            local decode_ok, task = pcall(JSON.decode, body)
            if decode_ok and type(task) == "table" and task.upload_id then
                tasks[#tasks + 1] = task
            end
        end
    end
    return tasks
end

function UploadQueue:_removeTask(upload_id)
    local _, final_path = self:_taskPaths(upload_id)
    os.remove(final_path)
end

function UploadQueue:enqueue(task)
    if type(task) ~= "table" or not task.upload_id or not task.file_path then return false end
    if task.partial_md5 and self:hasTaskFor(task.partial_md5) then return false end
    task.attempts = tonumber(task.attempts) or 0
    task.queued_at = task.queued_at or os.time()
    return self:_writeTask(task)
end

function UploadQueue:hasTaskFor(partial_md5)
    if not partial_md5 then return false end
    for _, task in ipairs(self:_tasks()) do
        if task.partial_md5 == partial_md5 then return true end
    end
    return false
end

function UploadQueue:pendingCount()
    return #self:_tasks()
end

-- Classify one transfer result. 4xx from the receiver means the file itself
-- is unacceptable (not an EPUB, fingerprint mismatch): that is permanent and
-- the task is dropped. Anything else (offline, 5xx, 503 module down, timeout)
-- keeps the task for another pass until the retry budget runs out.
function UploadQueue:_classify(result)
    if not result or not result.ok or type(result.value) ~= "table" then
        return { status = "retry", reason = (result and result.error) or "transfer failed" }
    end
    local value = result.value
    if value.outcome == "missing_file" then
        return { status = "failed", permanent = true, reason = "文件不存在" }
    end
    local code = tonumber(value.code)
    local body = type(value.body) == "table" and value.body or {}
    if code == 201 then
        return { status = "sent", book = body.book }
    elseif code == 200 then
        return { status = "duplicate", book = body.book }
    elseif code and code >= 400 and code < 500 and code ~= 401 and code ~= 429 then
        return { status = "failed", permanent = true, reason = body.error or ("HTTP " .. code) }
    end
    return { status = "retry", reason = body.error or (code and ("HTTP " .. code)) or "network" }
end

function UploadQueue:drain()
    if self.draining then return end
    local tasks = self:_tasks()
    if #tasks == 0 then return end
    local task = tasks[1]
    local url = self.settings:readSetting("books_upload_url") or Config.DEFAULT_BOOKS_UPLOAD_URL

    self.draining = true
    local started = self.net:startAsync("upload-drain", function()
        -- Subprocess: one transfer, nothing else.
        local attributes = lfs.attributes(task.file_path)
        if not attributes or attributes.mode ~= "file" then
            return { upload_id = task.upload_id, outcome = "missing_file" }
        end
        local headers = {
            ["X-Agentlink-Upload-Id"] = task.upload_id,
            ["X-Agentlink-File-Name"] = util.urlEncode(task.file_name or "book.epub"),
            ["X-Agentlink-Size"] = tostring(attributes.size),
        }
        if task.partial_md5 then
            headers["X-Agentlink-Partial-MD5"] = task.partial_md5
        end
        local code, body = self.net:uploadFile(url, task.file_path, headers)
        return { upload_id = task.upload_id, code = code, body = body }
    end, function(result)
        self.draining = false
        local outcome = self:_classify(result)
        if outcome.status == "sent" or outcome.status == "duplicate" or outcome.permanent then
            self:_removeTask(task.upload_id)
        else
            task.attempts = (tonumber(task.attempts) or 0) + 1
            task.last_error = outcome.reason
            if task.attempts >= MAX_ATTEMPTS then
                self:_removeTask(task.upload_id)
                outcome = { status = "failed", permanent = true, reason = "重试次数用尽：" .. tostring(outcome.reason) }
            else
                self:_writeTask(task)
            end
        end
        if self.on_result then
            local ok, err = pcall(self.on_result, task, outcome)
            if not ok then logger.warn("[agentlink] upload result callback failed:", err) end
        end
        -- Continue with the next book only after a success; a retryable
        -- failure waits for the next network / reader event instead of
        -- hammering the link. MAX_UPLOADS_PER_PASS keeps each pass to one.
        local should_continue = (outcome.status == "sent" or outcome.status == "duplicate" or outcome.permanent)
            and self:pendingCount() > 0
        if self.drain_requested or should_continue then
            self.drain_requested = false
            self:scheduleDrain(0.5)
        end
    end)
    if started then
        self.net:setJobTimeout("upload-drain", UPLOAD_JOB_TIMEOUT_SECONDS)
    else
        self.draining = false
    end
end

function UploadQueue:scheduleDrain(delay)
    if self.draining then
        self.drain_requested = true
        return
    end
    if self.drain_scheduled then return end
    self.drain_scheduled = true
    UIManager:scheduleIn(delay or 0.5, function()
        self.drain_scheduled = false
        self:drain()
    end)
end

function UploadQueue:scheduleDrainIfConnected(delay)
    if self:_networkRadioOn() then
        self:scheduleDrain(delay)
    end
end

function UploadQueue:_networkRadioOn()
    if type(NetworkMgr.isWifiOn) ~= "function" then return true end
    local ok, value = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return not ok or value == true
end

return UploadQueue
