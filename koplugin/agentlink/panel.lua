-- Reading-only UI shell. Existing modules remain the owners of all I/O.
local Device = require("device")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local lfs = require("libs/libkoreader-lfs")
local Panel = {}
Panel.__index = Panel
local Slider

local function clamp(value, low, high)
    value = tonumber(value)
    if not value or value ~= value then return nil end
    return math.max(low, math.min(high, math.floor(value + 0.5)))
end

local function sliderClass()
    if Slider then return Slider end
    local InputContainer = require("ui/widget/container/inputcontainer")
    local ProgressWidget = require("ui/widget/progresswidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local GestureRange = require("ui/gesturerange")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    Slider = InputContainer:extend{ not_focusable = true }
    function Slider:init()
        self.label = TextWidget:new{ text = "", face = Font:getFace("cfont"), max_width = self.width }
        self.progress = ProgressWidget:new{
            width = self.width, height = Device.screen:scaleBySize(36), percentage = 0,
        }
        self[1] = VerticalGroup:new{ align = "left", self.label, self.progress }
        self.dimen = Geom:new(self[1]:getSize())
        self.ges_events = { Adjust = {} }
        for _, gesture in ipairs({"tap", "pan", "pan_release"}) do
            table.insert(self.ges_events.Adjust, GestureRange:new{
                ges = gesture,
                rate = gesture == "pan" and 3 or nil,
                range = function() return self.progress.dimen end,
            })
        end
        self:refresh()
    end
    function Slider:refresh()
        local value = self.read_value()
        self.label:setText(string.format("%s  %d / %d", self.title, value, self.maximum))
        local span = self.maximum - self.minimum
        self.progress:setPercentage(span > 0 and (value - self.minimum) / span or 0)
    end
    function Slider:onAdjust(_, gesture)
        local percent = self.progress:getPercentageFromPosition(gesture.pos)
        if percent then
            self.write_value(self.minimum + percent * (self.maximum - self.minimum))
            self:refresh()
            UIManager:setDirty(self.parent, "ui")
        end
        return true
    end
    return Slider
end

function Panel:new(opts)
    local instance = setmetatable(opts or {}, self)
    instance.powerd = Device:getPowerDevice()
    instance.has_fl = Device:hasFrontlight()
    instance.has_nl = Device:hasNaturalLight()
    return instance
end

function Panel:setBrightness(value)
    if not self.has_fl then return end
    local p = self.powerd
    value = clamp(value, p.fl_min, p.fl_max)
    if not value then return end
    local current = p:frontlightIntensity()
    if current > p.fl_min then self.last_brightness = current end
    if value ~= current then
        -- Unlike the native toggle button, selecting zero is idempotently off.
        p:setIntensity(value)
        p:updateResumeFrontlightState()
    end
    if value > p.fl_min then self.last_brightness = value end
    if self.brightness_slider then self.brightness_slider:refresh() end
    return p:frontlightIntensity()
end

function Panel:setWarmth(value)
    if not self.has_nl then return end
    local p = self.powerd
    value = clamp(value, p.fl_warmth_min, p.fl_warmth_max)
    if not value then return end
    if value ~= p:toNativeWarmth(p:frontlightWarmth()) then
        p:setWarmth(p:fromNativeWarmth(value))
    end
    if self.warmth_slider then self.warmth_slider:refresh() end
    return p:toNativeWarmth(p:frontlightWarmth())
end

function Panel:_track(widget, field)
    field = field or "child_widget"
    self[field] = widget
    local old_close = widget.onCloseWidget
    widget.onCloseWidget = function(w, ...)
        if self[field] == w then
            self[field] = nil
            if field == "dialog_widget" then
                self.brightness_slider, self.warmth_slider = nil, nil
            end
        end
        if old_close then return old_close(w, ...) end
    end
    return widget
end

function Panel:close()
    local dialog, child = self.dialog_widget, self.child_widget
    self.dialog_widget, self.child_widget = nil, nil
    local dropdown = self.dropdown_content
    self.dropdown_content, self.dropdown_host = nil, nil
    self.brightness_slider, self.warmth_slider = nil, nil
    if dropdown and self.ui and self.ui.menu then self.ui.menu:onTapCloseMenu() end
    if dialog then UIManager:close(dialog) end
    if child then UIManager:close(child) end
end

function Panel:onCloseDocument()
    self:close()
end

function Panel:show()
    return require("agentlink.topbar").show(self.ui.menu)
end

function Panel:toggleLight()
    if not self.has_fl then return end
    local p = self.powerd
    local current = p:frontlightIntensity()
    if current > p.fl_min then
        self.last_brightness = current
        if p.turnOffFrontlight then p:turnOffFrontlight() else p:setIntensity(p.fl_min) end
    else
        local remembered = self.last_brightness or p.fl_intensity
        if not remembered or remembered <= p.fl_min then remembered = math.max(p.fl_min + 1, math.floor(p.fl_max / 2)) end
        p:setIntensity(remembered)
    end
    p:updateResumeFrontlightState()
    return p:frontlightIntensity()
end

function Panel:refreshBadge()
    if self.dropdown_content then self.dropdown_content:refreshBadge(self.dialog and self.dialog.unread_count or 0) end
end

function Panel:buildDropdownContent(width, host)
    local Body = require("agentlink.dropdownbody")
    local content = Body:new{
        width = width or Device.screen:getWidth(), show_parent = host and host.show_parent,
        unread_count = self.dialog and self.dialog.unread_count or 0,
        on_reply = function() self:onReplyButtonClick() end,
        on_books = function() self:onBooksButtonClick() end,
        on_status = function() self:onStatusButtonClick() end,
        on_wifi = function() self:onWifiButtonClick() end,
        on_toggle = function() self:toggleLight() end,
        is_light_on = function() return self.powerd:frontlightIntensity() > self.powerd.fl_min end,
        brightness = self.has_fl and {
            minimum = self.powerd.fl_min, maximum = self.powerd.fl_max,
            read_value = function() return self.powerd:frontlightIntensity() end,
            write_value = function(v) self:setBrightness(v) end,
        } or nil,
        warmth = self.has_nl and {
            minimum = self.powerd.fl_warmth_min, maximum = self.powerd.fl_warmth_max,
            read_value = function() return self.powerd:toNativeWarmth(self.powerd:frontlightWarmth()) end,
            write_value = function(v) self:setWarmth(v) end,
        } or nil,
    }
    self.dropdown_content, self.dropdown_host = content, host
    self.brightness_slider, self.warmth_slider = content.brightness_slider, content.warmth_slider
    content.on_detach = function(w)
        if self.dropdown_content == w then
            self.dropdown_content, self.dropdown_host = nil, nil
            self.brightness_slider, self.warmth_slider = nil, nil
        end
    end
    local old_free = content.free
    content.free = function(w, ...)
        w:on_detach()
        if old_free then return old_free(w, ...) end
    end
    return content
end

function Panel:onReplyButtonClick()
    self:close()
    self.dialog:openReplyViewer()
end

function Panel:_showMenu(title, items, icon)
    local TouchMenu = require("ui/widget/touchmenu")
    local tab = {text = title, icon = icon or "appbar.tools"}
    for _, item in ipairs(items) do tab[#tab + 1] = item end
    local menu = TouchMenu:new{
        width = Device.screen:getWidth(), last_index = 1,
        tab_item_table = {tab}, close_callback = function() self:close() end,
    }
    self:_track(menu)
    UIManager:show(menu)
end

function Panel:onBooksButtonClick()
    self:close()
    local label = self.books and self.books.agentName and string.format("%s 书库", self.books:agentName()) or "书库"
    self:_showMenu(label, self.books:menuItems(), "book.opened")
end

local function queueCount(queue)
    if not queue or not queue.dir then return "未知" end
    local ok, count = pcall(function()
        local total = 0
        for name in lfs.dir(queue.dir) do
            if name:match("%.json$") then total = total + 1 end
        end
        return total
    end)
    return ok and tostring(count) or "未知"
end

function Panel:getStatusText()
    local lines = {"本地同步状态（待发为零不代表服务器已收取）"}
    for _, item in ipairs({
        {"阅读记录", self.reading_queue}, {"选段消息", self.dialog_queue},
        {"旧版待发", self.legacy_queue},
    }) do
        local state = item[2] and item[2].draining and "，发送中" or ""
        lines[#lines + 1] = item[1] .. "：待发 " .. queueCount(item[2]) .. state
    end
    local ok, pending = pcall(function() return self.upload_queue:pendingCount() end)
    local state = self.upload_queue and self.upload_queue.draining and "，处理中" or ""
    lines[#lines + 1] = "书籍正文：待传 " .. (ok and tostring(pending) or "未知") .. state
    return table.concat(lines, "\n")
end

function Panel:onStatusButtonClick()
    self:close()
    local InfoMessage = require("ui/widget/infomessage")
    local widget = InfoMessage:new{text = self:getStatusText()}
    self:_track(widget)
    UIManager:show(widget)
end

function Panel:onWifiButtonClick()
    self:close()
    -- The stock TouchMenu item owns toggling, prompting and connection callbacks.
    self:_showMenu("Wi-Fi", {NetworkMgr:getWifiMenuTable(), NetworkMgr:getInfoMenuTable()}, "wifi")
end

return Panel
