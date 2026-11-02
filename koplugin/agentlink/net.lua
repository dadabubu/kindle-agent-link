-- Shared HTTP layer for Kindle AgentLink.
-- Synchronous request primitives run only inside low-priority subprocesses;
-- the async executor schedules those subprocesses and polls their results on
-- the UI thread without ever blocking page turns.

local FFIUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local https = require("ssl.https")
local Config = require("agentlink.config")
-- Capture our owned transport while PluginLoader still exposes this plugin's
-- module path. Older minimal test/legacy hosts can retain stock HTTPS safely.
local Transport = (function()
    local ok, mod = pcall(require, "agentlink.https_transport")
    if ok then return mod end
    logger.warn("[agentlink] owned TLS transport unavailable; retaining stock HTTPS")
end)()
local function requestHTTPS(request)
    if Transport then return Transport.request(request) end
    return https.request(request)
end
local SubprocessHygiene = (function()
    local ok, mod = pcall(require, "agentlink.subprocess_hygiene")
    return ok and mod or nil
end)()

local function getSubprocessHygiene()
    local ok, mod = pcall(require, "agentlink.subprocess_hygiene")
    if ok and mod then return mod end
    return SubprocessHygiene
end

local Net = {}
Net.__index = Net

local ASYNC_NETWORK_TIMEOUT_SECONDS = 20
local ASYNC_NETWORK_POLL_SECONDS = 0.25
local UPLOAD_BLOCK_TIMEOUT_SECONDS = 15
local UPLOAD_TOTAL_TIMEOUT_SECONDS = 600

-- Queue batches need one ordinary worker budget per serial request.
Net.DEFAULT_JOB_TIMEOUT_SECONDS = ASYNC_NETWORK_TIMEOUT_SECONDS

function Net:new(opts)
    local o = {
        settings = opts.settings,
        network_jobs = {},
        network_poll_scheduled = false,
    }
    setmetatable(o, Net)
    return o
end

function Net:postJSON(payload)
    local token = self.settings:readSetting("token") or ""
    local server_url
    if payload.kind == "reading_sync" then
        server_url = self.settings:readSetting("server_url") or Config.DEFAULT_SERVER_URL
    else
        server_url = self.settings:readSetting("excerpt_url") or Config.DEFAULT_EXCERPT_URL
    end
    if token == "" or server_url == "" then return false end

    local body = JSON.encode(payload)
    local sink = {}
    socketutil:set_timeout(5, 15)
    local request_ok, code, _, status = pcall(function()
        return socket.skip(1, requestHTTPS{
            url = server_url,
            method = "POST",
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. token,
                ["Content-Length"] = #body,
            },
        })
    end)
    socketutil:reset_timeout()
    if not request_ok then
        logger.warn("[agentlink] request failed")
        return false
    end
    local status_code = tonumber(code)
    if status_code ~= 200 and status_code ~= 202 then
        logger.warn("[agentlink] server rejected event:", status or code)
        return false
    end
    return true
end

function Net:requestJSON(url)
    local token = self.settings:readSetting("token") or ""
    if token == "" or url == "" then return nil end
    local sink = {}
    socketutil:set_timeout(5, 15)
    local request_ok, code, _, status = pcall(function()
        return socket.skip(1, requestHTTPS{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(sink),
            headers = {
                ["Authorization"] = "Bearer " .. token,
            },
        })
    end)
    socketutil:reset_timeout()
    if not request_ok then
        logger.warn("[agentlink] replies GET failed")
        return nil
    end
    if tonumber(code) ~= 200 then
        logger.warn("[agentlink] replies GET rejected:", status or code)
        return nil
    end
    local body = table.concat(sink)
    local decode_ok, payload = pcall(JSON.decode, body)
    if not decode_ok or type(payload) ~= "table" then return nil end
    return payload
end

