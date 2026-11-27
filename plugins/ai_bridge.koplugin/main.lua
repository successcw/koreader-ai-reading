-- Sends the current page and reading position to the iPhone companion.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Device = require("device")
local screen = Device.screen
local http = require("socket.http")
local ltn12 = require("ltn12")
local NetworkMgr = require("ui/network/manager")
local socketutil = require("socketutil")
local socket = require("socket")

-- KOReader's socketutil resets socket.http.TIMEOUT to 60s. Set it around
-- this request explicitly so an unreachable phone never freezes the UI.
local REQUEST_BLOCK_TIMEOUT = 1
local REQUEST_TOTAL_TIMEOUT = 3
local DISCOVERY_PORT = 8791
local DISCOVERY_REQUEST = "READING_COMPANION_DISCOVER_V1"
local WAKE_PORT = 8792
local WAKE_REQUEST = "READING_COMPANION_WAKE_V1"
local ACTIVE_RETRY_SECONDS = 30

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
    self.retry_scheduled = false
    self.retry_generation = 0
    self.retry_count = 0
    self.suspended = false
    self.discovery_socket = nil
    self.discovery_generation = 0
    self.wake_socket = nil
    self.wake_generation = 0
end

function AiBridge:onReaderReady()
    self.suspended = false
    self.retry_count = 0
    self:discover()
    self:startWakeListener()
    self:scheduleSend()
end

function AiBridge:onSuspend()
    logger.info("ai_bridge: suspended; stopping network retries")
    self.suspended = true
    self.retry_generation = (self.retry_generation or 0) + 1
    self.retry_scheduled = false
    if self.discovery_socket then
        self.discovery_socket:close()
        self.discovery_socket = nil
    end
    if self.wake_socket then
        self.wake_socket:close()
        self.wake_socket = nil
        self.wake_generation = (self.wake_generation or 0) + 1
    end
end

function AiBridge:onResume()
    logger.info("ai_bridge: resumed; discovery + sync")
    self.suspended = false
    self.retry_count = 0
    self:discover()
    self:startWakeListener()
    self:scheduleSend(nil, true)
end

function AiBridge:startWakeListener()
    if self.suspended or self.wake_socket then return end
    local udp = socket.udp()
    local ok = pcall(function()
        udp:setsockname("*", WAKE_PORT)
        udp:settimeout(0)
    end)
    if not ok then
        udp:close()
        return
    end
    self.wake_socket = udp
    self.wake_generation = (self.wake_generation or 0) + 1
    self:pollWake(self.wake_generation)
end

