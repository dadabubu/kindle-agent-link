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
local util = require("util")
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
    self.reading:onSuspend()
end

function AgentLink:onResume()
    if self.reading:onResume() then
        -- Wake from sleep is the natural moment to surface unread replies.
        self.dialog:scheduleReplyFetch(1.5)
    end
end

function AgentLink:onPageUpdate(page)
    return self.reading:onPageUpdate(page)
end

function AgentLink:onPosUpdate(_, page)
    self:onPageUpdate(page)
end

function AgentLink:onCloseDocument()
    self.reading:onCloseDocument()
    self.books:onCloseDocument()
end

function AgentLink:onNetworkConnected()
    self.legacy_queue:scheduleDrain(0.5)
    self.reading_queue:scheduleDrain(0.5)
    self.dialog_queue:scheduleDrain(0.5)
    self.dialog:scheduleReplyFetch(1.5)
    self.upload_queue:scheduleDrain(2.0)
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