function Net:ackReplies(reply_ids)
    local token = self.settings:readSetting("token") or ""
    if token == "" or type(reply_ids) ~= "table" or #reply_ids == 0 then return false end
    local ack_url = self.settings:readSetting("replies_ack_url") or Config.DEFAULT_REPLIES_ACK_URL
    local body = JSON.encode({ reply_ids = reply_ids })
    local sink = {}
    socketutil:set_timeout(5, 15)
    local request_ok, code = pcall(function()
        return socket.skip(1, requestHTTPS{
            url = ack_url,
            method = "POST",
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. token,
                ["Content-Length"] = #body,
            },
        })
    end)
    socketutil:reset_timeout()
    return request_ok and tonumber(code) == 200
end

function Net:_scheduleAsyncNetworkPoll()
    if self.network_poll_scheduled then return end
    self.network_poll_scheduled = true
    UIManager:scheduleIn(ASYNC_NETWORK_POLL_SECONDS, function()
        self.network_poll_scheduled = false
        self:_pollAsyncNetworkJobs()
    end)
end

function Net:_pollAsyncNetworkJobs()
    for label, job in pairs(self.network_jobs) do
        if not job.timed_out
                and os.time() - job.started_at > (job.timeout_seconds or ASYNC_NETWORK_TIMEOUT_SECONDS) then
            job.timed_out = true
            pcall(FFIUtil.terminateSubProcess, job.pid)
        end

        local status_ok, done = pcall(FFIUtil.isSubProcessDone, job.pid, false)
        if not status_ok then done = true end
        if done then
            local read_ok, raw = pcall(FFIUtil.readAllFromFD, job.read_fd)
            self.network_jobs[label] = nil
            local result
            if job.timed_out then
                result = { ok = false, error = "network worker timeout" }
            elseif not read_ok or not raw or raw == "" then
                result = { ok = false, error = "network worker returned no result" }
            else
                local decode_ok, decoded = pcall(JSON.decode, raw)
                result = decode_ok and decoded or {
                    ok = false,
                    error = "network worker result decode failed",
                }
            end
            if Transport and type(result) == "table" then
                Transport.importHints(result.transport_hints)
            end
            if job.callback then
                local callback_ok, callback_err = pcall(job.callback, result)
                if not callback_ok then
                    logger.warn("[agentlink] async callback failed:", callback_err)
                end
            end
        end
    end
    if next(self.network_jobs) then self:_scheduleAsyncNetworkPoll() end
end

function Net:startAsync(label, task, callback)
    if self.network_jobs[label] then return false end
    local launch_ok, pid, read_fd = pcall(FFIUtil.runInSubProcess, function(_, write_fd)
        local hygiene = getSubprocessHygiene()
        if hygiene and type(hygiene.close_inherited_sockets) == "function" then
            local prep_ok, ok, err, closed, res_ok = pcall(hygiene.close_inherited_sockets)
            if prep_ok and ok ~= false then
                local res_str = (res_ok == true) and "true" or (res_ok == false and "false" or "unsupported")
                local log_msg = string.format("[agentlink] child prep (%s): resolver_reset=%s, sockets_closed=%d",
                    tostring(label), res_str, tonumber(closed) or 0)
                if type(logger.info) == "function" then
                    logger.info(log_msg)
                elseif type(logger.warn) == "function" then
                    logger.warn(log_msg)
                end
            elseif prep_ok and ok == false then
                local res_str = (res_ok == true) and "true" or (res_ok == false and "false" or "unsupported")
                local log_msg = string.format("[agentlink] child prep (%s) unsupported: %s, resolver_reset=%s",
                    tostring(label), tostring(err), res_str)
                if type(logger.warn) == "function" then logger.warn(log_msg) end
            else
                local log_msg = string.format("[agentlink] child prep (%s) failed: %s",
                    tostring(label), tostring(ok))
                if type(logger.warn) == "function" then logger.warn(log_msg) end
            end
        else
            local log_msg = string.format("[agentlink] child prep (%s): hygiene helper unavailable", tostring(label))
            if type(logger.warn) == "function" then logger.warn(log_msg) end
        end
        local task_ok, value = pcall(task)
        local result = task_ok and { ok = true, value = value } or {
            ok = false,
            error = tostring(value),
        }
        if Transport then result.transport_hints = Transport.exportHints() end
        local encode_ok, encoded = pcall(JSON.encode, result)
        if not encode_ok then
            encoded = '{"ok":false,"error":"network worker result encode failed"}'
        end
        FFIUtil.writeToFD(write_fd, encoded, true)
    end, true)
    if not launch_ok or not pid then
        logger.warn("[agentlink] failed to start async network worker:", read_fd or pid)
        return false
    end
    self.network_jobs[label] = {
        pid = pid,
        read_fd = read_fd,
        callback = callback,
        started_at = os.time(),
    }
    self:_scheduleAsyncNetworkPoll()
    return true