function AiBridge:pollWake(generation)
    if generation ~= self.wake_generation then return end
    local udp = self.wake_socket
    if not udp then return end
    local data = udp:receivefrom()
    if data and type(data) == "string" and data:sub(1, #WAKE_REQUEST) == WAKE_REQUEST then
        local wake_url = data:match("|(http://[^|]+)$")
        if wake_url then
            self.config.url = wake_url
            logger.info("ai_bridge: app wake received", wake_url)
        else
            logger.info("ai_bridge: app wake received")
        end
        self.retry_count = 0
        self:scheduleSend(nil, true)
    end
    if not self.suspended and self.wake_socket then
        UIManager:scheduleIn(2, function()
            self:pollWake(generation)
        end)
    end
end

function AiBridge:onNetworkConnected()
    logger.info("ai_bridge: network connected")
    self.retry_count = 0
    self:discover()
    self:scheduleSend(nil, true)
end

function AiBridge:discover()
    if self.suspended then return end
    if self.discovery_socket then
        self.discovery_socket:close()
        self.discovery_socket = nil
    end
    self.discovery_generation = (self.discovery_generation or 0) + 1
    local generation = self.discovery_generation
    local udp = socket.udp()
    udp:setsockname("*", 0)
    udp:settimeout(0)
    udp:setoption("broadcast", true)
    local targets = {
        "255.255.255.255",
        "172.20.10.255", -- iPhone hotspot
        "192.168.43.255", -- common Android hotspot
    }
    if self.config.discovery_broadcast then
        targets[#targets + 1] = self.config.discovery_broadcast
    end
    local ok = false
    for _, host in ipairs(targets) do
        local sent = pcall(function()
            udp:sendto(DISCOVERY_REQUEST, host, DISCOVERY_PORT)
        end)
        ok = ok or sent
        logger.info("ai_bridge: discovery sent", host)
    end
    if not ok then
        udp:close()
        return
    end
    self.discovery_socket = udp
    self:pollDiscovery(generation, 0)
end

function AiBridge:pollDiscovery(generation, attempts)
    if generation ~= self.discovery_generation then return end
    local udp = self.discovery_socket
    if not udp then return end
    local data = udp:receivefrom()
    if data and type(data) == "string" then
        local url = data:match('"url"%s*:%s*"([^"]+)"')
        if url and url ~= "" then
            logger.info("ai_bridge: discovered", url)
            self.config.url = url
            udp:close()
            self.discovery_socket = nil
            self:scheduleSend(nil, true)
            return
        end
    end
    if attempts < 20 then
        UIManager:scheduleIn(0.2, function()
            self:pollDiscovery(generation, attempts + 1)
        end)
    else
        udp:close()
        self.discovery_socket = nil
    end
end

function AiBridge:onNetworkDisconnected()
    logger.info("ai_bridge: network disconnected, will retry")
    self.retry_count = 0
    self:scheduleRetry()
end

function AiBridge:scheduleRetry()
    if self.suspended then return end
    if self.retry_scheduled then return end
    self.retry_count = (self.retry_count or 0) + 1
    if self.retry_count > 3 then
        logger.info("ai_bridge: retry limit reached; waiting for page/network/wake")
        return
    end
    self.retry_scheduled = true
    self.retry_generation = (self.retry_generation or 0) + 1
    local generation = self.retry_generation
    UIManager:scheduleIn(ACTIVE_RETRY_SECONDS, function()
        if generation ~= self.retry_generation then return end
        self.retry_scheduled = false
        if self.ui and self.ui.document then
            self:sendContext()
        end
    end)
end

function AiBridge:onPageUpdate(pageno)
    logger.info("ai_bridge: page_update", tostring(pageno))
    self:scheduleSend(pageno)
end

function AiBridge:onPosUpdate(pos, pageno)
    logger.info("ai_bridge: pos_update", tostring(pageno))
    self:scheduleSend(pageno)
end

function AiBridge:scheduleSend(pageno, force)
    if self.suspended then return end
    local now = os.time()
    if not force and now - (self.last_sent or 0) < 1 then return end
    self.retry_count = 0
    self.last_sent = now
    UIManager:scheduleIn(0.1, function()
        self:sendContext(pageno)
    end)
end

function AiBridge:urlCandidates()
    local list, seen = {}, {}
    local function add(url)
        if type(url) == "string" and url ~= "" and not seen[url] then
            seen[url] = true
            list[#list + 1] = url
        end
    end
    add(self.config.url)
    if type(self.config.urls) == "table" then
        for _, url in ipairs(self.config.urls) do add(url) end
    else
        -- Keep the two hotspot gateways as fallbacks when the user only
        -- configured a home Wi-Fi address.
        add("http://172.20.10.1:8790/context")
        add("http://192.168.43.1:8790/context")
    end
    return list
end

function AiBridge:sendContext(pageno)
    if self.suspended then return end
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

    -- Cheap network check: when Wi-Fi is still off, retry later instead of
    -- blocking on a socket connect (which is what made the old flow wait for
    -- the next page turn).
    local connected = true
    pcall(function()
        if NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
            connected = false
        end
    end)
    if not connected then
        logger.info("ai_bridge: no network, requesting Wi-Fi restore")
        pcall(function()
            if NetworkMgr and NetworkMgr.restoreWifiAsync then
                NetworkMgr:restoreWifiAsync()
            end
        end)
        self:scheduleRetry()
        return
    end

    local sent = false
    local last_code = nil
    for _, url in ipairs(self:urlCandidates()) do
        local response = {}
        socketutil:set_timeout(REQUEST_BLOCK_TIMEOUT, REQUEST_TOTAL_TIMEOUT)
        local request_ok, ok, code = pcall(http.request, {
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["X-Companion-Token"] = self.config.token or "",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(response),
        })
        socketutil:reset_timeout()
        if not request_ok then
            code = tostring(ok)
            ok = nil
        end
        logger.info("ai_bridge: response", url, tostring(ok), tostring(code), "chars", #body)
        if ok and not (code and code >= 400) then
            self.config.url = url
            self.retry_count = 0
            sent = true
            break
        end
        last_code = code
    end
    if not sent then
        logger.warn("ai_bridge: send failed", tostring(last_code))
        if not self.config.url or self.retry_count < 1 then
            self:discover()
        end
        self:scheduleRetry()
    else
        -- Invalidate any retry that was queued before this successful send.
        self.retry_generation = (self.retry_generation or 0) + 1
        self.retry_scheduled = false
    end
end

return AiBridge
