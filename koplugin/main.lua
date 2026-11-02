-- Kindle AgentLink — entry file.
-- This file only wires the plugin together (settings, shared net executor,
-- independent queues, feature modules) and forwards ReaderUI lifecycle
-- hooks plus menu assembly. Feature logic lives in agentlink/:
--   config  — endpoint defaults and display names
--   context — event IDs and read-only book identity/position
--   net     — sync HTTP primitives + non-modal subprocess executor
--   queue   — persistent atomic queues, one per channel
--   reading — reading-state session machine
--   dialog  — selection doors, replies, unread surfaces
--   books   — book probe / send-to-agent / directory sync
--   upload_queue — independent whole-book transfer channel

local DataStorage = require("datastorage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local Net = require("agentlink.net")
local Queue = require("agentlink.queue")
local Reading = require("agentlink.reading")
local Dialog = require("agentlink.dialog")
local Books = require("agentlink.books")
local UploadQueue = require("agentlink.upload_queue")
local Config = require("agentlink.config")

local AgentLink = WidgetContainer:extend{
    name = "agentlink",
    is_doc_only = true,
}

function AgentLink:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/agentlink.lua")
    local queue_root = DataStorage:getDataDir() .. "/agentlink-queue"
    lfs.mkdir(queue_root)
    self.net = Net:new{ settings = self.settings }
    -- Independent channels: reading events, dialog events, and the legacy
    -- pre-split queue root. Each drains with its own single-flight markers
    -- and budget; a backlog in one cannot block the others.
    self.legacy_queue = Queue:new{ name = "legacy", dir = queue_root, net = self.net }
    self.reading_queue = Queue:new{ name = "reading", dir = queue_root .. "/reading", net = self.net }
    self.dialog_queue = Queue:new{ name = "dialog", dir = queue_root .. "/dialog", net = self.net }
    lfs.mkdir(self.reading_queue.dir)
    lfs.mkdir(self.dialog_queue.dir)
    self.reading = Reading:new{
        ui = self.ui,
        queue = self.reading_queue,
    }
    self.dialog = Dialog:new{
        ui = self.ui,
        queue = self.dialog_queue,
        net = self.net,
        settings = self.settings,
    }
    local function on_light_delivered(event_id)
        self.dialog:onLightDelivered(event_id)
    end
    self.dialog_queue.on_light_delivered = on_light_delivered
    self.legacy_queue.on_light_delivered = on_light_delivered
    -- Book uploads have their own channel, separate from the small JSON
    -- event queues: a stuck transfer cannot delay reading events or replies.
    self.upload_queue = UploadQueue:new{
        dir = queue_root .. "/upload",
        net = self.net,
        settings = self.settings,
        on_result = function(task, outcome)
            self.books:onUploadResult(task, outcome)
        end,
    }
    lfs.mkdir(self.upload_queue.dir)
    self.books = Books:new{
        ui = self.ui,
        net = self.net,
        queue = self.upload_queue,
        settings = self.settings,
    }
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addToHighlightDialog()
    end
    if self.ui.paging or self.ui.rolling then
        self.dialog:installFooterUnreadSuffix()
    end
    self:_installBadgeRefresh()
    self:onDispatcherRegisterActions()
    require("agentlink.topbar").install(self.ui.menu, function(width, host)
        return self:_getPanel():buildDropdownContent(width, host)
    end)
end

function AgentLink:_installBadgeRefresh()
    if self.dialog._agentlink_badge_refresh then return end
    local original = self.dialog._refreshFooter
    if type(original) ~= "function" then return end
    self.dialog._agentlink_badge_refresh = true
    self.dialog._refreshFooter = function(dialog, ...)
        local result = original(dialog, ...)
        if self.panel then self.panel:refreshBadge() end
        return result
    end
end

function AgentLink:onDispatcherRegisterActions()
    require("dispatcher"):registerAction("agentlink_panel", {
        category = "none", event = "ShowAgentLinkPanel",
        title = "AgentLink 面板", reader = true,
    })
end

function AgentLink:_getPanel()
    if not self.panel then
        self.panel = require("agentlink.panel"):new{
            ui = self.ui, dialog = self.dialog, books = self.books,
            reading_queue = self.reading_queue, dialog_queue = self.dialog_queue,
            legacy_queue = self.legacy_queue, upload_queue = self.upload_queue,
        }
    end
    return self.panel
end

function AgentLink:onShowAgentLinkPanel()
    return require("agentlink.topbar").show(self.ui.menu)
end

function AgentLink:onReaderReady()
    self.reading:onReaderReady()
    -- ReaderReady also covers KOReader starting while Wi-Fi is already on;
    -- resume the non-reading backlogs explicitly so queued files cannot wait
    -- forever after an upgrade or restart.
    self.legacy_queue:scheduleDrainIfConnected(0.5)
    self.dialog_queue:scheduleDrainIfConnected(0.5)
    self.upload_queue:scheduleDrainIfConnected(2.0)
    self.dialog:onReaderReady()
    self.books:onReaderReady()
end

function AgentLink:onSuspend()
    require("agentlink.topbar").cancelPending(self.ui.menu)
    if self.panel then self.panel:close() end
    self.reading:onSuspend()
end

function AgentLink:onResume()
    self.reading:onResume()
    -- Wake from sleep is the natural moment to surface unread replies, and
    -- it is no longer gated on the reading module's own bookkeeping. The
    -- Kindle radio often comes back late after the wpa restart (or its auth
    -- fails outright, so onNetworkConnected never fires): nudge the network
    -- manager once, then let the reply fetcher's backoff retries ride out
    -- the remaining delay. A failed ensure must not block the wake path.
    local wifi_ready = true
    if type(NetworkMgr.isWifiEnabled) == "function" then
        local ok, enabled = pcall(NetworkMgr.isWifiEnabled, NetworkMgr)
        if ok then wifi_ready = enabled == true end
    end
    if not wifi_ready then
        logger.info("[agentlink] wifi not ready on resume, ensuring...")
        if type(NetworkMgr.ensureWifiToOneOfNetworks) == "function" then
            NetworkMgr:ensureWifiToOneOfNetworks()
        end
    end
    self.dialog:scheduleReplyFetch(1.5)
end

function AgentLink:onPageUpdate(page)
    return self.reading:onPageUpdate(page)
end

function AgentLink:onPosUpdate(_, page)
    self:onPageUpdate(page)
end

function AgentLink:onCloseDocument()
    require("agentlink.topbar").deactivate(self.ui.menu)
    if self.panel then self.panel:onCloseDocument() end
    self.reading:onCloseDocument()
    self.books:onCloseDocument()
end

function AgentLink:onNetworkConnected()
    self.legacy_queue:scheduleDrain(0.5)
    self.reading_queue:scheduleDrain(0.5)
    self.dialog_queue:scheduleDrain(0.5)
    self.dialog:scheduleReplyFetch(1.5)
    self.upload_queue:scheduleDrain(2.0)
    self.books:onNetworkConnected()
end

function AgentLink:addToHighlightDialog()
    -- Two selection doors. Names come from settings so each install picks
    -- its own wording; the doors themselves stay independent end to end.
    self.ui.highlight:removeFromHighlightDialog("04_agentlink_deep")
    self.ui.highlight:removeFromHighlightDialog("05_agentlink_quick")
    self.ui.highlight:addToHighlightDialog("04_agentlink_1_deep", function(this)
        return {
            text = self.dialog:deepLabel(),
            callback = function()
                this:highlightFromHoldPos()
                local selected_text = this.selected_text and this.selected_text.text
                selected_text = util.cleanupSelectedText(selected_text or "")
                if selected_text == "" then return end
                this:onClose(true)
                self.dialog:showDeepDialog(selected_text)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("04_agentlink_2_quick", function(this)
        return {
            text = self.dialog:quickLabel(),
            callback = function()
                this:highlightFromHoldPos()
                local selected_text = this.selected_text and this.selected_text.text
                selected_text = util.cleanupSelectedText(selected_text or "")
                if selected_text == "" then return end
                this:onClose(true)
                self.dialog:showQuickDialog(selected_text)
            end,
        }
    end)
end

function AgentLink:addToMainMenu(menu_items)
    menu_items.agentlink_panel = {
        text = "AgentLink 面板",
        sorting_hint = "navi",
        callback = function() self:onShowAgentLinkPanel() end,
    }
    local agent_name = self.dialog:agentName()
    local unread = self.dialog.unread_count or 0
    local label
    if unread > 0 then
        label = string.format("%s（%d）", agent_name, unread)
    else
        label = agent_name
    end
    menu_items.agentlink = {
        text = label,
        sorting_hint = "navi",
        callback = function()
            self.dialog:openReplyViewer()
        end,
    }
    -- The library lives under Tools; the reply entry above keeps its
    -- first-page slot and the top menu never becomes a second chat door.
    menu_items.agentlink_books = {
        text = string.format(Config.DEFAULT_BOOKS_LABEL, agent_name),
        sorting_hint = "tools",
        sub_item_table = self.books:menuItems(),
    }
end

return AgentLink
