-- ReaderMenu-instance adapter: retain native toolbar, replace only our tab body.
local UIManager = require("ui/uimanager")
local Topbar = {}
local BUTTON_ID = "agentlink_panel_topbar"
local STATE_KEY = "_agentlink_panel_topbar"

local function insertButton(menu)
    local state = rawget(menu, STATE_KEY)
    local tabs = menu.tab_item_table
    if not state or not state.active or type(tabs) ~= "table" then return end
    for i = #tabs, 1, -1 do
        if tabs[i].id == BUTTON_ID then table.remove(tabs, i) end
    end
    table.insert(tabs, 1, {
        id = BUTTON_ID, text = "AgentLink 面板",
        icon = "star.full",
        remember = false,
        -- Native init requires an item. Replaced before the menu is shown.
        { text = "AgentLink 面板", enabled = false },
    })
end

local function attach(tm, state)
    if tm._agentlink_dropdown_adapter then return end
    tm._agentlink_dropdown_adapter = true
    local original = tm.updateItems
    tm.updateItems = function(this, ...)
        local previous = this.dimen and this.dimen:copy()
        this._agentlink_body = nil
        -- Native footer/time, focus, dirty-region and all other tabs stay native.
        local result = original(this, ...)
        if not state.active or not this.item_table or this.item_table.id ~= BUTTON_ID then return result end
        local body = state.build_body(this.item_width, this)
        this._agentlink_body = body
        this.item_group:clear()
        table.insert(this.item_group, this.bar)
        table.insert(this.item_group, body)
        table.insert(this.item_group, this.footer_top_margin)
        table.insert(this.item_group, this.footer)
        if this.item_group.resetLayout then this.item_group:resetLayout() end
        this.layout = { this.bar.icon_widgets }
        this.page, this.page_num = 1, 1
        this.dimen.w = this.width
        this.dimen.h = this.item_group:getSize().h + this.bordersize * 2 + this.padding
        UIManager:setDirty("all", "ui", previous and previous:combine(this.dimen) or this.dimen)
        return result
    end
    tm:updateItems(1)
end

function Topbar.install(menu, build_body)
    if type(menu) ~= "table" or type(menu.setUpdateItemTable) ~= "function" then return false end
    local state = rawget(menu, STATE_KEY)
    if state then
        state.active, state.build_body = true, build_body
    else
        state = {active = true, build_body = build_body}
        menu[STATE_KEY] = state
        local original_update = menu.setUpdateItemTable
        menu.setUpdateItemTable = function(this, ...)
            local result = original_update(this, ...)
            insertButton(this)
            return result
        end
        local original_close = menu.onCloseReaderMenu
        if original_close then
            menu.onCloseReaderMenu = function(this, ...)
                local tm = this.menu_container and this.menu_container[1]
                local body = tm and tm._agentlink_body
                if body and body.on_detach then body:on_detach() end
                if tm then tm._agentlink_body = nil end
                return original_close(this, ...)
            end
        end
        local original_show = menu.onShowMenu
        if original_show then
            menu.onShowMenu = function(this, index, hidden)
                local container = this.menu_container
                if not container then
                    -- Construct original chrome without showing an intermediate frame.
                    original_show(this, index, true)
                    container = this.menu_container
                    if not container then return false end
                    attach(container[1], state)
                elseif index and container[1].bar then
                    container[1].bar:switchToTab(index)
                end
                local tm = container[1]
                if not hidden and tm.not_shown ~= false then
                    tm.not_shown = false
                    UIManager:show(container)
                elseif hidden then
                    tm.not_shown = true
                end
                return true
            end
        end
    end
    insertButton(menu)
    return true
end

function Topbar.show(menu)
    local state = type(menu) == "table" and rawget(menu, STATE_KEY)
    if not state or not state.active or not menu.onShowMenu then return false end
    if not menu.tab_item_table then menu:setUpdateItemTable() end
    for index, tab in ipairs(menu.tab_item_table) do
        if tab.id == BUTTON_ID then return menu:onShowMenu(index) end
    end
    return false
end

function Topbar.cancelPending(menu)
    -- No delayed opening remains. Suspend closes the live native menu.
    if type(menu) == "table" and menu.menu_container and menu.onTapCloseMenu then menu:onTapCloseMenu() end
end

function Topbar.deactivate(menu)
    if type(menu) ~= "table" then return end
    local state = rawget(menu, STATE_KEY)
    if not state then return end
    Topbar.cancelPending(menu)
    state.active = false
    if type(menu.tab_item_table) == "table" then
        for i = #menu.tab_item_table, 1, -1 do
            if menu.tab_item_table[i].id == BUTTON_ID then table.remove(menu.tab_item_table, i) end
        end
    end
end

return Topbar
