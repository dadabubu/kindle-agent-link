-- Read-only document context for Kindle AgentLink.
-- Event IDs and book identity/position reading. Feature modules must not
-- mutate document state through here; it is a read-only view.

local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Context = {}

local event_counter = 0

function Context.newEventId()
    event_counter = event_counter + 1
    return string.format("%d-%06d", os.time(), event_counter)
end

function Context.bookIdentity(ui)
    local doc = ui and ui.document
    if not doc then return nil end
    local props = doc:getProps() or {}
    local filename = tostring(doc.file or ""):match("([^/]+)$") or ""
    return {
        source = "koreader",
        book_id = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum") or nil,
        title = props.title or filename,
        author = props.author,
    }
end

function Context.position(ui, page_hint)
    local doc = ui and ui.document
    if not doc then return nil end

    local fraction
    if doc.info and doc.info.has_pages and ui.paging then
        fraction = ui.paging:getLastPercent()
    elseif ui.rolling then
        fraction = ui.rolling:getLastPercent()
    end

    local progress
    if type(fraction) == "number" then
        progress = math.floor(fraction * 10000 + 0.5) / 100
    end

    local page = tonumber(page_hint)
    if not page and ui.paging then
        page = tonumber(ui.paging.current_page)
    elseif not page and ui.rolling then
        page = tonumber(ui.rolling.current_page)
    end

    return {
        progress = progress,
        page = page,
    }
end

function Context.documentFile(ui)
    local doc = ui and ui.document
    if not doc or not doc.file then return nil end
    return tostring(doc.file)
end

-- The relay reproduces KOReader's sampled partialMD5 exactly, so the device
-- never hashes a whole book; size + sampled MD5 is the fingerprint.
function Context.fileFingerprint(path)
    if not path or path == "" then return nil end
    local attributes = lfs.attributes(path)
    if not attributes or attributes.mode ~= "file" then return nil end
    local ok, partial_md5 = pcall(util.partialMD5, path)
    if not ok or type(partial_md5) ~= "string" or partial_md5 == "" then return nil end
    return {
        size = attributes.size,
        mtime = attributes.modification,
        partial_md5 = partial_md5,
    }
end

return Context
