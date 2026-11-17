-- WeRead Home: opens the WeRead shelf when KOReader starts.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local WeReadHome = WidgetContainer:extend{
    name = "weread_home",
    is_doc_only = false,
}

local function openShelf(ui, attempt)
    if not ui or ui.document then return end
    local weread = ui["weread"]
    if weread and weread.openBookshelf then
        local ok, err = pcall(function() weread:openBookshelf() end)
        if not ok then logger.warn("weread_home: openBookshelf failed:", err) end
        return
    end
    attempt = (attempt or 0) + 1
    if attempt <= 6 then
        UIManager:scheduleIn(0.5, function() openShelf(ui, attempt) end)
    end
end

function WeReadHome:init()
    UIManager:scheduleIn(0.5, function() openShelf(self.ui, 0) end)
end

return WeReadHome