end

-- Long-running jobs (a whole book, a library scan) outlive the default
-- 20-second watchdog. Call right after startAsync() returned true.
function Net:setJobTimeout(label, timeout_seconds)
    local job = self.network_jobs[label]
    if not job then return false end
    job.timeout_seconds = tonumber(timeout_seconds) or ASYNC_NETWORK_TIMEOUT_SECONDS
    return true
end

function Net:requestJSONAsync(label, url, callback)
    return self:startAsync(label, function()
        return self:requestJSON(url)
    end, function(result)
        callback(result and result.ok and result.value or nil)
    end)
end

-- JSON POST that returns the decoded response body (probe / manifest need
-- the verdict, not just success). Subprocess only.
function Net:requestJSONPost(url, payload)
    local token = self.settings:readSetting("token") or ""
    if token == "" or not url or url == "" then return nil end
    local body = JSON.encode(payload)
    local sink = {}
    socketutil:set_timeout(5, 30)
    local request_ok, code, _, status = pcall(function()
        return socket.skip(1, requestHTTPS{
            url = url,
            method = "POST",
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. token,
                ["Content-Length"] = #body,
            },
        })
    end)
    socketutil:reset_timeout()
    if not request_ok then
        logger.warn("[agentlink] JSON POST failed")
        return nil
    end
    local status_code = tonumber(code)
    if status_code ~= 200 and status_code ~= 201 and status_code ~= 202 then
        logger.warn("[agentlink] JSON POST rejected:", status or code)
        return nil
    end
    local decode_ok, decoded = pcall(JSON.decode, table.concat(sink))
    if not decode_ok or type(decoded) ~= "table" then return nil end
    return decoded
end

-- Stream one file body to the relay. Returns the HTTP status code (nil on
-- transport failure) and the decoded JSON body, so the upload queue can tell
-- a permanently bad file (4xx) from a retryable network or server problem.
-- Subprocess only; never on the UI thread.
function Net:uploadFile(url, path, headers)
    local token = self.settings:readSetting("token") or ""
    if token == "" or not url or url == "" then return nil, nil end
    local file = io.open(path, "rb")
    if not file then return nil, nil end
    local size = file:seek("end")
    file:seek("set", 0)
    local request_headers = {
        ["Content-Type"] = "application/octet-stream",
        ["Content-Length"] = size,
        ["Authorization"] = "Bearer " .. token,
    }
    for key, value in pairs(headers or {}) do
        request_headers[key] = value
    end
    local sink = {}
    socketutil:set_timeout(UPLOAD_BLOCK_TIMEOUT_SECONDS, UPLOAD_TOTAL_TIMEOUT_SECONDS)
    local request_ok, code, _, status = pcall(function()
        return socket.skip(1, requestHTTPS{
            url = url,
            method = "POST",
            source = ltn12.source.file(file),
            sink = ltn12.sink.table(sink),
            headers = request_headers,
        })
    end)
    socketutil:reset_timeout()
    pcall(function() file:close() end)
    if not request_ok then
        logger.warn("[agentlink] upload failed")
        return nil, nil
    end
    local decode_ok, decoded = pcall(JSON.decode, table.concat(sink))
    if tonumber(code) ~= 200 and tonumber(code) ~= 201 then
        logger.warn("[agentlink] upload rejected:", status or code)
    end
    return tonumber(code), (decode_ok and type(decoded) == "table") and decoded or nil
end

return Net
