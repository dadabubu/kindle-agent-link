-- Per-book reply history, retained locally for immediate/offline access.
local DataStorage = require("datastorage")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")

local History = {}

function History.path(book)
    local key = tostring(book.book_id or "")
    if key == "" or #key > 100 or key:find("[^%w_-]") then
        local title, hash = tostring(book.title or ""), 0
        for i = 1, #title do hash = (hash * 131 + title:byte(i)) % 4294967296 end
        key = string.format("title-%08x", hash)
    end
    return DataStorage:getSettingsDir() .. "/agentlink-history/" .. key .. ".json"
end

function History.read(book)
    local file = io.open(History.path(book), "rb")
    if not file then return { replies = {} } end
    local raw = file:read("*a")
    file:close()
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or data.book_title ~= book.title
        or type(data.replies) ~= "table" then return { replies = {} } end
    return data
end

function History.load(book)
    local data = History.read(book)
    local hidden = data.hidden_reply_ids or {}
    local replies = {}
    for _, reply in ipairs(data.replies) do
        if not hidden[tostring(reply.reply_id)] then replies[#replies + 1] = reply end
    end
    return replies
end

function History.merge(book, incoming)
    local existing = History.read(book)
    local hidden = existing.hidden_reply_ids or {}
    local by_id = {}
    local function add(rows)
        for _, reply in ipairs(rows or {}) do
            if type(reply) == "table" and (reply.book_title == nil or reply.book_title == book.title) then
                local key = reply.reply_id or reply.source_event_id
                if key and not hidden[tostring(reply.reply_id)] then by_id[tostring(key)] = reply end
            end
        end
    end
    add(existing.replies)
    add(incoming)
    local replies = {}
    for _, reply in pairs(by_id) do replies[#replies + 1] = reply end
    table.sort(replies, function(a, b)
        local at, bt = tonumber(a.created_at) or 0, tonumber(b.created_at) or 0
        if at ~= bt then return at > bt end
        return (tonumber(a.reply_id) or 0) > (tonumber(b.reply_id) or 0)
    end)
    local directory = DataStorage:getSettingsDir() .. "/agentlink-history"
    lfs.mkdir(directory)
    local path = History.path(book)
    local file = io.open(path .. ".tmp", "wb")
    if file then
        local encoded = JSON.encode({ book_title = book.title, replies = replies, hidden_reply_ids = hidden })
        local written = file:write(encoded)
        file:close()
        if written then os.rename(path .. ".tmp", path) end
    end
    return replies
end

return History
