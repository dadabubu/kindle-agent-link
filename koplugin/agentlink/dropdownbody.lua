-- Embedded native TouchMenu body. No separate window, toolbar or screen overlay.
local Device = require("device")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local IconWidget = require("ui/widget/iconwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Button = require("ui/widget/button")
local Blitbuffer = require("ffi/blitbuffer")

local Cell = InputContainer:extend{not_focusable = true}
function Cell:init()
    self.icon_widget = IconWidget:new{icon = self.icon, width = Device.screen:scaleBySize(36), height = Device.screen:scaleBySize(36)}
    -- Full text: reduce font if necessary, never truncate the four-character label.
    local size = 18
    repeat
        if self.label_widget and self.label_widget.free then self.label_widget:free() end
        self.label_widget = TextWidget:new{text = self.text, face = Font:getFace("cfont", size)}
        size = size - 1
    until self.label_widget:getSize().w <= self.width or size < 12
    local group = VerticalGroup:new{align="center", self.icon_widget, self.label_widget}
    self.dimen = Geom:new{w=self.width, h=group:getSize().h}
    self[1] = CenterContainer:new{dimen=Geom:new{w=self.width,h=self.dimen.h}, group}
    self.ges_events = {TapCell={GestureRange:new{ges="tap",range=function() return self.dimen end}}}
end
function Cell:onTapCell()
    if self.callback then self.callback() end
    return true
end
function Cell:setBadge(count)
    if self.badge_widget and self.badge_widget.free then self.badge_widget:free() end
    self.badge_widget = nil
    if count > 0 then
        self.badge_widget = FrameContainer:new{
            padding=Device.screen:scaleBySize(2), bordersize=0, margin=0,
            background=Blitbuffer.COLOR_BLACK,
            TextWidget:new{text=tostring(count), face=Font:getFace("cfont",12), fgcolor=Blitbuffer.COLOR_WHITE},
        }
    end
end
function Cell:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    self[1]:paintTo(bb,x,y)
    if self.badge_widget then
        local iw=self.icon_widget:getSize().w
        local bw=self.badge_widget:getSize().w
        self.badge_widget:paintTo(bb,math.min(x+self.width-bw,x+math.floor((self.width+iw)/2)-math.floor(bw/2)),y)
    end
end
function Cell:free()
    if self.badge_widget and self.badge_widget.free then self.badge_widget:free() end
    self.badge_widget=nil
    InputContainer.free(self)
end

local Slider = InputContainer:extend{not_focusable=true}
function Slider:init()
    self.label=TextWidget:new{text="",face=Font:getFace("cfont",16),max_width=self.width}
    self.progress=ProgressWidget:new{width=self.width,height=Device.screen:scaleBySize(32),percentage=0}
    self[1]=VerticalGroup:new{align="left",self.label,self.progress}
    self.dimen=Geom:new(self[1]:getSize())
    self.ges_events={Adjust={}}
    for _,ges in ipairs({"tap","pan","pan_release"}) do
        table.insert(self.ges_events.Adjust,GestureRange:new{
            ges=ges,rate=ges=="pan" and 3 or nil,range=function() return self.progress.dimen end,
        })
    end
    self:refresh()
end
function Slider:refresh()
    local value=self.read_value()
    self.label:setText(string.format("%s  %d / %d",self.title,value,self.maximum))
    local span=self.maximum-self.minimum
    self.progress:setPercentage(span>0 and (value-self.minimum)/span or 0)
end
function Slider:onAdjust(_,ges)
    local percent=self.progress:getPercentageFromPosition(ges.pos)
    if not percent and ges.pos and ges.pos.x and self.progress.dimen.w>0 then
        percent=(ges.pos.x-self.progress.dimen.x)/self.progress.dimen.w
    end
    if percent and percent==percent then
        percent=math.max(0,math.min(1,percent))
        self.write_value(self.minimum+percent*(self.maximum-self.minimum))
        self:refresh()
        if self.after_change then self.after_change() end
        UIManager:setDirty(self.show_parent or self,"ui")
    end
    return true
end

local Body=InputContainer:extend{not_focusable=true}
function Body:init()
    local col=math.floor(self.width/4)
    self.quick_buttons={
        {text="查看回复",icon="star.full",callback=self.on_reply,badge={visible=false,text=""}},
        {text="同步书库",icon="book.opened",callback=self.on_books},
        {text="同步状态",icon="appbar.tools",callback=self.on_status},
        {text="Wi-Fi",icon="wifi",callback=self.on_wifi},
    }
    local buttons=HorizontalGroup:new{align="center"}
    for _,b in ipairs(self.quick_buttons) do
        b.cell=Cell:new{width=col,text=b.text,icon=b.icon,callback=b.callback}
        table.insert(buttons,b.cell)
    end
    local content=VerticalGroup:new{
        align="left",
        VerticalSpan:new{width=Device.screen:scaleBySize(8)},
        buttons,
        VerticalSpan:new{width=Device.screen:scaleBySize(12)},
    }
    local function row(name,spec,toggle)
        local button_w=Device.screen:scaleBySize(40)
        local toggle_w=toggle and Device.screen:scaleBySize(64) or 0
        local slider=Slider:new{
            width=self.width-2*button_w-toggle_w,
            title=name=="brightness" and "亮度" or "色温（冷 → 暖）",
            minimum=spec.minimum,maximum=spec.maximum,read_value=spec.read_value,
            write_value=spec.write_value,show_parent=self.show_parent,
            after_change=function() self:refreshLights() end,
        }
        self[name.."_slider"]=slider
        local function step(delta)
            spec.write_value(spec.read_value()+delta)
            self:refreshLights()
            UIManager:setDirty(self.show_parent or self,"ui")
        end
        self[name.."_minus"]=Button:new{text="−",width=button_w,bordersize=0,callback=function() step(-1) end,show_parent=self.show_parent}
        self[name.."_plus"]=Button:new{text="＋",width=button_w,bordersize=0,callback=function() step(1) end,show_parent=self.show_parent}
        -- Align +/- and ON/OFF with the track, not label+track together.
        local label_height=slider.label:getSize().h
        local function alignedControl(button)
            return VerticalGroup:new{VerticalSpan:new{width=label_height},button}
        end
        local group=HorizontalGroup:new{
            align="center",alignedControl(self[name.."_minus"]),slider,alignedControl(self[name.."_plus"]),
        }
        if toggle then
            self.brightness_toggle=Button:new{
                text=self.is_light_on() and "ON" or "OFF",width=toggle_w,bordersize=0,show_parent=self.show_parent,
                callback=function() self.on_toggle();self:refreshLights();UIManager:setDirty(self.show_parent or self,"ui") end,
            }
            table.insert(group,alignedControl(self.brightness_toggle))
        end
        table.insert(content,group)
        table.insert(content,VerticalSpan:new{width=Device.screen:scaleBySize(8)})
    end
    if self.brightness then row("brightness",self.brightness,true) end
    if self.warmth then
        self.warmth_endpoints={"冷","暖"}
        row("warmth",self.warmth,false)
    end
    self[1]=content
    self.dimen=Geom:new{w=self.width,h=content:getSize().h}
    self.ges_events={Consume={}}
    for _,ges in ipairs({"tap","pan","pan_release","hold","swipe"}) do
        table.insert(self.ges_events.Consume,GestureRange:new{ges=ges,range=function() return self.dimen end})
    end
    self:refreshBadge(self.unread_count or 0)
end
function Body:onConsume() return true end
function Body:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    self[1]:paintTo(bb,x,y)
end
function Body:refreshBadge(count)
    count=math.max(0,math.floor(tonumber(count) or 0))
    local b=self.quick_buttons[1]
    b.badge.visible=count>0
    b.badge.text=count>0 and tostring(count) or ""
    b.cell:setBadge(count)
    UIManager:setDirty(self.show_parent or self,"ui")
end
function Body:refreshLights()
    if self.brightness_slider then self.brightness_slider:refresh() end
    if self.warmth_slider then self.warmth_slider:refresh() end
    if self.brightness_toggle then
        local text=self.is_light_on() and "ON" or "OFF"
        if self.brightness_toggle.setText then self.brightness_toggle:setText(text) else self.brightness_toggle.text=text end
    end
end
return Body
