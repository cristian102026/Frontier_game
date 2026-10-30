--[[
    FRONTIER - LAN networking

    * A small, SAFE serializer (never uses load/loadstring on network data)
    * LAN discovery over UDP broadcast (LuaSocket, bundled with LÖVE)
    * Game transport over ENet (lua-enet, bundled with LÖVE)
    * A "am I on a network?" check used to require Wi-Fi / LAN for multiplayer

    Channel 0 = reliable events, channel 1 = unreliable state (positions, snapshots).
]]

local N = {}

local okEnet, enet = pcall(require, "enet")
local okSock, socket = pcall(require, "socket")
N.available = okEnet and okSock and enet ~= nil and socket ~= nil

N.VERSION    = "frontier-lan-4"
N.GAME_PORT  = 47811
N.DISC_PORT  = 47810
N.MAX_PLAYERS = 4

local floor, abs = math.floor, math.abs
local sfmt, ssub, sbyte, sfind = string.format, string.sub, string.byte, string.find
local tconcat = table.concat

local function now()
    if okSock and socket and socket.gettime then return socket.gettime() end
    return os.clock()
end
N.now = now

------------------------------------------------------------------------------
-- Codec
--   i<int>;   integer          n<num>;  float       T / F    booleans
--   s<len>:<bytes>  string     a<count>: values...  array
--   m (key value)* e  map
------------------------------------------------------------------------------
local function enc(v, out, depth)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then v = 0 end
        if v == floor(v) and abs(v) < 1e15 then
            out[#out + 1] = "i" .. sfmt("%d", v) .. ";"
        else
            out[#out + 1] = "n" .. sfmt("%.7g", v) .. ";"
        end
    elseif t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        if depth > 12 then out[#out + 1] = "F" return end
        local n = #v
        local isArray = n > 0
        if isArray then
            for k in pairs(v) do
                if type(k) ~= "number" or k < 1 or k > n or k ~= floor(k) then isArray = false break end
            end
        end
        if isArray then
            out[#out + 1] = "a" .. n .. ":"
            for i = 1, n do
                local x = v[i]
                if x == nil then out[#out + 1] = "F" else enc(x, out, depth + 1) end
            end
        else
            out[#out + 1] = "m"
            for k, x in pairs(v) do
                local kt = type(k)
                if (kt == "string" or kt == "number") and type(x) ~= "function" and type(x) ~= "userdata" then
                    enc(k, out, depth + 1)
                    enc(x, out, depth + 1)
                end
            end
            out[#out + 1] = "e"
        end
    else
        out[#out + 1] = "F"
    end
end

function N.encode(v)
    local out = {}
    enc(v, out, 0)
    return tconcat(out)
end

-- Returns value, nextIndex  or  nil on malformed input
local MAX_ITEMS = 20000
local function dec(s, i, depth, budget)
    if depth > 16 then return nil end
    budget.n = budget.n + 1
    if budget.n > MAX_ITEMS then return nil end
    local c = ssub(s, i, i)
    if c == "i" or c == "n" then
        local j = sfind(s, ";", i + 1, true)
        if not j or j - i > 40 then return nil end
        local num = tonumber(ssub(s, i + 1, j - 1))
        if not num then return nil end
        return num, j + 1
    elseif c == "s" then
        local j = sfind(s, ":", i + 1, true)
        if not j or j - i > 12 then return nil end
        local len = tonumber(ssub(s, i + 1, j - 1))
        if not len or len < 0 or len > 65536 or j + len > #s then return nil end
        return ssub(s, j + 1, j + len), j + len + 1
    elseif c == "T" then
        return true, i + 1
    elseif c == "F" then
        return false, i + 1
    elseif c == "a" then
        local j = sfind(s, ":", i + 1, true)
        if not j or j - i > 12 then return nil end
        local n = tonumber(ssub(s, i + 1, j - 1))
        if not n or n < 0 or n > MAX_ITEMS then return nil end
        local arr = {}
        local p = j + 1
        for k = 1, n do
            local v
            v, p = dec(s, p, depth + 1, budget)
            if p == nil then return nil end
            arr[k] = v
        end
        return arr, p
    elseif c == "m" then
        local map = {}
        local p = i + 1
        while true do
            if p > #s then return nil end
            if ssub(s, p, p) == "e" then return map, p + 1 end
            local k, v
            k, p = dec(s, p, depth + 1, budget)
            if p == nil or (type(k) ~= "string" and type(k) ~= "number") then return nil end
            v, p = dec(s, p, depth + 1, budget)
            if p == nil then return nil end
            map[k] = v
        end
    end
    return nil
end

function N.decode(s)
    if type(s) ~= "string" or #s == 0 or #s > 4000000 then return nil end
    local ok, v, p = pcall(dec, s, 1, 0, { n = 0 })
    if not ok or p == nil then return nil end
    return v
end

------------------------------------------------------------------------------
-- Network presence (the game requires Wi-Fi / LAN for multiplayer)
------------------------------------------------------------------------------
local function routeIP(target)
    local s = socket.udp()
    if not s then return nil end
    local ok = s:setpeername(target, 80)
    local ip
    if ok then ip = s:getsockname() end
    s:close()
    if not ip or ip == "0.0.0.0" or ip:match("^127%.") or ip:match("^169%.254%.") then return nil end
    return ip
end

-- Returns the machine's LAN IP, or nil when it is not connected to a network
function N.localIP()
    if not N.available then return nil end
    local ok, ip = pcall(routeIP, "8.8.8.8")
    if ok and ip then return ip end
    ok, ip = pcall(routeIP, "192.168.1.1")
    if ok and ip then return ip end
    return nil
end

------------------------------------------------------------------------------
-- LAN discovery
------------------------------------------------------------------------------
local announceSock, browseSock
local lastQuery = 0
N.servers = {}        -- list of { ip, name, players, max, version, region, kills, seen }
local serverByIp = {}

-- Host side: answer "who's there?" broadcasts. infoFn() returns a table.
function N.startAnnounce(infoFn)
    N.stopAnnounce()
    if not N.available then return false end
    local s = socket.udp()
    if not s then return false end
    s:settimeout(0)
    pcall(function() s:setoption("reuseaddr", true) end)
    local ok = s:setsockname("*", N.DISC_PORT)
    if not ok then s:close() return false end
    announceSock = s
    N.announceInfo = infoFn
    return true
end

function N.stopAnnounce()
    if announceSock then announceSock:close() end
    announceSock = nil
end

function N.pollAnnounce()
    if not announceSock then return end
    for _ = 1, 32 do
        local data, ip, port = announceSock:receivefrom()
        if not data then break end
        if data == "FRONTIER?" and ip and port then
            local info = N.announceInfo and N.announceInfo() or {}
            info.v = N.VERSION
            announceSock:sendto("FRONTIER!" .. N.encode(info), ip, port)
        end
    end
end

-- Client side: search the LAN for hosts
function N.startBrowse()
    N.stopBrowse()
    N.servers, serverByIp = {}, {}
    if not N.available then return false end
    local s = socket.udp()
    if not s then return false end
    s:settimeout(0)
    s:setsockname("*", 0)
    pcall(function() s:setoption("broadcast", true) end)
    browseSock = s
    lastQuery = 0
    return true
end

function N.stopBrowse()
    if browseSock then browseSock:close() end
    browseSock = nil
end

local function broadcastTargets()
    local t = { "255.255.255.255", "127.0.0.1" }
    local ip = N.localIP()
    if ip then
        local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
        if a then t[#t + 1] = a .. "." .. b .. "." .. c .. ".255" end
    end
    return t
end

function N.pollBrowse()
    if not browseSock then return end
    local tnow = now()
    if tnow - lastQuery > 1.0 then
        lastQuery = tnow
        for _, target in ipairs(broadcastTargets()) do
            pcall(function() browseSock:sendto("FRONTIER?", target, N.DISC_PORT) end)
        end
    end
    for _ = 1, 64 do
        local data, ip = browseSock:receivefrom()
        if not data then break end
        if ip and ssub(data, 1, 9) == "FRONTIER!" then
            local info = N.decode(ssub(data, 10))
            if type(info) == "table" then
                -- one game can answer on several addresses (LAN + loopback): merge them by session id
                local key = info.sid and ("sid:" .. tostring(info.sid)) or ip
                local entry = serverByIp[key]
                if not entry then
                    entry = { ip = ip, key = key }
                    serverByIp[key] = entry
                    N.servers[#N.servers + 1] = entry
                elseif entry.ip == "127.0.0.1" and ip ~= "127.0.0.1" then
                    entry.ip = ip           -- prefer the real LAN address
                end
                entry.name = tostring(info.name or "Host"):sub(1, 20)
                entry.players = tonumber(info.players) or 1
                entry.max = tonumber(info.max) or N.MAX_PLAYERS
                entry.version = tostring(info.v or "?")
                entry.region = tostring(info.region or "desert")
                entry.kills = tonumber(info.kills) or 0
                entry.diff = tostring(info.diff or "easy")
                entry.mode = tostring(info.mode or "story")
                entry.seen = tnow
            end
        end
    end
    -- forget hosts that stopped answering; only list games with at least one person inside
    for i = #N.servers, 1, -1 do
        local e = N.servers[i]
        if tnow - e.seen > 4 or (e.players or 0) < 1 then
            serverByIp[e.key or e.ip] = nil
            table.remove(N.servers, i)
        end
    end
end

------------------------------------------------------------------------------
-- Game transport (ENet)
------------------------------------------------------------------------------
local host, serverPeer
local peers = {}      -- id -> peer  (host side)
local peerIds = {}    -- peer index -> id
N.role = nil          -- "host" | "client" | nil

function N.hostGame()
    N.close()
    if not N.available then return false, "Networking is not available in this LÖVE build." end
    local ok, h = pcall(enet.host_create, "*:" .. N.GAME_PORT, 8, 2)
    if not ok or not h then return false, "Could not open port " .. N.GAME_PORT .. " (is another game already hosting?)" end
    host, N.role = h, "host"
    peers, peerIds = {}, {}
    return true
end

function N.join(ip)
    N.close()
    if not N.available then return false, "Networking is not available in this LÖVE build." end
    local ok, h = pcall(enet.host_create)
    if not ok or not h then return false, "Could not create a network socket." end
    local ok2, p = pcall(function() return h:connect(ip .. ":" .. N.GAME_PORT, 2) end)
    if not ok2 or not p then pcall(function() h:destroy() end) return false, "Invalid address." end
    pcall(function() p:timeout(32, 3000, 8000) end)
    host, serverPeer, N.role = h, p, "client"
    return true
end

local function idOf(peer)
    local ok, idx = pcall(function() return peer:index() end)
    if not ok then return nil end
    return peerIds[idx], idx
end

-- handler(kind, id, msg) with kind = "connect" | "disconnect" | "msg"
function N.service(handler)
    if not host then return end
    for _ = 1, 400 do
        local ok, ev = pcall(function() return host:service(0) end)
        if not ok or not ev then break end
        if N.role == "host" then
            if ev.type == "connect" then
                local _, idx = idOf(ev.peer)
                local id = (idx or 0) + 1
                peerIds[idx] = id
                peers[id] = ev.peer
                pcall(function() ev.peer:timeout(32, 3000, 8000) end)
                handler("connect", id)
            elseif ev.type == "disconnect" then
                local id, idx = idOf(ev.peer)
                if id then
                    peers[id] = nil
                    peerIds[idx] = nil
                    handler("disconnect", id)
                end
            elseif ev.type == "receive" then
                local id = idOf(ev.peer)
                local msg = N.decode(ev.data)
                if id and type(msg) == "table" then handler("msg", id, msg) end
            end
        else
            if ev.type == "connect" then
                handler("connect", 1)
            elseif ev.type == "disconnect" then
                handler("disconnect", 1)
                N.close(true)
                return
            elseif ev.type == "receive" then
                local msg = N.decode(ev.data)
                if type(msg) == "table" then handler("msg", 1, msg) end
            end
        end
    end
end

-- Host -> one player
function N.send(id, msg, unreliable)
    local p = peers[id]
    if not p then return end
    pcall(function() p:send(N.encode(msg), unreliable and 1 or 0, unreliable and "unreliable" or "reliable") end)
end

-- Host -> everyone (optionally except one id)
function N.broadcast(msg, unreliable, exceptId)
    if not host or N.role ~= "host" then return end
    local data = N.encode(msg)
    for id, p in pairs(peers) do
        if id ~= exceptId then
            pcall(function() p:send(data, unreliable and 1 or 0, unreliable and "unreliable" or "reliable") end)
        end
    end
end

-- Client -> host
function N.toHost(msg, unreliable)
    if not serverPeer then return end
    pcall(function() serverPeer:send(N.encode(msg), unreliable and 1 or 0, unreliable and "unreliable" or "reliable") end)
end

function N.kick(id)
    local p = peers[id]
    if p then pcall(function() p:disconnect_later() end) end
end

function N.peerCount()
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

function N.close(silent)
    if host then
        if N.role == "client" and serverPeer and not silent then
            pcall(function() serverPeer:disconnect_now() end)
        elseif N.role == "host" then
            for _, p in pairs(peers) do pcall(function() p:disconnect_now() end) end
        end
        pcall(function() host:flush() end)
        pcall(function() host:destroy() end)
    end
    host, serverPeer, N.role = nil, nil, nil
    peers, peerIds = {}, {}
    collectgarbage("collect")   -- release the port even on lua-enet builds without host:destroy()
end

function N.active() return host ~= nil end

return N
