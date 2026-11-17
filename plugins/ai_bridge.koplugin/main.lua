-- Sends the current page and reading position to the iPhone companion.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Device = require("device")
local screen = Device.screen
local http = require("socket.http")
local ltn12 = require("ltn12")

local AiBridge = WidgetContainer:extend{
    name = "ai_bridge",
    is_doc_only = true,
}

local function loadConfig(path)
    local ok, config = pcall(dofile, (path or ".") .. "/config.lua")
    if ok and type(config) == "table" then return config end
    return {
        url = "http://172.20.10.1:8790/context",
        token = "change-me",
        max_chars = 4000,
    }
end

local function encode(value)
    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end
    if ok and json and json.encode then
        return json.encode(value)
    end
    return nil
end

function AiBridge:init()
    self.config = loadConfig(self.path)
    self.last_sent = 0
end

function AiBridge:onReaderReady()
    self:scheduleSend()
end

function AiBridge:onPageUpdate(pageno)
    logger.info("ai_bridge: page_update", tostring(pageno))
    self:scheduleSend(pageno)
end

function AiBridge:onPosUpdate(pos, pageno)
    logger.info("ai_bridge: pos_update", tostring(pageno))
    self:scheduleSend(pageno)
end

function AiBridge:scheduleSend(pageno)
    local now = os.time()
    if now - (self.last_sent or 0) < 1 then return end
    self.last_sent = now
    UIManager:scheduleIn(0.1, function()
        self:sendContext(pageno)
    end)
end

function AiBridge:sendContext(pageno)
    if not self.ui or not self.ui.document then return end
    local doc = self.ui.document
    local page = pageno or (self.ui.view and self.ui.view.footer and self.ui.view.footer.pageno) or 1
    local page_count = 1
    pcall(function() page_count = doc:getPageCount() or 1 end)

    local text = ""
    -- CRE documents do not implement Document:getPageText(); use the visible
    -- text selection API instead.
    pcall(function()
        local result = doc:getTextFromPositions(
            { x = 0, y = 0, page = page },
            { x = screen:getWidth(), y = screen:getHeight(), page = page },
            true
        )
        if result and result.text then text = result.text end
    end)
    if text == "" then
        pcall(function() text = doc:getPageText(page) or "" end)
    end
    text = text:sub(1, self.config.max_chars or 4000)
    logger.info("ai_bridge: text_length", #text, "screen", tostring(screen:getWidth()), tostring(screen:getHeight()))

    local props = self.ui.doc_props or {}
    local book = props.title or ""
    local chapter = ""
    pcall(function()
        if self.ui.toc and self.ui.toc.getTocTitleOfCurrentPage then
            chapter = self.ui.toc:getTocTitleOfCurrentPage() or ""
        end
    end)

    local payload = {
        book = book,
        chapter = chapter,
        page = page,
        progress = (page_count > 0) and (page / page_count * 100) or 0,
        text = text,
        updatedAt = os.time(),
    }
    local body = encode(payload)
    if not body then
        logger.warn("ai_bridge: no JSON encoder")
        return
    end

    local response = {}
    local ok, code = http.request{
        url = self.config.url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["X-Companion-Token"] = self.config.token or "",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    logger.info("ai_bridge: response", tostring(ok), tostring(code), "chars", #body)
    if not ok or (code and code >= 400) then
        logger.warn("ai_bridge: send failed", tostring(code))
    end
end

return AiBridge
