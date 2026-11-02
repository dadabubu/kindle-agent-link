-- Dialog module for Kindle AgentLink.
-- Owns both selection doors (deep discussion, quick question), reply
-- fetching with its bounded window, the reply card, unread surfaces (footer
-- suffix, top menu) and async ACKs. Events go out on the dialog module's own
-- dedicated queue. Door labels and the agent's display name come from
-- settings so every install picks its own wording.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local Config = require("agentlink.config")
local Context = require("agentlink.context")
local History = require("agentlink.history")

local Dialog = {}
Dialog.__index = Dialog

local MAX_UNREAD_PER_FETCH = 5
local REPLY_FETCH_WINDOW_SECONDS = 120
-- Wake-from-sleep backoff: the Kindle radio often comes back late, and a
-- failed wpa auth means the onNetworkConnected event never fires. Each
-- network failure schedules exactly one more fetch at the next delay; any
-- success (data or empty mailbox) resets the counter.
local REPLY_FETCH_BACKOFF_DELAYS = { 10, 30, 60, 120 }
local Screen = Device.screen
local REPLY_INDENT = Screen:scaleBySize(20)
local REPLY_SIDE_BUTTON_WIDTH = Screen:scaleBySize(44)

function Dialog:new(opts)
    local o = {
        ui = opts.ui,
        queue = opts.queue,
        net = opts.net,
        settings = opts.settings,
        unread_count = 0,
        last_reply_id = 0,
        reply_fetch_scheduled = false,
        reply_fetch_in_flight = false,
        reply_fetch_backoff_attempts = 0,
        reply_history_in_flight = false,
    }
    setmetatable(o, Dialog)
    return o
end

-- --- configurable naming -----------------------------------------------------

function Dialog:_setting(key, default)
    local value = self.settings and self.settings:readSetting(key)
    if value == nil or value == "" then return default end
    return value
end

function Dialog:agentName()
    return self:_setting("agent_name", Config.DEFAULT_AGENT_NAME)
end

function Dialog:deepLabel()
    return self:_setting("deep_entry_label", Config.DEFAULT_DEEP_LABEL)
end

function Dialog:quickLabel()
    return self:_setting("quick_entry_label", Config.DEFAULT_QUICK_LABEL)
end

-- --- replies: async ACK -------------------------------------------------------

function Dialog:scheduleReplyAck(reply_ids)
    local label = "reply-ack-" .. table.concat(reply_ids, "-")
    return self.net:startAsync(label, function()
        return self.net:ackReplies(reply_ids)
    end, function(result)
        if not result or not result.ok or result.value ~= true then
            logger.warn("[agentlink] async reply ACK failed")
        end
    end)
end

function Dialog:_showTransientInfo(text, timeout)
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = timeout or 1.2,
        })
    end)
end

-- --- reply card ---------------------------------------------------------------

