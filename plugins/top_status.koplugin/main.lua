-- Configures the native CRE top status bar and adds a Wi-Fi indicator.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

local TopStatus = WidgetContainer:extend{
    name = "top_status",
    is_doc_only = true,
}

local function wifiText()
    if not NetworkMgr:isWifiOn() then return "WiFi off" end
    if NetworkMgr:isConnected() then return "WiFi" end
    return "WiFi ..."
end

function TopStatus:onReaderReady()
    local ui = self.ui
    if not ui then return end
    if ui.doc_settings then
        ui.doc_settings:saveSetting("copt_status_line", 0)
    end
    ui:handleEvent(Event:new("SetStatusLine", 0))

    local cl = ui.crelistener
    if not cl then return end
    cl.header_auto_refresh = 1
    cl.title = 0
    cl.author = 0
    cl.chapter_marks = 0
    cl.clock = 1
    cl.page_number = 1
    cl.page_count = 1
    cl.battery = 1
    cl.battery_percent = 1
    cl.reading_percent = 0

    local function set(key, prop, value)
        cl[key] = value
        if prop then pcall(function() cl:setAndSave(key, prop, value) end) end
    end
    set("cre_header_auto_refresh", nil, 1)
    set("cre_header_title", "window.status.title", 0)
    set("cre_header_author", "window.status.author", 0)
    set("cre_header_chapter_marks", "crengine.page.header.chapter.marks", 0)
    set("cre_header_clock", "window.status.clock", 1)
    set("cre_header_page_number", "window.status.pos.page.number", 1)
    set("cre_header_page_count", "window.status.pos.page.count", 1)
    set("cre_header_battery", "window.status.battery", 1)
    set("cre_header_battery_percent", "window.status.battery.percent", 1)
    set("cre_header_reading_percent", "window.status.pos.percent", 0)
    pcall(function() cl:rescheduleHeaderRefreshIfNeeded() end)

    if self._wifi_func then
        pcall(function() cl:removeAdditionalHeaderContent(self._wifi_func) end)
    end
    self._wifi_func = function() return "  " .. wifiText() end
    cl:addAdditionalHeaderContent(self._wifi_func)
    cl:updateHeader()
    logger.info("top_status: configured")
end

function TopStatus:refresh()
    if self.ui and self.ui.crelistener then
        pcall(function() self.ui.crelistener:updateHeader() end)
    end
end
TopStatus.onNetworkConnected = TopStatus.refresh
TopStatus.onNetworkDisconnected = TopStatus.refresh
TopStatus.onNetworkWifiOn = TopStatus.refresh
TopStatus.onNetworkWifiOff = TopStatus.refresh

return TopStatus
