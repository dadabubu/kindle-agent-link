-- Persistent atomic queue for agentlink (5.5 decoupling).
-- Each channel (reading events, dialog events, and the pre-split legacy
-- directory) gets its own Queue instance with its own directory, its own
-- single-flight markers and its own per-pass drain budget, so one channel
-- backing up or failing cannot block the others.

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local JSON = require("json")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")

local Queue = {}
Queue.__index = Queue

local MAX_DRAIN_PER_PASS = 10

function Queue:new(opts)
    local o = {
        name = opts.name,
        dir = opts.dir,
        net = opts.net,
        draining = false,
        drain_scheduled = false,
        drain_requested = false,
    }
    setmetatable(o, Queue)
    return o
end

function Queue:_queuePaths(event_id)
    local final_path = self.dir .. "/" .. event_id .. ".json"
    return final_path .. ".tmp", final_path
end

function Queue:enqueue(event)
    local body = JSON.encode(event)
    local tmp_path, final_path = self:_queuePaths(event.event_id)
    local file, err = io.open(tmp_path, "w")
    if not file then
        logger.warn("[agentlink] queue open failed:", err)
        return false
    end
    local ok, write_err = file:write(body)
    file:flush()
    file:close()
    if not ok then
        os.remove(tmp_path)
        logger.warn("[agentlink] queue write failed:", write_err)
        return false
    end
    if not os.rename(tmp_path, final_path) then
        os.remove(tmp_path)
        logger.warn("[agentlink] queue rename failed")
        return false
    end
    return true
end

function Queue:drain()
    if self.draining then return end
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:match("%.json$") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    if #names == 0 then return end

    self.draining = true
    local started = self.net:startAsync("queue-drain-" .. self.name, function()
        local delivered = 0
        for index, name in ipairs(names) do
            if index > MAX_DRAIN_PER_PASS then break end
            local path = self.dir .. "/" .. name
            local file = io.open(path, "r")
            if file then
                local body = file:read("*a")
                file:close()
                local decode_ok, payload = pcall(JSON.decode, body)
                if decode_ok and type(payload) == "table" and self.net:postJSON(payload) then
                    os.remove(path)
                    delivered = delivered + 1
                end
            end
        end
        return delivered
    end, function(result)
        self.draining = false
        if not result or not result.ok then
            logger.warn("[agentlink] async queue drain failed")
        else
            local delivered = tonumber(result.value) or 0
            if delivered > 0 and #names > delivered then
                self:scheduleDrain(0.1)
            end
        end
        if self.drain_requested then
            self.drain_requested = false
            self:scheduleDrain(0.1)
        end
    end)
    if not started then
        self.draining = false
    end
end

function Queue:scheduleDrain(delay)
    if self.draining then
        self.drain_requested = true
        return
    end
    if self.drain_scheduled then return end
    self.drain_scheduled = true
    UIManager:scheduleIn(delay or 0.1, function()
        self.drain_scheduled = false
        self:drain()
    end)
end

function Queue:scheduleDrainIfConnected(delay)
    if self:_networkRadioOn() then
        self:scheduleDrain(delay)
    end
end

function Queue:sendOrQueue(event)
    if not event or not self:enqueue(event) then return false end
    if not self:_networkRadioOn() then return true end
    self:scheduleDrain(0.1)
    return true
end

function Queue:_networkRadioOn()
    if type(NetworkMgr.isWifiOn) ~= "function" then return true end
    local ok, value = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return not ok or value == true
end

return Queue
