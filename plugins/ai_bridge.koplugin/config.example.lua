-- Edit this file after connecting the iPhone hotspot.
-- iPhone personal hotspot gateway is usually 172.20.10.1.
return {
    url = "http://172.20.10.1:8790/context",
    token = "change-me",
    max_chars = 4000,
    -- Optional: add the current LAN subnet broadcast for routers that drop 255.255.255.255.
    -- discovery_broadcast = "192.168.1.255",
}
