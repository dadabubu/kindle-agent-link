-- Child-process-only HTTPS connection recovery. Keep the original URL/SNI and
-- stock LuaSec TLS configuration; retry another DNS peer only BEFORE TLS succeeds.
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local url = require("socket.url")
local logger = require("logger")

local Transport = {}
local preferred = {}
local invalidated = {}
local MAX_PEERS = 2
local MIN_HANDSHAKE_SECONDS = 8
local MIN_CONNECT_BUDGET_SECONDS = 18

local function pack(...)
    return { n = select("#", ...), ... }
end

local function ipv4(value)
    if type(value) ~= "string" then return false end
    local a,b,c,d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _, n in ipairs({a,b,c,d}) do
        if tonumber(n) > 255 then return false end
    end
    return true
end

function Transport.exportHints()
    local result = {}
    for host, address in pairs(preferred) do result[host] = address end
    for host in pairs(invalidated) do result[host] = false end
    return result
end

function Transport.importHints(hints)
    if type(hints) ~= "table" then return end
    for host, address in pairs(hints) do
        if type(host) == "string" and #host <= 253 and host:match("^[%w%.%-]+$") then
            if address == false then
                preferred[host], invalidated[host] = nil, nil
            elseif ipv4(address) then
                preferred[host], invalidated[host] = address, nil
            end
        end
    end
end

local function addressesFor(host)
    local found, seen = {}, {}
    local ok, rows = pcall(socket.dns.getaddrinfo, host)
    if ok and type(rows) == "table" then
        for _, row in ipairs(rows) do
            if ipv4(row.addr) and not seen[row.addr] then
                seen[row.addr] = true
                found[#found + 1] = row.addr
            end
        end
    end
    local cached = preferred[host]
    if cached and seen[cached] then
        local ordered = { cached }
        for _, address in ipairs(found) do
            if address ~= cached then ordered[#ordered + 1] = address end
        end
        found = ordered
    elseif cached then
        preferred[host] = nil
    end
    if #found == 0 then return { host } end -- let stock TCP resolution report its error
    return found
end

local function clone(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

function Transport.request(request)
    local parsed = type(request) == "table" and url.parse(request.url or "") or nil
    if not parsed or parsed.scheme ~= "https" or not parsed.host then
        return nil, "HTTPS URL required"
    end
    if http.PROXY or request.proxy then return nil, "proxy not supported" end
    if request.create then return nil, "custom socket factory not permitted" end
    local host = parsed.host
    local read_timeout = tonumber(https.TIMEOUT) or 5
    local started = socket.gettime()
    local deadline = started + math.max(MIN_CONNECT_BUDGET_SECONDS, read_timeout * 2 + 5)
    local peers = addressesFor(host)
    local last_error = "connection failed"
    for index = 1, math.min(#peers, MAX_PEERS) do
        if socket.gettime() >= deadline then break end
        local peer = peers[index]
        local req = clone(request)
        req.redirect = false -- never forward private headers to another URL
        local make_stock_tls = https.tcp(req)
        local connection, tls_ready = nil, false
        req.create = function()
            local conn = make_stock_tls()
            connection = conn
            local raw = conn.sock
            -- LuaSec ssl.wrap only transfers getfd()/setfd(). This narrow proxy
            -- chooses the TCP peer without changing the hostname passed to SNI.
            local routed = setmetatable({
                connect = function(_, original_host, port)
                    if original_host ~= host then return nil, "unexpected TLS host" end
                    local remaining = deadline - socket.gettime()
                    if remaining <= 0 then return nil, "connect budget exhausted" end
                    raw:settimeout(math.min(read_timeout, remaining))
                    local ok, err = raw:connect(peer, port)
                    -- Account for TCP elapsed time before allowing the TLS handshake.
                    remaining = deadline - socket.gettime()
                    if remaining <= 0 then return nil, "connect budget exhausted" end
                    https.TIMEOUT = math.min(math.max(read_timeout, MIN_HANDSHAKE_SECONDS), remaining)
                    return ok, err
                end,
            }, {
                __index = function(_, name)
                    local member = raw[name]
                    if type(member) == "function" then
                        return function(_, ...) return member(raw, ...) end
                    end
                    return member
                end,
            })
            conn.sock = routed
            -- Stock LuaSec captures a C TCP settimeout method before we wrap the
            -- socket. Do not pass our Lua proxy to that userdata-only method.
            conn.settimeout = function() return raw:settimeout(read_timeout) end
            local stock_connect = conn.connect
            conn.connect = function(self, original_host, port)
                local previous_timeout = https.TIMEOUT
                local result = pack(pcall(stock_connect, self, original_host, port))
                https.TIMEOUT = previous_timeout
                if not result[1] then error(result[2], 0) end
                if result[2] then
                    tls_ready = true
                    local remaining = deadline - socket.gettime()
                    self.sock:settimeout(math.min(read_timeout, math.max(remaining, 0.1)))
                end
                return unpack(result, 2, result.n)
            end
            return conn
        end
        logger.info("[agentlink] HTTPS connect peer", host, peer, "attempt", index)
        local result = pack(pcall(http.request, req))
        if connection and connection.sock then
            pcall(function() connection.sock:close() end)
        end
        if result[1] then
            if tls_ready then
                if result[2] and tonumber(result[3]) then
                    preferred[host] = ipv4(peer) and peer or nil
                    invalidated[host] = nil
                else
                    preferred[host], invalidated[host] = nil, true
                end
                -- Even a post-TLS read failure must not replay a consumed POST
                -- source. Application queues decide how to retry that request.
                return unpack(result, 2, result.n)
            end
            last_error = tostring(result[3] or "TLS connection failed")
        else
            last_error = tostring(result[2])
        end
        if tls_ready then
            preferred[host], invalidated[host] = nil, true
            return nil, last_error
        end
        logger.warn("[agentlink] HTTPS pre-HTTP connection failed", host, peer, last_error)
    end
    preferred[host], invalidated[host] = nil, true
    return nil, last_error
end

return Transport