function Dialog:_buildReplyCardWidgets(reply, width, older_callback, newer_callback)
    local widgets = {}
    local has_navigation = older_callback ~= nil or newer_callback ~= nil
    local body_width = width
    local small_face = Font:getFace("smallinfofont")
    local body_face = Font:getFace("infofont")
    local selection = tostring(reply.selection or "")
    local original = TextBoxWidget:new{
        text = "“" .. selection .. "”",
        face = small_face,
        fgcolor = Blitbuffer.COLOR_GRAY,
        width = body_width,
        line_height = 0,
    }
    original.not_focusable = true
    widgets[#widgets + 1] = original

    local divider = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{
            w = body_width,
            h = Size.line.medium,
        },
    }
    divider.not_focusable = true
    widgets[#widgets + 1] = divider

    local gap = VerticalSpan:new{ width = Screen:scaleBySize(8) }
    gap.not_focusable = true
    widgets[#widgets + 1] = gap

    local you_label = TextBoxWidget:new{
        text = "你",
        face = small_face,
        fgcolor = Blitbuffer.COLOR_GRAY,
        width = body_width,
        line_height = 0,
    }
    you_label.not_focusable = true
    widgets[#widgets + 1] = you_label

    local question = tostring(reply.question or "")
    if question == "" then question = "（只放入了原文）" end
    local question_body = TextBoxWidget:new{
        text = question,
        face = body_face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = body_width,
    }
    question_body.not_focusable = true
    widgets[#widgets + 1] = question_body

    local reply_gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    reply_gap.not_focusable = true
    widgets[#widgets + 1] = reply_gap

    local reply_width = math.max(Screen:scaleBySize(120), body_width - REPLY_INDENT)
    local agent_name = self:agentName()
    local reply_label = TextBoxWidget:new{
        text = "> " .. agent_name,
        face = small_face,
        fgcolor = Blitbuffer.COLOR_GRAY,
        width = reply_width,
        line_height = 0,
    }
    reply_label.not_focusable = true
    local reply_body = TextBoxWidget:new{
        text = tostring(reply.text or ""),
        face = body_face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = reply_width,
    }
    reply_body.not_focusable = true
    local reply_group = HorizontalGroup:new{
        HorizontalSpan:new{ width = REPLY_INDENT },
        VerticalGroup:new{
            reply_label,
            reply_body,
        },
    }
    reply_group.not_focusable = true
    widgets[#widgets + 1] = reply_group

    local meta = {}
    local created_at = tonumber(reply.created_at)
    if created_at then meta[#meta + 1] = os.date("%m-%d %H:%M", created_at) end
    local progress = tonumber(reply.progress)
    if progress then meta[#meta + 1] = string.format("%.2f%%", progress) end
    meta[#meta + 1] = reply.kindle_status == "acked" and "已读" or "未读"
    local meta_widget = TextBoxWidget:new{
        text = table.concat(meta, " · "),
        face = small_face,
        fgcolor = Blitbuffer.COLOR_GRAY,
        width = body_width,
        alignment = "right",
        line_height = 0,
    }
    meta_widget.not_focusable = true
    widgets[#widgets + 1] = meta_widget

    local body_group = VerticalGroup:new(widgets)
    body_group.not_focusable = true
    if not has_navigation then return { body_group } end

    local body_height = body_group:getSize().h
    local function side_button(icon, callback)
        local button = Button:new{
            icon = icon,
            enabled = callback ~= nil,
            callback = callback,
            width = REPLY_SIDE_BUTTON_WIDTH,
            height = body_height,
            icon_width = Screen:scaleBySize(18),
            icon_height = Screen:scaleBySize(18),
            padding = 0,
            bordersize = 0,
        }
        return CenterContainer:new{
            dimen = Geom:new{
                w = REPLY_SIDE_BUTTON_WIDTH,
                h = body_height,
            },
            button,
        }
    end
    local card_row = HorizontalGroup:new{
        side_button("chevron.left", older_callback),
        body_group,
        side_button("chevron.right", newer_callback),
    }
    return { card_row }
end

function Dialog:_gotoReplyPosition(reply)
    local progress = tonumber(reply.progress)
    if not progress or progress < 0 or progress > 100 then return false end
    return pcall(function()
        if self.ui.rolling and self.ui.rolling.onGotoPercent then
            self.ui.rolling:onGotoPercent(progress)
        else
            self.ui:handleEvent(Event:new("GotoPercent", progress))
        end
    end)
end

function Dialog:showReplyDialog(replies, history_mode)
    local dialog
    local index = math.max(1, math.min(tonumber(self.reply_card_index) or 1, #replies))
    local reply = replies[index]
    local reply_ids = {}
    if reply.kindle_status ~= "acked" then
        reply_ids[1] = tonumber(reply.reply_id)
    end
    if #reply_ids > 0 then
        reply.kindle_status = "acked"
        self.unread_count = math.max(0, self.unread_count - #reply_ids)
        self:_refreshFooter()
        self:scheduleReplyAck(reply_ids)
    end
    local older_callback
    if index < #replies then
        older_callback = function()
            if self.current_reply_dialog == dialog then
                self.current_reply_dialog = nil
            end
            UIManager:close(dialog)
            self.reply_card_index = index + 1
            self:showReplyDialog(replies, history_mode)
        end
    end
    local newer_callback
    if index > 1 then
        newer_callback = function()
            if self.current_reply_dialog == dialog then
                self.current_reply_dialog = nil
            end
            UIManager:close(dialog)
            self.reply_card_index = index - 1
            self:showReplyDialog(replies, history_mode)
        end
    end
    local close_viewer = function()
        if self.current_reply_dialog == dialog then
            self.current_reply_dialog = nil
        end
        self.reply_viewer_open = false
        UIManager:close(dialog)
    end
    local buttons = {}
    local actions = {}
    if tonumber(reply.progress) then
        actions[#actions + 1] = {
            text = "返回原文",
            callback = function()
                close_viewer()
                self:_gotoReplyPosition(reply)
            end,
        }
    end
    actions[#actions + 1] = {
        text = "关闭",
        callback = function()
            close_viewer()
        end,
    }
    buttons[#buttons + 1] = actions

    local dialog_width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.88)
    local content_width = math.floor(dialog_width * 0.78)
    dialog = ButtonDialog:new{
        width = dialog_width,
        buttons = buttons,
        _added_widgets = self:_buildReplyCardWidgets(
            reply,
            content_width,
            older_callback,
            newer_callback
        ),
        dismissable = false,
    }
    if self.current_reply_dialog and self.current_reply_dialog ~= dialog then
        UIManager:close(self.current_reply_dialog)
    end
    self.current_reply_dialog = dialog
    self.reply_viewer_open = true
    UIManager:show(dialog)
end

-- --- replies: bounded fetch window ---------------------------------------------

function Dialog:fetchAndShowReplies(callback)
    if not self.queue:_networkRadioOn() then
        callback(false)
        return false
    end
    local base_url = self.net.settings:readSetting("replies_url") or Config.DEFAULT_REPLIES_URL
    local url = string.format("%s?after=%d&limit=%d", base_url, self.last_reply_id, MAX_UNREAD_PER_FETCH)
    self.reply_fetch_in_flight = true
    local started = self.net:requestJSONAsync("reply-fetch", url, function(payload)
        self.reply_fetch_in_flight = false
        if not payload then
            -- Transport-level failure (timeout, no route, non-200, garbage
            -- body): signal it so the caller backs off instead of treating
            -- this like an empty mailbox.
            callback(false, nil, true)
            return
        end
        if type(payload.replies) ~= "table" or #payload.replies == 0 then
            callback(false)
            return
        end
        self.last_reply_id = tonumber(payload.next_after) or self.last_reply_id
        local book = Context.bookIdentity(self.ui)
        if book and book.title then History.merge(book, payload.replies) end
        self.unread_count = self.unread_count + #payload.replies
        self:_refreshFooter()
        self.reply_card_index = 1
        -- While waiting for one specific outgoing message, unrelated replies
        -- count as unread but do not end the window early (contract §4.5:
        -- replies are correlated by source event id).
        local matched_expected = false
        for _, reply in ipairs(payload.replies) do
            if reply.source_event_id == self.reply_fetch_expected_event_id then
                matched_expected = true
                break
            end
        end
        callback(true, matched_expected)
    end)
    if not started then
        self.reply_fetch_in_flight = false
        callback(false)
    end
    return started
end

function Dialog:startReplyFetchWindow(event_id)
    self.reply_fetch_latest_user_event_id = event_id
    self:onLightDelivered(event_id)
end

function Dialog:onLightDelivered(event_id)
    -- Older recovered sends must not hijack a newer question sent in this UI.
    if self.reply_fetch_latest_user_event_id
            and self.reply_fetch_latest_user_event_id ~= event_id then return end
    self.reply_fetch_expected_event_id = event_id
    self.reply_fetch_deadline = os.time() + REPLY_FETCH_WINDOW_SECONDS
    self.reply_fetch_backoff_attempts = 0
    self:scheduleReplyFetch(3)
end

function Dialog:scheduleReplyFetch(delay)
    if self.reply_fetch_scheduled or self.reply_fetch_in_flight then return end
    self.reply_fetch_scheduled = true
    UIManager:scheduleIn(delay or 2, function()
        self.reply_fetch_scheduled = false
        self:fetchAndShowReplies(function(found, matched_expected, network_failed)
            if network_failed then
                self:_scheduleReplyFetchBackoff()
                return
            end
            -- Any success (with data or an empty mailbox) means the
            -- transport works again; clear the backoff counter.
            self.reply_fetch_backoff_attempts = 0
            if matched_expected then
                self.reply_fetch_deadline = nil
                self.reply_fetch_expected_event_id = nil
            elseif found and not self.reply_fetch_expected_event_id then
                self.reply_fetch_deadline = nil
            elseif self.reply_fetch_deadline and os.time() < self.reply_fetch_deadline then
                self:scheduleReplyFetch(5)
            else
                self.reply_fetch_deadline = nil
                self.reply_fetch_expected_event_id = nil
            end
        end)
    end)
end

-- One more single-flight fetch at the next backoff delay, then stand down
-- after the last attempt (onNetworkConnected remains the catch-up trigger).
-- Going through scheduleReplyFetch keeps the reply_fetch_scheduled /
-- reply_fetch_in_flight mutexes authoritative, so a retry can never run
-- alongside the reply window's own 5s refetches.
function Dialog:_scheduleReplyFetchBackoff()
    local attempts = self.reply_fetch_backoff_attempts or 0
    local delay = REPLY_FETCH_BACKOFF_DELAYS[attempts + 1]
    if not delay then
        logger.warn("[agentlink] reply fetch backoff exhausted; waiting for network reconnect")
        return
    end
    self.reply_fetch_backoff_attempts = attempts + 1
    logger.info(string.format(
        "[agentlink] reply fetch network failure, retry %d/%d in %ds",
        self.reply_fetch_backoff_attempts, #REPLY_FETCH_BACKOFF_DELAYS, delay))
    self:scheduleReplyFetch(delay)
end

-- --- unread surfaces -------------------------------------------------------------

function Dialog:_footerUnreadText()
    if self.unread_count and self.unread_count > 0 then
        return string.format("%s·%d", self:agentName(), self.unread_count)
    end
    return nil
end

function Dialog:installFooterUnreadSuffix()
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if not footer or type(footer.updateFooterTextGenerator) ~= "function"
            or type(footer.applyFooterMode) ~= "function" then return end
    if footer.agentlink_original_update_generator then return end

    local plugin = self
    local function wrap_current_generator()
        if footer.genFooterText == footer.agentlink_wrapped_generator then return end
        local base_generator = footer.genFooterText
        footer.agentlink_base_generator = base_generator
        footer.agentlink_wrapped_generator = function(this)
            local text, merge = base_generator(this)
            local unread = plugin:_footerUnreadText()
            if not unread then return text, merge end
            if text and text ~= "" then
                return text .. this:genSeparator() .. unread, merge
            end
            return unread, merge
        end
        footer.genFooterText = footer.agentlink_wrapped_generator
    end

    footer.agentlink_original_update_generator = footer.updateFooterTextGenerator
    footer.updateFooterTextGenerator = function(this, ...)
        local changed = this.agentlink_original_update_generator(this, ...)
        wrap_current_generator()
        return changed
    end
    footer.agentlink_original_apply_footer_mode = footer.applyFooterMode
    footer.applyFooterMode = function(this, ...)
        local changed = this.agentlink_original_apply_footer_mode(this, ...)
        wrap_current_generator()
        return changed
    end
    wrap_current_generator()
end

function Dialog:_refreshFooter()
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if not footer then return end
    if type(footer.updateFooter) == "function" then
        footer:updateFooter()
    end
end

function Dialog:onReaderReady()
    self:installFooterUnreadSuffix()
    self:scheduleReplyFetch(1.5)
end

-- --- envelopes --------------------------------------------------------------------

-- The deep door carries the reader context when available; the quick door is
-- lightweight by contract. Both share one excerpt endpoint.
function Dialog:buildDoorEvent(door, note, selected_text)
    local event = {
        event_id = Context.newEventId(),
        kind = "excerpt",
        door = door,
        note = note,
        selection = { text = selected_text },
        sent_at = tostring(os.time()),
    }
    local book = Context.bookIdentity(self.ui)
    if book then
        event.book = book
        event.position = Context.position(self.ui)
    end
    return event
end

-- --- doors --------------------------------------------------------------------------

function Dialog:showQuickDialog(selected_text)
    local quick_dialog
    quick_dialog = InputDialog:new{
        title = self:quickLabel(),
        input = "",
        input_hint = "想说什么就说什么",
        description = "不打断阅读，一句话发过来就好。",
        allow_newline = true,
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(quick_dialog)
                    end,
                },
                {
                    text = "发送",
                    callback = function()
                        local text = util.cleanupSelectedText(quick_dialog:getInputValue() or "")
                        UIManager:close(quick_dialog)
                        if text == "" then return end
                        local event = self:buildDoorEvent("quick", text, selected_text)
                        if self.queue:sendOrQueue(event) then
                            self:_showTransientInfo("已发给 " .. self:agentName())
                            self:startReplyFetchWindow(event.event_id)
                        else
                            UIManager:show(InfoMessage:new{
                                text = "保存失败，请重试",
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(quick_dialog)
    quick_dialog:onShowKeyboard()
end

function Dialog:showDeepDialog(selected_text)
    local deep_dialog
    deep_dialog = InputDialog:new{
        title = self:deepLabel(),
        input = "",
        input_hint = "留空将只发送原句",
        description = "写下你的想法，或者直接发送。",
        allow_newline = true,
        buttons = {
            {
                {
                    text = "取消",
                    id = "close",
                    callback = function()
                        UIManager:close(deep_dialog)
                    end,
                },
                {
                    text = "发送",
                    callback = function()
                        local note = util.cleanupSelectedText(deep_dialog:getInputValue() or "")
                        if note == "" then note = nil end
                        local event = self:buildDoorEvent("deep", note, selected_text)
                        UIManager:close(deep_dialog)
                        if self.queue:sendOrQueue(event) then
                            self:_showTransientInfo("已发给 " .. self:agentName())
                        else
                            UIManager:show(InfoMessage:new{
                                text = "保存失败，请重试",
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(deep_dialog)
    deep_dialog:onShowKeyboard()
end

-- --- reply viewer --------------------------------------------------------------------

function Dialog:openReplyViewer()
    local book = Context.bookIdentity(self.ui)
    if not book or not book.title then return end
    local cached = History.load(book)
    local showing_cached = #cached > 0
    if showing_cached then
        self.reply_card_index = 1
        self:showReplyDialog(cached, true)
    else
        self.reply_viewer_open = true
    end
    if self.reply_history_in_flight then return end
    if not self.queue:_networkRadioOn() then
        if not showing_cached then
            self.reply_viewer_open = false
            UIManager:show(InfoMessage:new{
                text = "离线中，联网后可读取这本书的历史问答",
                timeout = 2,
            })
        end
        return
    end
    -- Reopening during an in-flight fetch must keep its result valid.
    self.reply_viewer_generation = (self.reply_viewer_generation or 0) + 1
    local current_generation = self.reply_viewer_generation
    local base_url = self.net.settings:readSetting("replies_url") or Config.DEFAULT_REPLIES_URL
    local url = string.format(
        "%s?history=1&limit=%d&book_title=%s",
        base_url,
        20,
        util.urlEncode(book.title)
    )
    self.reply_history_in_flight = true
    local started = self.net:requestJSONAsync("reply-history", url, function(payload)
        self.reply_history_in_flight = false
        if self.reply_viewer_generation ~= current_generation then return end
        if not payload or type(payload.replies) ~= "table" then
            if not showing_cached then
                self.reply_viewer_open = false
                UIManager:show(InfoMessage:new{
                    text = "暂时无法读取历史问答，请联网后重试",
                    timeout = 3,
                })
            end
            return
        end
        if #payload.replies == 0 then
            if not showing_cached then
                self.reply_viewer_open = false
                UIManager:show(InfoMessage:new{
                    text = "这本书还没有和 " .. self:agentName() .. " 的问答",
                    timeout = 2,
                })
            end
            return
        end
        local replies = History.merge(book, payload.replies)
        if not self.reply_viewer_open then return end
        if #replies == 0 then
            self.reply_viewer_open = false
            UIManager:show(InfoMessage:new{
                text = "这本书还没有和 " .. self:agentName() .. " 的问答",
                timeout = 2,
            })
            return
        end
        self.reply_card_index = 1
        self:showReplyDialog(replies, true)
    end)
    if not started then
        self.reply_history_in_flight = false
    end
end

return Dialog
