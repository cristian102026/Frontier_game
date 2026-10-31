--[[
    ███████ ██████   ██████  ███    ██ ████████ ██ ███████ ██████
    ██      ██   ██ ██    ██ ████   ██    ██    ██ ██      ██   ██
    █████   ██████  ██    ██ ██ ██  ██    ██    ██ █████   ██████
    ██      ██   ██ ██    ██ ██  ██ ██    ██    ██ ██      ██   ██
    ██      ██   ██  ██████  ██   ████    ██    ██ ███████ ██   ██

    FRONTIER - a top-down open-world survival shooter written in Lua (LÖVE 2D 11.x)

    Goal (Story): cross 5 regions, beat the Blaze Gatekeeper and the Guardian of the Hollow.
    Endless: survive the waves. Alone or with up to 4 players over LAN.

    Controls
      W A S D ........ move                 SPACE .......... dash
      LEFT CLICK ..... shoot                RIGHT CLICK .... block (hold)
      B .............. spellbook (click a spell to cast it)
      V .............. revive a teammate    E .............. trade (merchant)
      G .............. keybind guide        H .............. shop
      P .............. inventory            F .............. toggle HUD
      ESC ............ pause (multiplayer: menu only, the world keeps running)

    Files: main.lua (game), net.lua (LAN multiplayer), profile.lua (permanent player data).
    All sound effects and music are synthesized at startup - no asset files needed.
]]

------------------------------------------------------------------------------
-- Shortcuts & constants
------------------------------------------------------------------------------
local lg = love.graphics
local atan2 = math.atan2 or math.atan
local floor, sqrt, sin, cos, pi, abs = math.floor, math.sqrt, math.sin, math.cos, math.pi, math.abs
local max, min, exp = math.max, math.min, math.exp

-- All numeric constants live in K (keeps LuaJIT's local / upvalue limits happy)
local K = {}
K.WORLD_W, K.WORLD_H = 14400, 14400            -- every region is 3x wider and 3x taller than before
K.KILLS_TO_WIN       = 250                     -- the kill bar: the Hollow gate needs 250 kills
K.MAX_BOXES          = 20                      -- loot boxes kept around the player (per region)

-- Regions: the desert on top, the Frozen Wastes below it, the Haunted Hollow at the bottom
K.GATE_T              = 60                     -- thickness of the wall between the regions
K.FROZEN_Y0           = K.WORLD_H + K.GATE_T   -- top edge of the Frozen Wastes
K.FROZEN_Y1           = K.FROZEN_Y0 + K.WORLD_H
K.REGION_UNLOCK_KILLS = 50
K.GATE_W              = 220
K.GATE_X              = K.WORLD_W / 2 - K.GATE_W / 2
K.MAX_FROZEN_BOXES    = 14
K.MP_MAX, K.MP_PER_KILL = 100, 10
-- The map has two columns:
--   DESERT                        (west, row 0)
--   FROZEN  ->  SWAMP             (row 1: west, east)
--               VOLCANIC          (east, row 2)
--               HOLLOW            (east, row 3 - the Guardian's lair)
K.EAST_X              = K.WORLD_W + K.GATE_T   -- left edge of the east column
K.VOLC_Y0             = K.FROZEN_Y1 + K.GATE_T -- top edge of the Volcanic Rift
K.VOLC_Y1             = K.VOLC_Y0 + K.WORLD_H
K.SPOOKY_Y0           = K.VOLC_Y1 + K.GATE_T   -- top edge of the Haunted Hollow
K.SPOOKY_Y1           = K.SPOOKY_Y0 + K.WORLD_H
K.TOTAL_H             = K.SPOOKY_Y1
K.TOTAL_W             = K.EAST_X + K.WORLD_W
K.EGATE_X             = K.EAST_X + K.WORLD_W / 2 - K.GATE_W / 2   -- gates of the east column
K.G2_Y                = K.FROZEN_Y0 + K.WORLD_H / 2 - K.GATE_W / 2  -- Frozen -> Swamp gate (in a vertical wall)
K.SWAMP_UNLOCK_KILLS  = 150
K.VOLC_UNLOCK_KILLS   = 200
K.SPOOKY_UNLOCK_KILLS = 250                    -- ...and the Blaze Gatekeeper's key
K.MAX_SPOOKY_BOXES    = 14

local REGIONS = {
    desert = { id = "desert", name = "THE DUSTBOWL FRONTIER", sub = "Bandits & Scouts roam these plains",
               x0 = 0, x1 = K.WORLD_W, y0 = 0, y1 = K.WORLD_H, weather = "rain", col = { 1, 0.82, 0.45 } },
    frozen = { id = "frozen", name = "THE FROZEN WASTES", sub = "Frozens & Snowman Soldiers guard the ice",
               x0 = 0, x1 = K.WORLD_W, y0 = K.FROZEN_Y0, y1 = K.FROZEN_Y1, weather = "blizzard", col = { 0.7, 0.9, 1 } },
    swamp = { id = "swamp", name = "THE MURKY SWAMP", sub = "Shroomers, Toads & Crocodiles lurk in the murk",
               x0 = K.EAST_X, x1 = K.TOTAL_W, y0 = K.FROZEN_Y0, y1 = K.FROZEN_Y1, col = { 0.5, 0.9, 0.4 } },
    volcanic = { id = "volcanic", name = "THE VOLCANIC RIFT", sub = "Magma Slimes, Lava Serpents & BlazeShrooms",
               x0 = K.EAST_X, x1 = K.TOTAL_W, y0 = K.VOLC_Y0, y1 = K.VOLC_Y1, weather = "ash", col = { 1, 0.5, 0.2 } },
    spooky = { id = "spooky", name = "THE HAUNTED HOLLOW", sub = "Gourds, Bats & Witches lurk in the dark",
               x0 = K.EAST_X, x1 = K.TOTAL_W, y0 = K.SPOOKY_Y0, y1 = K.SPOOKY_Y1, col = { 0.85, 0.55, 1 } },
}
local REGION_ORDER = { "desert", "frozen", "swamp", "volcanic", "spooky" }

-- the region at a position (positions in the walls between regions go to the closest one)
local function regionAt(x, y)
    if x > K.WORLD_W + K.GATE_T * 0.5 then
        if y > K.VOLC_Y1 + K.GATE_T * 0.5 then return "spooky" end
        if y > K.FROZEN_Y1 + K.GATE_T * 0.5 then return "volcanic" end
        return "swamp"
    end
    if y > K.WORLD_H + K.GATE_T * 0.5 then return "frozen" end
    return "desert"
end

-- the region whose rectangle contains the point (nil = outside the world / in a wall)
local function regionIn(x, y)
    for _, id in ipairs(REGION_ORDER) do
        local R = REGIONS[id]
        if x >= R.x0 and x < R.x1 and y >= R.y0 and y < R.y1 then return id end
    end
end

local WEATHER_INFO = {
    rain     = { name = "Rain",     vis = 0.10, desc = "-10% visibility" },
    blizzard = { name = "Blizzard", vis = 0.50, desc = "-50% visibility" },
    ash      = { name = "Ash storm", vis = 0.25, desc = "-25% visibility" },
}

-- Spells are cast by clicking them in the spellbook (B). Every spell has a cooldown.
local SPELLS = {
    { id = "turtle", short = "Turtle", name = "Turtle Master", cost = 40, source = "book", duration = 12, cooldown = 90,
      desc = "12s: -50% movement speed, but you take 50% less damage (2x resistance)." },
    { id = "icicles", short = "Icicles", name = "Cold Icicles", cost = 30, source = "book", duration = 15, cooldown = 90,
      desc = "15s: bullets become icicles. +5 initial DMG, -10% enemy speed, freeze: -1 HP every 2s for 10s." },
    { id = "snowgrave", short = "SnowGRAVE", name = "SnowGRAVE", cost = 90, source = "book", cooldown = 180,
      desc = "The ground shakes... after 3s a blizzard erupts: 150 DMG to every enemy within 450 px of you." },
    { id = "iceshock", short = "IceShock", name = "IceShock", cost = 50, source = "chest", cooldown = 135,
      desc = "Stuns every enemy within 320 px for 3s, then slows them by 40% for 5s." },
    { id = "cursed", short = "CURSED", name = "THE CURSED SPELL", cost = 100, hpCost = 50, cooldown = 300,
      source = "witch",
      desc = "Blinds you for 2s, then a VIOLENT blast of shattering glass: 200 DMG to every enemy within 1000 px." },
    { id = "blaze", short = "Blaze", name = "Blaze Spell", cost = 80, source = "gatekeeper", duration = 10, cooldown = 135,
      desc = "10s: your bullets become flames. No hit damage, but enemies BURN for 5 DMG/s for 8s (hitting again resets it)." },
}
local SPELL_BY_ID = {}
for _, s in ipairs(SPELLS) do SPELL_BY_ID[s.id] = s end

-- enemy and weapon data live in enemies.lua and weapons.lua
local ENEMY_NAMES  = require("enemies").names
local ENEMY_REGION = require("enemies").region
local WEAPONS      = require("weapons")

local SHOP = {
    { id = "shotgun", name = "Shotgun",         price = 300, once = true,
      desc = "45-62 DMG spread blast. Includes 12 Ammo. Equip it from the Inventory (P)." },
    { id = "boots",   name = "Feather Boots",   price = 200, once = true,
      desc = "+35% movement speed. Downside: you take 1.2% more damage while worn." },
    { id = "bandage", name = "Bandage",         price = 60,
      desc = "Heals 50 HP. Use it from the Inventory (P)." },
    { id = "ammo",    name = "Ammo Crate",      price = 70,
      desc = "+40 Ammo. Ammo is universal: it works in every single gun." },
    { id = "vest",    name = "Reinforced Vest", price = 350, once = true,
      desc = "+25 max HP permanently (also heals 25)." },
    { id = "book",    name = "Magic Book",      price = 500, once = true, needsMP = true,
      desc = "Unlocks Turtle Master, Cold Icicles & SnowGRAVE (cast them from the spellbook, B). Sold once you reach 100 MP." },
}

------------------------------------------------------------------------------
-- Global game state
------------------------------------------------------------------------------
local gameState = "menu"   -- menu | howto | mp | credits | loading | play | win | lose
local overlay   = nil      -- nil | pause | shop | inventory | guide | book | admin
local showUI    = true
local settings  = { volume = 0.8, music = true }

local fonts   = {}
local SFX     = {}
local buttons = {}

-- Admin / debug mode (code typed on the main menu, valid for the next game only)
local ADMIN_CODE = "4ddin6"
local admin = {
    input = "", pending = false, msg = nil, msgT = 0, msgCol = { 1, 1, 1 },
    on = false, hp = false, mp = false, stealth = false, kills = false, weather = "auto",
}

local player, enemies, bullets, walls, floors, boxes, particles, texts, decals, rings, messages, decor
local stats, cam
local spawnTimer, boxTimer, endTimer, endResult
local shake, hurtFlash, heartbeatTimer = 0, 0, 0
local lakes, frozenChest, regionUnlocked, frozenSpawnTimer = {}, nil, false, 0
local weather, snowgraves, banner = nil, {}, nil
local lightning, lightningTimer, thunderDelay, snowFlash = 0, 20, nil, 0
local rainDrops, snowFlakes = {}, {}
local rainLoop, blizzardLoop, fogImg
local world, musicSrc = { stash = { desert = {}, frozen = {}, spooky = {} }, spookyOpen = false }, nil
local menuTime, menuDust = 0, {}
local ambient
local save = { bestKills = 0, bestTime = 0, wins = 0, games = 0 }   -- replaced by the permanent profile on load

local rng = love.math.random      -- swapped for a seeded generator while the world is generated (same map for every player)
local me                          -- the local player (enemy AI temporarily points `player` at its current target)
local X = {}                      -- newer systems: multiplayer, credits, weapons, day/night, screens
X.BOSSES = { guardian = true, gatekeeper = true }
X.MAP_COLORS = { desert = { 0.55, 0.46, 0.32, 0.95 }, frozen = { 0.82, 0.87, 0.93 }, swamp = { 0.14, 0.3, 0.1 },
                 volcanic = { 0.3, 0.2, 0.18 }, spooky = { 0.28, 0.24, 0.3 } }
X.REGION_NICE = { desert = "Dustbowl Frontier", frozen = "The Frozen Wastes", swamp = "The Murky Swamp",
                  volcanic = "The Volcanic Rift", spooky = "The Haunted Hollow" }
function X.titleCase(s)
    return (s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
local WG = { size = 256, cells = {}, dcells = {}, stamp = 0, buf = {}, buf2 = {}, buf3 = {} }   -- spatial grids
local NET = require("net")
local PROF = require("profile")
local MPS = { online = false, role = "solo", id = 1, others = {}, name = "Player" }

X.EN = require("enemies")
X.ESTATS = X.EN.stats
X.UT = require("utility")      -- utilities (Credit Shop > UTILITY)
X.AR = require("armor")        -- armor (Credit Shop > ARMOR)
X.WEAPON_ORDER = WEAPONS.ORDER
-- weapons sold for credits, by shop section; crates only ever pull NORMAL and FICTIONAL ones
X.SHOP_NORMAL, X.SHOP_FICTION, X.SHOP_FAME, X.CREDIT_WEAPONS, X.CRATE_POOL = {}, {}, {}, {}, {}
for _, id in ipairs(WEAPONS.ORDER) do
    local w = WEAPONS[id]
    if w.shop then
        X.CREDIT_WEAPONS[#X.CREDIT_WEAPONS + 1] = id
        if w.shop == "normal" then X.SHOP_NORMAL[#X.SHOP_NORMAL + 1] = id end
        if w.shop == "fictional" then X.SHOP_FICTION[#X.SHOP_FICTION + 1] = id end
        if w.shop == "fame" then X.SHOP_FAME[#X.SHOP_FAME + 1] = id end
        if w.shop ~= "fame" and w.chance then X.CRATE_POOL[#X.CRATE_POOL + 1] = id end
    end
end

-- Difficulty levels. EASY is the original balance.
--   dmg/hp = enemy damage & health   count = enemy numbers   react = how fast enemies notice / shoot
--   gold = gold per kill             credits = credits per 10 kills (0 = practice mode)
X.DIFFS = {
    { id = "easy",      name = "EASY",      dmg = 1.0,  hp = 1.0,  count = 1.0, react = 1.0, gold = 0.75, credits = 0,
      col = { 0.45, 0.9, 0.5 },  desc = "The classic Frontier. Practice mode: no credits.", bossSpeed = 1, faceWaves = 5, gkSpit = 3, gkSwirl = 10 },
    { id = "normal",    name = "NORMAL",    dmg = 1.25, hp = 1.15, count = 1.35, react = 1.15, gold = 1.0, credits = 1,
      bossSpeed = 1.5, faceWaves = 7, gkSpit = 5, gkSwirl = 15,
      col = { 1, 0.85, 0.4 },    desc = "Tougher enemies, more of them. 1 credit every 10 kills." },
    { id = "hard",      name = "HARD",      dmg = 1.5,  hp = 1.3,  count = 1.6, react = 1.3, gold = 1.15, credits = 1,
      bossSpeed = 2, faceWaves = 9, gkSpit = 6, gkSwirl = 20,
      col = { 1, 0.55, 0.25 },   desc = "Dangerous. +15% gold. 1 credit every 10 kills." },
    { id = "nightmare", name = "NIGHTMARE", dmg = 1.85, hp = 1.5,  count = 1.9, react = 1.5, gold = 1.3, credits = 2,
      bossSpeed = 2.5, faceWaves = 11, gkSpit = 8, gkSwirl = 25,
      col = { 0.95, 0.2, 0.25 }, desc = "Brutal. +30% gold. 2 credits every 10 kills." },
}
X.DIFF_BY_ID = {}
for _, d in ipairs(X.DIFFS) do X.DIFF_BY_ID[d.id] = d end
X.D = X.DIFF_BY_ID.easy      -- the difficulty of the current game

------------------------------------------------------------------------------
-- Utility
------------------------------------------------------------------------------
local function rand() return rng() end
local function randRange(a, b) return a + (b - a) * rng() end
local function randInt(a, b) return rng(a, b) end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function lerp(a, b, t) return a + (b - a) * t end
local function dist(x1, y1, x2, y2) local dx, dy = x2 - x1, y2 - y1 return sqrt(dx * dx + dy * dy) end
local function angleDiff(a, b) return (b - a + pi) % (2 * pi) - pi end
local function hash(x, y) local n = sin(x * 12.9898 + y * 78.233) * 43758.5453 return n - floor(n) end

local function turnTowards(a, target, step)
    local d = angleDiff(a, target)
    if abs(d) <= step then return target end
    return a + (d > 0 and step or -step)
end

local function rectOverlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

local function formatTime(s)
    s = floor(s or 0)
    return string.format("%02d:%02d", floor(s / 60), s % 60)
end

-- Liang-Barsky segment vs. axis-aligned rectangle. Returns hit, entry t (0..1)
local function segRect(x1, y1, x2, y2, r)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1 = 0, 1
    local function clip(p, q)
        if p == 0 then return q >= 0 end
        local t = q / p
        if p < 0 then
            if t > t1 then return false end
            if t > t0 then t0 = t end
        else
            if t < t0 then return false end
            if t < t1 then t1 = t end
        end
        return true
    end
    if clip(-dx, x1 - r.x) and clip(dx, r.x + r.w - x1)
       and clip(-dy, y1 - r.y) and clip(dy, r.y + r.h - y1) then
        return true, t0
    end
    return false
end

-- Segment vs circle. Returns t of closest approach if within radius
local function segCircle(x1, y1, x2, y2, cx, cy, r)
    local dx, dy = x2 - x1, y2 - y1
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then t = clamp(((cx - x1) * dx + (cy - y1) * dy) / len2, 0, 1) end
    local px, py = x1 + dx * t, y1 + dy * t
    if (px - cx) ^ 2 + (py - cy) ^ 2 <= r * r then return t end
    return nil
end

------------------------------------------------------------------------------
-- Spatial grid: walls are bucketed into 256 px cells so collision, line of
-- sight and drawing only look at nearby walls (the map has thousands of them).
------------------------------------------------------------------------------
function WG.add(w)
    local S = WG.size
    for cy = floor(w.y / S), floor((w.y + w.h) / S) do
        for cx = floor(w.x / S), floor((w.x + w.w) / S) do
            local k = cy * 4096 + cx
            local c = WG.cells[k]
            if not c then c = {} WG.cells[k] = c end
            c[#c + 1] = w
        end
    end
end

-- Walls in the grid cells touching a rectangle -> reused buffer, count
function WG.query(x, y, w, h, buf)
    local S = WG.size
    WG.stamp = WG.stamp + 1
    local st, n = WG.stamp, 0
    buf = buf or WG.buf
    for cy = floor(y / S), floor((y + h) / S) do
        for cx = floor(x / S), floor((x + w) / S) do
            local c = WG.cells[cy * 4096 + cx]
            if c then
                for i = 1, #c do
                    local wl = c[i]
                    if wl.stamp ~= st and not wl.off then
                        wl.stamp = st
                        n = n + 1
                        buf[n] = wl
                    end
                end
            end
        end
    end
    return buf, n
end

-- Decoration is bucketed into 512 px cells
function WG.addDecor(d)
    local k = floor(d.y / 512) * 4096 + floor(d.x / 512)
    local c = WG.dcells[k]
    if not c then c = {} WG.dcells[k] = c end
    c[#c + 1] = d
end

local function hasLOS(x1, y1, x2, y2)
    local buf, n = WG.query(min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1), WG.buf2)
    for i = 1, n do
        local w = buf[i]
        if not w.enemyOnly and segRect(x1, y1, x2, y2, w) then return false end
    end
    return true
end

local function isOnLake(x, y)
    if y < K.FROZEN_Y0 then return false end
    for i = 1, #lakes do
        local l = lakes[i]
        local dx, dy = (x - l.x) / l.rx, (y - l.y) / l.ry
        if dx * dx + dy * dy <= 1 then return true end
    end
    return false
end

-- Visibility multiplier for a region (1 = clear, lower during rain / blizzard)
local function weatherVis(region)
    local w = weather and weather[region or "desert"]
    if not w or w.intensity <= 0 then return 1 end
    return 1 - WEATHER_INFO[REGIONS[region or "desert"].weather].vis * w.intensity
end

------------------------------------------------------------------------------
-- Sound synthesis
------------------------------------------------------------------------------
local buildSounds
do
local RATE = 44100

local function genSound(name, dur, vol, fn)
    local n = floor(dur * RATE)
    local sd = love.sound.newSoundData(n, RATE, 16, 1)
    for i = 0, n - 1 do
        sd:setSample(i, clamp(fn(i / RATE, i / n), -1, 1))
    end
    SFX[name] = { src = love.audio.newSource(sd, "static"), vol = vol, data = sd }
end

local function tone(f, t) return sin(2 * pi * f * t) end
local function sqr(f, t) return sin(2 * pi * f * t) >= 0 and 1 or -1 end
local function noise() return love.math.random() * 2 - 1 end

-- Low-pass filtered noise generator factory
local function lpNoise()
    local s = 0
    return function(k) s = s + (noise() - s) * k return s end
end

-- Phase-accumulating oscillator (for smooth pitch sweeps)
local function osc()
    local ph = 0
    return function(f) ph = ph + 2 * pi * f / RATE return sin(ph) end
end

function buildSounds()
    local n, o

    genSound("pistol", 0.22, 0.55, function(t)
        return noise() * exp(-t * 38) * 0.7 + tone(140 - 180 * t, t) * exp(-t * 22) * 0.6
    end)

    n = lpNoise()
    genSound("shotgun", 0.5, 0.75, function(t)
        return n(0.45) * exp(-t * 8) * 1.3 + tone(62, t) * exp(-t * 9) * 0.8 + noise() * exp(-t * 60) * 0.5
    end)

    n = lpNoise()
    genSound("enemy_shot", 0.24, 0.5, function(t)
        return n(0.35) * exp(-t * 28) * 1.1 + tone(105, t) * exp(-t * 20) * 0.5
    end)

    genSound("hit", 0.09, 0.4, function(t)
        return sqr(520, t) * exp(-t * 40) * 0.35 + noise() * exp(-t * 70) * 0.35
    end)

    n = lpNoise()
    genSound("hurt", 0.32, 0.6, function(t)
        return (tone(170, t) + 0.5 * sqr(85, t)) * exp(-t * 11) * 0.45 + n(0.3) * exp(-t * 25) * 0.6
    end)

    n = lpNoise()
    genSound("dash", 0.28, 0.5, function(t, p)
        return n(0.06 + 0.35 * p) * sin(pi * p) * 2.2
    end)

    genSound("block", 0.5, 0.5, function(t)
        return (tone(820, t) + 0.7 * tone(1310, t) + 0.5 * tone(1975, t)) * exp(-t * 12) * 0.32
             + noise() * exp(-t * 80) * 0.4
    end)

    genSound("pickup", 0.24, 0.45, function(t, p)
        local f = p < 0.45 and 660 or 990
        return tone(f, t) * 0.5 * exp(-(p < 0.45 and t or t - 0.11) * 14)
    end)

    o = osc()
    genSound("heal", 0.5, 0.45, function(t, p)
        return o(380 + 520 * p) * sin(pi * p) * 0.5 + tone(1200 + 400 * p, t) * sin(pi * p) * 0.08
    end)

    genSound("click", 0.05, 0.35, function(t) return tone(1250, t) * exp(-t * 90) * 0.5 end)

    genSound("buy", 0.3, 0.45, function(t, p)
        local f = p < 0.35 and 988 or 1319
        return (tone(f, t) * 0.6 + sqr(f, t) * 0.12) * exp(-(p < 0.35 and t or t - 0.1) * 10)
    end)

    genSound("deny", 0.22, 0.35, function(t, p) return sqr(110, t) * 0.35 * (1 - p) end)

    genSound("alert", 0.7, 0.55, function(t, p)
        local seg = floor(t / 0.12)
        local f = (seg % 2 == 0) and 880 or 660
        local local_t = t - seg * 0.12
        return (sqr(f, t) * 0.25 + tone(f, t) * 0.3) * min(1, local_t * 60) * exp(-local_t * 6) * (1 - p * 0.5)
    end)

    genSound("spot", 0.22, 0.4, function(t, p)
        local f = p < 0.5 and 520 or 780
        return sqr(f, t) * 0.25 * exp(-((p < 0.5) and t or t - 0.11) * 18)
    end)

    o = osc(); n = lpNoise()
    genSound("enemy_die", 0.55, 0.55, function(t, p)
        return o(320 - 260 * p) * exp(-t * 6) * 0.5 + n(0.25) * exp(-t * 9) * 0.8
    end)

    genSound("empty", 0.07, 0.45, function(t)
        return noise() * exp(-t * 120) * 0.5 + tone(2400, t) * exp(-t * 100) * 0.3
    end)

    n = lpNoise()
    genSound("crate", 0.3, 0.55, function(t)
        return n(0.6) * exp(-t * 22) * 1.2 + tone(210, t) * exp(-t * 28) * 0.4
            + (t > 0.06 and n(0.5) * exp(-(t - 0.06) * 30) * 0.6 or 0)
    end)

    genSound("equip", 0.18, 0.45, function(t)
        return tone(300, t) * exp(-t * 30) * 0.4 + noise() * exp(-t * 50) * 0.3
            + (t > 0.08 and tone(450, t) * exp(-(t - 0.08) * 40) * 0.35 or 0)
    end)

    genSound("heartbeat", 0.5, 0.6, function(t)
        local a = tone(55, t) * exp(-t * 22)
        local b = t > 0.17 and tone(48, t) * exp(-(t - 0.17) * 22) * 0.8 or 0
        return (a + b) * 0.9
    end)

    genSound("win", 1.0, 0.5, function(t)
        local notes = { 523, 659, 784, 1047 }
        local i = min(4, floor(t / 0.18) + 1)
        local lt = t - (i - 1) * 0.18
        return (tone(notes[i], t) * 0.5 + tone(notes[i] * 2, t) * 0.1) * exp(-lt * (i == 4 and 3 or 8))
    end)

    genSound("lose", 1.0, 0.5, function(t)
        local notes = { 392, 330, 262, 196 }
        local i = min(4, floor(t / 0.22) + 1)
        local lt = t - (i - 1) * 0.22
        return (tone(notes[i], t) * 0.45 + sqr(notes[i] / 2, t) * 0.08) * exp(-lt * (i == 4 and 2.5 or 6))
    end)

    ------------------------------------------------------------------
    -- Mana, magic & the Frozen Wastes
    ------------------------------------------------------------------
    genSound("mana", 0.3, 0.3, function(t)
        return (tone(1320, t) * 0.4 + tone(1980, t) * 0.25 + tone(2640, t) * 0.12) * exp(-t * 12)
    end)

    o = osc(); n = lpNoise()
    genSound("cast", 0.55, 0.45, function(t, p)
        return o(260 + 1100 * p) * sin(pi * p) * 0.4 + n(0.9) * sin(pi * p) * 0.12
            + tone(2200 + 800 * p, t) * exp(-t * 6) * 0.08
    end)

    genSound("turtle", 0.7, 0.5, function(t, p)
        return tone(110, t) * exp(-t * 4) * 0.5 + tone(220, t) * sin(pi * p) * 0.25 + tone(165, t) * exp(-t * 18) * 0.4
    end)

    genSound("icicle_cast", 0.8, 0.45, function(t)
        local s = 0
        local notes = { 2093, 2637, 3136, 4186 }
        for i, f in ipairs(notes) do
            local st = (i - 1) * 0.08
            if t > st then s = s + tone(f, t) * exp(-(t - st) * 7) * 0.22 end
        end
        return s
    end)

    genSound("icicle_shot", 0.14, 0.3, function(t)
        return tone(2600 - 4000 * t, t) * exp(-t * 30) * 0.4 + noise() * exp(-t * 80) * 0.2
    end)

    genSound("freeze", 0.35, 0.4, function(t, p)
        local crackle = (rand() < 0.08 and noise() or 0) * (1 - p)
        return crackle * 0.9 + tone(1500, t) * exp(-t * 14) * 0.25 + tone(2250, t) * exp(-t * 20) * 0.15
    end)

    genSound("frost_tick", 0.08, 0.2, function(t) return (tone(1900, t) + noise() * 0.5) * exp(-t * 60) * 0.4 end)

    n = lpNoise()
    genSound("rumble", 3.1, 0.75, function(t, p)
        local a = min(1, t * 1.2) * (0.6 + 0.4 * p)
        return n(0.015 + 0.03 * p) * 4 * a + tone(38 + 10 * p, t) * a * 0.45 + (rand() < 0.002 * p and noise() * 0.6 or 0)
    end)

    n = lpNoise()
    genSound("snowgrave", 1.8, 0.8, function(t, p)
        return n(0.5 - 0.45 * p) * exp(-t * 2) * 1.6 + tone(55, t) * exp(-t * 3) * 0.7 + tone(1760, t) * exp(-t * 4) * 0.08
    end)

    o = osc()
    genSound("iceshock", 0.7, 0.5, function(t, p)
        return o(3000 - 2600 * p) * exp(-t * 4) * 0.3 + sqr(70, t) * exp(-t * 6) * 0.25
            + (rand() < 0.3 and noise() or 0) * exp(-t * 8) * 0.4
    end)

    o = osc()
    genSound("frozen_shot", 0.2, 0.4, function(t, p)
        return o(1900 - 1000 * p) * exp(-t * 18) * 0.35 + noise() * exp(-t * 50) * 0.25
    end)

    n = lpNoise()
    genSound("snowball_throw", 0.22, 0.35, function(t, p) return n(0.15) * sin(pi * p) * 1.6 end)

    n = lpNoise()
    genSound("snowball_hit", 0.25, 0.5, function(t)
        return n(0.25) * exp(-t * 22) * 1.4 + tone(85, t) * exp(-t * 25) * 0.6
    end)

    n = lpNoise()
    genSound("branch", 0.32, 0.45, function(t, p)
        local whoosh = n(0.12 + 0.3 * p) * sin(pi * min(1, p * 1.6)) * 1.3
        local crack = t > 0.2 and (noise() * exp(-(t - 0.2) * 60) * 0.7 + tone(140, t) * exp(-(t - 0.2) * 30) * 0.5) or 0
        return whoosh + crack
    end)

    n = lpNoise()
    genSound("yeti_growl", 0.5, 0.45, function(t, p)
        return (sqr(72 + 20 * sin(t * 30), t) * 0.25 + n(0.2) * 0.8) * sin(pi * p)
    end)

    genSound("snowman_spot", 0.3, 0.35, function(t, p)
        local f = p < 0.5 and 196 or 262
        return (tone(f, t) * 0.5 + tone(f * 2, t) * 0.1) * exp(-((p < 0.5) and t or t - 0.15) * 12)
    end)

    n = lpNoise()
    genSound("gate_open", 1.8, 0.6, function(t)
        local notes = { 392, 523, 659, 784 }
        local i = min(4, floor(t / 0.3) + 1)
        local lt = t - (i - 1) * 0.3
        return n(0.03) * 3 * exp(-t * 1.5) * 0.6 + tone(notes[i], t) * exp(-lt * (i == 4 and 2 or 6)) * 0.35
    end)

    genSound("chest_open", 1.4, 0.55, function(t)
        local notes = { 523, 784, 1047, 1319, 1568, 2093 }
        local s = 0
        for i, f in ipairs(notes) do
            local st = (i - 1) * 0.1
            if t > st then s = s + tone(f, t) * exp(-(t - st) * 4) * 0.14 end
        end
        return s + tone(3000 + 600 * sin(t * 40), t) * exp(-t * 3) * 0.04
    end)

    o = osc()
    genSound("region", 1.4, 0.45, function(t, p)
        return (tone(220, t) * 0.4 + tone(330, t) * 0.3 + tone(440, t) * 0.15 + o(110) * 0.2) * sin(pi * p)
    end)

    n = lpNoise()
    genSound("thunder", 3.0, 0.7, function(t, p)
        local crack = noise() * exp(-t * 18) * 0.8
        local roll = n(0.01 + 0.03 * (1 - p)) * 4 * exp(-t * 1.1) * (0.7 + 0.3 * sin(t * 9))
        return crack + roll
    end)

    o = osc()
    genSound("chill", 0.4, 0.4, function(t, p)
        return o(900 - 300 * p) * (0.6 + 0.4 * sin(t * 70)) * exp(-t * 6) * 0.35
    end)

    genSound("lock", 0.25, 0.35, function(t) return (sqr(180, t) * 0.2 + noise() * 0.3) * exp(-t * 25) end)

    n = lpNoise()
    genSound("shatter", 0.25, 0.4, function(t)
        return (noise() * 0.6 + tone(3200, t) * 0.3 + tone(4100, t) * 0.2) * exp(-t * 22)
    end)

    ------------------------------------------------------------------
    -- New weapons
    ------------------------------------------------------------------
    genSound("revolver", 0.35, 0.6, function(t)
        return noise() * exp(-t * 45) * 0.75 + tone(110 - 60 * t, t) * exp(-t * 14) * 0.6
            + tone(2300, t) * exp(-t * 18) * 0.06 + tone(3100, t) * exp(-t * 22) * 0.04
    end)

    genSound("swifter", 0.14, 0.45, function(t)
        return noise() * exp(-t * 70) * 0.6 + tone(420 - 900 * t, t) * exp(-t * 40) * 0.45
    end)

    n = lpNoise()
    genSound("spray", 0.09, 0.28, function(t)
        return n(0.7) * exp(-t * 55) * 0.9 + tone(900, t) * exp(-t * 80) * 0.15
    end)

    n = lpNoise()
    genSound("rifle", 0.2, 0.5, function(t)
        return noise() * exp(-t * 55) * 0.7 + n(0.3) * exp(-t * 25) * 0.6 + tone(95, t) * exp(-t * 30) * 0.55
    end)

    n = lpNoise()
    o = osc()
    genSound("rpg_fire", 0.8, 0.7, function(t, p)
        local thump = tone(55, t) * exp(-t * 14) * 0.8
        local whoosh = n(0.08 + 0.25 * (1 - p)) * min(1, t * 20) * exp(-t * 2.2) * 1.8
        return thump + whoosh + o(900 - 600 * p) * exp(-t * 6) * 0.08
    end)

    n = lpNoise()
    local n2 = lpNoise()
    genSound("explosion", 1.6, 0.85, function(t)
        return noise() * exp(-t * 14) * 0.9 + n(0.18) * exp(-t * 3) * 1.6 + n2(0.03) * exp(-t * 1.6) * 2.4
            + tone(42, t) * exp(-t * 3.5) * 0.9
    end)

    o = osc()
    genSound("laser", 0.4, 0.5, function(t, p)
        return (o(2400 - 2100 * p) * 0.45 + sqr(180 - 120 * p, t) * 0.12) * exp(-t * 7)
            + noise() * exp(-t * 60) * 0.25
    end)

    ------------------------------------------------------------------
    -- Weapons overhaul
    ------------------------------------------------------------------
    genSound("uzi", 0.09, 0.32, function(t)
        return noise() * exp(-t * 90) * 0.7 + tone(180, t) * exp(-t * 60) * 0.4
    end)

    n = lpNoise()
    genSound("bow", 0.32, 0.45, function(t, p)
        local twang = tone(196 + 40 * exp(-t * 30), t) * exp(-t * 16) * 0.5
        return twang + n(0.25) * exp(-t * 20) * 0.5 + tone(392, t) * exp(-t * 25) * 0.15
    end)

    n = lpNoise()
    genSound("flame", 0.16, 0.22, function(t, p)
        return n(0.15) * sin(pi * p) * 1.6 + noise() * sin(pi * p) * 0.15
    end)

    n = lpNoise()
    genSound("sniper", 0.9, 0.7, function(t)
        return noise() * exp(-t * 40) * 0.9 + n(0.12) * exp(-t * 4) * 1.4 + tone(70, t) * exp(-t * 9) * 0.7
            + tone(2600, t) * exp(-t * 30) * 0.05
    end)

    o = osc()
    genSound("minigun", 0.5, 0.35, function(t, p)
        return o(90 + 260 * p) * 0.45 * sin(pi * p) + sqr(45 + 120 * p, t) * 0.08 * sin(pi * p)
    end)

    o = osc()
    genSound("bubble", 0.18, 0.35, function(t, p)
        return o(300 + 900 * p) * exp(-t * 14) * 0.55
    end)

    n = lpNoise()
    genSound("boomerang", 0.45, 0.4, function(t, p)
        return n(0.3) * (0.5 + 0.5 * sin(t * 2 * pi * 14)) * sin(pi * p) * 1.4
    end)

    n = lpNoise()
    genSound("hammer", 0.6, 0.75, function(t)
        return tone(48, t) * exp(-t * 6) * 1.0 + n(0.2) * exp(-t * 10) * 1.2 + noise() * exp(-t * 50) * 0.4
    end)

    o = osc()
    genSound("void", 0.35, 0.45, function(t, p)
        return o(700 - 600 * p) * exp(-t * 8) * 0.45 + sqr(55, t) * exp(-t * 10) * 0.12
    end)

    o = osc()
    genSound("plasma", 0.28, 0.45, function(t, p)
        return o(1500 - 1200 * p) * exp(-t * 10) * 0.4 + noise() * exp(-t * 40) * 0.25 + tone(220, t) * exp(-t * 20) * 0.25
    end)

    genSound("tesla", 0.4, 0.4, function(t, p)
        local crack = (love.math.random() < 0.3 and noise() or 0) * exp(-t * 6)
        return crack * 0.8 + sqr(60, t) * exp(-t * 8) * 0.15 + tone(1800 + 600 * sin(t * 90), t) * exp(-t * 12) * 0.12
    end)

    o = osc(); n = lpNoise()
    genSound("blackhole", 1.4, 0.55, function(t, p)
        return o(40 + 70 * (1 - p)) * sin(pi * p) * 0.7 + n(0.05) * sin(pi * p) * 1.6
    end)

    o = osc(); n = lpNoise()
    genSound("meteor", 1.0, 0.5, function(t, p)
        return o(1200 - 1000 * p) * 0.2 * min(1, t * 6) + n(0.1 + 0.3 * p) * p * 1.6
    end)

    genSound("freeze_gun", 0.14, 0.3, function(t, p)
        return (tone(2200 - 800 * p, t) * 0.25 + noise() * 0.35) * exp(-t * 22)
    end)

    n = lpNoise()
    genSound("cannon", 1.1, 0.8, function(t)
        return tone(38, t) * exp(-t * 5) * 1.1 + n(0.12) * exp(-t * 6) * 1.8 + noise() * exp(-t * 35) * 0.7
    end)

    ------------------------------------------------------------------
    -- The Guardian of the Hollow
    ------------------------------------------------------------------
    -- a deep "HA-HA-HA-HA-HA" with an echo (vowel "a": formants ~700 / 1150 Hz)
    do
        local dur, sr = 2.3, RATE
        local nS = floor(dur * sr)
        local dry = {}
        local syl, gap = 0.17, 0.07
        for i = 0, nS - 1 do
            local t = i / sr
            local k = floor(t / (syl + gap))
            local lt = t - k * (syl + gap)
            local v = 0
            if k < 5 and lt < syl then
                local f0 = 150 - k * 12 - lt * 60
                local env = min(1, lt / 0.02) * (1 - lt / syl) ^ 0.6
                for hm = 1, 14 do
                    local F = f0 * hm
                    local a = math.exp(-((F - 700) / 260) ^ 2) + 0.6 * math.exp(-((F - 1150) / 320) ^ 2) + 0.25 / hm
                    v = v + sin(2 * pi * F * t) * a
                end
                v = v * env * 0.28 + noise() * env * 0.05
            end
            dry[i] = v
        end
        local d1, d2 = floor(0.19 * sr), floor(0.38 * sr)
        genSound("boss_laugh", dur, 0.75, function(t)
            local i = floor(t * sr)
            return (dry[i] or 0) + (dry[i - d1] or 0) * 0.45 + (dry[i - d2] or 0) * 0.2
        end)
    end

    n = lpNoise()
    genSound("boss_shake", 1.0, 0.6, function(t, p)
        return n(0.04) * (0.6 + 0.4 * sin(t * 2 * pi * 13)) * 2.6 + tone(38, t) * 0.35 * sin(pi * p)
    end)

    n = lpNoise()
    genSound("boss_jump", 0.7, 0.6, function(t, p)
        return n(0.05 + 0.35 * p) * sin(pi * p) * 2.2 + tone(60 + 60 * p, t) * 0.2 * (1 - p)
    end)

    n = lpNoise()
    local n3 = lpNoise()
    genSound("boss_land", 1.8, 0.95, function(t)
        return tone(32, t) * exp(-t * 3) * 1.1 + tone(48, t) * exp(-t * 5) * 0.6 + n(0.1) * exp(-t * 4) * 2.2
            + n3(0.02) * exp(-t * 1.5) * 2.5 + noise() * exp(-t * 30) * 0.5
    end)

    n = lpNoise()
    genSound("hat_throw", 0.7, 0.5, function(t, p)
        return n(0.3) * (0.5 + 0.5 * sin(t * 2 * pi * 11)) * sin(pi * p) * 1.6
    end)

    o = osc()
    local o2, o3 = osc(), osc()
    genSound("necro", 1.7, 0.5, function(t, p)
        local f = 220 + 160 * p
        local env = min(1, t / 0.3) * (1 - p) ^ 0.5
        return (o(f) + o2(f * 1.19) * 0.7 + o3(f * 1.5 * 1.003) * 0.6) * env * 0.25
            + noise() * env * 0.04 * (0.5 + 0.5 * sin(t * 40))
    end)

    n = lpNoise()
    genSound("gate_slam", 1.8, 0.9, function(t)
        local clang = (tone(210, t) + tone(523, t) * 0.7 + tone(831, t) * 0.5 + tone(1270, t) * 0.35) * exp(-t * 3.2) * 0.3
        return clang + tone(45, t) * exp(-t * 4) * 0.8 + n(0.08) * exp(-t * 2.5) * 1.6 + noise() * exp(-t * 40) * 0.5
    end)

    o = osc()
    genSound("face_shot", 0.35, 0.3, function(t, p)
        return o(620 - 300 * p + 30 * sin(t * 60)) * sin(pi * p) * 0.5
    end)

    o = osc()
    n = lpNoise()
    genSound("boss_die", 3.0, 0.85, function(t, p)
        local f = 130 - 95 * p
        local v = 0
        for hm = 1, 8 do v = v + sin(2 * pi * f * hm * t) * (0.6 / hm) end
        return v * (1 - p) * 0.35 + n(0.06) * (1 - p) * 1.8 + o(40) * exp(-t * 0.8) * 0.4
    end)


    ------------------------------------------------------------------
    -- Swamp, Volcanic Rift, Blaze Gatekeeper, levels, waves, events
    ------------------------------------------------------------------
    o = osc()
    genSound("mushroom_throw", 0.25, 0.35, function(t, p)
        return o(500 + 400 * p) * sin(pi * p) * 0.4 + noise() * exp(-t * 30) * 0.2
    end)
    n = lpNoise()
    genSound("mushroom_pop", 0.3, 0.45, function(t)
        return n(0.4) * exp(-t * 18) * 1.4 + tone(240, t) * exp(-t * 25) * 0.4
    end)
    n = lpNoise()
    genSound("toad_spit", 0.3, 0.4, function(t, p)
        return n(0.5) * exp(-t * 12) * 1.2 + tone(180 - 120 * p, t) * exp(-t * 15) * 0.3
    end)
    o = osc()
    genSound("toad_tongue", 0.25, 0.45, function(t, p)
        return o(900 - 700 * p) * exp(-t * 10) * 0.4 + noise() * exp(-t * 50) * 0.3
    end)
    genSound("toad_croak", 0.5, 0.5, function(t, p)
        local f = 90 + 20 * sin(t * 2 * pi * 4)
        local pulse = (sin(t * 2 * pi * 22) > 0) and 1 or 0.3
        return (sqr(f, t) * 0.25 + tone(f * 2, t) * 0.25) * pulse * sin(pi * p)
    end)
    n = lpNoise()
    genSound("croc_snap", 0.35, 0.65, function(t)
        return noise() * exp(-t * 60) * 0.9 + tone(70, t) * exp(-t * 14) * 0.7 + n(0.3) * exp(-t * 16) * 0.8
    end)
    o = osc()
    genSound("slime_hop", 0.22, 0.35, function(t, p)
        return o(160 + 260 * p) * sin(pi * p) * 0.5
    end)
    n = lpNoise()
    genSound("serpent_dash", 0.45, 0.45, function(t, p)
        return n(0.1 + 0.4 * p) * sin(pi * p) * 1.6 + tone(300 + 500 * p, t) * sin(pi * p) * 0.1
    end)
    n = lpNoise()
    genSound("flame_spit", 0.35, 0.45, function(t, p)
        return n(0.25) * sin(pi * min(1, p * 2)) * exp(-t * 4) * 1.6 + tone(110, t) * exp(-t * 12) * 0.3
    end)
    n = lpNoise()
    genSound("gk_rod", 0.5, 0.7, function(t, p)
        return n(0.2 + 0.4 * (1 - p)) * sin(pi * p) * 1.2 + (tone(330, t) + tone(497, t) * 0.6) * exp(-t * 7) * 0.25
    end)
    o = osc()
    n = lpNoise()
    genSound("gk_swirl", 2.0, 0.6, function(t, p)
        return o(80 + 260 * p) * 0.3 * min(1, t * 3) + n(0.1 + 0.3 * p) * (0.4 + 0.6 * sin(t * 2 * pi * (3 + 10 * p))) * 1.2
    end)
    genSound("key_pickup", 0.9, 0.55, function(t)
        local notes = { 784, 988, 1175, 1568 }
        local i = min(4, floor(t / 0.12) + 1)
        local lt = t - (i - 1) * 0.12
        return (tone(notes[i], t) * 0.4 + tone(notes[i] * 2, t) * 0.12) * exp(-lt * (i == 4 and 3 or 9))
    end)
    o = osc()
    genSound("blaze_cast", 0.7, 0.5, function(t, p)
        return o(200 + 500 * p) * sin(pi * p) * 0.3 + noise() * sin(pi * p) * 0.3
    end)
    genSound("levelup", 1.0, 0.55, function(t)
        local notes = { 523, 659, 784, 1047, 1319 }
        local i = min(5, floor(t / 0.1) + 1)
        local lt = t - (i - 1) * 0.1
        return (tone(notes[i], t) * 0.4 + sqr(notes[i], t) * 0.06) * exp(-lt * (i == 5 and 2.5 or 8))
    end)
    genSound("wave_horn", 2.2, 0.6, function(t, p)
        local env = min(1, t / 0.3) * min(1, (2.2 - t) / 0.6)
        return (sqr(110, t) * 0.15 + tone(110, t) * 0.4 + tone(165, t) * 0.25 + tone(220, t) * 0.12) * env
    end)
    o = osc()
    genSound("revive", 1.0, 0.5, function(t, p)
        return o(300 + 900 * p) * sin(pi * p) * 0.35 + tone(1500, t) * exp(-t * 4) * 0.08
    end)
    genSound("merchant_bell", 1.2, 0.45, function(t)
        local a = tone(1319, t) * exp(-t * 3) * 0.35
        local b = t > 0.25 and tone(1047, t) * exp(-(t - 0.25) * 3) * 0.35 or 0
        return a + b
    end)
    o = osc()
    genSound("goblin_giggle", 0.8, 0.45, function(t, p)
        local seg = floor(t / 0.1)
        local lt = t - seg * 0.1
        return o(900 + 300 * (seg % 2) - 400 * p) * exp(-lt * 18) * 0.45
    end)
    genSound("achievement", 1.1, 0.5, function(t)
        local notes = { 659, 880, 1319 }
        local i = min(3, floor(t / 0.13) + 1)
        local lt = t - (i - 1) * 0.13
        return (tone(notes[i], t) * 0.35 + tone(notes[i] * 1.5, t) * 0.12) * exp(-lt * (i == 3 and 2.2 or 7))
    end)

    -- Boss music: 140 BPM in D minor - kick, snare, a driving bass and an organ
    do
        local MR = 22050
        local beat = 60 / 140
        local bars = 8
        local mdur = beat * 4 * bars
        local cnt = floor(mdur * MR)
        local bsd = love.sound.newSoundData(cnt, MR, 16, 1)
        local function mtof(m) return 440 * 2 ^ ((m - 69) / 12) end
        local prog = { 50, 50, 46, 45, 50, 50, 48, 49 }        -- D D Bb A D D C C#
        local bassPat = { 0, 0, 12, 0, 7, 0, 10, 12 }
        local nz = 0
        for i = 0, cnt - 1 do
            local t = i / MR
            local barI = floor(t / (beat * 4)) % bars + 1
            local root = prog[barI]
            local bt = t % beat
            local e8 = floor(t / (beat / 2))
            local et = t % (beat / 2)
            local beatN = floor(t / beat) % 4
            local kick = sin(2 * pi * (55 + 90 * exp(-bt * 30)) * bt) * exp(-bt * 9) * 0.55
            nz = nz + ((love.math.random() * 2 - 1) - nz) * 0.5
            local snare = (beatN == 1 or beatN == 3) and nz * exp(-bt * 16) * 0.35 or 0
            local hat = love.math.random() * 2 - 1
            hat = hat * exp(-et * 60) * 0.05
            local bf = mtof(root - 24 + bassPat[e8 % 8 + 1])
            local bass = (sin(2 * pi * bf * t) + 0.4 * sin(4 * pi * bf * t)) * exp(-et * 5) * 0.2
            local minor3 = (root == 46 or root == 48) and 4 or 3
            local organ = 0
            for _, iv in ipairs({ 0, minor3, 7, 12 }) do
                local f = mtof(root + iv)
                organ = organ + (sin(2 * pi * f * t) + 0.3 * sin(4 * pi * f * t) + 0.15 * sin(6 * pi * f * t))
            end
            organ = organ * 0.035 * (0.75 + 0.25 * sin(t * 2 * pi * 5))
            bsd:setSample(i, clamp(kick + snare + hat + bass + organ, -1, 1))
        end
        X.bossMusic = love.audio.newSource(bsd, "static")
        X.bossMusic:setLooping(true)
    end

    ------------------------------------------------------------------
    -- Credits, loot crates & interface
    ------------------------------------------------------------------
    genSound("coin", 0.45, 0.5, function(t)
        local a = tone(1568, t) * exp(-t * 9) * 0.35
        local b = t > 0.08 and tone(2093, t) * exp(-(t - 0.08) * 7) * 0.35 or 0
        return a + b + tone(4186, t) * exp(-t * 20) * 0.05
    end)

    genSound("hover", 0.05, 0.15, function(t) return tone(1800, t) * exp(-t * 80) * 0.5 end)

    genSound("roll_tick", 0.04, 0.3, function(t)
        return (tone(2400, t) * 0.4 + noise() * 0.3) * exp(-t * 120)
    end)

    n = lpNoise()
    genSound("crate_open", 0.7, 0.55, function(t)
        local creak = sin(2 * pi * (180 + 90 * sin(t * 30)) * t) * exp(-t * 5) * 0.2
        return n(0.5) * exp(-t * 18) * 1.1 + creak + tone(140, t) * exp(-t * 20) * 0.4
    end)

    genSound("crate_win", 1.3, 0.55, function(t)
        local notes = { 523, 659, 784, 1047, 1319 }
        local s = 0
        for i, f in ipairs(notes) do
            local st = (i - 1) * 0.09
            if t > st then s = s + (tone(f, t) * 0.18 + tone(f * 2, t) * 0.04) * exp(-(t - st) * 3.5) end
        end
        return s
    end)

    genSound("crate_rare", 2.0, 0.6, function(t)
        local s = 0
        local notes = { 392, 523, 659, 784, 1047, 1319, 1568 }
        for i, f in ipairs(notes) do
            local st = (i - 1) * 0.07
            if t > st then s = s + tone(f, t) * exp(-(t - st) * 2.2) * 0.13 end
        end
        local shimmer = tone(3136 + 300 * sin(t * 25), t) * exp(-t * 1.5) * 0.05
        return s + shimmer + noise() * exp(-t * 3) * 0.04
    end)

    genSound("crate_nothing", 0.9, 0.45, function(t)
        local f = t < 0.3 and 330 or (t < 0.55 and 311 or 262)
        return (sqr(f, t) * 0.12 + tone(f, t) * 0.3) * exp(-(t % 0.3) * 3) * (1 - t / 0.9)
    end)

    genSound("join", 0.5, 0.45, function(t)
        local a = tone(659, t) * exp(-t * 8) * 0.35
        local b = t > 0.12 and tone(988, t) * exp(-(t - 0.12) * 6) * 0.35 or 0
        return a + b
    end)

    genSound("leave", 0.5, 0.4, function(t)
        local a = tone(784, t) * exp(-t * 8) * 0.35
        local b = t > 0.12 and tone(523, t) * exp(-(t - 0.12) * 6) * 0.35 or 0
        return a + b
    end)

    o = osc()
    genSound("respawn", 0.9, 0.5, function(t, p)
        return o(300 + 900 * p) * sin(pi * p) * 0.35 + tone(1500 + 800 * p, t) * sin(pi * p) * 0.06
    end)

    ------------------------------------------------------------------
    -- Day / night
    ------------------------------------------------------------------
    genSound("owl", 1.4, 0.45, function(t)
        local function hoot(st, f, len)
            if t < st or t > st + len then return 0 end
            local lt = t - st
            return tone(f - 30 * lt / len, t) * sin(pi * lt / len) * 0.5
        end
        return hoot(0, 380, 0.22) + hoot(0.32, 360, 0.18) + hoot(0.62, 370, 0.55)
    end)

    o = osc()
    genSound("howl", 2.6, 0.4, function(t, p)
        local f = 380 + 260 * sin(pi * min(1, p * 1.6)) - 120 * max(0, p - 0.6)
        return o(f) * sin(pi * p) * 0.4 * (0.85 + 0.15 * sin(t * 30))
    end)

    o = osc()
    genSound("bird", 0.6, 0.3, function(t)
        local seg = t % 0.15
        local gate = seg < 0.08 and sin(pi * seg / 0.08) or 0
        return o(2600 + 1400 * sin(seg * 60)) * gate * 0.35
    end)

    genSound("dawn", 1.6, 0.4, function(t, p)
        return (tone(523, t) * 0.25 + tone(659, t) * 0.2 + tone(784, t) * 0.18) * sin(pi * p)
    end)

    genSound("dusk", 1.8, 0.4, function(t, p)
        return (tone(220, t) * 0.3 + tone(262, t) * 0.22 + tone(330, t) * 0.12) * sin(pi * p)
    end)

    ------------------------------------------------------------------
    -- The Haunted Hollow
    ------------------------------------------------------------------
    o = osc()
    genSound("bat_screech", 0.4, 0.4, function(t)
        local seg = t % 0.08
        local chirp = seg < 0.05 and sin(pi * seg / 0.05) or 0
        return o(5200 - 30000 * seg) * chirp * exp(-t * 3) * 0.4
    end)

    genSound("bite", 0.16, 0.5, function(t)
        return (noise() * 0.8 + sqr(260, t) * 0.3) * exp(-t * 30)
            + (t > 0.05 and noise() * exp(-(t - 0.05) * 45) * 0.5 or 0)
    end)

    n = lpNoise()
    genSound("bat_poof", 0.35, 0.35, function(t, p) return n(0.25) * sin(pi * p) * 1.3 end)

    o = osc()
    genSound("gourd_spot", 0.6, 0.45, function(t, p)
        local syl = t % 0.1
        local gate = syl < 0.07 and sin(pi * syl / 0.07) or 0
        return o(330 + 120 * sin(t * 37) - 100 * p) * gate * 0.4 + noise() * gate * 0.06
    end)

    n = lpNoise()
    genSound("gourd_bite", 0.28, 0.55, function(t)
        return n(0.4) * exp(-t * 20) * 1.3 + tone(120, t) * exp(-t * 25) * 0.5
            + (t > 0.08 and noise() * exp(-(t - 0.08) * 50) * 0.4 or 0)
    end)

    local o2 = osc()
    o = osc()
    genSound("witch_laugh", 1.2, 0.55, function(t, p)
        local syl = t % 0.13
        local gate = syl < 0.09 and sin(pi * syl / 0.09) or 0
        local f = 880 - 380 * p + 45 * sin(t * 55)
        return (o2(f) * 0.5 + o(f * 2.01) * 0.2 + noise() * 0.15) * gate * (1 - p * 0.4) * 0.6
    end)

    n = lpNoise()
    genSound("potion_throw", 0.35, 0.35, function(t, p)
        return n(0.12) * sin(pi * p) * 1.2 + tone(300 + 60 * sin(t * 50), t) * sin(pi * p) * 0.12
    end)

    genSound("potion_break", 0.6, 0.5, function(t)
        local glass = (tone(3100, t) * 0.3 + tone(4300, t) * 0.25 + tone(5600, t) * 0.15) * exp(-t * 14)
        local bub = tone(220 + 160 * abs(sin(t * 45)), t) * exp(-t * 5) * 0.2
        return glass + noise() * exp(-t * 35) * 0.6 + bub
    end)

    o = osc()
    genSound("poison", 0.4, 0.35, function(t, p)
        return o(170 + 130 * abs(sin(t * 60))) * sin(pi * p) * 0.4
    end)

    o = osc()
    genSound("jumpscare", 0.9, 0.95, function(t, p)
        return noise() * exp(-t * 3) * 0.8 + o(2600 - 1800 * p) * 0.5 * (1 - p) + sqr(97, t) * 0.25 * (1 - p)
    end)

    -- 3-second "spooked" song: detuned music box over a tritone drone
    local notes = { 659, 622, 466, 440, 587, 415, 311, 349, 659, 494, 466, 330 }
    o = osc()
    genSound("spooked_song", 3.0, 0.6, function(t, p)
        local i = min(#notes, floor(t / 0.25) + 1)
        local lt = t - (i - 1) * 0.25
        local f = notes[i]
        local box = (tone(f, t) + tone(f * 1.012, t) * 0.8 + tone(f * 2.003, t) * 0.25) * exp(-lt * 6) * 0.22
        local drone = (tone(55, t) + tone(77.8, t)) * 0.12 * min(1, t * 2)
        local screech = p > 0.8 and o(1800 + 2600 * (p - 0.8)) * (p - 0.8) * 1.2 or 0
        return box + drone + screech
    end)

    n = lpNoise()
    o = osc()
    genSound("cursed_charge", 2.0, 0.6, function(t, p)
        return n(0.02 + 0.1 * p) * 3 * p + o(40 + 160 * p * p) * 0.35 * p + noise() * 0.05 * sin(t * 13) ^ 2
    end)

    -- A LOUD, violent explosion of shattering glass
    local pings = {}
    for i = 1, 70 do
        pings[i] = { st = rand() ^ 2 * 1.6, f = randRange(1800, 7500), d = randRange(6, 22), a = randRange(0.15, 0.35) }
    end
    n = lpNoise()
    genSound("glass_blast", 2.8, 1.0, function(t)
        local s = noise() * exp(-t * 5) * 1.1 + n(0.3) * exp(-t * 2) * 0.8 + tone(42, t) * exp(-t * 2.5) * 0.9
        for i = 1, #pings do
            local pg = pings[i]
            if t > pg.st then s = s + tone(pg.f, t) * exp(-(t - pg.st) * pg.d) * pg.a end
        end
        return s
    end)

    -- Looping ambient frontier wind
    n = lpNoise()
    local n2 = lpNoise()
    local dur = 6
    local count = floor(dur * RATE)
    local sd = love.sound.newSoundData(count, RATE, 16, 1)
    for i = 0, count - 1 do
        local p = i / count
        local gust = 0.35 + 0.65 * sin(pi * p) ^ 2 * (0.7 + 0.3 * sin(p * 2 * pi * 3))
        sd:setSample(i, clamp(n(0.015 + 0.02 * gust) * 3.5 * gust + n2(0.004) * 2, -1, 1))
    end
    ambient = love.audio.newSource(sd, "static")
    ambient:setLooping(true)

    -- Rain loop: bright filtered noise + random droplet ticks
    n = lpNoise()
    local drop = 0
    sd = love.sound.newSoundData(count, RATE, 16, 1)
    for i = 0, count - 1 do
        if rand() < 0.0006 then drop = 1 end
        drop = drop * 0.992
        sd:setSample(i, clamp(n(0.55) * 0.45 + noise() * drop * 0.35, -1, 1))
    end
    rainLoop = love.audio.newSource(sd, "static")
    rainLoop:setLooping(true)

    -- Blizzard loop: howling, gusting wind
    n = lpNoise(); n2 = lpNoise()
    local hph = 0
    sd = love.sound.newSoundData(count, RATE, 16, 1)
    for i = 0, count - 1 do
        local p = i / count
        local gust = 0.5 + 0.5 * sin(p * 2 * pi * 2) ^ 2
        hph = hph + 2 * pi * (320 + 140 * sin(p * 2 * pi * 3)) / RATE
        sd:setSample(i, clamp(n(0.04 + 0.08 * gust) * 4 * gust + n2(0.3) * 0.25 + sin(hph) * 0.05 * gust, -1, 1))
    end
    blizzardLoop = love.audio.newSource(sd, "static")
    blizzardLoop:setLooping(true)

    -- 30-second neutral background music loop (A minor, 128 BPM): pad, bass, arpeggio, shaker
    local MR = 22050
    local mdur = 30
    local mcount = floor(mdur * MR)
    local msd = love.sound.newSoundData(mcount, MR, 16, 1)
    local chords = {
        { 57, 60, 64 }, { 53, 57, 60 }, { 48, 52, 55 }, { 55, 59, 62 },
        { 57, 60, 64 }, { 53, 57, 60 }, { 50, 53, 57 }, { 52, 56, 59 },
    }
    local function mtof(m) return 440 * 2 ^ ((m - 69) / 12) end
    local padF, bassF, arpF = {}, {}, {}
    for i, c in ipairs(chords) do
        padF[i] = { mtof(c[1]), mtof(c[2]), mtof(c[3]) }
        bassF[i] = mtof(c[1] - 12)
        arpF[i] = { mtof(c[1] + 12), mtof(c[2] + 12), mtof(c[3] + 12), mtof(c[1] + 24) }
    end
    local chordLen = mdur / #chords
    local stepLen = chordLen / 16
    local pattern = { 1, 2, 3, 2, 4, 3, 2, 3 }
    for i = 0, mcount - 1 do
        local t = i / MR
        local ci = min(#chords, floor(t / chordLen) + 1)
        local ct = t - (ci - 1) * chordLen
        local env = min(1, ct / 0.5) * min(1, (chordLen - ct) / 0.4)
        local pf = padF[ci]
        local pad = (sin(2 * pi * pf[1] * t) + sin(2 * pi * pf[2] * t) + sin(2 * pi * pf[3] * t)
            + 0.3 * sin(2 * pi * pf[1] * 2.004 * t)) * env * 0.05
        local qt = t % (stepLen * 2)
        local bass = sin(2 * pi * bassF[ci] * t) * exp(-qt * 2.5) * 0.17
        local si = floor(t / stepLen)
        local st = t - si * stepLen
        local note = arpF[ci][pattern[si % 8 + 1]]
        local arp = (sin(2 * pi * note * t) * 0.7 + sin(2 * pi * note * 2 * t) * 0.15) * exp(-st * 9) * 0.09 * min(1, (chordLen - ct) / 0.05)
        local hat = (si % 2 == 1) and noise() * exp(-st * 45) * 0.03 or 0
        msd:setSample(i, clamp(pad + bass + arp + hat, -1, 1))
    end
    musicSrc = love.audio.newSource(msd, "static")
    musicSrc:setLooping(true)

    -- Night crickets loop (volume follows the darkness)
    local ccount = floor(4 * RATE)
    local csd = love.sound.newSoundData(ccount, RATE, 16, 1)
    local chirps = {}
    for _ = 1, 26 do chirps[#chirps + 1] = { st = rand() * 3.8, f = randRange(4200, 5200), pan = rand() } end
    for i = 0, ccount - 1 do
        local t = i / RATE
        local s = 0
        for k = 1, #chirps do
            local c = chirps[k]
            local lt = t - c.st
            if lt > 0 and lt < 0.18 then
                local pulse = (lt % 0.045) < 0.028 and 1 or 0
                s = s + sin(2 * pi * c.f * t) * pulse * sin(pi * lt / 0.18) * 0.18
            end
        end
        csd:setSample(i, clamp(s, -1, 1))
    end
    X.cricketLoop = love.audio.newSource(csd, "static")
    X.cricketLoop:setLooping(true)
end
end

local function playSfx(name, pitchVar, volMul)
    local s = SFX[name]
    if not s or settings.volume <= 0 then return end
    local v = s.vol * (volMul or 1) * settings.volume
    if v <= 0.01 then return end
    local c = s.src:clone()
    c:setVolume(v)
    if pitchVar then c:setPitch(1 + (rand() * 2 - 1) * pitchVar) end
    c:play()
end

-- Volume falloff for world sounds relative to the player
local function volAt(x, y)
    if not me then return 1 end
    return clamp(1 - dist(x, y, me.x, me.y) / 1300, 0, 1)
end

local function updateAmbientVolume()
    if ambient then ambient:setVolume(0.18 * settings.volume) end
end

------------------------------------------------------------------------------
-- Save data
------------------------------------------------------------------------------
-- Records, credits and permanent weapons live in the profile (profile.lua)
local function loadSave()
    save = PROF.load()
    settings.volume = clamp(save.volume or 0.8, 0, 1)
    settings.music = (save.music or 1) == 1
end

local function writeSave()
    save.volume = settings.volume
    save.music = settings.music and 1 or 0
    PROF.save()
end

------------------------------------------------------------------------------
-- Effects: particles, floating text, messages
------------------------------------------------------------------------------
local function spawnParticles(x, y, count, color, spMin, spMax, life, size, angle, spread, drag)
    for _ = 1, count do
        local a = angle and (angle + randRange(-(spread or pi), spread or pi)) or rand() * 2 * pi
        local sp = randRange(spMin, spMax)
        particles[#particles + 1] = {
            x = x, y = y, vx = cos(a) * sp, vy = sin(a) * sp,
            life = life * randRange(0.6, 1.2), maxLife = life,
            color = color, size = size * randRange(0.7, 1.3), drag = drag or 4,
        }
    end
end

local function addText(x, y, text, color, big)
    texts[#texts + 1] = {
        x = x + randRange(-8, 8), y = y, text = text, color = color or { 1, 1, 1 },
        life = 1.1, maxLife = 1.1, big = big, vy = -60,
    }
end

local function addMessage(text, color)
    table.insert(messages, 1, { text = text, color = color or { 1, 1, 1 }, life = 5 })
    if #messages > 7 then table.remove(messages) end
end

local function addShake(a) shake = min(18, shake + a) end

------------------------------------------------------------------------------
-- World generation
------------------------------------------------------------------------------
local function addWall(x, y, w, h, kind)
    local wl = { x = x, y = y, w = w, h = h, kind = kind or "wood" }
    walls[#walls + 1] = wl
    WG.add(wl)
    return wl
end

local function areaFree(x, y, w, h, pad)
    pad = pad or 0
    local qx, qy, qw, qh = x - pad, y - pad, w + 2 * pad, h + 2 * pad
    local buf, n = WG.query(qx, qy, qw, qh, WG.buf3)
    for i = 1, n do
        local wl = buf[i]
        if rectOverlap(qx, qy, qw, qh, wl.x, wl.y, wl.w, wl.h) then return false end
    end
    -- nothing else is built or spawned inside the Stronghold
    local S = X.SH
    if S and not X.shOpen and rectOverlap(qx, qy, qw, qh, S.x - 60, S.y - 60, S.w + 120, S.h + 120) then return false end
    local L = X.LAIR
    if L and not X.lairFree and rectOverlap(qx, qy, qw, qh, L.x - 90, L.y - 90, L.w + 180, L.h + 180) then return false end
    local G = X.GKA
    if G and not X.lairFree and rectOverlap(qx, qy, qw, qh, G.x - 90, G.y - 90, G.w + 180, G.h + 180) then return false end
    return true
end

-- Walls around and between the regions, with the 4 sealed gates:
--   gate  = Desert -> Frozen   (50 kills)        gate2 = Frozen -> Swamp  (150 kills)
--   gate3 = Swamp -> Volcanic  (200 kills)       gate4 = Volcanic -> Hollow (250 kills + the Gatekeeper's key)
function X.buildBorders()
    local T, W, H = K.GATE_T, K.WORLD_W, K.WORLD_H
    local E, GW = K.EAST_X, K.GATE_W
    local function hgate(x0, x1, y, gx, kind)      -- horizontal wall from x0 to x1 with a gate at gx
        addWall(x0, y, gx - x0, T, "border")
        addWall(gx + GW, y, x1 - gx - GW, T, "border")
        addWall(gx, y, GW, T, kind)
    end
    addWall(-T, -T, W + 2 * T, T, "border")                              -- top of the desert
    addWall(-T, 0, T, K.FROZEN_Y1 + T, "border")                         -- west side
    addWall(W, -T, T, H + T, "border")                                   -- east side of the desert
    hgate(-T, W + T, H, K.GATE_X, "gate")                                -- desert / frozen
    addWall(-T, K.FROZEN_Y1, W + 2 * T, T, "border")                     -- bottom of the frozen wastes
    -- frozen / swamp: a vertical wall with a gate in the middle
    addWall(W, H, T, K.G2_Y - H, "border")
    addWall(W, K.G2_Y + GW, T, K.FROZEN_Y1 - K.G2_Y - GW, "border")
    addWall(W, K.G2_Y, T, GW, "gate2")
    addWall(W, H, W + 2 * T, T, "border")                                -- top of the swamp
    addWall(K.TOTAL_W, H, T, K.TOTAL_H - H + T, "border")               -- east side of the east column
    addWall(W, K.FROZEN_Y1, T, K.TOTAL_H - K.FROZEN_Y1 + T, "border")    -- west side of volcanic + hollow
    hgate(E, K.TOTAL_W, K.FROZEN_Y1, K.EGATE_X, "gate3")                 -- swamp / volcanic
    hgate(E, K.TOTAL_W, K.VOLC_Y1, K.EGATE_X, "gate4")                   -- volcanic / hollow
    addWall(W, K.TOTAL_H, W + 2 * T, T, "border")                        -- bottom of the hollow
end

local function generateWorld()
    local T = 60
    X.buildBorders()
    X.buildShed()   -- everyone spawns in the safe shed in the middle of the desert
    X.buildStronghold()

    local cx, cy = K.WORLD_W / 2, K.WORLD_H / 2
    local placed, tries = 0, 0
    local thick, door = 22, 84

    local function hwall(x, y, len, hasDoor, kind)
        if hasDoor then
            local seg = (len - door) / 2
            addWall(x, y, seg, thick, kind); addWall(x + seg + door, y, seg, thick, kind)
        else addWall(x, y, len, thick, kind) end
    end
    local function vwall(x, y, len, hasDoor, kind)
        if hasDoor then
            local seg = (len - door) / 2
            addWall(x, y, thick, seg, kind); addWall(x, y + seg + door, thick, seg, kind)
        else addWall(x, y, thick, len, kind) end
    end

    while placed < 1350 and tries < 54000 do
        tries = tries + 1
        local roll = rand()
        if roll < 0.28 then
            -- Abandoned building with doorways
            local bw, bh = randInt(240, 440), randInt(200, 330)
            local x, y = randRange(120, K.WORLD_W - bw - 120), randRange(120, K.WORLD_H - bh - 120)
            if dist(x + bw / 2, y + bh / 2, cx, cy) > 500 and areaFree(x, y, bw, bh, 80) then
                floors[#floors + 1] = { x = x, y = y, w = bw, h = bh }
                hwall(x, y, bw, rand() < 0.4)
                hwall(x, y + bh - thick, bw, true)
                vwall(x, y + thick, bh - 2 * thick, rand() < 0.5)
                vwall(x + bw - thick, y + thick, bh - 2 * thick, rand() < 0.5)
                placed = placed + 1
            end
        elseif roll < 0.58 then
            -- Long fence / wall segment
            local len = randInt(160, 480)
            local horiz = rand() < 0.5
            local w, h = horiz and len or thick, horiz and thick or len
            local x, y = randRange(100, K.WORLD_W - w - 100), randRange(100, K.WORLD_H - h - 100)
            if dist(x + w / 2, y + h / 2, cx, cy) > 260 and areaFree(x, y, w, h, 70) then
                addWall(x, y, w, h, "wood")
                placed = placed + 1
            end
        elseif roll < 0.78 then
            -- L-shaped cover
            local a, b = randInt(120, 260), randInt(120, 260)
            local x, y = randRange(100, K.WORLD_W - a - 100), randRange(100, K.WORLD_H - b - 100)
            if dist(x + a / 2, y + b / 2, cx, cy) > 280 and areaFree(x, y, a, b, 70) then
                local fx, fy = rand() < 0.5, rand() < 0.5
                addWall(x, fy and y or y + b - thick, a, thick, "stone")
                addWall(fx and x or x + a - thick, y, thick, b, "stone")
                placed = placed + 1
            end
        else
            -- Boulder
            local s = randInt(50, 120)
            local s2 = s + randInt(-20, 20)
            local x, y = randRange(100, K.WORLD_W - s - 100), randRange(100, K.WORLD_H - s2 - 100)
            if dist(x, y, cx, cy) > 220 and areaFree(x, y, s, s2, 60) then
                addWall(x, y, s, s2, "rock")
                placed = placed + 1
            end
        end
    end

    -- Ground decoration (purely visual)
    for _ = 1, 23400 do
        local kind = rand()
        WG.addDecor({
            x = rand() * K.WORLD_W, y = rand() * K.WORLD_H,
            kind = kind < 0.55 and "grass" or (kind < 0.85 and "pebble" or (kind < 0.96 and "bush" or "cactus")),
            s = randRange(0.7, 1.4), r = rand() * 2 * pi,
        })
    end
end

------------------------------------------------------------------------------
-- World generation: the Frozen Wastes (south of the desert)
------------------------------------------------------------------------------
local function generateFrozen()
    local T = K.GATE_T

    local entryX, entryY = K.WORLD_W / 2, K.FROZEN_Y0 + 260
    local thick, door = 22, 84

    local function hwall(x, y, len, hasDoor, kind)
        if hasDoor then
            local seg = (len - door) / 2
            addWall(x, y, seg, thick, kind); addWall(x + seg + door, y, seg, thick, kind)
        else addWall(x, y, len, thick, kind) end
    end
    local function vwall(x, y, len, hasDoor, kind)
        if hasDoor then
            local seg = (len - door) / 2
            addWall(x, y, thick, seg, kind); addWall(x, y + seg + door, thick, seg, kind)
        else addWall(x, y, thick, len, kind) end
    end

    -- Frozen lakes: slippery ice, no collision
    local tries = 0
    while #lakes < 144 and tries < 4500 do
        tries = tries + 1
        local rx, ry = randInt(140, 300), randInt(90, 200)
        local x = randRange(rx + 150, K.WORLD_W - rx - 150)
        local y = randRange(K.FROZEN_Y0 + ry + 220, K.FROZEN_Y1 - ry - 150)
        local ok = dist(x, y, entryX, entryY) > 520
        for _, l in ipairs(lakes) do
            if dist(x, y, l.x, l.y) < rx + l.rx + 140 then ok = false break end
        end
        if ok then lakes[#lakes + 1] = { x = x, y = y, rx = rx, ry = ry, seed = rand() * 100 } end
    end
    local function nearLake(x, y, w, h)
        for _, l in ipairs(lakes) do
            if rectOverlap(x, y, w, h, l.x - l.rx - 30, l.y - l.ry - 30, l.rx * 2 + 60, l.ry * 2 + 60) then return true end
        end
        return false
    end

    -- The FROZEN CHEST shrine: a single one, hidden deep in the south
    for _ = 1, 500 do
        local s = 280
        local x = randRange(500, K.WORLD_W - 500)
        local y = randRange(K.FROZEN_Y0 + floor(K.WORLD_H * 0.6), K.FROZEN_Y1 - 450)
        if areaFree(x - s / 2, y - s / 2, s, s, 60) and not nearLake(x - s / 2, y - s / 2, s, s) then
            local x0, y0 = x - s / 2, y - s / 2
            floors[#floors + 1] = { x = x0, y = y0, w = s, h = s, kind = "shrine" }
            local doorSide = randInt(1, 4)
            hwall(x0, y0, s, doorSide == 1, "ice")
            hwall(x0, y0 + s - thick, s, doorSide == 2, "ice")
            vwall(x0, y0 + thick, s - 2 * thick, doorSide == 3, "ice")
            vwall(x0 + s - thick, y0 + thick, s - 2 * thick, doorSide == 4, "ice")
            frozenChest = { x = x, y = y, opened = false }
            break
        end
    end
    local function nearChest(x, y)
        return frozenChest and dist(x, y, frozenChest.x, frozenChest.y) < 230
    end

    local placed = 0
    tries = 0
    while placed < 1440 and tries < 63000 do
        tries = tries + 1
        local roll = rand()
        if roll < 0.2 then
            -- Ruined ice outpost with doorways
            local bw, bh = randInt(240, 420), randInt(200, 320)
            local x, y = randRange(120, K.WORLD_W - bw - 120), randRange(K.FROZEN_Y0 + 140, K.FROZEN_Y1 - bh - 120)
            if dist(x + bw / 2, y + bh / 2, entryX, entryY) > 450 and areaFree(x, y, bw, bh, 80) and not nearLake(x, y, bw, bh) then
                floors[#floors + 1] = { x = x, y = y, w = bw, h = bh, kind = "ice" }
                hwall(x, y, bw, rand() < 0.5, "ice")
                hwall(x, y + bh - thick, bw, true, "ice")
                vwall(x, y + thick, bh - 2 * thick, rand() < 0.5, "ice")
                vwall(x + bw - thick, y + thick, bh - 2 * thick, rand() < 0.5, "ice")
                placed = placed + 1
            end
        elseif roll < 0.42 then
            -- Ice wall
            local len = randInt(160, 460)
            local horiz = rand() < 0.5
            local w, h = horiz and len or thick, horiz and thick or len
            local x, y = randRange(100, K.WORLD_W - w - 100), randRange(K.FROZEN_Y0 + 120, K.FROZEN_Y1 - h - 100)
            if dist(x + w / 2, y + h / 2, entryX, entryY) > 280 and areaFree(x, y, w, h, 70)
               and not nearLake(x, y, w, h) and not nearChest(x + w / 2, y + h / 2) then
                addWall(x, y, w, h, "ice")
                placed = placed + 1
            end
        elseif roll < 0.74 then
            -- Pine grove (trees block movement, bullets and sight)
            local gx, gy = randRange(200, K.WORLD_W - 200), randRange(K.FROZEN_Y0 + 200, K.FROZEN_Y1 - 200)
            if dist(gx, gy, entryX, entryY) > 320 and not nearChest(gx, gy) then
                local any = false
                for _ = 1, randInt(2, 5) do
                    local s = randInt(34, 50)
                    local x, y = gx + randRange(-110, 110), gy + randRange(-110, 110)
                    if areaFree(x, y, s, s, 34) and not nearLake(x, y, s, s) then
                        addWall(x, y, s, s, "pine")
                        any = true
                    end
                end
                if any then placed = placed + 1 end
            end
        elseif roll < 0.88 then
            -- Snow-capped boulder
            local s = randInt(50, 110)
            local s2 = s + randInt(-20, 20)
            local x, y = randRange(100, K.WORLD_W - s - 100), randRange(K.FROZEN_Y0 + 100, K.FROZEN_Y1 - s2 - 100)
            if dist(x, y, entryX, entryY) > 240 and areaFree(x, y, s, s2, 60)
               and not nearLake(x, y, s, s2) and not nearChest(x, y) then
                addWall(x, y, s, s2, "snowrock")
                placed = placed + 1
            end
        else
            -- Ice crystal cluster
            local s = randInt(36, 60)
            local x, y = randRange(100, K.WORLD_W - s - 100), randRange(K.FROZEN_Y0 + 100, K.FROZEN_Y1 - s - 100)
            if dist(x, y, entryX, entryY) > 240 and areaFree(x, y, s, s, 50) and not nearChest(x, y) then
                addWall(x, y, s, s, "crystal")
                placed = placed + 1
            end
        end
    end

    -- Snowy ground decoration (purely visual)
    for _ = 1, 19800 do
        local k = rand()
        WG.addDecor({
            x = rand() * K.WORLD_W, y = randRange(K.FROZEN_Y0, K.FROZEN_Y1),
            kind = k < 0.4 and "snowdrift" or (k < 0.65 and "snowtuft" or (k < 0.82 and "frostpebble" or (k < 0.94 and "deadbush" or "icebit"))),
            s = randRange(0.7, 1.4), r = rand() * 2 * pi,
        })
    end
end

------------------------------------------------------------------------------
-- World generation: the Haunted Hollow (south of the Frozen Wastes)
------------------------------------------------------------------------------
local function generateSpooky()
    local T = K.GATE_T
    local OX = K.EAST_X           -- the Hollow is in the east column
    X.buildLair()        -- the Guardian's lair at the far south

    local entryX, entryY = OX + K.WORLD_W / 2, K.SPOOKY_Y0 + 260
    local thick, door = 22, 84
    local function hwall(x, y, len, hasDoor, kind)
        if hasDoor then
            local seg = (len - door) / 2
            addWall(x, y, seg, thick, kind); addWall(x + seg + door, y, seg, thick, kind)
        else addWall(x, y, len, thick, kind) end
    end
    local function vwall(x, y, len, hasDoor, kind)
        if hasDoor then
            local seg = (len - door) / 2
            addWall(x, y, thick, seg, kind); addWall(x, y + seg + door, thick, seg, kind)
        else addWall(x, y, thick, len, kind) end
    end

    local placed, tries = 0, 0
    while placed < 1350 and tries < 63000 do
        tries = tries + 1
        local roll = rand()
        if roll < 0.18 then
            -- Crypt / mausoleum with a doorway
            local bw, bh = randInt(220, 380), randInt(180, 300)
            local x, y = OX + randRange(120, K.WORLD_W - bw - 120), randRange(K.SPOOKY_Y0 + 140, K.SPOOKY_Y1 - bh - 120)
            if dist(x + bw / 2, y + bh / 2, entryX, entryY) > 450 and areaFree(x, y, bw, bh, 80) then
                floors[#floors + 1] = { x = x, y = y, w = bw, h = bh, kind = "crypt" }
                hwall(x, y, bw, rand() < 0.4, "crypt")
                hwall(x, y + bh - thick, bw, true, "crypt")
                vwall(x, y + thick, bh - 2 * thick, rand() < 0.5, "crypt")
                vwall(x + bw - thick, y + thick, bh - 2 * thick, rand() < 0.5, "crypt")
                placed = placed + 1
            end
        elseif roll < 0.4 then
            -- Graveyard: rows of gravestones inside an iron fence with gaps
            local cols, rows = randInt(3, 5), randInt(2, 4)
            local gw, gh = cols * 60 + 40, rows * 70 + 40
            local x, y = OX + randRange(120, K.WORLD_W - gw - 120), randRange(K.SPOOKY_Y0 + 140, K.SPOOKY_Y1 - gh - 120)
            if dist(x + gw / 2, y + gh / 2, entryX, entryY) > 420 and areaFree(x, y, gw, gh, 70) then
                local ft = 8
                -- fence with a gap in the middle of every side
                local function hf(fy) local seg = (gw - 90) / 2 addWall(x, fy, seg, ft, "fence") addWall(x + seg + 90, fy, seg, ft, "fence") end
                local function vf(fx) local seg = (gh - 90) / 2 addWall(fx, y, ft, seg, "fence") addWall(fx, y + seg + 90, ft, seg, "fence") end
                hf(y); hf(y + gh - ft); vf(x); vf(x + gw - ft)
                for c = 0, cols - 1 do
                    for r = 0, rows - 1 do
                        if rand() < 0.8 then
                            addWall(x + 30 + c * 60, y + 30 + r * 70, 24, 16, "grave")
                        end
                    end
                end
                placed = placed + 1
            end
        elseif roll < 0.7 then
            -- Dead tree
            local s = randInt(28, 44)
            local x, y = OX + randRange(100, K.WORLD_W - s - 100), randRange(K.SPOOKY_Y0 + 100, K.SPOOKY_Y1 - s - 100)
            if dist(x, y, entryX, entryY) > 260 and areaFree(x, y, s, s, 50) then
                addWall(x, y, s, s, "deadtree")
                placed = placed + 1
            end
        elseif roll < 0.85 then
            -- Crumbling stone wall
            local len = randInt(140, 400)
            local horiz = rand() < 0.5
            local w, h = horiz and len or thick, horiz and thick or len
            local x, y = OX + randRange(100, K.WORLD_W - w - 100), randRange(K.SPOOKY_Y0 + 120, K.SPOOKY_Y1 - h - 100)
            if dist(x + w / 2, y + h / 2, entryX, entryY) > 280 and areaFree(x, y, w, h, 70) then
                addWall(x, y, w, h, "crypt")
                placed = placed + 1
            end
        else
            -- Iron fence run
            local len = randInt(140, 320)
            local horiz = rand() < 0.5
            local w, h = horiz and len or 8, horiz and 8 or len
            local x, y = OX + randRange(100, K.WORLD_W - w - 100), randRange(K.SPOOKY_Y0 + 120, K.SPOOKY_Y1 - h - 100)
            if dist(x + w / 2, y + h / 2, entryX, entryY) > 280 and areaFree(x, y, w, h, 70) then
                addWall(x, y, w, h, "fence")
                placed = placed + 1
            end
        end
    end

    -- Haunted ground decoration (purely visual)
    for _ = 1, 19800 do
        local k = rand()
        WG.addDecor({
            x = OX + rand() * K.WORLD_W, y = randRange(K.SPOOKY_Y0, K.SPOOKY_Y1),
            kind = k < 0.38 and "deadgrass" or (k < 0.56 and "bones" or (k < 0.74 and "mushroom" or (k < 0.9 and "pumpkin" or "candle"))),
            s = randRange(0.7, 1.4), r = rand() * 2 * pi, ph = rand() * 10,
        })
    end
end

-- Finds a free spot in a region. With an anchor (a player), the spot is picked
-- in a ring around it, so enemies & loot appear near the action on the huge maps.
local function findFreeSpot(r, minDist, region, anchor, maxDist)
    local reg = REGIONS[region or "desert"]
    local y0, y1 = reg.y0 + 100, reg.y1 - 100
    local x0, x1 = reg.x0 + 100, reg.x1 - 100
    for i = 1, 300 do
        local x, y
        if anchor and i <= 220 then
            local a = rand() * 2 * pi
            local d = randRange(minDist or 0, maxDist or ((minDist or 0) + 1600))
            x, y = clamp(anchor.x + cos(a) * d, x0, x1), clamp(anchor.y + sin(a) * d, y0, y1)
        else
            x, y = randRange(x0, x1), randRange(y0, y1)
        end
        local ok = areaFree(x - r, y - r, 2 * r, 2 * r, 8) and not X.inAnyPool(x, y, r + 10)
        if ok and minDist and me then
            for _, p in ipairs(X.allPlayers()) do
                if dist(x, y, p.x, p.y) < minDist * 0.85 then ok = false break end
            end
        end
        if ok then return x, y end
    end
    return nil
end

------------------------------------------------------------------------------
-- Movement with wall collision (axis separated, sub-stepped to avoid tunneling)
------------------------------------------------------------------------------
local function moveAxis(e, d, axis)
    local r = e.r
    if axis == "x" then e.x = e.x + d else e.y = e.y + d end
    local buf, n = WG.query(e.x - r - 2, e.y - r - 2, 2 * r + 4, 2 * r + 4)
    local isEnemy = e.kind ~= nil
    for i = 1, n do
        local w = buf[i]
        if (isEnemy or not w.enemyOnly) and rectOverlap(e.x - r, e.y - r, 2 * r, 2 * r, w.x, w.y, w.w, w.h) then
            if axis == "x" then
                if d > 0 then e.x = w.x - r elseif d < 0 then e.x = w.x + w.w + r end
            else
                if d > 0 then e.y = w.y - r elseif d < 0 then e.y = w.y + w.h + r end
            end
        end
    end
end

local function moveEntity(e, dx, dy)
    local steps = max(1, math.ceil(max(abs(dx), abs(dy)) / 8))
    for _ = 1, steps do
        moveAxis(e, dx / steps, "x")
        moveAxis(e, dy / steps, "y")
    end
end

------------------------------------------------------------------------------
-- Spawning
------------------------------------------------------------------------------
local function pickPatrolTarget(e)
    local reg = REGIONS[e.region or "desert"]
    if e.pool then
        local p, a, d = e.pool, rand() * 2 * pi, randRange(0.1, 0.8)
        e.px, e.py = p.x + cos(a) * p.rx * d, p.y + sin(a) * p.ry * d
        return
    end
    local S = X.SH
    if e.kind == "bowman" and S then
        -- Bow Wielders only wander inside the Stronghold
        for _ = 1, 10 do
            local tx, ty = randRange(S.x + 70, S.x + S.w - 70), randRange(S.y + 70, S.y + S.h - 70)
            if hasLOS(e.x, e.y, tx, ty) then e.px, e.py = tx, ty return end
        end
        e.px, e.py = S.cx, S.cy + 120
        return
    end
    for _ = 1, 10 do
        local a, d = rand() * 2 * pi, randRange(120, 450)
        local tx = clamp(e.homeX + cos(a) * d, reg.x0 + 80, reg.x1 - 80)
        local ty = clamp(e.homeY + sin(a) * d, reg.y0 + 80, reg.y1 - 80)
        if e.kind == "bat" or hasLOS(e.x, e.y, tx, ty) then e.px, e.py = tx, ty return end
    end
    e.px, e.py = e.homeX, e.homeY
end

-- spawnEnemy(kind, minDist)          -> random free spot in the kind's region
-- spawnEnemy(kind, nil, x, y)        -> at an exact position (used for groups)
local function spawnEnemy(kind, minDist, px, py)
    local region = ENEMY_REGION[kind]
    local x, y = px, py
    if not x then
        local anchor = X.anchorFor(region)
        x, y = findFreeSpot(18, minDist or 800, region, anchor, (minDist or 800) + 1700)
    end
    if not x then return end
    world.nextId = world.nextId + 1
    local e = {
        id = world.nextId, kind = kind, region = region, x = x, y = y, homeX = x, homeY = y, angle = rand() * 2 * pi,
        state = "patrol", awareness = 0, losTimer = 0, canSee = false,
        fireCd = randRange(0.6, 1.4), hitFlash = 0, stuck = 0, avoid = 1, avoidTimer = 0,
        searchTimer = 0, alertCd = 0, fleeTimer = 0, waitTimer = 0, muzzle = 0,
        strafe = rand() < 0.5 and 1 or -1, strafeTimer = 0, walkAnim = 0, spawnFade = 0,
        -- status effects & melee
        frostT = 0, frostTick = 0, stunT = 0, shockSlowT = 0, speedMul = 1,
        meleeCd = 0, throwCd = randRange(1, 2.5), swingT = 0, throwAnim = 0,
        -- haunted hollow
        hidden = 0, castT = 0, hop = rand() * 6, flap = rand() * 6, wob = rand() * 6, hover = rand() * 6,
    }
    local st = X.ESTATS[kind]
    e.r, e.hp, e.maxHp = st.r, st.hp, st.hp
    e.speed, e.huntSpeed, e.vision, e.fov = st.speed, st.hunt, st.vision, st.fov
    if kind == "witch" then e.throwCd = randRange(1.5, 3) end
    if kind == "shroomer" or kind == "toad" then e.throwCd = randRange(1, 2.5) end
    if kind == "blazeshroom" then e.fireCd = randRange(0.5, 1.2) end
    if kind == "croc" and X.swampPools and #X.swampPools > 0 then
        -- crocodiles live in the murky water
        local p = X.randomPoolNear(X.swampPools, x, y, 2600) or X.swampPools[randInt(1, #X.swampPools)]
        e.pool = p
        e.x, e.y = p.x + randRange(-p.rx, p.rx) * 0.4, p.y + randRange(-p.ry, p.ry) * 0.4
        e.homeX, e.homeY = p.x, p.y
    end
    e.hp = floor(e.hp * X.D.hp + 0.5)
    e.maxHp = e.hp
    e.hpLag = e.hp
    if X.endless and (world.wave or 0) >= X.LAST_WAVE then X.applyLastForm(e) end
    pickPatrolTarget(e)
    enemies[#enemies + 1] = e
    return e
end

local function randomKind(region)
    local r = rand()
    if region == "desert" then return r < 0.3 and "scout" or "bandit" end
    if region == "frozen" then return r < 0.45 and "snowman" or "frozen" end
    if region == "swamp" then return r < 0.4 and "shroomer" or (r < 0.75 and "toad" or "croc") end
    if region == "volcanic" then return r < 0.4 and "slime" or (r < 0.7 and "serpent" or "blazeshroom") end
    return r < 0.4 and "gourd" or (r < 0.7 and "bat" or "witch")
end

-- Desert enemies travel in groups (packs of up to 5 around one camp spot)
local function spawnGroup(kinds, minDist)
    local anchor = X.anchorFor("desert")
    local cx, cy = findFreeSpot(60, minDist or 900, "desert", anchor, (minDist or 900) + 1500)
    if not cx then return end
    for _, kind in ipairs(kinds) do
        local e
        for _ = 1, 25 do
            local x, y = cx + randRange(-170, 170), cy + randRange(-170, 170)
            if x > 100 and x < K.WORLD_W - 100 and y > 100 and y < K.WORLD_H - 100
               and areaFree(x - 18, y - 18, 36, 36, 8) and hasLOS(cx, cy, x, y) then
                e = spawnEnemy(kind, nil, x, y)
                break
            end
        end
        e = e or spawnEnemy(kind, minDist)
        if e then e.homeX, e.homeY = cx, cy end
    end
end

local function randomGroup(n)
    local g = {}
    for i = 1, n do g[i] = randomKind("desert") end
    return g
end

local function spawnBox(minDist, x, y, region)
    if not x then x, y = findFreeSpot(18, minDist or 300, region, me, 2800) end
    if not x then return end
    local reg = regionAt(x, y)
    boxes[#boxes + 1] = { x = x, y = y, r = 16, bob = rand() * 2 * pi, region = reg,
        frozen = reg == "frozen", spooky = reg == "spooky" }
end

-- Counts living entities of a list that are in the given region
local function countIn(list, region)
    local n = 0
    for _, o in ipairs(list) do
        if not o.dead and o.kind ~= "bowman" and regionAt(o.x, o.y) == region then n = n + 1 end
    end
    return n
end

X.PAIRED = { shroomer = true, toad = true, slime = true, blazeshroom = true }

local function maxEnemies(region)
    local base
    if region == "frozen" then
        base = min(34, 16 + floor(max(0, world.kills - K.REGION_UNLOCK_KILLS) / 5))
    elseif region == "spooky" then
        base = min(32, 16 + floor(max(0, world.kills - K.SPOOKY_UNLOCK_KILLS) / 5))
    elseif region == "swamp" then
        base = min(32, 16 + floor(max(0, world.kills - K.SWAMP_UNLOCK_KILLS) / 5))
    elseif region == "volcanic" then
        base = min(32, 16 + floor(max(0, world.kills - K.VOLC_UNLOCK_KILLS) / 5))
    else
        base = min(42, 18 + floor(world.kills / 5))
        if X.endless then base = max(base, floor(X.groupSize() * 2.5)) end   -- room for the big wave groups
    end
    -- more players in the same region -> more enemies
    local n = #X.playersInRegion(region)
    return floor(base * X.D.count * (1 + 0.5 * max(0, n - 1)))
end

-- Region streaming (see X.updateStreaming): called when the local player changes region
local function switchRegion(new)
    X.updateStreaming(true)
    if MPS.role ~= "client" then X.fillRegion(new, 6) end
end

------------------------------------------------------------------------------
-- New game
------------------------------------------------------------------------------
local unlockFrozen, unlockSpooky
local function newGame(opts)
    -- generation takes a moment on the huge maps: show a loading screen first
    X.pendingGame = opts or {}
    gameState = "loading"
    X.loadFrames = 0
    overlay = nil
    love.mouse.setVisible(true)
end

function X.startGame(opts)
    walls, floors, enemies, bullets, boxes = {}, {}, {}, {}, {}
    particles, texts, decals, rings, messages, decor = {}, {}, {}, {}, {}, {}
    lakes, snowgraves = {}, {}
    WG.cells, WG.dcells = {}, {}
    X.beams, X.fireflies, X.vortices, X.meteors = {}, {}, {}, {}
    X.chat.open, X.chat.text, X.chat.log = false, "", {}
    frozenChest, regionUnlocked = nil, false
    world.stash = { desert = {}, frozen = {}, swamp = {}, volcanic = {}, spooky = {} }
    world.spookyOpen, world.swampOpen, world.volcOpen, world.hasKey = false, false, false, false
    world.gkDead, world.keyItem = false, nil
    X.keyFly = nil
    world.visited = { desert = true }
    world.nextId = 0
    if X.resetEvents then X.resetEvents() end
    X.rev, X.toasts = nil, X.toasts or {}
    world.kills = opts.kills or 0
    world.seed = opts.seed or floor(love.math.random() * 1000000000)
    X.D = X.DIFF_BY_ID[opts.diff or "easy"] or X.DIFF_BY_ID.easy
    X.endless = opts.endless and true or false
    X.lastEndless = X.endless
    -- every run starts a fresh kill count towards the next credit (no carrying 9 kills into a Nightmare run)
    if (PROF.data.killBank or 0) ~= 0 then PROF.data.killBank = 0 PROF.save() end
    if X.achieveCheck then X.achieveCheck() end
    world.wave = opts.wave or (X.endless and 1 or 0)
    X.SH, X.LAIR, X.BF, X.cut, X.camZoom = nil, nil, nil, nil, 1
    X.GKA, X.swampPools, X.lavaPools = nil, {}, {}
    world.infiltrated, world.lairOpen, world.gourdPool = (opts.inf == 1), false, opts.gp or 0
    world.tod = opts.tod or X.DAY_LEN * 0.3
    world.day = opts.day or 1
    if MPS.role ~= "host" and MPS.role ~= "client" then MPS.role, MPS.id, MPS.online, MPS.others = "solo", 1, false, {} end

    stats = {
        kills = 0, banditKills = 0, scoutKills = 0, frozenKills = 0, snowmanKills = 0,
        shotsFired = 0, shotsHit = 0, damageDealt = 0, damageTaken = 0, damageBlocked = 0,
        dodges = 0, boxesOpened = 0, bandagesUsed = 0, goldEarned = 0, goldSpent = 0,
        distance = 0, dashes = 0, alertsRaised = 0, streak = 0, bestStreak = 0, time = 0,
        itemsBought = 0, mpEarned = 0, spellsCast = 0, snowgraveKills = 0, frostKills = 0,
        reachedFrozen = false, chestFound = false, weatherSurvived = 0,
        gourdKills = 0, batKills = 0, witchKills = 0, cursedKills = 0, spooked = 0, reachedSpooky = false,
        deaths = 0, creditsEarned = 0, bowmanKills = 0, guardianKills = 0, bossDefeated = false,
        shroomerKills = 0, toadKills = 0, crocKills = 0, slimeKills = 0, serpentKills = 0, blazeshroomKills = 0, gatekeeperKills = 0,
    }

    local sx, sy = X.shedSpot(MPS.id)
    player = {
        x = sx, y = sy, r = 14,
        hp = 100, maxHp = 100, hpLag = 100,
        baseSpeed = 210, angle = -pi / 2,
        stamina = 100, maxStamina = 100, staminaDelay = 0,
        dashTime = 0, dashCd = 0, dashDx = 0, dashDy = 0, iframes = 0,
        blocking = false, blockFlash = 0, fireCd = 0, muzzle = 0, recoil = 0,
        weapon = "pistol",
        owned = { pistol = true, shotgun = false, boots = false, vest = false, book = false },
        ammo = 60, ammoFrac = 0,                 -- ONE universal ammo type for every gun
        bandages = 1, bootsOn = false,
        gold = 0, dead = false, deathTimer = 0, walkAnim = 0, hitFlash = 0, respawnT = 0, lives = 3, out = false,
        level = 0, spellCds = {}, blazeT = 0, hasBlaze = false,
        -- magic
        mp = 0, mpUnlocked = false, hasBook = false, hasIceShock = false,
        turtleT = 0, iciclesT = 0, chillT = 0, spellCd = 0,
        -- movement extras (knockback, ice sliding)
        kbx = 0, kby = 0, vx = 0, vy = 0, onIce = false, moving = false, region = "desert",
        -- haunted hollow
        hasCursed = false, cursedCd = 0, cursedT = 0, blindT = 0, spookT = 0, poisonT = 0, poisonTick = 0,
    }
    me = player
    -- weapons, utilities and armor come from the LOADOUT (Credit Shop)
    X.initKit(player)

    cam = { x = player.x, y = player.y }
    -- the same seed builds the exact same world on every player's machine
    local gen = love.math.newRandomGenerator(world.seed)
    rng = function(a, b) if a then return gen:random(a, b) end return gen:random() end
    generateWorld()
    generateFrozen()
    generateSpooky()
    X.generateSwamp()
    X.generateVolcanic()
    rng = love.math.random

    weather = {
        desert = { active = false, t = 0, next = randRange(90, 200), intensity = 0 },
        frozen = { active = false, t = 0, next = randRange(45, 120), intensity = 0 },
        volcanic = { active = false, t = 0, next = randRange(60, 150), intensity = 0 },
    }
    if MPS.role ~= "client" then
        for _ = 1, 4 do spawnGroup(randomGroup(X.groupSize()), 1000) end   -- desert enemies travel in groups of 5
        world.shT = 300
        X.spawnBowmen(5)                                       -- the Stronghold starts guarded
    end
    for _ = 1, K.MAX_BOXES do spawnBox(220) end

    spawnTimer, boxTimer, endTimer, endResult = 3, 10, nil, nil
    frozenSpawnTimer = 3
    shake, hurtFlash, heartbeatTimer = 0, 0, 0
    lightning, lightningTimer, thunderDelay, snowFlash = 0, 20, nil, 0
    banner = { title = REGIONS.desert.name, sub = MPS.online and "Multiplayer - you spawned in the safe shed" or "You spawned in the safe shed. Enemies can't see you inside.",
        t = 4.5, col = { 1, 0.82, 0.45 } }
    overlay = nil
    gameState = "play"
    save.games = save.games + 1
    love.mouse.setVisible(false)
    MPS.inGame = MPS.online
    X.lastWasMP = MPS.online
    MPS.connecting = false

    addMessage("Welcome to the Frontier. Defeat the Guardian of the Hollow.", { 1, 0.85, 0.5 })
    addMessage("Press G for the keybind guide, H for the shop, P for your inventory.", { 0.8, 0.8, 0.8 })
    addMessage("The shed is safe: enemies can't see you or get inside.", { 0.7, 1, 0.75 })
    addMessage("Every 10 kills = 1 permanent CREDIT for the Credit Shop.", { 1, 0.85, 0.3 })

    -- Admin mode only lasts for the single-player game started right after entering the code
    admin.on, admin.pending, admin.input = admin.pending and not MPS.online, false, ""
    admin.hp, admin.mp, admin.stealth, admin.kills, admin.weather = false, false, false, false, "auto"
    if admin.on then
        -- admin: the old inventory - every permanent weapon you own can be equipped
        for _, id in ipairs(X.CREDIT_WEAPONS) do if PROF.owns(id) then player.owned[id] = true end end
    end
    if (opts.g1 or 0) == 1 then unlockFrozen() end
    if (opts.gs or 0) == 1 then X.unlockSwamp() end
    if (opts.gv or 0) == 1 then X.unlockVolcanic() end
    if (opts.ky or 0) == 1 then world.hasKey = true end
    if (opts.gk or 0) == 1 then world.gkDead = true end
    if (opts.g2 or 0) == 1 then unlockSpooky() end
    if admin.on then
        unlockFrozen()   -- debug mode unlocks every region gate
        X.unlockSwamp()
        X.unlockVolcanic()        -- the Hollow gate still needs the Blaze Gatekeeper's key (teleports work anyway)
        addMessage("ADMIN MODE ACTIVE - press I for the admin panel.", { 1, 0.4, 0.4 })
    end
    if MPS.role == "client" then
        addMessage("Joined " .. (MPS.hostName or "the host") .. "'s game. ESC opens the menu (the game keeps running).", { 0.6, 1, 0.7 })
    elseif MPS.role == "host" then
        addMessage("Hosting on " .. (NET.localIP() or "LAN") .. " - friends can join from the Multiplayer tab.", { 0.6, 1, 0.7 })
    end
    writeSave()
end

------------------------------------------------------------------------------
-- Game end
------------------------------------------------------------------------------
-- records per difficulty (shown on the Statistics screen)
function X.recordDiff(won)
    local d, id = PROF.data, X.D.id
    if won then
        d["wins_" .. id] = (d["wins_" .. id] or 0) + 1
        local bt = d["bestTime_" .. id] or 0
        if bt == 0 or stats.time < bt then d["bestTime_" .. id] = floor(stats.time) end
    end
    if stats.kills > (d["bestKills_" .. id] or 0) then d["bestKills_" .. id] = stats.kills end
    if X.endless and (world.wave or 0) > (d["bestWave_" .. id] or 0) then d["bestWave_" .. id] = world.wave end
end

local function finishGame(won)
    endResult = won and "win" or "lose"
    if won and MPS.role == "host" then NET.broadcast({ t = "end" }) end
    if won then
        save.wins = save.wins + 1
        if save.bestTime == 0 or stats.time < save.bestTime then save.bestTime = floor(stats.time) end
    end
    if stats.kills > save.bestKills then save.bestKills = stats.kills end
    if won and not X.endless then
        X.achieve("guardian")
        if X.D.id == "nightmare" then X.achieve("nightmare") end
    end
    X.recordDiff(won)
    writeSave()
end

------------------------------------------------------------------------------
-- Combat
------------------------------------------------------------------------------
local function showBanner(title, sub, col)
    banner = { title = title, sub = sub, t = 4.5, col = col or { 1, 0.82, 0.45 } }
end

local function gainMP(n)
    local before = me.mp
    me.mp = min(K.MP_MAX, me.mp + n)
    local gained = me.mp - before
    stats.mpEarned = stats.mpEarned + gained
    if gained > 0 then
        addText(me.x + 26, me.y - 44, "+" .. floor(gained) .. " MP", { 0.5, 0.7, 1 })
        playSfx("mana", 0.05)
    end
    if me.mp >= K.MP_MAX and not me.mpUnlocked then
        me.mpUnlocked = true
        addMessage("Mana reached 100! The Magic Book is now sold in the shop (H) for 500g.", { 0.55, 0.75, 1 })
    end
end

local function raiseAlarm(s)
    X.wsfx("alert", s.x, s.y, 0.04)
    X.wring(s.x, s.y, 750, nil, 1)
    local n = 0
    for _, b in ipairs(enemies) do
        if b.kind == "bandit" and not b.dead and dist(b.x, b.y, s.x, s.y) < 750 then
            b.state, b.awareness = "hunt", 1
            b.lastX, b.lastY, b.searchTimer = player.x, player.y, 9
            n = n + 1
        end
    end
    stats.alertsRaised = stats.alertsRaised + 1
    X.wtext(s.x, s.y - 30, "ALARM!", { 0.4, 0.8, 1 }, true)
    X.wmsg("A scout raised the alarm! " .. n .. " bandit" .. (n == 1 and "" or "s") .. " alerted.", { 0.45, 0.8, 1 })
end

local SPOT_SOUND = X.EN.spotSound or { bandit = "spot", frozen = "yeti_growl", snowman = "snowman_spot",
                     gourd = "gourd_spot", bat = "bat_screech", witch = "spot" }

local function enemyBecomesAware(e)
    if e.kind ~= "scout" then
        if e.state ~= "hunt" then X.wsfx(SPOT_SOUND[e.kind] or "spot", e.x, e.y, 0.1) end
        e.state, e.awareness = "hunt", 1
        e.lastX, e.lastY, e.searchTimer = player.x, player.y, 9
    else
        if e.alertCd <= 0 then raiseAlarm(e); e.alertCd = 10 end
        e.state, e.fleeTimer, e.awareness = "flee", 4, 1
    end
end

function unlockFrozen()
    regionUnlocked = true
    for _, w in ipairs(walls) do
        if w.kind == "gate" then w.off = true end
    end
    local gx, gy = K.WORLD_W / 2, K.WORLD_H + K.GATE_T / 2
    playSfx("gate_open")
    addShake(10)
    rings[#rings + 1] = { x = gx, y = gy, r = 0, max = 600, life = 1, col = { 0.6, 0.9, 1 } }
    spawnParticles(gx, gy, 50, { 0.8, 0.95, 1 }, 60, 320, 1.2, 4)
    if MPS.role ~= "client" then
        for _ = 1, 16 do table.insert(world.stash.frozen, randomKind("frozen")) end
        X.fillRegion("frozen", 8)
    end
    showBanner("THE FROZEN PASS IS OPEN", "Head south through the gate to reach the Frozen Wastes", { 0.6, 0.9, 1 })
    addMessage("The Frozen Pass has opened! Travel south through the gate.", { 0.6, 0.9, 1 })
end

-- the 4 gates (x, y = the middle of the gate)
function X.gates()
    local T, W, H = K.GATE_T, K.WORLD_W, K.WORLD_H
    return {
        { kind = "gate", name = "THE FROZEN PASS", x = W / 2, y = H + T / 2, open = regionUnlocked,
          kills = K.REGION_UNLOCK_KILLS, col = REGIONS.frozen.col },
        { kind = "gate2", name = "THE SWAMP GATE", x = W + T / 2, y = K.FROZEN_Y0 + H / 2, open = world.swampOpen,
          kills = K.SWAMP_UNLOCK_KILLS, col = REGIONS.swamp.col, vertical = true },
        { kind = "gate3", name = "THE VOLCANIC GATE", x = K.EAST_X + W / 2, y = K.FROZEN_Y1 + T / 2, open = world.volcOpen,
          kills = K.VOLC_UNLOCK_KILLS, col = REGIONS.volcanic.col },
        { kind = "gate4", name = "THE HOLLOW GATE", x = K.EAST_X + W / 2, y = K.VOLC_Y1 + T / 2, open = world.spookyOpen,
          kills = K.SPOOKY_UNLOCK_KILLS, col = REGIONS.spooky.col, key = true },
    }
end

function X.checkGates()
    if MPS.role == "client" then return end
    local k = world.kills
    if k >= K.REGION_UNLOCK_KILLS and not regionUnlocked then unlockFrozen() end
    if k >= K.SWAMP_UNLOCK_KILLS and not world.swampOpen then X.unlockSwamp() end
    if k >= K.VOLC_UNLOCK_KILLS and not world.volcOpen then X.unlockVolcanic() end
    if (k >= K.SPOOKY_UNLOCK_KILLS or admin.on) and world.hasKey and not world.spookyOpen and not X.keyFly then unlockSpooky(true) end
end

local function openGate(kind, col, stashRegion)
    for _, w in ipairs(walls) do
        if w.kind == kind then w.off = true end
    end
    for _, g in ipairs(X.gates()) do
        if g.kind == kind then
            rings[#rings + 1] = { x = g.x, y = g.y, r = 0, max = 600, life = 1, col = col }
            spawnParticles(g.x, g.y, 50, col, 60, 320, 1.2, 4)
        end
    end
    playSfx("gate_open", 0, 0.9)
    addShake(10)
    if MPS.role ~= "client" and stashRegion then
        for _ = 1, 16 do table.insert(world.stash[stashRegion], randomKind(stashRegion)) end
        X.fillRegion(stashRegion, 8)
    end
end

function X.unlockSwamp()
    world.swampOpen = true
    openGate("gate2", { 0.5, 0.9, 0.4 }, "swamp")
    showBanner("THE MURKY SWAMP IS OPEN", "Its gate is in the east wall of the Frozen Wastes", { 0.5, 0.9, 0.4 })
    addMessage("The Murky Swamp has opened! Its gate is in the east wall of the Frozen Wastes.", { 0.5, 0.9, 0.4 })
end

function X.unlockVolcanic()
    world.volcOpen = true
    openGate("gate3", { 1, 0.5, 0.2 }, "volcanic")
    showBanner("THE VOLCANIC RIFT IS OPEN", "Its gate lies at the far south of the Murky Swamp", { 1, 0.5, 0.2 })
    addMessage("The Volcanic Rift has opened! Its gate is at the south end of the Murky Swamp.", { 1, 0.5, 0.2 })
end

-- live = it opened right now (plays the flyover cutscene); false when joining / admin
function unlockSpooky(live)
    world.spookyOpen = true
    for _, w in ipairs(walls) do
        if w.kind == "gate4" then w.off = true end
    end
    local gx, gy = K.EAST_X + K.WORLD_W / 2, K.VOLC_Y1 + K.GATE_T / 2
    playSfx("gate_open", 0, 0.9)
    playSfx("witch_laugh", 0, 0.5)
    addShake(10)
    rings[#rings + 1] = { x = gx, y = gy, r = 0, max = 600, life = 1, col = { 0.8, 0.45, 1 } }
    spawnParticles(gx, gy, 50, { 0.75, 0.45, 1 }, 60, 320, 1.2, 4)
    if MPS.role ~= "client" then
        for _ = 1, 16 do table.insert(world.stash.spooky, randomKind("spooky")) end
        X.fillRegion("spooky", 8)
    end
    showBanner("THE HAUNTED HOLLOW AWAKENS", "Its gate lies at the far south of the Volcanic Rift", { 0.85, 0.55, 1 })
    addMessage("The Haunted Hollow is open! Its gate is at the south end of the Volcanic Rift.", { 0.85, 0.55, 1 })
    if live and X.startFlyover then X.startFlyover() end
end

local KILL_COLORS = X.EN.killColor

-- by  = id of the player who made the kill (rewards go to that player)
-- how = "frost" | "snowgrave" | "cursed" | nil (for statistics)
local function killEnemy(e, angle, by, how)
    if e.dead then return end
    e.dead = true
    world.kills = world.kills + 1          -- team progress: gates and the win condition
    local reward = floor(X.rewardFor(e.kind) * X.D.gold * (e.goldKill and 1.5 or 1) + 0.5)   -- difficulty / Golden Shooter
    local drop = rand() < 0.2              -- 20% chance to drop a loot box
    X.killFx(e.kind, e.x, e.y, e.r, angle)
    X.netKill(e, by or MPS.id, reward, drop, angle, how)
    if (by or MPS.id) == MPS.id then X.killReward(e.kind, e.x, e.y, reward, drop, how) end

    local k = world.kills
    if k == 25 or k == 50 or k == 75 or k == 125 then
        addMessage("Milestone: " .. k .. " kills! The frontier grows hostile...", { 1, 0.9, 0.3 })
    end
    if e.kind == "gourd" then world.gourdPool = (world.gourdPool or 0) + 1 end   -- the Necromancer can raise it again
    if e.kind == "goblin" and MPS.role ~= "client" then
        -- the Treasure Goblin spills its loot
        for _ = 1, 3 do spawnBox(nil, e.x + randRange(-50, 50), e.y + randRange(-50, 50)) end
        if X.EV and X.EV.k == "goblin" then X.EV = nil end
    end
    if e.kind == "slime" and MPS.role ~= "client" then
        -- Magma Slime: splits into two small slimes
        for i = 1, 2 do
            local a = (angle or rand() * 2 * pi) + (i == 1 and 1.2 or -1.2)
            local sx, sy = e.x + cos(a) * 18, e.y + sin(a) * 18
            if X.inLava(sx, sy) or not areaFree(sx - 9, sy - 9, 18, 18, 0) then sx, sy = e.x, e.y end
            local m = spawnEnemy("slimelet", nil, sx, sy)
            if m then
                m.state, m.awareness, m.spawnFade = "hunt", 1, 0.6
                m.lastX, m.lastY, m.searchTimer = e.lastX or e.x, e.lastY or e.y, 6
            end
        end
    end
    if X.BOSSES[e.kind] then X.bossDefeated(e.x, e.y) end
end

-- fx letters (from weapons.lua): b burn, u bubble, f freeze, k knockback, g golden, s silent, m execute
local function damageEnemy(e, dmg, angle, isCrit, icy, by, fx)
    if e.dead then return end
    by = by or MPS.id
    e.lastHitBy = by
    fx = fx or ""
    if e.kind == "guardian" and fx:find("x", 1, true) then
        addText(e.x, e.y - e.r - 10, "IMMUNE", { 0.75, 0.75, 0.8 })
        return
    end
    e.goldKill = fx:find("g", 1, true) ~= nil
    if fx:find("b", 1, true) then e.burnT, e.burnBy, e.burnDmg = 3, by, 3 end
    if fx:find("B", 1, true) then e.burnT, e.burnBy, e.burnDmg = 8, by, 2.5 end     -- Blaze Spell: 5 DMG/s for 8 s
    if fx:find("u", 1, true) then e.stunT, e.bubbleT, e.swingT = max(e.stunT, 2), 2, 0 end
    if fx:find("f", 1, true) then e.shockSlowT = max(e.shockSlowT, 2) end
    if fx:find("t", 1, true) then e.stunT, e.swingT, e.trapT = max(e.stunT, 4), 0, 4 end   -- Bear Trap
    if fx:find("k", 1, true) and not X.BOSSES[e.kind] then moveEntity(e, cos(angle) * 55, sin(angle) * 55) end
    if icy then dmg = dmg + 5 end           -- Cold Icicles: +5 initial damage
    if admin.on and admin.kills then dmg = max(dmg, e.hp) end   -- admin: one-hit kills
    if fx:find("m", 1, true) then dmg = max(dmg, e.hp) end      -- Guided Missile: always a kill
    local before = e.hp
    e.hp = e.hp - dmg
    e.hitFlash = 0.12
    if by == MPS.id then stats.damageDealt = stats.damageDealt + min(dmg, before) end
    moveEntity(e, cos(angle) * 7, sin(angle) * 7)
    if e.region == "spooky" then
        spawnParticles(e.x, e.y, 8, e.kind == "gourd" and { 1, 0.55, 0.12 } or { 0.45, 0.2, 0.6 }, 60, 220, 0.4, 3, angle, 0.6)
    elseif e.region == "frozen" then
        spawnParticles(e.x, e.y, 8, { 0.8, 0.92, 1 }, 60, 220, 0.4, 3, angle, 0.6)
    else
        spawnParticles(e.x, e.y, 8, { 0.65, 0.1, 0.08 }, 60, 220, 0.4, 3, angle, 0.6)
    end
    local col = icy and { 0.6, 0.9, 1 } or (isCrit and { 1, 0.75, 0.2 } or { 1, 1, 1 })
    if dmg > 0 then addText(e.x, e.y - 20, tostring(floor(dmg + 0.5)), col, isCrit)
    else addText(e.x, e.y - 20, "BURN", { 1, 0.55, 0.15 }) end
    playSfx("hit", 0.15, 0.8)
    if icy then
        if e.frostT <= 0 then e.frostTick = 2 end
        e.frostT = 10
        spawnParticles(e.x, e.y, 6, { 0.75, 0.92, 1 }, 40, 160, 0.5, 2.5)
        playSfx("freeze", 0.1, 0.6 * volAt(e.x, e.y))
    end
    if e.hp <= 0 then
        killEnemy(e, angle, by)
    elseif admin.on and admin.stealth then
        -- admin stealth: getting shot does not reveal you
    elseif fx:find("s", 1, true) and e.state == "patrol" then
        -- silent weapon (Crossbow): the target doesn't notice where it came from
    elseif e.state == "patrol" then
        enemyBecomesAware(e)
    elseif e.kind ~= "scout" then
        -- hunters turn towards whoever shot them
        local shooter = by == MPS.id and me or MPS.others[by]
        if shooter then e.lastX, e.lastY, e.searchTimer = shooter.x, shooter.y, 9 end
    end
end

-- Returns true if the hit was blocked by the player's shield
local function damagePlayer(amount, fromX, fromY, kind)
    if player.dead or endTimer then return false end
    if admin.on and admin.hp then return true end          -- admin: infinite HP
    amount = amount * X.D.dmg                             -- difficulty
    if player.bootsOn then amount = amount * 1.012 end    -- Feather boots downside: +1.2% damage
    if player.turtleT > 0 then amount = amount * 0.5 end  -- Turtle Master: 2x resistance

    local blocked = false
    if (player.weakT or 0) > 0 then amount = amount * 1.25 end   -- Shroomer WEAKNESS: +25% damage taken
    if player.blocking and kind ~= "poison" and kind ~= "lava" and kind ~= "pass" and kind ~= "meteorfall" and kind ~= "reflect" then
        local ang = atan2(fromY - player.y, fromX - player.x)
        if abs(angleDiff(player.angle, ang)) < math.rad(75) then
            blocked = true
            -- a shielded icicle shatters completely: no damage, no slow
            local absorbed = (kind == "icicle") and amount or amount * 0.8
            amount = amount - absorbed
            stats.damageBlocked = stats.damageBlocked + absorbed
            player.stamina = max(0, player.stamina - 12)
            player.staminaDelay = 0.9
            player.blockFlash = 0.15
            playSfx("block", 0.1)
            if kind == "icicle" then playSfx("shatter", 0.1) end
            local col = kind == "icicle" and { 0.75, 0.93, 1 } or { 1, 0.9, 0.5 }
            spawnParticles(player.x + cos(ang) * 22, player.y + sin(ang) * 22, 10, col, 80, 260, 0.3, 2.5, ang, 0.8)
            addText(player.x, player.y - 30, kind == "icicle" and "SHATTERED" or "BLOCKED", { 0.7, 0.85, 1 })
        end
    end
    if amount <= 0 then return true end

    if player == me then
        if (me.armorFire or 0) ~= 0 and X.FIRE_KINDS[kind] then amount = amount * (1 + me.armorFire) end   -- Fireproof Cloak
        if me.recallT then me.recallT = nil addText(me.x, me.y - 50, "Recall interrupted!", { 1, 0.5, 0.4 }) end
        -- the SHIELD takes the damage first
        if (me.shield or 0) > 0 then
            local take = min(me.shield, amount)
            me.shield = me.shield - take
            amount = amount - take
            addText(me.x + 18, me.y - 34, "-" .. floor(take + 0.5), { 0.45, 0.7, 1 })
            playSfx("block", 0.15, 0.5)
            if me.shield <= 0 then
                me.shield = 0
                playSfx("shatter", 0.1)
                addText(me.x, me.y - 52, "SHIELD BROKEN", { 0.45, 0.7, 1 }, true)
                addMessage("Your shield broke! Repair it with Metal Scraps: Inventory (P), hold your armor for 3 s.", { 0.5, 0.75, 1 })
            end
            if amount <= 0.05 then player.hitFlash = 0.08 return blocked end
        end
    end

    amount = floor(amount * 10 + 0.5) / 10
    player.hp = player.hp - amount
    stats.damageTaken = stats.damageTaken + amount
    stats.streak = 0
    player.hitFlash = 0.15
    hurtFlash = min(1, hurtFlash + amount / 45)
    addShake(4 + amount / 6)
    playSfx("hurt", 0.1)
    addText(player.x, player.y - 22, "-" .. (amount % 1 == 0 and string.format("%d", floor(amount)) or string.format("%.1f", amount)), { 1, 0.3, 0.3 })
    spawnParticles(player.x, player.y, 8, { 0.7, 0.1, 0.1 }, 50, 180, 0.4, 3)

    if player.hp <= 0 then
        player.hp = 0
        player.dead = true
        player.deathTimer = 0
        stats.deaths = stats.deaths + 1
        spawnParticles(player.x, player.y, 40, { 0.6, 0.08, 0.06 }, 60, 300, 0.9, 4)
        if MPS.online then
            -- multiplayer: you are DOWN. A teammate can revive you (hold V), otherwise you
            -- lose a heart after 60 s and respawn in the shed (no hearts left = out)
            X.goDown()
        else
            endTimer = 2.5
            finishGame(false)
            playSfx("lose")
            addMessage("You have fallen on the frontier...", { 1, 0.3, 0.3 })
        end
    end
    return blocked
end

local function enemyShoot(e, kind)
    kind = kind or "bullet"
    if kind == "bullet" then
        local a = e.angle + randRange(-0.085, 0.085)
        -- Moving or dashing targets are harder to hit
        if player.dashTime > 0 then a = a + randRange(-0.15, 0.15)
        elseif player.moving then a = a + randRange(-0.07, 0.07) end
        bullets[#bullets + 1] = {
            x = e.x + cos(a) * 22, y = e.y + sin(a) * 22,
            vx = cos(a) * 640, vy = sin(a) * 640, life = 1.3,
            owner = "enemy", kind = "bullet", dmg = randInt(18, 28), srcX = e.x, srcY = e.y,
        }
        X.netEnemyShot(bullets[#bullets])
        e.muzzle = 0.07
        playSfx("enemy_shot", 0.12, volAt(e.x, e.y))
        spawnParticles(e.x + cos(a) * 24, e.y + sin(a) * 24, 4, { 1, 0.8, 0.4 }, 40, 140, 0.15, 2.5, a, 0.4)
        return
    end

    local a = e.angle
    if kind == "icicle" then
        a = a + randRange(-0.08, 0.08)
        if player.dashTime > 0 then a = a + randRange(-0.15, 0.15)
        elseif player.moving then a = a + randRange(-0.06, 0.06) end
        bullets[#bullets + 1] = {
            x = e.x + cos(a) * 20, y = e.y + sin(a) * 20,
            vx = cos(a) * 560, vy = sin(a) * 560, life = 1.4,
            owner = "enemy", kind = "icicle", dmg = 7, srcX = e.x, srcY = e.y,
        }
        X.netEnemyShot(bullets[#bullets])
        playSfx("frozen_shot", 0.12, volAt(e.x, e.y))
        spawnParticles(e.x + cos(a) * 20, e.y + sin(a) * 20, 5, { 0.75, 0.93, 1 }, 30, 120, 0.25, 2, a, 0.5)
    elseif kind == "potion" then
        -- lobbed purple poison potion: shatters on hit or where it lands
        local d = min(540, dist(e.x, e.y, player.x, player.y))
        a = atan2(player.y - e.y, player.x - e.x) + randRange(-0.06, 0.06)
        bullets[#bullets + 1] = {
            x = e.x + cos(a) * 18, y = e.y + sin(a) * 18,
            vx = cos(a) * 380, vy = sin(a) * 380, life = 2, age = 0, land = d / 380,
            owner = "enemy", kind = "potion", dmg = 0, srcX = e.x, srcY = e.y,
        }
        X.netEnemyShot(bullets[#bullets])
        playSfx("potion_throw", 0.1, volAt(e.x, e.y))
    elseif kind == "arrow" then
        a = a + randRange(-0.05, 0.05)
        if player.dashTime > 0 then a = a + randRange(-0.15, 0.15)
        elseif player.moving then a = a + randRange(-0.05, 0.05) end
        bullets[#bullets + 1] = {
            x = e.x + cos(a) * 20, y = e.y + sin(a) * 20,
            vx = cos(a) * 700, vy = sin(a) * 700, life = 1.2,
            owner = "enemy", kind = "arrow", dmg = 20, srcX = e.x, srcY = e.y,
        }
        X.netEnemyShot(bullets[#bullets])
        playSfx("bow", 0.12, volAt(e.x, e.y))
    else -- snowball
        a = a + randRange(-0.1, 0.1)
        bullets[#bullets + 1] = {
            x = e.x + cos(a) * 22, y = e.y + sin(a) * 22,
            vx = cos(a) * 430, vy = sin(a) * 430, life = 1.5, age = 0,
            owner = "enemy", kind = "snowball", dmg = 3, srcX = e.x, srcY = e.y,
        }
        X.netEnemyShot(bullets[#bullets])
        playSfx("snowball_throw", 0.15, volAt(e.x, e.y))
    end
    e.muzzle = 0.07
    e.throwAnim = 0.25
end

-- blast weapons (the Guardian of the Hollow is immune to them)
X.BLAST = { rpg = true, meteor = true, blackhole = true, cannon = true, bubble = true }

local function tryShoot(fresh)
    local p = player
    local w = WEAPONS[p.weapon]
    if p.unarmed or X.hb.mode ~= "gun" then return end
    if p.fireCd > 0 then return end
    if w.spinup and (p.spin or 0) < 1 then return end     -- the Minigun has to spin up first
    if p.ammo <= 0 and not w.noAmmo then
        if fresh then
            playSfx("empty")
            addText(p.x, p.y - 30, "NO AMMO", { 1, 0.5, 0.3 })
            p.fireCd = 0.3
        end
        return
    end
    -- universal Ammo (the Spray Gun only uses one Ammo every 3 shots; the Battle Axe none)
    p.ammoFrac = p.ammoFrac + (w.noAmmo and 0 or (w.ammoCost or 1))
    while p.ammoFrac >= 0.999 and p.ammo > 0 do
        p.ammo = p.ammo - 1
        p.ammoFrac = p.ammoFrac - 1
    end
    if p.ammoFrac < 0 then p.ammoFrac = 0 end
    p.fireCd = w.rate
    stats.shotsFired = stats.shotsFired + 1

    local icy = p.iciclesT > 0
    local dmg = randInt(w.min, w.max)
    local crit = dmg >= w.min + (w.max - w.min) * 0.85
    local shot = { hit = false, dmg = dmg, crit = crit, icy = icy }
    local mwx, mwy = X.mouseWorld()
    local aim = dist(p.x, p.y, mwx, mwy)
    shot.fx = w.fx
    if X.BLAST[p.weapon] then shot.fx = (shot.fx or "") .. "x" end   -- blast weapon: the Guardian is immune
    -- levels: +5% gun / melee damage per level
    shot.dmg = floor(shot.dmg * (1 + 0.05 * (p.level or 0)) + 0.5)
    -- Blaze Spell: flame bullets with no hit damage that set enemies on fire
    if (p.blazeT or 0) > 0 then shot.dmg, shot.fx, shot.blaze = 0, (w.fx or "") .. "B", true end
    X.fireWeapon(p.weapon, p.x, p.y, p.angle, icy, "player", shot, aim)
    if MPS.online then X.netShot(p.weapon, p.x, p.y, p.angle, icy, aim) end

    p.muzzle = 0.06
    p.recoil = 1
    addShake(w.shake)
    playSfx(w.sound, 0.08)
    if icy then playSfx("icicle_shot", 0.1) end
    local mx, my = p.x + cos(p.angle) * 26, p.y + sin(p.angle) * 26
    local flash = w.kind == "laser" and { 1, 0.35, 0.45 } or (icy and { 0.7, 0.92, 1 } or { 1, 0.85, 0.4 })
    spawnParticles(mx, my, w.pellets > 1 and 12 or 5, flash, 60, 220, 0.12, 3, p.angle, 0.5)
    if w.kind ~= "laser" then
        spawnParticles(mx, my, w.pellets > 1 and 6 or 2, { 0.6, 0.6, 0.6 }, 20, 60, 0.6, 5, p.angle, 0.6, 2)
        -- ejected shell casing
        spawnParticles(p.x, p.y, 1, { 0.85, 0.7, 0.3 }, 80, 140, 0.5, 2, p.angle + pi / 2, 0.3, 6)
    end
    if w.kick > 0 then moveEntity(p, -cos(p.angle) * w.kick * 0.08, -sin(p.angle) * w.kick * 0.08) end
end

------------------------------------------------------------------------------
-- Player actions
------------------------------------------------------------------------------
local function useBandage()
    if player.bandages <= 0 then playSfx("deny") addMessage("No bandages left.", { 1, 0.5, 0.4 }) return end
    if player.hp >= player.maxHp then playSfx("deny") addMessage("Already at full health.", { 0.8, 0.8, 0.8 }) return end
    local healed = min(50, player.maxHp - player.hp)
    player.hp = player.hp + healed
    player.bandages = player.bandages - 1
    stats.bandagesUsed = stats.bandagesUsed + 1
    playSfx("heal")
    spawnParticles(player.x, player.y, 18, { 0.4, 1, 0.5 }, 30, 120, 0.8, 3)
    addText(player.x, player.y - 30, "+" .. floor(healed) .. " HP", { 0.4, 1, 0.5 }, true)
end

local function equipWeapon(id)
    if not WEAPONS[id] then return end
    if not player.owned[id] then
        playSfx("deny")
        if WEAPONS[id].price then
            addMessage("The " .. WEAPONS[id].name .. " is a permanent weapon: get it in the Credit Shop (Multiplayer tab).", { 1, 0.5, 0.4 })
        else
            addMessage("You don't own the " .. WEAPONS[id].name .. " yet. Buy it at the shop (H).", { 1, 0.5, 0.4 })
        end
        return
    end
    if me.slots and admin.on then           -- admin's old inventory: the gun goes into the selected slot
        me.slots[X.hb.gsel] = id
        X.hb.mode = "gun"
        me.unarmed = false
    end
    if player.weapon == id then return end
    player.weapon = id
    player.fireCd = 0.35
    player.spin = 0
    playSfx("equip")
    addMessage(WEAPONS[id].name .. " equipped.", { 0.9, 0.9, 0.7 })
end

X.useBandage = useBandage
local function toggleBoots()
    if not player.owned.boots then playSfx("deny") addMessage("You don't own Feather Boots yet.", { 1, 0.5, 0.4 }) return end
    player.bootsOn = not player.bootsOn
    playSfx("equip")
    addMessage(player.bootsOn and "Feather Boots equipped (+35% speed, +1.2% damage taken)." or "Feather Boots removed.", { 0.9, 0.9, 0.7 })
end

X.toggleBoots = toggleBoots
local function buyItem(item)
    if item.once and player.owned[item.id] then playSfx("deny") return end
    if item.id == "vest" and me.armorSet and me.armorSet.chest then
        playSfx("deny")
        addMessage("Your CHEST slot is taken by the " .. X.ARMOR[me.armorSet.chest].name .. " (choose a different loadout to wear the Vest).", { 1, 0.5, 0.4 })
        return
    end
    if item.id == "shotgun" and not admin.on and not X.freeGunSlot() then
        playSfx("deny")
        addMessage("No free weapon slot - store a weapon in the chest in the shed first.", { 1, 0.5, 0.4 })
        return
    end
    if item.needsMP and not player.mpUnlocked then
        playSfx("lock")
        addMessage("The Magic Book unlocks once your mana reaches 100 MP.", { 0.6, 0.7, 1 })
        return
    end
    if player.gold < item.price then
        playSfx("deny")
        addMessage("Not enough gold for " .. item.name .. " (" .. item.price .. "g).", { 1, 0.5, 0.4 })
        return
    end
    player.gold = player.gold - item.price
    stats.goldSpent = stats.goldSpent + item.price
    stats.itemsBought = stats.itemsBought + 1
    playSfx("buy")
    if item.id == "shotgun" then
        player.owned.shotgun = true
        if not admin.on then X.giveGun("shotgun") end
        player.ammo = player.ammo + 12
        addMessage("Shotgun purchased! Open the Inventory (P) to equip it.", { 1, 0.85, 0.4 })
    elseif item.id == "boots" then
        player.owned.boots = true
        player.bootsOn = true
        if me.armorSet then me.armorSet.feet = "boots" end
        addMessage("Feather Boots purchased and equipped. Toggle them in the Inventory (P).", { 1, 0.85, 0.4 })
    elseif item.id == "bandage" then
        player.bandages = player.bandages + 1
        addMessage("Bandage purchased.", { 1, 0.85, 0.4 })
    elseif item.id == "ammo" then
        player.ammo = player.ammo + 40
        addMessage("Ammo crate purchased: +40 Ammo.", { 1, 0.85, 0.4 })
    elseif item.id == "book" then
        player.owned.book = true
        player.hasBook = true
        playSfx("cast")
        showBanner("MAGIC BOOK ACQUIRED", "Open the spellbook (B) and click a spell to cast it", { 0.6, 0.75, 1 })
        addMessage("Magic Book purchased! Open the spellbook (B) and click a spell to cast it.", { 0.6, 0.75, 1 })
    elseif item.id == "vest" then
        player.owned.vest = true
        if me.armorSet then me.armorSet.chest = "vest" end
        player.maxHp = player.maxHp + 25
        player.hp = min(player.maxHp, player.hp + 25)
        addMessage("Reinforced Vest purchased: +25 max HP.", { 1, 0.85, 0.4 })
    end
end

local function tryDash()
    if player.dead or player.dashCd > 0 or player.stamina < 25 then
        if player.stamina < 25 and not player.dead then playSfx("deny", 0, 0.5) end
        return
    end
    local ix, iy = 0, 0
    if love.keyboard.isDown("w") then iy = iy - 1 end
    if love.keyboard.isDown("s") then iy = iy + 1 end
    if love.keyboard.isDown("a") then ix = ix - 1 end
    if love.keyboard.isDown("d") then ix = ix + 1 end
    if ix == 0 and iy == 0 then ix, iy = cos(player.angle), sin(player.angle) end
    local l = sqrt(ix * ix + iy * iy)
    player.dashDx, player.dashDy = ix / l, iy / l
    player.dashTime, player.iframes, player.dashCd = 0.17, 0.22, 0.55
    player.stamina = player.stamina - 25
    player.staminaDelay = 0.8
    stats.dashes = stats.dashes + 1
    playSfx("dash", 0.1)
end

local spellUnlocked, castSpell, updateSnowgraves
do
------------------------------------------------------------------------------
-- Magic: spells (cast with keys 1-4)
------------------------------------------------------------------------------
function spellUnlocked(sp)
    if sp.source == "book" then return player.hasBook end
    if sp.source == "witch" then return player.hasCursed end
    if sp.source == "gatekeeper" then return player.hasBlaze end
    return player.hasIceShock
end

-- Area spells are resolved by the host in multiplayer
local function areaSpell(kind)
    -- the Gatekeeper's FIRE SHIELD throws your spell back at YOU
    local g = X.shieldedGK()
    local R = ({ iceshock = 320, snowgrave = 450, cursed = 1000 })[kind]
    if g and R and dist(g.x, g.y, player.x, player.y) <= R + g.r then
        if kind == "iceshock" then
            player.slowT = 8
            X.reflectToMe(0, g.x, g.y, "ICESHOCK DEFLECTED - SLOWED!")
        else
            X.reflectToMe(kind == "snowgrave" and 150 or 200, g.x, g.y, (kind == "snowgrave" and "SNOWGRAVE" or "CURSED SPELL") .. " DEFLECTED!")
        end
    end
    if MPS.role == "client" then
        NET.toHost({ t = "spell", s = kind, x = floor(player.x), y = floor(player.y) })
        return nil
    end
    return X.spellArea(kind, player.x, player.y, MPS.id)
end

local function castIceShock()
    local n = areaSpell("iceshock")
    playSfx("iceshock")
    addShake(6)
    rings[#rings + 1] = { x = player.x, y = player.y, r = 0, max = 320, life = 0.6, maxLife = 0.6, col = { 0.6, 0.9, 1 } }
    spawnParticles(player.x, player.y, 40, { 0.75, 0.95, 1 }, 150, 420, 0.5, 3)
    addMessage(n and ("IceShock! " .. n .. " enem" .. (n == 1 and "y" or "ies") .. " stunned.") or "IceShock!", { 0.6, 0.9, 1 })
end

function castSpell(id)
    local sp = SPELL_BY_ID[id]
    if not sp or player.dead or endTimer then return end
    if not spellUnlocked(sp) then
        playSfx("lock")
        if sp.source == "book" then
            addMessage(sp.name .. " requires the Magic Book (Shop - H, unlocks at 100 MP).", { 0.6, 0.7, 1 })
        elseif sp.source == "witch" then
            addMessage("THE CURSED SPELL can only be taken from a Witch (15% drop) in the Haunted Hollow.", { 0.9, 0.3, 0.35 })
        else
            addMessage("IceShock is sealed inside the FROZEN CHEST, deep in the Frozen Wastes.", { 0.6, 0.9, 1 })
        end
        return
    end
    if player.spellCd > 0 then return end
    if id == "snowgrave" and #snowgraves > 0 then playSfx("deny") return end
    player.spellCds = player.spellCds or {}
    if id ~= "cursed" and (player.spellCds[id] or 0) > 0 then
        playSfx("deny")
        addText(player.x, player.y - 34, sp.short .. " recharging " .. formatTime(player.spellCds[id]), { 0.6, 0.7, 1 })
        return
    end
    if id == "cursed" then
        if player.cursedT > 0 then return end
        if player.cursedCd > 0 then
            playSfx("deny")
            addMessage("THE CURSED SPELL is recharging (" .. formatTime(player.cursedCd) .. ").", { 0.9, 0.3, 0.35 })
            return
        end
        if player.hp <= sp.hpCost and not (admin.on and admin.hp) then
            playSfx("deny")
            addMessage("THE CURSED SPELL demands " .. sp.hpCost .. " HP - you are too weak.", { 0.9, 0.3, 0.35 })
            return
        end
    end
    if player.mp < sp.cost then
        playSfx("deny")
        addText(player.x, player.y - 34, "NOT ENOUGH MP", { 0.5, 0.65, 1 })
        addMessage(sp.name .. " needs " .. sp.cost .. " MP (you have " .. floor(player.mp) .. ").", { 0.5, 0.65, 1 })
        return
    end
    player.mp = player.mp - sp.cost
    player.spellCd = 0.5
    if id ~= "cursed" then player.spellCds[id] = sp.cooldown end
    stats.castIds = stats.castIds or {}
    stats.castIds[id] = true
    if X.achieve then X.achieveCheck() end
    stats.spellsCast = stats.spellsCast + 1
    playSfx("cast", 0.05)
    if id == "turtle" then
        player.turtleT = sp.duration
        playSfx("turtle")
        spawnParticles(player.x, player.y, 20, { 0.4, 0.85, 0.45 }, 40, 160, 0.6, 3)
        addText(player.x, player.y - 34, "TURTLE MASTER", { 0.45, 0.9, 0.5 }, true)
    elseif id == "icicles" then
        player.iciclesT = sp.duration
        playSfx("icicle_cast")
        spawnParticles(player.x, player.y, 24, { 0.7, 0.92, 1 }, 40, 200, 0.7, 3)
        addText(player.x, player.y - 34, "COLD ICICLES", { 0.6, 0.9, 1 }, true)
    elseif id == "snowgrave" then
        snowgraves[#snowgraves + 1] = { t = 3, maxT = 3 }
        playSfx("rumble")
        addMessage("SnowGRAVE invoked... the ground begins to tremble!", { 0.85, 0.92, 1 })
    elseif id == "iceshock" then
        castIceShock()
    elseif id == "blaze" then
        player.blazeT = sp.duration
        playSfx("blaze_cast")
        spawnParticles(player.x, player.y, 30, { 1, 0.5, 0.1 }, 40, 220, 0.7, 3.5)
        addText(player.x, player.y - 34, "BLAZE SPELL", { 1, 0.55, 0.15 }, true)
    elseif id == "cursed" then
        if not (admin.on and admin.hp) then player.hp = player.hp - sp.hpCost end
        player.cursedT, player.blindT, player.cursedCd = 2, 2, sp.cooldown
        playSfx("cursed_charge")
        addMessage("THE CURSED SPELL... darkness falls.", { 0.9, 0.3, 0.35 })
    end
end

local function detonateSnowgrave()
    local n = areaSpell("snowgrave")
    playSfx("snowgrave")
    snowFlash = 1
    addShake(16)
    rings[#rings + 1] = { x = player.x, y = player.y, r = 0, max = 450, life = 0.8, maxLife = 0.8, col = { 1, 1, 1 } }
    rings[#rings + 1] = { x = player.x, y = player.y, r = 0, max = 650, life = 1.2, maxLife = 1.2, col = { 0.7, 0.9, 1 } }
    spawnParticles(player.x, player.y, 140, { 0.92, 0.97, 1 }, 100, 650, 1.4, 5, nil, nil, 1.5)
    addMessage(n and ("SnowGRAVE! The blizzard buried " .. n .. " enem" .. (n == 1 and "y" or "ies") .. ".") or "SnowGRAVE! The blizzard erupts!", { 0.85, 0.95, 1 })
end

local function detonateCursed()
    local n = areaSpell("cursed")
    playSfx("glass_blast")
    playSfx("glass_blast", 0.05)
    playSfx("shatter", 0, 1)
    snowFlash = 1
    shake = 0
    addShake(18)
    rings[#rings + 1] = { x = player.x, y = player.y, r = 0, max = 1000, life = 1, maxLife = 1, col = { 1, 1, 1 } }
    rings[#rings + 1] = { x = player.x, y = player.y, r = 0, max = 700, life = 0.7, maxLife = 0.7, col = { 0.9, 0.2, 0.3 } }
    for _ = 1, 160 do
        local a, sp = rand() * 2 * pi, randRange(200, 900)
        particles[#particles + 1] = { x = player.x, y = player.y, vx = cos(a) * sp, vy = sin(a) * sp, life = 1.2, maxLife = 1.2,
            color = rand() < 0.5 and { 0.85, 0.95, 1 } or { 1, 1, 1 }, size = randRange(2, 4), drag = 2 }
    end
    addMessage(n and ("THE CURSED SPELL shattered " .. n .. " enem" .. (n == 1 and "y" or "ies") .. "!") or "THE CURSED SPELL shatters everything around you!", { 0.95, 0.3, 0.35 })
end

function updateSnowgraves(dt)
    if player.cursedT > 0 then
        player.cursedT = player.cursedT - dt
        if player.cursedT <= 0 then detonateCursed() end
    end
    for i = #snowgraves, 1, -1 do
        local s = snowgraves[i]
        s.t = s.t - dt
        shake = max(shake, 2 + (1 - s.t / s.maxT) * 7)
        if rand() < 0.7 then
            local a, d = rand() * 2 * pi, rand() * 450
            particles[#particles + 1] = {
                x = player.x + cos(a) * d, y = player.y + sin(a) * d, vx = randRange(-10, 10), vy = randRange(-70, -30),
                life = 0.9, maxLife = 0.9, color = { 0.9, 0.96, 1 }, size = randRange(2, 4), drag = 0.5,
            }
        end
        if s.t <= 0 then
            table.remove(snowgraves, i)
            detonateSnowgrave()
        end
    end
end
end

------------------------------------------------------------------------------
-- Update: player
------------------------------------------------------------------------------
local function mouseWorld()
    local mx, my = love.mouse.getPosition()
    local sw, sh = lg.getDimensions()
    return mx + cam.x - sw / 2, my + cam.y - sh / 2
end
X.mouseWorld = mouseWorld

local function updatePlayer(dt)
    local p = player
    p.hitFlash = max(0, p.hitFlash - dt)
    p.muzzle = max(0, p.muzzle - dt)
    p.recoil = max(0, p.recoil - dt * 8)
    p.blockFlash = max(0, p.blockFlash - dt)
    p.hpLag = p.hpLag > p.hp and max(p.hp, p.hpLag - 40 * dt) or p.hp
    p.turtleT = max(0, p.turtleT - dt)
    p.iciclesT = max(0, p.iciclesT - dt)
    p.chillT = max(0, p.chillT - dt)
    p.quakeT = max(0, (p.quakeT or 0) - dt)
    p.slowT = max(0, (p.slowT or 0) - dt)
    p.weakT = max(0, (p.weakT or 0) - dt)
    p.fungusT = max(0, (p.fungusT or 0) - dt)
    p.serpSlowT = max(0, (p.serpSlowT or 0) - dt)
    p.spellCd = max(0, p.spellCd - dt)
    p.cursedCd = max(0, p.cursedCd - dt)
    p.blazeT = max(0, (p.blazeT or 0) - dt)
    for k, v in pairs(p.spellCds or {}) do p.spellCds[k] = max(0, v - dt) end
    p.blindT = max(0, p.blindT - dt)
    p.spookT = max(0, p.spookT - dt)
    if p.dead then
        p.deathTimer = p.deathTimer + dt
        if MPS.online and p.respawnT > 0 then
            p.respawnT = p.respawnT - dt
            if p.respawnT <= 0 then X.downExpired() end
        end
        return
    end
    local inMenu = overlay == "pause" or X.chat.open   -- other overlays (shop, inventory...) no longer freeze you

    -- Witch potion puddles linger for 30 s: stepping in one poisons you again
    if p.region == "spooky" and not (admin.on and admin.hp) and p.iframes <= 0 then
        for _, d in ipairs(decals) do
            if d.kind == "puddle" and d.life > 0.5 and abs(d.x - p.x) < 50 and abs(d.y - p.y) < 40
               and ((d.x - p.x) / (d.r * 1.4 + p.r * 0.5)) ^ 2 + ((d.y - p.y) / (d.r + p.r * 0.5)) ^ 2 <= 1 then
                if p.poisonT <= 0 then
                    p.poisonTick = 1
                    playSfx("poison", 0.1)
                    addText(p.x, p.y - 40, "POISONED", { 0.75, 0.35, 1 }, true)
                end
                p.poisonT = max(p.poisonT, 5)
                break
            end
        end
    end
    -- Witch poison: 2 damage per second for 5 seconds
    if p.poisonT > 0 then
        p.poisonT = p.poisonT - dt
        p.poisonTick = p.poisonTick - dt
        if p.poisonTick <= 0 then
            p.poisonTick = 1
            damagePlayer(2, p.x, p.y, "poison")
            spawnParticles(p.x, p.y, 5, { 0.7, 0.3, 1 }, 15, 50, 0.7, 3, -pi / 2, 0.8, 1)
        end
        if p.dead then return end
    end

    local mx, my = mouseWorld()
    if not overlay then p.angle = atan2(my - p.y, mx - p.x) end

    local ix, iy = 0, 0
    if not inMenu then
        if love.keyboard.isDown("w") then iy = iy - 1 end
        if love.keyboard.isDown("s") then iy = iy + 1 end
        if love.keyboard.isDown("a") then ix = ix - 1 end
        if love.keyboard.isDown("d") then ix = ix + 1 end
    end
    if ix ~= 0 and iy ~= 0 then ix, iy = ix * 0.7071, iy * 0.7071 end

    local speed = p.baseSpeed * (p.bootsOn and 1.35 or 1) * (1 + 0.05 * (p.level or 0))   -- +5% speed per level
    speed = speed * (1 + (p.armorSpeed or 0))                                              -- armor
    speed = speed * (1 + (WEAPONS[p.weapon].mod or 0))   -- bigger weapons are harder to move with
    if p.turtleT > 0 then speed = speed * 0.5 end    -- Turtle Master: -50% speed
    if p.chillT > 0 then speed = speed * 0.85 end    -- hit by a Frozen's icicle: -15% speed
    if p.quakeT > 0 then speed = speed * 0.9 end     -- the Guardian's earthquake: -10% speed
    if p.slowT > 0 then speed = speed * 0.7 end      -- Shroomer SLOWNESS
    if p.serpSlowT > 0 then speed = speed * 0.9 end  -- scorched by a Lava Serpent
    p.inMurk = X.inMurk(p.x, p.y) ~= nil
    if p.inMurk and not p.waders then speed = speed * 0.8 end   -- murky swamp water: -20% speed (not with Swamp Waders)
    -- lava burns: 10 DMG per second
    if X.inLava(p.x, p.y) and p.dashTime <= 0 then
        p.lavaTick = (p.lavaTick or 0) - dt
        if p.lavaTick <= 0 then
            p.lavaTick = 0.5
            damagePlayer(5, p.x, p.y, "lava")
            spawnParticles(p.x, p.y, 8, { 1, 0.5, 0.1 }, 30, 140, 0.5, 3, -pi / 2, 0.8)
            if p.dead then return end
        end
    else
        p.lavaTick = 0
    end
    p.blocking = not overlay and love.mouse.isDown(2) and p.stamina > 0 and p.dashTime <= 0
    if p.blocking then
        speed = speed * 0.45
        p.stamina = max(0, p.stamina - 9 * dt)
        p.staminaDelay = 0.6
    end

    p.onIce = isOnLake(p.x, p.y)
    local ox, oy = p.x, p.y

    -- Knockback (snowballs, branches)
    if abs(p.kbx) + abs(p.kby) > 5 then
        moveEntity(p, p.kbx * dt, p.kby * dt)
        local d = max(0, 1 - 7 * dt)
        p.kbx, p.kby = p.kbx * d, p.kby * d
    else
        p.kbx, p.kby = 0, 0
    end

    if p.dashTime > 0 then
        p.dashTime = p.dashTime - dt
        moveEntity(p, p.dashDx * speed * 3.4 * dt, p.dashDy * speed * 3.4 * dt)
        p.vx, p.vy = p.dashDx * speed, p.dashDy * speed
        particles[#particles + 1] = { x = p.x, y = p.y, vx = 0, vy = 0, life = 0.25, maxLife = 0.25,
            color = { 0.6, 0.9, 1 }, size = p.r * 0.9, drag = 0, ghost = true }
    else
        local tvx, tvy = ix * speed, iy * speed
        if p.onIce then
            -- frozen lakes are slippery: velocity changes slowly
            local k = min(1, dt * 1.8)
            p.vx, p.vy = lerp(p.vx, tvx, k), lerp(p.vy, tvy, k)
        else
            p.vx, p.vy = tvx, tvy
        end
        moveEntity(p, p.vx * dt, p.vy * dt)
    end
    local moved = dist(ox, oy, p.x, p.y)
    stats.distance = stats.distance + moved
    p.moving = moved > speed * dt * 0.3
    p.walkAnim = p.walkAnim + moved * 0.07
    if moved > 1 and rand() < 0.15 then
        local col = p.region == "frozen" and (p.onIce and { 0.85, 0.95, 1 } or { 0.95, 0.97, 1 }) or { 0.75, 0.65, 0.48 }
        spawnParticles(p.x, p.y + p.r * 0.6, 1, col, 5, 25, 0.5, 3, nil, nil, 3)
    end

    p.dashCd = max(0, p.dashCd - dt)
    p.iframes = max(0, p.iframes - dt)
    p.fireCd = max(0, p.fireCd - dt)
    if p.staminaDelay > 0 then p.staminaDelay = p.staminaDelay - dt
    else p.stamina = min(p.maxStamina, p.stamina + 26 * dt * ((p.tonicT or 0) > 0 and 1.5 or 1)) end

    local holding = not overlay and love.mouse.isDown(1) and not p.blocking
    local wcur = WEAPONS[p.weapon]
    if wcur.spinup then
        if holding then
            if (p.spin or 0) < 1 and rand() < 0.3 then playSfx("minigun", 0.3, 0.25) end
            p.spin = min(1, (p.spin or 0) + dt / wcur.spinup)
        else
            p.spin = max(0, (p.spin or 0) - dt * 2)
        end
    end
    if holding then tryShoot(false) end

    -- Loot boxes
    for i = #boxes, 1, -1 do
        local b = boxes[i]
        if dist(b.x, b.y, p.x, p.y) < b.r + p.r + 4 then
            table.remove(boxes, i)
            stats.boxesOpened = stats.boxesOpened + 1
            playSfx("crate", 0.1)
            spawnParticles(b.x, b.y, 16, { 0.6, 0.42, 0.22 }, 60, 200, 0.6, 4)
            local roll = rand()
            if roll < 1 / 3 then
                p.ammo = p.ammo + 20
                addText(b.x, b.y - 20, "+20 AMMO", { 1, 0.85, 0.3 }, true)
                addMessage("Loot box: +20 Ammo.", { 1, 0.85, 0.3 })
            elseif roll < 2 / 3 then
                p.scraps = (p.scraps or 0) + 2
                addText(b.x, b.y - 20, "+2 METAL SCRAPS", { 0.6, 0.75, 1 }, true)
                addMessage("Loot box: 2 Metal Scraps (repair your armor in the Inventory - P).", { 0.6, 0.75, 1 })
            else
                p.bandages = p.bandages + 1
                addText(b.x, b.y - 20, "+1 BANDAGE", { 0.4, 1, 0.5 }, true)
                addMessage("Loot box: found a Bandage (use it in Inventory - P).", { 0.4, 1, 0.5 })
            end
            playSfx("pickup")
        end
    end

    -- The FROZEN CHEST
    if frozenChest and not frozenChest.opened and dist(p.x, p.y, frozenChest.x, frozenChest.y) < p.r + 28 then
        frozenChest.opened = true
        p.hasIceShock = true
        stats.chestFound = true
        playSfx("chest_open")
        addShake(5)
        spawnParticles(frozenChest.x, frozenChest.y, 60, { 0.7, 0.9, 1 }, 60, 300, 1.2, 4)
        spawnParticles(frozenChest.x, frozenChest.y, 30, { 0.75, 0.55, 1 }, 40, 200, 1.4, 3)
        showBanner("FROZEN CHEST OPENED", "Spell learned: ICESHOCK  -  cast it from the spellbook (B)", { 0.7, 0.9, 1 })
        addMessage("You found the FROZEN CHEST! IceShock learned (spellbook B, 50 MP).", { 0.7, 0.9, 1 })
    end

    -- Entering a new region
    local reg = regionAt(p.x, p.y)
    if reg ~= p.region then
        p.region = reg
        switchRegion(reg)   -- unload enemies of empty regions, spawn the new region's back
        local R = REGIONS[reg]
        showBanner(R.name, R.sub, R.col)
        world.visited = world.visited or {}
        world.visited[reg] = true
        local nv = 0
        for _ in pairs(world.visited) do nv = nv + 1 end
        if nv >= 5 then X.achieve("explorer") end
        playSfx("region")
        if reg == "spooky" and not stats.reachedSpooky then
            stats.reachedSpooky = true
            playSfx("witch_laugh", 0, 0.6)
            addMessage("You entered the Haunted Hollow. Something is watching you...", { 0.85, 0.55, 1 })
        end
        if reg == "frozen" and not stats.reachedFrozen then
            stats.reachedFrozen = true
            addMessage("You entered the Frozen Wastes. Careful: frozen lakes are slippery!", { 0.7, 0.9, 1 })
        end
    end

    -- Low health heartbeat
    if p.hp < 30 then
        heartbeatTimer = heartbeatTimer - dt
        if heartbeatTimer <= 0 then playSfx("heartbeat") heartbeatTimer = 0.9 end
    end
end

------------------------------------------------------------------------------
-- Update: enemies (AI)
------------------------------------------------------------------------------
local updateEnemy
do
local function moveDir(e, dx, dy, speed, dt)
    local l = sqrt(dx * dx + dy * dy)
    if l < 0.001 then return 0 end
    dx, dy = dx / l, dy / l
    if e.avoidTimer > 0 then
        local a = atan2(dy, dx) + e.avoid * pi * 0.45
        dx, dy = cos(a), sin(a)
        e.avoidTimer = e.avoidTimer - dt
    end
    local step = speed * (e.speedMul or 1) * dt
    local ox, oy = e.x, e.y
    moveEntity(e, dx * step, dy * step)
    local moved = dist(ox, oy, e.x, e.y)
    if moved < step * 0.35 then
        e.stuck = e.stuck + dt
        if e.stuck > 0.12 then
            if e.avoidTimer > 0 then e.avoid = -e.avoid end
            e.avoidTimer, e.stuck = 0.6, 0
        end
    else
        e.stuck = 0
    end
    e.walkAnim = e.walkAnim + moved * 0.08
    return moved
end
X.moveDir = moveDir

local function steer(e, tx, ty, speed, dt)
    local d = dist(e.x, e.y, tx, ty)
    if d < 10 then return true end
    moveDir(e, tx - e.x, ty - e.y, speed, dt)
    return false
end

local function patrol(e, dt, toP)
    if e.awareness > 0.25 and e.canSee then
        -- Suspicious: stop and stare at the player
        e.angle = turnTowards(e.angle, toP, 3 * dt)
        return
    end
    if e.waitTimer > 0 then
        e.waitTimer = e.waitTimer - dt
        e.angle = e.angle + sin(menuTime * 1.3 + e.homeX) * dt * 1.2
        return
    end
    local arrived = steer(e, e.px, e.py, e.speed, dt)
    e.angle = turnTowards(e.angle, atan2(e.py - e.y, e.px - e.x), 4 * dt)
    if arrived or e.stuck > 0.1 and rand() < 0.02 then
        e.waitTimer = randRange(0.8, 2.5)
        pickPatrolTarget(e)
    end
end

-- Hunter lost sight: walk to the last known position and look around
-- Bats fly straight over walls
local function batFly(e, dx, dy, speed, dt)
    local reg = REGIONS[e.region]
    local ox, oy = e.x, e.y
    e.x = clamp(e.x + dx * speed * e.speedMul * dt, reg.x0 + e.r, reg.x1 - e.r)
    e.y = clamp(e.y + dy * speed * e.speedMul * dt, reg.y0 + e.r, reg.y1 - e.r)
    -- not even bats can get into the shed
    local z = X.shedZone
    if z and rectOverlap(e.x - e.r, e.y - e.r, 2 * e.r, 2 * e.r, z.x, z.y, z.w, z.h) then e.x, e.y = ox, oy end
end

-- Gourd attack side effect: jumpscare + 3s of reduced visibility
function X.spookPlayer()
    player.spookT = 3
    stats.spooked = stats.spooked + 1
    playSfx("jumpscare")
    playSfx("spooked_song")
    addShake(10)
    addText(player.x, player.y - 44, "SPOOKED!", { 1, 0.5, 0.1 }, true)
end

local function searchLastKnown(e, dt)
    local arrived = steer(e, e.lastX, e.lastY, e.huntSpeed, dt)
    if arrived then e.angle = e.angle + dt * 2.2
    else e.angle = turnTowards(e.angle, atan2(e.lastY - e.y, e.lastX - e.x), 6 * dt) end
    e.searchTimer = e.searchTimer - dt
    if e.searchTimer <= 0 then
        e.state, e.awareness = "patrol", 0.2
        e.homeX, e.homeY = e.x, e.y
        pickPatrolTarget(e)
        addText(e.x, e.y - 30, "?", { 1, 0.9, 0.3 })
    end
end

-- a straight enemy projectile (mushrooms, toad spit, flames...)
X.SHOT_SND = { mushroom = "mushroom_throw", spit = "toad_spit", eflame = "flame_spit" }
function X.enemyShot(e, kind, a, speed, life, dmg)
    local b = { x = e.x + cos(a) * (e.r + 6), y = e.y + sin(a) * (e.r + 6), vx = cos(a) * speed, vy = sin(a) * speed,
        life = life, owner = "enemy", kind = kind, dmg = dmg or 0, srcX = e.x, srcY = e.y, age = 0 }
    bullets[#bullets + 1] = b
    X.netEnemyShot(b)
    playSfx(X.SHOT_SND[kind] or "enemy_shot", 0.1, volAt(e.x, e.y))
    return b
end

------------------------------------------------------------------------------
-- AI of the Swamp and Volcanic enemies (pd = distance to the target, toP = angle to it)
------------------------------------------------------------------------------
X.AI = {}

-- shared: become aware / patrol / search, returns true when it is hunting and can see you
local function awareHunt(e, dt, toP, col)
    if e.state == "patrol" then
        if e.awareness >= 1 then
            enemyBecomesAware(e)
            X.wtext(e.x, e.y - 30, "!", col or { 1, 0.4, 0.3 }, true)
        else
            patrol(e, dt, toP)
        end
        return false
    end
    if not e.canSee then
        searchLastKnown(e, dt)
        return false
    end
    e.lastX, e.lastY, e.searchTimer = player.x, player.y, 9
    e.angle = turnTowards(e.angle, toP, 6 * dt)
    return true
end

-- SHROOMER: keeps its distance and throws cursed mushrooms, bites up close (16 DMG)
X.AI.shroomer = function(e, dt, pd, toP)
    e.hop = e.hop + dt * 4
    if e.swingT > 0 then
        e.swingT = e.swingT - dt
        if e.swingT <= 0 and not player.dead and pd < e.r + player.r + 30 then
            X.meleeHit("sbite", 16, e.x, e.y, toP)
        end
        return
    end
    if not awareHunt(e, dt, toP, { 1, 0.35, 0.35 }) then return end
    if pd < e.r + player.r + 20 and e.meleeCd <= 0 then
        e.swingT, e.meleeCd = 0.35, 1.3
        return
    end
    if pd > 340 then
        moveDir(e, cos(toP), sin(toP), e.huntSpeed, dt)
    elseif pd < 140 then
        moveDir(e, cos(toP), sin(toP), e.huntSpeed * 0.8, dt)      -- close enough to bite
    else
        e.strafeTimer = e.strafeTimer - dt
        if e.strafeTimer <= 0 then e.strafe, e.strafeTimer = -e.strafe, randRange(1, 2) end
        moveDir(e, cos(toP + pi / 2) * e.strafe, sin(toP + pi / 2) * e.strafe, e.speed * 0.6, dt)
    end
    if e.throwCd <= 0 and pd < 560 then
        X.enemyShot(e, "mushroom", toP + randRange(-0.06, 0.06), 400, 1.6, 0)
        e.throwCd, e.throwAnim = randRange(2.2, 3.2), 0.3
    end
end

-- TOAD: sprints after you for 1 s, then lashes its tongue (300 px, 11 DMG); far away (> 600 px) it spits poison
X.AI.toad = function(e, dt, pd, toP)
    e.hop = e.hop + dt * ((e.sprintT or 0) > 0 and 14 or 5)
    if e.swingT > 0 then                         -- the tongue is out
        e.swingT = e.swingT - dt
        return
    end
    if (e.sprintT or 0) > 0 then
        e.sprintT = e.sprintT - dt
        e.angle = turnTowards(e.angle, toP, 10 * dt)
        if pd > e.r + player.r + 30 then moveDir(e, cos(toP), sin(toP), 300, dt) end
        if e.sprintT <= 0 then
            e.swingT, e.meleeCd = 0.3, 1.5
            X.wsfx("toad_tongue", e.x, e.y, 0.1)
            if not player.dead and pd <= 300 + player.r and hasLOS(e.x, e.y, player.x, player.y) then
                X.meleeHit("tongue", 11, e.x, e.y, toP)
            end
        end
        return
    end
    if not awareHunt(e, dt, toP, { 0.6, 0.9, 0.3 }) then return end
    if pd > 600 then
        moveDir(e, cos(toP), sin(toP), e.huntSpeed * 0.6, dt)
        if e.throwCd <= 0 then
            X.enemyShot(e, "spit", toP + randRange(-0.04, 0.04), 430, 2.4, 0)
            e.throwCd = randRange(2.6, 3.6)
        end
    elseif e.meleeCd <= 0 then
        e.sprintT = 1.0
        X.wsfx("toad_croak", e.x, e.y, 0.15)
    else
        moveDir(e, cos(toP), sin(toP), e.huntSpeed * 0.5, dt)
    end
end

-- CROCODILE: hides in the murky water (only the eyes show), fast in water, slow on land, 32 DMG bite
X.AI.croc = function(e, dt, pd, toP)
    local inW = X.inMurk(e.x, e.y) ~= nil
    local sp = inW and 2.5 or 1
    e.walkAnim = e.walkAnim + dt * (inW and 3 or 6)
    if e.swingT > 0 then
        e.swingT = e.swingT - dt
        if e.swingT <= 0 then
            moveEntity(e, cos(toP) * 22, sin(toP) * 22)
            X.wsfx("croc_snap", e.x, e.y, 0.1)
            if not player.dead and pd < e.r + player.r + 30 then X.meleeHit("croc", 32, e.x, e.y, toP) end
        end
        return
    end
    if e.state == "patrol" then
        if e.awareness >= 1 then
            enemyBecomesAware(e)
        else
            local arrived = steer(e, e.px, e.py, e.speed * sp * 0.6, dt)
            e.angle = turnTowards(e.angle, atan2(e.py - e.y, e.px - e.x), 3 * dt)
            if arrived or e.stuck > 0.1 then pickPatrolTarget(e) end
        end
        return
    end
    -- never strays too far from its pool
    local home = e.pool
    if home and dist(e.x, e.y, home.x, home.y) > 1100 then
        steer(e, home.x, home.y, e.huntSpeed * sp, dt)
        e.angle = turnTowards(e.angle, atan2(home.y - e.y, home.x - e.x), 4 * dt)
        if dist(e.x, e.y, home.x, home.y) < 300 then e.state, e.awareness = "patrol", 0.3 pickPatrolTarget(e) end
        return
    end
    if not e.canSee then searchLastKnown(e, dt) return end
    e.lastX, e.lastY, e.searchTimer = player.x, player.y, 6
    e.angle = turnTowards(e.angle, toP, 5 * dt)
    if pd < e.r + player.r + 22 and e.meleeCd <= 0 then
        e.swingT, e.meleeCd = 0.25, 1.6
    elseif pd > e.r + player.r + 10 then
        moveDir(e, cos(toP), sin(toP), e.huntSpeed * sp, dt)
    end
end

-- MAGMA SLIME (and the small ones): hops at you, 18 DMG bite (25%: 24 FIREBURN)
local function slimeAI(e, dt, pd, toP)
    e.hop = e.hop + dt * (e.state == "hunt" and 10 or 5)
    if e.swingT > 0 then
        e.swingT = e.swingT - dt
        if e.swingT <= 0 and not player.dead and pd < e.r + player.r + 24 then
            if e.kind == "slimelet" then
                X.meleeHit("slimelet", 6, e.x, e.y, toP)
            elseif rand() < 0.25 then
                X.meleeHit("fireburn", 24, e.x, e.y, toP)
            else
                X.meleeHit("slime", 18, e.x, e.y, toP)
            end
        end
        return
    end
    if not awareHunt(e, dt, toP, { 1, 0.5, 0.15 }) then return end
    local reach = e.r + player.r + 16
    if pd < reach and e.meleeCd <= 0 then
        e.swingT, e.meleeCd = 0.2, 1.1
    elseif pd > reach - 6 then
        moveDir(e, cos(toP), sin(toP), e.huntSpeed * (0.4 + 0.6 * abs(sin(e.hop))), dt)
    end
end
X.AI.slime, X.AI.slimelet = slimeAI, slimeAI

-- LAVA SERPENT: swims through the air and over walls, darts THROUGH you (5 DMG, -10% speed), 31 DMG bite
X.AI.serpent = function(e, dt, pd, toP)
    e.wob = e.wob + dt * 8
    e.dashCd = (e.dashCd or 1.5) - dt * X.D.react
    if (e.dashT or 0) > 0 then
        e.dashT = e.dashT - dt
        batFly(e, cos(e.dashA), sin(e.dashA), 560, dt)
        e.angle = e.dashA
        if not e.passHit and not player.dead and dist(e.x, e.y, player.x, player.y) < e.r + player.r + 4 then
            e.passHit = true
            X.meleeHit("pass", 5, e.x, e.y, e.dashA)
        end
        if e.dashT <= 0 then e.dashCd = randRange(2.2, 3.2) end
        return
    end
    if e.swingT > 0 then
        e.swingT = e.swingT - dt
        if e.swingT <= 0 and not player.dead and pd < e.r + player.r + 26 then
            X.meleeHit("serpent", 31, e.x, e.y, toP)
        end
        return
    end
    if e.state == "patrol" then
        if e.awareness >= 1 then
            enemyBecomesAware(e)
        else
            if dist(e.x, e.y, e.px, e.py) < 30 then pickPatrolTarget(e) end
            local a = atan2(e.py - e.y, e.px - e.x) + sin(e.wob) * 0.5
            batFly(e, cos(a), sin(a), e.speed, dt)
            e.angle = a
        end
        return
    end
    local tx, ty = e.lastX or player.x, e.lastY or player.y
    if e.canSee then
        e.lastX, e.lastY, e.searchTimer = player.x, player.y, 6
        tx, ty = player.x, player.y
    else
        e.searchTimer = e.searchTimer - dt
        if e.searchTimer <= 0 then e.state, e.awareness = "patrol", 0.2 e.homeX, e.homeY = e.x, e.y pickPatrolTarget(e) return end
    end
    if e.canSee and pd < e.r + player.r + 20 and e.meleeCd <= 0 then
        e.swingT, e.meleeCd = 0.2, 1.6
    elseif e.canSee and e.dashCd <= 0 and pd < 460 then
        e.dashA, e.dashT, e.passHit = toP, (pd + 240) / 560, false
        X.wsfx("serpent_dash", e.x, e.y, 0.1)
    else
        local a = atan2(ty - e.y, tx - e.x) + sin(e.wob) * 0.35
        batFly(e, cos(a), sin(a), e.huntSpeed, dt)
        e.angle = a
    end
end

-- BLAZESHROOM: slow, spits a flame (20 DMG) every 0.9 s at up to 500 px
X.AI.blazeshroom = function(e, dt, pd, toP)
    e.hop = e.hop + dt * 3
    if not awareHunt(e, dt, toP, { 1, 0.55, 0.1 }) then return end
    if pd <= 500 then
        if e.fireCd <= 0 then
            X.enemyShot(e, "eflame", toP + randRange(-0.05, 0.05), 440, 520 / 440, 20)
            e.fireCd, e.throwAnim = 0.9, 0.25
        end
        if pd < 220 then moveDir(e, -cos(toP), -sin(toP), e.huntSpeed, dt) end
    else
        moveDir(e, cos(toP), sin(toP), e.huntSpeed, dt)
    end
end

function updateEnemy(e, dt)
    if e.kind == "guardian" then X.updateGuardian(e, dt) return end
    if e.kind == "gatekeeper" then X.updateGatekeeper(e, dt) return end
    e.hitFlash = max(0, e.hitFlash - dt)
    e.muzzle = max(0, e.muzzle - dt)
    e.fireCd = e.fireCd - dt * X.D.react
    e.alertCd = e.alertCd - dt
    e.meleeCd = e.meleeCd - dt * X.D.react
    e.throwCd = e.throwCd - dt * X.D.react
    e.throwAnim = max(0, e.throwAnim - dt)
    e.spawnFade = min(1, e.spawnFade + dt * 2)
    e.hpLag = e.hpLag > e.hp and max(e.hp, e.hpLag - 60 * dt) or e.hp

    -- Status effects: freezing (Cold Icicles), stun & slowness (IceShock)
    if e.frostT > 0 then
        e.frostT = e.frostT - dt
        e.frostTick = e.frostTick - dt
        if e.frostTick <= 0 then
            e.frostTick = 2
            e.hp = e.hp - 1
            stats.damageDealt = stats.damageDealt + 1
            X.wtext(e.x, e.y - 20, "-1", { 0.55, 0.85, 1 })
            X.wsfx("frost_tick", e.x, e.y, 0.2)
            if e.hp <= 0 then
                killEnemy(e, nil, e.lastHitBy, "frost")
                return
            end
        end
        if rand() < 0.08 then spawnParticles(e.x, e.y, 1, { 0.8, 0.95, 1 }, 10, 30, 0.6, 2) end
    end
    -- Flamethrower burn: 3 damage every 0.5 s
    if (e.burnT or 0) > 0 then
        e.burnT = e.burnT - dt
        e.burnTick = (e.burnTick or 0.5) - dt
        if e.burnTick <= 0 then
            e.burnTick = 0.5
            local bd = e.burnDmg or 3
            e.hp = e.hp - bd
            X.wtext(e.x, e.y - 20, "-" .. bd, { 1, 0.6, 0.2 })
            if e.hp <= 0 then
                killEnemy(e, nil, e.burnBy)
                return
            end
        end
        if rand() < 0.3 then spawnParticles(e.x, e.y - 4, 1, { 1, 0.55, 0.15 }, 10, 40, 0.5, 3, -pi / 2, 0.6, 1) end
    end
    e.bubbleT = max(0, (e.bubbleT or 0) - dt)
    e.shockSlowT = max(0, e.shockSlowT - dt)
    e.speedMul = (e.frostT > 0 and 0.9 or 1) * ((e.shockSlowT > 0 and e.stunT <= 0) and 0.6 or 1)
    if e.stunT > 0 then
        e.stunT = e.stunT - dt
        return
    end
    -- a bat that bit you is gone for 10s, then returns to that exact spot
    if e.hidden > 0 then
        e.hidden = e.hidden - dt
        if e.hidden <= 0 then
            e.x, e.y = e.biteX, e.biteY
            e.homeX, e.homeY = e.x, e.y
            e.state, e.awareness, e.spawnFade = "patrol", 0.7, 0
            pickPatrolTarget(e)
            spawnParticles(e.x, e.y, 16, { 0.22, 0.18, 0.28 }, 40, 170, 0.7, 4)
            X.wsfx("bat_poof", e.x, e.y, 0.1)
            X.wsfx("bat_screech", e.x, e.y, 0.1)
        end
        return
    end

    local pd = dist(e.x, e.y, player.x, player.y)
    local toP = atan2(player.y - e.y, player.x - e.x)
    local vision = e.vision * weatherVis(e.region)   -- rain / blizzard reduce enemy sight too
    vision = vision * (1 - (player.stealth or 0))     -- Shadow Cloak

    -- Vision check (throttled - line of sight is blocked by walls)
    e.losTimer = e.losTimer - dt
    if e.losTimer <= 0 then
        e.losTimer = randRange(0.1, 0.18)
        -- nobody can be seen inside the shed
        e.canSee = (not player.dead) and pd < vision and not X.inShed(player.x, player.y)
            and hasLOS(e.x, e.y, player.x, player.y) and not (X.smokes[1] and X.smokeBlocks(e.x, e.y, player.x, player.y))
        if player.decoy and e.canSee then e.awareness, e.state = 1, "hunt" end
    end
    if admin.on and admin.stealth then e.canSee = false e.awareness = 0 end   -- admin: infinite stealth

    -- Awareness meter
    if e.canSee then
        local inCone = abs(angleDiff(e.angle, toP)) < e.fov or pd < 140 or e.state ~= "patrol"
        if inCone then
            local rate = (0.7 + 2.6 * max(0, 1 - pd / vision)) * X.D.react
            e.awareness = min(1, e.awareness + rate * dt)
        end
    elseif e.state == "patrol" then
        e.awareness = max(0, e.awareness - 0.3 * dt)
    end

    local ai = X.AI[e.kind]
    if ai then
        ai(e, dt, pd, toP)
        -- walking enemies never step into lava
        if e.region == "volcanic" and e.kind ~= "serpent" then
            local lp = X.inLava(e.x, e.y)
            if lp then e.x, e.y = X.poolEdge(lp, e.x, e.y, e.r + 4) end
        end
        return
    end
    if e.kind == "bandit" or e.kind == "frozen" then
        if e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
                X.wtext(e.x, e.y - 30, "!", { 1, 0.3, 0.2 }, true)
            else
                patrol(e, dt, toP)
            end
        elseif e.state == "hunt" then
            if e.canSee then
                e.lastX, e.lastY, e.searchTimer = player.x, player.y, 9
                e.angle = turnTowards(e.angle, toP, 7 * dt)
                e.strafeTimer = e.strafeTimer - dt
                if e.strafeTimer <= 0 then e.strafe = -e.strafe e.strafeTimer = randRange(0.8, 2.2) end
                local mx, my = 0, 0
                if pd > 340 then mx, my = cos(toP), sin(toP)
                elseif pd < 190 then mx, my = -cos(toP), -sin(toP) end
                mx = mx + cos(toP + pi / 2) * e.strafe * 0.5
                my = my + sin(toP + pi / 2) * e.strafe * 0.5
                moveDir(e, mx, my, e.huntSpeed * 0.55, dt)
                if e.fireCd <= 0 and pd < 580 and abs(angleDiff(e.angle, toP)) < 0.3 then
                    if e.kind == "frozen" then
                        enemyShoot(e, "icicle")
                        e.fireCd = randRange(0.7, 1.25)
                    else
                        enemyShoot(e)
                        e.fireCd = randRange(0.85, 1.5)
                    end
                end
            else
                searchLastKnown(e, dt)
            end
        end
    elseif e.kind == "bowman" then
        -- Bow Wielder: stop, shoot, move. Never leaves the Stronghold.
        local S = X.SH
        local leashed = S and dist(e.x, e.y, S.cx, S.cy) > S.leash
        if e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
                X.wtext(e.x, e.y - 30, "!", { 0.6, 0.9, 0.45 }, true)
                e.bowPhase, e.bowT = "aim", 0.6
            else
                patrol(e, dt, toP)
            end
        elseif e.state == "hunt" then
            if leashed then
                -- too far from the Stronghold: walk back in
                if steer(e, S.cx, S.cy, e.huntSpeed, dt) or dist(e.x, e.y, S.cx, S.cy) < S.leash * 0.6 then
                    e.state, e.awareness = "patrol", 0.3
                    pickPatrolTarget(e)
                end
                e.angle = turnTowards(e.angle, atan2(S.cy - e.y, S.cx - e.x), 6 * dt)
            elseif e.canSee then
                e.lastX, e.lastY, e.searchTimer = player.x, player.y, 6
                e.bowT = (e.bowT or 0.6) - dt
                if (e.bowPhase or "aim") == "aim" then
                    -- stop and draw the bow
                    e.angle = turnTowards(e.angle, toP, 8 * dt)
                    e.throwAnim = 0.25
                    if e.bowT <= 0 and e.fireCd <= 0 and pd < 640 then
                        enemyShoot(e, "arrow")
                        e.fireCd = randRange(1.8, 2.2)
                        e.bowPhase, e.bowT = "move", 1.4
                        local side = rand() < 0.5 and 1 or -1
                        local back = pd < 260 and -0.8 or (pd > 520 and 0.8 or randRange(-0.3, 0.3))
                        e.mvx, e.mvy = cos(toP + pi / 2) * side + cos(toP) * back, sin(toP + pi / 2) * side + sin(toP) * back
                    elseif pd >= 640 then
                        moveDir(e, cos(toP), sin(toP), e.huntSpeed * 0.6, dt)
                    end
                else
                    -- reposition fast, then stop again
                    moveDir(e, e.mvx or 0, e.mvy or 0, e.huntSpeed, dt)
                    e.angle = turnTowards(e.angle, toP, 5 * dt)
                    if e.bowT <= 0 or e.stuck > 0.2 then e.bowPhase, e.bowT = "aim", 0.6 end
                end
            else
                searchLastKnown(e, dt)
                if e.state == "patrol" and S then e.homeX, e.homeY = S.cx, S.cy pickPatrolTarget(e) end
            end
        end
    elseif e.kind == "scout" then
        if e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
            else
                patrol(e, dt, toP)
            end
        elseif e.state == "flee" then
            e.fleeTimer = e.fleeTimer - dt
            moveDir(e, -cos(toP), -sin(toP), e.huntSpeed, dt)
            e.angle = turnTowards(e.angle, toP + pi, 8 * dt)
            if e.fleeTimer <= 0 then
                if e.canSee then
                    if e.alertCd <= 0 then raiseAlarm(e) e.alertCd = 10 end
                    e.fleeTimer = 3
                else
                    e.state, e.awareness = "patrol", 0.3
                    e.homeX, e.homeY = e.x, e.y
                    pickPatrolTarget(e)
                end
            end
        end
    elseif e.kind == "gourd" then
        -- Gourd: hopping pumpkin, 18 DMG lunge, 10% chance to SPOOK you
        e.hop = e.hop + dt * (e.state == "hunt" and 9 or 5)
        if e.swingT > 0 then
            e.swingT = e.swingT - dt
            e.angle = turnTowards(e.angle, toP, 4 * dt)
            if e.swingT <= 0 then
                X.wsfx("gourd_bite", e.x, e.y, 0.1)
                moveEntity(e, cos(toP) * 14, sin(toP) * 14)
                if not player.dead and pd < e.r + player.r + 32 then
                    X.meleeHit("gourd", 18, e.x, e.y, toP)
                end
            end
        elseif e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
                X.wtext(e.x, e.y - 30, "!", { 1, 0.5, 0.1 }, true)
            else
                patrol(e, dt, toP)
            end
        elseif e.state == "hunt" then
            if e.canSee then
                e.lastX, e.lastY, e.searchTimer = player.x, player.y, 9
                e.angle = turnTowards(e.angle, toP, 6 * dt)
                local reach = e.r + player.r + 20
                if pd < reach and e.meleeCd <= 0 then
                    e.swingT, e.meleeCd = 0.3, 1.4
                elseif pd > reach - 6 then
                    moveDir(e, cos(toP), sin(toP), e.huntSpeed * (0.45 + 0.55 * abs(sin(e.hop))), dt)
                end
            else
                searchLastKnown(e, dt)
            end
        end
    elseif e.kind == "bat" then
        -- Bat: flies over walls, tiny vision, bites (5 DMG) then vanishes for 10s
        e.flap = e.flap + dt * 22
        e.wob = e.wob + dt * 7
        if e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
                e.searchTimer = 4
            else
                if dist(e.x, e.y, e.px, e.py) < 24 then pickPatrolTarget(e) end
                local a = atan2(e.py - e.y, e.px - e.x) + sin(e.wob) * 0.9
                batFly(e, cos(a), sin(a), e.speed, dt)
                e.angle = a
            end
        elseif e.state == "hunt" then
            local tx, ty = e.lastX, e.lastY
            if e.canSee then
                e.lastX, e.lastY, e.searchTimer = player.x, player.y, 4
                tx, ty = player.x, player.y
            else
                e.searchTimer = e.searchTimer - dt
            end
            local a = atan2(ty - e.y, tx - e.x) + sin(e.wob) * 0.45
            batFly(e, cos(a), sin(a), e.huntSpeed, dt)
            e.angle = a
            if not player.dead and dist(e.x, e.y, player.x, player.y) < e.r + player.r + 4 and player.iframes <= 0 then
                X.meleeHit("bite", 5, e.x, e.y, a)
                X.wsfx("bat_poof", e.x, e.y, 0.1)
                spawnParticles(e.x, e.y, 16, { 0.22, 0.18, 0.28 }, 40, 170, 0.7, 4)
                e.biteX, e.biteY = player.x, player.y   -- it will return to this exact spot
                e.hidden = 10
                return
            end
            if e.searchTimer <= 0 then
                e.state, e.awareness = "patrol", 0.3
                e.homeX, e.homeY = e.x, e.y
                pickPatrolTarget(e)
            end
        end
    elseif e.kind == "witch" then
        -- Witch: cackles, then lobs a purple poison potion
        e.hover = e.hover + dt * 3
        if e.castT > 0 then
            e.castT = e.castT - dt
            e.angle = turnTowards(e.angle, toP, 5 * dt)
            if e.castT <= 0 and not player.dead then enemyShoot(e, "potion") end
        elseif e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
                X.wtext(e.x, e.y - 30, "!", { 0.8, 0.4, 1 }, true)
            else
                patrol(e, dt, toP)
            end
        elseif e.state == "hunt" then
            e.dodgeCd = (e.dodgeCd or 0) - dt
            if (e.dodgeT or 0) > 0 then
                e.dodgeT = e.dodgeT - dt
                moveDir(e, cos(toP + pi / 2) * e.dodgeDir, sin(toP + pi / 2) * e.dodgeDir, 430, dt)
            elseif e.canSee and e.dodgeCd <= 0 and pd < 700
               and abs(angleDiff(player.angle or 0, atan2(e.y - player.y, e.x - player.x))) < 0.14 then
                -- you are aiming at her: she dashes sideways
                e.dodgeT, e.dodgeCd, e.dodgeDir = 0.3, randRange(1.2, 2), rand() < 0.5 and -1 or 1
            end
            if e.canSee then
                e.lastX, e.lastY, e.searchTimer = player.x, player.y, 9
                e.angle = turnTowards(e.angle, toP, 6 * dt)
                e.strafeTimer = e.strafeTimer - dt
                if e.strafeTimer <= 0 then e.strafe = -e.strafe e.strafeTimer = randRange(1, 2.4) end
                local mx, my = 0, 0
                if pd > 420 then mx, my = cos(toP), sin(toP)
                elseif pd < 260 then mx, my = -cos(toP), -sin(toP) end
                mx = mx + cos(toP + pi / 2) * e.strafe * 0.6
                my = my + sin(toP + pi / 2) * e.strafe * 0.6
                moveDir(e, mx, my, e.huntSpeed * 0.6, dt)
                if e.throwCd <= 0 and pd < 540 and abs(angleDiff(e.angle, toP)) < 0.4 then
                    e.castT, e.throwCd = 0.9, randRange(2.6, 3.6)
                    X.wsfx("witch_laugh", e.x, e.y, 0.08)
                    X.wtext(e.x, e.y - 36, "HEHEHE!", { 0.8, 0.45, 1 })
                end
            else
                searchLastKnown(e, dt)
            end
        end
    else -- snowman soldier: branch melee up close, snowballs at range
        if e.swingT > 0 then
            e.swingT = e.swingT - dt
            e.angle = turnTowards(e.angle, toP, 3 * dt)
            if e.swingT <= 0 then
                X.wsfx("branch", e.x, e.y, 0.1)
                if not player.dead and pd < e.r + player.r + 38 and abs(angleDiff(e.angle, toP)) < 1.3 then
                    X.meleeHit("branch", 12, e.x, e.y, toP)
                end
            end
        elseif e.state == "patrol" then
            if e.awareness >= 1 then
                enemyBecomesAware(e)
                X.wtext(e.x, e.y - 30, "!", { 1, 0.3, 0.2 }, true)
            else
                patrol(e, dt, toP)
            end
        elseif e.state == "hunt" then
            if e.canSee then
                e.lastX, e.lastY, e.searchTimer = player.x, player.y, 9
                e.angle = turnTowards(e.angle, toP, 6 * dt)
                local reach = e.r + player.r + 24
                if pd < reach and e.meleeCd <= 0 then
                    e.swingT, e.meleeCd = 0.4, 1.3          -- wind-up before the branch lands
                elseif pd > 150 and pd < 460 and e.throwCd <= 0 and abs(angleDiff(e.angle, toP)) < 0.35 then
                    enemyShoot(e, "snowball")
                    e.throwCd = randRange(1.8, 2.8)
                end
                if pd > reach - 8 then moveDir(e, cos(toP), sin(toP), e.huntSpeed, dt) end
            else
                searchLastKnown(e, dt)
            end
        end
    end

    -- Keep inside its own region
    local reg = REGIONS[e.region]
    e.x = clamp(e.x, reg.x0 + e.r, reg.x1 - e.r)
    e.y = clamp(e.y, reg.y0 + e.r, reg.y1 - e.r)
end
end

local function separateEntities()
    local players = X.allPlayers()
    for i = 1, #enemies do
        local a = enemies[i]
        for j = i + 1, #enemies do
            local b = enemies[j]
            local d = dist(a.x, a.y, b.x, b.y)
            local minD = a.r + b.r
            if d < minD and d > 0.01 and a.hidden <= 0 and b.hidden <= 0 then
                local push = (minD - d) / 2
                local nx, ny = (b.x - a.x) / d, (b.y - a.y) / d
                if X.BOSSES[a.kind] then moveEntity(b, nx * push * 2, ny * push * 2)
                elseif X.BOSSES[b.kind] then moveEntity(a, -nx * push * 2, -ny * push * 2)
                else
                    moveEntity(a, -nx * push, -ny * push)
                    moveEntity(b, nx * push, ny * push)
                end
            end
        end
        if a.hidden <= 0 and not X.BOSSES[a.kind] then
            for _, pl in ipairs(players) do
                if not pl.dead then
                    local d = dist(a.x, a.y, pl.x, pl.y)
                    local minD = a.r + pl.r
                    if d < minD and d > 0.01 then
                        local push = minD - d
                        moveEntity(a, (a.x - pl.x) / d * push, (a.y - pl.y) / d * push)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- Update: bullets, effects, spawning
------------------------------------------------------------------------------
-- removes every enemy shot; while the bullet loop is running it waits until the loop ends
-- (a boss can die in the middle of the loop - removing bullets then breaks the loop's indices)
function X.clearEnemyBullets()
    if X.inBulletLoop then X.clearPending = true return end
    for i = #bullets, 1, -1 do if bullets[i].owner == "enemy" then table.remove(bullets, i) end end
end

local updateBullets0
local function updateBullets(dt)
    X.inBulletLoop = true
    local ok, err = pcall(updateBullets0, dt)
    X.inBulletLoop = false
    if X.clearPending then X.clearPending = false X.clearEnemyBullets() end
    if not ok then error(err, 0) end
end

function updateBullets0(dt)
    local players = MPS.online and X.allPlayers() or nil
    for i = #bullets, 1, -1 do
        local b = bullets[i]
        if b.kind == "boomerang" or b.kind == "missile" or b.homing then X.steerShot(b, dt) end
        local nx, ny = b.x + b.vx * dt, b.y + b.vy * dt
        local wallT
        local buf, n = WG.query(min(b.x, nx), min(b.y, ny), abs(nx - b.x), abs(ny - b.y))
        for k = 1, n do
            local w = buf[k]
            -- Void Pistol bullets go through everything except the world border and the gates
            if not w.enemyOnly and not (b.ghost and w.kind ~= "border" and w.kind:sub(1, 4) ~= "gate") then
                local hit, t = segRect(b.x, b.y, nx, ny, w)
                if hit and (not wallT or t < wallT) then wallT = t end
            end
        end

        local remove = false
        local ang = atan2(b.vy, b.vx)
        if b.owner == "player" or b.owner == "remote" then
            -- "player" = this machine's shots (deal damage), "remote" = other players' shots (visual)
            -- multi = passes through enemies (each enemy is hit once per flight / boomerang phase)
            local multi = b.kind == "boomerang" or b.kind == "flame" or b.pierce
            for _, e in ipairs(enemies) do
                if not e.dead and e.hidden <= 0 and not (b.hitSet and b.hitSet[e]) then
                    local t = segCircle(b.x, b.y, nx, ny, e.x, e.y, e.r + (b.kind == "flame" and 12 or 5))
                    if t and (not wallT or t <= wallT) and X.gkShielded(e) then
                        -- the FIRE SHIELD bounces it back as a burning shot (other players' shots just fizzle here)
                        if b.owner == "player" then
                            local ra = atan2(me.y - e.y, me.x - e.x) + randRange(-0.08, 0.08)
                            local hx, hy = e.x + cos(ra) * (e.r + 14), e.y + sin(ra) * (e.r + 14)
                            bullets[#bullets + 1] = { x = hx, y = hy, vx = cos(ra) * 760, vy = sin(ra) * 760, life = 1.6,
                                owner = "enemy", kind = "eflame", dmg = max(8, (b.shot and b.shot.dmg) or 10), srcX = e.x, srcY = e.y, reflected = true }
                        end
                        spawnParticles(e.x + cos(ang + pi) * e.r, e.y + sin(ang + pi) * e.r, 6, { 1, 0.6, 0.15 }, 60, 200, 0.3, 2.5)
                        X.wsfx("block", e.x, e.y, 0.15, 0.6)
                        remove = true
                        break
                    elseif t and (not wallT or t <= wallT) then
                        if b.kind == "rocket" then
                            X.explode(b.x + (nx - b.x) * t, b.y + (ny - b.y) * t, b.owner, b.shot)
                            remove = true
                            break
                        elseif b.kind == "bhole" then
                            b.pop = true
                            break
                        elseif b.kind == "missile" then
                            -- Guided Missile: kills the enemy it hits (no splash damage)
                            X.explode(b.x + (nx - b.x) * t, b.y + (ny - b.y) * t, nil, nil, 60)
                            if b.owner == "player" then
                                if not b.shot.hit then b.shot.hit = true stats.shotsHit = stats.shotsHit + 1 end
                                X.hitEnemy(e, b.shot.dmg, ang, b.shot.crit, b.icy, b.fx)
                            end
                            remove = true
                            break
                        end
                        if multi then b.hitSet = b.hitSet or {} b.hitSet[e] = true end
                        if b.owner == "player" then
                            if multi or e.lastShot ~= b.shot then
                                if not multi then e.lastShot = b.shot end
                                if not b.shot.hit then b.shot.hit = true stats.shotsHit = stats.shotsHit + 1 end
                                X.hitEnemy(e, b.shot.dmg, ang, b.shot.crit, b.icy, b.fx)
                            end
                        elseif b.kind ~= "flame" then
                            spawnParticles(e.x, e.y, 4, e.region == "frozen" and { 0.8, 0.92, 1 } or { 0.65, 0.1, 0.08 }, 50, 180, 0.3, 2.5, ang, 0.6)
                        end
                        if b.pierce then
                            b.hits = (b.hits or 0) + 1
                            if b.hits > b.pierce then remove = true break end
                        elseif not multi then
                            remove = true
                            break
                        end
                    end
                end
            end
        elseif X.decoys[1] and X.decoyHit(b, nx, ny) then
            remove = true
        elseif not player.dead then
            local t = segCircle(b.x, b.y, nx, ny, player.x, player.y, player.r + (b.kind == "snowball" and 5 or (b.kind == "face" and 9 or 1)))
            if t and (not wallT or t <= wallT) then
                if player.iframes > 0 then
                    if not b.dodged then
                        b.dodged = true
                        stats.dodges = stats.dodges + 1
                        addText(player.x, player.y - 30, "DODGE", { 0.6, 0.9, 1 })
                    end
                elseif b.kind == "potion" then
                    b.splash = true
                elseif b.kind == "mushroom" or b.kind == "spit" then
                    X.curseHit(b.kind)                  -- your shield can't stop these
                    remove = true
                else
                    local blocked = damagePlayer(b.dmg, b.srcX, b.srcY, b.kind)
                    if b.kind == "icicle" then
                        spawnParticles(player.x, player.y, 6, { 0.75, 0.93, 1 }, 40, 150, 0.4, 2.5)
                        if not blocked and not player.dead then
                            -- Frozen icicle: -15% movement speed for 3 seconds
                            if player.chillT <= 0 then
                                playSfx("chill", 0.1)
                                addText(player.x, player.y - 40, "SLOWED", { 0.6, 0.9, 1 })
                            end
                            player.chillT = 3
                        end
                    elseif b.kind == "snowball" then
                        -- Snowball: major knockback (reduced when blocked)
                        local sp = sqrt(b.vx * b.vx + b.vy * b.vy)
                        local kb = blocked and 110 or 640
                        player.kbx = player.kbx + b.vx / sp * kb
                        player.kby = player.kby + b.vy / sp * kb
                        playSfx("snowball_hit", 0.1)
                        spawnParticles(player.x, player.y, 14, { 0.95, 0.97, 1 }, 50, 220, 0.5, 4)
                        addShake(blocked and 2 or 7)
                    end
                    remove = true
                end
            end
        end

        -- enemy projectiles also stop on the other players (each machine damages only its own player)
        if not remove and b.owner == "enemy" and players then
            for _, o in ipairs(players) do
                if o ~= me and not o.dead then
                    local t = segCircle(b.x, b.y, nx, ny, o.x, o.y, o.r + 1)
                    if t and (not wallT or t <= wallT) then
                        if b.kind == "potion" then b.splash = true else remove = true end
                        if b.kind == "snowball" then spawnParticles(o.x, o.y, 10, { 0.95, 0.97, 1 }, 50, 200, 0.4, 3.5) end
                        break
                    end
                end
            end
        end

        -- potions shatter where they land (or when they hit someone / a wall)
        if b.kind == "potion" and not remove and (b.splash or wallT or b.age + dt >= b.land) then
            local hx, hy = b.x, b.y
            if wallT then hx, hy = b.x + (nx - b.x) * wallT, b.y + (ny - b.y) * wallT end
            playSfx("potion_break", 0.1, max(0.3, volAt(hx, hy)))
            spawnParticles(hx, hy, 18, { 0.65, 0.2, 0.95 }, 40, 200, 0.7, 3.5)
            decals[#decals + 1] = { x = hx, y = hy, r = 24, a = rand() * 2 * pi, kind = "puddle", life = 30 }
            if not player.dead and dist(hx, hy, player.x, player.y) < 50 and player.iframes <= 0 then
                local shielded = player.blocking
                    and abs(angleDiff(player.angle, atan2(b.srcY - player.y, b.srcX - player.x))) < math.rad(75)
                if shielded then
                    playSfx("block", 0.1)
                    addText(player.x, player.y - 30, "SHATTERED", { 0.8, 0.6, 1 })
                elseif not (admin.on and admin.hp) then
                    if player.poisonT <= 0 then player.poisonTick = 1 end
                    player.poisonT = 5
                    playSfx("poison", 0.1)
                    addText(player.x, player.y - 40, "POISONED", { 0.75, 0.35, 1 }, true)
                end
            end
            remove = true
        end

        if not remove and wallT and b.kind == "boomerang" and not b.back then
            -- the boomerang bounces off walls and comes back
            b.back, b.hitSet = true, nil
            wallT = nil
            nx, ny = b.x, b.y
        end
        if not remove and (b.pop or (wallT and b.kind == "bhole") or (b.kind == "bhole" and b.life - dt <= 0)) then
            local hx, hy = b.x, b.y
            if wallT and not b.pop then hx, hy = b.x + (nx - b.x) * wallT - cos(ang) * 10, b.y + (ny - b.y) * wallT - sin(ang) * 10 end
            X.popBlackHole(b, hx, hy)
            remove, wallT = true, nil
        end
        if not remove and wallT then
            local hx, hy = b.x + (nx - b.x) * wallT, b.y + (ny - b.y) * wallT
            if b.kind == "flame" then
                -- flames just die on walls
            elseif b.kind == "rocket" then
                X.explode(hx - cos(ang) * 6, hy - sin(ang) * 6, b.owner, b.shot)
            elseif b.kind == "missile" then
                X.explode(hx - cos(ang) * 6, hy - sin(ang) * 6, nil, nil, 60)   -- wasted on the wall
            elseif b.kind == "snowball" then
                spawnParticles(hx, hy, 10, { 0.95, 0.97, 1 }, 30, 140, 0.5, 3.5, ang + pi, 1.3)
                playSfx("snowball_hit", 0.15, 0.5 * volAt(hx, hy))
            elseif b.kind == "icicle" or b.icy then
                spawnParticles(hx, hy, 7, { 0.75, 0.93, 1 }, 40, 180, 0.3, 2, ang + pi, 1.2)
                if b.kind == "icicle" then playSfx("shatter", 0.2, 0.4 * volAt(hx, hy)) end
            else
                spawnParticles(hx, hy, 5, { 1, 0.85, 0.5 }, 40, 180, 0.2, 2, ang + pi, 1.2)
                spawnParticles(hx, hy, 3, { 0.55, 0.45, 0.35 }, 20, 80, 0.5, 3, ang + pi, 1.2)
            end
            remove = true
        end

        if b.kind == "flame" and not remove and rand() < 0.5 then
            spawnParticles(b.x, b.y, 1, rand() < 0.5 and { 1, 0.55, 0.1 } or { 1, 0.85, 0.3 }, 10, 40, 0.3, 5, ang + pi, 0.6, 3)
        end
        if b.look == "plasma" or b.look == "ghost" or b.look == "void" then
            if not remove and rand() < 0.5 then
                local c = b.look == "plasma" and { 0.4, 1, 0.6 } or (b.look == "ghost" and { 0.75, 0.95, 1 } or { 0.55, 0.2, 0.8 })
                spawnParticles(b.x, b.y, 1, c, 5, 30, 0.3, 3, ang + pi, 0.5, 3)
            end
        end
        -- rocket exhaust trail
        if (b.kind == "rocket" or b.kind == "missile") and not remove and rand() < 0.8 then
            spawnParticles(b.x, b.y, 1, rand() < 0.5 and { 1, 0.6, 0.2 } or { 0.45, 0.42, 0.4 }, 10, 40, 0.5, 4, ang + pi, 0.5, 3)
        end

        b.life = b.life - dt
        if b.age then b.age = b.age + dt end
        if not remove and b.life <= 0 and b.kind == "rocket" then
            X.explode(nx, ny, b.owner, b.shot)   -- reached its 500 px range
        elseif not remove and b.life <= 0 and b.kind == "missile" then
            X.explode(nx, ny, nil, nil, 60)      -- out of fuel
        end
        if remove or b.life <= 0 then
            table.remove(bullets, i)
        else
            b.x, b.y = nx, ny
        end
    end
end

-- Boomerangs fly back to their thrower; Ghost Bow arrows home in on enemies
function X.steerShot(b, dt)
    local sp = sqrt(b.vx * b.vx + b.vy * b.vy)
    if b.kind == "boomerang" then
        b.spin = (b.spin or 0) + dt * 18
        b.travel = b.travel + sp * dt
        if not b.back and b.travel >= b.range then b.back, b.hitSet = true, nil end
        if b.back then
            local h = b.home
            if not h then b.life = min(b.life, 0.4) return end
            local d = dist(b.x, b.y, h.x, h.y)
            if d < 26 then b.life = 0 return end
            b.vx, b.vy = (h.x - b.x) / d * sp, (h.y - b.y) / d * sp
            b.life = max(b.life, 0.5)
        end
        return
    end
    if b.kind == "missile" then
        -- Guided Missile: chases its locked target; if that one dies, locks onto the nearest enemy
        local tg = b.target
        if not tg or tg.dead or tg.hidden > 0 then
            tg, b.target = nil, nil
            local bd = 900
            for _, e in ipairs(enemies) do
                if not e.dead and e.hidden <= 0 then
                    local d = dist(b.x, b.y, e.x, e.y)
                    if d < bd then tg, bd = e, d end
                end
            end
            b.target = tg
        end
        if tg then
            local a = turnTowards(atan2(b.vy, b.vx), atan2(tg.y - b.y, tg.x - b.x), 4.5 * dt)
            b.vx, b.vy = cos(a) * sp, sin(a) * sp
        end
        return
    end
    local cur = atan2(b.vy, b.vx)
    local best, bd = nil, 420
    for _, e in ipairs(enemies) do
        if not e.dead and e.hidden <= 0 then
            local d = dist(b.x, b.y, e.x, e.y)
            if d < bd and abs(angleDiff(cur, atan2(e.y - b.y, e.x - b.x))) < 1.3 then best, bd = e, d end
        end
    end
    if best then
        local a = turnTowards(cur, atan2(best.y - b.y, best.x - b.x), 6 * dt)
        b.vx, b.vy = cos(a) * sp, sin(a) * sp
    end
end

-- Guided Missile lock-on: the enemy closest to the cursor (within 300 px), or nil
function X.missileLock(cx, cy)
    local best, bd = nil, 300
    for _, e in ipairs(enemies) do
        if not e.dead and e.hidden <= 0 then
            local d = dist(cx, cy, e.x, e.y)
            if d < bd then best, bd = e, d end
        end
    end
    return best
end

-- Black Hole Launcher shell: the real vortex lives on the host (or in single player)
function X.popBlackHole(b, x, y)
    if b.owner == "player" then
        if MPS.role == "client" then
            X.spawnVortex(x, y, 0, nil, false)
            NET.toHost({ t = "vortex", x = floor(x), y = floor(y), d = b.shot.dmg })
        else
            X.spawnVortex(x, y, b.shot.dmg, MPS.id, true)
        end
    elseif MPS.role ~= "host" then
        X.spawnVortex(x, y, 0, nil, false)   -- another player's black hole (visual)
    end
end

local function updateEffects(dt)
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.life = p.life - dt
        if p.life <= 0 then table.remove(particles, i)
        else
            p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
            local d = max(0, 1 - p.drag * dt)
            p.vx, p.vy = p.vx * d, p.vy * d
        end
    end
    for i = #texts, 1, -1 do
        local t = texts[i]
        t.life = t.life - dt
        t.y = t.y + t.vy * dt
        t.vy = t.vy * (1 - 2 * dt)
        if t.life <= 0 then table.remove(texts, i) end
    end
    for i = #rings, 1, -1 do
        local r = rings[i]
        r.life = r.life - dt
        r.r = r.max * (1 - r.life / (r.maxLife or 1))
        if r.life <= 0 then table.remove(rings, i) end
    end
    for i = #messages, 1, -1 do
        messages[i].life = messages[i].life - dt
        if messages[i].life <= 0 then table.remove(messages, i) end
    end
    for i = #decals, 1, -1 do
        decals[i].life = decals[i].life - dt
        if decals[i].life <= 0 then table.remove(decals, i) end
    end
    shake = max(0, shake - dt * 30)
    hurtFlash = max(0, hurtFlash - dt * 1.5)
    snowFlash = max(0, snowFlash - dt * 0.9)
    lightning = max(0, lightning - dt * 2.5)
    for i = #X.beams, 1, -1 do
        X.beams[i].life = X.beams[i].life - dt
        if X.beams[i].life <= 0 then table.remove(X.beams, i) end
    end
    if banner then
        banner.t = banner.t - dt
        if banner.t <= 0 then banner = nil end
    end
    -- the FROZEN CHEST sparkles
    if frozenChest and not frozenChest.opened and rand() < 0.35
       and dist(frozenChest.x, frozenChest.y, player.x, player.y) < 1000 then
        spawnParticles(frozenChest.x + randRange(-24, 24), frozenChest.y + randRange(-16, 16), 1,
            rand() < 0.5 and { 0.7, 0.9, 1 } or { 0.8, 0.6, 1 }, 10, 40, 0.9, 2.2, -pi / 2, 0.6, 1)
    end
end

local function updateSpawning(dt)
    for i = #enemies, 1, -1 do
        if enemies[i].dead then table.remove(enemies, i) end
    end
    X.updateBoxes(dt)
    if MPS.role == "client" then return end      -- the host runs every enemy
    X.updateStreaming(false, dt)
    spawnTimer = spawnTimer - dt
    if spawnTimer <= 0 then
        spawnTimer = max(1.2, 3 - world.kills * 0.015)
        X.fillRegion("desert")                    -- desert: whole groups of 5
    end
    frozenSpawnTimer = frozenSpawnTimer - dt
    if frozenSpawnTimer <= 0 then
        frozenSpawnTimer = max(1.4, 3.2 - max(0, world.kills - K.REGION_UNLOCK_KILLS) * 0.02)
        X.fillRegion("frozen")                    -- the other regions: scattered
        X.fillRegion("swamp")
        X.fillRegion("volcanic")
        X.fillRegion("spooky")
    end
end

------------------------------------------------------------------------------
-- Weather: rain (desert, -10% visibility) and blizzards (frozen, -50%)
------------------------------------------------------------------------------
local function updateWeather(dt)
    for id, w in pairs(weather) do
      if MPS.role ~= "client" then             -- clients get the weather from the host
        local info = WEATHER_INFO[REGIONS[id].weather]
        if admin.on and admin.weather == "storm" then
            w.active, w.t = true, max(w.t, 60)
        elseif admin.on and admin.weather == "clear" then
            w.active, w.next = false, max(w.next, 30)
        end
        if w.active then
            w.t = w.t - dt
            w.intensity = min(1, w.intensity + dt / 8)
            if w.t <= 0 then
                w.active = false
                w.next = randRange(180, 360)
                stats.weatherSurvived = stats.weatherSurvived + 1
                if player.region == id then
                    addMessage("The " .. info.name:lower() .. " is clearing up.", { 0.8, 0.85, 0.9 })
                end
            end
        else
            w.intensity = max(0, w.intensity - dt / 8)
            w.next = w.next - dt
            if w.next <= 0 then
                w.next = randRange(60, 120)
                -- weather is rare: only a 30% chance at each check
                if (id == "desert" or regionUnlocked) and rand() < 0.3 then
                    w.active = true
                    w.t = randRange(110, 135)   -- roughly two minutes
                    if player.region == id then
                        addMessage(info.name .. " is rolling in! (" .. info.desc .. " for you AND enemies)",
                            id == "frozen" and { 0.85, 0.92, 1 } or { 0.6, 0.7, 0.95 })
                        if id == "desert" then playSfx("thunder", 0.1, 0.6) else playSfx("snowball_throw", 0, 0.1) end
                    end
                end
            end
        end
      end
    end

    -- Lightning & thunder during desert rain
    local dw = weather.desert
    if dw.active and dw.intensity > 0.5 and player.region == "desert" then
        lightningTimer = lightningTimer - dt
        if lightningTimer <= 0 then
            lightningTimer = randRange(10, 26)
            lightning = 1
            thunderDelay = randRange(0.3, 1.5)
        end
    end
    if thunderDelay then
        thunderDelay = thunderDelay - dt
        if thunderDelay <= 0 then
            thunderDelay = nil
            playSfx("thunder", 0.15)
            addShake(3)
        end
    end

    -- Screen-space precipitation
    local sw, sh = lg.getDimensions()
    if player.region == "desert" then
        for _, d in ipairs(rainDrops) do
            d.y = d.y + d.spd * dt
            d.x = d.x - d.spd * 0.18 * dt
            if d.y > sh + 20 or d.x < -40 then d.y = -randRange(10, 80) d.x = rand() * (sw + 120) end
        end
    elseif player.region == "spooky" then
        -- drifting embers / spirits rise slowly
        for _, f in ipairs(snowFlakes) do
            f.x = f.x + sin(menuTime * 1.3 + f.ph) * 18 * dt
            f.y = f.y - (12 + f.vy * 0.25) * f.z * dt
            if f.y < -20 then f.y = sh + 10 f.x = rand() * sw end
        end
    else
        local blz = weather.frozen.intensity
        for _, f in ipairs(snowFlakes) do
            f.x = f.x + ((f.vx + blz * 520) * f.z + sin(menuTime * 2 + f.ph) * 12) * dt
            f.y = f.y + (f.vy + blz * 90) * f.z * dt
            if f.x > sw + 20 then f.x = -10 f.y = rand() * sh end
            if f.x < -20 then f.x = sw + 10 end
            if f.y > sh + 20 then f.y = -10 f.x = rand() * sw end
        end
    end
end

local function updateWeatherAudio()
    if not rainLoop or not ambient then return end
    local v = settings.volume
    local want = (gameState == "play" and X.BF and not X.BF.done) and 1 or 0
    X.bossMix = (X.bossMix or 0) + (want - (X.bossMix or 0)) * 0.03
    if musicSrc then musicSrc:setVolume(settings.music and 0.3 * v * (1 - X.bossMix) or 0) end
    if X.bossMusic then X.bossMusic:setVolume(settings.music and 0.42 * v * X.bossMix or 0) end
    if X.cricketLoop then
        local cv = 0
        if gameState == "play" and player then
            cv = X.darkness() * (player.region == "frozen" and 0 or (player.region == "spooky" and 0.18 or 0.3)) * v
            if overlay == "pause" and not MPS.online then cv = cv * 0.4 end
        end
        X.cricketLoop:setVolume(cv)
    end
    if gameState ~= "play" or not weather then
        rainLoop:setVolume(0)
        blizzardLoop:setVolume(0)
        ambient:setPitch(1)
        ambient:setVolume(0.18 * v)
        return
    end
    local inFrozen = player.region == "frozen"
    local paused = (overlay == "pause" and not MPS.online) and 0.4 or 1
    local inSpooky = player.region == "spooky"
    rainLoop:setVolume(player.region == "desert" and weather.desert.intensity * 0.45 * v * paused or 0)
    local inVolc, inSwamp = player.region == "volcanic", player.region == "swamp"
    if inVolc then
        -- the ash storm reuses the blizzard wind, lower and darker
        blizzardLoop:setPitch(0.6)
        blizzardLoop:setVolume(weather.volcanic.intensity * 0.45 * v * paused)
    else
        blizzardLoop:setPitch(1)
        blizzardLoop:setVolume(inFrozen and weather.frozen.intensity * 0.6 * v * paused or 0)
    end
    ambient:setPitch(inFrozen and 0.72 or (inSpooky and 0.5 or (inVolc and 0.42 or (inSwamp and 0.85 or 1))))
    ambient:setVolume((inFrozen and 0.24 or (inSpooky and 0.22 or (inVolc and 0.3 or 0.18))) * v)
end

local function updateCamera(dt)
    if X.cut then return end          -- the cutscene moves the camera
    X.camZoom = 1
    local mx, my = mouseWorld()
    local tx = player.x + clamp((mx - player.x) * 0.18, -140, 140)
    local ty = player.y + clamp((my - player.y) * 0.18, -110, 110)
    local spec = player.out and X.spectateTarget()
    if spec then tx, ty = spec.x, spec.y end
    local k = min(1, dt * 7)
    cam.x, cam.y = lerp(cam.x, tx, k), lerp(cam.y, ty, k)
end

------------------------------------------------------------------------------
-- Players, the safe shed, region streaming, weapons, kills, multiplayer sync,
-- day / night. (Everything lives in X to stay under Lua's local-variable limit.)
------------------------------------------------------------------------------
do
local DAY_LEN = 360                 -- one full day/night cycle: 3 minutes of day, 3 minutes of night
X.DAY_LEN = DAY_LEN

-- ENDLESS WAVES: a new wave every 3 days (day 4 = wave 1, day 7 = wave 2 ...)
X.WAVE_DAYS = 3
-- ENDLESS: one wave per day (day 1 = wave 1). Wave 5 is the LAST WAVE: it lasts until you die.
X.WAVE_SIZES = { 5, 7, 9, 10, 20 }
X.LAST_WAVE = 5
function X.groupSize()
    if not X.endless then return 5 end
    return X.WAVE_SIZES[clamp(world.wave or 1, 1, X.LAST_WAVE)]
end
function X.waveFor(day) return min(X.LAST_WAVE, max(1, day or 1)) end
function X.nextWaveDay() return (world.wave or 1) + 1 end
-- the last wave: every enemy sees 15% farther and moves 15% faster (FOV unchanged)
function X.applyLastForm(e)
    if e.lastForm or X.BOSSES[e.kind] then return end
    e.lastForm = true
    e.vision = e.vision * 1.15
    e.speed, e.huntSpeed = e.speed * 1.15, e.huntSpeed * 1.15
end
function X.waveBanner()
    playSfx("wave_horn")
    local n = X.groupSize()
    if world.wave >= X.LAST_WAVE then
        showBanner("LAST WAVE: Wave " .. X.LAST_WAVE, "Survive as long as you can. Enemies have adapted, they are on their last form",
            { 1, 0.3, 0.2 })
        addMessage("LAST WAVE: groups of " .. n .. " - every enemy sees 15% farther and moves 15% faster.", { 1, 0.35, 0.25 })
        if X.achieve then X.achieve("survivor") end
    else
        showBanner("WAVE " .. world.wave, "Bandit groups and Bow Wielders: " .. n .. " strong", { 1, 0.45, 0.25 })
    end
end
-- a new wave (host / single player): enemies nobody can see are swapped for new, bigger groups
function X.startWave(w)
    world.wave = w
    for _, e in ipairs(enemies) do
        if not e.dead and not X.BOSSES[e.kind] and X.nearestPlayerDist(e.x, e.y, e.region) > 1100 then
            e.dead, e.unloaded = true, true
        end
    end
    for k in pairs(world.stash) do world.stash[k] = {} end
    if w >= X.LAST_WAVE then
        for _, e in ipairs(enemies) do if not e.dead then X.applyLastForm(e) end end
    end
    X.waveBanner()
end

-- every player this machine knows about: the local one plus remote ones
function X.allPlayers()
    local list = { me }
    for _, o in pairs(MPS.others) do
        if o.ready then list[#list + 1] = o end
    end
    return list
end

local function playersInRegion(region)
    local out = {}
    for _, p in ipairs(X.allPlayers()) do
        if p.region == region then out[#out + 1] = p end
    end
    return out
end
X.playersInRegion = playersInRegion

-- Each enemy hunts the closest player in its region (players inside the shed are ignored
-- unless there is nobody else). The choice is re-evaluated every 0.6 s to avoid jitter.
function X.pickTarget(e, dt)
    if X.decoys[1] then
        local d = X.decoyFor(e)
        if d then return d end
    end
    if not MPS.online then return me end
    e.tgtT = (e.tgtT or 0) - dt
    local cur = e.tgt
    if cur and e.tgtT > 0 and not cur.dead and cur.region == e.region and (cur == me or MPS.others[cur.id] == cur) then
        return cur
    end
    e.tgtT = 0.6
    local best, bd = nil, math.huge
    for _, p in ipairs(X.allPlayers()) do
        if not p.dead and p.region == e.region then
            local d = dist(e.x, e.y, p.x, p.y)
            if X.inShed(p.x, p.y) then d = d + 50000 end
            if d < bd then best, bd = p, d end
        end
    end
    e.tgt = best or me
    return e.tgt
end

function X.anchorFor(region)
    local ps = playersInRegion(region)
    if #ps == 0 then return nil end
    return ps[randInt(1, #ps)]
end

function X.nearestPlayerDist(x, y, region)
    local best = math.huge
    for _, p in ipairs(X.allPlayers()) do
        if (not region or p.region == region) then
            local d = dist(x, y, p.x, p.y)
            if d < best then best = d end
        end
    end
    return best
end

------------------------------------------------------------------------------
-- The spawn shed: fits 4 people, enemies can't see in or enter
------------------------------------------------------------------------------
X.SHED = { x = K.WORLD_W / 2 - 100, y = K.WORLD_H / 2 - 85, w = 200, h = 170, t = 16, door = 64 }

function X.buildShed()
    local S = X.SHED
    floors[#floors + 1] = { x = S.x, y = S.y, w = S.w, h = S.h, kind = "shed" }
    addWall(S.x, S.y, S.w, S.t, "shed")
    addWall(S.x, S.y + S.t, S.t, S.h - S.t, "shed")
    addWall(S.x + S.w - S.t, S.y + S.t, S.t, S.h - S.t, "shed")
    local seg = (S.w - S.door) / 2
    addWall(S.x, S.y + S.h - S.t, seg, S.t, "shed")
    addWall(S.x + seg + S.door, S.y + S.h - S.t, seg, S.t, "shed")
    -- invisible barrier that only stops enemies (covers the inside and the doorway)
    local z = addWall(S.x + S.t, S.y + S.t, S.w - 2 * S.t, S.h - S.t + 30, "shedzone")
    z.enemyOnly = true
    X.shedZone = z
end

function X.inShed(x, y)
    local S = X.SHED
    return x > S.x + S.t - 4 and x < S.x + S.w - S.t + 4 and y > S.y + S.t - 4 and y < S.y + S.h - S.t + 6
end

function X.shedSpot(i)
    local S = X.SHED
    local cx, cy = S.x + S.w / 2, S.y + S.h / 2 - 6
    i = ((i or 1) - 1) % 4
    return cx + ((i % 2 == 0) and -40 or 40), cy + ((i < 2) and -24 or 24)
end

------------------------------------------------------------------------------
-- Region streaming: a region is only simulated while a player is inside it.
-- Enemies of empty regions (or far away from every player) are REMOVED and
-- remembered by kind; they are spawned back when someone comes near again.
------------------------------------------------------------------------------
local streamT = 0
function X.updateStreaming(force, dt)
    if MPS.role == "client" then return end
    streamT = streamT - (dt or 0)
    if not force and streamT > 0 then return end
    streamT = 0.5
    for _, e in ipairs(enemies) do
        if not e.dead then
            local d = X.nearestPlayerDist(e.x, e.y, e.region)
            local far = d > 4200 or (d > 3200 and e.state == "patrol")
            if e.kind == "bowman" or X.BOSSES[e.kind] or e.necro or e.kind == "goblin" then far = false d = 0 end   -- the Stronghold garrison / the boss stay
            if d == math.huge or far then
                local list = world.stash[e.region]
                list[#list + 1] = e.kind
                e.dead, e.unloaded = true, true
            end
        end
    end
    for i = #bullets, 1, -1 do
        local b = bullets[i]
        if b.owner == "enemy" and X.nearestPlayerDist(b.x, b.y, regionAt(b.x, b.y)) == math.huge then table.remove(bullets, i) end
    end
end

-- Spawns enemies near players: stashed (unloaded) ones first, then fresh ones.
function X.fillRegion(region, budget)
    if X.BF then return end            -- only the boss (and its gourds) during the fight
    if region == "frozen" and not regionUnlocked then return end
    if region == "spooky" and not world.spookyOpen then return end
    if region == "swamp" and not world.swampOpen then return end
    if region == "volcanic" and not world.volcOpen then return end
    if #playersInRegion(region) == 0 then return end
    local have = countIn(enemies, region)
    local cap = maxEnemies(region)
    local stash = world.stash[region]
    if region == "desert" then
        if have + X.groupSize() > cap then return end
        local g = {}
        for i = 1, X.groupSize() do g[i] = table.remove(stash) or randomKind("desert") end
        spawnGroup(g, 900)
    else
        for _ = 1, budget or 1 do
            if have >= cap then return end
            local k = table.remove(stash) or randomKind(region)
            local e = spawnEnemy(k, 900)
            have = have + 1
            if e and X.PAIRED[k] then
                -- its partner (and one stashed copy of the same kind is used up)
                for i = #stash, 1, -1 do if stash[i] == k then table.remove(stash, i) break end end
                local px, py
                for _ = 1, 25 do
                    local a, d = rand() * 2 * pi, randRange(40, 90)
                    local x, y = e.x + cos(a) * d, e.y + sin(a) * d
                    if areaFree(x - 16, y - 16, 32, 32, 4) and not X.inAnyPool(x, y, 10) then px, py = x, y break end
                end
                local m = spawnEnemy(k, 900, px or e.x, py or e.y)
                if m then m.homeX, m.homeY = e.homeX, e.homeY have = have + 1 end
            end
        end
    end
end

------------------------------------------------------------------------------
-- Loot boxes are per-player ("instanced"): each machine keeps its own boxes
-- around its own player.
------------------------------------------------------------------------------
local boxCaps = { desert = K.MAX_BOXES, frozen = K.MAX_FROZEN_BOXES, swamp = K.MAX_SPOOKY_BOXES,
                  volcanic = K.MAX_SPOOKY_BOXES, spooky = K.MAX_SPOOKY_BOXES }
local boxT = 0
function X.updateBoxes(dt)
    boxT = boxT - dt
    if boxT > 0 then return end
    boxT = 2.5
    for i = #boxes, 1, -1 do
        if dist(boxes[i].x, boxes[i].y, me.x, me.y) > 6500 then table.remove(boxes, i) end
    end
    local near = 0
    for _, b in ipairs(boxes) do
        if regionAt(b.x, b.y) == me.region and dist(b.x, b.y, me.x, me.y) < 3400 then near = near + 1 end
    end
    if near < boxCaps[me.region] then spawnBox(500, nil, nil, me.region) end
end

------------------------------------------------------------------------------
-- World sound / text / ring / message helpers: played here AND sent to others
------------------------------------------------------------------------------
function X.wsfx(name, x, y, pitch, volMul)
    playSfx(name, pitch, (volMul or 1) * volAt(x, y))
    if MPS.role == "host" then NET.broadcast({ t = "sfx", n = name, x = floor(x), y = floor(y), p = pitch, v = volMul }) end
end

function X.wtext(x, y, text, col, big)
    addText(x, y, text, col, big)
    if MPS.role == "host" then NET.broadcast({ t = "txt", x = floor(x), y = floor(y), s = text, c = col, b = big and 1 or 0 }) end
end

function X.wring(x, y, maxR, col, life)
    rings[#rings + 1] = { x = x, y = y, r = 0, max = maxR, life = life or 1, maxLife = life or 1, col = col }
    if MPS.role == "host" then NET.broadcast({ t = "ring", x = floor(x), y = floor(y), m = maxR, c = col, l = life or 1 }) end
end

function X.wmsg(text, col, chat)
    addMessage(text, col)
    if chat then X.chatAdd(nil, text, col) end
    if MPS.role == "host" then NET.broadcast({ t = "msg", s = text, c = col, ch = chat and 1 or 0 }) end
end

------------------------------------------------------------------------------
-- Chat (T): messages show in the bottom-left corner. In multiplayer the host
-- relays every message to all players.
------------------------------------------------------------------------------
X.chat = { open = false, text = "", log = {}, skipT = -1 }

function X.cleanChat(s)
    s = tostring(s or ""):gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 80 then s = s:sub(1, 80) end
    return s
end

function X.chatAdd(name, text, col)
    local L = X.chat.log
    L[#L + 1] = { name = name, text = text, col = col, t = love.timer.getTime() }
    while #L > 40 do table.remove(L, 1) end
end

-- player messages (name) or system lines (sys = true, sent by this machine about itself)
function X.sendChat(name, text, sys)
    text = X.cleanChat(text)
    if #text == 0 then return end
    local col = sys and { 1, 0.75, 0.45 } or nil
    if MPS.role == "host" and MPS.online then
        if not sys then X.chatAdd(name, text) end
        NET.broadcast({ t = "chat", n = name, s = text, c = col })
    elseif MPS.role == "client" and MPS.online then
        NET.toHost({ t = "chat", s = text, sys = sys and 1 or 0 })
    elseif not sys then
        X.chatAdd(name, text)
    end
end

-- host: a chat line arrived from a client
function X.hostChat(id, o, m)
    local text = X.cleanChat(m.s)
    if not o or #text == 0 then return end
    if m.sys == 1 then
        X.chatAdd(nil, text, { 1, 0.75, 0.45 })
        NET.broadcast({ t = "chat", s = text, c = { 1, 0.75, 0.45 } }, false, id)
    else
        X.chatAdd(o.name, text)
        NET.broadcast({ t = "chat", n = o.name, s = text })
        playSfx("click", 0.1, 0.6)
    end
end

function X.chatKey(key)
    local C = X.chat
    if key == "escape" then
        C.open, C.text = false, ""
    elseif key == "return" or key == "kpenter" then
        if #X.cleanChat(C.text) > 0 then X.sendChat(MPS.online and MPS.name or PROF.data.name, C.text) end
        C.open, C.text = false, ""
    elseif key == "backspace" then
        local ok, utf8 = pcall(require, "utf8")
        local off = ok and utf8.offset(C.text, -1)
        if off then C.text = C.text:sub(1, off - 1) else C.text = C.text:sub(1, -2) end
    end
end

function X.chatText(t)
    local C = X.chat
    if t:lower() == "t" and love.timer.getTime() - C.skipT < 0.1 then C.skipT = -1 return end   -- the T that opened the chat
    if #C.text + #t <= 80 then C.text = C.text .. t end
end

-- everyone (me + ready remote players) is out of hearts
function X.teamOut()
    if not me.out then return false end
    for _, o in pairs(MPS.others) do
        if o.ready and not o.out then return false end
    end
    return true
end

function X.spectateTarget()
    for _, o in pairs(MPS.others) do
        if o.ready and not o.dead and o.x then return o end
    end
end

------------------------------------------------------------------------------
-- Melee hits from enemies. `player` is the enemy's current target here; a
-- remote target gets the hit sent over the network and resolves it itself.
------------------------------------------------------------------------------
function X.applyMelee(kind, dmg, ex, ey, ang)
    if player.dead then return end
    if player.iframes > 0 and kind ~= "bite" then
        stats.dodges = stats.dodges + 1
        addText(player.x, player.y - 30, "DODGE", { 0.6, 0.9, 1 })
        return
    end
    if kind == "bite" then
        if player.iframes > 0 then return end
        damagePlayer(5, ex, ey, "bite")
        playSfx("bite", 0.1)
        return
    end
    if kind == "pass" then
        -- a Lava Serpent darted through you
        damagePlayer(dmg, ex, ey, "pass")
        player.serpSlowT = 3
        spawnParticles(player.x, player.y, 12, { 1, 0.5, 0.1 }, 50, 200, 0.4, 3)
        addText(player.x, player.y - 40, "SCORCHED -10% speed", { 1, 0.55, 0.2 })
        return
    end
    local blocked = damagePlayer(dmg, ex, ey, "melee")
    if kind == "fireburn" and not blocked then
        addText(player.x, player.y - 44, "FIREBURN!", { 1, 0.5, 0.1 }, true)
        spawnParticles(player.x, player.y, 14, { 1, 0.45, 0.1 }, 50, 220, 0.5, 3.5)
    elseif kind == "tongue" then
        spawnParticles(player.x, player.y, 8, { 0.95, 0.4, 0.6 }, 40, 160, 0.4, 2.5, ang, 0.8)
    elseif kind == "croc" then
        addShake(5)
        spawnParticles(player.x, player.y, 12, { 0.7, 0.1, 0.08 }, 60, 220, 0.5, 3, ang, 0.8)
    end
    if kind == "branch" then
        local kb = blocked and 90 or 300
        player.kbx = player.kbx + cos(ang) * kb
        player.kby = player.kby + sin(ang) * kb
        spawnParticles(player.x, player.y, 8, { 0.5, 0.33, 0.18 }, 50, 180, 0.4, 2.5, ang, 0.8)
    elseif kind == "gourd" then
        spawnParticles(player.x, player.y, 8, { 0.95, 0.55, 0.1 }, 50, 180, 0.4, 2.5, ang, 0.8)
        if not blocked and not player.dead and rand() < 0.10 then X.spookPlayer() end
    end
end

function X.meleeHit(kind, dmg, ex, ey, ang)
    if player.decoy then X.hurtDecoy(player.decoy, dmg) return end
    if player.remote then
        NET.send(player.id, { t = "mel", k = kind, d = dmg, x = ex, y = ey, a = ang })
        return
    end
    X.applyMelee(kind, dmg, ex, ey, ang)
end

-- Host: enemy projectiles are simulated on every machine; each machine only
-- applies damage to its own player.
function X.netEnemyShot(b)
    if MPS.role ~= "host" then return end
    NET.broadcast({ t = "es", k = b.kind, x = b.x, y = b.y, vx = b.vx, vy = b.vy, d = b.dmg,
        sx = b.srcX, sy = b.srcY, l = b.land, life = b.life })
end

------------------------------------------------------------------------------
-- Weapons
------------------------------------------------------------------------------
X.beams = {}

local function addBeam(x1, y1, x2, y2, col)
    X.beams[#X.beams + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, life = 0.14, col = col }
end

-- distance (0..1 of the segment) to the first wall, or nil
local function firstWall(x1, y1, x2, y2)
    local buf, n = WG.query(min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1), WG.buf2)
    local best
    for i = 1, n do
        local w = buf[i]
        if not w.enemyOnly then
            local hit, t = segRect(x1, y1, x2, y2, w)
            if hit and (not best or t < best) then best = t end
        end
    end
    return best
end
X.firstWall = firstWall

-- Local hit on an enemy: real damage on the host / single player,
-- prediction + a "hit" message on a client.
function X.hitEnemy(e, dmg, ang, crit, icy, fx)
    if e.dead then return end
    if e.kind == "guardian" and fx and fx:find("x", 1, true) then
        addText(e.x, e.y - e.r - 10, "IMMUNE", { 0.75, 0.75, 0.8 })
        return
    end
    if X.gkShielded(e) then X.reflectToMe(dmg, e.x, e.y) return end
    if MPS.role == "client" then
        local shown = dmg + (icy and 5 or 0)
        if fx and fx:find("m", 1, true) then shown = max(shown, math.ceil(e.hp)) end   -- Guided Missile (the host makes the real kill)
        e.hitFlash = 0.12
        stats.damageDealt = stats.damageDealt + min(shown, max(0, e.hp))
        e.hp = e.hp - shown
        local col = icy and { 0.6, 0.9, 1 } or (crit and { 1, 0.75, 0.2 } or { 1, 1, 1 })
        if shown > 0 then addText(e.x, e.y - 20, tostring(shown), col, crit)
        else addText(e.x, e.y - 20, "BURN", { 1, 0.55, 0.15 }) end
        playSfx("hit", 0.15, 0.8)
        spawnParticles(e.x, e.y, 8, e.region == "frozen" and { 0.8, 0.92, 1 } or (e.region == "spooky" and { 0.45, 0.2, 0.6 } or { 0.65, 0.1, 0.08 }),
            60, 220, 0.4, 3, ang, 0.6)
        NET.toHost({ t = "hit", e = e.id, d = dmg, a = ang, c = crit and 1 or 0, i = icy and 1 or 0, f = fx })
    else
        damageEnemy(e, dmg, ang, crit, icy, MPS.id, fx)
    end
end

function X.explode(x, y, owner, shot, radius, look)
    radius = radius or WEAPONS.rpg.blast
    playSfx("explosion", 0.08, max(0.25, volAt(x, y)))
    local dd = dist(x, y, me.x, me.y)
    addShake(max(0, 14 - dd / 60))
    if look == "meteor" then
        spawnParticles(x, y, 40, { 1, 0.45, 0.1 }, 100, 420, 0.6, 6)
        spawnParticles(x, y, 24, { 0.4, 0.3, 0.25 }, 60, 260, 1.2, 6)
    else
        spawnParticles(x, y, 34, { 1, 0.6, 0.15 }, 80, 380, 0.5, 5)
        spawnParticles(x, y, 20, { 1, 0.9, 0.4 }, 40, 220, 0.3, 4)
    end
    spawnParticles(x, y, 18, { 0.3, 0.28, 0.26 }, 20, 120, 1.4, 7, nil, nil, 1.5)
    rings[#rings + 1] = { x = x, y = y, r = 0, max = radius, life = 0.35, maxLife = 0.35, col = { 1, 0.7, 0.3 } }
    decals[#decals + 1] = { x = x, y = y, r = radius * 0.3, a = rand() * 6, kind = "scorch", life = 25 }
    if owner == "player" and shot then
        for _, e in ipairs(enemies) do
            if not e.dead and e.hidden <= 0 and dist(x, y, e.x, e.y) <= radius + e.r and hasLOS(x, y, e.x, e.y) then
                if not shot.hit then shot.hit = true stats.shotsHit = stats.shotsHit + 1 end
                X.hitEnemy(e, shot.dmg, atan2(e.y - y, e.x - x), shot.crit, shot.icy, shot.fx)
            end
        end
    end
end

------------------------------------------------------------------------------
-- Black holes & meteors (they live for a moment after the shot)
------------------------------------------------------------------------------
X.vortices, X.meteors = {}, {}

-- real = this machine moves / damages the enemies (host or single player)
function X.spawnVortex(x, y, dmg, by, real)
    X.vortices[#X.vortices + 1] = { x = x, y = y, t = 2, dmg = dmg, by = by, real = real }
    playSfx("blackhole", 0.05, max(0.3, volAt(x, y)))
end

function X.updateVortices(dt)
    for i = #X.vortices, 1, -1 do
        local v = X.vortices[i]
        v.t = v.t - dt
        if rand() < 0.8 then
            local a, d = rand() * 2 * pi, randRange(60, 200)
            particles[#particles + 1] = { x = v.x + cos(a) * d, y = v.y + sin(a) * d, vx = -cos(a) * d * 2, vy = -sin(a) * d * 2,
                life = 0.45, maxLife = 0.45, color = { 0.55, 0.25, 0.85 }, size = 3, drag = 0 }
        end
        if v.real then
            for _, e in ipairs(enemies) do
                if not e.dead and e.hidden <= 0 then
                    local d = dist(e.x, e.y, v.x, v.y)
                    if d < 230 and d > 8 and not X.BOSSES[e.kind] then
                        local pull = 260 * dt
                        moveEntity(e, (v.x - e.x) / d * pull, (v.y - e.y) / d * pull)
                    end
                end
            end
        end
        if v.t <= 0 then
            table.remove(X.vortices, i)
            playSfx("explosion", 0.2, max(0.3, volAt(v.x, v.y)) * 0.8)
            rings[#rings + 1] = { x = v.x, y = v.y, r = 0, max = 170, life = 0.4, maxLife = 0.4, col = { 0.7, 0.35, 1 } }
            spawnParticles(v.x, v.y, 40, { 0.65, 0.3, 1 }, 80, 360, 0.5, 4)
            if v.real then
                for _, e in ipairs(enemies) do
                    if not e.dead and e.hidden <= 0 and dist(e.x, e.y, v.x, v.y) <= 160 + e.r then
                        damageEnemy(e, v.dmg, atan2(e.y - v.y, e.x - v.x), false, false, v.by, "x")
                    end
                end
            end
        end
    end
    for i = #X.meteors, 1, -1 do
        local m = X.meteors[i]
        m.t = m.t - dt
        if m.t <= 0 then
            table.remove(X.meteors, i)
            X.explode(m.x, m.y, m.owner, m.shot, WEAPONS.meteor.blast, "meteor")
        end
    end
end

------------------------------------------------------------------------------
-- Weapons
------------------------------------------------------------------------------
-- Creates the projectiles / beams for one trigger pull.
-- owner = "player" (real, deals damage) or "remote" (another player's shot, visual only)
-- aim = distance to the cursor (meteors), shooter = the remote player object (boomerangs fly back to it)
function X.fireWeapon(wid, x, y, ang, icy, owner, shot, aim, shooter)
    local w = WEAPONS[wid] or WEAPONS.pistol
    local sx, sy = x + cos(ang) * 22, y + sin(ang) * 22
    local real = owner == "player"
    local function hit(e, a)
        if not real then return end
        if not shot.hit then shot.hit = true stats.shotsHit = stats.shotsHit + 1 end
        X.hitEnemy(e, shot.dmg, a, shot.crit, icy, w.fx)
    end

    if w.kind == "laser" then
        local ex, ey = x + cos(ang) * (w.range + 14), y + sin(ang) * (w.range + 14)
        local wt = firstWall(sx, sy, ex, ey)
        if wt then ex, ey = sx + (ex - sx) * wt, sy + (ey - sy) * wt end
        addBeam(sx, sy, ex, ey, icy and { 0.6, 0.9, 1 } or { 1, 0.25, 0.35 })
        spawnParticles(ex, ey, 8, { 1, 0.4, 0.5 }, 40, 160, 0.25, 2.5)
        for _, e in ipairs(enemies) do
            if not e.dead and e.hidden <= 0 and segCircle(sx, sy, ex, ey, e.x, e.y, e.r + 6) then
                spawnParticles(e.x, e.y, 6, { 1, 0.35, 0.45 }, 40, 140, 0.3, 2.5)
                hit(e, ang)
            end
        end
        return
    elseif w.kind == "hammer" then
        -- melee smash in a 140-degree arc in front of you
        rings[#rings + 1] = { x = x + cos(ang) * 30, y = y + sin(ang) * 30, r = 0, max = 55, life = 0.25, maxLife = 0.25, col = { 0.75, 0.55, 1 } }
        spawnParticles(x + cos(ang) * 40, y + sin(ang) * 40, 14, { 0.75, 0.6, 1 }, 60, 240, 0.35, 3, ang, 0.9)
        for _, e in ipairs(enemies) do
            if not e.dead and e.hidden <= 0 then
                local d = dist(x, y, e.x, e.y)
                if d <= w.range + e.r + 14 and abs(angleDiff(ang, atan2(e.y - y, e.x - x))) < math.rad(70) then
                    hit(e, atan2(e.y - y, e.x - x))
                end
            end
        end
        return
    elseif w.kind == "tesla" then
        -- lightning: first enemy in front of you, then jumps to the nearest others
        local hitList, cx, cy = {}, sx, sy
        local first, fd = nil, math.huge
        for _, e in ipairs(enemies) do
            if not e.dead and e.hidden <= 0 then
                local d = dist(x, y, e.x, e.y)
                if d < w.range and abs(angleDiff(ang, atan2(e.y - y, e.x - x))) < 0.45 and d < fd and hasLOS(x, y, e.x, e.y) then
                    first, fd = e, d
                end
            end
        end
        local cur = first
        while cur and #hitList < (w.chain or 3) do
            hitList[#hitList + 1] = cur
            cur.teslaMark = true
            addBeam(cx, cy, cur.x, cur.y, { 0.55, 0.8, 1 })
            spawnParticles(cur.x, cur.y, 8, { 0.7, 0.9, 1 }, 60, 200, 0.25, 2.5)
            hit(cur, atan2(cur.y - cy, cur.x - cx))
            cx, cy = cur.x, cur.y
            local nxt, nd = nil, 230
            for _, e in ipairs(enemies) do
                if not e.dead and e.hidden <= 0 and not e.teslaMark then
                    local d = dist(cx, cy, e.x, e.y)
                    if d < nd then nxt, nd = e, d end
                end
            end
            cur = nxt
        end
        for _, e in ipairs(hitList) do e.teslaMark = nil end
        if not first then
            -- crackle into the air
            addBeam(sx, sy, x + cos(ang) * w.range * 0.6, y + sin(ang) * w.range * 0.6, { 0.55, 0.8, 1 })
        end
        return
    elseif w.kind == "meteor" then
        local d = min(w.range, max(80, aim or w.range))
        X.meteors[#X.meteors + 1] = { x = x + cos(ang) * d, y = y + sin(ang) * d, t = 1, maxT = 1, owner = owner, shot = shot }
        return
    end

    for i = 1, w.pellets do
        local a
        if w.pellets > 1 then
            a = ang + lerp(-w.spread, w.spread, (i - 1) / (w.pellets - 1)) + randRange(-0.04, 0.04)
        else
            a = ang + randRange(-w.spread, w.spread)
        end
        local sp = w.speed * randRange(0.96, 1.03)
        local kind
        if w.kind == "rocket" or w.kind == "flame" or w.kind == "boomerang" or w.kind == "missile" then kind = w.kind end
        if w.kind == "blackhole" then kind = "bhole" end
        local range = w.range
        if real and wid == "cannon" then range = range * (1 + (me.cannonBonus or 0)) end   -- Tanky Plate
        bullets[#bullets + 1] = {
            x = sx, y = sy, vx = cos(a) * sp, vy = sin(a) * sp, life = range / sp, owner = owner,
            shot = shot, weapon = wid, icy = icy, kind = kind, look = (shot and shot.blaze) and "blaze" or w.look,
            fx = shot and shot.fx or w.fx,
            pierce = w.pierce, ghost = w.ghost, homing = w.homing,
            travel = 0, range = w.range, home = owner == "player" and me or shooter,
        }
        if kind == "boomerang" then
            bullets[#bullets].life = 3
            bullets[#bullets].shot2 = {}
        elseif kind == "missile" then
            bullets[#bullets].target = X.missileLock(x + cos(ang) * (aim or 0), y + sin(ang) * (aim or 0))
        end
    end
end

------------------------------------------------------------------------------
-- The Stronghold: one rare fortress in the Dustbowl Frontier, guarded by Bow Wielders
------------------------------------------------------------------------------
function X.buildStronghold()
    local w, h, t, gate = 1100, 820, 30, 130
    for _ = 1, 600 do
        local x = randRange(400, K.WORLD_W - w - 400)
        local y = randRange(400, K.WORLD_H - h - 400)
        if dist(x + w / 2, y + h / 2, K.WORLD_W / 2, K.WORLD_H / 2) > 2600 and areaFree(x - 80, y - 80, w + 160, h + 160) then
            X.SH = { x = x, y = y, w = w, h = h, cx = x + w / 2, cy = y + h / 2, leash = 760 }
            floors[#floors + 1] = { x = x, y = y, w = w, h = h, kind = "stronghold" }
            local seg = (w - gate) / 2
            addWall(x, y, seg, t, "fort") addWall(x + seg + gate, y, seg, t, "fort")
            addWall(x, y + h - t, seg, t, "fort") addWall(x + seg + gate, y + h - t, seg, t, "fort")
            local vseg = (h - 2 * t - gate) / 2
            addWall(x, y + t, t, vseg, "fort") addWall(x, y + t + vseg + gate, t, vseg, "fort")
            addWall(x + w - t, y + t, t, vseg, "fort") addWall(x + w - t, y + t + vseg + gate, t, vseg, "fort")
            -- corner towers
            for _, c in ipairs({ { x - 25, y - 25 }, { x + w - 55, y - 25 }, { x - 25, y + h - 55 }, { x + w - 55, y + h - 55 } }) do
                addWall(c[1], c[2], 80, 80, "tower")
            end
            -- the central keep and barricades for cover
            addWall(x + w / 2 - 90, y + h / 2 - 70, 180, 140, "keep")
            addWall(x + 190, y + 170, 170, 24, "barricade")
            addWall(x + w - 360, y + 170, 170, 24, "barricade")
            addWall(x + 190, y + h - 194, 170, 24, "barricade")
            addWall(x + w - 360, y + h - 194, 170, 24, "barricade")
            addWall(x + 160, y + h / 2 - 80, 24, 160, "barricade")
            addWall(x + w - 184, y + h / 2 - 80, 24, 160, "barricade")
            return
        end
    end
end

-- Bow Wielders spawn only inside the Stronghold: 5 at a time, every 5 minutes, at most 40
function X.spawnBowmen(n)
    local S = X.SH
    if not S then return 0 end
    local have = 0
    for _, e in ipairs(enemies) do if not e.dead and e.kind == "bowman" then have = have + 1 end end
    local made = 0
    for _ = 1, min(n, 40 - have) do
        for _ = 1, 40 do
            local px, py = randRange(S.x + 60, S.x + S.w - 60), randRange(S.y + 60, S.y + S.h - 60)
            X.shOpen = true
            local free = areaFree(px - 18, py - 18, 36, 36, 6)
            X.shOpen = false
            if free then
                local e = spawnEnemy("bowman", nil, px, py)
                if e then e.homeX, e.homeY = S.cx, S.cy made = made + 1 end
                break
            end
        end
    end
    return made
end

function X.updateStronghold(dt)
    if MPS.role == "client" or not X.SH or X.BF then return end
    world.shT = (world.shT or 300) - dt
    if world.shT <= 0 then
        world.shT = 300
        local made = X.spawnBowmen(X.groupSize())
        if made > 0 and dist(me.x, me.y, X.SH.cx, X.SH.cy) < 2500 then
            X.wmsg(made .. " Bow Wielders arrived at the Stronghold!", { 0.6, 0.9, 0.45 }, true)
        end
    end
end

------------------------------------------------------------------------------
-- Kills: effects on every machine, rewards only for the killer
------------------------------------------------------------------------------
local REWARD = X.EN.reward
function X.rewardFor(kind)
    local r = REWARD[kind] or { 20, 30 }
    return randInt(r[1], r[2])
end

function X.killFx(kind, x, y, r, angle)
    if kind == "guardian" then X.guardianDeathFx(x, y) return end
    if kind == "gatekeeper" then X.gatekeeperDeathFx(x, y) return end
    playSfx("enemy_die", 0.1, volAt(x, y))
    local region = ENEMY_REGION[kind]
    if region == "spooky" then
        local col = kind == "gourd" and { 1, 0.55, 0.12 } or (kind == "witch" and { 0.6, 0.25, 0.85 } or { 0.2, 0.16, 0.25 })
        spawnParticles(x, y, 24, col, 60, 260, 0.8, 4, angle, angle and 0.9 or nil)
        spawnParticles(x, y, 10, { 0.3, 0.9, 0.4 }, 20, 90, 1.2, 3)
    elseif region == "frozen" then
        playSfx("shatter", 0.15, volAt(x, y))
        spawnParticles(x, y, 26, { 0.85, 0.95, 1 }, 60, 280, 0.8, 4, angle, angle and 0.9 or nil)
        spawnParticles(x, y, 12, { 0.55, 0.8, 1 }, 30, 140, 1.0, 3)
    else
        spawnParticles(x, y, 26, { 0.55, 0.08, 0.06 }, 60, 260, 0.7, 4, angle, angle and 0.9 or nil)
        spawnParticles(x, y, 10, { 0.8, 0.7, 0.45 }, 30, 120, 0.9, 3)
    end
    decals[#decals + 1] = { x = x, y = y, r = (r or 14) * randRange(1.2, 1.7), a = rand() * 2 * pi, kind = kind, life = 40 }
    if #decals > 160 then table.remove(decals, 1) end
end

local STAT_KEY = X.EN.statKey
local HOW_KEY = { frost = "frostKills", snowgrave = "snowgraveKills", cursed = "cursedKills" }

-- Runs on the killer's machine only
-- LEVELS: LVL 0 - 10, one level every 10 kills: +5 max HP, +5% speed, +5% gun / melee damage
X.MAX_LEVEL = 10
function X.updateLevel(p)
    local lvl = min(X.MAX_LEVEL, floor(stats.kills / 10))
    while (p.level or 0) < lvl do
        p.level = (p.level or 0) + 1
        p.maxHp = p.maxHp + 5
        p.hp = min(p.maxHp, p.hp + 5)
        playSfx("levelup")
        spawnParticles(p.x, p.y, 30, { 1, 0.85, 0.3 }, 40, 220, 0.8, 3)
        rings[#rings + 1] = { x = p.x, y = p.y, r = 0, max = 120, life = 0.6, maxLife = 0.6, col = { 1, 0.85, 0.3 } }
        if p.level >= X.MAX_LEVEL then
            addText(p.x, p.y - 60, "LEVEL MAX!", { 1, 0.85, 0.25 }, true)
            if X.achieve then X.achieve("maxlevel") end
        else
            addText(p.x, p.y - 60, "LEVEL UP!  LVL " .. p.level, { 1, 0.85, 0.25 }, true)
        end
    end
end

function X.killReward(kind, x, y, reward, drop, how)
    if (me.goldPotT or 0) > 0 then reward = floor(reward * 1.5 + 0.5) end   -- Potion of GOLD
    stats.kills = stats.kills + 1
    X.updateLevel(me)
    if stats.kills == 1 then X.achieve("firstblood") end
    if stats.kills >= 100 then X.achieve("centurion") end
    if kind == "goblin" then
        X.achieve("treasure")
        showBanner("TREASURE GOBLIN CAUGHT!", "It dropped a pile of gold and loot", { 1, 0.85, 0.2 })
    end
    stats.streak = stats.streak + 1
    stats.bestStreak = max(stats.bestStreak, stats.streak)
    local sk = STAT_KEY[kind]
    if sk then stats[sk] = stats[sk] + 1 end
    if how and HOW_KEY[how] then stats[HOW_KEY[how]] = stats[HOW_KEY[how]] + 1 end
    me.gold = me.gold + reward
    stats.goldEarned = stats.goldEarned + reward
    addText(x, y - 24, "+" .. reward .. "g", { 1, 0.85, 0.2 }, true)
    addMessage(ENEMY_NAMES[kind] .. " eliminated  +" .. reward .. "g  [" .. world.kills .. "/" .. K.KILLS_TO_WIN .. "]", KILL_COLORS[kind])
    gainMP(K.MP_PER_KILL)
    -- Credits: 1 credit for every 10 kills (permanent, saved immediately)
    -- Easy = practice mode (no credits); Nightmare = 2 credits per 10 kills
    -- admin mode never earns credits (and its kills don't count towards the next credit)
    if X.D.credits == 0 and not admin.on then PROF.data.lifetimeKills = PROF.data.lifetimeKills + 1 end
    if X.D.credits > 0 and not admin.on and PROF.addKill() then
        local n = X.D.credits
        if n > 1 then
            PROF.data.credits = PROF.data.credits + (n - 1)
            PROF.save()
        end
        PROF.data.creditsTotal = (PROF.data.creditsTotal or 0) + n
        stats.creditsEarned = stats.creditsEarned + n
        playSfx("coin")
        addText(me.x, me.y - 58, "+" .. n .. " CREDIT" .. (n > 1 and "S" or ""), { 1, 0.85, 0.25 }, true)
    end
    if drop then spawnBox(nil, x, y) end
    -- Witches have a 15% chance to drop THE CURSED SPELL
    if kind == "witch" and not me.hasCursed and rand() < 0.15 then
        me.hasCursed = true
        playSfx("cursed_charge", 0, 0.6)
        playSfx("chest_open")
        spawnParticles(x, y, 40, { 0.5, 0.05, 0.1 }, 40, 220, 1.4, 4)
        showBanner("THE CURSED SPELL", "The witch's grimoire is yours. Cast it from the spellbook (B)", { 0.9, 0.2, 0.25 })
        addMessage("A witch dropped THE CURSED SPELL! Open your spellbook with B.", { 0.95, 0.3, 0.35 })
    end
end

------------------------------------------------------------------------------
-- Area spells (authoritative on the host / single player)
------------------------------------------------------------------------------
function X.spellArea(kind, x, y, by)
    local n = 0
    for _, e in ipairs(enemies) do
        if not e.dead and e.hidden <= 0 and not X.gkShielded(e) then
            local d = dist(e.x, e.y, x, y)
            if kind == "iceshock" and d < 320 then
                e.stunT, e.shockSlowT, e.swingT = 3, 8, 0
                spawnParticles(e.x, e.y, 12, { 0.7, 0.9, 1 }, 40, 180, 0.6, 3)
                n = n + 1
            elseif (kind == "snowgrave" and d <= 450) or (kind == "cursed" and d <= 1000) then
                local a = atan2(e.y - y, e.x - x)
                spawnParticles(e.x, e.y, 14, { 0.9, 0.97, 1 }, 80, 320, 0.9, 4, a, 0.8)
                -- SnowGRAVE deals 150 DMG, THE CURSED SPELL 200 DMG (no more instant kills - the boss survives them)
                local dmg = kind == "snowgrave" and 150 or 200
                n = n + 1
                if e.hp <= dmg then
                    e.hp = 0
                    killEnemy(e, a, by, kind)
                else
                    damageEnemy(e, dmg, a, true, false, by)
                end
            end
        end
    end
    return n
end

------------------------------------------------------------------------------
-- Day / night
------------------------------------------------------------------------------
-- 0 = full day, 1 = full night
-- world -> screen position (follows the cutscene zoom)
function X.ws(x, y)
    local sw, sh = lg.getDimensions()
    local z = X.camZoom or 1
    return (x - cam.x) * z + sw / 2, (y - cam.y) * z + sh / 2
end

function X.darkness()
    if X.BF and me and X.inLair(me.x, me.y, -100) then return 0.25 * X.darkness0() end
    return X.darkness0()
end
function X.darkness0()
    local p = (world.tod or 0) / DAY_LEN
    if p < 0.20 then return 1 end
    if p < 0.30 then return 1 - (p - 0.20) / 0.10 end
    if p < 0.70 then return 0 end
    if p < 0.80 then return (p - 0.70) / 0.10 end
    return 1
end

-- warm sunrise / sunset glow (0..1)
function X.twilight()
    local p = (world.tod or 0) / DAY_LEN
    local function bell(c) return max(0, 1 - abs(p - c) / 0.07) end
    return max(bell(0.25), bell(0.75))
end

function X.clock()
    local p = (world.tod or 0) / DAY_LEN
    local mins = floor(p * 24 * 60)
    return string.format("%02d:%02d", floor(mins / 60), mins % 60)
end

X.fireflies = {}
local ambT = 12
local wasNight = false
function X.updateDayNight(dt)
    if MPS.role ~= "client" then
        world.tod = world.tod + dt
        if world.tod >= DAY_LEN then
            world.tod = world.tod - DAY_LEN
            world.day = world.day + 1
            if X.endless and X.waveFor(world.day) > (world.wave or 0) then X.startWave(X.waveFor(world.day)) end
            if X.endless and world.day == 2 then X.EV = nil X.hostEvent("merchant") end
        end
    else
        world.tod = (world.tod + dt) % DAY_LEN
    end
    local dark = X.darkness()
    local night = dark > 0.6
    if night ~= wasNight then
        wasNight = night
        if night then
            playSfx("dusk")
            addMessage("Night falls over the frontier... fireflies come out.", { 0.6, 0.65, 1 })
        else
            playSfx("dawn")
            addMessage("The sun rises. Day " .. (world.day or 1) .. ".", { 1, 0.85, 0.5 })
        end
    end
    -- occasional ambient animal sounds
    ambT = ambT - dt
    if ambT <= 0 then
        ambT = randRange(14, 30)
        if dark > 0.6 then
            if me.region == "frozen" then playSfx("howl", 0.08, 0.6)
            else playSfx("owl", 0.06, 0.7) end
        elseif dark < 0.2 and me.region == "desert" then
            playSfx("bird", 0.15, 0.6)
        end
    end
    -- fireflies drift around the player at night (world space)
    local ff = X.fireflies
    local want = floor(70 * clamp((dark - 0.25) / 0.75, 0, 1))
    local sw, sh = lg.getDimensions()
    while #ff < want do
        ff[#ff + 1] = { x = me.x + randRange(-sw * 0.7, sw * 0.7), y = me.y + randRange(-sh * 0.7, sh * 0.7),
            vx = randRange(-14, 14), vy = randRange(-14, 14), ph = rand() * 10, sp = randRange(1.5, 3.5), life = randRange(6, 14) }
    end
    for i = #ff, 1, -1 do
        local f = ff[i]
        f.life = f.life - dt
        f.vx = clamp(f.vx + randRange(-30, 30) * dt, -22, 22)
        f.vy = clamp(f.vy + randRange(-30, 30) * dt, -22, 22)
        f.x, f.y = f.x + f.vx * dt, f.y + f.vy * dt
        if f.life <= 0 or #ff > want or abs(f.x - me.x) > sw or abs(f.y - me.y) > sh then table.remove(ff, i) end
    end
end

------------------------------------------------------------------------------
-- Respawning (multiplayer only - single player keeps the classic game over)
------------------------------------------------------------------------------
function X.respawn()
    local p = me
    p.dead, p.hp, p.hpLag = false, p.maxHp, p.maxHp
    p.poisonT, p.chillT, p.spookT, p.blindT, p.kbx, p.kby, p.vx, p.vy = 0, 0, 0, 0, 0, 0, 0, 0
    p.stamina, p.iframes = p.maxStamina, 1.5
    p.x, p.y = X.shedSpot(MPS.id)
    p.region = "desert"
    if X.BF and not X.BF.done then
        -- during a boss fight you come back inside the arena
        local L = X.BF.A
        p.x, p.y = L.cx - 90 + ((MPS.id or 1) - 1) % 4 * 60, L.iy + 130
        p.region = "spooky"
    end
    cam.x, cam.y = p.x, p.y
    playSfx("respawn")
    addMessage("You respawned in the shed.", { 0.6, 1, 0.7 })
end

------------------------------------------------------------------------------
-- Multiplayer: state exchange
------------------------------------------------------------------------------
local KIND_LIST = { "bandit", "scout", "frozen", "snowman", "gourd", "bat", "witch", "bowman", "guardian",
    "shroomer", "toad", "croc", "slime", "slimelet", "serpent", "blazeshroom", "gatekeeper", "goblin" }
local KIND_IDX = {}
for i, k in ipairs(KIND_LIST) do KIND_IDX[k] = i end
local STATE_LIST = { "patrol", "hunt", "flee" }
local STATE_IDX = { patrol = 1, hunt = 2, flee = 3 }

local function pflags(p)
    local f = 0
    if p.dashTime and p.dashTime > 0 then f = f + 1 end
    if p.moving then f = f + 2 end
    if p.turtleT and p.turtleT > 0 then f = f + 4 end
    if p.iciclesT and p.iciclesT > 0 then f = f + 8 end
    if p.bootsOn then f = f + 16 end
    if p.chillT and p.chillT > 0 then f = f + 32 end
    if p.muzzle and p.muzzle > 0 then f = f + 64 end
    return f
end

local function bit(f, v) return floor(f / v) % 2 == 1 end

local function myState()
    local p = me
    return { floor(p.x * 10) / 10, floor(p.y * 10) / 10, floor(p.angle * 100) / 100, p.weapon, floor(p.hp * 10) / 10,
        p.maxHp, p.dead and 1 or 0, p.blocking and 1 or 0, p.region, pflags(p), MPS.id, nil, p.lives or 3, p.stealth or 0 }
end

local function applyPlayerState(o, s)
    o.tx, o.ty, o.ta = s[1], s[2], s[3]
    if not o.x then o.x, o.y, o.angle = o.tx, o.ty, o.ta end
    o.weapon = WEAPONS[s[4]] and s[4] or "pistol"
    o.hp, o.maxHp = s[5] or 100, s[6] or 100
    local wasDead = o.dead
    o.dead = s[7] == 1
    o.blocking = s[8] == 1
    o.region = s[9] or "desert"
    local f = s[10] or 0
    o.dashTime = bit(f, 1) and 0.1 or 0
    o.moving = bit(f, 2)
    o.turtle, o.icicles, o.boots, o.chill = bit(f, 4), bit(f, 8), bit(f, 16), bit(f, 32)
    o.ready = true
    o.lives = tonumber(s[13]) or o.lives or 3
    o.stealth = tonumber(s[14]) or 0
    o.out = o.dead and o.lives <= 0
    if o.dead and not wasDead then
        spawnParticles(o.x, o.y, 30, { 0.6, 0.08, 0.06 }, 60, 260, 0.8, 4)
    end
end

local function newRemote(id, name)
    return { id = id, name = name or ("Player " .. id), remote = true, r = 14, iframes = 0, dashTime = 0,
        hp = 100, maxHp = 100, dead = false, region = "desert", weapon = "pistol", walkAnim = 0,
        muzzle = 0, recoil = 0, hitFlash = 0, angle = 0, ready = false }
end

local snapT, stateT, announceT, ipT = 0, 0, 0, 0

local function snapshot()
    local ens = {}
    for _, e in ipairs(enemies) do
        if not e.dead then
            local f = 0
            if e.canSee then f = f + 1 end
            if e.hidden > 0 then f = f + 2 end
            if e.stunT > 0 then f = f + 4 end
            if e.frostT > 0 then f = f + 8 end
            if e.shockSlowT > 0 then f = f + 16 end
            if e.swingT > 0 then f = f + 32 end
            if e.castT > 0 then f = f + 64 end
            if e.hitFlash > 0 then f = f + 128 end
            if e.muzzle > 0 then f = f + 256 end
            if (e.bubbleT or 0) > 0 then f = f + 512 end
            if (e.burnT or 0) > 0 then f = f + 1024 end
            ens[#ens + 1] = e.id
            ens[#ens + 1] = KIND_IDX[e.kind]
            ens[#ens + 1] = floor(e.x)
            ens[#ens + 1] = floor(e.y)
            ens[#ens + 1] = floor(e.angle * 100) / 100
            ens[#ens + 1] = max(0, floor(e.hp))
            ens[#ens + 1] = STATE_IDX[e.state] or 1
            ens[#ens + 1] = floor(e.awareness * 100)
            ens[#ens + 1] = f
        end
    end
    local ps = { myState() }
    for _, o in pairs(MPS.others) do
        if o.ready then
            ps[#ps + 1] = { floor(o.tx or o.x), floor(o.ty or o.y), o.ta or o.angle, o.weapon, o.hp, o.maxHp,
                o.dead and 1 or 0, o.blocking and 1 or 0, o.region,
                (o.dashTime > 0 and 1 or 0) + (o.moving and 2 or 0) + (o.turtle and 4 or 0) + (o.icicles and 8 or 0)
                + (o.boots and 16 or 0) + (o.chill and 32 or 0), o.id, o.name, o.lives or 3 }
        end
    end
    ps[1][12] = MPS.name
    local wx = {}
    for id, w in pairs(weather) do wx[id] = { w.active and 1 or 0, floor(w.t), floor(w.intensity * 100) / 100 } end
    return { t = "s", k = world.kills, g1 = regionUnlocked and 1 or 0, g2 = world.spookyOpen and 1 or 0,
        gs = world.swampOpen and 1 or 0, gv = world.volcOpen and 1 or 0, ky = world.hasKey and 1 or 0, gk = world.gkDead and 1 or 0,
        tod = floor(world.tod * 10) / 10, day = world.day, wx = wx, p = ps, e = ens,
        inf = world.infiltrated and 1 or 0, bs = X.BF and X.bossNet() or nil, wv = world.wave }
end

local function makeProxy(id, kind)
    local st = X.ESTATS[kind]
    local e = {
        id = id, kind = kind, region = ENEMY_REGION[kind], proxy = true,
        r = st.r, maxHp = floor(st.hp * X.D.hp + 0.5), hp = floor(st.hp * X.D.hp + 0.5), hpLag = st.hp, vision = st.vision, fov = st.fov,
        state = "patrol", awareness = 0, canSee = false, hitFlash = 0, muzzle = 0, spawnFade = 0,
        stunT = 0, frostT = 0, shockSlowT = 0, hidden = 0, swingT = 0, castT = 0, meleeCd = 0,
        throwCd = 1, throwAnim = 0, fireCd = 1, walkAnim = 0, hop = rand() * 6, flap = rand() * 6,
        wob = rand() * 6, hover = rand() * 6, angle = 0,
    }
    return e
end

local function applySnapshot(s)
    world.kills = s.k or world.kills
    if s.inf == 1 and not world.infiltrated then X.infiltrated("A teammate") end
    if s.wv and s.wv ~= world.wave and X.endless then
        world.wave = s.wv
        if s.wv > 0 then X.waveBanner() end
    end
    if s.bs then X.bossApply(s.bs) end
    if s.g1 == 1 and not regionUnlocked then unlockFrozen() end
    if s.gs == 1 and not world.swampOpen then X.unlockSwamp() end
    if s.gv == 1 and not world.volcOpen then X.unlockVolcanic() end
    if s.ky == 1 then world.hasKey, world.keyItem = true, nil end
    if s.gk == 1 then world.gkDead = true end
    if s.g2 == 1 and not world.spookyOpen then unlockSpooky(true) end
    if s.tod then world.tod, world.day = s.tod, s.day or world.day end
    if type(s.wx) == "table" then
        for id, w in pairs(s.wx) do
            local lw = weather[id]
            if lw and type(w) == "table" then
                lw.active, lw.t, lw.intensity = w[1] == 1, w[2] or 0, w[3] or 0
            end
        end
    end
    -- players
    local seen = {}
    if type(s.p) == "table" then
        for _, ps in ipairs(s.p) do
            local id = ps[11]
            if id and id ~= MPS.id then
                local o = MPS.others[id]
                if not o then o = newRemote(id, ps[12]) MPS.others[id] = o end
                if ps[12] then o.name = ps[12] end
                applyPlayerState(o, ps)
                seen[id] = true
            end
        end
    end
    for id in pairs(MPS.others) do if not seen[id] then MPS.others[id] = nil end end
    -- enemies
    local byId = {}
    for _, e in ipairs(enemies) do byId[e.id] = e end
    local keep = {}
    local arr = type(s.e) == "table" and s.e or {}
    for i = 1, #arr - 8, 9 do
        local id, kind = arr[i], KIND_LIST[arr[i + 1]]
        if kind then
            local e = byId[id]
            if not e then
                e = makeProxy(id, kind)
                e.x, e.y = arr[i + 2], arr[i + 3]
            end
            e.tx, e.ty, e.ta = arr[i + 2], arr[i + 3], arr[i + 4]
            if not e.predictT or e.predictT <= 0 then e.hp = arr[i + 5] end
            e.state = STATE_LIST[arr[i + 6]] or "patrol"
            e.awareness = (arr[i + 7] or 0) / 100
            local f = arr[i + 8] or 0
            e.canSee = bit(f, 1)
            e.hidden = bit(f, 2) and 1 or 0
            e.stunT = bit(f, 4) and 1 or 0
            e.frostT = bit(f, 8) and 1 or 0
            e.shockSlowT = bit(f, 16) and 1 or 0
            e.swingT = bit(f, 32) and 0.2 or 0
            e.castT = bit(f, 64) and 0.5 or 0
            if bit(f, 128) then e.hitFlash = max(e.hitFlash, 0.06) end
            if bit(f, 256) then e.muzzle = 0.07 end
            e.bubbleT = bit(f, 512) and 1 or 0
            e.burnT = bit(f, 1024) and 1 or 0
            keep[#keep + 1] = e
        end
    end
    enemies = keep
end

-- client side: smooth enemy / player movement between snapshots
function X.updateProxies(dt)
    local k = min(1, dt * 12)
    for _, e in ipairs(enemies) do
        local ox, oy = e.x, e.y
        e.x, e.y = lerp(e.x, e.tx or e.x, k), lerp(e.y, e.ty or e.y, k)
        e.angle = e.angle + angleDiff(e.angle, e.ta or e.angle) * k
        local moved = dist(ox, oy, e.x, e.y)
        e.walkAnim = e.walkAnim + moved * 0.08
        e.hop = e.hop + dt * (e.state == "hunt" and 9 or 5)
        e.flap, e.wob, e.hover = e.flap + dt * 22, e.wob + dt * 7, e.hover + dt * 3
        e.hitFlash = max(0, e.hitFlash - dt)
        e.muzzle = max(0, e.muzzle - dt)
        e.spawnFade = min(1, e.spawnFade + dt * 2)
        e.hpLag = e.hpLag > e.hp and max(e.hp, e.hpLag - 60 * dt) or e.hp
        if e.predictT then e.predictT = e.predictT - dt end
    end
end

function X.updateRemotePlayers(dt)
    local k = min(1, dt * 14)
    for _, o in pairs(MPS.others) do
        if o.ready and o.tx then
            local ox, oy = o.x, o.y
            o.x, o.y = lerp(o.x, o.tx, k), lerp(o.y, o.ty, k)
            o.angle = o.angle + angleDiff(o.angle, o.ta or o.angle) * k
            o.walkAnim = o.walkAnim + dist(ox, oy, o.x, o.y) * 0.07
            o.muzzle = max(0, o.muzzle - dt)
            o.recoil = max(0, o.recoil - dt * 8)
            o.hitFlash = max(0, o.hitFlash - dt)
            o.inShed = X.inShed(o.x, o.y)
        end
    end
end

local function remoteShot(o, m)
    if not o then return end
    o.muzzle, o.recoil = 0.06, 1
    local w = WEAPONS[m.w] or WEAPONS.pistol
    X.fireWeapon(m.w, m.x, m.y, m.a, m.i == 1, "remote", nil, m.d, o)
    playSfx(w.sound, 0.08, volAt(m.x, m.y))
end

local function spawnEnemyShot(m)
    local b = { x = m.x, y = m.y, vx = m.vx, vy = m.vy, life = m.life or 1.4, owner = "enemy", kind = m.k,
        dmg = m.d or 0, srcX = m.sx or m.x, srcY = m.sy or m.y, land = m.l }
    if m.k == "potion" or m.k == "snowball" or X.SHOT_SND[m.k] then b.age = 0 end
    if X.SHOT_SND[m.k] then playSfx(X.SHOT_SND[m.k], 0.1, volAt(m.x, m.y)) end
    bullets[#bullets + 1] = b
    local v = volAt(m.x, m.y)
    if m.k == "bullet" then
        playSfx("enemy_shot", 0.12, v)
        spawnParticles(m.x, m.y, 4, { 1, 0.8, 0.4 }, 40, 140, 0.15, 2.5, atan2(m.vy, m.vx), 0.4)
    elseif m.k == "arrow" then playSfx("bow", 0.12, v)
    elseif m.k == "face" then playSfx("face_shot", 0.1, v * 0.6)
    elseif m.k == "icicle" then playSfx("frozen_shot", 0.12, v)
    elseif m.k == "potion" then playSfx("potion_throw", 0.1, v)
    elseif m.k == "snowball" then playSfx("snowball_throw", 0.15, v) end
end

------------------------------------------------------------------------------
-- Host message handling
------------------------------------------------------------------------------
local function hostHandle(kind, id, m)
    if kind == "connect" then return end
    if kind == "disconnect" then
        local o = MPS.others[id]
        MPS.others[id] = nil
        if o then
            X.wmsg((o.name or "A player") .. " left the game.", { 1, 0.7, 0.5 }, true)
            playSfx("leave")
        end
        return
    end
    local t = m.t
    if t == "hi" then
        local count = 1
        for _ in pairs(MPS.others) do count = count + 1 end
        if m.v ~= NET.VERSION then
            NET.send(id, { t = "deny", s = "Version mismatch: the host runs a different version of Frontier." })
            NET.kick(id)
            return
        end
        if count >= NET.MAX_PLAYERS then
            NET.send(id, { t = "deny", s = "That game is full (4 / 4 players)." })
            NET.kick(id)
            return
        end
        local name = tostring(m.name or ("Player " .. id)):gsub("[^%w _%-]", ""):sub(1, 16)
        local o = newRemote(id, name)
        o.x, o.y = X.shedSpot(id)
        o.tx, o.ty, o.ta = o.x, o.y, 0
        MPS.others[id] = o
        NET.send(id, { t = "wl", id = id, seed = world.seed, k = world.kills, diff = X.D.id, inf = world.infiltrated and 1 or 0,
            gp = world.gourdPool, g1 = regionUnlocked and 1 or 0,
            g2 = world.spookyOpen and 1 or 0, gs = world.swampOpen and 1 or 0, gv = world.volcOpen and 1 or 0,
            ky = world.hasKey and 1 or 0, gk = world.gkDead and 1 or 0, tod = world.tod, day = world.day, host = MPS.name,
            en = X.endless and 1 or 0, wv = world.wave })
        X.wmsg(name .. " joined the game!", { 0.6, 1, 0.7 }, true)
        playSfx("join")
    elseif t == "st" then
        local o = MPS.others[id]
        if o and type(m.s) == "table" then
            applyPlayerState(o, m.s)
            o.inShed = X.inShed(o.tx, o.ty)
        end
    elseif t == "sh" then
        local o = MPS.others[id]
        if o and WEAPONS[m.w] then
            remoteShot(o, m)
            m.id = id
            NET.broadcast(m, false, id)
        end
    elseif t == "hit" then
        for _, e in ipairs(enemies) do
            if e.id == m.e and not e.dead then
                damageEnemy(e, tonumber(m.d) or 0, tonumber(m.a) or 0, m.c == 1, m.i == 1, id, type(m.f) == "string" and m.f:sub(1, 6) or nil)
                break
            end
        end
    elseif t == "ut" then
        X.utilNet(m, id)
    elseif t == "rev" then
        if m.to == MPS.id then X.getRevived(m.by) elseif m.to then NET.send(m.to, { t = "rev", by = m.by }) end
    elseif t == "key" then
        if not world.hasKey then
            world.hasKey, world.keyItem = true, nil
            showBanner("KEY TO THE HOLLOW", "A teammate picked up the key", { 1, 0.8, 0.3 })
        end
    elseif t == "inf" then
        local o = MPS.others[id]
        X.infiltrated(o and o.name or "A teammate")
    elseif t == "vortex" then
        X.spawnVortex(tonumber(m.x) or 0, tonumber(m.y) or 0, min(120, tonumber(m.d) or 0), id, true)
    elseif t == "chat" then
        X.hostChat(id, MPS.others[id], m)
    elseif t == "spell" then
        if m.s == "snowgrave" or m.s == "iceshock" or m.s == "cursed" then
            X.spellArea(m.s, tonumber(m.x) or 0, tonumber(m.y) or 0, id)
        end
    end
end

------------------------------------------------------------------------------
-- Client message handling
------------------------------------------------------------------------------
local function clientHandle(kind, id, m)
    if kind == "connect" then
        NET.toHost({ t = "hi", name = MPS.name, v = NET.VERSION })
        MPS.status = "Connected - waiting for the host..."
        return
    end
    if kind == "disconnect" then
        -- the game is already ending (win / everyone out): let the end screen show
        if endTimer and gameState == "play" then return end
        X.leaveGame(MPS.inGame and "The host left the game." or "Could not reach that game.")
        return
    end
    local t = m.t
    if t == "wl" then
        MPS.id = m.id
        MPS.hostName = m.host
        MPS.role = "client"
        newGame({ seed = m.seed, kills = m.k, g1 = m.g1, g2 = m.g2, gs = m.gs, gv = m.gv, ky = m.ky, gk = m.gk, tod = m.tod, day = m.day,
            endless = m.en == 1, wave = m.wv,
            diff = m.diff, inf = m.inf, gp = m.gp })
    elseif t == "deny" then
        X.leaveGame(m.s or "The host refused the connection.")
    elseif not MPS.inGame then
        return
    elseif t == "s" then
        applySnapshot(m)
    elseif t == "kill" then
        world.kills = m.n or world.kills
        X.killFx(m.k, m.x, m.y, m.r, m.a)
        for _, e in ipairs(enemies) do if e.id == m.e then e.dead = true end end
        if m.by == MPS.id then X.killReward(m.k, m.x, m.y, m.g or 20, m.d == 1, m.how) end
        if m.n == 25 or m.n == 50 or m.n == 75 or m.n == 125 then
            addMessage("Milestone: " .. m.n .. " team kills! The frontier grows hostile...", { 1, 0.9, 0.3 })
        end
    elseif t == "es" then
        spawnEnemyShot(m)
    elseif t == "mel" then
        X.applyMelee(m.k, m.d, m.x, m.y, m.a or 0)
    elseif t == "rev" then
        X.getRevived(m.by)
    elseif t == "ut" then
        X.utilNet(m)
    elseif t == "ev" then
        X.startEvent(m.k, tonumber(m.d) or 30, m.s)
    elseif t == "sfx" then
        if SFX[m.n] then playSfx(m.n, m.p, (m.v or 1) * volAt(m.x, m.y)) end
    elseif t == "txt" then
        addText(m.x, m.y, tostring(m.s), type(m.c) == "table" and m.c or nil, m.b == 1)
    elseif t == "ring" then
        rings[#rings + 1] = { x = m.x, y = m.y, r = 0, max = m.m or 300, life = m.l or 1, maxLife = m.l or 1,
            col = type(m.c) == "table" and m.c or nil }
    elseif t == "msg" then
        addMessage(tostring(m.s), type(m.c) == "table" and m.c or nil)
        if m.ch == 1 then X.chatAdd(nil, tostring(m.s), type(m.c) == "table" and m.c or nil) end
        if tostring(m.s):find("joined") then playSfx("join") elseif tostring(m.s):find("left the game") then playSfx("leave") end
    elseif t == "sh" then
        remoteShot(MPS.others[m.id], m)
    elseif t == "end" and m.lose == 1 then
        if not endTimer then
            endTimer = 3
            finishGame(false)
            playSfx("lose")
            X.chatAdd(nil, "Every player is out of hearts. GAME OVER.", { 1, 0.3, 0.3 })
        end
    elseif t == "bstart" then
        if not X.BF then X.beginBoss(m.k or "guardian", true) end
    elseif t == "stomp" then
        X.stompLocal(tonumber(m.x) or 0, tonumber(m.y) or 0, tonumber(m.sx) or 0, tonumber(m.sy) or 0)
    elseif t == "bdead" then
        X.onBossDead(tonumber(m.x) or 0, tonumber(m.y) or 0)
    elseif t == "chat" then
        X.chatAdd(m.n, tostring(m.s or ""), type(m.c) == "table" and m.c or nil)
        if m.n then playSfx("click", 0.1, 0.6) end
    elseif t == "end" then
        if not endTimer then
            endTimer = 2.2
            finishGame(true)
            playSfx("win")
            addMessage("THE FRONTIER IS YOURS!", { 1, 0.9, 0.3 })
        end
    end
end

function X.netUpdate(dt)
    if MPS.role == "host" then
        NET.service(hostHandle)
        NET.pollAnnounce()
        if MPS.inGame and gameState == "play" and not endTimer and X.teamOut() then
            NET.broadcast({ t = "end", lose = 1 })
            endTimer = 3
            finishGame(false)
            X.chatAdd(nil, "Every player is out of hearts. GAME OVER.", { 1, 0.3, 0.3 })
        end
        snapT = snapT - dt
        if snapT <= 0 and MPS.inGame and gameState == "play" then
            snapT = 1 / 15
            NET.broadcast(snapshot(), true)
        end
    elseif MPS.role == "client" or MPS.connecting then
        NET.service(clientHandle)
        if MPS.inGame and MPS.role == "client" then
            stateT = stateT - dt
            if stateT <= 0 then
                stateT = 1 / 20
                NET.toHost({ t = "st", s = myState() }, true)
            end
        end
    end
end

-- local shot -> other players see it
function X.netShot(wid, x, y, ang, icy, aim)
    local m = { t = "sh", w = wid, x = floor(x), y = floor(y), a = floor(ang * 1000) / 1000, i = icy and 1 or 0, d = floor(aim or 0) }
    if MPS.role == "client" then NET.toHost(m)
    elseif MPS.role == "host" then m.id = MPS.id NET.broadcast(m) end
end

function X.netKill(e, by, reward, drop, angle, how)
    if MPS.role ~= "host" then return end
    NET.broadcast({ t = "kill", e = e.id, by = by, k = e.kind, x = floor(e.x), y = floor(e.y), r = e.r,
        a = angle, g = reward, d = drop and 1 or 0, n = world.kills, how = how })
end

------------------------------------------------------------------------------
-- Hosting / joining / leaving
------------------------------------------------------------------------------
function X.hostGame(diff)
    X.hostDiff = diff or "easy"
    if not NET.localIP() then
        MPS.error = "You must be connected to Wi-Fi (or a LAN) to host."
        return
    end
    local ok, err = NET.hostGame()
    if not ok then MPS.error = err return end
    MPS.role, MPS.id, MPS.others, MPS.online = "host", 1, {}, true
    MPS.name = PROF.data.name
    MPS.sid = floor(love.math.random() * 1000000000)
    NET.startAnnounce(function()
        local n = 1
        for _ in pairs(MPS.others) do n = n + 1 end
        return { name = MPS.name, sid = MPS.sid, players = n, max = NET.MAX_PLAYERS, diff = X.hostDiff or "easy",
            mode = X.gameMode == "endless" and "endless" or "story",
            region = me and me.region or "desert", kills = world.kills or 0 }
    end)
    NET.stopBrowse()
    PROF.data.mpGames = (PROF.data.mpGames or 0) + 1
    newGame({ seed = floor(love.math.random() * 1000000000), diff = X.hostDiff, endless = X.gameMode == "endless" })
end

function X.joinGame(ip)
    if not NET.localIP() then
        MPS.error = "You must be connected to Wi-Fi (or a LAN) to join a game."
        return
    end
    local ok, err = NET.join(ip)
    if not ok then MPS.error = err return end
    MPS.role, MPS.others, MPS.online, MPS.connecting = "connecting", {}, true, true
    MPS.name = PROF.data.name
    MPS.status = "Connecting to " .. ip .. "..."
    MPS.joinT = 8
    PROF.data.mpGames = (PROF.data.mpGames or 0) + 1
end

-- leave any multiplayer session and go back to the menus
function X.leaveGame(reason)
    NET.stopAnnounce()
    NET.close()
    local wasOnline = MPS.online
    MPS.online, MPS.connecting, MPS.inGame, MPS.role, MPS.id, MPS.others = false, false, false, "solo", 1, {}
    if reason then MPS.error = reason end
    overlay = nil
    love.mouse.setVisible(true)
    if wasOnline then
        gameState = "mp"
        X.openMP()
    else
        gameState = "menu"
    end
end

function X.openMP()
    gameState = "mp"
    MPS.scroll = 0
    NET.startBrowse()
    X.ipCheckT = 0
end
end

------------------------------------------------------------------------------
-- LÖVE callbacks: load / update
------------------------------------------------------------------------------
function love.load()
    love.math.setRandomSeed(os.time())
    lg.setDefaultFilter("linear", "linear")
    fonts.tiny   = lg.newFont(11)
    fonts.small  = lg.newFont(13)
    fonts.normal = lg.newFont(16)
    fonts.medium = lg.newFont(22)
    fonts.large  = lg.newFont(34)
    fonts.huge   = lg.newFont(96)
    fonts.dmg    = lg.newFont(15)
    fonts.dmgBig = lg.newFont(20)

    buildSounds()
    updateAmbientVolume()
    ambient:play()
    rainLoop:setVolume(0) rainLoop:play()
    blizzardLoop:setVolume(0) blizzardLoop:play()
    loadSave()
    musicSrc:setVolume(0.3 * settings.volume) musicSrc:play()
    if X.bossMusic then X.bossMusic:setVolume(0) X.bossMusic:play() end
    X.cricketLoop:setVolume(0) X.cricketLoop:play()
    -- soft radial glow used for lanterns and fireflies at night
    local gimg = love.image.newImageData(128, 128)
    for gy = 0, 127 do
        for gx = 0, 127 do
            local d = min(1, sqrt((gx - 63.5) ^ 2 + (gy - 63.5) ^ 2) / 64)
            gimg:setPixel(gx, gy, 1, 1, 1, (1 - d) ^ 2)
        end
    end
    X.glowImg = lg.newImage(gimg)
    MPS.name = save.name

    for _ = 1, 90 do
        menuDust[#menuDust + 1] = { x = rand(), y = rand(), s = randRange(0.5, 2.5), v = randRange(0.02, 0.08) }
    end

    -- Radial fog texture used for rain / blizzard visibility
    local img = love.image.newImageData(256, 256)
    for y = 0, 255 do
        for x = 0, 255 do
            local d = sqrt((x - 127.5) ^ 2 + (y - 127.5) ^ 2) / 128
            local a = clamp((d - 0.3) / 0.7, 0, 1)
            img:setPixel(x, y, 1, 1, 1, a * a * (3 - 2 * a))
        end
    end
    fogImg = lg.newImage(img)

    -- Precipitation (screen space)
    for _ = 1, 280 do
        rainDrops[#rainDrops + 1] = { x = rand() * 1400, y = rand() * 800, spd = randRange(700, 1100), len = randRange(10, 22) }
    end
    for _ = 1, 450 do
        snowFlakes[#snowFlakes + 1] = {
            x = rand() * 1400, y = rand() * 800, vx = randRange(-15, 25), vy = randRange(40, 90),
            z = randRange(0.6, 1.4), ph = rand() * 10, s = randRange(1.2, 2.8),
        }
    end
end

------------------------------------------------------------------------------
-- THE MURKY SWAMP and THE VOLCANIC RIFT: world generation, murky water,
-- lava and the Blaze Gatekeeper's arena
------------------------------------------------------------------------------
do
local function inPool(list, x, y, pad)
    pad = pad or 0
    for i = 1, #list do
        local p = list[i]
        local dx, dy = (x - p.x) / (p.rx + pad), (y - p.y) / (p.ry + pad)
        if dx * dx + dy * dy <= 1 then return p end
    end
end
local function nearPool(list, x, y, w, h, pad)
    for i = 1, #list do
        local p = list[i]
        if rectOverlap(x, y, w, h, p.x - p.rx - pad, p.y - p.ry - pad, 2 * (p.rx + pad), 2 * (p.ry + pad)) then return true end
    end
    return false
end
function X.inMurk(x, y) return X.swampPools and inPool(X.swampPools, x, y) end
function X.inLava(x, y) return X.lavaPools and inPool(X.lavaPools, x, y) end
-- no spawning inside water or lava
function X.inAnyPool(x, y, pad)
    return (X.swampPools and inPool(X.swampPools, x, y, pad)) or (X.lavaPools and inPool(X.lavaPools, x, y, pad))
end
-- the closest point outside a pool (enemies are pushed out of the lava)
function X.poolEdge(p, x, y, pad)
    local a = atan2((y - p.y) / p.ry, (x - p.x) / p.rx)
    return p.x + cos(a) * (p.rx + pad), p.y + sin(a) * (p.ry + pad)
end
function X.randomPoolNear(list, x, y, maxD)
    local best, bd
    for _, p in ipairs(list) do
        local d = dist(p.x, p.y, x, y)
        if d < maxD and d > 500 and (not bd or rand() < 0.35) then best, bd = p, d end
    end
    return best
end

-- scatter obstacles of a region (placer returns w, h, kind or nil)
local function scatter(R, count, tries, pools, keepOut, placer)
    local placed, t = 0, 0
    while placed < count and t < tries do
        t = t + 1
        local w, h, kind, round = placer()
        local x, y = randRange(R.x0 + 120, R.x1 - w - 120), randRange(R.y0 + 120, R.y1 - h - 120)
        local ok = areaFree(x, y, w, h, 60) and not nearPool(pools, x, y, w, h, 40)
        if ok then
            for _, k in ipairs(keepOut) do
                if dist(x + w / 2, y + h / 2, k.x, k.y) < k.r then ok = false break end
            end
        end
        if ok then
            local wl = addWall(x, y, w, h, kind)
            wl.v = rand()
            placed = placed + 1
        end
    end
end

local function makePools(R, n, rxA, rxB, ryA, ryB, keepOut, extraOk)
    local list, tries = {}, 0
    while #list < n and tries < 6000 do
        tries = tries + 1
        local rx, ry = randInt(rxA, rxB), randInt(ryA, ryB)
        local x = randRange(R.x0 + rx + 160, R.x1 - rx - 160)
        local y = randRange(R.y0 + ry + 160, R.y1 - ry - 160)
        local ok = true
        for _, k in ipairs(keepOut) do
            if dist(x, y, k.x, k.y) < k.r + rx then ok = false break end
        end
        if ok and extraOk and not extraOk(x, y, rx, ry) then ok = false end
        if ok then
            for _, p in ipairs(list) do
                if dist(x, y, p.x, p.y) < rx + p.rx + 120 then ok = false break end
            end
        end
        if ok then list[#list + 1] = { x = x, y = y, rx = rx, ry = ry, seed = rand() * 100 } end
    end
    return list
end

function X.generateSwamp()
    local R = REGIONS.swamp
    local keepOut = {
        { x = R.x0 + 60, y = K.G2_Y + K.GATE_W / 2, r = 700 },                    -- the gate from the Frozen Wastes
        { x = K.EAST_X + K.WORLD_W / 2, y = R.y1 - 40, r = 700 },                 -- the gate to the Volcanic Rift
    }
    -- big murky pools (dark green blobs in the sketch): -20% speed, crocodiles hide in them
    X.swampPools = makePools(R, 150, 160, 340, 110, 240, keepOut)
    local P = X.swampPools
    scatter(R, 420, 9000, P, keepOut, function() local s = randInt(50, 110) return s, s * randRange(0.7, 1), "mud" end)
    scatter(R, 520, 9000, P, keepOut, function() return randInt(80, 160), randInt(46, 80), "swampbush" end)
    scatter(R, 260, 6000, P, keepOut, function() local s = randInt(38, 58) return s, s, "bigshroom" end)
    scatter(R, 160, 4000, P, keepOut, function() local s = randInt(28, 44) return s, s, "deadtree" end)
    scatter(R, 120, 4000, P, keepOut, function()
        if rand() < 0.5 then return randInt(150, 260), 26, "log" end
        return 26, randInt(150, 260), "log"
    end)
    -- decoration: olive moss streaks, reeds, small mushrooms, lily pads on the water
    for _ = 1, 21000 do
        local k = rand()
        WG.addDecor({
            x = randRange(R.x0, R.x1), y = randRange(R.y0, R.y1),
            kind = k < 0.18 and "z_moss" or (k < 0.5 and "z_swampgrass" or (k < 0.72 and "z_reed" or (k < 0.9 and "z_shroom" or "z_mudspot"))),
            s = randRange(0.7, 1.4), r = rand() * 2 * pi, ph = rand() * 10,
        })
    end
    for _, p in ipairs(P) do
        for _ = 1, randInt(2, 6) do
            local a, d = rand() * 2 * pi, rand() * 0.75
            WG.addDecor({ x = p.x + cos(a) * p.rx * d, y = p.y + sin(a) * p.ry * d, kind = "z_lily", s = randRange(0.8, 1.5),
                r = rand() * 2 * pi, ph = rand() * 10 })
        end
    end
end

function X.generateVolcanic()
    local R = REGIONS.volcanic
    X.buildGatekeeperArena()
    local G = X.GKA
    local keepOut = {
        { x = K.EAST_X + K.WORLD_W / 2, y = R.y0 + 40, r = 700 },                 -- the gate from the Swamp
        { x = G.x + G.w / 2, y = G.y + G.h / 2, r = 1500 },                       -- the Gatekeeper's arena
    }
    X.lavaPools = makePools(R, 120, 120, 300, 80, 210, keepOut)
    local P = X.lavaPools
    scatter(R, 650, 12000, P, keepOut, function() local s = randInt(50, 140) return s, s * randRange(0.65, 1), "basalt" end)
    scatter(R, 240, 6000, P, keepOut, function() local s = randInt(30, 50) return s, s, "obsidian" end)
    scatter(R, 220, 6000, P, keepOut, function()
        if rand() < 0.5 then return randInt(150, 380), 28, "basaltwall" end
        return 28, randInt(150, 380), "basaltwall"
    end)
    for _ = 1, 19000 do
        local k = rand()
        WG.addDecor({
            x = randRange(R.x0, R.x1), y = randRange(R.y0, R.y1),
            kind = k < 0.4 and "z_ash" or (k < 0.65 and "z_pebble" or (k < 0.82 and "z_ember" or (k < 0.94 and "z_vent" or "z_skull"))),
            s = randRange(0.7, 1.4), r = rand() * 2 * pi, ph = rand() * 10,
        })
    end
end

-- a Shroomer mushroom (1 in 3: slowness, weakness, fungus) or a Toad's poison spit hit this machine's player
function X.curseHit(kind)
    if player.dead then return end
    if kind == "spit" then
        if player.poisonT <= 0 then player.poisonTick = 1 end
        player.poisonT = player.waders and 3 or 6                   -- Swamp Waders: half as long
        playSfx("poison", 0.1)
        addText(player.x, player.y - 40, "POISONED", { 0.6, 0.9, 0.3 }, true)
        spawnParticles(player.x, player.y, 12, { 0.5, 0.8, 0.2 }, 40, 180, 0.6, 3)
        return
    end
    playSfx("mushroom_pop", 0.1)
    spawnParticles(player.x, player.y, 14, { 0.95, 0.25, 0.25 }, 40, 180, 0.5, 3)
    local r = rand()
    if r < 1 / 3 then
        player.slowT = 5
        addText(player.x, player.y - 40, "SLOWNESS", { 0.6, 0.75, 1 }, true)
    elseif r < 2 / 3 then
        player.weakT = 5
        addText(player.x, player.y - 40, "WEAKNESS", { 1, 0.45, 0.45 }, true)
    else
        player.fungusT = 10
        addText(player.x, player.y - 40, "FUNGUS", { 0.55, 1, 0.4 }, true)
    end
end

-- The Blaze Gatekeeper's arena: right in front of the Hollow gate (its south wall holds gate4)
function X.buildGatekeeperArena()
    local w, h, T = 1900, 1300, 44
    local x, y = K.EAST_X + K.WORLD_W / 2 - w / 2, K.VOLC_Y1 - h
    local A = { x = x, y = y, w = w, h = h, kind = "gatekeeper" }
    X.GKA = A
    A.ix, A.iy, A.iw, A.ih = x + T, y + T, w - 2 * T, h - T
    A.bx, A.by, A.cx = x + w / 2, y + h * 0.45, x + w / 2
    floors[#floors + 1] = { x = A.ix, y = A.iy, w = A.iw, h = A.ih, kind = "gkfloor" }
    local gw = 260
    local seg = (w - gw) / 2
    addWall(x, y, seg, T, "gkwall")
    addWall(x + seg + gw, y, seg, T, "gkwall")
    A.gate = addWall(x + seg, y, gw, T, "gkgate")
    A.gate.off = true                                  -- open until the fight starts
    A.gx, A.gy = x + seg + gw / 2, y + T / 2
    addWall(x, y + T, T, h - T, "gkwall")
    addWall(x + w - T, y + T, T, h - T, "gkwall")
    addWall(x + seg - 70, y - 30, 70, T + 60, "gktower")
    addWall(x + seg + gw, y - 30, 70, T + 60, "gktower")
    for _, p in ipairs({ { 0.2, 0.3 }, { 0.8, 0.3 }, { 0.2, 0.75 }, { 0.8, 0.75 } }) do
        addWall(x + w * p[1] - 35, y + h * p[2] - 35, 70, 70, "gkpillar")
    end
end
end

------------------------------------------------------------------------------
-- THE GUARDIAN OF THE HOLLOW: the lair, the cutscene and the boss fight.
-- The host (or single player) runs the boss; clients get its state in every
-- snapshot ("bs") and resolve hits on their own player.
------------------------------------------------------------------------------
do
local GATE_W, WALL_T = 280, 46
local HAT_RANGE, HAT_OUT, HAT_BACK, HAT_HIT = 1200, 720, 840, 58
local FACE_SPEED, HAT_SPIN = 540, 24
-- attack speed: Easy 1x, Normal 1.5x, Hard 2x, Nightmare 2.5x
local function bossSpeed() return X.D.bossSpeed or 1 end
local function faceWaves() return X.D.faceWaves or 5 end
local JUMP_H, CUT_LEN = 320, 5.0
X.JUMP_H = JUMP_H
X.BOSS_CREDITS = 30
-- how long each phase lasts (clients use it to animate between snapshots)
local PH_LEN = { laugh = 2.85, prep = 1.0, air = 0.9, land = 0.9, necro = 1.5, hat = 0.4, walk = 1.6 }

-- The lair: a walled arena at the far south of the Haunted Hollow
function X.buildLair()
    local w, h = 2100, 1560
    local x, y = K.EAST_X + K.WORLD_W / 2 - w / 2, K.SPOOKY_Y1 - h
    local L = { x = x, y = y, w = w, h = h, cx = x + w / 2 }
    X.LAIR = L
    L.ix, L.iy, L.iw, L.ih = x + WALL_T, y + WALL_T, w - 2 * WALL_T, h - WALL_T     -- the inside
    L.bx, L.by = L.cx, y + h * 0.6                                               -- where the Guardian sleeps
    floors[#floors + 1] = { x = L.ix, y = L.iy, w = L.iw, h = L.ih, kind = "lair" }
    local seg = (w - GATE_W) / 2
    addWall(x, y, seg, WALL_T, "lair")
    addWall(x + seg + GATE_W, y, seg, WALL_T, "lair")
    L.gate = addWall(x + seg, y, GATE_W, WALL_T, "lairgate")          -- sealed until the lair opens
    L.gx, L.gy = x + seg + GATE_W / 2, y + WALL_T / 2
    addWall(x, y + WALL_T, WALL_T, h - WALL_T, "lair")
    addWall(x + w - WALL_T, y + WALL_T, WALL_T, h - WALL_T, "lair")
    addWall(x + seg - 74, y - 34, 74, WALL_T + 68, "lairtower")
    addWall(x + seg + GATE_W, y - 34, 74, WALL_T + 68, "lairtower")
    -- broken pillars and two low walls to hide behind (the Guardian still sees you)
    for _, p in ipairs({ { 0.2, 0.3 }, { 0.8, 0.3 }, { 0.2, 0.8 }, { 0.8, 0.8 } }) do
        addWall(x + w * p[1] - 40, y + h * p[2] - 40, 80, 80, "lairpillar")
    end
    addWall(x + w * 0.33 - 90, y + h * 0.5, 180, 30, "lairlow")
    addWall(x + w * 0.67 - 90, y + h * 0.5, 180, 30, "lairlow")
end

function X.inArena(A, x, y, pad)
    pad = pad or 0
    return A ~= nil and x > A.ix + pad and x < A.ix + A.iw - pad and y > A.iy + pad and y < A.iy + A.ih - pad
end
function X.inLair(x, y, pad) return X.inArena(X.LAIR, x, y, pad) end

-- the boss of the current fight (the Guardian or the Blaze Gatekeeper)
function X.bossEntity()
    local kind = X.BF and X.BF.kind or "guardian"
    for _, e in ipairs(enemies) do
        if e.kind == kind and not e.dead then return e end
    end
end
X.BOSS_NAMES = { guardian = "GUARDIAN OF THE HOLLOW", gatekeeper = "BLAZE GATEKEEPER" }
X.BOSS_SUBS = { guardian = "Keeper of the Haunted Hollow", gatekeeper = "Warden of the Hollow gate" }

function X.openLair(silent)
    world.lairOpen = true
    local L = X.LAIR
    if L and L.gate then L.gate.off = true end
    if not silent then
        playSfx("gate_open", 0, 0.9)
        playSfx("boss_laugh", 0.05, 0.35)
        addShake(8)
        showBanner("THE GUARDIAN'S LAIR IS OPEN", "Something stirs at the far south of the Haunted Hollow...", { 1, 0.6, 0.2 })
        X.chatAdd(nil, "The Guardian's Lair has opened at the far south of the Haunted Hollow.", { 1, 0.6, 0.2 })
    end
end

function X.infiltrated(who)
    if world.infiltrated then return end
    world.infiltrated = true
    X.achieve("infiltrator")
    playSfx("gate_open", 0.1, 0.6)
    playSfx("coin")
    showBanner("STRONGHOLD INFILTRATED", who and (who .. " reached the keep of the Stronghold.") or "You reached the keep of the Stronghold.",
        { 0.6, 0.9, 0.45 })
end

-- every frame on every machine
function X.updateLair(dt)
    local L = X.LAIR
    if not L then return end
    -- walking up to the keep of the Stronghold = infiltration
    local S = X.SH
    if not world.infiltrated and S and not me.dead and abs(me.x - S.cx) < 240 and abs(me.y - S.cy) < 210 then
        X.infiltrated()
        if MPS.role == "client" then NET.toHost({ t = "inf" }) end
    end
    X.checkGates()
    if not world.lairOpen and not X.BF and not X.endless
       and (admin.on or (world.spookyOpen and (world.infiltrated or not S))) then
        X.openLair()
    end
    -- the fight starts as soon as someone walks in (decided by the host / single player)
    if world.lairOpen and not X.BF and MPS.role ~= "client" then
        for _, p in ipairs(X.allPlayers()) do
            if not p.dead and X.inLair(p.x, p.y) and p.y > L.iy + 80 then X.startBoss("guardian") break end
        end
    end
    -- the Blaze Gatekeeper wakes up when someone walks into his arena (until he drops the key)
    local G = X.GKA
    if G and world.volcOpen and not world.gkDead and not X.BF and MPS.role ~= "client" then
        for _, p in ipairs(X.allPlayers()) do
            if not p.dead and X.inArena(G, p.x, p.y) and p.y > G.iy + 80 then X.startBoss("gatekeeper") break end
        end
    end
end

function X.startBoss(kind)
    if MPS.role == "host" then NET.broadcast({ t = "bstart", k = kind }) end
    X.beginBoss(kind, true)
end

-- the ammo boxes in the corners of the arena (each player has their own)
local function lairBoxes(L)
    for _, c in ipairs({ { 0.1, 0.16 }, { 0.9, 0.16 }, { 0.1, 0.92 }, { 0.9, 0.92 } }) do
        local bx, by = L.x + L.w * c[1], L.y + L.h * c[2]
        local have = false
        for _, b in ipairs(boxes) do if dist(b.x, b.y, bx, by) < 40 then have = true break end end
        if not have then spawnBox(nil, bx, by) end
    end
end

-- start of the fight on every machine. cut = play the cutscene first.
function X.beginBoss(kind, cut)
    kind = kind or "guardian"
    local L = kind == "gatekeeper" and X.GKA or X.LAIR
    X.BF = { kind = kind, A = L, name = X.BOSS_NAMES[kind], ph = "sleep", pt = 0, hatOn = true, hatHitN = -1,
        gateClose = cut and 0 or 1, fight = not cut, boxT = 45 }
    if kind == "guardian" then world.lairOpen = true end
    L.gate.off = false                                   -- nobody can escape
    -- everyone is pulled into the arena
    if not X.inArena(L, me.x, me.y, 30) then
        local i = ((MPS.id or 1) - 1) % 4
        me.x, me.y = L.cx - 90 + i * 60, L.iy + 130
        me.kbx, me.kby, me.vx, me.vy = 0, 0, 0, 0
        if not cut then cam.x, cam.y = me.x, me.y end
    end
    -- every other enemy disappears (and their shots)
    X.clearEnemyBullets()
    if MPS.role ~= "client" then
        for _, e in ipairs(enemies) do e.dead = true end
        for k in pairs(world.stash) do world.stash[k] = {} end
        local g = spawnEnemy(kind, nil, L.bx, L.by)
        g.state, g.awareness, g.angle, g.spawnFade = "hunt", 1, -pi / 2, 1
        local n = #X.allPlayers()
        g.maxHp = floor(g.maxHp * (1 + 0.5 * (n - 1)))   -- tougher with more players
        g.hp, g.hpLag = g.maxHp, g.maxHp
        g.bph, g.bt, g.bt0 = "walk", 1.6, 1.6
        X.BF.boss = g
    end
    lairBoxes(L)
    if X.bossMusic then pcall(function() X.bossMusic:seek(0) end) end
    if cut then
        X.cut = { t = 0, fx = cam.x, fy = cam.y, slam = false, wake = false }
        banner = nil
        overlay = nil
        X.chat.open = false
    end
end

------------------------------------------------------------------------------
-- Cutscene: the camera flies to the entrance, the gate slams shut, the
-- Guardian wakes up, then back to the player.
------------------------------------------------------------------------------
local function ease(t) t = clamp(t, 0, 1) return t * t * (3 - 2 * t) end

function X.updateCut(dt)
    local C, BF = X.cut, X.BF
    if C.kind == "fly" then X.updateFlyover(dt) return end
    if C.kind == "key" then X.updateKeyCut(dt) return end
    local L = BF.A
    C.t = C.t + dt
    local t = C.t
    local gx, gy = L.gx, L.gy + 40
    local g = X.bossEntity()
    local bx, by = g and g.x or L.bx, g and g.y or L.by
    local fx, fy, z
    if t < 1.3 then
        local k = ease(t / 1.3)
        fx, fy, z = lerp(C.fx, gx, k), lerp(C.fy, gy, k), 1 + 0.45 * k
    elseif t < 2.6 then
        fx, fy, z = gx, gy, 1.45
    elseif t < 3.9 then
        local k = ease((t - 2.6) / 1.3)
        fx, fy, z = lerp(gx, bx, k), lerp(gy, by, k), 1.45 - 0.3 * k
    else
        local k = ease((t - 3.9) / (CUT_LEN - 3.9))
        fx, fy, z = lerp(bx, me.x, k), lerp(by, me.y, k), 1.15 - 0.15 * k
    end
    cam.x, cam.y, X.camZoom = fx, fy, z
    -- the gate doors slide shut
    BF.gateClose = clamp((t - 1.3) / 0.6, 0, 1)
    if t >= 1.9 and not C.slam then
        C.slam = true
        playSfx("gate_slam", 0, 1)
        addShake(14)
        spawnParticles(L.gx, L.gy, 40, { 0.45, 0.4, 0.5 }, 40, 260, 1.0, 6)
        spawnParticles(L.gx, L.gy + 30, 20, { 0.75, 0.6, 1 }, 30, 160, 0.8, 3)
    end
    if t >= 3.2 and not C.wake then
        C.wake = true
        playSfx("boss_laugh", 0, 1.2)
        addShake(6)
        rings[#rings + 1] = { x = bx, y = by, r = 0, max = 420, life = 0.8, maxLife = 0.8, col = { 1, 0.6, 0.2 } }
    end
    if t >= CUT_LEN then
        X.cut, X.camZoom = nil, 1
        BF.fight = true
        BF.ph = "walk"
    end
end

------------------------------------------------------------------------------
-- The boss AI (host / single player)
------------------------------------------------------------------------------
local function bossTarget(e)
    local best, bd
    for _, p in ipairs(X.allPlayers()) do
        if not p.dead and not p.out then
            local d = dist(e.x, e.y, p.x, p.y)        -- no line of sight needed: it sees you through walls
            if not bd or d < bd then best, bd = p, d end
        end
    end
    return best, bd or 0
end

local function setPhase(e, ph, t)
    e.bph, e.bt, e.bt0 = ph, t, t
    X.BF.ph, X.BF.pt = ph, 0
end

local function aliveGourds()
    local n = 0
    for _, o in ipairs(enemies) do if not o.dead and o.kind == "gourd" then n = n + 1 end end
    return n
end

function X.bossPickAttack(e)
    local r = rand()
    local atk = r < 0.25 and "laugh" or (r < 0.5 and "prep" or (r < 0.75 and "necro" or "hat"))
    if atk == "necro" and aliveGourds() >= 15 then atk = rand() < 0.5 and "laugh" or "hat" end
    e.throws, e.volleys, e.raised = 0, 0, false
    X.BF.hat, X.BF.hatOn = nil, true
    if atk == "laugh" then
        setPhase(e, "laugh", 0.7 + faceWaves() * 0.45 + 0.8)
        X.wsfx("boss_laugh", e.x, e.y, 0.05, 1.3)
    elseif atk == "prep" then
        setPhase(e, "prep", max(PH_LEN.prep, 0.6 * bossSpeed()))   -- the jump warning never gets shorter than 0.6 s
        X.wsfx("boss_shake", e.x, e.y, 0.05, 1.2)
    elseif atk == "necro" then
        setPhase(e, "necro", PH_LEN.necro)
        X.wsfx("necro", e.x, e.y, 0.03, 1.2)
    else
        setPhase(e, "hat", PH_LEN.hat)
    end
end

-- 1. THE LAUGHTER: a fan of spooky faces
local function shootFaces(e, tgt, volley)
    local base = tgt and atan2(tgt.y - e.y, tgt.x - e.x) or e.angle
    local n, spread = 7, 1.15
    local off = (volley % 2 == 1) and spread / (n - 1) / 2 or 0
    for k = 0, n - 1 do
        local a = base - spread / 2 + k * spread / (n - 1) + off
        local b = { x = e.x + cos(a) * e.r * 0.95, y = e.y + sin(a) * e.r * 0.95, vx = cos(a) * FACE_SPEED, vy = sin(a) * FACE_SPEED,
            life = 2.6, owner = "enemy", kind = "face", dmg = 20, srcX = e.x, srcY = e.y }
        bullets[#bullets + 1] = b
        X.netEnemyShot(b)
    end
    X.wsfx("face_shot", e.x, e.y, 0.1, 1.2)
end

-- 3. NECROMANCER: the Gourds you killed rise again (at most 15 alive)
function X.bossRaise(e)
    local n = min(15 - aliveGourds(), max(3, world.gourdPool or 0))
    if n <= 0 then return end
    world.gourdPool = max(0, (world.gourdPool or 0) - n)
    local tgt = bossTarget(e)
    X.lairFree = true
    for _ = 1, n do
        for _ = 1, 25 do
            local a, d = rand() * 2 * pi, randRange(e.r + 60, e.r + 360)
            local x, y = e.x + cos(a) * d, e.y + sin(a) * d
            if X.inLair(x, y, 40) and areaFree(x - 16, y - 16, 32, 32, 4) then
                local g = spawnEnemy("gourd", nil, x, y)
                if g then
                    g.state, g.awareness, g.necro = "hunt", 1, true
                    g.lastX, g.lastY, g.searchTimer = tgt and tgt.x or x, tgt and tgt.y or y, 30
                    X.wring(x, y, 46, { 0.45, 1, 0.4 }, 0.6)
                end
                break
            end
        end
    end
    X.lairFree = false
end

-- push the boss out of any wall it landed on
local function unstick(e)
    local L = X.BF.A
    for _ = 1, 40 do
        local buf, n = WG.query(e.x - e.r, e.y - e.r, 2 * e.r, 2 * e.r)
        local hit = false
        for i = 1, n do
            local w = buf[i]
            if not w.enemyOnly and rectOverlap(e.x - e.r, e.y - e.r, 2 * e.r, 2 * e.r, w.x, w.y, w.w, w.h) then hit = true break end
        end
        if not hit then return end
        local d = max(1, dist(e.x, e.y, L.cx, L.by))
        e.x, e.y = e.x + (L.cx - e.x) / d * 12, e.y + (L.by - e.y) / d * 12
    end
end

function X.updateGuardian(e, dt)
    local BF = X.BF
    -- immune to stuns, bubbles, freezing and slows
    e.stunT, e.bubbleT, e.frostT, e.shockSlowT, e.speedMul = 0, 0, 0, 0, 1
    e.hitFlash = max(0, e.hitFlash - dt)
    e.muzzle = 0
    e.hpLag = e.hpLag > e.hp and max(e.hp, e.hpLag - 250 * dt) or e.hp
    e.spawnFade, e.canSee, e.state, e.awareness = 1, true, "hunt", 1
    if (e.burnT or 0) > 0 then                     -- the Flamethrower still burns it
        e.burnT = e.burnT - dt
        e.burnTick = (e.burnTick or 0.5) - dt
        if e.burnTick <= 0 then
            e.burnTick = 0.5
            local bd = e.burnDmg or 3
            e.hp = e.hp - bd
            X.wtext(e.x, e.y - e.r, "-" .. bd, { 1, 0.6, 0.2 })
            if e.hp <= 0 then killEnemy(e, nil, e.burnBy) return end
        end
    end
    if not BF or not BF.fight or BF.done then return end
    local tgt, td = bossTarget(e)
    local S = bossSpeed()
    e.bt = (e.bt or 1) - dt * S                    -- every attack runs faster on harder difficulties
    local ph = e.bph or "walk"
    BF.pt = clamp(1 - e.bt / max(0.01, e.bt0 or 1), 0, 1)
    if tgt and ph ~= "air" then
        e.angle = turnTowards(e.angle, atan2(tgt.y - e.y, tgt.x - e.x), (ph == "walk" and 3 or 1.6) * dt)
    end

    if ph == "walk" then
        if tgt then
            -- closes in while strafing from side to side (hard to aim at)
            e.gstrafeT = (e.gstrafeT or 0) - dt
            if e.gstrafeT <= 0 then e.gstrafeT, e.gstrafe = randRange(0.7, 1.5), rand() < 0.5 and -1 or 1 end
            local a = atan2(tgt.y - e.y, tgt.x - e.x)
            local fx, fy = 0, 0
            if td > e.r + 110 then fx, fy = cos(a) * 0.7, sin(a) * 0.7 end
            fx, fy = fx + cos(a + pi / 2) * e.gstrafe, fy + sin(a + pi / 2) * e.gstrafe
            X.moveDir(e, fx, fy, e.speed, dt)
        end
        if e.bt <= 0 and tgt then X.bossPickAttack(e) end
    elseif ph == "laugh" then
        local el = e.bt0 - e.bt
        local v = e.volleys or 0
        if v < faceWaves() and el >= 0.7 + v * 0.45 then
            shootFaces(e, tgt, v)
            e.volleys = v + 1
        end
        if e.bt <= 0 then setPhase(e, "walk", randRange(1.3, 2.1)) end
    elseif ph == "prep" then
        -- 2. JUMP: it shakes for 1 s, then jumps onto where you are standing
        if e.bt <= 0 then
            local L = X.BF.A
            local tx = clamp(tgt and tgt.x or e.x, L.ix + e.r + 10, L.ix + L.iw - e.r - 10)
            local ty = clamp(tgt and tgt.y or e.y, L.iy + e.r + 10, L.iy + L.ih - e.r - 10)
            e.jsx, e.jsy, e.jtx, e.jty = e.x, e.y, tx, ty
            BF.jsx, BF.jsy, BF.jtx, BF.jty = e.x, e.y, tx, ty
            e.hidden = 1                            -- can't be hit while in the air
            setPhase(e, "air", PH_LEN.air)
            X.wsfx("boss_jump", e.x, e.y, 0.05, 1.2)
        end
    elseif ph == "air" then
        local p = clamp(1 - e.bt / e.bt0, 0, 1)
        e.x, e.y = lerp(e.jsx, e.jtx, p), lerp(e.jsy, e.jty, p)
        if e.bt <= 0 then
            e.hidden = 0
            e.x, e.y = e.jtx, e.jty
            unstick(e)
            X.stomp(e.x, e.y, e.jsx, e.jsy)
            setPhase(e, "land", PH_LEN.land)
        end
    elseif ph == "land" then
        if e.bt <= 0 then setPhase(e, "walk", randRange(1.2, 2)) end
    elseif ph == "necro" then
        if not e.raised and e.bt <= e.bt0 - 0.7 then
            e.raised = true
            X.bossRaise(e)
        end
        if e.bt <= 0 then setPhase(e, "walk", randRange(1.4, 2.2)) end
    elseif ph == "hat" then
        -- 4. BOOMERANG HAT: thrown 600 px and back, 3 times
        local H = BF.hat
        if not H then
            if e.bt <= 0 then
                if (e.throws or 0) >= 3 then
                    BF.hatOn = true
                    setPhase(e, "walk", randRange(1.2, 2))
                else
                    e.throws = (e.throws or 0) + 1
                    local a = tgt and atan2(tgt.y - e.y, tgt.x - e.x) or e.angle
                    BF.hatN = (BF.hatN or 0) + 1
                    BF.hat = { x = e.x, y = e.y, vx = cos(a) * HAT_OUT, vy = sin(a) * HAT_OUT, d = 0, back = false, n = BF.hatN, spin = 0 }
                    BF.hatOn = false
                    X.wsfx("hat_throw", e.x, e.y, 0.1, 1.3)
                end
            end
        else
            H.spin = H.spin + dt * HAT_SPIN
            if not H.back then
                H.x, H.y = H.x + H.vx * dt * S, H.y + H.vy * dt * S
                H.d = H.d + HAT_OUT * dt * S
                if H.d >= HAT_RANGE then H.back = true end
            else
                local d = dist(H.x, H.y, e.x, e.y)
                if d < 40 then
                    BF.hat, BF.hatOn = nil, true
                    e.bt = 0.35                     -- a short pause before the next throw
                else
                    local sp = min(d, HAT_BACK * dt * S)
                    H.x, H.y = H.x + (e.x - H.x) / d * sp, H.y + (e.y - H.y) / d * sp
                end
            end
        end
    end
end

-- landing of the jump: damage + earthquake (on every machine for its own player)
function X.stomp(x, y, sx, sy)
    if MPS.role == "host" then NET.broadcast({ t = "stomp", x = floor(x), y = floor(y), sx = floor(sx), sy = floor(sy) }) end
    X.stompLocal(x, y, sx, sy)
end

function X.stompLocal(x, y, sx, sy)
    playSfx("boss_land", 0.05, max(0.4, volAt(x, y)))
    addShake(18)
    rings[#rings + 1] = { x = x, y = y, r = 0, max = 300, life = 0.5, maxLife = 0.5, col = { 1, 0.6, 0.25 } }
    rings[#rings + 1] = { x = x, y = y, r = 0, max = 800, life = 1.1, maxLife = 1.1, col = { 0.6, 0.45, 0.35 } }
    spawnParticles(x, y, 50, { 0.35, 0.27, 0.32 }, 80, 420, 1.0, 7)
    spawnParticles(x, y, 24, { 1, 0.55, 0.15 }, 60, 260, 0.6, 4)
    decals[#decals + 1] = { x = x, y = y, r = 70, a = rand() * 6, kind = "scorch", life = 30 }
    local saved = player
    player = me
    local R = X.ESTATS.guardian.r + 30
    if not me.dead and not me.out then
        local d = dist(x, y, me.x, me.y)
        if me.iframes > 0 then
            if d < R + me.r then
                stats.dodges = stats.dodges + 1
                addText(me.x, me.y - 30, "DODGE", { 0.6, 0.9, 1 })
            end
        else
            if d < R + me.r then damagePlayer(50, sx, sy, "stomp") end
            if d < 800 and not me.dead then
                if (me.quakeT or 0) <= 0 then addText(me.x, me.y - 46, "EARTHQUAKE! -10% speed", { 1, 0.6, 0.3 }, true) end
                me.quakeT = 5
            end
        end
    end
    player = saved
end

-- every frame on every machine while the fight exists
function X.updateBossFight(dt)
    local BF = X.BF
    local g = X.bossEntity()
    -- after the Gatekeeper falls the arena goes back to normal
    if BF.done and BF.kind == "gatekeeper" then
        BF.clearT = (BF.clearT or 4) - dt
        if BF.clearT <= 0 then X.BF = nil end
        return
    end
    if MPS.role == "client" then
        BF.pt = min(1, (BF.pt or 0) + dt * bossSpeed() / (PH_LEN[BF.ph] or 1))
        -- smooth the thrown hat between snapshots
        local H, T = BF.hat, BF.hatT
        if H and T then
            if H.n ~= T.n then H.x, H.y, H.n = T.x, T.y, T.n end
            local k = min(1, dt * 14)
            H.x, H.y = lerp(H.x, T.x, k), lerp(H.y, T.y, k)
            H.spin = (H.spin or 0) + dt * HAT_SPIN
        end
    end
    if BF.done then return end
    -- the boss is solid: it pushes you away
    if g and (g.hidden or 0) <= 0 and not me.dead then
        local d = dist(g.x, g.y, me.x, me.y)
        local minD = g.r + me.r
        if d < minD and d > 0.01 then moveEntity(me, (me.x - g.x) / d * (minD - d), (me.y - g.y) / d * (minD - d)) end
    end
    -- the boomerang hat hits once per throw
    local H = BF.hat
    if H and BF.fight and not me.dead and not me.out and BF.hatHitN ~= H.n and dist(H.x, H.y, me.x, me.y) < HAT_HIT + me.r then
        BF.hatHitN = H.n
        if me.iframes > 0 then
            stats.dodges = stats.dodges + 1
            addText(me.x, me.y - 30, "DODGE", { 0.6, 0.9, 1 })
        else
            damagePlayer(20, H.x, H.y, "hat")
        end
    end
    -- fresh ammo boxes in the corners every 45 s
    BF.boxT = (BF.boxT or 45) - dt
    if BF.boxT <= 0 then BF.boxT = 45 lairBoxes(BF.A) end
end

-- the boss is dead (every machine)
function X.bossDefeated(x, y)
    if MPS.role == "host" then NET.broadcast({ t = "bdead", x = floor(x), y = floor(y) }) end
    X.onBossDead(x, y)
end

function X.onBossDead(x, y)
    local BF = X.BF
    if not BF or BF.done then return end
    if BF.kind == "gatekeeper" then X.onGatekeeperDead(x, y) return end
    BF.done, BF.fight, BF.hat, BF.hatOn = true, false, nil, false
    if MPS.role ~= "client" then
        for _, e in ipairs(enemies) do if e.kind == "gourd" then e.dead = true end end
    end
    X.clearEnemyBullets()
    -- 30 credits for beating the boss (not on Easy = practice mode, never in admin mode)
    if X.D.credits > 0 and not admin.on then
        PROF.data.credits = PROF.data.credits + X.BOSS_CREDITS
        PROF.data.creditsTotal = (PROF.data.creditsTotal or 0) + X.BOSS_CREDITS
        PROF.save()
        stats.creditsEarned = stats.creditsEarned + X.BOSS_CREDITS
        addText(me.x, me.y - 70, "+" .. X.BOSS_CREDITS .. " CREDITS", { 1, 0.85, 0.25 }, true)
        playSfx("coin")
    end
    stats.bossDefeated = true
    showBanner("THE GUARDIAN HAS FALLEN", "The Haunted Hollow is free. The Frontier is yours!", { 1, 0.75, 0.25 })
    X.LAIR.gate.off = true
    if not endTimer then
        endTimer = 6
        finishGame(true)
        playSfx("win")
    end
end

-- boss state for the snapshot
function X.bossNet()
    local BF = X.BF
    local g = BF.boss
    local H = BF.hat
    return { k = BF.kind, ph = BF.ph, pt = floor((BF.pt or 0) * 100) / 100, mh = g and g.maxHp or 0, f = BF.fight and 1 or 0,
        d = BF.done and 1 or 0, ho = BF.hatOn and 1 or 0,
        hx = H and floor(H.x) or nil, hy = H and floor(H.y) or nil, hn = H and H.n or nil,
        jsx = BF.jsx and floor(BF.jsx) or nil, jsy = BF.jsy and floor(BF.jsy) or nil,
        jtx = BF.jtx and floor(BF.jtx) or nil, jty = BF.jty and floor(BF.jty) or nil }
end

function X.bossApply(bs)
    if type(bs) ~= "table" then return end
    if bs.d == 1 and not X.BF then return end
    if not X.BF then X.beginBoss(bs.k or "guardian", false) end
    local BF = X.BF
    if bs.ph and BF.ph ~= bs.ph then BF.ph, BF.pt = bs.ph, tonumber(bs.pt) or 0 end
    if bs.f == 1 and not X.cut then BF.fight = true end
    BF.hatOn = bs.ho == 1
    BF.jsx, BF.jsy, BF.jtx, BF.jty = bs.jsx, bs.jsy, bs.jtx, bs.jty
    if bs.hx then
        BF.hatT = { x = bs.hx, y = bs.hy, n = bs.hn }
        if not BF.hat then BF.hat = { x = bs.hx, y = bs.hy, n = bs.hn, spin = 0 } end
    else
        BF.hat, BF.hatT = nil, nil
    end
    local g = X.bossEntity()
    if g and (tonumber(bs.mh) or 0) > 0 then g.maxHp = bs.mh end
end
end

------------------------------------------------------------------------------
-- THE BLAZE GATEKEEPER (mini-boss in front of the Hollow gate)
--   BLAZE ROD   charges you and swings a burning rod (25 DMG)
--   FIRE SPIT   a fan of flames, 30 DMG each (Easy 3 / Normal 5 / Hard 6 / Nightmare 8)
--   FIRE SWIRL  spins for 2 s, then flames in every direction (10 / 15 / 20 / 25)
--   FIRE SHIELD 3.5 s at half speed: deflects bullets, melee and even spells back at you
------------------------------------------------------------------------------
do
local GK_LEN = { walk = 1.2, charge = 0.6, rod = 0.35, spit = 0.55, swirl = 2.0, rest = 0.6, shield = 3.5 }
X.GK_LEN = GK_LEN
X.GK_CREDITS = 5

-- is this the Blaze Gatekeeper with his FIRE SHIELD up? (works on clients too: BF.ph is synced)
function X.gkShielded(e)
    local BF = X.BF
    return e and e.kind == "gatekeeper" and BF and BF.kind == "gatekeeper" and BF.ph == "shield" and not BF.done
end
function X.shieldedGK()
    local BF = X.BF
    if not BF or BF.kind ~= "gatekeeper" or BF.ph ~= "shield" or BF.done then return nil end
    return X.bossEntity()
end
-- whatever hits the shield is thrown back at me
function X.reflectToMe(dmg, fromX, fromY, what)
    if me.dead then return end
    local saved = player
    player = me
    addText(me.x, me.y - 46, what or "DEFLECTED!", { 1, 0.5, 0.15 }, true)
    spawnParticles(me.x, me.y, 14, { 1, 0.55, 0.15 }, 60, 240, 0.5, 3)
    if dmg > 0 then damagePlayer(dmg, fromX, fromY, "reflect") end
    player = saved
end

local function gkTarget(e)
    local best, bd
    for _, p in ipairs(X.allPlayers()) do
        if not p.dead and not p.out then
            local d = dist(e.x, e.y, p.x, p.y)
            if not bd or d < bd then best, bd = p, d end
        end
    end
    return best, bd or 0
end

local function setPh(e, ph, t)
    e.bph, e.bt, e.bt0 = ph, t, t
    X.BF.ph, X.BF.pt = ph, 0
end

local function flame(e, a, speed, life, dmg)
    X.enemyShot(e, "eflame", a, speed, life, dmg)
end

function X.updateGatekeeper(e, dt)
    local BF = X.BF
    e.stunT, e.bubbleT, e.frostT, e.shockSlowT, e.speedMul = 0, 0, 0, 0, 1
    e.hitFlash = max(0, e.hitFlash - dt)
    e.hpLag = e.hpLag > e.hp and max(e.hp, e.hpLag - 200 * dt) or e.hp
    e.spawnFade, e.canSee, e.state, e.awareness = 1, true, "hunt", 1
    e.burnT = 0                                   -- made of fire: flames don't burn him
    if not BF or not BF.fight or BF.done then return end
    local S = X.D.bossSpeed or 1
    local tgt, td = gkTarget(e)
    e.bt = (e.bt or 1) - dt * S
    local ph = e.bph or "walk"
    BF.pt = clamp(1 - e.bt / max(0.01, e.bt0 or 1), 0, 1)
    local toT = tgt and atan2(tgt.y - e.y, tgt.x - e.x) or e.angle
    if ph ~= "swirl" then e.angle = turnTowards(e.angle, toT, 6 * dt) end
    e.walkAnim = e.walkAnim + dt * 6

    if ph == "walk" then
        if tgt and td > e.r + 90 then X.moveDir(e, tgt.x - e.x, tgt.y - e.y, e.speed, dt) end
        if e.bt <= 0 and tgt then
            local r = rand()
            if r < 0.25 then
                setPh(e, "charge", GK_LEN.charge)
            elseif r < 0.5 then
                setPh(e, "spit", GK_LEN.spit)
            elseif r < 0.75 then
                -- FIRE SHIELD: 3.5 s, half speed, deflects EVERYTHING (bullets, melee, spells)
                setPh(e, "shield", GK_LEN.shield * S)
                X.wsfx("gk_swirl", e.x, e.y, 0.05, 0.8)
            else
                setPh(e, "swirl", GK_LEN.swirl)
                X.wsfx("gk_swirl", e.x, e.y, 0.05, 1.3)
            end
        end
    elseif ph == "shield" then
        if tgt and td > e.r + 90 then X.moveDir(e, tgt.x - e.x, tgt.y - e.y, e.speed * 0.5, dt) end
        if e.bt <= 0 then setPh(e, "rest", GK_LEN.rest) end
    elseif ph == "charge" then
        -- runs at you, then swings the rod
        if tgt and td > e.r + tgt.r + 40 then X.moveDir(e, tgt.x - e.x, tgt.y - e.y, 430, dt) end
        if e.bt <= 0 or (tgt and td <= e.r + tgt.r + 40) then
            setPh(e, "rod", GK_LEN.rod)
            X.wsfx("gk_rod", e.x, e.y, 0.1, 1.2)
        end
    elseif ph == "rod" then
        if e.bt <= 0 then
            -- BLAZE ROD: hits everyone in front of him
            for _, p in ipairs(X.allPlayers()) do
                if not p.dead and dist(e.x, e.y, p.x, p.y) < e.r + p.r + 70
                   and abs(angleDiff(e.angle, atan2(p.y - e.y, p.x - e.x))) < 1.4 then
                    local saved = player
                    player = p
                    X.meleeHit("rod", 25, e.x, e.y, e.angle)
                    player = saved
                end
            end
            X.wring(e.x + cos(e.angle) * 60, e.y + sin(e.angle) * 60, 90, { 1, 0.5, 0.1 }, 0.3)
            setPh(e, "rest", GK_LEN.rest)
        end
    elseif ph == "spit" then
        if e.bt <= 0 then
            -- FIRE SPIT: a fan of flames
            local n = X.D.gkSpit or 3
            local spread = 0.18 * (n - 1)
            for i = 0, n - 1 do
                local a = toT - spread / 2 + (n > 1 and spread * i / (n - 1) or 0)
                flame(e, a, 520, 620 / 520, 30)
            end
            setPh(e, "rest", GK_LEN.rest)
        end
    elseif ph == "swirl" then
        e.angle = e.angle + dt * 18                -- spinning!
        if e.bt <= 0 then
            -- FIRE SWIRL: flames in every direction
            local n = X.D.gkSwirl or 10
            for i = 0, n - 1 do
                flame(e, i * 2 * pi / n + rand() * 0.1, 430, 700 / 430, 30)
            end
            X.wring(e.x, e.y, 260, { 1, 0.45, 0.1 }, 0.5)
            setPh(e, "rest", GK_LEN.rest)
        end
    elseif ph == "rest" then
        if e.bt <= 0 then setPh(e, "walk", randRange(0.9, 1.5)) end
    end
end

-- the Gatekeeper fell (every machine): the key drops, everybody learns the Blaze Spell
function X.onGatekeeperDead(x, y)
    local BF = X.BF
    BF.done, BF.fight = true, false
    world.gkDead = true
    -- the blazing key flies into the Hollow gate
    X.keyFly = { x = x, y = y, sx = x, sy = y, tx = K.EAST_X + K.WORLD_W / 2, ty = K.VOLC_Y1 + K.GATE_T / 2, t = 0, dur = 2.4 }
    if not X.cut then X.cut = { kind = "key", t = 0, cx = cam.x, cy = cam.y } end
    X.clearEnemyBullets()
    if X.GKA then X.GKA.gate.off = true end
    -- 5 credits (not on Easy = practice mode, never in admin mode)
    if X.D.credits > 0 and not admin.on then
        PROF.data.credits = PROF.data.credits + X.GK_CREDITS
        PROF.data.creditsTotal = (PROF.data.creditsTotal or 0) + X.GK_CREDITS
        PROF.save()
        stats.creditsEarned = stats.creditsEarned + X.GK_CREDITS
        addText(me.x, me.y - 70, "+" .. X.GK_CREDITS .. " CREDITS", { 1, 0.85, 0.25 }, true)
        playSfx("coin")
    end
    if not me.hasBlaze then
        me.hasBlaze = true
        X.chatAdd(nil, "You learned THE BLAZE SPELL (open the spellbook with B).", { 1, 0.55, 0.15 })
    end
    stats.gatekeeperDefeated = true
    if X.achieve then X.achieve("gatekeeper") end
    showBanner("THE BLAZE GATEKEEPER HAS FALLEN", "His blazing KEY flies to the Hollow gate - you learned the BLAZE SPELL!", { 1, 0.55, 0.15 })
    playSfx("win")
end

------------------------------------------------------------------------------
-- The Hollow opens: a flyover of the whole map (no HUD, no enemies) that ends
-- on the sleeping Guardian, then back to the player
------------------------------------------------------------------------------
local FLY_OUT, FLY_PATH, FLY_IN, FLY_HOLD, FLY_BACK = 1.2, 10, 1.4, 2.2, 2.2
X.FLY_LEN = FLY_OUT + FLY_PATH + FLY_IN + FLY_HOLD + FLY_BACK
function X.startFlyover()
    if X.cut and X.cut.kind == "key" then X.cut.thenFly = true return end   -- right after the key cutscene
    if X.cut then return end
    local W = K.WORLD_W
    local L = X.LAIR
    X.cut = { kind = "fly", t = 0, fx = cam.x, fy = cam.y,
        path = {
            { W / 2, K.WORLD_H / 2 },                                   -- the Dustbowl Frontier
            { W / 2, (K.FROZEN_Y0 + K.FROZEN_Y1) / 2 },                 -- the Frozen Wastes
            { K.EAST_X + W / 2, (K.FROZEN_Y0 + K.FROZEN_Y1) / 2 },      -- the Murky Swamp
            { K.EAST_X + W / 2, (K.VOLC_Y0 + K.VOLC_Y1) / 2 },          -- the Volcanic Rift
            { K.EAST_X + W / 2, K.SPOOKY_Y0 + 2500 },                   -- the Haunted Hollow
            { L.bx, L.by - 200 },                                        -- the Guardian's lair
        } }
    X.hideEnemies = true
    banner, overlay = nil, nil
    X.chat.open = false
    playSfx("boss_laugh", 0.05, 0.4)
end

local function ease(t) t = clamp(t, 0, 1) return t * t * (3 - 2 * t) end
function X.flyRegion()
    return regionIn(cam.x, cam.y) or regionAt(cam.x, cam.y)
end

function X.updateFlyover(dt)
    local C = X.cut
    C.t = C.t + dt
    local t = C.t
    local P = C.path
    local fx, fy, z
    if t < FLY_OUT then
        local k = ease(t / FLY_OUT)
        fx, fy, z = lerp(C.fx, P[1][1], k), lerp(C.fy, P[1][2], k), lerp(1, 0.3, k)
    elseif t < FLY_OUT + FLY_PATH then
        -- glide from region to region
        local u = (t - FLY_OUT) / FLY_PATH * (#P - 1)
        local i = min(#P - 1, floor(u) + 1)
        local k = ease(u - (i - 1))
        fx, fy, z = lerp(P[i][1], P[i + 1][1], k), lerp(P[i][2], P[i + 1][2], k), 0.3
    elseif t < FLY_OUT + FLY_PATH + FLY_IN then
        local k = ease((t - FLY_OUT - FLY_PATH) / FLY_IN)
        local L = X.LAIR
        fx, fy, z = lerp(P[#P][1], L.bx, k), lerp(P[#P][2], L.by, k), lerp(0.3, 0.85, k)
        C.lx, C.ly = fx, fy
    elseif t < FLY_OUT + FLY_PATH + FLY_IN + FLY_HOLD then
        local L = X.LAIR
        fx, fy, z = L.bx, L.by, 0.85
        C.lx, C.ly = fx, fy
    else
        -- back to the player: zoom out, glide, zoom in
        local k = ease((t - X.FLY_LEN + FLY_BACK) / FLY_BACK)
        fx, fy = lerp(C.lx, me.x, k), lerp(C.ly, me.y, k)
        z = 0.85 + (1 - 0.85) * k - 0.55 * sin(pi * k)
    end
    cam.x, cam.y, X.camZoom = fx, fy, max(0.12, z)
    if t >= X.FLY_LEN then
        X.cut, X.camZoom, X.hideEnemies = nil, 1, false
        cam.x, cam.y = me.x, me.y
        showBanner("THE HAUNTED HOLLOW IS OPEN", "Its gate is at the far south of the Volcanic Rift", { 0.85, 0.55, 1 })
    end
end

-- the blazing key flying into the Hollow gate (every machine)
local function updateKeyFly(dt)
    local F = X.keyFly
    if not F then return end
    F.t = F.t + dt
    local k = clamp(F.t / F.dur, 0, 1)
    local e = k * k * (3 - 2 * k)
    F.x = F.sx + (F.tx - F.sx) * e
    F.y = F.sy + (F.ty - F.sy) * e - sin(pi * k) * 260         -- a high arc
    if rand() < 0.9 then spawnParticles(F.x, F.y, 2, { 1, 0.55 + rand() * 0.3, 0.1 }, 20, 120, 0.5, 3) end
    if k >= 1 then
        X.keyFly = nil
        addShake(16)
        playSfx("key_pickup")
        playSfx("explosion", 0.1, 0.6)
        rings[#rings + 1] = { x = F.tx, y = F.ty, r = 0, max = 420, life = 0.8, maxLife = 0.8, col = { 1, 0.55, 0.15 } }
        spawnParticles(F.tx, F.ty, 60, { 1, 0.55, 0.15 }, 80, 380, 1, 4)
        world.hasKey = true
        if world.kills < K.SPOOKY_UNLOCK_KILLS and not admin.on then
            showBanner("THE KEY IS IN THE LOCK", "The Hollow Gate opens at " .. K.SPOOKY_UNLOCK_KILLS .. " kills", { 1, 0.8, 0.3 })
        end
        X.checkGates()             -- enough kills: the wall opens right now
    end
end
X.updateKeyFly = updateKeyFly

-- camera: follows the key, watches the gate (shake + the wall opens), glides back to you
X.KEYCUT_LEN = 2.4 + 1.6 + 1.0
function X.updateKeyCut(dt)
    local C = X.cut
    C.t = C.t + dt
    updateKeyFly(dt)
    local F = X.keyFly
    local gx, gy = K.EAST_X + K.WORLD_W / 2, K.VOLC_Y1 + K.GATE_T / 2 - 120
    if C.t < 2.4 then
        local k = clamp(C.t / 0.6, 0, 1)
        local fx, fy = F and F.x or gx, F and F.y or gy
        cam.x, cam.y = C.cx + (fx - C.cx) * k, C.cy + (fy - C.cy) * k
    elseif C.t < 4.0 then
        cam.x, cam.y = cam.x + (gx - cam.x) * min(1, dt * 6), cam.y + (gy - cam.y) * min(1, dt * 6)
        C.lx, C.ly = cam.x, cam.y
    else
        local k = clamp((C.t - 4.0) / 1.0, 0, 1)
        k = k * k * (3 - 2 * k)
        cam.x, cam.y = (C.lx or gx) + (me.x - (C.lx or gx)) * k, (C.ly or gy) + (me.y - (C.ly or gy)) * k
    end
    if C.t >= X.KEYCUT_LEN then
        X.cut = nil
        cam.x, cam.y = me.x, me.y
        if C.thenFly then X.startFlyover() end
    end
end

function X.drawKeyFly()
    local F = X.keyFly
    if not F then return end
    local t = menuTime
    lg.setColor(1, 0.45, 0.1, 0.35)
    lg.circle("fill", F.x, F.y, 30 + 4 * sin(t * 12))
    lg.push()
    lg.translate(F.x, F.y)
    lg.rotate(t * 8)
    lg.setColor(1, 0.8, 0.25)
    lg.setLineWidth(4)
    lg.circle("line", -12, 0, 9)
    lg.line(-3, 0, 20, 0)
    lg.line(14, 0, 14, 8)
    lg.line(20, 0, 20, 7)
    lg.setLineWidth(1)
    lg.pop()
end

-- (old pickup: the key no longer lies on the ground)
function X.updateKeyItem(dt)
    if not (X.cut and X.cut.kind == "key") then updateKeyFly(dt) end
    local K2 = world.keyItem
    if not K2 or world.hasKey then return end
    K2.t = K2.t + dt
    if not me.dead and dist(me.x, me.y, K2.x, K2.y) < 50 then
        world.keyItem = nil
        playSfx("key_pickup")
        showBanner("KEY TO THE HOLLOW", "The Hollow Gate opens at " .. K.SPOOKY_UNLOCK_KILLS .. " kills", { 1, 0.8, 0.3 })
        if MPS.role == "client" then
            NET.toHost({ t = "key" })
        else
            world.hasKey = true
        end
    end
end
end

------------------------------------------------------------------------------
-- ACHIEVEMENTS, CO-OP REVIVE and RANDOM EVENTS
------------------------------------------------------------------------------
do
-- ============ ACHIEVEMENTS (saved forever in the profile: ach_<id> = 1)
X.ACH = {
    { id = "firstblood",  name = "First Blood",       desc = "Get your first kill" },
    { id = "centurion",   name = "Centurion",         desc = "100 kills in one game" },
    { id = "maxlevel",    name = "Max Level",         desc = "Reach LVL MAX" },
    { id = "infiltrator", name = "Infiltrator",       desc = "Infiltrate the Stronghold" },
    { id = "gatekeeper",  name = "Gatekeeper Slayer", desc = "Defeat the Blaze Gatekeeper" },
    { id = "guardian",    name = "Guardian Slayer",   desc = "Defeat the Guardian of the Hollow" },
    { id = "nightmare",   name = "Nightmare Legend",  desc = "Win Story mode on Nightmare" },
    { id = "survivor",    name = "Survivor",          desc = "Reach wave 5 in Endless" },
    { id = "collector",   name = "Collector",         desc = "Own 10 credit weapons" },
    { id = "lucky",       name = "Lucky Pull",        desc = "Pull a 2% (or rarer) crate weapon" },
    { id = "savior",      name = "Savior",            desc = "Revive a teammate" },
    { id = "treasure",    name = "Treasure Hunter",   desc = "Catch a Treasure Goblin" },
    { id = "explorer",    name = "Explorer",          desc = "Visit all 5 regions in one game" },
    { id = "spellbinder", name = "Spellbinder",       desc = "Cast every spell at least once" },
}
X.ACH_BY = {}
for i, a in ipairs(X.ACH) do a.i = i X.ACH_BY[a.id] = a end
X.toasts = {}

function X.hasAch(id) return (PROF.data["ach_" .. id] or 0) == 1 end
function X.achCount()
    local n = 0
    for _, a in ipairs(X.ACH) do if X.hasAch(a.id) then n = n + 1 end end
    return n
end

-- admin mode never unlocks achievements
function X.achieve(id)
    local a = X.ACH_BY[id]
    if not a or X.hasAch(id) or admin.on then return end
    PROF.data["ach_" .. id] = 1
    PROF.save()
    X.toasts[#X.toasts + 1] = { a = a, t = 0 }
    playSfx("achievement")
end

function X.achieveCheck()
    if admin.on then return end
    local d = PROF.data
    local changed = false
    for id in pairs(stats and stats.castIds or {}) do
        if d["cast_" .. id] ~= 1 then d["cast_" .. id] = 1 changed = true end
    end
    if changed then PROF.save() end
    local all = true
    for _, id in ipairs(PROF.SPELL_IDS) do if d["cast_" .. id] ~= 1 then all = false end end
    if all then X.achieve("spellbinder") end
    local n = 0
    for id, own in pairs(d.owned) do if own and WEAPONS[id] then n = n + 1 end end
    if n >= 10 then X.achieve("collector") end
end

-- ============ CO-OP REVIVE
-- Downed: 60 s until you respawn in the shed (and lose a heart). A teammate
-- holding V next to you for 3 s revives you in place with half HP - no heart lost.
X.DOWN_TIME = 60
X.REVIVE_TIME = 3
X.REVIVE_RANGE = 90

function X.goDown()
    local p = me
    p.respawnT = X.DOWN_TIME
    playSfx("lose")
    X.chatAdd(nil, "You are DOWN! A teammate can revive you (hold V next to you). Respawn in " .. X.DOWN_TIME .. " s, or press R.",
        { 1, 0.4, 0.35 })
    X.sendChat(nil, MPS.name .. " is DOWN! Hold V next to them for 3 s to revive.", true)
end

-- the timer ran out (or R): a heart is lost
function X.downExpired()
    local p = me
    p.lives = max(0, (p.lives or 3) - 1)
    if p.lives > 0 then
        X.respawn()
        X.chatAdd(nil, "You lost a heart - " .. p.lives .. " heart" .. (p.lives == 1 and "" or "s") .. " left.", { 1, 0.5, 0.4 })
        X.sendChat(nil, MPS.name .. " respawned in the shed (" .. p.lives .. " heart" .. (p.lives == 1 and "" or "s") .. " left)", true)
    else
        p.out, p.respawnT = true, 0
        X.chatAdd(nil, "You are out of hearts - GAME OVER. Spectating your team...", { 1, 0.3, 0.3 })
        X.sendChat(nil, MPS.name .. " is out of hearts!", true)
    end
end

-- a teammate revived me
function X.getRevived(by)
    local p = me
    if not p.dead or p.out then return end
    p.dead, p.respawnT = false, 0
    p.hp, p.hpLag = floor(p.maxHp / 2), floor(p.maxHp / 2)
    p.poisonT, p.chillT, p.spookT, p.blindT, p.kbx, p.kby, p.vx, p.vy = 0, 0, 0, 0, 0, 0, 0, 0
    p.iframes = 2
    playSfx("revive")
    spawnParticles(p.x, p.y, 30, { 0.5, 1, 0.6 }, 40, 200, 0.8, 3)
    rings[#rings + 1] = { x = p.x, y = p.y, r = 0, max = 140, life = 0.6, maxLife = 0.6, col = { 0.5, 1, 0.6 } }
    addText(p.x, p.y - 40, "REVIVED!", { 0.5, 1, 0.6 }, true)
    X.chatAdd(nil, (by or "A teammate") .. " revived you! (half HP, no heart lost)", { 0.5, 1, 0.6 })
end

function X.sendRevive(id)
    if MPS.role == "host" then
        NET.send(id, { t = "rev", by = MPS.name })
    else
        NET.toHost({ t = "rev", to = id, by = MPS.name })
    end
end

X.rev = nil
function X.updateRevive(dt)
    X.reviveTarget = nil
    if not MPS.online or me.dead or X.chat.open or overlay or X.cut then X.rev = nil return end
    local tgt, tid
    for id, o in pairs(MPS.others) do
        if o.ready and o.dead and not o.out and o.x and dist(me.x, me.y, o.x, o.y) < X.REVIVE_RANGE then tgt, tid = o, id break end
    end
    X.reviveTarget = tgt
    if tgt and love.keyboard.isDown("v") then
        if not X.rev or X.rev.id ~= tid then X.rev = { id = tid, t = 0 } end
        X.rev.t = X.rev.t + dt
        if X.rev.t >= X.REVIVE_TIME then
            X.sendRevive(tid)
            tgt.dead = false
            X.rev = nil
            playSfx("revive")
            addText(tgt.x, tgt.y - 40, "REVIVED!", { 0.5, 1, 0.6 }, true)
            X.sendChat(nil, MPS.name .. " revived " .. (tgt.name or "a teammate") .. "!", true)
            X.chatAdd(nil, "You revived " .. (tgt.name or "a teammate") .. "!", { 0.5, 1, 0.6 })
            X.achieve("savior")
        end
    else
        X.rev = nil
    end
end

-- ============ RANDOM EVENTS (host / single player decides, every machine plays them)
--   meteors   METEOR SHOWER: red circles, then a rock falls (30 s)
--   merchant  TRAVELLING MERCHANT at the shed for one day
--   goblin    TREASURE GOBLIN: runs away - catch it within 30 s
X.EV = nil
X.evT = 200
X.skyRocks = {}
X.EVENT_KINDS = { "meteors", "merchant", "goblin" }
X.METEOR_DMG = 20
X.METEOR_R = 80

X.MERCHANT_ITEMS = {
    { id = "ammo",    name = "Ammo pack",       desc = "+60 ammo",                    price = 45 },
    { id = "bandage", name = "Bandage pack",    desc = "+3 bandages",                 price = 60 },
    { id = "potion",  name = "Vitality potion", desc = "+25 MAX HP (one per visit)",  price = 200 },
}

function X.merchantSpot()
    local S = X.SHED
    return S.x + S.w / 2 + 70, S.y + S.h + 60
end

function X.resetEvents()
    X.EV, X.evT, X.skyRocks = nil, randRange(150, 220), {}
    X.potionBought = false
end

-- every machine
function X.startEvent(k, d, stock)
    X.EV = { k = k, t = d or 30 }
    if k == "merchant" then X.setStock(stock) end
    if k == "meteors" then
        X.metT = 1
        showBanner("METEOR SHOWER!", "Watch the sky - get out of the red circles! (30 s)", { 1, 0.45, 0.2 })
        playSfx("thunder", 0.1, 0.8)
    elseif k == "merchant" then
        X.potionBought = false
        showBanner("A TRAVELLING MERCHANT", "He waits next to the shed until tomorrow - press E next to him to trade", { 1, 0.85, 0.45 })
        playSfx("merchant_bell")
        X.chatAdd(nil, "A travelling merchant arrived at the shed (press E next to him).", { 1, 0.85, 0.45 })
    elseif k == "goblin" then
        showBanner("A TREASURE GOBLIN!", "Catch it within 30 seconds for big gold and loot!", { 1, 0.85, 0.2 })
        playSfx("goblin_giggle")
    end
end

-- host / SP: pick and start an event
function X.hostEvent(k)
    k = k or X.EVENT_KINDS[randInt(1, #X.EVENT_KINDS)]
    local d = k == "merchant" and X.DAY_LEN or 30
    if k == "goblin" then
        local list = {}
        for _, p in ipairs(X.allPlayers()) do if not p.dead and not p.out then list[#list + 1] = p end end
        if #list == 0 then return end
        local p = list[randInt(1, #list)]
        local reg = regionIn(p.x, p.y) or "desert"
        local x, y = findFreeSpot(16, 420, reg, p, 750)
        if not x then return end
        local e = spawnEnemy("goblin", nil, x, y)
        if not e then return end
        e.region, e.lifeT, e.state, e.awareness, e.spawnFade = reg, 30, "hunt", 1, 0.5
    end
    local stock = (k == "merchant" and X.endless) and X.pickStock() or nil
    X.startEvent(k, d, stock)
    if MPS.role == "host" then NET.broadcast({ t = "ev", k = k, d = d, s = stock }) end
end

function X.goblinEscape(e)
    e.dead, e.unloaded = true, true
    spawnParticles(e.x, e.y, 30, { 1, 0.85, 0.2 }, 60, 260, 0.7, 3)
    X.wsfx("bat_poof", e.x, e.y, 0.1)
    addMessage("The Treasure Goblin escaped with its gold...", { 1, 0.7, 0.3 })
    if MPS.role == "host" then NET.broadcast({ t = "msg", s = "The Treasure Goblin escaped with its gold...", c = { 1, 0.7, 0.3 } }) end
end

X.AI.goblin = function(e, dt, pd, toP)
    e.hop = e.hop + dt * 14
    e.lifeT = (e.lifeT or 30) - dt
    if e.lifeT <= 0 then X.goblinEscape(e) return end
    e.gigT = (e.gigT or 1.5) - dt
    if e.gigT <= 0 then e.gigT = randRange(2, 3.5) X.wsfx("goblin_giggle", e.x, e.y, 0.15) end
    e.turnT = (e.turnT or 0) - dt
    if pd < 700 then
        -- runs away from you, zig-zagging
        local a = toP + pi + sin(e.hop * 0.25) * 0.7
        if e.stuck > 0.05 or e.turnT > 0 then
            if e.turnT <= 0 then e.turnT, e.wa = 0.6, a + (rand() < 0.5 and 1.6 or -1.6) end
            a = e.wa
        end
        X.moveDir(e, cos(a), sin(a), e.huntSpeed, dt)
        e.angle = a
    else
        if e.turnT <= 0 then e.turnT, e.wa = randRange(1, 2), rand() * 2 * pi end
        X.moveDir(e, cos(e.wa), sin(e.wa), e.speed, dt)
        e.angle = e.wa
    end
end

-- falling rocks around MY player (each machine hurts only its own player)
local function updateMeteors(dt)
    X.metT = (X.metT or 1) - dt
    if X.metT <= 0 and not me.dead and X.EV and X.EV.t > 1.5 then
        X.metT = randRange(0.6, 1.0)
        local x, y
        if rand() < 0.25 then
            x, y = me.x + me.vx * 0.9, me.y + me.vy * 0.9      -- aimed where you are going
        else
            local a, d = rand() * 2 * pi, randRange(60, 520)
            x, y = me.x + cos(a) * d, me.y + sin(a) * d
        end
        X.skyRocks[#X.skyRocks + 1] = { x = x, y = y, t = 1.4, maxT = 1.4 }
    end
    for i = #X.skyRocks, 1, -1 do
        local m = X.skyRocks[i]
        m.t = m.t - dt
        if m.t <= 0 then
            table.remove(X.skyRocks, i)
            X.wsfx("explosion", m.x, m.y, 0.15, 0.7)
            spawnParticles(m.x, m.y, 26, { 1, 0.5, 0.15 }, 60, 320, 0.6, 3.5)
            spawnParticles(m.x, m.y, 14, { 0.35, 0.3, 0.28 }, 40, 200, 0.9, 4)
            rings[#rings + 1] = { x = m.x, y = m.y, r = 0, max = X.METEOR_R * 1.4, life = 0.35, maxLife = 0.35, col = { 1, 0.5, 0.2 } }
            if dist(m.x, m.y, me.x, me.y) < X.METEOR_R + me.r * 0.5 then addShake(10) end
            if not me.dead and dist(m.x, m.y, me.x, me.y) < X.METEOR_R + me.r * 0.5 and (me.dashTime or 0) <= 0 then
                local saved = player
                player = me
                damagePlayer(X.METEOR_DMG, m.x, m.y, "meteorfall")
                player = saved
            end
        end
    end
end

function X.updateEvents(dt)
    if X.EV then
        X.EV.t = X.EV.t - dt
        if X.EV.k == "meteors" then updateMeteors(dt) end
        if X.EV.k == "merchant" and overlay == "merchant" then
            local mx, my = X.merchantSpot()
            if dist(me.x, me.y, mx, my) > 160 then overlay = nil love.mouse.setVisible(false) end
        end
        if X.EV.t <= 0 then
            if X.EV.k == "merchant" then
                addMessage("The travelling merchant packed up and left.", { 1, 0.85, 0.45 })
                if overlay == "merchant" then overlay = nil love.mouse.setVisible(false) end
            end
            X.EV = nil
        end
    elseif #X.skyRocks > 0 then
        updateMeteors(dt)
    end
    if MPS.role == "client" then return end
    if X.EV or X.BF or X.cut or endTimer or admin.on and admin.noEvents then return end
    X.evT = X.evT - dt
    if X.evT <= 0 then
        X.evT = randRange(160, 260)
        X.hostEvent()
    end
end

function X.nearMerchant()
    if not X.EV or X.EV.k ~= "merchant" or me.dead then return false end
    local mx, my = X.merchantSpot()
    return dist(me.x, me.y, mx, my) < 110
end

function X.buyMerchant(i)
    local it = (X.merchantStock or X.MERCHANT_ITEMS)[i]
    if not it or not X.nearMerchant() then return end
    if it.id == "potion" and X.potionBought then playSfx("deny") return end
    if me.gold < it.price then playSfx("deny") addMessage("Not enough gold.", { 1, 0.5, 0.4 }) return end
    if X.ENDLESS_STOCK_BY[it.id] then
        -- Endless stock
        if not X.applyStock(it.id) then playSfx("deny") return end
        me.gold = me.gold - it.price
        stats.goldSpent = stats.goldSpent + it.price
        playSfx("buy")
        addMessage("Bought: " .. it.name .. " (" .. it.desc .. ")", { 1, 0.85, 0.45 })
        return
    end
    me.gold = me.gold - it.price
    stats.goldSpent = stats.goldSpent + it.price
    playSfx("buy")
    if it.id == "ammo" then
        me.ammo = me.ammo + 60
    elseif it.id == "bandage" then
        me.bandages = me.bandages + 3
    else
        X.potionBought = true
        me.maxHp = me.maxHp + 25
        me.hp = min(me.maxHp, me.hp + 25)
        playSfx("heal")
        addText(me.x, me.y - 40, "+25 MAX HP", { 0.5, 1, 0.6 }, true)
    end
    addMessage("Bought: " .. it.name .. " (" .. it.desc .. ")", { 1, 0.85, 0.45 })
end
end

------------------------------------------------------------------------------
-- LOADOUT, HOTBAR, UTILITIES, ARMOR & SHIELD, THE SHED CHEST, ENDLESS MERCHANT
------------------------------------------------------------------------------
do
local UT, AR = X.UT, X.AR
X.UTIL, X.ARMOR = UT.UTILITY, AR.ARMOR
X.thrown, X.smokes, X.traps, X.turrets, X.decoys = {}, {}, {}, {}, {}
X.hb = { mode = "gun", gsel = 1, usel = 1 }
X.FIRE_KINDS = { eflame = true, fireburn = true, lava = true, rod = true }

local function indexOf(list, id)
    for i, v in ipairs(list) do if v == id then return i end end
    return 0
end
X.indexOf = indexOf

-- can this weapon go into a loadout? (the Pistol, or a permanent credit weapon you own)
function X.loadoutWeaponOK(id)
    local w = WEAPONS[id]
    return w ~= nil and (id == "pistol" or (w.shop ~= nil and PROF.owns(id)))
end

-- the saved LOADOUT (profile keys lw1-4 / lu1-4 / la = indices into the order lists, 0 = empty)
function X.loadout()
    local d = PROF.data
    local L = { w = {}, u = {} }
    for i = 1, 4 do
        local wid = X.WEAPON_ORDER[d["lw" .. i] or 0]
        L.w[i] = (wid and X.loadoutWeaponOK(wid)) and wid or false
        local uid = UT.UTILITY_ORDER[d["lu" .. i] or 0]
        L.u[i] = (uid and PROF.owns(uid)) and uid or false
    end
    L.a = {}
    for _, sl in ipairs({ "head", "chest", "legs" }) do
        local aid = AR.ARMOR_ORDER[d["la" .. sl:sub(1, 1)] or 0]
        L.a[sl] = (aid and PROF.owns(aid) and X.ARMOR[aid].slot == sl) and aid or nil
    end
    return L
end

function X.setLoadout(kind, i, id)
    local d = PROF.data
    if kind == "a" then
        -- i = the slot name ("head", "chest", "legs")
        d["la" .. tostring(i):sub(1, 1)] = id and indexOf(AR.ARMOR_ORDER, id) or 0
    else
        local list = kind == "w" and X.WEAPON_ORDER or UT.UTILITY_ORDER
        -- an item can only be in one slot
        if id then
            for k = 1, 4 do if d["l" .. kind .. k] == indexOf(list, id) then d["l" .. kind .. k] = 0 end end
        end
        d["l" .. kind .. i] = id and indexOf(list, id) or 0
    end
    PROF.save()
end

-- a new run: weapons, utilities (with their uses) and armor from the loadout
function X.initKit(p)
    local L = X.loadout()
    p.slots = { L.w[1], L.w[2], L.w[3], L.w[4] }
    p.uslots = { L.u[1], L.u[2], L.u[3], L.u[4] }
    p.uses, p.ucd = {}, {}
    for _, id in ipairs(p.uslots) do if id then p.uses[id] = X.UTIL[id].uses end end
    p.armorSet = { head = L.a.head, chest = L.a.chest, legs = L.a.legs, feet = nil }
    X.recalcArmor(p)
    p.shield = p.maxShield
    p.scraps, p.chest, p.goldPotT, p.tonicT = 0, {}, 0, 0
    for _, id in ipairs(p.slots) do if id then p.owned[id] = true end end
    X.thrown, X.smokes, X.traps, X.turrets, X.decoys = {}, {}, {}, {}, {}
    X.hb = { mode = "gun", gsel = 1, usel = 1 }
    for i = 1, 4 do if p.slots[i] then X.hb.gsel = i break end end
    X.selectGun(X.hb.gsel, true)
end

-- the worn pieces add up: shield, speed, fire resistance, stealth and specials
function X.recalcArmor(p)
    local sh, sp, fire, st, cannon = 0, 0, 0, 0, 0
    p.waders, p.headLamp = false, false
    for _, sl in ipairs(AR.SLOTS) do
        local a = p.armorSet[sl] and X.ARMOR[p.armorSet[sl]]
        if a then
            sh, sp = sh + (a.shield or 0), sp + (a.speed or 0)
            fire, st, cannon = fire + (a.fire or 0), st + (a.stealth or 0), cannon + (a.cannonRange or 0)
            if a.waders then p.waders = true end
            if a.lamp then p.headLamp = true end
        end
    end
    p.maxShield, p.armorSpeed, p.armorFire, p.stealth, p.cannonBonus = sh, sp, fire, min(0.6, st), cannon
    p.shield = min(p.shield or sh, sh)
    p.armor = sh > 0 or nil           -- "wears shield armor"
end

function X.selectGun(i, silent)
    local p = me
    X.hb.gsel = i
    local id = p.slots and p.slots[i]
    if id then
        p.unarmed = false
        if p.weapon ~= id then
            p.weapon, p.fireCd, p.spin = id, 0.35, 0
            if not silent then playSfx("equip") end
        end
    else
        p.unarmed = true
    end
end

function X.freeGunSlot()
    for i = 1, 4 do if not me.slots[i] then return i end end
end

-- put a weapon bought during the run (Shotgun, Battle Axe) into an empty slot
function X.giveGun(id)
    local i = X.freeGunSlot()
    if not i then return false end
    me.slots[i] = id
    me.owned[id] = true
    if X.hb.mode == "gun" and X.hb.gsel == i then X.selectGun(i) end
    return true
end

-- add uses of a utility (merchant): its slot, or an empty utility slot
function X.giveUtil(id, n)
    local p = me
    for i = 1, 4 do
        if p.uslots[i] == id then p.uses[id] = (p.uses[id] or 0) + n return true end
    end
    for i = 1, 4 do
        if not p.uslots[i] then
            p.uslots[i], p.uses[id] = id, n
            return true
        end
    end
    return false
end

-- you can't switch while one of your shots is still flying
function X.canSwitch()
    for _, b in ipairs(bullets) do
        if b.owner == "player" and not b.turret then return false end
    end
    for _, m in ipairs(X.meteors) do if m.owner == "player" then return false end end
    return #X.thrown == 0
end

local denyT = 0
function X.scrollHotbar(dir)
    if not X.canSwitch() then
        if love.timer.getTime() > denyT then
            denyT = love.timer.getTime() + 0.6
            addText(me.x, me.y - 40, "Wait for your shot to land!", { 1, 0.6, 0.4 })
            playSfx("deny", 0.1)
        end
        return
    end
    if X.hb.mode == "gun" then
        X.selectGun((X.hb.gsel - 1 + dir) % 4 + 1)
    else
        X.hb.usel = (X.hb.usel - 1 + dir) % 4 + 1
        playSfx("hover")
    end
end

function X.toggleHotbar()
    X.hb.mode = X.hb.mode == "gun" and "util" or "gun"
    playSfx("equip")
    if X.hb.mode == "gun" then X.selectGun(X.hb.gsel, true) end
end

------------------------------------------------------------------------------
-- Network: utility effects other machines must see (or the host must run)
------------------------------------------------------------------------------
function X.netUtil(m)
    if not MPS.online then return end
    if MPS.role == "host" then NET.broadcast(m) else NET.toHost(m) end
end

local function addSmoke(x, y)
    local u = X.UTIL.smoke
    X.smokes[#X.smokes + 1] = { x = x, y = y, r = u.radius, t = u.duration, maxT = u.duration }
    playSfx("bat_poof", 0.1, max(0.3, volAt(x, y)))
end

local decoyId = 0
local DUMMY = { dashTime = 0, moving = false, iframes = 0, blocking = false, angle = 0, hp = 100, maxHp = 100,
    lives = 3, out = false, vx = 0, vy = 0, kbx = 0, kby = 0, poisonT = 0, chillT = 0, slowT = 0, weakT = 0,
    fungusT = 0, serpSlowT = 0, quakeT = 0, spookT = 0, blindT = 0, turtleT = 0, stealth = 0, stamina = 0 }
DUMMY.__index = DUMMY
local function addDecoy(x, y, id)
    local u = X.UTIL.decoy
    local d = { id = id, x = x, y = y, hp = u.hp, t = u.duration }
    d.dummy = setmetatable({ x = x, y = y, r = 16, region = regionAt(x, y), decoy = d, dead = false, id = -1 }, DUMMY)
    X.decoys[#X.decoys + 1] = d
    playSfx("equip", 0.1, max(0.3, volAt(x, y)))
    return d
end

local function removeDecoy(id)
    for i = #X.decoys, 1, -1 do
        local d = X.decoys[i]
        if d.id == id then
            spawnParticles(d.x, d.y, 24, { 0.85, 0.75, 0.45 }, 60, 240, 0.7, 3)
            table.remove(X.decoys, i)
        end
    end
end

-- the host creates every decoy (enemies are simulated there)
local function hostDecoy(x, y)
    decoyId = decoyId + 1
    local id = (MPS.id or 1) * 1000 + decoyId
    addDecoy(x, y, id)
    if MPS.role == "host" then NET.broadcast({ t = "ut", k = "decoy", x = floor(x), y = floor(y), id = id }) end
end

function X.hurtDecoy(d, dmg)
    if MPS.role == "client" then return end
    d.hp = d.hp - dmg
    X.wtext(d.x, d.y - 30, "-" .. floor(dmg), { 0.9, 0.8, 0.5 })
    if d.hp <= 0 and not d.gone then
        d.gone = true
        removeDecoy(d.id)
        if MPS.role == "host" then NET.broadcast({ t = "ut", k = "decoyx", id = d.id }) end
    end
end

-- an enemy close to a decoy attacks the decoy instead
function X.decoyFor(e)
    for _, d in ipairs(X.decoys) do
        if not d.gone and dist(e.x, e.y, d.x, d.y) < X.UTIL.decoy.radius and d.dummy.region == e.region then return d.dummy end
    end
end

-- enemy shots hit decoys (only the host takes their HP)
function X.decoyHit(b, nx, ny)
    for _, d in ipairs(X.decoys) do
        if segCircle(b.x, b.y, nx, ny, d.x, d.y, 18) then
            X.hurtDecoy(d, max(4, b.dmg or 0))
            return true
        end
    end
    return false
end

function X.smokeBlocks(x1, y1, x2, y2)
    for _, s in ipairs(X.smokes) do
        local r = s.r * min(1, s.t / 0.6, (s.maxT - s.t) / 0.5 + 0.2)
        if dist(x1, y1, s.x, s.y) < r or dist(x2, y2, s.x, s.y) < r or segCircle(x1, y1, x2, y2, s.x, s.y, r) then return true end
    end
    return false
end

-- utility messages ("ut"): from = the client who sent it (host only)
function X.utilNet(m, from)
    local k = m.k
    local x, y = tonumber(m.x) or 0, tonumber(m.y) or 0
    if MPS.role == "host" and from then
        if k == "decoy" then hostDecoy(x, y) return end
        NET.broadcast(m, false, from)
    end
    if k == "boom" then
        X.explode(x, y, "remote", nil, X.UTIL.grenade.radius, "grenade")
    elseif k == "smoke" then
        addSmoke(x, y)
    elseif k == "trap" then
        X.traps[#X.traps + 1] = { id = m.id, x = x, y = y, remote = true }
    elseif k == "trapx" then
        for i = #X.traps, 1, -1 do if X.traps[i].id == m.id then X.traps[i].sprung = 0.5 end end
    elseif k == "turret" then
        X.turrets[#X.turrets + 1] = { x = x, y = y, t = X.UTIL.turret.duration, ang = 0, remote = true }
    elseif k == "decoy" then
        addDecoy(x, y, m.id)
    elseif k == "decoyx" then
        removeDecoy(m.id)
    end
end

------------------------------------------------------------------------------
-- Using a utility (left click while the hotbar shows utilities)
------------------------------------------------------------------------------
local trapId = 0
local function throwTarget(p, range)
    local mx, my = X.mouseWorld()
    local a = atan2(my - p.y, mx - p.x)
    local d = min(range, dist(p.x, p.y, mx, my))
    local tx, ty = p.x + cos(a) * d, p.y + sin(a) * d
    local wt = X.firstWall(p.x, p.y, tx, ty)
    if wt then tx, ty = p.x + (tx - p.x) * wt * 0.92, p.y + (ty - p.y) * wt * 0.92 end
    return tx, ty, a
end

local USE = {}
USE.grenade = function(p, u)
    local tx, ty = throwTarget(p, u.range)
    X.thrown[#X.thrown + 1] = { kind = "grenade", sx = p.x, sy = p.y, x = p.x, y = p.y, tx = tx, ty = ty, t = 0,
        dur = 0.25 + dist(p.x, p.y, tx, ty) / 900 }
    playSfx("potion_throw", 0.1)
end
USE.smoke = function(p, u)
    local tx, ty = throwTarget(p, u.range)
    X.thrown[#X.thrown + 1] = { kind = "smoke", sx = p.x, sy = p.y, x = p.x, y = p.y, tx = tx, ty = ty, t = 0,
        dur = 0.25 + dist(p.x, p.y, tx, ty) / 900 }
    playSfx("potion_throw", 0.1)
end
USE.medkit = function(p, u)
    if p.hp >= p.maxHp then
        playSfx("deny")
        addText(p.x, p.y - 30, "Already at full health", { 0.8, 0.8, 0.8 })
        return false
    end
    local healed = min(u.heal, p.maxHp - p.hp)
    p.hp = p.hp + healed
    playSfx("heal")
    spawnParticles(p.x, p.y, 22, { 0.4, 1, 0.5 }, 30, 140, 0.8, 3)
    addText(p.x, p.y - 30, "+" .. floor(healed) .. " HP", { 0.4, 1, 0.5 }, true)
end
USE.goldpot = function(p, u)
    p.goldPotT = u.duration
    playSfx("coin")
    spawnParticles(p.x, p.y, 26, { 1, 0.85, 0.2 }, 30, 160, 0.9, 3)
    addText(p.x, p.y - 30, "+50% GOLD for 2:00", { 1, 0.85, 0.2 }, true)
end
USE.trap = function(p, u)
    local mine = {}
    for i, t in ipairs(X.traps) do if t.own and not t.sprung then mine[#mine + 1] = i end end
    if #mine >= u.max then
        local old = X.traps[mine[1]]
        old.sprung = 0.01
        X.netUtil({ t = "ut", k = "trapx", id = old.id })
    end
    trapId = trapId + 1
    local id = (MPS.id or 1) * 1000 + trapId
    X.traps[#X.traps + 1] = { id = id, x = p.x, y = p.y + 6, own = true, armT = 0.6 }
    X.netUtil({ t = "ut", k = "trap", x = floor(p.x), y = floor(p.y + 6), id = id })
    playSfx("lock", 0.1)
end
USE.decoy = function(p, u)
    local x, y = p.x + cos(p.angle) * 40, p.y + sin(p.angle) * 40
    if not areaFree(x - 14, y - 14, 28, 28, 0) then x, y = p.x, p.y end
    if MPS.role == "client" then
        NET.toHost({ t = "ut", k = "decoy", x = floor(x), y = floor(y) })
    else
        hostDecoy(x, y)
    end
end
USE.turret = function(p, u)
    local x, y = p.x + cos(p.angle) * 34, p.y + sin(p.angle) * 34
    if not areaFree(x - 14, y - 14, 28, 28, 0) then x, y = p.x, p.y end
    X.turrets[#X.turrets + 1] = { x = x, y = y, t = u.duration, cd = 0.4, ang = p.angle, own = true }
    X.netUtil({ t = "ut", k = "turret", x = floor(x), y = floor(y) })
    playSfx("equip")
end
USE.recall = function(p, u)
    if X.BF and not X.BF.done then
        playSfx("deny")
        addText(p.x, p.y - 30, "The arena is sealed - no recall!", { 1, 0.5, 0.4 })
        return false
    end
    p.recallT = u.channel
    playSfx("cast")
end

function X.useUtility(id)
    local p = me
    if p.dead or endTimer then return end
    if not id then
        playSfx("deny")
        addText(p.x, p.y - 30, "Empty slot", { 0.8, 0.8, 0.8 })
        return
    end
    local u = X.UTIL[id]
    if (p.uses[id] or 0) <= 0 then
        playSfx("deny")
        addText(p.x, p.y - 30, u.name .. ": no uses left this run", { 1, 0.5, 0.4 })
        return
    end
    if (p.ucd[id] or 0) > 0 then
        playSfx("deny")
        addText(p.x, p.y - 30, u.name .. " recharging " .. math.ceil(p.ucd[id]) .. "s", { 0.6, 0.7, 1 })
        return
    end
    if USE[id](p, u) == false then return end
    p.uses[id] = p.uses[id] - 1
    p.ucd[id] = u.cooldown
    stats.utilitiesUsed = (stats.utilitiesUsed or 0) + 1
end

------------------------------------------------------------------------------
-- Every frame
------------------------------------------------------------------------------
function X.updateKit(dt)
    local p = me
    if not p.ucd then return end
    for id, v in pairs(p.ucd) do p.ucd[id] = max(0, v - dt) end
    p.goldPotT = max(0, (p.goldPotT or 0) - dt)
    p.tonicT = max(0, (p.tonicT or 0) - dt)
    -- Recall Scroll: channel, then back to the shed
    if p.recallT then
        if p.dead then p.recallT = nil
        else
            p.recallT = p.recallT - dt
            if rand() < 0.6 then spawnParticles(p.x, p.y, 1, { 0.55, 0.45, 1 }, 20, 90, 0.6, 3) end
            if p.recallT <= 0 then
                p.recallT = nil
                spawnParticles(p.x, p.y, 30, { 0.55, 0.45, 1 }, 60, 260, 0.7, 3)
                p.x, p.y = X.shedSpot(MPS.id)
                p.kbx, p.kby, p.vx, p.vy = 0, 0, 0, 0
                cam.x, cam.y = p.x, p.y
                playSfx("respawn")
                addMessage("Recall Scroll: back at the shed.", { 0.7, 0.6, 1 })
            end
        end
    end
    -- thrown grenades and smoke bombs
    for i = #X.thrown, 1, -1 do
        local g = X.thrown[i]
        g.t = g.t + dt
        local k = min(1, g.t / g.dur)
        g.x, g.y = g.sx + (g.tx - g.sx) * k, g.sy + (g.ty - g.sy) * k
        g.h = sin(pi * k) * 60
        if k >= 1 then
            table.remove(X.thrown, i)
            if g.kind == "grenade" then
                local u = X.UTIL.grenade
                X.explode(g.tx, g.ty, "player", { hit = false, dmg = u.dmg, fx = "x" }, u.radius, "grenade")
                X.netUtil({ t = "ut", k = "boom", x = floor(g.tx), y = floor(g.ty) })
            else
                addSmoke(g.tx, g.ty)
                X.netUtil({ t = "ut", k = "smoke", x = floor(g.tx), y = floor(g.ty) })
            end
        end
    end
    for i = #X.smokes, 1, -1 do
        local s = X.smokes[i]
        s.t = s.t - dt
        if rand() < 0.5 then
            local a, d = rand() * 2 * pi, rand() * s.r * 0.8
            spawnParticles(s.x + cos(a) * d, s.y + sin(a) * d, 1, { 0.6, 0.62, 0.65 }, 5, 25, 1.2, 10, nil, nil, 2)
        end
        if s.t <= 0 then table.remove(X.smokes, i) end
    end
    -- bear traps: only the owner's machine checks them
    for i = #X.traps, 1, -1 do
        local t = X.traps[i]
        if t.sprung then
            t.sprung = t.sprung - dt
            if t.sprung <= 0 then table.remove(X.traps, i) end
        elseif t.own then
            t.armT = max(0, (t.armT or 0) - dt)
            if t.armT <= 0 then
                for _, e in ipairs(enemies) do
                    if not e.dead and e.hidden <= 0 and not X.BOSSES[e.kind] and dist(e.x, e.y, t.x, t.y) < e.r + 16 then
                        local u = X.UTIL.trap
                        X.hitEnemy(e, u.dmg, 0, false, false, "t")
                        X.wtext(e.x, e.y - 34, "TRAPPED!", { 1, 0.8, 0.4 }, true)
                        X.wsfx("croc_snap", t.x, t.y, 0.1)
                        t.sprung = 0.6
                        X.netUtil({ t = "ut", k = "trapx", id = t.id })
                        break
                    end
                end
            end
        end
    end
    -- sentry turrets: the owner's machine shoots (other players see the shots)
    for i = #X.turrets, 1, -1 do
        local tr = X.turrets[i]
        tr.t = tr.t - dt
        local best, bd
        for _, e in ipairs(enemies) do
            if not e.dead and e.hidden <= 0 then
                local d = dist(tr.x, tr.y, e.x, e.y)
                if d < X.UTIL.turret.range and (not bd or d < bd) and hasLOS(tr.x, tr.y, e.x, e.y) then best, bd = e, d end
            end
        end
        if best then tr.ang = turnTowards(tr.ang, atan2(best.y - tr.y, best.x - tr.x), 10 * dt) end
        if tr.own then
            tr.cd = tr.cd - dt
            if best and tr.cd <= 0 then
                tr.cd = X.UTIL.turret.rate
                local a = atan2(best.y - tr.y, best.x - tr.x)
                local n0 = #bullets
                X.fireWeapon("pistol", tr.x, tr.y, a, false, "player", { hit = false, dmg = X.UTIL.turret.dmg, crit = false })
                for k = n0 + 1, #bullets do bullets[k].turret = true end
                if MPS.online then X.netShot("pistol", tr.x, tr.y, a, false, 0) end
                X.wsfx("pistol", tr.x, tr.y, 0.2, 0.5)
                spawnParticles(tr.x + cos(a) * 24, tr.y + sin(a) * 24, 3, { 1, 0.85, 0.4 }, 60, 160, 0.12, 2.5, a, 0.5)
            end
        end
        if tr.t <= 0 then
            spawnParticles(tr.x, tr.y, 16, { 0.6, 0.6, 0.65 }, 40, 180, 0.6, 3)
            table.remove(X.turrets, i)
        end
    end
    -- decoys
    for i = #X.decoys, 1, -1 do
        local d = X.decoys[i]
        d.t = d.t - dt
        if d.t <= 0 then
            spawnParticles(d.x, d.y, 20, { 0.85, 0.75, 0.45 }, 60, 220, 0.6, 3)
            table.remove(X.decoys, i)
        end
    end
end

------------------------------------------------------------------------------
-- Armor: repairing the shield with Metal Scraps (hold the armor in the inventory)
------------------------------------------------------------------------------
function X.repairShield()
    local p = me
    if (p.maxShield or 0) <= 0 then return false end
    if p.shield >= p.maxShield then addText(p.x, p.y - 30, "Shield is already full", { 0.6, 0.8, 1 }) return false end
    if (p.scraps or 0) <= 0 then addText(p.x, p.y - 30, "No Metal Scraps", { 1, 0.5, 0.4 }) playSfx("deny") return false end
    p.scraps = p.scraps - 1
    p.shield = min(p.maxShield, p.shield + AR.SCRAP_REPAIR)
    playSfx("hammer", 0.1, 0.6)
    addText(p.x, p.y - 30, "+" .. AR.SCRAP_REPAIR .. " SHIELD", { 0.45, 0.7, 1 }, true)
    return true
end

------------------------------------------------------------------------------
-- The chest in the shed: 10 slots, it keeps weapons for the whole run
------------------------------------------------------------------------------
X.CHEST_SLOTS = 10
function X.chestSpot()
    local S = X.SHED
    return S.x + S.w - 40, S.y + 44
end
function X.nearChest()
    if me.dead then return false end
    local cx, cy = X.chestSpot()
    return dist(me.x, me.y, cx, cy) < 70
end
function X.storeGun(i)
    local p = me
    local id = p.slots[i]
    if not id then return end
    if #p.chest >= X.CHEST_SLOTS then playSfx("deny") addMessage("The chest is full (10 slots).", { 1, 0.5, 0.4 }) return end
    p.chest[#p.chest + 1] = id
    p.slots[i] = false
    playSfx("equip")
    if X.hb.gsel == i then X.selectGun(i, true) end
end
function X.takeGun(k)
    local p = me
    local id = p.chest[k]
    if not id then return end
    local i = X.freeGunSlot()
    if not i then playSfx("deny") addMessage("No free weapon slot - store a weapon in the chest first.", { 1, 0.5, 0.4 }) return end
    table.remove(p.chest, k)
    p.slots[i] = id
    playSfx("equip")
    if X.hb.gsel == i then X.selectGun(i, true) end
end

------------------------------------------------------------------------------
-- ENDLESS merchant: always on day 2, 3 random items out of 6
------------------------------------------------------------------------------
X.ENDLESS_STOCK = {
    { id = "medkit",  name = "Medkit",          desc = "+1 Medkit use (heals 100 HP)",       price = 60 },
    { id = "axe",     name = "Battle Axe",      desc = "Melee weapon: 50 DMG, 90 px reach",  price = 150 },
    { id = "ammo20",  name = "20 Ammo",         desc = "+20 ammo",                           price = 25 },
    { id = "grenade", name = "Grenade",         desc = "+1 Grenade use (60 DMG blast)",      price = 40 },
    { id = "scraps",  name = "Metal Scraps x2", desc = "Repair your armor's shield",         price = 50 },
    { id = "tonic",   name = "Stamina Tonic",   desc = "Stamina recovers 50% faster (2:00)", price = 45 },
}
X.ENDLESS_STOCK_BY = {}
for _, it in ipairs(X.ENDLESS_STOCK) do X.ENDLESS_STOCK_BY[it.id] = it end

function X.pickStock()
    local ids = {}
    for _, it in ipairs(X.ENDLESS_STOCK) do ids[#ids + 1] = it.id end
    for i = #ids, 2, -1 do local j = randInt(1, i) ids[i], ids[j] = ids[j], ids[i] end
    return ids[1] .. "," .. ids[2] .. "," .. ids[3]
end

function X.setStock(s)
    if not s then X.merchantStock = X.MERCHANT_ITEMS return end
    local list = {}
    for id in tostring(s):gmatch("[^,]+") do
        if X.ENDLESS_STOCK_BY[id] then list[#list + 1] = X.ENDLESS_STOCK_BY[id] end
    end
    X.merchantStock = #list > 0 and list or X.MERCHANT_ITEMS
end

-- returns false when it can't be bought (no free slot)
function X.applyStock(id)
    local p = me
    if id == "medkit" or id == "grenade" then
        if not X.giveUtil(id, 1) then addMessage("No free utility slot for that.", { 1, 0.5, 0.4 }) return false end
    elseif id == "axe" then
        if not X.giveGun("axe") then addMessage("No free weapon slot - store one in the shed chest first.", { 1, 0.5, 0.4 }) return false end
    elseif id == "ammo20" then
        p.ammo = p.ammo + 20
    elseif id == "scraps" then
        p.scraps = (p.scraps or 0) + 2
    elseif id == "tonic" then
        p.tonicT = 120
    end
    return true
end
end

function love.update(dt)
    dt = min(dt, 1 / 30)
    menuTime = menuTime + dt
    admin.msgT = max(0, admin.msgT - dt)
    updateWeatherAudio()
    if X.updateScreens then X.updateScreens(dt) end

    -- multiplayer traffic is processed every frame, whatever screen is open
    if MPS.online then X.netUpdate(dt) end

    if gameState == "loading" then
        X.loadFrames = X.loadFrames + 1
        if X.loadFrames >= 2 then X.startGame(X.pendingGame or {}) end
        return
    end

    if gameState ~= "play" then
        for _, d in ipairs(menuDust) do
            d.x = d.x + d.v * dt
            if d.x > 1.05 then d.x = -0.05 d.y = rand() end
        end
        return
    end

    -- Only the ESC menu pauses, and only in single player.
    -- Shop / inventory / guide / spellbook keep the world running.
    if overlay == "pause" and not MPS.online then return end

    stats.time = stats.time + dt
    if admin.on then
        if admin.hp then player.hp = player.maxHp end
        if admin.mp then player.mp = K.MP_MAX player.mpUnlocked = true end
    end
    X.updateLair(dt)
    if X.cut then
        -- cutscene: nobody moves, the camera flies
        X.updateCut(dt)
        if MPS.role == "client" then X.updateProxies(dt) end
        if MPS.online then X.updateRemotePlayers(dt) end
        updateEffects(dt)
        return
    end
    updatePlayer(dt)
    updateSnowgraves(dt)
    X.updateDayNight(dt)
    if MPS.role == "client" then
        X.updateProxies(dt)
    else
        -- each enemy hunts the closest player it can reach (`player` points at that target meanwhile)
        for _, e in ipairs(enemies) do
            if not e.dead then
                local tgt = X.pickTarget(e, dt)
                player = tgt
                updateEnemy(e, dt)
                player = me
            end
        end
        separateEntities()
    end
    if MPS.online then X.updateRemotePlayers(dt) end
    updateBullets(dt)
    X.updateVortices(dt)
    X.updateStronghold(dt)
    if X.BF then X.updateBossFight(dt) end
    X.updateKeyItem(dt)
    X.updateRevive(dt)
    X.updateEvents(dt)
    X.updateKit(dt)
    updateEffects(dt)
    updateSpawning(dt)
    updateWeather(dt)
    updateCamera(dt)

    if endTimer then
        endTimer = endTimer - dt
        if endTimer <= 0 then
            gameState = endResult
            overlay = nil
            love.mouse.setVisible(true)
            if MPS.online then NET.stopAnnounce() NET.close() MPS.online, MPS.inGame = false, false MPS.role = "solo" end
        end
    end
end

------------------------------------------------------------------------------
-- Drawing helpers
------------------------------------------------------------------------------
local PAL = {
    sand     = { 0.66, 0.56, 0.40 },
    gold     = { 0.95, 0.75, 0.35 },
    panel    = { 0.09, 0.07, 0.05 },
    border   = { 0.85, 0.62, 0.32 },
    text     = { 0.96, 0.91, 0.80 },
    dim      = { 0.70, 0.64, 0.55 },
    red      = { 0.88, 0.25, 0.20 },
    green    = { 0.35, 0.85, 0.45 },
    blue     = { 0.40, 0.75, 1.00 },
}

local function setC(c, a) lg.setColor(c[1], c[2], c[3], a or c[4] or 1) end

local function panel(x, y, w, h, alpha)
    lg.setColor(0, 0, 0, 0.35 * (alpha or 1))
    lg.rectangle("fill", x + 4, y + 5, w, h, 10, 10)
    lg.setColor(PAL.panel[1], PAL.panel[2], PAL.panel[3], 0.9 * (alpha or 1))
    lg.rectangle("fill", x, y, w, h, 10, 10)
    lg.setLineWidth(2)
    setC(PAL.border, 0.85 * (alpha or 1))
    lg.rectangle("line", x, y, w, h, 10, 10)
    lg.setLineWidth(1)
end

local function button(label, x, y, w, h, fn, enabled, sub)
    enabled = enabled ~= false
    local mx, my = love.mouse.getPosition()
    local hov = enabled and mx >= x and mx <= x + w and my >= y and my <= y + h
    if hov then lg.setColor(0.85, 0.6, 0.28, 0.95) else lg.setColor(0.2, 0.15, 0.1, enabled and 0.95 or 0.5) end
    lg.rectangle("fill", x, y, w, h, 8, 8)
    setC(PAL.border, enabled and 1 or 0.4)
    lg.setLineWidth(2)
    lg.rectangle("line", x, y, w, h, 8, 8)
    lg.setLineWidth(1)
    lg.setFont(fonts.medium)
    if hov then lg.setColor(0.1, 0.07, 0.04) else setC(PAL.text, enabled and 1 or 0.45) end
    local ty = sub and y + h / 2 - 20 or y + h / 2 - fonts.medium:getHeight() / 2
    lg.printf(label, x, ty, w, "center")
    if sub then
        lg.setFont(fonts.small)
        lg.printf(sub, x, ty + 26, w, "center")
    end
    buttons[#buttons + 1] = { x = x, y = y, w = w, h = h, fn = fn, enabled = enabled, label = label }
    return hov
end

local function bar(x, y, w, h, frac, col, lagFrac, label)
    lg.setColor(0, 0, 0, 0.55)
    lg.rectangle("fill", x - 2, y - 2, w + 4, h + 4, 5, 5)
    lg.setColor(0.18, 0.14, 0.1, 1)
    lg.rectangle("fill", x, y, w, h, 4, 4)
    if lagFrac and lagFrac > frac then
        lg.setColor(1, 0.9, 0.6, 0.8)
        lg.rectangle("fill", x, y, w * clamp(lagFrac, 0, 1), h, 4, 4)
    end
    setC(col)
    lg.rectangle("fill", x, y, w * clamp(frac, 0, 1), h, 4, 4)
    lg.setColor(1, 1, 1, 0.15)
    lg.rectangle("fill", x, y, w * clamp(frac, 0, 1), h * 0.4, 4, 4)
    if label then
        lg.setFont(fonts.small)
        lg.setColor(0, 0, 0, 0.7)
        lg.printf(label, x + 1, y + h / 2 - 7, w, "center")
        lg.setColor(1, 1, 1)
        lg.printf(label, x, y + h / 2 - 8, w, "center")
    end
end

local function shadowText(text, x, y, w, align, col, font)
    if font then lg.setFont(font) end
    lg.setColor(0, 0, 0, 0.7)
    lg.printf(text, x + 2, y + 2, w, align)
    setC(col or PAL.text)
    lg.printf(text, x, y, w, align)
end

------------------------------------------------------------------------------
-- Weapon art (all procedural): side-view icons for menus, top-down guns in hand
------------------------------------------------------------------------------
do
local function c(r, g, b, a) lg.setColor(r, g, b, a or X.iconAlpha or 1) end

local ICONS = {}
-- every icon is drawn in a ~120 x 50 box centred on (0, 0)
ICONS.pistol = function()
    c(0.2, 0.2, 0.23) lg.rectangle("fill", -34, -12, 66, 16, 3, 3)
    c(0.32, 0.32, 0.36) lg.rectangle("fill", -34, -12, 66, 5, 3, 3)
    c(0.42, 0.27, 0.15) lg.polygon("fill", -30, 4, -12, 4, -16, 28, -34, 28)
    c(0.15, 0.15, 0.17) lg.rectangle("fill", -10, 4, 10, 10, 2, 2)
    c(0.1, 0.1, 0.1) lg.rectangle("fill", 28, -9, 6, 6)
end
ICONS.shotgun = function()
    c(0.18, 0.18, 0.2) lg.rectangle("fill", -20, -12, 78, 8, 2, 2)
    c(0.22, 0.22, 0.25) lg.rectangle("fill", -20, -4, 70, 7, 2, 2)
    c(0.45, 0.28, 0.14) lg.rectangle("fill", -2, 3, 30, 8, 3, 3)
    c(0.5, 0.31, 0.16) lg.polygon("fill", -20, -12, -20, 6, -58, 18, -60, 4)
    c(0.36, 0.22, 0.11) lg.polygon("fill", -24, 2, -14, 2, -16, 18, -26, 18)
end
ICONS.revolver = function()
    c(0.72, 0.74, 0.78) lg.rectangle("fill", -6, -11, 46, 9, 2, 2)
    c(0.58, 0.6, 0.64) lg.circle("fill", -10, -4, 13)
    c(0.4, 0.42, 0.46)
    for k = 0, 5 do lg.circle("fill", -10 + cos(k * 1.047) * 7, -4 + sin(k * 1.047) * 7, 2.6) end
    c(0.62, 0.64, 0.68) lg.rectangle("fill", -30, -14, 22, 10, 3, 3)
    c(0.48, 0.3, 0.15) lg.polygon("fill", -30, -4, -18, -4, -22, 26, -38, 24)
    c(0.2, 0.2, 0.22) lg.circle("line", -16, 8, 5)
end
ICONS.swifter = function()
    c(0.92, 0.95, 0.98) lg.polygon("fill", -30, -12, 36, -12, 40, -4, 36, 2, -30, 2)
    c(0.2, 0.75, 0.75) lg.rectangle("fill", -30, -6, 70, 3)
    c(0.15, 0.55, 0.6) lg.polygon("fill", -28, 2, -12, 2, -16, 26, -32, 24)
    c(1, 1, 1, 0.9 * (X.iconAlpha or 1))
    lg.polygon("fill", 6, -18, 22, -30, 18, -18)
    lg.polygon("fill", 0, -18, 12, -34, 12, -18)
end
ICONS.spray = function()
    c(0.3, 0.62, 0.3) lg.rectangle("fill", -40, -14, 44, 26, 8, 8)
    c(0.38, 0.75, 0.38) lg.rectangle("fill", -36, -12, 36, 8, 5, 5)
    c(0.2, 0.2, 0.22) lg.rectangle("fill", 4, -6, 26, 10, 2, 2)
    c(0.85, 0.85, 0.3) lg.polygon("fill", 30, -10, 44, -16, 44, 14, 30, 8)
    c(0.25, 0.25, 0.28) lg.polygon("fill", -14, 12, -2, 12, -6, 30, -18, 28)
    c(0.9, 0.9, 0.4, 0.5 * (X.iconAlpha or 1))
    for k = 0, 3 do lg.circle("fill", 52 + k * 6, -12 + k * 8, 2.4) end
end
ICONS.rifle = function()
    c(0.14, 0.14, 0.16) lg.rectangle("fill", -26, -10, 86, 11, 2, 2)
    c(0.24, 0.24, 0.27) lg.rectangle("fill", -26, -14, 50, 5, 2, 2)
    c(0.1, 0.1, 0.12) lg.rectangle("fill", 56, -7, 14, 4)
    c(0.18, 0.18, 0.2) lg.polygon("fill", -2, 1, 12, 1, 18, 26, 6, 28)
    c(0.2, 0.2, 0.22) lg.polygon("fill", -22, 1, -12, 1, -14, 20, -24, 20)
    c(0.16, 0.16, 0.18) lg.polygon("fill", -26, -12, -26, 2, -60, 12, -62, -6)
    c(0.4, 0.42, 0.45) lg.rectangle("fill", -10, -20, 20, 6, 2, 2)
end
ICONS.rpg = function()
    c(0.36, 0.42, 0.24) lg.rectangle("fill", -58, -9, 96, 18, 4, 4)
    c(0.44, 0.5, 0.3) lg.rectangle("fill", -58, -9, 96, 5, 4, 4)
    c(0.5, 0.52, 0.48) lg.polygon("fill", 38, -14, 58, -6, 66, 0, 58, 6, 38, 14)
    c(0.75, 0.2, 0.15) lg.polygon("fill", 58, -6, 70, 0, 58, 6)
    c(0.22, 0.24, 0.16) lg.rectangle("fill", -14, 9, 10, 18, 2, 2)
    c(0.22, 0.24, 0.16) lg.rectangle("fill", 8, 9, 8, 14, 2, 2)
    c(0.15, 0.15, 0.15) lg.rectangle("fill", -6, -18, 16, 9, 2, 2)
end
ICONS.missile = function()
    c(0.28, 0.3, 0.34) lg.rectangle("fill", -58, -11, 92, 22, 4, 4)
    c(0.38, 0.4, 0.45) lg.rectangle("fill", -58, -11, 92, 6, 4, 4)
    c(0.85, 0.87, 0.9) lg.rectangle("fill", 30, -7, 26, 14, 2, 2)
    c(0.9, 0.15, 0.15) lg.polygon("fill", 56, -7, 70, 0, 56, 7)
    c(0.3, 0.32, 0.36) lg.polygon("fill", 30, -7, 38, -7, 32, -14) lg.polygon("fill", 30, 7, 38, 7, 32, 14)
    c(0.18, 0.19, 0.22) lg.rectangle("fill", -14, 11, 10, 18, 2, 2)
    c(0.18, 0.19, 0.22) lg.rectangle("fill", 8, 11, 8, 14, 2, 2)
    c(0.12, 0.12, 0.14) lg.rectangle("fill", -10, -22, 22, 11, 2, 2)
    c(1, 0.2, 0.2, (0.6 + 0.4 * sin((menuTime or 0) * 6)) * (X.iconAlpha or 1)) lg.circle("fill", 6, -17, 3)
end
ICONS.laser = function()
    local glow = 0.6 + 0.4 * sin((menuTime or 0) * 6)
    c(0.92, 0.92, 0.96) lg.polygon("fill", -40, -10, 20, -14, 36, -6, 36, 4, 20, 10, -40, 8)
    c(0.55, 0.2, 0.75) lg.rectangle("fill", -30, -4, 54, 4)
    c(1, 0.3, 0.5, glow * (X.iconAlpha or 1))
    for k = 0, 3 do lg.circle("fill", -18 + k * 12, -2, 3.2) end
    c(1, 0.4, 0.6, 0.5 * glow * (X.iconAlpha or 1)) lg.circle("fill", 42, -1, 7)
    c(1, 0.85, 0.95, glow * (X.iconAlpha or 1)) lg.circle("fill", 40, -1, 3.5)
    c(0.4, 0.4, 0.46) lg.polygon("fill", -30, 8, -16, 8, -20, 28, -34, 26)
end

local function ia(a) return (a or 1) * (X.iconAlpha or 1) end
ICONS.uzi = function()
    c(0.16, 0.16, 0.18) lg.rectangle("fill", -26, -12, 52, 14, 2, 2)
    c(0.1, 0.1, 0.12) lg.rectangle("fill", 26, -9, 12, 6)
    c(0.2, 0.2, 0.22) lg.rectangle("fill", -6, 2, 10, 30, 2, 2)
    c(0.24, 0.24, 0.27) lg.polygon("fill", -24, 2, -12, 2, -14, 20, -26, 20)
    c(0.3, 0.3, 0.33) lg.rectangle("fill", -26, -16, 30, 4, 1, 1)
end
ICONS.crossbow = function()
    c(0.45, 0.3, 0.16) lg.rectangle("fill", -50, -4, 90, 9, 2, 2)
    c(0.32, 0.22, 0.12) lg.polygon("fill", -50, -4, -50, 5, -62, 16, -64, 2)
    c(0.25, 0.25, 0.28) lg.setLineWidth(5) lg.arc("line", "open", 10, 0, 34, -1.9, 1.9) lg.setLineWidth(1)
    c(0.9, 0.9, 0.85) lg.line(10 + cos(1.9) * 34, -sin(1.9) * 34, -18, 0, 10 + cos(1.9) * 34, sin(1.9) * 34)
    c(0.55, 0.38, 0.22) lg.rectangle("fill", -18, -2, 70, 3)
    c(0.8, 0.8, 0.85) lg.polygon("fill", 52, -5, 62, 0, 52, 5)
end
ICONS.flamethrower = function()
    c(0.75, 0.22, 0.15) lg.rectangle("fill", -54, -16, 24, 34, 10, 10)
    c(0.2, 0.2, 0.22) lg.rectangle("fill", -30, -8, 64, 12, 3, 3)
    c(0.35, 0.35, 0.38) lg.rectangle("fill", 34, -10, 10, 16, 2, 2)
    c(0.25, 0.25, 0.28) lg.polygon("fill", -6, 4, 6, 4, 2, 26, -10, 24)
    local fl = 0.7 + 0.3 * sin((menuTime or 0) * 12)
    c(1, 0.55, 0.1, ia(0.9 * fl)) lg.polygon("fill", 44, -8, 64, -14, 70, -2, 62, 10, 44, 6)
    c(1, 0.9, 0.3, ia(fl)) lg.polygon("fill", 44, -4, 56, -6, 58, 2, 44, 3)
end
ICONS.sniper = function()
    c(0.18, 0.2, 0.16) lg.rectangle("fill", -40, -8, 100, 9, 2, 2)
    c(0.12, 0.12, 0.13) lg.rectangle("fill", 60, -6, 14, 5)
    c(0.1, 0.1, 0.12) lg.rectangle("fill", -14, -20, 36, 8, 3, 3)
    c(0.4, 0.7, 0.9) lg.circle("fill", 22, -16, 3)
    c(0.32, 0.36, 0.26) lg.polygon("fill", -40, -10, -40, 4, -68, 14, -70, -4)
    c(0.22, 0.24, 0.2) lg.polygon("fill", -18, 1, -8, 1, -12, 20, -22, 20)
    c(0.25, 0.25, 0.27) lg.line(40, 1, 34, 22) lg.line(40, 1, 46, 22)
end
ICONS.minigun = function()
    c(0.3, 0.3, 0.33) lg.rectangle("fill", -50, -16, 40, 32, 6, 6)
    c(0.18, 0.18, 0.2)
    for k = -2, 2 do lg.rectangle("fill", -10, k * 5 - 2, 66, 4, 1, 1) end
    c(0.4, 0.4, 0.44) lg.rectangle("fill", 20, -14, 6, 28, 2, 2) lg.rectangle("fill", 50, -14, 6, 28, 2, 2)
    c(0.7, 0.55, 0.2) lg.rectangle("fill", -44, 16, 12, 14, 2, 2)
    c(0.22, 0.22, 0.24) lg.rectangle("fill", -36, -24, 18, 8, 2, 2)
end
ICONS.bubble = function()
    c(0.95, 0.5, 0.75) lg.rectangle("fill", -36, -12, 58, 20, 8, 8)
    c(0.45, 0.85, 0.95) lg.rectangle("fill", 18, -8, 20, 12, 4, 4)
    c(0.95, 0.85, 0.3) lg.circle("fill", -14, -14, 9)
    c(0.7, 0.35, 0.6) lg.polygon("fill", -26, 8, -12, 8, -16, 28, -30, 26)
    c(0.7, 0.9, 1, ia(0.6)) lg.circle("line", 50, -10, 7) lg.circle("line", 60, 6, 5) lg.circle("line", 48, 12, 3.5)
end
ICONS.boomerang = function()
    c(0.75, 0.8, 0.86) lg.polygon("fill", -50, 10, -40, -2, 0, -24, 40, -2, 50, 10, 34, 8, 0, -10, -34, 8)
    c(0.5, 0.32, 0.18) lg.rectangle("fill", -8, -20, 16, 12, 3, 3)
    c(0.95, 0.97, 1) lg.line(-40, -2, 0, -24, 40, -2)
end
ICONS.hammer = function()
    c(0.42, 0.28, 0.16) lg.rectangle("fill", -58, -4, 80, 9, 3, 3)
    c(0.35, 0.3, 0.45) lg.rectangle("fill", 22, -24, 36, 48, 6, 6)
    c(0.5, 0.42, 0.65) lg.rectangle("fill", 22, -24, 36, 10, 6, 6)
    local g = 0.6 + 0.4 * sin((menuTime or 0) * 5)
    c(0.75, 0.55, 1, ia(g)) lg.circle("fill", 40, 0, 8)
    c(0.25, 0.2, 0.3) lg.rectangle("fill", -60, -6, 10, 13, 2, 2)
end
ICONS.void = function()
    c(0.2, 0.12, 0.28) lg.polygon("fill", -32, -12, 26, -12, 36, -4, 26, 4, -32, 4)
    c(0.5, 0.25, 0.75) lg.rectangle("fill", -26, -7, 50, 3)
    c(0.28, 0.16, 0.38) lg.polygon("fill", -28, 4, -14, 4, -18, 28, -32, 26)
    c(0.05, 0, 0.08) lg.circle("fill", 44, -4, 8)
    c(0.6, 0.3, 0.9, ia(0.8)) lg.circle("line", 44, -4, 10)
end
ICONS.plasma = function()
    c(0.85, 0.88, 0.9) lg.polygon("fill", -50, -10, 30, -12, 48, -4, 48, 4, 30, 8, -50, 8)
    c(0.25, 0.85, 0.45) lg.rectangle("fill", -36, -3, 66, 4)
    local g = 0.6 + 0.4 * sin((menuTime or 0) * 7)
    c(0.4, 1, 0.6, ia(g)) lg.circle("fill", 0, -1, 7)
    c(0.5, 0.52, 0.56) lg.polygon("fill", -24, 8, -10, 8, -14, 28, -28, 26)
    c(0.5, 0.52, 0.56) lg.polygon("fill", -50, -10, -50, 6, -66, 12, -66, -6)
end
ICONS.tesla = function()
    c(0.55, 0.38, 0.22) lg.rectangle("fill", -44, -8, 54, 16, 4, 4)
    c(0.7, 0.5, 0.25)
    for k = 0, 3 do lg.circle("line", 14 + k * 6, 0, 9 - k) end
    c(0.85, 0.65, 0.3) lg.rectangle("fill", 10, -2, 30, 4)
    c(0.6, 0.85, 1, ia(0.8 + 0.2 * sin((menuTime or 0) * 20)))
    lg.line(42, 0, 50, -10, 56, 4, 64, -6)
    c(0.4, 0.28, 0.16) lg.polygon("fill", -34, 8, -22, 8, -26, 28, -38, 26)
end
ICONS.ghostbow = function()
    c(0.75, 0.92, 1, ia(0.85)) lg.setLineWidth(5) lg.arc("line", "open", -6, 0, 30, -1.5, 1.5) lg.setLineWidth(1)
    c(1, 1, 1, ia(0.8)) lg.line(-6 + cos(1.5) * 30, -30, -6 + cos(1.5) * 30, 30)
    c(0.6, 0.85, 1, ia(0.7)) lg.rectangle("fill", -6, -2, 60, 3)
    c(0.9, 1, 1, ia(0.9)) lg.polygon("fill", 54, -5, 64, 0, 54, 5)
    c(0.6, 0.85, 1, ia(0.25)) lg.circle("fill", 10, 0, 30)
end
ICONS.blackhole = function()
    c(0.25, 0.25, 0.3) lg.rectangle("fill", -54, -12, 90, 24, 6, 6)
    c(0.4, 0.2, 0.6) lg.rectangle("fill", -54, -12, 90, 6, 6, 6)
    c(0.3, 0.3, 0.35) lg.rectangle("fill", 36, -16, 14, 32, 4, 4)
    c(0.03, 0, 0.06) lg.circle("fill", 43, 0, 8)
    c(0.6, 0.3, 1, ia(0.7)) lg.circle("line", 43, 0, 11)
    c(0.2, 0.2, 0.24) lg.rectangle("fill", -14, 12, 10, 16, 2, 2)
end
ICONS.meteor = function()
    c(0.35, 0.25, 0.4) lg.rectangle("fill", -6, -6, 14, 46, 3, 3)
    c(0.55, 0.4, 0.2) lg.circle("fill", 1, -14, 14)
    c(1, 0.55, 0.15, ia(0.7 + 0.3 * sin((menuTime or 0) * 6))) lg.circle("fill", 1, -14, 9)
    c(1, 0.85, 0.4) lg.circle("fill", -2, -17, 3.5)
    c(1, 0.5, 0.15, ia(0.6)) lg.polygon("fill", 14, -24, 42, -40, 20, -10)
end
ICONS.freezer = function()
    c(0.75, 0.88, 0.96) lg.rectangle("fill", -40, -12, 66, 18, 5, 5)
    c(0.45, 0.7, 0.9) lg.rectangle("fill", -36, -8, 56, 4)
    c(0.6, 0.85, 1) lg.polygon("fill", 26, -12, 40, -16, 40, 10, 26, 6)
    c(0.4, 0.55, 0.7) lg.polygon("fill", -24, 6, -10, 6, -14, 28, -28, 26)
    c(0.9, 0.97, 1) lg.circle("fill", -30, -16, 6)
end
ICONS.huntsman = function()
    c(0.48, 0.3, 0.15) lg.polygon("fill", -30, -8, -30, 6, -66, 14, -68, -2)
    c(0.2, 0.2, 0.22) lg.rectangle("fill", -30, -8, 96, 8, 2, 2)
    c(0.5, 0.32, 0.16) lg.rectangle("fill", -30, -2, 60, 9, 3, 3)
    c(0.15, 0.15, 0.17) lg.rectangle("fill", -8, -16, 28, 7, 3, 3)
    c(0.3, 0.3, 0.33) lg.circle("line", -10, 10, 5)
end
ICONS.cannon = function()
    c(0.42, 0.28, 0.15) lg.rectangle("fill", -44, 6, 60, 12, 3, 3)
    c(0.25, 0.18, 0.1) lg.circle("fill", -30, 20, 12) lg.circle("fill", 4, 20, 12)
    c(0.5, 0.35, 0.2) lg.circle("fill", -30, 20, 5) lg.circle("fill", 4, 20, 5)
    c(0.18, 0.18, 0.2) lg.polygon("fill", -50, -14, 50, -10, 50, 8, -50, 10)
    c(0.28, 0.28, 0.3) lg.rectangle("fill", 44, -14, 10, 26, 3, 3)
    c(0.05, 0.05, 0.06) lg.circle("fill", 54, -1, 5)
end
ICONS.golden = function()
    c(0.95, 0.75, 0.2) lg.rectangle("fill", -10, -12, 54, 11, 2, 2)
    c(1, 0.88, 0.4) lg.rectangle("fill", -10, -12, 54, 4, 2, 2)
    c(0.85, 0.65, 0.15) lg.circle("fill", -14, -4, 13)
    c(0.7, 0.5, 0.1)
    for k = 0, 5 do lg.circle("fill", -14 + cos(k * 1.047) * 7, -4 + sin(k * 1.047) * 7, 2.6) end
    c(0.4, 0.25, 0.12) lg.polygon("fill", -32, -4, -20, -4, -24, 26, -40, 24)
    c(1, 1, 0.8, ia(0.6 + 0.4 * sin((menuTime or 0) * 4))) lg.circle("fill", 30, -18, 3)
end

-- top-down colours of the new guns: { body, accent }
local TOP = {
    uzi = { { 0.16, 0.16, 0.18 }, { 0.3, 0.3, 0.33 } }, crossbow = { { 0.45, 0.3, 0.16 }, { 0.25, 0.25, 0.28 } },
    flamethrower = { { 0.2, 0.2, 0.22 }, { 0.75, 0.22, 0.15 } }, sniper = { { 0.18, 0.2, 0.16 }, { 0.1, 0.1, 0.12 } },
    minigun = { { 0.3, 0.3, 0.33 }, { 0.18, 0.18, 0.2 } }, bubble = { { 0.95, 0.5, 0.75 }, { 0.45, 0.85, 0.95 } },
    boomerang = { { 0.75, 0.8, 0.86 }, { 0.5, 0.32, 0.18 } }, hammer = { { 0.42, 0.28, 0.16 }, { 0.5, 0.42, 0.65 } },
    void = { { 0.2, 0.12, 0.28 }, { 0.55, 0.25, 0.8 } }, plasma = { { 0.85, 0.88, 0.9 }, { 0.3, 0.95, 0.5 } },
    tesla = { { 0.55, 0.38, 0.22 }, { 0.6, 0.85, 1 } }, ghostbow = { { 0.75, 0.92, 1 }, { 1, 1, 1 } },
    blackhole = { { 0.25, 0.25, 0.3 }, { 0.5, 0.25, 0.75 } }, meteor = { { 0.35, 0.25, 0.4 }, { 1, 0.55, 0.15 } },
    freezer = { { 0.75, 0.88, 0.96 }, { 0.45, 0.7, 0.9 } }, huntsman = { { 0.2, 0.2, 0.22 }, { 0.5, 0.32, 0.16 } },
    cannon = { { 0.18, 0.18, 0.2 }, { 0.42, 0.28, 0.15 } }, golden = { { 0.95, 0.75, 0.2 }, { 1, 0.9, 0.45 } },
    missile = { { 0.28, 0.3, 0.34 }, { 0.85, 0.87, 0.9 } },
}
function X.drawGunTopNew(id, r, len)
    local t = TOP[id]
    if not t then return false end
    local x0 = r * 0.3
    local wide = (id == "minigun" or id == "cannon" or id == "blackhole" or id == "flamethrower" or id == "missile") and 0.5 or 0.32
    lg.setColor(t[1]) lg.rectangle("fill", x0, r * (0.31 - wide / 2), len, r * wide, 2, 2)
    lg.setColor(t[2]) lg.rectangle("fill", x0 + len * 0.6, r * (0.31 - wide / 4), len * 0.4, r * wide / 2)
    if id == "hammer" then
        lg.setColor(t[2]) lg.rectangle("fill", x0 + len - 4, r * 0.31 - 10, 12, 20, 3, 3)
    elseif id == "crossbow" or id == "ghostbow" then
        lg.setColor(t[2]) lg.setLineWidth(2) lg.arc("line", "open", x0 + len * 0.7, r * 0.31, 10, -1.6, 1.6) lg.setLineWidth(1)
    elseif id == "boomerang" then
        lg.setColor(t[1]) lg.polygon("fill", x0 + len - 6, r * 0.31 - 8, x0 + len + 6, r * 0.31, x0 + len - 6, r * 0.31 + 8)
    elseif id == "missile" then
        lg.setColor(0.9, 0.15, 0.15) lg.polygon("fill", x0 + len, r * 0.31 - 5, x0 + len + 7, r * 0.31, x0 + len, r * 0.31 + 5)
    end
    return true
end

-- Side-view icon of a weapon centred on (cx, cy); scale 1 is about 120 px wide
-- the merchant's Battle Axe
ICONS.axe = function()
    c(0.45, 0.3, 0.16) lg.rectangle("fill", -56, -4, 92, 9, 3, 3)
    c(0.3, 0.2, 0.1) lg.rectangle("fill", -58, -5, 12, 11, 2, 2)
    c(0.62, 0.64, 0.68) lg.polygon("fill", 22, -6, 40, -30, 54, -26, 48, 0, 54, 26, 40, 30, 22, 6)
    c(0.82, 0.84, 0.88) lg.polygon("fill", 48, 0, 54, -26, 58, -14, 58, 14, 54, 26)
end
-- UTILITIES -------------------------------------------------------------------
ICONS.grenade = function()
    c(0.28, 0.36, 0.2) lg.circle("fill", 0, 6, 22)
    c(0.36, 0.46, 0.26) lg.circle("fill", -6, 0, 9)
    c(0.2, 0.26, 0.14) lg.setLineWidth(3) lg.line(-20, 6, 20, 6) lg.line(0, -14, 0, 26) lg.setLineWidth(1)
    c(0.55, 0.55, 0.58) lg.rectangle("fill", -8, -24, 16, 10, 2, 2)
    c(0.75, 0.75, 0.78) lg.setLineWidth(3) lg.arc("line", "open", 14, -20, 10, -pi, 0.4) lg.setLineWidth(1)
end
ICONS.medkit = function()
    c(0.92, 0.92, 0.9) lg.rectangle("fill", -30, -20, 60, 44, 6, 6)
    c(0.6, 0.6, 0.6) lg.rectangle("fill", -10, -28, 20, 10, 3, 3)
    c(0.85, 0.15, 0.15) lg.rectangle("fill", -6, -14, 12, 32) lg.rectangle("fill", -16, -4, 32, 12)
end
ICONS.goldpot = function()
    c(0.75, 0.85, 0.95, ia(0.6)) lg.circle("fill", 0, 8, 22)
    c(1, 0.8, 0.15) lg.circle("fill", 0, 12, 17)
    c(1, 0.95, 0.55) lg.circle("fill", -6, 6, 5)
    c(0.75, 0.85, 0.95, ia(0.8)) lg.rectangle("fill", -7, -24, 14, 14)
    c(0.5, 0.32, 0.18) lg.rectangle("fill", -9, -30, 18, 8, 2, 2)
end
ICONS.smoke = function()
    c(0.55, 0.57, 0.6) lg.circle("fill", -14, -8, 14) lg.circle("fill", 10, -14, 16) lg.circle("fill", 20, 4, 12)
    c(0.25, 0.27, 0.3) lg.rectangle("fill", -14, 4, 28, 26, 4, 4)
    c(0.85, 0.7, 0.2) lg.rectangle("fill", -14, 10, 28, 4)
end
ICONS.trap = function()
    c(0.45, 0.45, 0.48) lg.setLineWidth(4) lg.circle("line", 0, 0, 24) lg.setLineWidth(1)
    c(0.7, 0.7, 0.74)
    for i = 0, 7 do
        local a = i * pi / 4
        lg.polygon("fill", cos(a) * 18, sin(a) * 18, cos(a + 0.2) * 26, sin(a + 0.2) * 26, cos(a - 0.2) * 26, sin(a - 0.2) * 26)
    end
    c(0.6, 0.35, 0.15) lg.circle("fill", 0, 0, 7)
end
ICONS.decoy = function()
    c(0.5, 0.35, 0.18) lg.rectangle("fill", -3, -10, 6, 40)
    c(0.5, 0.35, 0.18) lg.rectangle("fill", -26, -4, 52, 6)
    c(0.85, 0.75, 0.45) lg.circle("fill", 0, -16, 11)
    c(0.4, 0.25, 0.12) lg.ellipse("fill", 0, -26, 18, 5) lg.rectangle("fill", -9, -36, 18, 10, 3, 3)
    c(0.7, 0.25, 0.2) lg.rectangle("fill", -12, -4, 24, 18, 3, 3)
end
ICONS.turret = function()
    c(0.3, 0.3, 0.33) lg.polygon("fill", -24, 28, 24, 28, 12, 8, -12, 8)
    c(0.45, 0.47, 0.5) lg.circle("fill", 0, 0, 14)
    c(0.25, 0.25, 0.28) lg.rectangle("fill", 6, -5, 34, 10, 2, 2)
    c(1, 0.3, 0.2) lg.circle("fill", 0, 0, 4)
end
ICONS.recall = function()
    c(0.92, 0.85, 0.65) lg.rectangle("fill", -26, -18, 52, 36, 3, 3)
    c(0.7, 0.55, 0.3) lg.circle("fill", -26, 0, 8) lg.circle("fill", 26, 0, 8)
    c(0.45, 0.35, 0.85) lg.circle("line", 0, 0, 11) lg.circle("fill", 0, 0, 4)
    c(0.6, 0.45, 0.25) lg.line(-16, -10, 16, -10) lg.line(-16, 12, 16, 12)
end
-- ARMOR -----------------------------------------------------------------------
local function chest(r, g, b, r2, g2, b2)
    c(r, g, b) lg.polygon("fill", -24, -24, -10, -30, 10, -30, 24, -24, 30, -6, 20, -2, 20, 30, -20, 30, -20, -2, -30, -6)
    c(r2, g2, b2) lg.polygon("fill", -10, -30, 0, -18, 10, -30)
end
ICONS.leather = function() chest(0.55, 0.35, 0.18, 0.35, 0.22, 0.12) c(0.35, 0.22, 0.12) lg.line(0, -18, 0, 30) end
ICONS.fireproof = function()
    c(0.7, 0.22, 0.12) lg.polygon("fill", -14, -28, 14, -28, 30, 30, -30, 30)
    c(1, 0.6, 0.15) lg.polygon("fill", -8, 30, 0, 10, 8, 30) lg.polygon("fill", -22, 30, -16, 16, -10, 30) lg.polygon("fill", 10, 30, 16, 16, 22, 30)
    c(0.45, 0.12, 0.08) lg.circle("fill", 0, -26, 8)
end
ICONS.shadow = function()
    c(0.16, 0.14, 0.22) lg.polygon("fill", -14, -28, 14, -28, 30, 30, -30, 30)
    c(0.08, 0.07, 0.12) lg.circle("fill", 0, -24, 11)
    c(0.6, 0.5, 1, ia(0.8)) lg.circle("fill", -4, -24, 2) lg.circle("fill", 4, -24, 2)
end
ICONS.waders = function()
    c(0.3, 0.42, 0.22) lg.rectangle("fill", -22, -28, 16, 48, 4, 4) lg.rectangle("fill", 6, -28, 16, 48, 4, 4)
    c(0.22, 0.32, 0.16) lg.rectangle("fill", -26, 16, 24, 12, 4, 4) lg.rectangle("fill", 2, 16, 24, 12, 4, 4)
    c(0.45, 0.32, 0.18) lg.rectangle("fill", -24, -30, 48, 6)
end
ICONS.tanky = function()
    chest(0.5, 0.52, 0.56, 0.32, 0.33, 0.36)
    c(0.7, 0.72, 0.76) lg.rectangle("fill", -16, 0, 32, 6) lg.rectangle("fill", -16, 12, 32, 6)
    c(0.32, 0.33, 0.36) lg.circle("fill", -26, -14, 7) lg.circle("fill", 26, -14, 7)
end
ICONS.scrap = function()
    c(0.55, 0.56, 0.6) lg.polygon("fill", -24, -6, -6, -20, 10, -12, 4, 6, -16, 10)
    c(0.7, 0.66, 0.6) lg.polygon("fill", 2, 8, 22, -4, 26, 14, 10, 22)
    c(0.4, 0.4, 0.44) lg.circle("fill", -10, -6, 3) lg.circle("fill", 16, 8, 3)
end
-- tab / menu symbols
ICONS.tab_loadout = function()
    c(0.5, 0.35, 0.18) lg.rectangle("fill", -22, -18, 44, 46, 8, 8)
    c(0.4, 0.27, 0.13) lg.rectangle("fill", -14, -28, 28, 14, 5, 5)
    c(0.6, 0.45, 0.25) lg.rectangle("fill", -16, 4, 32, 16, 4, 4)
end
ICONS.tab_armor = function() chest(0.55, 0.56, 0.6, 0.35, 0.36, 0.4) end
ICONS.miner = function()
    c(0.85, 0.65, 0.15) lg.arc("fill", "pie", 0, 10, 28, pi, 2 * pi) lg.rectangle("fill", -36, 8, 72, 8, 3, 3)
    c(0.7, 0.5, 0.1) lg.rectangle("fill", -6, -16, 12, 22, 2, 2)
    c(1, 1, 0.75) lg.circle("fill", 0, -6, 6)
    c(1, 0.95, 0.6, ia(0.35)) lg.polygon("fill", 0, -6, 44, -26, 44, 14)
end
ICONS.vest = function()
    chest(0.35, 0.38, 0.3, 0.25, 0.27, 0.2)
    c(0.55, 0.58, 0.48) lg.rectangle("fill", -14, -8, 28, 6) lg.rectangle("fill", -14, 6, 28, 6)
end
ICONS.boots = function()
    c(0.55, 0.42, 0.28) lg.polygon("fill", -24, -26, -6, -26, -6, 14, 18, 16, 24, 28, -24, 28)
    c(0.9, 0.9, 0.95) lg.polygon("fill", -6, -10, 22, -30, 12, -4)
    c(0.4, 0.3, 0.2) lg.rectangle("fill", -26, 24, 52, 6, 2, 2)
end
-- armor SLOT symbols (drawn tinted, tan on dark brown)
ICONS.slot_head = function() c(1, 1, 1) lg.arc("fill", "pie", 0, 10, 26, pi, 2 * pi) lg.rectangle("fill", -34, 8, 68, 9, 3, 3) end
ICONS.slot_chest = function() chest(1, 1, 1, 0.45, 0.45, 0.45) end
ICONS.slot_legs = function()
    c(1, 1, 1) lg.rectangle("fill", -22, -28, 44, 12, 3, 3)
    lg.polygon("fill", -22, -18, -2, -18, -6, 30, -22, 30) lg.polygon("fill", 22, -18, 2, -18, 6, 30, 22, 30)
end
ICONS.slot_feet = function()
    c(1, 1, 1) lg.polygon("fill", -22, -28, -4, -28, -4, 10, 20, 12, 26, 28, -22, 28)
end

-- an icon in one flat colour (the yellow symbols on the shop tabs)
function X.drawIconTinted(id, cx, cy, scale, col)
    local f = ICONS[id]
    if not f then return end
    lg.push()
    lg.translate(cx, cy)
    lg.scale(scale, scale)
    local sc = lg.setColor
    lg.setColor = function(_, _, _, a) sc(col[1], col[2], col[3], (a or 1) * (col[4] or 1)) end
    f()
    lg.setColor = sc
    lg.pop()
end
X.hasIcon = function(id) return ICONS[id] ~= nil end

function X.drawWeaponIcon(id, cx, cy, scale, alpha, silhouette)
    local f = ICONS[id]
    if not f then return end
    lg.push()
    lg.translate(cx, cy)
    lg.scale(scale, scale)
    X.iconAlpha = alpha or 1
    if silhouette then
        -- locked: draw a dark silhouette
        local sc = lg.setColor
        lg.setColor = function(_, _, _, a) sc(0.05, 0.04, 0.04, (a or 1) * 0.85) end
        f()
        lg.setColor = sc
    else
        f()
    end
    X.iconAlpha = nil
    lg.pop()
end

-- The loot crate icon
function X.drawCrateIcon(cx, cy, scale, glow)
    lg.push()
    lg.translate(cx, cy)
    lg.scale(scale, scale)
    if glow and glow > 0 then
        lg.setColor(1, 0.8, 0.3, 0.18 * glow)
        lg.circle("fill", 0, 0, 52)
    end
    lg.setColor(0.45, 0.28, 0.13)
    lg.rectangle("fill", -36, -22, 72, 46, 5, 5)
    lg.setColor(0.6, 0.39, 0.19)
    lg.rectangle("fill", -36, -30, 72, 14, 5, 5)
    lg.setColor(0.95, 0.75, 0.3)
    lg.rectangle("fill", -36, -18, 72, 5)
    lg.rectangle("fill", -6, -30, 12, 54)
    lg.setColor(0.25, 0.15, 0.07)
    lg.setLineWidth(2)
    lg.rectangle("line", -36, -30, 72, 54, 5, 5)
    lg.setLineWidth(1)
    lg.setColor(1, 0.95, 0.7)
    lg.setFont(fonts.medium)
    lg.printf("?", -36, -2, 72, "center")
    lg.pop()
end

-- Top-down gun drawn inside drawHumanoid (already rotated to the aim direction)
function X.drawGunTop(id, r, len)
    local w = WEAPONS[id]
    local x0 = r * 0.3
    if id == "shotgun" then
        lg.setColor(0.15, 0.15, 0.17) lg.rectangle("fill", x0, r * 0.15, len, r * 0.32)
        lg.setColor(0.4, 0.26, 0.14) lg.rectangle("fill", r * 0.2, r * 0.1, len * 0.4, r * 0.42)
    elseif id == "revolver" then
        lg.setColor(0.7, 0.72, 0.76) lg.rectangle("fill", x0, r * 0.17, len, r * 0.28)
        lg.setColor(0.55, 0.57, 0.6) lg.circle("fill", x0 + 3, r * 0.31, r * 0.27)
    elseif id == "swifter" then
        lg.setColor(0.92, 0.95, 0.98) lg.rectangle("fill", x0, r * 0.18, len, r * 0.26)
        lg.setColor(0.2, 0.75, 0.75) lg.rectangle("fill", x0, r * 0.28, len, r * 0.07)
    elseif id == "spray" then
        lg.setColor(0.3, 0.62, 0.3) lg.rectangle("fill", x0 - 2, r * 0.05, len * 0.55, r * 0.5, 3, 3)
        lg.setColor(0.85, 0.85, 0.3) lg.rectangle("fill", x0 + len * 0.55, r * 0.17, len * 0.45, r * 0.28)
    elseif id == "rifle" then
        lg.setColor(0.14, 0.14, 0.16) lg.rectangle("fill", x0 - 4, r * 0.15, len + 4, r * 0.3)
        lg.setColor(0.2, 0.2, 0.22) lg.rectangle("fill", x0 + len * 0.3, r * 0.42, 5, r * 0.4)
    elseif id == "rpg" then
        lg.setColor(0.36, 0.42, 0.24) lg.rectangle("fill", x0 - 10, r * 0.05, len + 6, r * 0.5, 3, 3)
        lg.setColor(0.6, 0.6, 0.55) lg.polygon("fill", x0 + len - 4, r * 0.0, x0 + len + 8, r * 0.3, x0 + len - 4, r * 0.6)
    elseif id == "laser" then
        lg.setColor(0.92, 0.92, 0.96) lg.rectangle("fill", x0, r * 0.12, len, r * 0.38, 3, 3)
        lg.setColor(1, 0.3, 0.5, 0.6 + 0.4 * sin((menuTime or 0) * 8)) lg.circle("fill", x0 + len, r * 0.31, 3)
    elseif not X.drawGunTopNew(id, r, len) then
        lg.setColor(0.15, 0.15, 0.17) lg.rectangle("fill", x0, r * 0.15, len, r * 0.32)
    end
    local _ = w
end
end

------------------------------------------------------------------------------
-- Drawing: world
------------------------------------------------------------------------------
local drawWorld
do
local function drawGround(l, t, r, b)
    local TS = 128
    for tx = floor(l / TS), floor(r / TS) do
        for ty = floor(t / TS), floor(b / TS) do
            local h = hash(tx, ty)
            local v = (h - 0.5) * 0.05
            local x, y = tx * TS, ty * TS
            local reg = regionIn(x + 64, y + 64) or regionAt(x + 64, y + 64)
            -- outside the world: dark rock
            local outside = x + 64 < -K.GATE_T or y + 64 < -K.GATE_T or y + 64 > K.TOTAL_H + K.GATE_T or x + 64 > K.TOTAL_W + K.GATE_T
                or (x + 64 > K.WORLD_W + K.GATE_T and y + 64 < K.WORLD_H)
                or (x + 64 < K.WORLD_W and y + 64 > K.FROZEN_Y1 + K.GATE_T)
            if outside then
                lg.setColor(0.13 + v, 0.11 + v, 0.1 + v)
                lg.rectangle("fill", x, y, TS + 1, TS + 1)
            elseif reg == "spooky" then
                -- haunted soil
                lg.setColor(0.22 + v, 0.19 + v, 0.24 + v)
                lg.rectangle("fill", x, y, TS + 1, TS + 1)
                if h > 0.68 then
                    lg.setColor(0.16, 0.22, 0.14, 0.5)
                    lg.ellipse("fill", x + 64 + (h - 0.8) * 200, y + 64, 40 + h * 30, 18 + h * 12)
                end
            elseif reg == "frozen" then
                -- packed snow
                lg.setColor(0.88 + v, 0.91 + v, 0.95 + v * 0.5)
                lg.rectangle("fill", x, y, TS + 1, TS + 1)
                if h > 0.7 then
                    lg.setColor(0.78, 0.84, 0.92, 0.45)
                    lg.ellipse("fill", x + 64 + (h - 0.8) * 200, y + 64, 44 + h * 30, 16 + h * 10)
                end
            elseif reg == "swamp" then
                -- dark wet grass (like the sketch)
                lg.setColor(0.1 + v, 0.23 + v, 0.06 + v * 0.5)
                lg.rectangle("fill", x, y, TS + 1, TS + 1)
                if h > 0.66 then
                    lg.setColor(0.07, 0.2, 0.08, 0.6)
                    lg.ellipse("fill", x + 64 + (h - 0.8) * 200, y + 64, 46 + h * 30, 22 + h * 12)
                end
            elseif reg == "volcanic" then
                -- dark basalt with glowing cracks
                lg.setColor(0.2 + v, 0.16 + v, 0.15 + v)
                lg.rectangle("fill", x, y, TS + 1, TS + 1)
                if h > 0.72 then
                    local glow = 0.5 + 0.3 * sin(menuTime * 2 + h * 20)
                    lg.setColor(1, 0.35 + 0.1 * glow, 0.08, 0.35 * glow)
                    lg.setLineWidth(3)
                    lg.line(x + 20, y + 30 + h * 40, x + 64, y + 60, x + 100, y + 50 + h * 30)
                    lg.setLineWidth(1)
                elseif h < 0.2 then
                    lg.setColor(0.13, 0.11, 0.11, 0.6)
                    lg.ellipse("fill", x + 64, y + 64, 40 + h * 60, 20 + h * 30)
                end
            else
                lg.setColor(PAL.sand[1] + v, PAL.sand[2] + v, PAL.sand[3] + v * 0.8)
                lg.rectangle("fill", x, y, TS + 1, TS + 1)
                if h > 0.72 then
                    lg.setColor(0.55, 0.46, 0.32, 0.35)
                    lg.ellipse("fill", x + 64 + (h - 0.8) * 200, y + 64, 40 + h * 30, 18 + h * 12)
                end
            end
        end
    end
    -- frost line where the desert meets the Frozen Wastes (seen through the gate)
    if t < K.FROZEN_Y0 + 10 and b > K.WORLD_H and l < K.WORLD_W then
        local rr = min(r, K.WORLD_W)
        lg.setColor(0.88, 0.91, 0.95)
        lg.rectangle("fill", l, K.WORLD_H, rr - l, K.GATE_T + 8)
        lg.setColor(0.78, 0.85, 0.93)
        for x = floor(l / 40) * 40, rr, 40 do
            lg.ellipse("fill", x + 20, K.WORLD_H + 6, 26, 7)
        end
    end
end

local function drawDecor(l, t, r, b)
    local S = 512
    for gy = floor((t - 40) / S), floor((b + 40) / S) do
    for gx = floor((l - 40) / S), floor((r + 40) / S) do
    local cell = WG.dcells[gy * 4096 + gx]
    if cell then
    for _, d in ipairs(cell) do
        if d.x > l - 40 and d.x < r + 40 and d.y > t - 40 and d.y < b + 40 then
            if d.kind:sub(1, 2) == "z_" then
                X.drawDecorZ(d)
            elseif d.kind == "grass" then
                lg.setColor(0.45, 0.48, 0.25, 0.8)
                for k = -1, 1 do
                    lg.line(d.x + k * 3, d.y, d.x + k * 5 * d.s, d.y - 9 * d.s)
                end
            elseif d.kind == "pebble" then
                lg.setColor(0.5, 0.45, 0.38)
                lg.ellipse("fill", d.x, d.y, 3 * d.s, 2.2 * d.s)
            elseif d.kind == "bush" then
                lg.setColor(0, 0, 0, 0.15)
                lg.circle("fill", d.x + 3, d.y + 4, 12 * d.s)
                lg.setColor(0.42, 0.45, 0.24)
                lg.circle("fill", d.x, d.y, 11 * d.s)
                lg.setColor(0.5, 0.53, 0.3)
                lg.circle("fill", d.x - 3, d.y - 3, 6 * d.s)
            elseif d.kind == "cactus" then
                lg.setColor(0, 0, 0, 0.18)
                lg.ellipse("fill", d.x + 4, d.y + 18 * d.s, 9 * d.s, 4 * d.s)
                lg.setColor(0.28, 0.5, 0.3)
                lg.rectangle("fill", d.x - 4 * d.s, d.y - 16 * d.s, 8 * d.s, 34 * d.s, 4, 4)
                lg.rectangle("fill", d.x - 12 * d.s, d.y - 6 * d.s, 6 * d.s, 12 * d.s, 3, 3)
                lg.rectangle("fill", d.x + 6 * d.s, d.y - 10 * d.s, 6 * d.s, 10 * d.s, 3, 3)
            -- Frozen Wastes decoration
            elseif d.kind == "snowdrift" then
                lg.setColor(0.72, 0.8, 0.9, 0.5)
                lg.ellipse("fill", d.x + 3, d.y + 4, 22 * d.s, 7 * d.s)
                lg.setColor(0.97, 0.98, 1)
                lg.ellipse("fill", d.x, d.y, 20 * d.s, 6 * d.s)
            elseif d.kind == "snowtuft" then
                lg.setColor(0.6, 0.66, 0.6, 0.7)
                for k = -1, 1 do
                    lg.line(d.x + k * 3, d.y, d.x + k * 5 * d.s, d.y - 8 * d.s)
                end
                lg.setColor(1, 1, 1, 0.9)
                lg.circle("fill", d.x, d.y - 1, 2.5 * d.s)
            elseif d.kind == "frostpebble" then
                lg.setColor(0.58, 0.64, 0.72)
                lg.ellipse("fill", d.x, d.y, 3.4 * d.s, 2.4 * d.s)
                lg.setColor(1, 1, 1, 0.8)
                lg.ellipse("fill", d.x - 0.6, d.y - 1, 2.2 * d.s, 1 * d.s)
            elseif d.kind == "deadbush" then
                lg.setColor(0.4, 0.32, 0.25, 0.85)
                for k = 0, 4 do
                    local a = d.r + k * 1.25
                    lg.line(d.x, d.y, d.x + cos(a) * 11 * d.s, d.y + sin(a) * 11 * d.s)
                end
                lg.setColor(1, 1, 1, 0.7)
                lg.circle("fill", d.x, d.y, 2 * d.s)
            elseif d.kind == "icebit" then
                lg.setColor(0.65, 0.88, 1, 0.85)
                lg.polygon("fill", d.x, d.y - 5 * d.s, d.x + 3 * d.s, d.y, d.x, d.y + 5 * d.s, d.x - 3 * d.s, d.y)
            -- Haunted Hollow decoration
            elseif d.kind == "deadgrass" then
                lg.setColor(0.38, 0.33, 0.28, 0.8)
                for k = -1, 1 do lg.line(d.x + k * 3, d.y, d.x + k * 6 * d.s, d.y - 8 * d.s) end
            elseif d.kind == "bones" then
                lg.setColor(0.85, 0.82, 0.72, 0.9)
                lg.setLineWidth(2)
                lg.line(d.x - 6 * d.s, d.y - 3 * d.s, d.x + 6 * d.s, d.y + 3 * d.s)
                lg.line(d.x - 6 * d.s, d.y + 3 * d.s, d.x + 6 * d.s, d.y - 3 * d.s)
                lg.setLineWidth(1)
                lg.circle("fill", d.x + 8 * d.s, d.y - 6 * d.s, 3.5 * d.s)
                lg.setColor(0.1, 0.08, 0.1)
                lg.circle("fill", d.x + 7 * d.s, d.y - 6.5 * d.s, 0.9 * d.s)
                lg.circle("fill", d.x + 9 * d.s, d.y - 6.5 * d.s, 0.9 * d.s)
            elseif d.kind == "mushroom" then
                local g = 0.6 + 0.4 * sin(menuTime * 2 + d.ph)
                lg.setColor(0.4, 1, 0.5, 0.15 * g)
                lg.circle("fill", d.x, d.y, 12 * d.s)
                lg.setColor(0.85, 0.85, 0.75)
                lg.rectangle("fill", d.x - 1.5 * d.s, d.y, 3 * d.s, 5 * d.s)
                lg.setColor(0.3, 0.8 * g + 0.2, 0.4)
                lg.ellipse("fill", d.x, d.y, 6 * d.s, 3.5 * d.s)
            elseif d.kind == "pumpkin" then
                local g = 0.7 + 0.3 * sin(menuTime * 8 + d.ph)
                lg.setColor(1, 0.6, 0.1, 0.12 * g)
                lg.circle("fill", d.x, d.y, 18 * d.s)
                lg.setColor(0.9, 0.45, 0.08)
                lg.ellipse("fill", d.x, d.y, 8 * d.s, 6.5 * d.s)
                lg.setColor(1, 0.85 * g, 0.2)
                lg.polygon("fill", d.x - 4 * d.s, d.y - 2 * d.s, d.x - 1.5 * d.s, d.y - 2 * d.s, d.x - 2.75 * d.s, d.y - 4 * d.s)
                lg.polygon("fill", d.x + 4 * d.s, d.y - 2 * d.s, d.x + 1.5 * d.s, d.y - 2 * d.s, d.x + 2.75 * d.s, d.y - 4 * d.s)
                lg.rectangle("fill", d.x - 4 * d.s, d.y + 1 * d.s, 8 * d.s, 1.6 * d.s)
                lg.setColor(0.3, 0.4, 0.15)
                lg.rectangle("fill", d.x - 1, d.y - 8.5 * d.s, 2, 3 * d.s)
            elseif d.kind == "candle" then
                local fl = 0.7 + 0.3 * sin(menuTime * 15 + d.ph)
                lg.setColor(1, 0.7, 0.3, 0.12 * fl)
                lg.circle("fill", d.x, d.y - 6, 16 * d.s)
                lg.setColor(0.9, 0.88, 0.8)
                lg.rectangle("fill", d.x - 2, d.y - 5, 4, 8)
                lg.setColor(1, 0.75 * fl, 0.2)
                lg.ellipse("fill", d.x, d.y - 8, 1.8, 3 * fl)
            end
        end
    end
    end end end
end

local function drawLakes(l, t, r, b)
    for _, k in ipairs(lakes) do
        if k.x + k.rx > l and k.x - k.rx < r and k.y + k.ry > t and k.y - k.ry < b then
            lg.setColor(0.55, 0.7, 0.84, 0.9)
            lg.ellipse("fill", k.x, k.y, k.rx + 6, k.ry + 6)
            lg.setColor(0.68, 0.84, 0.95)
            lg.ellipse("fill", k.x, k.y, k.rx, k.ry)
            lg.setColor(0.78, 0.9, 0.98)
            lg.ellipse("fill", k.x - k.rx * 0.2, k.y - k.ry * 0.25, k.rx * 0.55, k.ry * 0.4)
            -- cracks
            lg.setColor(0.5, 0.68, 0.84, 0.7)
            for c = 1, 5 do
                local a = k.seed + c * 1.3
                local x1, y1 = k.x + cos(a) * k.rx * 0.15, k.y + sin(a) * k.ry * 0.15
                local x2, y2 = k.x + cos(a + 0.2) * k.rx * 0.8, k.y + sin(a + 0.2) * k.ry * 0.8
                lg.line(x1, y1, (x1 + x2) / 2 + sin(a * 3) * 10, (y1 + y2) / 2 + cos(a * 3) * 6, x2, y2)
            end
            -- shine streaks
            lg.setColor(1, 1, 1, 0.45)
            lg.setLineWidth(2)
            lg.line(k.x - k.rx * 0.5, k.y + k.ry * 0.1, k.x - k.rx * 0.3, k.y - k.ry * 0.2)
            lg.line(k.x - k.rx * 0.35, k.y + k.ry * 0.2, k.x - k.rx * 0.2, k.y - k.ry * 0.02)
            lg.setLineWidth(1)
        end
    end
end

-- The Stronghold: stone fort walls, towers, the keep and barricades
function X.drawFortWall(w)
    local k = w.kind
    if k ~= "fort" and k ~= "tower" and k ~= "keep" and k ~= "barricade" then return false end
    lg.setColor(0, 0, 0, 0.3)
    lg.rectangle("fill", w.x + 7, w.y + 9, w.w, w.h)
    if k == "barricade" then
        lg.setColor(0.42, 0.3, 0.18)
        lg.rectangle("fill", w.x, w.y, w.w, w.h, 3, 3)
        lg.setColor(0.3, 0.2, 0.1)
        if w.w > w.h then
            for px = w.x + 14, w.x + w.w - 4, 14 do lg.line(px, w.y, px - 6, w.y + w.h) end
        else
            for py = w.y + 14, w.y + w.h - 4, 14 do lg.line(w.x, py, w.x + w.w, py - 6) end
        end
        lg.setColor(0.6, 0.6, 0.62)
        lg.rectangle("fill", w.x, w.y, w.w, 3)
        return true
    end
    local base = k == "keep" and { 0.5, 0.45, 0.4 } or { 0.56, 0.5, 0.42 }
    lg.setColor(base)
    lg.rectangle("fill", w.x, w.y, w.w, w.h)
    -- stone blocks
    lg.setColor(base[1] - 0.1, base[2] - 0.1, base[3] - 0.1)
    for py = w.y + 15, w.y + w.h - 2, 15 do lg.line(w.x, py, w.x + w.w, py) end
    local row = 0
    for py = w.y, w.y + w.h - 2, 15 do
        local off = (row % 2) * 15
        for px = w.x + 30 - off, w.x + w.w - 2, 30 do lg.line(px, py, px, min(py + 15, w.y + w.h)) end
        row = row + 1
    end
    -- battlements
    lg.setColor(base[1] + 0.12, base[2] + 0.12, base[3] + 0.1)
    lg.rectangle("fill", w.x, w.y, w.w, 5)
    if k == "tower" or k == "keep" then
        lg.setColor(base[1] - 0.18, base[2] - 0.18, base[3] - 0.16)
        lg.rectangle("line", w.x + 6, w.y + 6, w.w - 12, w.h - 12)
        for i = 0, 3 do
            lg.rectangle("fill", w.x + 6 + i * (w.w - 22) / 3, w.y + 6, 10, 8)
        end
        if k == "keep" then
            -- a green banner of the Bow Wielders
            local fx = w.x + w.w / 2
            lg.setColor(0.25, 0.2, 0.15)
            lg.setLineWidth(3)
            lg.line(fx, w.y + w.h / 2 + 20, fx, w.y + w.h / 2 - 40)
            lg.setLineWidth(1)
            local wave = sin(menuTime * 4) * 4
            lg.setColor(0.3, 0.62, 0.25)
            lg.polygon("fill", fx, w.y + w.h / 2 - 40, fx + 34, w.y + w.h / 2 - 32 + wave, fx, w.y + w.h / 2 - 22)
        end
    end
    return true
end

function X.drawShot(bl)
    local look, a = bl.look, atan2(bl.vy, bl.vx)
    if bl.kind == "flame" then
        local pr = 1 - clamp(bl.life / 0.45, 0, 1)
        lg.setColor(1, 0.5 + 0.3 * (1 - pr), 0.1, 0.75 * (1 - pr * 0.6))
        lg.circle("fill", bl.x, bl.y, 5 + pr * 12)
        lg.setColor(1, 0.9, 0.4, 0.6 * (1 - pr))
        lg.circle("fill", bl.x, bl.y, 3 + pr * 5)
    elseif bl.kind == "boomerang" then
        lg.push()
        lg.translate(bl.x, bl.y)
        lg.rotate(bl.spin or 0)
        lg.setColor(0.8, 0.85, 0.9)
        lg.polygon("fill", -14, -3, 0, -6, 14, -3, 0, 2)
        lg.setColor(0.45, 0.3, 0.2)
        lg.circle("fill", 0, -2, 3)
        lg.pop()
    elseif bl.kind == "bhole" then
        lg.setColor(0.45, 0.2, 0.75, 0.5)
        lg.circle("fill", bl.x, bl.y, 11)
        lg.setColor(0.05, 0, 0.08)
        lg.circle("fill", bl.x, bl.y, 7)
    elseif look == "bubble" then
        lg.setColor(0.6, 0.85, 1, 0.35)
        lg.circle("fill", bl.x, bl.y, 7)
        lg.setColor(0.85, 0.95, 1, 0.9)
        lg.setLineWidth(1.5)
        lg.circle("line", bl.x, bl.y, 7)
        lg.circle("fill", bl.x - 2.5, bl.y - 2.5, 1.5)
    elseif look == "bolt" or look == "ghost" then
        local c = look == "ghost" and { 0.75, 0.95, 1, 0.85 } or { 0.55, 0.38, 0.22, 1 }
        lg.setColor(c)
        lg.setLineWidth(2.5)
        lg.line(bl.x - cos(a) * 16, bl.y - sin(a) * 16, bl.x, bl.y)
        lg.polygon("fill", bl.x + cos(a) * 6, bl.y + sin(a) * 6, bl.x + cos(a + 2.4) * 5, bl.y + sin(a + 2.4) * 5,
            bl.x + cos(a - 2.4) * 5, bl.y + sin(a - 2.4) * 5)
    elseif look == "void" then
        lg.setColor(0.55, 0.2, 0.85, 0.5)
        lg.circle("fill", bl.x, bl.y, 6)
        lg.setColor(0.1, 0, 0.15)
        lg.circle("fill", bl.x, bl.y, 3)
    elseif look == "plasma" then
        lg.setColor(0.3, 1, 0.55, 0.35)
        lg.circle("fill", bl.x, bl.y, 8)
        lg.setColor(0.8, 1, 0.85)
        lg.circle("fill", bl.x, bl.y, 4)
    elseif look == "ice" then
        lg.setColor(0.65, 0.9, 1, 0.8)
        lg.circle("fill", bl.x, bl.y, 4)
        lg.setColor(1, 1, 1)
        lg.circle("fill", bl.x, bl.y, 1.8)
    elseif look == "ball" then
        lg.setColor(0, 0, 0, 0.25)
        lg.circle("fill", bl.x + 3, bl.y + 5, 7)
        lg.setColor(0.18, 0.18, 0.2)
        lg.circle("fill", bl.x, bl.y, 7)
        lg.setColor(0.45, 0.45, 0.5)
        lg.circle("fill", bl.x - 2, bl.y - 2, 2)
    elseif look == "blaze" then
        -- Blaze Spell bullets are little flames
        lg.setColor(1, 0.4, 0.05, 0.5)
        lg.circle("fill", bl.x - bl.vx * 0.012, bl.y - bl.vy * 0.012, 7)
        lg.setColor(1, 0.65, 0.15)
        lg.circle("fill", bl.x, bl.y, 5)
        lg.setColor(1, 0.95, 0.5)
        lg.circle("fill", bl.x, bl.y, 2.5)
    elseif look == "gold" then
        lg.setColor(1, 0.82, 0.2)
        lg.setLineWidth(3)
        lg.line(bl.x - bl.vx * 0.022, bl.y - bl.vy * 0.022, bl.x, bl.y)
        lg.setColor(1, 1, 0.7)
        lg.circle("fill", bl.x, bl.y, 2.5)
    else
        return false
    end
    lg.setLineWidth(3)
    return true
end

-- black holes, falling meteors, the Stronghold label
function X.drawSpecials()
    X.drawBossWorld()
    X.drawKitWorld()
    X.drawExtrasWorld()
    for _, v in ipairs(X.vortices) do
        local k = clamp(v.t / 2, 0, 1)
        local r = 30 + 10 * sin(menuTime * 12)
        lg.setColor(0.45, 0.2, 0.8, 0.18)
        lg.circle("fill", v.x, v.y, 220 * (0.4 + 0.6 * k))
        lg.setColor(0.6, 0.3, 1, 0.6)
        lg.setLineWidth(3)
        for i = 0, 2 do
            local a = menuTime * 5 + i * 2.1
            lg.arc("line", "open", v.x, v.y, r + 18 + i * 10, a, a + 1.6)
        end
        lg.setColor(0.03, 0, 0.06)
        lg.circle("fill", v.x, v.y, r)
        lg.setLineWidth(1)
    end
    for _, m in ipairs(X.meteors) do
        local p = 1 - clamp(m.t / m.maxT, 0, 1)
        -- target marker grows, the rock falls in from the top-right
        lg.setColor(1, 0.35, 0.1, 0.25 + 0.35 * p)
        lg.circle("fill", m.x, m.y, WEAPONS.meteor.blast * p)
        lg.setColor(1, 0.5, 0.2, 0.8)
        lg.setLineWidth(2)
        lg.circle("line", m.x, m.y, WEAPONS.meteor.blast)
        lg.setLineWidth(1)
        local h = (1 - p) * 520
        local mx, my = m.x + h * 0.55, m.y - h
        lg.setColor(1, 0.6, 0.15, 0.5)
        lg.circle("fill", mx + 10, my - 18, 16)
        lg.setColor(0.4, 0.28, 0.2)
        lg.circle("fill", mx, my, 14)
        lg.setColor(1, 0.45, 0.1)
        lg.circle("fill", mx - 4, my + 4, 6)
    end
    local S = X.SH
    if S and dist(player.x, player.y, S.cx, S.cy) < 1100 then
        lg.setFont(fonts.normal)
        lg.setColor(0, 0, 0, 0.6)
        lg.printf("THE STRONGHOLD", S.x + 1, S.y - 59, S.w, "center")
        lg.setColor(0.6, 0.9, 0.45)
        lg.printf("THE STRONGHOLD", S.x, S.y - 60, S.w, "center")
    end
end

local function drawWall(w)
    if w.enemyOnly then return end
    if X.drawFortWall(w) then return end
    if X.drawLairWall(w) then return end
    if X.drawNewWall(w) then return end
    if w.kind == "shed" then
        lg.setColor(0, 0, 0, 0.28)
        lg.rectangle("fill", w.x + 6, w.y + 8, w.w, w.h)
        lg.setColor(0.36, 0.22, 0.12)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.26, 0.15, 0.08)
        if w.w > w.h then
            for px = w.x + 20, w.x + w.w - 4, 20 do lg.line(px, w.y, px, w.y + w.h) end
        else
            for py = w.y + 20, w.y + w.h - 4, 20 do lg.line(w.x, py, w.x + w.w, py) end
        end
        lg.setColor(0.55, 0.36, 0.2)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
        return
    end
    if w.kind == "pine" then
        local cx, cy, rr = w.x + w.w / 2, w.y + w.h / 2, w.w * 0.85
        lg.setColor(0, 0, 0, 0.22)
        lg.circle("fill", cx + 8, cy + 10, rr)
        for i = 0, 2 do
            local k = 1 - i * 0.28
            lg.setColor(0.12 + i * 0.04, 0.3 + i * 0.07, 0.2 + i * 0.03)
            lg.circle("fill", cx - i * 2, cy - i * 3, rr * k, 9)
        end
        lg.setColor(0.96, 0.98, 1, 0.92)
        lg.circle("fill", cx - 6, cy - 9, rr * 0.3)
        lg.circle("fill", cx + rr * 0.35, cy + rr * 0.1, rr * 0.16)
        lg.circle("fill", cx - rr * 0.4, cy + rr * 0.25, rr * 0.14)
        return
    end
    if w.kind == "deadtree" then
        local cx, cy, rr = w.x + w.w / 2, w.y + w.h / 2, w.w * 0.5
        lg.setColor(0, 0, 0, 0.25)
        lg.circle("fill", cx + 7, cy + 9, rr * 1.6)
        lg.setColor(0.2, 0.15, 0.13)
        lg.circle("fill", cx, cy, rr)
        lg.setLineWidth(4)
        for k = 0, 5 do
            local a = k * 1.05 + (w.x % 5) * 0.4
            local L = w.w * (0.9 + 0.3 * ((k * 3) % 2))
            local mx, my = cx + cos(a) * L * 0.55, cy + sin(a) * L * 0.55
            lg.line(cx, cy, mx, my)
            lg.setLineWidth(2)
            lg.line(mx, my, cx + cos(a + 0.35) * L, cy + sin(a + 0.35) * L)
            lg.line(mx, my, cx + cos(a - 0.3) * L * 0.85, cy + sin(a - 0.3) * L * 0.85)
            lg.setLineWidth(4)
        end
        lg.setLineWidth(1)
        lg.setColor(0.32, 0.25, 0.2)
        lg.circle("fill", cx - 2, cy - 2, rr * 0.55)
        return
    end
    if w.kind == "crystal" then
        local cx, cy = w.x + w.w / 2, w.y + w.h / 2
        lg.setColor(0, 0, 0, 0.2)
        lg.ellipse("fill", cx + 6, cy + 8, w.w * 0.55, w.h * 0.4)
        for k = 0, 5 do
            local a = k * 1.047 + (w.x % 7) * 0.3
            local L = w.w * (0.45 + 0.2 * ((k * 7) % 3) / 2)
            lg.setColor(0.55 + 0.05 * k, 0.82, 1, 0.92)
            lg.polygon("fill", cx + cos(a) * L, cy + sin(a) * L,
                cx + cos(a + 0.5) * L * 0.3, cy + sin(a + 0.5) * L * 0.3,
                cx + cos(a - 0.5) * L * 0.3, cy + sin(a - 0.5) * L * 0.3)
            lg.setColor(1, 1, 1, 0.6)
            lg.line(cx, cy, cx + cos(a) * L, cy + sin(a) * L)
        end
        lg.setColor(0.85, 0.96, 1)
        lg.circle("fill", cx, cy, w.w * 0.15)
        return
    end
    -- shadow
    lg.setColor(0, 0, 0, 0.25)
    lg.rectangle("fill", w.x + 7, w.y + 9, w.w, w.h, 3, 3)
    if w.kind == "wood" then
        lg.setColor(0.42, 0.27, 0.15)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.32, 0.2, 0.11)
        if w.w > w.h then
            for px = w.x + 30, w.x + w.w - 5, 30 do lg.line(px, w.y, px, w.y + w.h) end
        else
            for py = w.y + 30, w.y + w.h - 5, 30 do lg.line(w.x, py, w.x + w.w, py) end
        end
        lg.setColor(0.55, 0.37, 0.22)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
    elseif w.kind == "stone" then
        lg.setColor(0.46, 0.44, 0.42)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.36, 0.34, 0.33)
        lg.rectangle("line", w.x + 0.5, w.y + 0.5, w.w - 1, w.h - 1)
        lg.setColor(0.58, 0.56, 0.53)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
    elseif w.kind == "rock" then
        lg.setColor(0.48, 0.42, 0.36)
        lg.rectangle("fill", w.x, w.y, w.w, w.h, 14, 14)
        lg.setColor(0.58, 0.52, 0.45)
        lg.rectangle("fill", w.x + 6, w.y + 4, w.w * 0.55, w.h * 0.4, 10, 10)
        lg.setColor(0.36, 0.31, 0.27)
        lg.line(w.x + w.w * 0.3, w.y + w.h * 0.6, w.x + w.w * 0.7, w.y + w.h * 0.75)
    elseif w.kind == "ice" then
        lg.setColor(0.58, 0.75, 0.88)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.75, 0.88, 0.97)
        lg.rectangle("fill", w.x + 2, w.y + 2, w.w - 4, w.h * 0.45)
        lg.setColor(0.45, 0.62, 0.78)
        if w.w > w.h then
            for px = w.x + 40, w.x + w.w - 5, 40 do lg.line(px, w.y, px - 6, w.y + w.h) end
        else
            for py = w.y + 40, w.y + w.h - 5, 40 do lg.line(w.x, py, w.x + w.w, py - 6) end
        end
        lg.setColor(1, 1, 1, 0.9)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
    elseif w.kind == "snowrock" then
        lg.setColor(0.45, 0.47, 0.52)
        lg.rectangle("fill", w.x, w.y, w.w, w.h, 14, 14)
        lg.setColor(0.36, 0.38, 0.43)
        lg.line(w.x + w.w * 0.3, w.y + w.h * 0.65, w.x + w.w * 0.7, w.y + w.h * 0.8)
        lg.setColor(0.96, 0.98, 1)
        lg.rectangle("fill", w.x + 3, w.y + 2, w.w * 0.8, w.h * 0.42, 12, 12)
    elseif w.kind == "crypt" then
        lg.setColor(0.3, 0.28, 0.34)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.22, 0.2, 0.26)
        if w.w > w.h then
            for px = w.x + 24, w.x + w.w - 5, 24 do lg.line(px, w.y, px, w.y + w.h) end
        else
            for py = w.y + 24, w.y + w.h - 5, 24 do lg.line(w.x, py, w.x + w.w, py) end
        end
        lg.setColor(0.28, 0.36, 0.24, 0.9)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
    elseif w.kind == "grave" then
        lg.setColor(0.48, 0.48, 0.53)
        lg.rectangle("fill", w.x, w.y, w.w, w.h, 8, 8)
        lg.setColor(0.36, 0.36, 0.4)
        lg.rectangle("line", w.x + 0.5, w.y + 0.5, w.w - 1, w.h - 1, 8, 8)
        lg.setColor(0.25, 0.25, 0.28)
        lg.line(w.x + w.w / 2, w.y + 3, w.x + w.w / 2, w.y + w.h - 3)
        lg.line(w.x + w.w / 2 - 5, w.y + 6, w.x + w.w / 2 + 5, w.y + 6)
    elseif w.kind == "fence" then
        lg.setColor(0.1, 0.09, 0.12)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.3, 0.28, 0.34)
        if w.w > w.h then
            for px = w.x + 6, w.x + w.w, 14 do lg.circle("fill", px, w.y + w.h / 2, 2.5) end
        else
            for py = w.y + 6, w.y + w.h, 14 do lg.circle("fill", w.x + w.w / 2, py, 2.5) end
        end
    elseif w.kind == "gate" or w.kind == "gate2" then
        lg.setColor(0.16, 0.18, 0.22)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.36, 0.4, 0.48)
        lg.setLineWidth(5)
        for px = w.x + 12, w.x + w.w - 6, 18 do lg.line(px, w.y + 4, px, w.y + w.h - 4) end
        lg.setLineWidth(1)
        lg.setColor(0.8, 0.9, 1, 0.6)
        lg.rectangle("fill", w.x, w.y, w.w, 8)
        local pulse = 0.5 + 0.5 * sin(menuTime * 3)
        if w.kind == "gate2" then lg.setColor(0.75, 0.4, 1, 0.35 + 0.4 * pulse) else lg.setColor(0.4, 0.8, 1, 0.35 + 0.4 * pulse) end
        lg.circle("fill", w.x + w.w / 2, w.y + w.h / 2, 16 + pulse * 3)
        lg.setColor(0.85, 0.95, 1)
        lg.circle("line", w.x + w.w / 2, w.y + w.h / 2, 12)
        lg.rectangle("fill", w.x + w.w / 2 - 4, w.y + w.h / 2 - 2, 8, 9)
    else
        lg.setColor(0.2, 0.15, 0.1)
        lg.rectangle("fill", w.x, w.y, w.w, w.h)
    end
end

local function drawHumanoid(x, y, r, angle, bodyCol, hatCol, flash, gunLen, walk, muzzle, extra)
    lg.push()
    lg.translate(x, y)
    -- shadow
    lg.setColor(0, 0, 0, 0.25)
    lg.ellipse("fill", 3, r * 0.7, r * 1.05, r * 0.5)
    lg.rotate(angle)
    -- feet (walk cycle)
    local step = sin(walk) * r * 0.45
    lg.setColor(0.2, 0.14, 0.1)
    lg.ellipse("fill", step, -r * 0.5, r * 0.35, r * 0.22)
    lg.ellipse("fill", -step, r * 0.5, r * 0.35, r * 0.22)
    -- gun
    if extra and WEAPONS[extra] then
        X.drawGunTop(extra, r, gunLen)
    else
        lg.setColor(0.15, 0.15, 0.17)
        lg.rectangle("fill", r * 0.3, r * 0.15, gunLen, r * 0.32)
    end
    if muzzle > 0 then
        lg.setColor(1, 0.85, 0.4, 0.9)
        lg.circle("fill", r * 0.3 + gunLen + 5, r * 0.3, 7)
        lg.setColor(1, 1, 0.8, 0.9)
        lg.circle("fill", r * 0.3 + gunLen + 4, r * 0.3, 3.5)
    end
    -- body
    if flash > 0 then lg.setColor(1, 1, 1) else setC(bodyCol) end
    lg.circle("fill", 0, 0, r)
    lg.setColor(0, 0, 0, 0.35)
    lg.setLineWidth(2)
    lg.circle("line", 0, 0, r)
    lg.setLineWidth(1)
    -- hat (wide brim)
    if hatCol then
        setC(hatCol)
        lg.ellipse("fill", -1, 0, r * 0.95, r * 1.05)
        lg.setColor(hatCol[1] * 1.25, hatCol[2] * 1.25, hatCol[3] * 1.25)
        lg.circle("fill", -2, 0, r * 0.55)
    end
    lg.pop()
end

-- Frozen: a small yeti with icy horns
local function drawYeti(e, alpha)
    drawHumanoid(e.x, e.y, e.r, e.angle, { 0.93, 0.96, 1, alpha }, nil, e.hitFlash, 4, e.walkAnim, 0)
    lg.push()
    lg.translate(e.x, e.y)
    lg.rotate(e.angle)
    local r = e.r
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.86, 0.91, 0.98, alpha) end
    for k = 0, 6 do
        local a = k * 0.9 + 1.2
        lg.circle("fill", cos(a) * r * 0.85, sin(a) * r * 0.85, r * 0.32)
    end
    -- face
    lg.setColor(0.42, 0.62, 0.84, alpha)
    lg.circle("fill", r * 0.45, 0, r * 0.45)
    -- glowing eyes
    lg.setColor(0.45, 1, 1, alpha)
    lg.circle("fill", r * 0.66, -r * 0.18, 2.2)
    lg.circle("fill", r * 0.66, r * 0.18, 2.2)
    -- horns
    lg.setColor(0.72, 0.86, 0.98, alpha)
    lg.polygon("fill", r * 0.1, -r * 0.65, -r * 0.35, -r * 1.25, r * 0.35, -r * 0.8)
    lg.polygon("fill", r * 0.1, r * 0.65, -r * 0.35, r * 1.25, r * 0.35, r * 0.8)
    -- icicle ready in claw
    if e.state == "hunt" and e.fireCd < 0.4 then
        lg.setColor(0.7, 0.93, 1, alpha)
        lg.polygon("fill", r * 0.9, r * 0.45, r * 0.9, r * 0.75, r * 1.7, r * 0.6)
    end
    lg.pop()
end

-- Snowman Soldier: two snowballs, army helmet, carrot nose, branch weapon
local function drawSnowman(e, alpha)
    local r = e.r
    lg.push()
    lg.translate(e.x, e.y)
    lg.setColor(0, 0, 0, 0.22)
    lg.ellipse("fill", 3, r * 0.75, r * 1.3, r * 0.55)
    lg.rotate(e.angle)
    local white = e.hitFlash > 0 and { 1, 1, 1 } or { 0.95, 0.97, 1 }
    -- body
    lg.setColor(white[1], white[2], white[3], alpha)
    lg.circle("fill", -r * 0.35, 0, r)
    lg.setColor(0.7, 0.8, 0.9, alpha)
    lg.setLineWidth(2)
    lg.circle("line", -r * 0.35, 0, r)
    -- coal buttons
    lg.setColor(0.12, 0.12, 0.14, alpha)
    for k = -1, 1 do lg.circle("fill", -r * 0.35 - r * 0.55, k * r * 0.35, 2) end
    -- branch arm (weapon) with swing animation
    local ba = 0.9
    if e.swingT > 0 then
        local p = 1 - e.swingT / 0.4
        ba = 1.8 - 2.9 * p
    elseif e.meleeCd > 0.9 then
        ba = -1.1 + (1.3 - e.meleeCd) * 4
    end
    local sx, sy = -r * 0.1, r * 0.8
    local ex, ey = sx + cos(ba) * r * 1.7, sy + sin(ba) * r * 1.7
    lg.setColor(0.42, 0.27, 0.14, alpha)
    lg.setLineWidth(4)
    lg.line(sx, sy, ex, ey)
    lg.setLineWidth(2)
    lg.line(sx + (ex - sx) * 0.6, sy + (ey - sy) * 0.6, sx + (ex - sx) * 0.6 + cos(ba + 0.7) * 8, sy + (ey - sy) * 0.6 + sin(ba + 0.7) * 8)
    -- other arm holding a snowball
    lg.line(-r * 0.1, -r * 0.8, r * 0.5, -r * 1.35)
    if e.throwCd < 0.6 or e.throwAnim > 0 then
        lg.setColor(1, 1, 1, alpha)
        lg.circle("fill", r * 0.6, -r * 1.4, 5)
    end
    lg.setLineWidth(1)
    -- head
    lg.setColor(white[1], white[2], white[3], alpha)
    lg.circle("fill", r * 0.45, 0, r * 0.68)
    lg.setColor(0.7, 0.8, 0.9, alpha)
    lg.circle("line", r * 0.45, 0, r * 0.68)
    -- army helmet (back half of the head)
    lg.setColor(0.33, 0.38, 0.27, alpha)
    lg.arc("fill", r * 0.4, 0, r * 0.66, pi * 0.5, pi * 1.5, 12)
    lg.setColor(0.25, 0.3, 0.2, alpha)
    lg.rectangle("fill", r * 0.32, -r * 0.66, 4, r * 1.32)
    -- coal eyes & carrot nose
    lg.setColor(0.1, 0.1, 0.12, alpha)
    lg.circle("fill", r * 0.72, -r * 0.24, 2.3)
    lg.circle("fill", r * 0.72, r * 0.24, 2.3)
    lg.setColor(1, 0.55, 0.15, alpha)
    lg.polygon("fill", r * 0.95, -3, r * 0.95, 3, r * 1.5, 0)
    lg.pop()
end

-- Gourd: a small pumpkin with a carved spooky face
local function drawGourd(e, alpha)
    local r = e.r
    local hop = abs(sin(e.hop))
    local squash = e.swingT > 0 and 0.75 or 1
    lg.push()
    lg.translate(e.x, e.y)
    lg.setColor(0, 0, 0, 0.25)
    lg.ellipse("fill", 2, r * 0.8, r * (1.1 - hop * 0.25), r * 0.45)
    lg.translate(0, -hop * 6)
    lg.rotate(e.angle)
    lg.scale(1 / squash, squash)
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.93, 0.48, 0.1, alpha) end
    lg.ellipse("fill", -r * 0.35, 0, r * 0.7, r)
    lg.ellipse("fill", r * 0.35, 0, r * 0.7, r)
    lg.setColor(1, 0.6, 0.18, alpha)
    lg.ellipse("fill", 0, 0, r * 0.8, r * 1.02)
    lg.setColor(0.6, 0.28, 0.05, alpha)
    lg.setLineWidth(1.5)
    lg.ellipse("line", 0, 0, r * 0.8, r * 1.02)
    -- stem (at the back)
    lg.setColor(0.3, 0.42, 0.15, alpha)
    lg.rectangle("fill", -r * 1.05, -3, r * 0.35, 6, 2, 2)
    -- glowing carved face (front)
    local glow = 0.75 + 0.25 * sin(menuTime * 9 + e.hop)
    lg.setColor(1, 0.9 * glow, 0.2, alpha)
    lg.polygon("fill", r * 0.25, -r * 0.55, r * 0.6, -r * 0.4, r * 0.25, -r * 0.2)
    lg.polygon("fill", r * 0.25, r * 0.55, r * 0.6, r * 0.4, r * 0.25, r * 0.2)
    lg.polygon("fill", r * 0.7, -r * 0.45, r * 0.9, -r * 0.2, r * 0.75, 0, r * 0.9, r * 0.2, r * 0.7, r * 0.45, r * 0.95, 0)
    lg.setLineWidth(1)
    lg.pop()
end

-- Bat: flapping wings, red eyes
local function drawBat(e, alpha)
    local r = e.r
    local flap = sin(e.flap)
    lg.push()
    lg.translate(e.x, e.y)
    lg.setColor(0, 0, 0, 0.18)
    lg.ellipse("fill", 4, 18, r * 1.4, r * 0.4)
    lg.rotate(e.angle)
    local col = e.hitFlash > 0 and { 1, 1, 1 } or { 0.16, 0.13, 0.2 }
    lg.setColor(col[1], col[2], col[3], alpha)
    local span = r * (1.6 + flap * 0.9)
    lg.polygon("fill", 0, -r * 0.3, -r * 0.6, -span, -r * 0.2, -span * 0.6, r * 0.1, -span * 0.75, r * 0.3, -r * 0.4)
    lg.polygon("fill", 0, r * 0.3, -r * 0.6, span, -r * 0.2, span * 0.6, r * 0.1, span * 0.75, r * 0.3, r * 0.4)
    lg.circle("fill", 0, 0, r * 0.65)
    lg.setColor(0.24, 0.2, 0.28, alpha)
    lg.polygon("fill", r * 0.3, -r * 0.45, r * 0.15, -r * 0.85, r * 0.05, -r * 0.4)
    lg.polygon("fill", r * 0.3, r * 0.45, r * 0.15, r * 0.85, r * 0.05, r * 0.4)
    lg.setColor(1, 0.15, 0.1, alpha)
    lg.circle("fill", r * 0.4, -r * 0.2, 1.6)
    lg.circle("fill", r * 0.4, r * 0.2, 1.6)
    lg.pop()
end

-- Witch: pointy hat, green face, broom, bubbling potion while cackling
local function drawWitch(e, alpha)
    local r = e.r
    local bob = sin(e.hover) * 2.5
    lg.push()
    lg.translate(e.x, e.y)
    lg.setColor(0, 0, 0, 0.25)
    lg.ellipse("fill", 3, r * 0.9, r * 1.1, r * 0.45)
    lg.translate(0, bob)
    lg.rotate(e.angle)
    -- broom
    lg.setColor(0.45, 0.3, 0.16, alpha)
    lg.setLineWidth(3)
    lg.line(-r * 1.6, r * 0.2, r * 1.2, r * 0.2)
    lg.setLineWidth(1)
    lg.setColor(0.75, 0.6, 0.3, alpha)
    lg.polygon("fill", -r * 1.5, r * 0.2, -r * 2.3, -r * 0.3, -r * 2.4, r * 0.7)
    -- robe
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.22, 0.12, 0.3, alpha) end
    lg.circle("fill", 0, 0, r)
    -- face
    lg.setColor(0.45, 0.7, 0.35, alpha)
    lg.circle("fill", r * 0.45, 0, r * 0.42)
    lg.setColor(1, 0.9, 0.2, alpha)
    lg.circle("fill", r * 0.65, -r * 0.15, 1.8)
    lg.circle("fill", r * 0.65, r * 0.15, 1.8)
    lg.setColor(0.35, 0.6, 0.25, alpha)
    lg.polygon("fill", r * 0.8, -2, r * 0.8, 2, r * 1.15, 1)
    -- pointy hat (brim + cone seen from above)
    lg.setColor(0.1, 0.07, 0.14, alpha)
    lg.circle("fill", -r * 0.05, 0, r * 0.82)
    lg.setColor(0.17, 0.1, 0.22, alpha)
    lg.polygon("fill", -r * 0.6, -r * 0.4, -r * 0.6, r * 0.4, -r * 1.3, r * 0.15)
    lg.setColor(0.6, 0.3, 0.8, alpha)
    lg.rectangle("fill", -r * 0.3, -r * 0.5, 3, r)
    -- potion in hand while casting
    if e.castT > 0 then
        lg.setColor(0.7, 0.25, 0.95, alpha)
        lg.circle("fill", r * 0.7, r * 0.95, 5)
        lg.setColor(0.9, 0.7, 1, alpha)
        lg.circle("fill", r * 0.6, r * 0.85, 1.5)
    end
    lg.pop()
end

local HP_COLORS = X.EN.hpColor

-- Bow Wielder: green cloak, hood and a drawn bow
function X.drawBowman(e, alpha)
    drawHumanoid(e.x, e.y, e.r, e.angle, { 0.3, 0.52, 0.24, alpha }, nil, e.hitFlash, 0, e.walkAnim, 0)
    lg.push()
    lg.translate(e.x, e.y)
    lg.rotate(e.angle)
    local r = e.r
    -- hood
    lg.setColor(0.2, 0.36, 0.16, alpha)
    lg.polygon("fill", -r * 0.9, -r * 0.55, r * 0.35, 0, -r * 0.9, r * 0.55)
    lg.circle("fill", -r * 0.15, 0, r * 0.55)
    -- bow (bends more while aiming)
    local draw = e.throwAnim > 0 and 1 or 0.35
    lg.setColor(0.5, 0.33, 0.18, alpha)
    lg.setLineWidth(3)
    lg.arc("line", "open", r * 0.55, 0, r * 0.95, -1.25, 1.25, 10)
    lg.setLineWidth(1)
    lg.setColor(0.9, 0.9, 0.85, alpha)
    local bx = r * 0.55 + cos(1.25) * r * 0.95
    local pull = r * 0.55 - draw * r * 0.5
    lg.line(bx, -sin(1.25) * r * 0.95, pull, 0, bx, sin(1.25) * r * 0.95)
    if e.throwAnim > 0 then
        lg.setColor(0.45, 0.32, 0.2, alpha)
        lg.line(pull, 0, pull + r * 1.3, 0)
    end
    -- quiver on the back
    lg.setColor(0.4, 0.26, 0.14, alpha)
    lg.rectangle("fill", -r * 1.05, -r * 0.6, r * 0.45, r * 0.9, 2, 2)
    lg.pop()
end

local function drawEnemy(e)
    if X.BOSSES[e.kind] then return end           -- drawn on top of everything (X.drawBossWorld)
    local alpha = e.spawnFade
    -- Vision cone for patrolling enemies (helps stealth play)
    if e.state == "patrol" and e.stunT <= 0 and dist(e.x, e.y, player.x, player.y) < 900 then
        local c = e.awareness > 0.05 and { 1, 0.75, 0.2 } or { 1, 1, 0.85 }
        lg.setColor(c[1], c[2], c[3], (0.05 + e.awareness * 0.12) * alpha)
        lg.arc("fill", e.x, e.y, e.vision * weatherVis(e.region) * 0.55, e.angle - e.fov, e.angle + e.fov, 24)
    end

    if e.kind == "gourd" then
        drawGourd(e, alpha)
    elseif e.kind == "bat" then
        drawBat(e, alpha)
    elseif e.kind == "witch" then
        drawWitch(e, alpha)
    elseif e.kind == "frozen" then
        drawYeti(e, alpha)
    elseif e.kind == "snowman" then
        drawSnowman(e, alpha)
    elseif e.kind == "bowman" then
        X.drawBowman(e, alpha)
    elseif X.DRAW[e.kind] then
        X.DRAW[e.kind](e, alpha)
    else
        local body = e.kind == "bandit" and { 0.72, 0.28, 0.2, alpha } or { 0.3, 0.55, 0.78, alpha }
        local hat = e.kind == "bandit" and { 0.18, 0.12, 0.09 } or nil
        drawHumanoid(e.x, e.y, e.r, e.angle, body, hat, e.hitFlash, e.kind == "bandit" and 16 or 6, e.walkAnim, e.muzzle)
        if e.kind == "scout" then
            -- scout bandana + binoculars
            lg.setColor(0.9, 0.85, 0.3, alpha)
            lg.circle("fill", e.x, e.y, e.r * 0.45)
            lg.setColor(0.12, 0.12, 0.12, alpha)
            local bx, by = e.x + cos(e.angle) * e.r * 0.8, e.y + sin(e.angle) * e.r * 0.8
            lg.circle("fill", bx + cos(e.angle + pi / 2) * 3, by + sin(e.angle + pi / 2) * 3, 3)
            lg.circle("fill", bx - cos(e.angle + pi / 2) * 3, by - sin(e.angle + pi / 2) * 3, 3)
        end
    end

    -- Status effects
    if e.frostT > 0 then
        lg.setColor(0.55, 0.85, 1, 0.3 * alpha)
        lg.circle("fill", e.x, e.y, e.r + 3)
        lg.setColor(0.85, 0.97, 1, 0.8 * alpha)
        local a = menuTime * 2 + e.x
        lg.polygon("fill", e.x + cos(a) * (e.r + 4), e.y + sin(a) * (e.r + 4) - 4,
            e.x + cos(a) * (e.r + 4) + 3, e.y + sin(a) * (e.r + 4),
            e.x + cos(a) * (e.r + 4), e.y + sin(a) * (e.r + 4) + 4,
            e.x + cos(a) * (e.r + 4) - 3, e.y + sin(a) * (e.r + 4))
    end
    if (e.burnT or 0) > 0 then
        for k = 0, 3 do
            local fl = sin(menuTime * 14 + k * 1.7)
            lg.setColor(1, 0.45 + 0.25 * fl, 0.1, 0.7)
            lg.circle("fill", e.x + cos(k * 1.57 + menuTime) * e.r * 0.6, e.y - e.r * 0.3 + fl * 3, 4 + fl)
        end
    end
    if (e.bubbleT or 0) > 0 then
        -- trapped in a bubble
        local s = e.r + 9 + sin(menuTime * 6) * 1.5
        lg.setColor(0.6, 0.85, 1, 0.3)
        lg.circle("fill", e.x, e.y, s)
        lg.setColor(0.9, 0.97, 1, 0.9)
        lg.setLineWidth(2)
        lg.circle("line", e.x, e.y, s)
        lg.setLineWidth(1)
        lg.setColor(1, 1, 1, 0.9)
        lg.circle("fill", e.x - s * 0.45, e.y - s * 0.45, 3)
    elseif e.stunT > 0 then
        local s = e.r + 7
        lg.setColor(0.7, 0.9, 1, 0.42)
        lg.rectangle("fill", e.x - s, e.y - s, s * 2, s * 2, 5, 5)
        lg.setColor(1, 1, 1, 0.85)
        lg.rectangle("line", e.x - s, e.y - s, s * 2, s * 2, 5, 5)
        lg.line(e.x - s + 4, e.y - s + 8, e.x - s + 12, e.y - s + 3)
        for k = 0, 2 do
            local a = menuTime * 4 + k * 2.09
            lg.setColor(0.8, 0.95, 1)
            lg.circle("fill", e.x + cos(a) * e.r, e.y - e.r - 12 + sin(a) * 4, 2.5)
        end
    elseif e.shockSlowT > 0 then
        lg.setColor(0.6, 0.85, 1, 0.6)
        lg.arc("line", "open", e.x, e.y, e.r + 6, menuTime * 5, menuTime * 5 + 2.5, 10)
    end

    -- Health bar
    if e.hp < e.maxHp or e.state ~= "patrol" then
        local w = 36
        local hc = HP_COLORS[e.kind]
        lg.setColor(0, 0, 0, 0.6)
        lg.rectangle("fill", e.x - w / 2 - 1, e.y - e.r - 14, w + 2, 6)
        lg.setColor(1, 0.9, 0.6, 0.9)
        lg.rectangle("fill", e.x - w / 2, e.y - e.r - 13, w * e.hpLag / e.maxHp, 4)
        lg.setColor(hc[1], hc[2], hc[3])
        lg.rectangle("fill", e.x - w / 2, e.y - e.r - 13, w * max(0, e.hp) / e.maxHp, 4)
    end

    -- State indicator
    lg.setFont(fonts.medium)
    local iy = e.y - e.r - 40
    if e.stunT > 0 then
        -- stars already drawn
    elseif e.state == "patrol" and e.awareness > 0.05 then
        lg.setColor(1, 0.85, 0.2, 0.4 + e.awareness * 0.6)
        lg.printf("?", e.x - 20, iy, 40, "center")
        lg.setColor(0, 0, 0, 0.5)
        lg.rectangle("fill", e.x - 12, iy + 28, 24, 3)
        lg.setColor(1, 0.85, 0.2)
        lg.rectangle("fill", e.x - 12, iy + 28, 24 * e.awareness, 3)
    elseif e.state == "hunt" then
        lg.setColor(1, 0.25, 0.2, e.canSee and 1 or 0.5)
        lg.printf("!", e.x - 20, iy, 40, "center")
    elseif e.state == "flee" then
        lg.setColor(0.4, 0.8, 1, 0.6 + sin(menuTime * 12) * 0.4)
        lg.printf("!!", e.x - 20, iy, 40, "center")
    end
end

-- Journal portraits: the real in-game drawing of each enemy, scaled up
function X.drawEnemyPortrait(kind, cx, cy, scale)
    local st = X.ESTATS[kind]
    local e = {
        kind = kind, x = 0, y = 0, r = st.r, angle = -pi / 2 + 0.5, hitFlash = 0, walkAnim = menuTime * 6, muzzle = 0,
        throwAnim = kind == "bowman" and 1 or 0, swingT = 0, castT = 0, hop = menuTime * 3, flap = menuTime * 10,
        wob = menuTime, hover = menuTime, spawnFade = 1, hidden = 0, stunT = 0, frostT = 0, state = "patrol",
        meleeCd = 1, throwCd = 1, fireCd = 1, awareness = 0, shockSlowT = 0, speedMul = 1,
    }
    local depth = lg.getStackDepth()
    lg.push()
    lg.translate(cx, cy)
    lg.scale(scale, scale)
    local ok = pcall(function()
        if kind == "gourd" then drawGourd(e, 1)
        elseif kind == "bat" then drawBat(e, 1)
        elseif kind == "witch" then drawWitch(e, 1)
        elseif kind == "frozen" then drawYeti(e, 1)
        elseif kind == "snowman" then drawSnowman(e, 1)
        elseif kind == "bowman" then X.drawBowman(e, 1)
        elseif X.DRAW and X.DRAW[kind] then X.DRAW[kind](e, 1)
        else
            drawHumanoid(0, 0, e.r, e.angle, kind == "bandit" and { 0.72, 0.28, 0.2, 1 } or { 0.3, 0.55, 0.78, 1 },
                kind == "bandit" and { 0.18, 0.12, 0.09 } or nil, 0, kind == "bandit" and 16 or 6, e.walkAnim, 0)
        end
    end)
    while lg.getStackDepth() > depth do lg.pop() end
    return ok
end

local function drawPlayer()
    local p = player
    if p.dead then
        local a = clamp(1 - p.deathTimer / 2, 0, 1)
        lg.setColor(0.5, 0.08, 0.06, 0.6)
        lg.circle("fill", p.x, p.y, p.r * 1.6 * (1 + p.deathTimer * 0.2))
        lg.setColor(0.25, 0.5, 0.35, a)
        lg.circle("fill", p.x, p.y, p.r)
        return
    end
    local gunLen = (WEAPONS[p.weapon].len or 15) - p.recoil * 5
    local flicker = p.iframes > 0 and 0.55 or 1
    -- Turtle Master shell (drawn under the player)
    if p.turtleT > 0 then
        local pulse = 0.5 + 0.5 * sin(menuTime * 4)
        local pts = {}
        for k = 0, 5 do
            local a = k * pi / 3 + menuTime * 0.5
            pts[#pts + 1] = p.x + cos(a) * (p.r + 10)
            pts[#pts + 1] = p.y + sin(a) * (p.r + 10)
        end
        lg.setColor(0.35, 0.8, 0.4, 0.25 + 0.1 * pulse)
        lg.polygon("fill", pts)
        lg.setColor(0.5, 1, 0.55, 0.8)
        lg.setLineWidth(2)
        lg.polygon("line", pts)
        lg.setLineWidth(1)
    end
    local body = p.chillT > 0 and { 0.45, 0.72, 0.8, flicker } or { 0.3, 0.68, 0.45, flicker }
    drawHumanoid(p.x, p.y, p.r, p.angle, body, { 0.48, 0.32, 0.16 }, p.hitFlash,
        gunLen, p.walkAnim, p.muzzle, p.weapon)
    if p.bootsOn then
        lg.setColor(0.9, 0.95, 1, 0.5)
        lg.circle("line", p.x, p.y, p.r + 4)
    end
    -- Cold Icicles aura on the gun
    if p.iciclesT > 0 then
        local gx, gy = p.x + cos(p.angle) * (p.r + gunLen), p.y + sin(p.angle) * (p.r + gunLen)
        lg.setColor(0.6, 0.9, 1, 0.5 + 0.3 * sin(menuTime * 10))
        lg.circle("fill", gx, gy, 5)
    end
    if p.chillT > 0 then
        lg.setColor(0.7, 0.92, 1, 0.5)
        lg.circle("line", p.x, p.y, p.r + 2)
    end
    -- Block shield arc
    if p.blocking then
        local a = 0.55 + p.blockFlash * 3
        lg.setLineWidth(5)
        lg.setColor(0.6, 0.85, 1, a)
        lg.arc("line", "open", p.x, p.y, p.r + 12, p.angle - math.rad(75), p.angle + math.rad(75), 20)
        lg.setLineWidth(2)
        lg.setColor(1, 1, 1, a * 0.6)
        lg.arc("line", "open", p.x, p.y, p.r + 16, p.angle - math.rad(60), p.angle + math.rad(60), 20)
        lg.setLineWidth(1)
    end
    -- Aim laser (subtle)
    lg.setColor(1, 0.4, 0.3, 0.12)
    lg.line(p.x + cos(p.angle) * 30, p.y + sin(p.angle) * 30, p.x + cos(p.angle) * 220, p.y + sin(p.angle) * 220)
end

-- Other players (multiplayer)
local PLAYER_COLORS = { { 0.3, 0.68, 0.45 }, { 0.35, 0.55, 0.95 }, { 0.75, 0.4, 0.9 }, { 0.95, 0.6, 0.25 },
                        { 0.9, 0.85, 0.3 }, { 0.3, 0.85, 0.85 }, { 0.9, 0.35, 0.45 }, { 0.6, 0.6, 0.6 }, { 0.8, 0.8, 0.8 } }
X.PLAYER_COLORS = PLAYER_COLORS
local function drawRemote(o)
    local col = PLAYER_COLORS[((o.id - 1) % #PLAYER_COLORS) + 1]
    if o.dead then
        lg.setColor(0.5, 0.08, 0.06, 0.5)
        lg.circle("fill", o.x, o.y, 20)
        lg.setColor(0.5, 0.5, 0.55)
        lg.rectangle("fill", o.x - 8, o.y - 14, 16, 22, 6, 6)
        lg.setColor(0.3, 0.3, 0.34)
        lg.line(o.x - 4, o.y - 6, o.x + 4, o.y - 6)
        lg.line(o.x, o.y - 10, o.x, o.y + 2)
    else
        if o.turtle then
            lg.setColor(0.35, 0.8, 0.4, 0.3)
            lg.circle("fill", o.x, o.y, o.r + 10, 6)
        end
        local gunLen = (WEAPONS[o.weapon] and WEAPONS[o.weapon].len or 15) - (o.recoil or 0) * 5
        drawHumanoid(o.x, o.y, o.r, o.angle, { col[1], col[2], col[3] }, { 0.42, 0.28, 0.14 }, o.hitFlash or 0,
            gunLen, o.walkAnim or 0, o.muzzle or 0, o.weapon)
        if o.blocking then
            lg.setLineWidth(4)
            lg.setColor(0.6, 0.85, 1, 0.6)
            lg.arc("line", "open", o.x, o.y, o.r + 12, o.angle - math.rad(75), o.angle + math.rad(75), 16)
            lg.setLineWidth(1)
        end
    end
    -- name tag + health
    lg.setFont(fonts.small)
    local name = o.name or ("Player " .. o.id)
    lg.setColor(0, 0, 0, 0.6)
    lg.printf(name, o.x - 79, o.y - o.r - 33, 160, "center")
    lg.setColor(col[1] * 0.5 + 0.5, col[2] * 0.5 + 0.5, col[3] * 0.5 + 0.5)
    lg.printf(name, o.x - 80, o.y - o.r - 34, 160, "center")
    if not o.dead then
        lg.setColor(0, 0, 0, 0.6)
        lg.rectangle("fill", o.x - 19, o.y - o.r - 14, 38, 6)
        lg.setColor(0.35, 0.9, 0.45)
        lg.rectangle("fill", o.x - 18, o.y - o.r - 13, 36 * clamp((o.hp or 0) / (o.maxHp or 100), 0, 1), 4)
    end
end

local function drawBox(b)
    local bob = sin(menuTime * 3 + b.bob) * 2
    lg.setColor(1, 0.85, 0.3, 0.15 + 0.1 * sin(menuTime * 4 + b.bob))
    lg.circle("fill", b.x, b.y, 26)
    lg.setColor(0, 0, 0, 0.25)
    lg.rectangle("fill", b.x - 13 + 4, b.y - 13 + 6, 26, 26, 3, 3)
    lg.setColor(0.62, 0.42, 0.2)
    lg.rectangle("fill", b.x - 13, b.y - 13 + bob, 26, 26, 3, 3)
    lg.setColor(0.42, 0.27, 0.12)
    lg.setLineWidth(2)
    lg.rectangle("line", b.x - 13, b.y - 13 + bob, 26, 26, 3, 3)
    lg.line(b.x - 13, b.y - 13 + bob, b.x + 13, b.y + 13 + bob)
    lg.setLineWidth(1)
    lg.setColor(1, 0.85, 0.3)
    lg.rectangle("fill", b.x - 4, b.y - 15 + bob, 8, 5)
    if b.frozen then
        lg.setColor(0.97, 0.99, 1, 0.95)
        lg.rectangle("fill", b.x - 14, b.y - 15 + bob, 28, 7, 3, 3)
    elseif b.spooky then
        lg.setColor(0.9, 0.9, 0.95, 0.55)
        lg.line(b.x - 13, b.y - 13 + bob, b.x - 3, b.y - 3 + bob)
        lg.line(b.x - 13, b.y - 5 + bob, b.x - 5, b.y - 13 + bob)
        lg.arc("line", "open", b.x - 13, b.y - 13 + bob, 7, 0, pi / 2, 6)
        lg.arc("line", "open", b.x - 13, b.y - 13 + bob, 11, 0, pi / 2, 6)
    end
end

local function drawFrozenChest(c)
    local pulse = 0.5 + 0.5 * sin(menuTime * 3)
    if not c.opened then
        lg.setColor(0.5, 0.8, 1, 0.12 + 0.12 * pulse)
        lg.circle("fill", c.x, c.y, 50 + pulse * 8)
        lg.setColor(0.7, 0.5, 1, 0.12)
        lg.circle("fill", c.x, c.y, 34)
    end
    lg.setColor(0, 0, 0, 0.25)
    lg.rectangle("fill", c.x - 22 + 5, c.y - 14 + 7, 44, 30, 4, 4)
    lg.setColor(0.32, 0.5, 0.72)
    lg.rectangle("fill", c.x - 22, c.y - 8, 44, 24, 4, 4)
    if c.opened then
        lg.setColor(0.12, 0.16, 0.25)
        lg.rectangle("fill", c.x - 19, c.y - 8, 38, 8)
        lg.setColor(0.55, 0.78, 0.96)
        lg.rectangle("fill", c.x - 22, c.y - 26, 44, 10, 4, 4)
    else
        lg.setColor(0.55, 0.78, 0.96)
        lg.rectangle("fill", c.x - 22, c.y - 16, 44, 12, 5, 5)
    end
    lg.setColor(0.88, 0.95, 1)
    lg.setLineWidth(2)
    lg.rectangle("line", c.x - 22, c.y - 8, 44, 24, 4, 4)
    lg.line(c.x - 10, c.y - 8, c.x - 10, c.y + 16)
    lg.line(c.x + 10, c.y - 8, c.x + 10, c.y + 16)
    lg.setLineWidth(1)
    if not c.opened then
        lg.setColor(0.75, 0.5, 1, 0.7 + 0.3 * pulse)
        lg.circle("fill", c.x, c.y - 2, 4)
    end
    if dist(c.x, c.y, player.x, player.y) < 240 then
        lg.setFont(fonts.small)
        lg.setColor(0, 0, 0, 0.6)
        lg.printf(c.opened and "FROZEN CHEST (empty)" or "FROZEN CHEST", c.x - 99, c.y - 49, 200, "center")
        lg.setColor(0.75, 0.9, 1)
        lg.printf(c.opened and "FROZEN CHEST (empty)" or "FROZEN CHEST", c.x - 100, c.y - 50, 200, "center")
    end
end

function drawWorld()
    local sw, sh = lg.getDimensions()
    local sx, sy = 0, 0
    if shake > 0 then sx, sy = randRange(-shake, shake), randRange(-shake, shake) end
    local z = X.camZoom or 1
    local hw, hh = sw / 2 / z, sh / 2 / z
    local l, t = cam.x - hw - 20, cam.y - hh - 20
    local r, b = cam.x + hw + 20, cam.y + hh + 20

    lg.push()
    lg.translate(floor(sw / 2 + sx), floor(sh / 2 + sy))
    lg.scale(z)
    lg.translate(-floor(cam.x), -floor(cam.y))

    drawGround(l, t, r, b)
    drawLakes(l, t, r, b)
    X.drawPools(l, t, r, b)
    drawDecor(l, t, r, b)

    -- building floors
    for _, f in ipairs(floors) do
        if f.x < r and f.x + f.w > l and f.y < b and f.y + f.h > t then
            if f.kind == "ice" then
                lg.setColor(0.7, 0.77, 0.85)
                lg.rectangle("fill", f.x, f.y, f.w, f.h)
                lg.setColor(0.62, 0.7, 0.8)
                for px = f.x + 36, f.x + f.w, 36 do lg.line(px, f.y, px, f.y + f.h) end
                for py = f.y + 36, f.y + f.h, 36 do lg.line(f.x, py, f.x + f.w, py) end
            elseif f.kind == "shrine" then
                lg.setColor(0.58, 0.64, 0.84)
                lg.rectangle("fill", f.x, f.y, f.w, f.h)
                local pulse = 0.5 + 0.5 * sin(menuTime * 2)
                lg.setColor(0.7, 0.55, 1, 0.25 + 0.2 * pulse)
                lg.setLineWidth(3)
                lg.circle("line", f.x + f.w / 2, f.y + f.h / 2, 80)
                lg.circle("line", f.x + f.w / 2, f.y + f.h / 2, 60)
                for k = 0, 5 do
                    local a = k * pi / 3 + menuTime * 0.2
                    lg.line(f.x + f.w / 2 + cos(a) * 60, f.y + f.h / 2 + sin(a) * 60,
                        f.x + f.w / 2 + cos(a) * 80, f.y + f.h / 2 + sin(a) * 80)
                end
                lg.setLineWidth(1)
            elseif f.kind == "shed" then
                -- the safe shed: planks, a rug, crates and a lantern
                lg.setColor(0.46, 0.32, 0.2)
                lg.rectangle("fill", f.x, f.y, f.w, f.h)
                lg.setColor(0.38, 0.26, 0.16)
                for px = f.x + 16, f.x + f.w, 16 do lg.line(px, f.y, px, f.y + f.h) end
                lg.setColor(0.55, 0.16, 0.14, 0.9)
                lg.rectangle("fill", f.x + f.w / 2 - 45, f.y + f.h / 2 - 28, 90, 56, 6, 6)
                lg.setColor(0.85, 0.65, 0.3, 0.8)
                lg.rectangle("line", f.x + f.w / 2 - 40, f.y + f.h / 2 - 23, 80, 46, 4, 4)
                lg.setColor(0.5, 0.33, 0.17)
                lg.rectangle("fill", f.x + 22, f.y + 22, 24, 22, 2, 2)
                lg.rectangle("fill", f.x + f.w - 46, f.y + 22, 24, 22, 2, 2)
                lg.setColor(0.33, 0.21, 0.1)
                lg.line(f.x + 22, f.y + 22, f.x + 46, f.y + 44)
                lg.line(f.x + f.w - 46, f.y + 22, f.x + f.w - 22, f.y + 44)
                local fl = 0.75 + 0.25 * sin(menuTime * 9)
                lg.setColor(1, 0.75, 0.3, 0.18 * fl)
                lg.circle("fill", f.x + f.w / 2, f.y + 30, 34)
                lg.setColor(1, 0.85, 0.4, fl)
                lg.circle("fill", f.x + f.w / 2, f.y + 30, 5)
                lg.setFont(fonts.tiny)
                lg.setColor(0.95, 0.9, 0.7, 0.75)
                lg.printf("SAFE SHED", f.x, f.y + f.h - 34, f.w, "center")
            elseif f.kind == "lair" then
                X.drawLairFloor(f)
            elseif f.kind == "gkfloor" then
                X.drawGKFloor(f)
            elseif f.kind == "stronghold" then
                lg.setColor(0.6, 0.53, 0.42)
                lg.rectangle("fill", f.x, f.y, f.w, f.h)
                lg.setColor(0.54, 0.47, 0.37)
                for px = f.x + 40, f.x + f.w, 40 do lg.line(px, f.y, px, f.y + f.h) end
                for py = f.y + 40, f.y + f.h, 40 do lg.line(f.x, py, f.x + f.w, py) end
            elseif f.kind == "crypt" then
                lg.setColor(0.27, 0.25, 0.3)
                lg.rectangle("fill", f.x, f.y, f.w, f.h)
                lg.setColor(0.22, 0.2, 0.25)
                for px = f.x + 30, f.x + f.w, 30 do lg.line(px, f.y, px, f.y + f.h) end
                for py = f.y + 30, f.y + f.h, 30 do lg.line(f.x, py, f.x + f.w, py) end
                lg.setColor(0.45, 0.1, 0.12, 0.35)
                lg.circle("line", f.x + f.w / 2, f.y + f.h / 2, 40)
            else
                lg.setColor(0.5, 0.38, 0.26)
                lg.rectangle("fill", f.x, f.y, f.w, f.h)
                lg.setColor(0.44, 0.33, 0.22)
                for py = f.y + 18, f.y + f.h, 18 do lg.line(f.x, py, f.x + f.w, py) end
            end
        end
    end

    -- decals (bodies / blood / melted snow)
    for _, d in ipairs(decals) do
        if d.x > l - 40 and d.x < r + 40 and d.y > t - 40 and d.y < b + 40 then
            local a = min(1, d.life / 5)
            if d.kind == "scorch" then
                lg.setColor(0.08, 0.06, 0.05, 0.55 * a)
                lg.circle("fill", d.x, d.y, d.r)
                lg.setColor(0.15, 0.1, 0.07, 0.4 * a)
                lg.circle("fill", d.x + 6, d.y - 4, d.r * 0.6)
            elseif d.kind == "puddle" then
                lg.setColor(0.5, 0.15, 0.7, 0.45 * a)
                lg.ellipse("fill", d.x, d.y, d.r * 1.4, d.r)
                lg.setColor(0.75, 0.4, 1, 0.5 * a)
                lg.circle("fill", d.x + cos(menuTime * 3 + d.a) * 6, d.y + sin(menuTime * 2 + d.a) * 3, 2.5)
            elseif d.kind == "gourd" then
                lg.setColor(0.85, 0.4, 0.08, 0.8 * a)
                for k = 0, 4 do lg.ellipse("fill", d.x + cos(d.a + k * 1.3) * 9, d.y + sin(d.a + k * 1.3) * 7, 5, 3.5) end
                lg.setColor(0.95, 0.85, 0.5, 0.8 * a)
                for k = 0, 5 do lg.circle("fill", d.x + cos(d.a * 2 + k) * 13, d.y + sin(d.a * 2 + k) * 10, 1.4) end
            elseif d.kind == "bat" or d.kind == "witch" then
                lg.setColor(0.35, 0.12, 0.45, 0.45 * a)
                lg.ellipse("fill", d.x, d.y, d.r * 1.4, d.r)
                if d.kind == "witch" then
                    lg.setColor(0.12, 0.08, 0.16, 0.9 * a)
                    lg.polygon("fill", d.x - 8, d.y + 4, d.x + 8, d.y + 4, d.x + cos(d.a) * 4, d.y - 14)
                end
            elseif d.kind == "frozen" or d.kind == "snowman" then
                lg.setColor(0.72, 0.82, 0.92, 0.6 * a)
                lg.ellipse("fill", d.x, d.y, d.r * 1.5, d.r)
                lg.setColor(0.97, 0.98, 1, 0.9 * a)
                lg.circle("fill", d.x + cos(d.a) * 5, d.y + sin(d.a) * 5, d.r * 0.6)
                if d.kind == "snowman" then
                    lg.setColor(1, 0.55, 0.15, a)
                    lg.polygon("fill", d.x + cos(d.a) * 12, d.y + sin(d.a) * 12 - 2, d.x + cos(d.a) * 12, d.y + sin(d.a) * 12 + 2,
                        d.x + cos(d.a) * 20, d.y + sin(d.a) * 20)
                end
            else
                lg.setColor(0.45, 0.07, 0.05, 0.55 * a)
                lg.ellipse("fill", d.x, d.y, d.r * 1.4, d.r)
                if d.kind == "bandit" then lg.setColor(0.4, 0.17, 0.12, 0.8 * a)
                else lg.setColor(0.2, 0.32, 0.45, 0.8 * a) end
                lg.circle("fill", d.x + cos(d.a) * 4, d.y + sin(d.a) * 4, d.r * 0.55)
            end
        end
    end

    for _, bx in ipairs(boxes) do
        if bx.x > l - 40 and bx.x < r + 40 and bx.y > t - 40 and bx.y < b + 40 then drawBox(bx) end
    end
    if frozenChest and frozenChest.x > l - 80 and frozenChest.x < r + 80 and frozenChest.y > t - 80 and frozenChest.y < b + 80 then
        drawFrozenChest(frozenChest)
    end

    -- SnowGRAVE charging circle
    for _, s in ipairs(snowgraves) do
        local p = 1 - s.t / s.maxT
        lg.setColor(0.9, 0.96, 1, 0.06 + 0.16 * p)
        lg.circle("fill", player.x, player.y, 450)
        lg.setColor(1, 1, 1, 0.3 + 0.5 * p)
        lg.setLineWidth(3)
        for k = 0, 23 do
            local a = k / 24 * 2 * pi + menuTime * 0.8
            lg.arc("line", "open", player.x, player.y, 450, a, a + 0.15, 4)
        end
        lg.setColor(0.75, 0.9, 1, 0.6 * p)
        for k = 0, 11 do
            local a = k * 0.5236 + hash(k, 3) * 0.4
            local len = 450 * p
            lg.line(player.x + cos(a) * 30, player.y + sin(a) * 30,
                player.x + cos(a + 0.08) * len * 0.5, player.y + sin(a + 0.08) * len * 0.5,
                player.x + cos(a) * len, player.y + sin(a) * len)
        end
        lg.setLineWidth(1)
    end

    -- particles that sit below characters (ghosts, dust)
    for _, p in ipairs(particles) do
        if p.ghost then
            lg.setColor(p.color[1], p.color[2], p.color[3], 0.35 * p.life / p.maxLife)
            lg.circle("fill", p.x, p.y, p.size)
        end
    end

    if not X.hideEnemies then
        for _, e in ipairs(enemies) do
            if not e.dead and e.hidden <= 0 and e.x > l - 300 and e.x < r + 300 and e.y > t - 300 and e.y < b + 300 then drawEnemy(e) end
        end
    end
    for _, o in pairs(MPS.others) do
        if o.ready and o.x > l - 100 and o.x < r + 100 and o.y > t - 100 and o.y < b + 100 then drawRemote(o) end
    end
    drawPlayer()

    -- walls drawn above characters' shadows for a slight depth effect (only nearby ones, via the grid)
    local wbuf, wn = WG.query(l - 40, t - 40, r - l + 80, b - t + 80, WG.buf3)
    for i = 1, wn do
        local w = wbuf[i]
        if w.x < r + 40 and w.x + w.w > l - 40 and w.y < b + 40 and w.y + w.h > t - 40 then drawWall(w) end
    end

    -- sealed gate labels
    for _, g in ipairs(X.gates()) do
        if not g.open and dist(player.x, player.y, g.x, g.y) < 500 then
            lg.setFont(fonts.normal)
            local txt = string.format("%s IS SEALED  -  %d / %d kills", g.name, min(world.kills, g.kills), g.kills)
            if g.key then txt = txt .. (world.hasKey and "  +  KEY" or "  +  the Gatekeeper's key") end
            local tx, ty = g.x - 250, g.y - 40 - K.GATE_T / 2
            if g.vertical then tx, ty = g.x - 560, g.y - 12 end
            lg.setColor(0, 0, 0, 0.6)
            lg.printf(txt, tx + 1, ty + 1, 500, "center")
            lg.setColor(g.col)
            lg.printf(txt, tx, ty, 500, "center")
        end
    end

    -- projectiles
    lg.setLineWidth(3)
    for _, bl in ipairs(bullets) do
        if bl.kind == "rocket" then
            local a = atan2(bl.vy, bl.vx)
            lg.push()
            lg.translate(bl.x, bl.y)
            lg.rotate(a)
            lg.setColor(1, 0.6, 0.2, 0.6 + 0.4 * sin(menuTime * 40))
            lg.circle("fill", -12, 0, 5)
            lg.setColor(0.36, 0.42, 0.24)
            lg.rectangle("fill", -10, -3.5, 16, 7, 2, 2)
            lg.setColor(0.75, 0.2, 0.15)
            lg.polygon("fill", 6, -3.5, 13, 0, 6, 3.5)
            lg.pop()
        elseif bl.kind == "missile" then
            local a = atan2(bl.vy, bl.vx)
            lg.push()
            lg.translate(bl.x, bl.y)
            lg.rotate(a)
            lg.setColor(0.5, 0.85, 1, 0.6 + 0.4 * sin(menuTime * 40))
            lg.circle("fill", -13, 0, 5)
            lg.setColor(0.85, 0.87, 0.9)
            lg.rectangle("fill", -11, -3, 18, 6, 2, 2)
            lg.setColor(0.3, 0.32, 0.36)
            lg.polygon("fill", -11, -3, -6, -3, -10, -7) lg.polygon("fill", -11, 3, -6, 3, -10, 7)
            lg.setColor(0.9, 0.15, 0.15)
            lg.polygon("fill", 7, -3, 14, 0, 7, 3)
            lg.pop()
        elseif (bl.owner == "player" or bl.owner == "remote") and X.drawShot(bl) then
            -- special looks (bubbles, bolts, plasma, flames...)
        elseif bl.owner == "player" or bl.owner == "remote" then
            if bl.icy then
                lg.setColor(0.6, 0.9, 1)
                lg.setLineWidth(4)
                lg.line(bl.x - bl.vx * 0.024, bl.y - bl.vy * 0.024, bl.x, bl.y)
                lg.setColor(1, 1, 1)
                lg.circle("fill", bl.x, bl.y, 2.5)
                lg.setLineWidth(3)
            else
                lg.setColor(1, 0.9, 0.45)
                lg.line(bl.x - bl.vx * 0.022, bl.y - bl.vy * 0.022, bl.x, bl.y)
            end
        elseif X.SHOT_SND[bl.kind] then
            X.drawEnemyShot(bl)
        elseif bl.kind == "face" then
            X.drawFace(bl)
        elseif bl.kind == "arrow" then
            local a = atan2(bl.vy, bl.vx)
            lg.setLineWidth(2)
            lg.setColor(0.45, 0.32, 0.2)
            lg.line(bl.x - cos(a) * 18, bl.y - sin(a) * 18, bl.x, bl.y)
            lg.setColor(0.8, 0.8, 0.85)
            lg.polygon("fill", bl.x + cos(a) * 5, bl.y + sin(a) * 5, bl.x + cos(a + 2.5) * 4, bl.y + sin(a + 2.5) * 4,
                bl.x + cos(a - 2.5) * 4, bl.y + sin(a - 2.5) * 4)
            lg.setColor(0.4, 0.75, 0.35)
            lg.line(bl.x - cos(a) * 18, bl.y - sin(a) * 18, bl.x - cos(a) * 13 + cos(a + 1.2) * 3, bl.y - sin(a) * 13 + sin(a + 1.2) * 3)
            lg.setLineWidth(3)
        elseif bl.kind == "icicle" then
            local a = atan2(bl.vy, bl.vx)
            lg.setColor(0.72, 0.92, 1)
            lg.polygon("fill", bl.x + cos(a) * 8, bl.y + sin(a) * 8,
                bl.x - cos(a) * 12 + cos(a + pi / 2) * 3.5, bl.y - sin(a) * 12 + sin(a + pi / 2) * 3.5,
                bl.x - cos(a) * 12 - cos(a + pi / 2) * 3.5, bl.y - sin(a) * 12 - sin(a + pi / 2) * 3.5)
            lg.setColor(1, 1, 1, 0.8)
            lg.line(bl.x + cos(a) * 6, bl.y + sin(a) * 6, bl.x - cos(a) * 8, bl.y - sin(a) * 8)
        elseif bl.kind == "potion" then
            local pr = clamp(bl.age / max(0.1, bl.land), 0, 1)
            local lift = sin(pr * pi) * 26
            lg.setColor(0, 0, 0, 0.2)
            lg.ellipse("fill", bl.x + 3, bl.y + 6, 6, 3)
            lg.setColor(0.65, 0.2, 0.95)
            lg.circle("fill", bl.x, bl.y - lift, 6)
            lg.setColor(0.45, 0.3, 0.2)
            lg.rectangle("fill", bl.x - 2, bl.y - lift - 10, 4, 5)
            lg.setColor(0.95, 0.8, 1, 0.8)
            lg.circle("fill", bl.x - 2, bl.y - lift - 2, 1.8)
            lg.setLineWidth(3)
        elseif bl.kind == "snowball" then
            local lift = sin(clamp((bl.age or 0) / 0.9, 0, 1) * pi) * 10
            lg.setColor(0, 0, 0, 0.2)
            lg.ellipse("fill", bl.x + 3, bl.y + 6, 6, 3)
            lg.setColor(0.98, 0.99, 1)
            lg.circle("fill", bl.x, bl.y - lift, 6.5)
            lg.setColor(0.72, 0.8, 0.9)
            lg.setLineWidth(1)
            lg.circle("line", bl.x, bl.y - lift, 6.5)
            lg.setLineWidth(3)
        else
            lg.setColor(1, 0.4, 0.3)
            lg.line(bl.x - bl.vx * 0.022, bl.y - bl.vy * 0.022, bl.x, bl.y)
        end
    end
    lg.setLineWidth(1)

    for _, p in ipairs(particles) do
        if not p.ghost then
            local a = clamp(p.life / p.maxLife, 0, 1)
            lg.setColor(p.color[1], p.color[2], p.color[3], a)
            lg.circle("fill", p.x, p.y, p.size * (0.5 + a * 0.5))
        end
    end

    X.drawSpecials()

    -- laser beams
    for _, bm in ipairs(X.beams) do
        local a = clamp(bm.life / 0.14, 0, 1)
        local col = bm.col or { 1, 0.25, 0.35 }
        lg.setLineWidth(9 * a + 2)
        lg.setColor(col[1], col[2], col[3], 0.35 * a)
        lg.line(bm.x1, bm.y1, bm.x2, bm.y2)
        lg.setLineWidth(3)
        lg.setColor(1, 0.9, 0.95, a)
        lg.line(bm.x1, bm.y1, bm.x2, bm.y2)
        lg.setLineWidth(1)
    end

    for _, rg in ipairs(rings) do
        local c = rg.col or { 0.4, 0.8, 1 }
        lg.setLineWidth(3)
        lg.setColor(c[1], c[2], c[3], rg.life / (rg.maxLife or 1) * 0.7)
        lg.circle("line", rg.x, rg.y, rg.r)
        lg.setLineWidth(1)
    end
    X.drawSmokes()

    for _, tx in ipairs(texts) do
        local a = clamp(tx.life / tx.maxLife * 1.5, 0, 1)
        lg.setFont(tx.big and fonts.dmgBig or fonts.dmg)
        lg.setColor(0, 0, 0, a * 0.7)
        lg.printf(tx.text, tx.x - 79, tx.y + 1, 160, "center")
        lg.setColor(tx.color[1], tx.color[2], tx.color[3], a)
        lg.printf(tx.text, tx.x - 80, tx.y, 160, "center")
    end

    lg.pop()
end
end

------------------------------------------------------------------------------
-- Drawing: HUD
------------------------------------------------------------------------------
local drawHUD, drawBanner, drawWeather, drawCrosshair, drawVignette
do
local MINIMAP_COLORS = X.EN.mapColor

local function drawMinimap(x, y, size)
    local range = 2600
    local scale = size / range
    local function toMap(wx, wy)
        return x + size / 2 + (wx - player.x) * scale, y + size / 2 + (wy - player.y) * scale
    end
    panel(x - 6, y - 6, size + 12, size + 30)
    local scx, scy = lg.transformPoint(x, y)
    local scx2, scy2 = lg.transformPoint(x + size, y + size)
    lg.setScissor(scx, scy, scx2 - scx, scy2 - scy)
    lg.setColor(0.2, 0.16, 0.12)
    lg.rectangle("fill", x, y, size, size)
    for id, c in pairs(X.MAP_COLORS) do
        local R = REGIONS[id]
        local rx, ry = toMap(R.x0, R.y0)
        lg.setColor(c)
        lg.rectangle("fill", rx, ry, (R.x1 - R.x0) * scale, (R.y1 - R.y0) * scale)
    end
    lg.setColor(0.6, 0.78, 0.92)
    for _, k in ipairs(lakes) do
        local lx, ly = toMap(k.x, k.y)
        lg.ellipse("fill", lx, ly, k.rx * scale, k.ry * scale)
    end
    lg.setColor(0.07, 0.2, 0.08)
    for _, k in ipairs(X.swampPools or {}) do
        local lx, ly = toMap(k.x, k.y)
        lg.ellipse("fill", lx, ly, k.rx * scale, k.ry * scale)
    end
    lg.setColor(1, 0.4, 0.05)
    for _, k in ipairs(X.lavaPools or {}) do
        local lx, ly = toMap(k.x, k.y)
        lg.ellipse("fill", lx, ly, k.rx * scale, k.ry * scale)
    end
    -- region bounds
    lg.setColor(0.25, 0.2, 0.15)
    lg.setLineWidth(2)
    for _, R in pairs(REGIONS) do
        local rx, ry = toMap(R.x0, R.y0)
        lg.rectangle("line", rx, ry, (R.x1 - R.x0) * scale, (R.y1 - R.y0) * scale)
    end
    lg.setLineWidth(1)
    local mbuf, mn = WG.query(player.x - range / 2, player.y - range / 2, range, range, WG.buf3)
    for i = 1, mn do
        local w = mbuf[i]
        if w.kind ~= "border" and not w.enemyOnly then
            if w.kind == "ice" or w.kind == "crystal" then lg.setColor(0.42, 0.58, 0.75)
            elseif w.kind == "shed" then lg.setColor(0.95, 0.75, 0.35)
            elseif w.kind == "fort" or w.kind == "tower" or w.kind == "keep" then lg.setColor(0.45, 0.85, 0.3)
            elseif w.kind == "lairgate" then lg.setColor(1, 0.5, 0.15)
            elseif w.kind:sub(1, 4) == "lair" then lg.setColor(0.6, 0.3, 0.75)
            elseif w.kind == "pine" then lg.setColor(0.2, 0.42, 0.26)
            elseif w.kind == "swampbush" or w.kind == "log" then lg.setColor(0.22, 0.45, 0.2)
            elseif w.kind == "mud" then lg.setColor(0.4, 0.24, 0.1)
            elseif w.kind == "bigshroom" then lg.setColor(0.8, 0.1, 0.12)
            elseif w.kind == "basalt" or w.kind == "basaltwall" or w.kind == "obsidian" then lg.setColor(0.12, 0.1, 0.1)
            elseif w.kind == "gkgate" then lg.setColor(1, 0.5, 0.15)
            elseif w.kind:sub(1, 2) == "gk" then lg.setColor(0.9, 0.35, 0.1)
            elseif w.kind == "snowrock" then lg.setColor(0.45, 0.47, 0.52)
            elseif w.kind:sub(1, 4) == "gate" then lg.setColor(0.9, 0.2, 0.2)
            elseif w.kind == "deadtree" or w.kind == "fence" then lg.setColor(0.1, 0.08, 0.1)
            elseif w.kind == "crypt" or w.kind == "grave" then lg.setColor(0.45, 0.42, 0.5)
            else lg.setColor(0.3, 0.2, 0.12) end
            local wx, wy = toMap(w.x, w.y)
            lg.rectangle("fill", wx, wy, max(1, w.w * scale), max(1, w.h * scale))
        end
    end
    -- the gates (green = open)
    for _, g in ipairs(X.gates()) do
        local gx, gy = toMap(g.x, g.y)
        if g.open then lg.setColor(0.3, 1, 0.5) else lg.setColor(1, 0.3, 0.3) end
        lg.circle("line", gx, gy, 5)
    end
    lg.setColor(1, 0.85, 0.3)
    for _, b in ipairs(boxes) do
        local mx, my = toMap(b.x, b.y)
        lg.rectangle("fill", mx - 2, my - 2, 4, 4)
    end
    -- the FROZEN CHEST only shows up once you are close
    if frozenChest and not frozenChest.opened and dist(player.x, player.y, frozenChest.x, frozenChest.y) < 650 then
        local cx, cy = toMap(frozenChest.x, frozenChest.y)
        lg.setColor(0.75, 0.55, 1, 0.6 + 0.4 * sin(menuTime * 6))
        lg.circle("fill", cx, cy, 4.5)
    end
    -- enemies (weather limits how far you can spot them)
    local vis = weatherVis(player.region)
    local spot = vis < 0.999 and 1100 * vis or math.huge
    for _, e in ipairs(enemies) do
        if not e.dead and e.hidden <= 0 and dist(e.x, e.y, player.x, player.y) < spot then
            local mx, my = toMap(e.x, e.y)
            local c = MINIMAP_COLORS[e.kind]
            lg.setColor(c[1], c[2], c[3])
            local rr = (e.state ~= "patrol") and (3 + sin(menuTime * 10)) or 2.5
            lg.circle("fill", mx, my, rr)
            if e.kind == "snowman" then lg.setColor(0.3, 0.35, 0.4) lg.circle("line", mx, my, rr) end
        end
    end
    for _, rg in ipairs(rings) do
        local mx, my = toMap(rg.x, rg.y)
        local c = rg.col or { 0.4, 0.8, 1 }
        lg.setColor(c[1], c[2], c[3], rg.life / (rg.maxLife or 1))
        lg.circle("line", mx, my, rg.r * scale)
    end
    if #snowgraves > 0 then
        lg.setColor(1, 1, 1, 0.6)
        lg.circle("line", x + size / 2, y + size / 2, 450 * scale)
    end
    -- the safe shed
    local shx, shy = toMap(X.SHED.x + X.SHED.w / 2, X.SHED.y + X.SHED.h / 2)
    lg.setColor(1, 0.85, 0.4)
    lg.polygon("fill", shx - 5, shy, shx, shy - 6, shx + 5, shy)
    lg.rectangle("fill", shx - 4, shy, 8, 5)
    -- teammates: a coloured arrow (pointing where they face); off the map it sits on the edge and points at them
    for _, o in pairs(MPS.others) do
        if o.ready and o.x then
            local ox, oy = toMap(o.x, o.y)
            local c = X.PLAYER_COLORS[((o.id - 1) % #X.PLAYER_COLORS) + 1]
            local m = 9
            local inside = ox >= x + m and ox <= x + size - m and oy >= y + m and oy <= y + size - m
            local a = o.angle or 0
            if not inside then
                local cx, cy = x + size / 2, y + size / 2
                a = atan2(oy - cy, ox - cx)
                -- slide along the ray from the centre until it hits the inner border
                local k = min((size / 2 - m) / max(1e-3, abs(ox - cx)), (size / 2 - m) / max(1e-3, abs(oy - cy)))
                ox, oy = cx + (ox - cx) * k, cy + (oy - cy) * k
            end
            local r = inside and 9 or 11
            local pts = { ox + cos(a) * r, oy + sin(a) * r, ox + cos(a + 2.4) * r * 0.75, oy + sin(a + 2.4) * r * 0.75,
                ox + cos(a - 2.4) * r * 0.75, oy + sin(a - 2.4) * r * 0.75 }
            if o.dead then lg.setColor(c[1] * 0.5, c[2] * 0.5, c[3] * 0.5, 0.8) else lg.setColor(c[1], c[2], c[3]) end
            lg.polygon("fill", pts)
            lg.setColor(0, 0, 0, 0.8)
            lg.setLineWidth(1.5)
            lg.polygon("line", pts)
            lg.setLineWidth(1)
            if not inside then
                lg.setFont(fonts.tiny)
                lg.setColor(c[1], c[2], c[3])
                local nm = tostring(o.name or ""):sub(1, 1):upper()
                lg.print(nm, ox - cos(a) * 15 - 3, oy - sin(a) * 15 - 7)
            end
        end
    end
    -- player arrow
    local px, py = x + size / 2, y + size / 2
    lg.setColor(1, 1, 1)
    lg.polygon("fill",
        px + cos(player.angle) * 7, py + sin(player.angle) * 7,
        px + cos(player.angle + 2.5) * 5, py + sin(player.angle + 2.5) * 5,
        px + cos(player.angle - 2.5) * 5, py + sin(player.angle - 2.5) * 5)
    lg.setColor(0, 0, 0, 0.6)
    lg.polygon("line",
        px + cos(player.angle) * 7, py + sin(player.angle) * 7,
        px + cos(player.angle + 2.5) * 5, py + sin(player.angle + 2.5) * 5,
        px + cos(player.angle - 2.5) * 5, py + sin(player.angle - 2.5) * 5)
    lg.setScissor()
    lg.setFont(fonts.tiny)
    setC(PAL.dim)
    lg.printf(string.format("X %d  Y %d", floor(player.x), floor(player.y)), x, y + size + 6, size, "center")
end

local function drawSpellBar(cx, y)
    local p = player
    local slotW, slotH, gap = 78, 64, 8
    local total = #SPELLS * slotW + (#SPELLS - 1) * gap
    local x0 = cx - total / 2
    for i, sp in ipairs(SPELLS) do
        local x = x0 + (i - 1) * (slotW + gap)
        local unlocked = spellUnlocked(sp)
        local afford = p.mp >= sp.cost
        local activeT, activeMax = 0, 1
        if sp.id == "turtle" then activeT, activeMax = p.turtleT, sp.duration
        elseif sp.id == "icicles" then activeT, activeMax = p.iciclesT, sp.duration
        elseif sp.id == "snowgrave" and #snowgraves > 0 then activeT, activeMax = snowgraves[1].t, snowgraves[1].maxT
        elseif sp.id == "blaze" then activeT, activeMax = p.blazeT or 0, sp.duration end

        lg.setColor(0, 0, 0, 0.35)
        lg.rectangle("fill", x + 3, y + 4, slotW, slotH, 8, 8)
        if activeT > 0 then lg.setColor(0.22, 0.42, 0.68, 0.92)
        elseif unlocked and afford then lg.setColor(0.14, 0.2, 0.34, 0.92)
        else lg.setColor(0.1, 0.09, 0.1, 0.85) end
        lg.rectangle("fill", x, y, slotW, slotH, 8, 8)
        if activeT > 0 then
            lg.setColor(0.5, 0.8, 1, 0.35)
            lg.rectangle("fill", x, y + slotH * (1 - activeT / activeMax), slotW, slotH * activeT / activeMax, 8, 8)
        end
        lg.setLineWidth(2)
        if unlocked and afford then lg.setColor(0.5, 0.75, 1) elseif unlocked then lg.setColor(0.35, 0.45, 0.65) else lg.setColor(0.35, 0.3, 0.3) end
        lg.rectangle("line", x, y, slotW, slotH, 8, 8)
        lg.setLineWidth(1)

        local cdl = sp.id == "cursed" and p.cursedCd or ((p.spellCds or {})[sp.id] or 0)
        if unlocked and cdl > 0 then
            lg.setColor(0, 0, 0, 0.55)
            lg.rectangle("fill", x, y, slotW, slotH * min(1, cdl / sp.cooldown), 8, 8)
        end
        lg.setFont(fonts.small)
        lg.setColor(0.9, 0.95, 1, unlocked and 1 or 0.45)
        lg.printf(sp.short, x, y + 20, slotW, "center")
        lg.setFont(fonts.tiny)
        if unlocked then
            if afford then lg.setColor(0.55, 0.75, 1) else lg.setColor(1, 0.45, 0.4) end
            lg.printf(activeT > 0 and string.format("%.1fs", activeT) or (cdl > 0 and formatTime(cdl) or (sp.cost .. " MP")), x, y + 44, slotW, "center")
        else
            -- lock icon
            lg.setColor(0.7, 0.65, 0.6, 0.8)
            lg.rectangle("fill", x + slotW / 2 - 6, y + 44, 12, 9, 2, 2)
            lg.setLineWidth(2)
            lg.arc("line", "open", x + slotW / 2, y + 44, 4.5, pi, 2 * pi, 8)
            lg.setLineWidth(1)
        end
    end
end

------------------------------------------------------------------------------
-- Drawing: the Guardian of the Hollow, its lair, its attacks and the boss HUD
------------------------------------------------------------------------------
do
-- jack-o'-lantern triangle (pointing at angle a)
local function tri(x, y, s, a)
    lg.polygon("fill", x + cos(a) * s, y + sin(a) * s, x + cos(a + 2.2) * s, y + sin(a + 2.2) * s,
        x + cos(a - 2.2) * s, y + sin(a - 2.2) * s)
end

-- The witch hat seen from above: brim, crown made of shrinking rings, a bent tip
-- with a little moon charm. k = size (radius of the brim)
local function drawHat(k, bend, necro, alpha, dorm)
    alpha = alpha or 1
    local function c(r, g, b, a)
        if dorm then local v = (r + g + b) / 3 lg.setColor(v * 0.8, v * 0.78, v * 0.9, (a or 1) * alpha)
        else lg.setColor(r, g, b, (a or 1) * alpha) end
    end
    -- the crown (center): rings get smaller and lean towards the bend
    local cr = k * 0.44
    c(0.13, 0.06, 0.18) lg.circle("fill", 0, 0, cr)
    -- hat band (glows green while casting the Necromancer)
    if necro then c(0.4, 1, 0.45, 0.35 + 0.25 * sin(menuTime * 12)) lg.circle("fill", 0, 0, cr * 1.18) end
    c(necro and 0.35 or 0.22, necro and 0.85 or 0.48, necro and 0.35 or 0.2)
    lg.setLineWidth(k * 0.07)
    lg.circle("line", 0, 0, cr * 0.93)
    lg.setLineWidth(1)
    -- golden buckle on the band
    c(0.95, 0.75, 0.25) lg.rectangle("fill", cr * 0.82, -k * 0.07, k * 0.1, k * 0.14, 2, 2)
    c(0.13, 0.06, 0.18) lg.rectangle("fill", cr * 0.85, -k * 0.035, k * 0.04, k * 0.07)
    for i = 1, 5 do
        local f = i / 6
        local off = f * f * k * 0.5
        local shade = 0.16 + 0.05 * (i % 2)
        c(shade, 0.07 + 0.02 * i, shade + 0.1)
        lg.circle("fill", cos(bend) * off, sin(bend) * off, cr * (1 - f * 0.8))
    end
    -- the bent, curly tip (the triangle in the sketch)
    local tx, ty = cos(bend) * k * 0.5, sin(bend) * k * 0.5
    local a2 = bend + 1.2 + 0.15 * sin(menuTime * 2)
    c(0.2, 0.09, 0.26)
    lg.polygon("fill", tx + cos(bend + pi / 2) * k * 0.09, ty + sin(bend + pi / 2) * k * 0.09,
        tx - cos(bend + pi / 2) * k * 0.09, ty - sin(bend + pi / 2) * k * 0.09,
        tx + cos(a2) * k * 0.36, ty + sin(a2) * k * 0.36)
    -- a little moon charm hanging from the tip
    local mx, my = tx + cos(a2) * k * 0.36, ty + sin(a2) * k * 0.36
    c(1, 0.9, 0.45) lg.circle("fill", mx, my, k * 0.05)
    c(0.2, 0.09, 0.26) lg.circle("fill", mx + k * 0.02, my - k * 0.015, k * 0.042)
end

local function drawBrim(k, dorm, alpha)
    alpha = alpha or 1
    local function c(r, g, b, a)
        if dorm then local v = (r + g + b) / 3 lg.setColor(v * 0.8, v * 0.78, v * 0.9, (a or 1) * alpha)
        else lg.setColor(r, g, b, (a or 1) * alpha) end
    end
    -- a slightly wavy, worn brim
    local pts = {}
    for i = 0, 35 do
        local a = i / 36 * 2 * pi
        local rr = k * (1 + 0.035 * sin(a * 5 + 1.3) + 0.02 * sin(a * 11))
        pts[#pts + 1] = cos(a) * rr
        pts[#pts + 1] = sin(a) * rr
    end
    c(0.15, 0.07, 0.21)
    local ok, tris = pcall(love.math.triangulate, pts)
    if ok then for _, t in ipairs(tris) do lg.polygon("fill", t) end else lg.circle("fill", 0, 0, k) end
    c(0.42, 0.24, 0.55)
    lg.setLineWidth(k * 0.045)
    lg.polygon("line", pts)
    -- folds in the fabric
    c(0.09, 0.04, 0.13, 0.9)
    lg.setLineWidth(2)
    for i = 0, 8 do
        local a = i * 0.7 + 0.3
        lg.arc("line", "open", 0, 0, k * 0.88, a, a + 0.28)
    end
    -- a stitched patch
    lg.push()
    lg.rotate(2.3)
    c(0.33, 0.2, 0.42) lg.rectangle("fill", k * 0.78, -k * 0.07, k * 0.15, k * 0.14, 2, 2)
    c(0.75, 0.65, 0.5)
    lg.setLineWidth(1.5)
    for j = 0, 3 do
        local y = -k * 0.06 + j * k * 0.04
        lg.line(k * 0.77, y, k * 0.8, y + k * 0.01)
        lg.line(k * 0.91, y, k * 0.94, y + k * 0.01)
    end
    lg.pop()
    lg.setLineWidth(1)
end
X.drawHatTop = function(k, bend, necro, alpha) drawBrim(k, false, alpha) drawHat(k, bend, necro, alpha) end

-- THE GUARDIAN. o = { h = jump height, dormant, hatOn, laugh, necro, flash, shake, eyes (0..1) }
function X.drawGuardian(cx, cy, r, ang, o)
    o = o or {}
    local h = o.h or 0
    local t = menuTime
    local dorm = o.dormant
    local s = 1 + h / 800                       -- higher in the air = closer to the camera
    local sx, sy = 0, 0
    if o.shake and o.shake > 0 then sx, sy = randRange(-o.shake, o.shake), randRange(-o.shake, o.shake) end
    local function c(rr, gg, bb, a)
        if dorm then local v = (rr + gg + bb) / 3 lg.setColor(v * 0.75, v * 0.72, v * 0.82, a or 1)
        else lg.setColor(rr, gg, bb, a or 1) end
    end
    -- shadow on the ground (shrinks while it is in the air)
    local sh = 1 - min(0.55, h / 650)
    lg.setColor(0, 0, 0, 0.38 * sh)
    lg.ellipse("fill", cx + 12, cy + r * 0.28, r * 1.35 * sh, r * 1.05 * sh)

    lg.push()
    lg.translate(cx + sx, cy - h + sy)
    lg.scale(s, s)
    local hatOn = o.hatOn ~= false
    -- 1) the brim of the witch hat, under the pumpkin (the blue circle in the sketch)
    if hatOn then drawBrim(r * 1.33, dorm) end

    -- 2) the pumpkin: 10 lobes, ribs, shading
    local wob = o.laugh and (1 + 0.05 * sin(t * 32)) or (1 + 0.012 * sin(t * 2.2))
    lg.push()
    lg.scale(wob, 2 - wob)
    local lobes = 10
    c(0.72, 0.3, 0.04)
    for k = 0, lobes - 1 do
        local a = k * 2 * pi / lobes + 0.15
        lg.circle("fill", cos(a) * r * 0.62, sin(a) * r * 0.62, r * 0.44)
    end
    for k = 0, lobes - 1 do
        local a = k * 2 * pi / lobes + 0.15
        c(0.95, 0.5, 0.1)
        lg.circle("fill", cos(a) * r * 0.6, sin(a) * r * 0.6, r * 0.39)
        -- highlight on each lobe (light from the top-left)
        c(1, 0.68, 0.3, 0.45)
        lg.circle("fill", cos(a) * r * 0.6 - r * 0.07, sin(a) * r * 0.6 - r * 0.08, r * 0.16)
    end
    c(0.98, 0.55, 0.13)
    lg.circle("fill", 0, 0, r * 0.72)
    -- ribs between the lobes
    c(0.66, 0.28, 0.04)
    lg.setLineWidth(max(2, r * 0.035))
    for k = 0, lobes - 1 do
        local a = (k + 0.5) * 2 * pi / lobes + 0.15
        local a2 = a + 0.08
        lg.line(cos(a) * r * 0.3, sin(a) * r * 0.3, cos(a2) * r * 0.66, sin(a2) * r * 0.66, cos(a) * r * 1.0, sin(a) * r * 1.0)
    end
    -- scars and cracks of an old pumpkin
    c(0.5, 0.2, 0.05, 0.8)
    lg.setLineWidth(2)
    lg.line(-r * 0.75, r * 0.2, -r * 0.62, r * 0.32, -r * 0.7, r * 0.42)
    lg.line(r * 0.35, -r * 0.8, r * 0.45, -r * 0.68, r * 0.38, -r * 0.6)
    lg.setLineWidth(1)
    lg.pop()

    -- 3) the face, on the side looking at you
    lg.push()
    lg.rotate(ang)
    local glow = dorm and 0 or (o.eyes or 1) * (0.82 + 0.18 * sin(t * 9))
    if o.laugh then glow = min(1, glow + 0.2 * abs(sin(t * 25))) end
    for sgn = -1, 1, 2 do
        local ex, ey = r * 0.62, sgn * r * 0.33
        local ea = pi + sgn * 0.5                     -- the eyes slant inwards = angry
        if glow > 0 then c(1, 0.8, 0.2, 0.22 * glow) lg.circle("fill", ex, ey, r * 0.24) end
        c(0.22, 0.07, 0.02) tri(ex, ey, r * 0.17, ea)
        if glow > 0 then
            lg.setColor(1, 0.92, 0.35, glow) tri(ex, ey, r * 0.11, ea)
            lg.setColor(1, 1, 0.8, glow) lg.circle("fill", ex - r * 0.02, ey, r * 0.03)
        end
    end
    -- a jagged grin near the front edge (opens wide when laughing)
    local open = o.laugh and (0.55 + 0.45 * abs(sin(t * 18))) or 0.3
    local ri, ro = r * 0.8, r * (0.88 + 0.1 * open)
    local n, a0, a1 = 10, -0.62, 0.62
    for i = 0, n - 1 do
        local aa, ab = a0 + (a1 - a0) * i / n, a0 + (a1 - a0) * (i + 1) / n
        c(0.22, 0.07, 0.02)
        lg.polygon("fill", cos(aa) * ri, sin(aa) * ri, cos(ab) * ri, sin(ab) * ri, cos(ab) * ro, sin(ab) * ro, cos(aa) * ro, sin(aa) * ro)
    end
    if glow > 0 then
        lg.setColor(1, 0.85, 0.25, glow)
        for i = 0, n - 1 do
            local aa, ab = a0 + (a1 - a0) * i / n + 0.01, a0 + (a1 - a0) * (i + 1) / n - 0.01
            local ri2, ro2 = ri + r * 0.02, ro - r * 0.02
            lg.polygon("fill", cos(aa) * ri2, sin(aa) * ri2, cos(ab) * ri2, sin(ab) * ri2, cos(ab) * ro2, sin(ab) * ro2, cos(aa) * ro2, sin(aa) * ro2)
        end
    end
    -- teeth
    c(0.95, 0.5, 0.1)
    for i = 1, n - 1, 2 do
        local a = a0 + (a1 - a0) * i / n
        lg.polygon("fill", cos(a - 0.05) * ri, sin(a - 0.05) * ri, cos(a + 0.05) * ri, sin(a + 0.05) * ri,
            cos(a) * (ri + (ro - ri) * 0.75), sin(a) * (ri + (ro - ri) * 0.75))
    end
    lg.pop()

    -- 4) the crown of the hat on top (or the stem when the hat is thrown)
    if hatOn then
        drawHat(r * 1.33, ang + pi * 0.85, o.necro, 1, dorm)
    else
        c(0.3, 0.38, 0.12)
        lg.circle("fill", 0, 0, r * 0.16)
        c(0.38, 0.48, 0.16)
        lg.circle("fill", -r * 0.03, -r * 0.03, r * 0.1)
        c(0.22, 0.34, 0.12)
        lg.setLineWidth(3)
        lg.arc("line", "open", r * 0.18, 0, r * 0.14, pi * 0.6, pi * 1.9)
        lg.setLineWidth(1)
    end
    -- curly vines and leaves peeking out
    c(0.2, 0.4, 0.15)
    lg.setLineWidth(3)
    for i = 0, 1 do
        local a = ang + pi * (0.55 + i * 0.9)
        local bx, by = cos(a) * r * 0.98, sin(a) * r * 0.98
        lg.arc("line", "open", bx, by, r * 0.1, a, a + 4)
        c(0.25, 0.5, 0.18)
        lg.ellipse("fill", bx + cos(a + 0.6) * r * 0.12, by + sin(a + 0.6) * r * 0.12, r * 0.1, r * 0.05)
        c(0.2, 0.4, 0.15)
    end
    lg.setLineWidth(1)

    -- 5) necromancer: green souls circling
    if o.necro then
        for i = 0, 5 do
            local a = t * 3 + i * pi / 3
            local rr = r * (1.45 + 0.1 * sin(t * 5 + i))
            lg.setColor(0.45, 1, 0.5, 0.35)
            lg.circle("fill", cos(a) * rr, sin(a) * rr, r * 0.12)
            lg.setColor(0.8, 1, 0.8, 0.85)
            lg.circle("fill", cos(a) * rr, sin(a) * rr, r * 0.05)
        end
    end
    -- hit flash
    if o.flash then
        lg.setColor(1, 1, 1, 0.45)
        lg.circle("fill", 0, 0, r * 1.02)
    end
    lg.pop()
end

-- the flying boomerang hat
local function drawFlyingHat(H, r)
    local k = r * 0.85
    lg.setColor(0, 0, 0, 0.25)
    lg.ellipse("fill", H.x + 10, H.y + 26, k * 0.9, k * 0.6)
    local sp = H.spin or 0
    lg.push()
    lg.translate(H.x, H.y - 20)
    lg.rotate(sp)
    lg.scale(1, 0.82 + 0.18 * sin(sp * 0.35))      -- tumbles a little while it spins
    drawBrim(k, false)
    -- glowing stripes on the brim make the spin easy to see
    lg.setColor(1, 0.6, 0.2, 0.75)
    lg.setLineWidth(5)
    for i = 0, 2 do
        local a = i * 2 * pi / 3
        lg.line(cos(a) * k * 0.5, sin(a) * k * 0.5, cos(a + 0.25) * k * 0.95, sin(a + 0.25) * k * 0.95)
    end
    lg.setLineWidth(1)
    drawHat(k, 0.6, false, 1, false)
    lg.pop()
    -- speed streaks
    lg.setColor(0.6, 0.4, 0.8, 0.35)
    lg.setLineWidth(3)
    lg.arc("line", "open", H.x, H.y - 20, k * 1.08, (H.spin or 0), (H.spin or 0) + 1.2)
    lg.arc("line", "open", H.x, H.y - 20, k * 1.08, (H.spin or 0) + pi, (H.spin or 0) + pi + 1.2)
    lg.setLineWidth(1)
end

-- spooky face projectile (like the Gourds)
function X.drawFace(bl)
    local a = atan2(bl.vy, bl.vx)
    local wob = sin(menuTime * 14 + bl.x * 0.05) * 2
    -- ghostly trail
    for i = 1, 3 do
        lg.setColor(1, 0.55, 0.1, 0.18 / i)
        lg.circle("fill", bl.x - cos(a) * i * 9, bl.y - sin(a) * i * 9 + wob, 12 - i * 2)
    end
    lg.setColor(1, 0.6, 0.15, 0.3)
    lg.circle("fill", bl.x, bl.y + wob, 16)
    lg.setColor(0.95, 0.5, 0.1)
    lg.circle("fill", bl.x, bl.y + wob, 11)
    lg.setColor(0.75, 0.32, 0.05)
    lg.setLineWidth(1.5)
    lg.line(bl.x - 4, bl.y - 10 + wob, bl.x - 5, bl.y + 10 + wob)
    lg.line(bl.x + 4, bl.y - 10 + wob, bl.x + 5, bl.y + 10 + wob)
    lg.setLineWidth(1)
    -- glowing eyes + grin
    lg.setColor(1, 0.95, 0.4)
    tri(bl.x - 4, bl.y - 2 + wob, 3, -pi / 2)
    tri(bl.x + 4, bl.y - 2 + wob, 3, -pi / 2)
    lg.arc("fill", bl.x, bl.y + 3 + wob, 5, 0.2, pi - 0.2)
    lg.setColor(0.3, 0.42, 0.15)
    lg.rectangle("fill", bl.x - 1.5, bl.y - 13 + wob, 3, 4)
end

-- lair walls: dark stone, towers with green fire, the gate, broken pillars
function X.drawLairWall(w)
    local k = w.kind
    if k ~= "lair" and k ~= "lairgate" and k ~= "lairtower" and k ~= "lairpillar" and k ~= "lairlow" then return false end
    lg.setColor(0, 0, 0, 0.32)
    lg.rectangle("fill", w.x + 7, w.y + 9, w.w, w.h)
    if k == "lairgate" then
        -- two iron doors sliding shut (BF.gateClose = 0..1 during the cutscene)
        local close = (X.BF and X.BF.A == X.LAIR) and X.BF.gateClose or 1
        local half = w.w / 2 * close
        for side = 0, 1 do
            local dx = side == 0 and w.x or w.x + w.w - half
            lg.setColor(0.18, 0.15, 0.2)
            lg.rectangle("fill", dx, w.y, half, w.h)
            lg.setColor(0.35, 0.3, 0.38)
            for bx = dx + 8, dx + half - 4, 16 do lg.rectangle("fill", bx, w.y + 2, 5, w.h - 4) end
            lg.setColor(0.45, 0.4, 0.48)
            lg.rectangle("fill", dx, w.y + w.h * 0.3, half, 5)
            lg.rectangle("fill", dx, w.y + w.h * 0.65, half, 5)
        end
        -- a glowing seal while it is closed
        if close >= 1 then
            local p = 0.6 + 0.4 * sin(menuTime * 3)
            lg.setColor(1, 0.5, 0.15, 0.6 * p)
            lg.circle("line", w.x + w.w / 2, w.y + w.h / 2, 18)
            lg.setColor(1, 0.6, 0.2, p)
            tri(w.x + w.w / 2 - 6, w.y + w.h / 2 - 3, 4, -pi / 2)
            tri(w.x + w.w / 2 + 6, w.y + w.h / 2 - 3, 4, -pi / 2)
        end
        return true
    end
    if k == "lairpillar" then
        local cx, cy = w.x + w.w / 2, w.y + w.h / 2
        lg.setColor(0.3, 0.26, 0.34)
        lg.rectangle("fill", w.x, w.y, w.w, w.h, 6, 6)
        lg.setColor(0.4, 0.36, 0.45)
        lg.circle("fill", cx, cy, w.w * 0.4)
        lg.setColor(0.32, 0.28, 0.36)
        lg.circle("line", cx, cy, w.w * 0.3)
        lg.setColor(0.2, 0.17, 0.24)
        lg.line(cx - w.w * 0.3, cy - 4, cx, cy + 6, cx + w.w * 0.25, cy - 10)
        lg.setColor(0.3, 0.55, 0.3, 0.7)
        lg.circle("fill", w.x + 8, w.y + w.h - 10, 7)
        lg.circle("fill", w.x + 16, w.y + w.h - 6, 5)
        return true
    end
    if k == "lairlow" then
        lg.setColor(0.33, 0.28, 0.36)
        lg.rectangle("fill", w.x, w.y, w.w, w.h, 4, 4)
        lg.setColor(0.24, 0.2, 0.28)
        for px = w.x + 30, w.x + w.w - 10, 30 do lg.line(px, w.y, px, w.y + w.h) end
        lg.setColor(0.45, 0.4, 0.5)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
        return true
    end
    -- stone walls / towers
    lg.setColor(0.24, 0.2, 0.28)
    lg.rectangle("fill", w.x, w.y, w.w, w.h)
    lg.setColor(0.17, 0.14, 0.21)
    for py = w.y + 18, w.y + w.h - 2, 18 do lg.line(w.x, py, w.x + w.w, py) end
    local row = 0
    for py = w.y, w.y + w.h - 2, 18 do
        local off = (row % 2) * 18
        for px = w.x + 36 - off, w.x + w.w - 2, 36 do lg.line(px, py, px, min(py + 18, w.y + w.h)) end
        row = row + 1
    end
    lg.setColor(0.36, 0.3, 0.42)
    lg.rectangle("fill", w.x, w.y, w.w, 5)
    -- purple moss
    lg.setColor(0.42, 0.22, 0.5, 0.6)
    for i = 0, 3 do
        local mx = w.x + ((i * 97 + w.x * 0.37) % max(1, w.w))
        local my = w.y + ((i * 53 + w.y * 0.21) % max(1, w.h))
        lg.circle("fill", mx, my, 6 + i % 3 * 2)
    end
    if k == "lairtower" then
        lg.setColor(0.32, 0.27, 0.38)
        lg.rectangle("line", w.x + 6, w.y + 6, w.w - 12, w.h - 12)
        -- green flame of the torch
        local cx, cy = w.x + w.w / 2, w.y + w.h / 2
        local fl = 0.7 + 0.3 * sin(menuTime * 13 + w.x)
        lg.setColor(0.4, 1, 0.45, 0.2 * fl)
        lg.circle("fill", cx, cy, 34)
        lg.setColor(0.45, 1, 0.5, fl)
        lg.circle("fill", cx, cy, 10 * fl)
        lg.setColor(0.9, 1, 0.9, fl)
        lg.circle("fill", cx, cy, 4)
    end
    return true
end

-- the lair floor: dark purple flagstones and a rune circle where the Guardian sleeps
function X.drawLairFloor(f)
    lg.setColor(0.33, 0.15, 0.34)
    lg.rectangle("fill", f.x, f.y, f.w, f.h)
    lg.setColor(0.27, 0.11, 0.28)
    lg.setLineWidth(2)
    for px = f.x + 110, f.x + f.w, 110 do lg.line(px, f.y, px, f.y + f.h) end
    for py = f.y + 110, f.y + f.h, 110 do lg.line(f.x, py, f.x + f.w, py) end
    lg.setLineWidth(1)
    -- cracked stones
    lg.setColor(0.22, 0.08, 0.23)
    for i = 0, 24 do
        local x = f.x + (i * 389) % f.w
        local y = f.y + (i * 617) % f.h
        lg.line(x, y, x + 22, y + 14, x + 30, y + 40)
    end
    local L = X.LAIR
    if L then
        local p = 0.6 + 0.4 * sin(menuTime * 1.5)
        lg.setColor(0.75, 0.35, 0.9, 0.25 + 0.15 * p)
        lg.setLineWidth(4)
        lg.circle("line", L.bx, L.by, 380)
        lg.circle("line", L.bx, L.by, 330)
        lg.setLineWidth(2)
        for i = 0, 11 do
            local a = i * pi / 6 + menuTime * 0.05
            local x, y = L.bx + cos(a) * 355, L.by + sin(a) * 355
            lg.line(x - 8, y - 8, x + 8, y + 8)
            lg.line(x - 8, y + 8, x, y)
        end
        lg.setLineWidth(1)
        -- scattered bones
        lg.setColor(0.85, 0.82, 0.72, 0.8)
        for i = 0, 9 do
            local x = L.ix + 140 + (i * 431) % (L.iw - 280)
            local y = L.iy + 160 + (i * 277) % (L.ih - 320)
            lg.rectangle("fill", x, y, 22, 4, 2, 2)
            lg.circle("fill", x, y + 2, 4) lg.circle("fill", x + 22, y + 2, 4)
        end
    end
end

-- boss, hat, landing marker and labels (world coordinates, drawn above the walls)
function X.drawBossWorld()
    local L = X.LAIR
    if not L then return end
    local BF = X.BF
    local r = X.ESTATS.guardian.r
    -- the gate label
    local gd = dist(me.x, me.y, L.gx, L.gy)
    if gd < 700 and not BF then
        lg.setFont(fonts.normal)
        local txt = world.lairOpen and "THE GUARDIAN'S LAIR" or "THE GUARDIAN'S LAIR IS SEALED"
        lg.setColor(0, 0, 0, 0.6)
        lg.printf(txt, L.gx - 299, L.gy - 79, 600, "center")
        lg.setColor(1, 0.6, 0.25)
        lg.printf(txt, L.gx - 300, L.gy - 80, 600, "center")
    end
    -- open doors pushed to the sides
    if L.gate.off then
        lg.setColor(0.18, 0.15, 0.2)
        lg.rectangle("fill", L.gate.x - 6, L.gate.y + L.gate.h, 14, 60)
        lg.rectangle("fill", L.gate.x + L.gate.w - 8, L.gate.y + L.gate.h, 14, 60)
    end
    X.drawGatekeeperWorld()
    if BF and BF.kind == "gatekeeper" then return end
    if not BF or BF.kind ~= "guardian" then
        -- the Guardian sleeps until someone walks in (a grey, still statue). Not in Endless mode.
        if not X.endless and (dist(me.x, me.y, L.bx, L.by) < 1600 or X.cut) then
            X.drawGuardian(L.bx, L.by, r, -pi / 2, { dormant = true })
            lg.setFont(fonts.medium)
            lg.setColor(0.8, 0.7, 1, 0.5 + 0.3 * sin(menuTime * 2))
            lg.print("z", L.bx + r * 0.9, L.by - r * 1.2 - (menuTime * 20) % 30)
            lg.print("z", L.bx + r * 1.1, L.by - r * 1.5 - (menuTime * 20 + 15) % 30)
        end
        return
    end
    local g = X.bossEntity()
    local ph = BF.ph
    -- landing marker while it is in the air
    if ph == "air" and BF.jtx then
        local p = 0.5 + 0.5 * sin(menuTime * 16)
        lg.setColor(1, 0.15, 0.1, 0.18 + 0.12 * BF.pt)
        lg.circle("fill", BF.jtx, BF.jty, (r + 30) * (0.5 + 0.5 * BF.pt))
        lg.setColor(1, 0.25, 0.15, 0.6 + 0.4 * p)
        lg.setLineWidth(4)
        lg.circle("line", BF.jtx, BF.jty, r + 30)
        lg.line(BF.jtx - 30, BF.jty, BF.jtx + 30, BF.jty)
        lg.line(BF.jtx, BF.jty - 30, BF.jtx, BF.jty + 30)
        lg.setLineWidth(1)
    end
    if g then
        local h = 0
        if ph == "air" then h = sin(pi * clamp(BF.pt or 0, 0, 1)) * X.JUMP_H end
        local eyes = 1
        if X.cut and not X.cut.wake then eyes = 0 end
        X.drawGuardian(g.x, g.y, g.r, g.angle, {
            h = h, hatOn = BF.hatOn and not BF.done, laugh = ph == "laugh", necro = ph == "necro",
            flash = g.hitFlash > 0, shake = ph == "prep" and 5 or (ph == "laugh" and 2 or 0), eyes = eyes,
            dormant = X.cut and not X.cut.wake,
        })
        if ph == "prep" and rand() < 0.6 then
            spawnParticles(g.x + randRange(-g.r, g.r), g.y + g.r * randRange(0.2, 0.9), 1, { 0.4, 0.3, 0.35 }, 20, 90, 0.6, 5, -pi / 2, 0.8)
        end
        if ph == "laugh" then
            lg.setFont(fonts.large)
            local a = 0.6 + 0.4 * sin(menuTime * 20)
            lg.setColor(1, 0.75, 0.2, a)
            lg.print("HA", g.x - g.r * 1.2 + sin(menuTime * 9) * 8, g.y - g.r * 1.6)
            lg.print("HA", g.x + g.r * 0.6 + sin(menuTime * 11) * 8, g.y - g.r * 1.75)
        end
    end
    -- the boomerang hat
    if BF.hat then drawFlyingHat(BF.hat, r) end
end

-- THE BLAZE GATEKEEPER: a towering knight of obsidian and fire with a burning rod
function X.drawGatekeeper(x, y, r, ang, o)
    o = o or {}
    local t = menuTime
    local dorm = o.dormant
    local function c(rr, gg, bb, a)
        if o.flash then lg.setColor(1, 1, 1, a or 1) return end
        if dorm then local v = (rr + gg + bb) / 3 lg.setColor(v * 0.7, v * 0.68, v * 0.7, a or 1) return end
        lg.setColor(rr, gg, bb, a or 1)
    end
    local glow = dorm and 0 or (0.7 + 0.3 * sin(t * 6))
    -- shadow and heat aura
    lg.setColor(0, 0, 0, 0.35)
    lg.ellipse("fill", x + 8, y + r * 0.5, r * 1.3, r * 0.75)
    if not dorm then
        lg.setColor(1, 0.4, 0.05, 0.12 + 0.06 * sin(t * 4))
        lg.circle("fill", x, y, r * 1.9)
    end
    lg.push()
    lg.translate(x, y)
    lg.rotate(ang)
    -- shoulders / cape of embers
    c(0.25, 0.08, 0.05)
    lg.ellipse("fill", -r * 0.15, 0, r * 0.75, r * 1.05)
    -- armored body
    c(0.13, 0.09, 0.11)
    lg.circle("fill", 0, 0, r * 0.72)
    c(0.2, 0.14, 0.17)
    lg.circle("fill", -r * 0.08, -r * 0.1, r * 0.5)
    -- molten cracks in the armor
    if glow > 0 then
        lg.setColor(1, 0.45, 0.08, glow)
        lg.setLineWidth(3)
        lg.line(-r * 0.5, -r * 0.3, -r * 0.2, -r * 0.05, -r * 0.35, r * 0.3)
        lg.line(r * 0.1, r * 0.45, r * 0.3, r * 0.15, r * 0.15, -r * 0.2)
        lg.setLineWidth(1)
    end
    -- pauldrons with spikes
    for sgn = -1, 1, 2 do
        c(0.17, 0.11, 0.14)
        lg.circle("fill", 0, sgn * r * 0.72, r * 0.32)
        c(0.35, 0.3, 0.33)
        lg.polygon("fill", -r * 0.1, sgn * r * 0.9, r * 0.12, sgn * r * 1.25, r * 0.2, sgn * r * 0.85)
    end
    -- helmet with horns and burning eyes
    c(0.1, 0.07, 0.09)
    lg.circle("fill", r * 0.22, 0, r * 0.36)
    c(0.4, 0.35, 0.3)
    lg.polygon("fill", r * 0.05, -r * 0.3, -r * 0.35, -r * 0.65, r * 0.15, -r * 0.18)
    lg.polygon("fill", r * 0.05, r * 0.3, -r * 0.35, r * 0.65, r * 0.15, r * 0.18)
    if glow > 0 then
        lg.setColor(1, 0.75, 0.2, glow)
        lg.circle("fill", r * 0.42, -r * 0.12, r * 0.07)
        lg.circle("fill", r * 0.42, r * 0.12, r * 0.07)
    end
    -- mouth glow while spitting
    if o.spit and glow > 0 then
        lg.setColor(1, 0.6, 0.1, 0.9)
        lg.circle("fill", r * 0.55, 0, r * 0.12 + sin(t * 30) * 2)
    end
    -- the BLAZE ROD (swung while attacking)
    local swing = o.swing or 0
    lg.push()
    lg.translate(r * 0.15, r * 0.75)
    lg.rotate(-0.9 + swing * 2.2)
    c(0.25, 0.16, 0.1)
    lg.rectangle("fill", 0, -4, r * 1.7, 8, 3, 3)
    c(0.5, 0.42, 0.3)
    lg.rectangle("fill", r * 1.5, -7, r * 0.22, 14, 3, 3)
    if glow > 0 then
        local fl = 0.7 + 0.3 * sin(t * 18)
        lg.setColor(1, 0.45, 0.08, 0.5 * fl)
        lg.circle("fill", r * 1.75, 0, r * 0.35 * fl)
        lg.setColor(1, 0.85, 0.35, fl)
        lg.circle("fill", r * 1.75, 0, r * 0.15)
    end
    lg.pop()
    lg.pop()
    -- fire ring while spinning
    if o.swirl and not dorm then
        for i = 0, 7 do
            local a = t * 14 + i * pi / 4
            lg.setColor(1, 0.5 + 0.3 * (i % 2), 0.1, 0.7)
            lg.circle("fill", x + cos(a) * r * 1.4, y + sin(a) * r * 1.4, r * 0.2)
        end
    end
    if o.flash then
        lg.setColor(1, 1, 1, 0.4)
        lg.circle("fill", x, y, r * 0.8)
    end
end

-- the Gatekeeper's arena: label, dormant statue, the fight, the dropped key
function X.drawGatekeeperWorld()
    local A = X.GKA
    if not A then return end
    local BF = X.BF
    local r = X.ESTATS.gatekeeper.r
    if dist(me.x, me.y, A.gx, A.gy) < 700 and not (BF and BF.kind == "gatekeeper") then
        lg.setFont(fonts.normal)
        local txt = world.gkDead and "THE GATEKEEPER'S ARENA" or "THE BLAZE GATEKEEPER"
        lg.setColor(0, 0, 0, 0.6)
        lg.printf(txt, A.gx - 299, A.gy - 79, 600, "center")
        lg.setColor(1, 0.5, 0.15)
        lg.printf(txt, A.gx - 300, A.gy - 80, 600, "center")
    end
    if BF and BF.kind == "gatekeeper" and not BF.done then
        local g = X.bossEntity()
        if g then
            local ph = BF.ph
            local swing = 0
            if ph == "rod" then swing = clamp(BF.pt or 0, 0, 1) end
            X.drawGatekeeper(g.x, g.y, g.r, g.angle, {
                dormant = X.cut and not X.cut.wake, flash = g.hitFlash > 0, swing = swing,
                spit = ph == "spit", swirl = ph == "swirl",
            })
            if ph == "shield" then
                local t = menuTime
                for k = 0, 2 do
                    lg.setColor(1, 0.35 + 0.2 * k, 0.05, 0.25 - k * 0.05)
                    lg.circle("fill", g.x, g.y, g.r + 22 + k * 10 + 4 * sin(t * 10 + k))
                end
                lg.setLineWidth(4)
                lg.setColor(1, 0.75, 0.2, 0.85)
                lg.circle("line", g.x, g.y, g.r + 26 + 3 * sin(t * 14))
                lg.setLineWidth(1)
                for k = 0, 11 do
                    local a = t * 3 + k * pi / 6
                    lg.setColor(1, 0.5 + 0.3 * sin(t * 9 + k), 0.1, 0.8)
                    lg.circle("fill", g.x + cos(a) * (g.r + 30), g.y + sin(a) * (g.r + 30), 6 + 2 * sin(t * 12 + k))
                end
                if rand() < 0.6 then spawnParticles(g.x, g.y - g.r, 1, { 1, 0.6, 0.15 }, 30, 120, 0.5, 3) end
            end
            if ph == "swirl" and rand() < 0.8 then
                spawnParticles(g.x, g.y, 1, { 1, 0.5, 0.1 }, 80, 260, 0.4, 4)
            end
        end
    elseif not world.gkDead and dist(me.x, me.y, A.bx, A.by) < 1600 then
        X.drawGatekeeper(A.bx, A.by, r, pi / 2, { dormant = true })
    end
    X.drawKeyFly()
    -- the key to the Hollow
    local Ki = world.keyItem
    if Ki and not world.hasKey then
        local bob = sin(menuTime * 3) * 6
        lg.setColor(1, 0.8, 0.2, 0.25 + 0.15 * sin(menuTime * 5))
        lg.circle("fill", Ki.x, Ki.y, 34)
        lg.push()
        lg.translate(Ki.x, Ki.y + bob)
        lg.rotate(0.5)
        lg.setColor(1, 0.82, 0.25)
        lg.setLineWidth(5)
        lg.circle("line", -14, 0, 9)
        lg.line(-5, 0, 22, 0)
        lg.line(14, 0, 14, 9)
        lg.line(20, 0, 20, 7)
        lg.setLineWidth(1)
        lg.pop()
        lg.setFont(fonts.small)
        lg.setColor(1, 0.85, 0.4)
        lg.printf("KEY", Ki.x - 40, Ki.y - 52 + bob, 80, "center")
    end
end

function X.gatekeeperDeathFx(x, y)
    playSfx("boss_die", 0.1, 0.9)
    playSfx("explosion", 0.1, 1)
    addShake(16)
    spawnParticles(x, y, 80, { 1, 0.45, 0.08 }, 80, 480, 1.3, 7)
    spawnParticles(x, y, 40, { 0.15, 0.1, 0.12 }, 60, 320, 1.4, 6)
    rings[#rings + 1] = { x = x, y = y, r = 0, max = 500, life = 0.9, maxLife = 0.9, col = { 1, 0.5, 0.15 } }
    decals[#decals + 1] = { x = x, y = y, r = 90, a = rand() * 6, kind = "scorch", life = 60 }
end

-- cutscene: black bars and the title card
function X.drawCutUI()
    local sw, sh = lg.getDimensions()
    local C = X.cut
    if C.kind == "key" then
        local bar = min(1, C.t / 0.4, (X.KEYCUT_LEN - C.t) / 0.4) * 60
        lg.setColor(0, 0, 0, 1)
        lg.rectangle("fill", 0, 0, sw, bar)
        lg.rectangle("fill", 0, sh - bar, sw, bar)
        return
    end
    if C.kind == "fly" then
        local bar = min(1, C.t / 0.5, (X.FLY_LEN - C.t) / 0.5) * 70
        lg.setColor(0, 0, 0, 1)
        lg.rectangle("fill", 0, 0, sw, bar)
        lg.rectangle("fill", 0, sh - bar, sw, bar)
        local reg = X.flyRegion()
        local R = REGIONS[reg]
        if R and C.t > 1 and C.t < X.FLY_LEN - 2.5 then
            lg.setFont(fonts.large)
            lg.setColor(0, 0, 0, 0.7)
            lg.printf(R.name, 3, sh - 64 + 3, sw, "center")
            lg.setColor(R.col)
            lg.printf(R.name, 0, sh - 64, sw, "center")
        end
        if C.t > 1.2 and C.t < 4 then
            lg.setFont(fonts.medium)
            lg.setColor(0.85, 0.55, 1, min(1, (C.t - 1.2) / 0.4, (4 - C.t) / 0.4))
            lg.printf("THE HAUNTED HOLLOW HAS OPENED", 0, 22, sw, "center")
        end
        return
    end
    local bar = min(1, C.t / 0.5) * 80
    lg.setColor(0, 0, 0, 1)
    lg.rectangle("fill", 0, 0, sw, bar)
    lg.rectangle("fill", 0, sh - bar, sw, bar)
    local t = C.t - 3.2
    if t > 0 then
        local a = min(1, t / 0.4) * min(1, (5.0 - C.t) / 0.4)
        local yy = sh - 80 - 96
        lg.setFont(fonts.large)
        lg.setColor(0, 0, 0, 0.75 * a)
        local kind = X.BF and X.BF.kind or "guardian"
        lg.printf(X.BOSS_NAMES[kind], 3, yy + 3, sw, "center")
        lg.setColor(1, 0.75, 0.2, a)
        lg.printf(X.BOSS_NAMES[kind], 0, yy, sw, "center")
        lg.setFont(fonts.normal)
        lg.setColor(0.9, 0.8, 1, a)
        lg.printf(X.BOSS_SUBS[kind], 0, yy + 50, sw, "center")
    elseif C.t > 1.3 and C.t < 2.6 then
        lg.setFont(fonts.medium)
        lg.setColor(1, 0.5, 0.35, min(1, (C.t - 1.3) / 0.3))
        lg.printf("There is no way back...", 0, sh - 64, sw, "center")
    end
end

-- the boss HUD (like the sketch): boss name + HP on top, your HP + MP at the bottom
function X.drawBossHUD()
    local sw, sh = lg.getDimensions()
    local BF = X.BF
    local g = X.bossEntity()
    local p = me
    -- boss name and HP bar
    shadowText(BF.name or "", 0, 12, sw, "center", { 1, 0.78, 0.2 }, fonts.large)
    local bw = min(660, sw - 80)
    local bx, by = sw / 2 - bw / 2, 60
    lg.setColor(0, 0, 0, 0.55)
    lg.rectangle("fill", bx - 4, by - 4, bw + 8, 32, 6, 6)
    lg.setColor(0.3, 0.02, 0.05)
    lg.rectangle("fill", bx, by, bw, 24, 4, 4)
    if g then
        local mh = max(1, g.maxHp)
        lg.setColor(1, 0.85, 0.5, 0.8)
        lg.rectangle("fill", bx, by, bw * clamp(g.hpLag / mh, 0, 1), 24, 4, 4)
        lg.setColor(0.66, 0.02, 0.1)
        lg.rectangle("fill", bx, by, bw * clamp(g.hp / mh, 0, 1), 24, 4, 4)
        lg.setColor(0.85, 0.12, 0.2)
        lg.rectangle("fill", bx, by, bw * clamp(g.hp / mh, 0, 1), 7, 4, 4)
        lg.setFont(fonts.small)
        lg.setColor(1, 0.95, 0.9)
        lg.print("BOSS HP", bx + 12, by + 4)
        lg.printf(string.format("%d / %d", max(0, math.ceil(g.hp)), mh), bx, by + 4, bw - 12, "right")
    end
    -- what it is doing (helps you react)
    local warn = BF.ph == "prep" and "It's about to JUMP - get ready to dash!" or
        (BF.ph == "necro" and "NECROMANCER - the Gourds rise again!" or nil)
    if warn then
        shadowText(warn, 0, by + 34, sw, "center", { 1, 0.5 + 0.3 * sin(menuTime * 12), 0.3 }, fonts.small)
    end

    -- your HP and MP
    local pw = min(540, sw - 300)
    local px, py = sw / 2 - pw / 2, sh - 96
    lg.setColor(0, 0, 0, 0.5)
    lg.rectangle("fill", px - 4, py - 4, pw + 8, 50, 6, 6)
    lg.setColor(0.35, 0.05, 0.05)
    lg.rectangle("fill", px, py, pw, 22, 4, 4)
    lg.setColor(1, 0.85, 0.5, 0.7)
    lg.rectangle("fill", px, py, pw * clamp(p.hpLag / p.maxHp, 0, 1), 22, 4, 4)
    lg.setColor(0.93, 0.15, 0.15)
    lg.rectangle("fill", px, py, pw * clamp(p.hp / p.maxHp, 0, 1), 22, 4, 4)
    lg.setFont(fonts.small)
    lg.setColor(1, 1, 1)
    lg.print("HP", px + 10, py + 3)
    lg.printf(string.format("%d/%d", math.ceil(p.hp), p.maxHp), px, py + 3, pw - 10, "right")
    lg.setColor(0.12, 0.12, 0.3)
    lg.rectangle("fill", px, py + 27, pw, 14, 4, 4)
    lg.setColor(0.27, 0.3, 0.85)
    lg.rectangle("fill", px, py + 27, pw * clamp(p.mp / K.MP_MAX, 0, 1), 14, 4, 4)
    lg.setFont(fonts.tiny)
    lg.setColor(1, 1, 1)
    lg.print("MP", px + 10, py + 27)
    lg.printf(string.format("%d/%d", floor(p.mp), K.MP_MAX), px, py + 27, pw - 10, "right")
    -- weapon & ammo on the right, hearts on the left (multiplayer)
    X.drawHotbarMini(p, px + pw + 18, py)
    if MPS.online then
        for i = 1, 3 do X.drawHeart(px - 104 + (i - 1) * 32, py + 18, 12, i <= (p.lives or 3)) end
    end
    -- status line above the bars
    local st = {}
    if (p.quakeT or 0) > 0 then st[#st + 1] = string.format("EARTHQUAKE -10%% speed %.1fs", p.quakeT) end
    if p.chillT > 0 then st[#st + 1] = "Chilled" end
    if p.poisonT > 0 then st[#st + 1] = "Poisoned" end
    local dashReady = p.dashCd <= 0 and p.stamina >= 25
    st[#st + 1] = dashReady and "DASH READY [SPACE]" or "dash..."
    shadowText(table.concat(st, "   |   "), 0, py - 26, sw, "center",
        (p.quakeT or 0) > 0 and { 1, 0.6, 0.3 } or (dashReady and { 0.6, 0.9, 1 } or { 0.6, 0.6, 0.6 }), fonts.small)
end

-- the Guardian bursts apart (every machine)
function X.guardianDeathFx(x, y)
    playSfx("boss_die", 0, 1)
    playSfx("explosion", 0.1, 1)
    addShake(20)
    spawnParticles(x, y, 90, { 1, 0.5, 0.1 }, 80, 520, 1.4, 8)
    spawnParticles(x, y, 50, { 1, 0.85, 0.3 }, 40, 300, 1.0, 5)
    spawnParticles(x, y, 40, { 0.2, 0.08, 0.28 }, 60, 360, 1.6, 7)
    spawnParticles(x, y, 30, { 0.45, 1, 0.45 }, 30, 200, 2.0, 4)
    rings[#rings + 1] = { x = x, y = y, r = 0, max = 600, life = 1.0, maxLife = 1.0, col = { 1, 0.6, 0.2 } }
    rings[#rings + 1] = { x = x, y = y, r = 0, max = 900, life = 1.6, maxLife = 1.6, col = { 0.7, 0.35, 1 } }
    decals[#decals + 1] = { x = x, y = y, r = 120, a = rand() * 6, kind = "scorch", life = 60 }
end
end

------------------------------------------------------------------------------
-- Drawing: the Murky Swamp and the Volcanic Rift (ground details, obstacles,
-- pools, enemies and their projectiles)
------------------------------------------------------------------------------
do
local function tri(x, y, s, a)
    lg.polygon("fill", x + cos(a) * s, y + sin(a) * s, x + cos(a + 2.2) * s, y + sin(a + 2.2) * s,
        x + cos(a - 2.2) * s, y + sin(a - 2.2) * s)
end

-- murky water and lava pools
function X.drawPools(l, t, r, b)
    local tm = menuTime
    for _, p in ipairs(X.swampPools or {}) do
        if p.x + p.rx > l and p.x - p.rx < r and p.y + p.ry > t and p.y - p.ry < b then
            lg.setColor(0.06, 0.16, 0.06)
            lg.ellipse("fill", p.x, p.y, p.rx + 10, p.ry + 8)
            lg.setColor(0.08, 0.25, 0.1)
            lg.ellipse("fill", p.x, p.y, p.rx, p.ry)
            lg.setColor(0.1, 0.3, 0.12, 0.8)
            lg.ellipse("fill", p.x - p.rx * 0.15, p.y - p.ry * 0.2, p.rx * 0.6, p.ry * 0.45)
            -- slow ripples and bubbles
            lg.setColor(0.25, 0.45, 0.25, 0.35)
            for i = 0, 2 do
                local k = ((tm * 0.25 + i / 3 + p.seed) % 1)
                lg.ellipse("line", p.x + cos(p.seed + i * 2) * p.rx * 0.4, p.y + sin(p.seed + i * 2) * p.ry * 0.4,
                    18 + 40 * k, 8 + 18 * k)
            end
            local bk = (tm * 0.7 + p.seed) % 1
            lg.setColor(0.3, 0.5, 0.25, 0.7 * (1 - bk))
            lg.circle("line", p.x + cos(p.seed * 3) * p.rx * 0.5, p.y + sin(p.seed * 3) * p.ry * 0.5, 3 + 7 * bk)
        end
    end
    for _, p in ipairs(X.lavaPools or {}) do
        if p.x + p.rx > l and p.x - p.rx < r and p.y + p.ry > t and p.y - p.ry < b then
            lg.setColor(0.25, 0.08, 0.04)
            lg.ellipse("fill", p.x, p.y, p.rx + 12, p.ry + 10)
            lg.setColor(0.85, 0.25, 0.05)
            lg.ellipse("fill", p.x, p.y, p.rx, p.ry)
            -- moving hot blobs
            for i = 0, 3 do
                local a = tm * 0.3 + i * 1.6 + p.seed
                local g = 0.6 + 0.4 * sin(tm * 2 + i + p.seed)
                lg.setColor(1, 0.55 + 0.2 * g, 0.1, 0.8)
                lg.ellipse("fill", p.x + cos(a) * p.rx * 0.45, p.y + sin(a * 1.3) * p.ry * 0.45, p.rx * 0.25, p.ry * 0.2)
            end
            lg.setColor(1, 0.85, 0.4, 0.5 + 0.2 * sin(tm * 3 + p.seed))
            lg.ellipse("fill", p.x - p.rx * 0.1, p.y - p.ry * 0.1, p.rx * 0.22, p.ry * 0.16)
            -- dark crust floating on top
            lg.setColor(0.3, 0.1, 0.06, 0.8)
            lg.ellipse("fill", p.x + cos(p.seed) * p.rx * 0.55, p.y + sin(p.seed) * p.ry * 0.5, p.rx * 0.16, p.ry * 0.1)
        end
    end
end

-- obstacles
function X.drawNewWall(w)
    local k = w.kind
    local cx, cy = w.x + w.w / 2, w.y + w.h / 2
    if k == "mud" then
        lg.setColor(0, 0, 0, 0.25) lg.ellipse("fill", cx + 6, cy + 8, w.w / 2, w.h / 2)
        lg.setColor(0.35, 0.2, 0.08) lg.ellipse("fill", cx, cy, w.w / 2, w.h / 2)
        lg.setColor(0.42, 0.25, 0.1) lg.ellipse("fill", cx - w.w * 0.1, cy - w.h * 0.12, w.w * 0.32, w.h * 0.3)
        lg.setColor(0.28, 0.15, 0.06) lg.circle("fill", cx + w.w * 0.2, cy + w.h * 0.1, w.w * 0.08)
        return true
    elseif k == "swampbush" then
        lg.setColor(0, 0, 0, 0.22) lg.ellipse("fill", cx + 6, cy + 8, w.w / 2, w.h / 2)
        lg.setColor(0.2, 0.42, 0.18)
        for i = 0, 4 do
            local fx = w.x + w.w * (0.12 + i * 0.19)
            lg.circle("fill", fx, cy + sin(i * 2.3 + w.x) * w.h * 0.12, w.h * (0.42 + 0.08 * (i % 2)))
        end
        lg.setColor(0.28, 0.55, 0.25)
        for i = 0, 3 do
            local fx = w.x + w.w * (0.2 + i * 0.2)
            lg.circle("fill", fx - 4, cy - w.h * 0.12, w.h * 0.25)
        end
        return true
    elseif k == "bigshroom" then
        local s = w.w
        lg.setColor(0, 0, 0, 0.25) lg.ellipse("fill", cx + 6, cy + 8, s * 0.55, s * 0.4)
        lg.setColor(0.85, 0.84, 0.8) lg.rectangle("fill", cx - s * 0.12, cy, s * 0.24, s * 0.45, 3, 3)
        lg.setColor(0.68, 0.06, 0.1) lg.circle("fill", cx, cy, s * 0.55)
        lg.setColor(0.82, 0.12, 0.15) lg.circle("fill", cx - s * 0.1, cy - s * 0.1, s * 0.38)
        if (w.v or 0) > 0.4 then
            lg.setColor(1, 1, 1)
            lg.circle("fill", cx - s * 0.2, cy - s * 0.15, s * 0.09)
            lg.circle("fill", cx + s * 0.18, cy - s * 0.05, s * 0.07)
            lg.circle("fill", cx, cy + s * 0.2, s * 0.06)
            lg.circle("fill", cx + s * 0.3, cy + s * 0.25, s * 0.05)
        end
        return true
    elseif k == "log" then
        lg.setColor(0, 0, 0, 0.25) lg.rectangle("fill", w.x + 5, w.y + 7, w.w, w.h, 10, 10)
        lg.setColor(0.33, 0.22, 0.12) lg.rectangle("fill", w.x, w.y, w.w, w.h, 10, 10)
        lg.setColor(0.25, 0.16, 0.08)
        if w.w > w.h then
            for px = w.x + 20, w.x + w.w - 10, 26 do lg.line(px, w.y + 4, px + 10, w.y + w.h - 4) end
        else
            for py = w.y + 20, w.y + w.h - 10, 26 do lg.line(w.x + 4, py, w.x + w.w - 4, py + 10) end
        end
        lg.setColor(0.3, 0.5, 0.2, 0.8) lg.circle("fill", w.x + 8, w.y + 8, 6)
        return true
    elseif k == "basalt" then
        lg.setColor(0, 0, 0, 0.3) lg.rectangle("fill", w.x + 6, w.y + 8, w.w, w.h, 12, 12)
        lg.setColor(0.17, 0.14, 0.14) lg.rectangle("fill", w.x, w.y, w.w, w.h, 12, 12)
        lg.setColor(0.26, 0.22, 0.21) lg.rectangle("fill", w.x + 4, w.y + 3, w.w * 0.7, w.h * 0.4, 10, 10)
        local g = 0.5 + 0.4 * sin(menuTime * 2 + w.x)
        lg.setColor(1, 0.4, 0.08, 0.6 * g)
        lg.setLineWidth(2)
        lg.line(w.x + w.w * 0.2, w.y + w.h * 0.7, w.x + w.w * 0.45, w.y + w.h * 0.55, w.x + w.w * 0.75, w.y + w.h * 0.8)
        lg.setLineWidth(1)
        return true
    elseif k == "obsidian" then
        lg.setColor(0, 0, 0, 0.3) lg.ellipse("fill", cx + 6, cy + 8, w.w * 0.5, w.h * 0.4)
        lg.setColor(0.1, 0.07, 0.14)
        lg.polygon("fill", cx, w.y - 6, w.x + w.w, cy, cx + w.w * 0.2, w.y + w.h, w.x, cy + w.h * 0.2)
        lg.setColor(0.35, 0.25, 0.5, 0.8)
        lg.line(cx, w.y - 6, cx + w.w * 0.1, cy)
        return true
    elseif k == "basaltwall" then
        lg.setColor(0, 0, 0, 0.3) lg.rectangle("fill", w.x + 6, w.y + 8, w.w, w.h)
        lg.setColor(0.2, 0.16, 0.15) lg.rectangle("fill", w.x, w.y, w.w, w.h, 4, 4)
        lg.setColor(0.13, 0.1, 0.1)
        if w.w > w.h then
            for px = w.x + 24, w.x + w.w - 4, 24 do lg.line(px, w.y, px, w.y + w.h) end
        else
            for py = w.y + 24, w.y + w.h - 4, 24 do lg.line(w.x, py, w.x + w.w, py) end
        end
        lg.setColor(0.3, 0.25, 0.23) lg.rectangle("fill", w.x, w.y, w.w, 4)
        return true
    elseif k == "gkwall" or k == "gktower" or k == "gkpillar" then
        lg.setColor(0, 0, 0, 0.32) lg.rectangle("fill", w.x + 7, w.y + 9, w.w, w.h)
        lg.setColor(0.12, 0.08, 0.1) lg.rectangle("fill", w.x, w.y, w.w, w.h)
        lg.setColor(0.2, 0.13, 0.14)
        for py = w.y + 16, w.y + w.h - 2, 16 do lg.line(w.x, py, w.x + w.w, py) end
        local g = 0.5 + 0.5 * sin(menuTime * 3 + w.x * 0.01)
        lg.setColor(1, 0.4, 0.05, 0.5 * g)
        lg.rectangle("fill", w.x, w.y, w.w, 4)
        if k ~= "gkwall" then
            -- a brazier of fire on the towers / pillars
            local fl = 0.7 + 0.3 * sin(menuTime * 12 + w.x)
            lg.setColor(1, 0.45, 0.1, 0.25 * fl) lg.circle("fill", cx, cy, w.w * 0.55)
            lg.setColor(1, 0.55, 0.1, fl) lg.circle("fill", cx, cy, w.w * 0.18 * fl)
            lg.setColor(1, 0.9, 0.5, fl) lg.circle("fill", cx, cy, w.w * 0.08)
        end
        return true
    elseif k == "gkgate" then
        local close = (X.BF and X.BF.A == X.GKA and X.BF.gateClose) or 1
        local half = w.w / 2 * close
        for side = 0, 1 do
            local dx = side == 0 and w.x or w.x + w.w - half
            lg.setColor(0.2, 0.08, 0.06)
            lg.rectangle("fill", dx, w.y, half, w.h)
            lg.setColor(1, 0.45, 0.1, 0.8)
            for bx = dx + 8, dx + half - 4, 16 do lg.rectangle("fill", bx, w.y + 2, 4, w.h - 4) end
        end
        return true
    end
    return false
end

function X.drawGKFloor(f)
    lg.setColor(0.16, 0.1, 0.1)
    lg.rectangle("fill", f.x, f.y, f.w, f.h)
    lg.setColor(0.22, 0.13, 0.12)
    lg.setLineWidth(2)
    for px = f.x + 100, f.x + f.w, 100 do lg.line(px, f.y, px, f.y + f.h) end
    for py = f.y + 100, f.y + f.h, 100 do lg.line(f.x, py, f.x + f.w, py) end
    local g = 0.5 + 0.5 * sin(menuTime * 1.6)
    lg.setColor(1, 0.35, 0.05, 0.25 + 0.15 * g)
    lg.setLineWidth(5)
    local A = X.GKA
    if A then
        lg.circle("line", A.bx, A.by, 340)
        lg.circle("line", A.bx, A.by, 300)
        for i = 0, 7 do
            local a = i * pi / 4 + menuTime * 0.1
            lg.line(A.bx + cos(a) * 300, A.by + sin(a) * 300, A.bx + cos(a) * 340, A.by + sin(a) * 340)
        end
    end
    lg.setLineWidth(1)
end

-- decoration of the new regions (decor kinds starting with z_)
function X.drawDecorZ(d)
    local k = d.kind
    if k == "z_moss" then
        lg.setColor(0.33, 0.35, 0.08, 0.85)
        lg.rectangle("fill", d.x - 40 * d.s, d.y - 5 * d.s, 80 * d.s, 10 * d.s, 5, 5)
        lg.rectangle("fill", d.x - 22 * d.s, d.y + 4 * d.s, 60 * d.s, 8 * d.s, 4, 4)
    elseif k == "z_swampgrass" then
        lg.setColor(0.2, 0.36, 0.12, 0.85)
        for i = -1, 1 do lg.line(d.x + i * 3, d.y, d.x + i * 5 * d.s, d.y - 10 * d.s) end
    elseif k == "z_reed" then
        lg.setColor(0.32, 0.42, 0.18)
        lg.setLineWidth(2)
        lg.line(d.x, d.y, d.x - 2, d.y - 22 * d.s)
        lg.line(d.x + 4, d.y, d.x + 6, d.y - 18 * d.s)
        lg.setLineWidth(1)
        lg.setColor(0.4, 0.25, 0.12)
        lg.rectangle("fill", d.x - 4, d.y - 26 * d.s, 4, 9 * d.s, 2, 2)
    elseif k == "z_shroom" then
        lg.setColor(0.85, 0.84, 0.8) lg.rectangle("fill", d.x - 1.5, d.y - 2, 3, 7 * d.s)
        lg.setColor(0.8, 0.1, 0.12) lg.circle("fill", d.x, d.y - 3, 5 * d.s)
        lg.setColor(1, 1, 1) lg.circle("fill", d.x - 1.5, d.y - 4, 1.1)
    elseif k == "z_mudspot" then
        lg.setColor(0.3, 0.2, 0.08, 0.7) lg.ellipse("fill", d.x, d.y, 14 * d.s, 8 * d.s)
    elseif k == "z_lily" then
        lg.setColor(0.25, 0.55, 0.22) lg.arc("fill", d.x, d.y, 10 * d.s, d.r, d.r + 5.6)
        if d.ph > 8 then lg.setColor(1, 0.75, 0.85) lg.circle("fill", d.x + 2, d.y - 2, 3) end
    elseif k == "z_ash" then
        lg.setColor(0.32, 0.29, 0.28, 0.8) lg.ellipse("fill", d.x, d.y, 12 * d.s, 5 * d.s)
    elseif k == "z_pebble" then
        lg.setColor(0.12, 0.1, 0.1) lg.ellipse("fill", d.x, d.y, 4 * d.s, 3 * d.s)
    elseif k == "z_ember" then
        local g = 0.5 + 0.5 * sin(menuTime * 3 + d.ph)
        lg.setColor(1, 0.5, 0.1, 0.4 + 0.5 * g) lg.circle("fill", d.x, d.y, 2.5 * d.s)
    elseif k == "z_vent" then
        lg.setColor(0.1, 0.07, 0.07) lg.circle("fill", d.x, d.y, 9 * d.s)
        local g = 0.5 + 0.5 * sin(menuTime * 5 + d.ph)
        lg.setColor(1, 0.45, 0.1, 0.5 + 0.4 * g) lg.circle("fill", d.x, d.y, 4 * d.s)
        lg.setColor(0.5, 0.45, 0.42, 0.3 * g)
        lg.circle("fill", d.x + sin(menuTime + d.ph) * 4, d.y - 12 - 10 * ((menuTime * 0.8 + d.ph) % 1), 6 * d.s)
    elseif k == "z_skull" then
        lg.setColor(0.85, 0.8, 0.7) lg.circle("fill", d.x, d.y, 5 * d.s)
        lg.setColor(0.1, 0.08, 0.08) lg.circle("fill", d.x - 2, d.y - 1, 1.3) lg.circle("fill", d.x + 2, d.y - 1, 1.3)
    end
end

------------------------------------------------------------------------------
-- the new enemies
------------------------------------------------------------------------------
X.DRAW = {}

local function shadow(e, sx, sy)
    lg.setColor(0, 0, 0, 0.25)
    lg.ellipse("fill", e.x + 3, e.y + e.r * 0.75, e.r * (sx or 1.05), e.r * (sy or 0.5))
end

-- SHROOMER: a walking red mushroom with white spots and angry eyes
X.DRAW.shroomer = function(e, alpha)
    shadow(e)
    local r = e.r
    local bob = sin(e.hop * 2) * 2
    lg.push()
    lg.translate(e.x, e.y + bob)
    -- little legs
    local step = sin(e.walkAnim) * 4
    lg.setColor(0.85, 0.82, 0.76, alpha)
    lg.ellipse("fill", -5, r * 0.6 + step, 4, 3)
    lg.ellipse("fill", 5, r * 0.6 - step, 4, 3)
    lg.rectangle("fill", -r * 0.38, -r * 0.1, r * 0.76, r * 0.75, 4, 4)
    -- cap
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.72, 0.06, 0.1, alpha) end
    lg.ellipse("fill", 0, -r * 0.2, r * 1.15, r * 0.85)
    lg.setColor(0.86, 0.14, 0.16, alpha)
    lg.ellipse("fill", -r * 0.15, -r * 0.35, r * 0.75, r * 0.5)
    lg.setColor(1, 1, 1, alpha)
    lg.circle("fill", -r * 0.5, -r * 0.35, r * 0.16)
    lg.circle("fill", r * 0.35, -r * 0.5, r * 0.13)
    lg.circle("fill", r * 0.65, -r * 0.05, r * 0.11)
    lg.circle("fill", -r * 0.1, -r * 0.7, r * 0.1)
    -- face on the stem
    local fa = cos(e.angle) * r * 0.15
    lg.setColor(0.1, 0.05, 0.05, alpha)
    lg.circle("fill", -r * 0.15 + fa, r * 0.25, 2)
    lg.circle("fill", r * 0.15 + fa, r * 0.25, 2)
    if e.throwAnim > 0 then
        lg.setColor(0.8, 0.1, 0.12, alpha)
        lg.circle("fill", cos(e.angle) * r * 1.1, sin(e.angle) * r * 1.1 - r * 0.3, 5)
    end
    lg.pop()
end

-- TOAD: green, wide mouth, pink tongue (like the sketch)
X.DRAW.toad = function(e, alpha)
    shadow(e, 1.15, 0.55)
    local r = e.r
    local hop = abs(sin(e.hop)) * 5
    -- tongue (out while attacking)
    if e.swingT > 0 then
        local len = 300
        local tgt = me
        if tgt then len = min(300, dist(e.x, e.y, tgt.x, tgt.y)) end
        local ex, ey = e.x + cos(e.angle) * len, e.y + sin(e.angle) * len
        lg.setColor(0.95, 0.4, 0.65, alpha)
        lg.setLineWidth(5)
        lg.line(e.x + cos(e.angle) * r * 0.8, e.y + sin(e.angle) * r * 0.8 - hop, ex, ey)
        lg.setLineWidth(1)
        lg.circle("fill", ex, ey, 6)
    end
    lg.push()
    lg.translate(e.x, e.y - hop)
    lg.rotate(e.angle)
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.28, 0.4, 0.14, alpha) end
    lg.ellipse("fill", 0, 0, r * 1.05, r * 0.9)
    -- back legs
    lg.setColor(0.22, 0.33, 0.1, alpha)
    lg.ellipse("fill", -r * 0.7, -r * 0.7, r * 0.45, r * 0.25)
    lg.ellipse("fill", -r * 0.7, r * 0.7, r * 0.45, r * 0.25)
    -- spots
    lg.setColor(0.2, 0.3, 0.1, alpha)
    lg.circle("fill", -r * 0.3, -r * 0.2, r * 0.15)
    lg.circle("fill", -r * 0.1, r * 0.35, r * 0.12)
    -- bulging eyes
    for sgn = -1, 1, 2 do
        lg.setColor(0.32, 0.45, 0.16, alpha)
        lg.circle("fill", r * 0.45, sgn * r * 0.45, r * 0.32)
        lg.setColor(0.05, 0.05, 0.03, alpha)
        lg.circle("fill", r * 0.52, sgn * r * 0.45, r * 0.15)
    end
    -- mouth with the tip of the tongue
    lg.setColor(0.9, 0.3, 0.55, alpha)
    lg.circle("fill", r * 0.95, 0, r * 0.18)
    lg.pop()
end

-- CROCODILE: only the eyes (and a ripple) while hiding in the murky water
X.DRAW.croc = function(e, alpha)
    local r = e.r
    local inW = X.inMurk(e.x, e.y) ~= nil
    if inW and e.swingT <= 0 then
        lg.setColor(0.2, 0.4, 0.2, 0.4 * alpha)
        lg.ellipse("line", e.x, e.y, r * 1.3 + sin(menuTime * 3 + e.x) * 2, r * 0.6)
        for sgn = -1, 1, 2 do
            local ex = e.x + cos(e.angle) * r * 0.6 + cos(e.angle + pi / 2) * sgn * 6
            local ey = e.y + sin(e.angle) * r * 0.6 + sin(e.angle + pi / 2) * sgn * 6
            lg.setColor(0.2, 0.36, 0.15, alpha)
            lg.circle("fill", ex, ey, 5)
            lg.setColor(1, 0.85, 0.2, alpha)
            lg.circle("fill", ex, ey, 2.8)
            lg.setColor(0, 0, 0, alpha)
            lg.rectangle("fill", ex - 0.6, ey - 2.4, 1.2, 4.8)
        end
        if e.hitFlash > 0 then
            lg.setColor(1, 1, 1, 0.5)
            lg.ellipse("fill", e.x, e.y, r, r * 0.5)
        end
        return
    end
    shadow(e, 1.6, 0.5)
    lg.push()
    lg.translate(e.x, e.y)
    lg.rotate(e.angle)
    local sw = sin(e.walkAnim) * 0.25
    local body = e.hitFlash > 0 and { 1, 1, 1 } or { 0.28, 0.42, 0.2 }
    -- tail
    lg.setColor(body[1] * 0.85, body[2] * 0.85, body[3] * 0.85, alpha)
    lg.polygon("fill", -r * 0.8, -r * 0.35, -r * 2.2, sw * r * 2, -r * 0.8, r * 0.35)
    -- legs
    for sgn = -1, 1, 2 do
        lg.ellipse("fill", r * 0.4, sgn * r * 0.62, r * 0.28, r * 0.14)
        lg.ellipse("fill", -r * 0.55, sgn * r * 0.62, r * 0.28, r * 0.14)
    end
    lg.setColor(body[1], body[2], body[3], alpha)
    lg.ellipse("fill", 0, 0, r * 1.1, r * 0.55)
    -- snout (open while biting)
    local open = e.swingT > 0 and 0.35 or 0.05
    lg.polygon("fill", r * 0.8, -r * 0.35, r * 2.0, -r * 0.18 - open * r, r * 2.0, -r * 0.05, r * 0.8, 0)
    lg.polygon("fill", r * 0.8, r * 0.35, r * 2.0, r * 0.18 + open * r, r * 2.0, r * 0.05, r * 0.8, 0)
    lg.setColor(0.95, 0.95, 0.85, alpha)
    for i = 0, 3 do
        local tx = r * (1.0 + i * 0.25)
        lg.polygon("fill", tx, -r * 0.12 - open * r * 0.8, tx + 3, -r * 0.02, tx + 6, -r * 0.12 - open * r * 0.8)
    end
    -- ridged back
    lg.setColor(0.2, 0.3, 0.14, alpha)
    for i = -2, 2 do lg.circle("fill", i * r * 0.32, 0, r * 0.1) end
    -- eyes
    lg.setColor(1, 0.85, 0.2, alpha)
    lg.circle("fill", r * 0.65, -r * 0.3, 3)
    lg.circle("fill", r * 0.65, r * 0.3, 3)
    lg.pop()
end

-- MAGMA SLIME: a glowing blob of lava (the small ones too)
local function slimeDraw(e, alpha)
    local r = e.r
    local sq = 1 + 0.18 * sin(e.hop * 2)
    lg.setColor(0, 0, 0, 0.25)
    lg.ellipse("fill", e.x + 3, e.y + r * 0.7, r * 1.1, r * 0.45)
    lg.setColor(1, 0.45, 0.05, 0.25 * alpha)
    lg.circle("fill", e.x, e.y, r * 1.6)
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.85, 0.2, 0.03, alpha) end
    lg.ellipse("fill", e.x, e.y - r * 0.1, r * sq, r * (2 - sq))
    lg.setColor(1, 0.6, 0.1, alpha)
    lg.ellipse("fill", e.x - r * 0.15, e.y - r * 0.3, r * 0.55 * sq, r * 0.4 * (2 - sq))
    lg.setColor(1, 0.95, 0.6, alpha)
    lg.circle("fill", e.x - r * 0.3, e.y - r * 0.45, r * 0.15)
    -- dark crust pieces and angry eyes
    lg.setColor(0.25, 0.06, 0.02, alpha)
    lg.circle("fill", e.x + r * 0.45, e.y + r * 0.2, r * 0.18)
    local fx, fy = cos(e.angle) * r * 0.3, sin(e.angle) * r * 0.3
    lg.setColor(0.15, 0.03, 0, alpha)
    lg.circle("fill", e.x + fx - r * 0.22, e.y + fy - r * 0.1, max(1.5, r * 0.12))
    lg.circle("fill", e.x + fx + r * 0.22, e.y + fy - r * 0.1, max(1.5, r * 0.12))
end
X.DRAW.slime, X.DRAW.slimelet = slimeDraw, slimeDraw

-- LAVA SERPENT: a fish skeleton on fire
X.DRAW.serpent = function(e, alpha)
    local r = e.r
    local wv = sin(e.wob or 0)
    -- flames trailing behind
    for i = 1, 4 do
        local bx = e.x - cos(e.angle) * (r * 0.8 * i) + cos(e.angle + pi / 2) * wv * i * 2
        local by = e.y - sin(e.angle) * (r * 0.8 * i) + sin(e.angle + pi / 2) * wv * i * 2
        lg.setColor(1, 0.45 + 0.1 * i, 0.1, (0.5 - i * 0.08) * alpha)
        lg.circle("fill", bx, by - 4, r * (0.9 - i * 0.12) + sin(menuTime * 20 + i) * 2)
    end
    lg.push()
    lg.translate(e.x, e.y - 4)
    lg.rotate(e.angle)
    local bone = e.hitFlash > 0 and { 1, 1, 1 } or { 0.93, 0.88, 0.78 }
    lg.setColor(bone[1], bone[2], bone[3], alpha)
    lg.setLineWidth(3)
    -- spine
    lg.line(r * 0.6, 0, -r * 2.4, wv * r * 0.5)
    -- ribs
    lg.setLineWidth(2)
    for i = 0, 4 do
        local x = r * 0.2 - i * r * 0.5
        local yo = wv * r * 0.1 * i
        local len = r * (0.75 - i * 0.1)
        lg.line(x, yo, x - r * 0.25, yo - len)
        lg.line(x, yo, x - r * 0.25, yo + len)
    end
    -- tail fin
    lg.polygon("line", -r * 2.4, wv * r * 0.5, -r * 3.0, -r * 0.6 + wv * r * 0.5, -r * 3.0, r * 0.6 + wv * r * 0.5)
    lg.setLineWidth(1)
    -- skull with a burning eye and teeth
    lg.polygon("fill", r * 0.4, -r * 0.55, r * 1.5, -r * 0.1, r * 1.5, r * 0.15, r * 0.4, r * 0.55)
    lg.setColor(1, 0.5, 0.1, alpha)
    lg.circle("fill", r * 0.8, -r * 0.15, r * 0.15)
    lg.setColor(0.3, 0.2, 0.15, alpha)
    for i = 0, 2 do lg.line(r * (0.9 + i * 0.2), r * 0.05, r * (0.95 + i * 0.2), r * 0.3) end
    lg.pop()
end

-- BLAZESHROOM: a big glowing orange mushroom
X.DRAW.blazeshroom = function(e, alpha)
    local r = e.r
    local g = 0.7 + 0.3 * sin(menuTime * 5 + e.x)
    lg.setColor(1, 0.5, 0.1, 0.22 * g * alpha)
    lg.circle("fill", e.x, e.y - r * 0.2, r * 2)
    shadow(e, 1.2, 0.55)
    lg.setColor(0.85, 0.75, 0.62, alpha)
    lg.rectangle("fill", e.x - r * 0.35, e.y - r * 0.1, r * 0.7, r * 0.85, 5, 5)
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.95, 0.42, 0.05, alpha) end
    lg.ellipse("fill", e.x, e.y - r * 0.3, r * 1.2, r * 0.85)
    lg.setColor(1, 0.65, 0.15, alpha)
    lg.ellipse("fill", e.x - r * 0.15, e.y - r * 0.45, r * 0.8, r * 0.5)
    lg.setColor(1, 0.95, 0.5, g * alpha)
    lg.circle("fill", e.x - r * 0.45, e.y - r * 0.5, r * 0.14)
    lg.circle("fill", e.x + r * 0.4, e.y - r * 0.55, r * 0.11)
    lg.circle("fill", e.x + r * 0.05, e.y - r * 0.85, r * 0.1)
    lg.circle("fill", e.x + r * 0.7, e.y - r * 0.15, r * 0.09)
    -- mouth glows while spitting
    local fx, fy = cos(e.angle) * r * 0.2, r * 0.3
    lg.setColor(e.throwAnim > 0 and 1 or 0.2, e.throwAnim > 0 and 0.8 or 0.08, 0.1, alpha)
    lg.ellipse("fill", e.x + fx, e.y + fy, r * 0.22, r * (e.throwAnim > 0 and 0.18 or 0.08))
    lg.setColor(0.1, 0.03, 0.02, alpha)
    lg.circle("fill", e.x - r * 0.18 + fx, e.y + r * 0.08, 2.5)
    lg.circle("fill", e.x + r * 0.18 + fx, e.y + r * 0.08, 2.5)
end

-- enemy projectiles of the new regions
function X.drawEnemyShot(bl)
    local a = atan2(bl.vy, bl.vx)
    if bl.kind == "mushroom" then
        lg.push()
        lg.translate(bl.x, bl.y)
        lg.rotate(menuTime * 10)
        lg.setColor(0.85, 0.82, 0.76) lg.rectangle("fill", -2, 0, 4, 7)
        lg.setColor(0.8, 0.08, 0.12) lg.circle("fill", 0, 0, 7)
        lg.setColor(1, 1, 1) lg.circle("fill", -2, -2, 1.6) lg.circle("fill", 3, 1, 1.3)
        lg.pop()
    elseif bl.kind == "spit" then
        lg.setColor(0.45, 0.8, 0.2, 0.35) lg.circle("fill", bl.x, bl.y, 10)
        lg.setColor(0.55, 0.9, 0.25) lg.circle("fill", bl.x, bl.y, 6)
        lg.setColor(0.4, 0.7, 0.15, 0.6)
        lg.circle("fill", bl.x - cos(a) * 9, bl.y - sin(a) * 9, 4)
    elseif bl.kind == "eflame" then
        for i = 3, 0, -1 do
            local k = i / 3
            lg.setColor(1, 0.35 + 0.5 * (1 - k), 0.05 + 0.3 * (1 - k), 0.85 - k * 0.5)
            lg.circle("fill", bl.x - cos(a) * i * 7, bl.y - sin(a) * i * 7, 9 - i * 1.5)
        end
        lg.setColor(1, 0.95, 0.6) lg.circle("fill", bl.x, bl.y, 3.5)
    end
end
end

local HUD_SCALE = 0.85
-- a red heart (empty = a lost life)
function X.drawHeart(cx, cy, r, full)
    local function shape(mode)
        lg.circle(mode, cx - r * 0.5, cy - r * 0.25, r * 0.55)
        lg.circle(mode, cx + r * 0.5, cy - r * 0.25, r * 0.55)
        lg.polygon(mode, cx - r * 1.02, cy - r * 0.05, cx + r * 1.02, cy - r * 0.05, cx, cy + r)
    end
    lg.setColor(0, 0, 0, 0.45)
    lg.push() lg.translate(2, 3) shape("fill") lg.pop()
    if full then
        local beat = 1 + 0.06 * max(0, sin(menuTime * 6))
        lg.push()
        lg.translate(cx, cy) lg.scale(beat, beat) lg.translate(-cx, -cy)
        lg.setColor(0.9, 0.12, 0.15)
        shape("fill")
        lg.setColor(1, 0.55, 0.55, 0.8)
        lg.circle("fill", cx - r * 0.5, cy - r * 0.38, r * 0.2)
        lg.pop()
    else
        lg.setColor(0.22, 0.12, 0.12, 0.9)
        shape("fill")
    end
end

-- Chat lines in the bottom-left corner (all lines while typing, the newest fade out after 12 s)
function X.drawChat()
    local C = X.chat
    local sw, sh = lg.getDimensions()
    local w = min(460, sw * 0.4)
    local x, bottom = 14, sh - 14
    local now = love.timer.getTime()
    local font = fonts.small
    lg.setFont(font)
    local fh = font:getHeight()
    if C.open then
        lg.setColor(0.06, 0.04, 0.03, 0.85)
        lg.rectangle("fill", x, bottom - 30, w, 30, 6, 6)
        setC(PAL.gold)
        lg.setLineWidth(2)
        lg.rectangle("line", x, bottom - 30, w, 30, 6, 6)
        lg.setLineWidth(1)
        local shown = C.text .. ((floor(menuTime * 2) % 2 == 0) and "_" or "")
        setC(PAL.gold) lg.print("Say:", x + 8, bottom - 23)
        setC(PAL.text) lg.print(shown, x + 44, bottom - 23)
        if #C.text == 0 then
            lg.setColor(1, 1, 1, 0.35)
            lg.print("type a message - ENTER send, ESC cancel", x + 54, bottom - 23)
        end
        bottom = bottom - 36
    end
    -- collect visible lines, newest at the bottom
    local y = bottom
    local shownN = 0
    for i = #C.log, 1, -1 do
        local l = C.log[i]
        local age = now - l.t
        local a = C.open and 1 or clamp((12 - age) / 2, 0, 1)
        if a <= 0 or shownN >= (C.open and 12 or 7) then break end
        local prefix = l.name and (l.name .. ": ") or ""
        local _, lines = font:getWrap(prefix .. l.text, w - 16)
        local h = #lines * fh + 4
        y = y - h
        lg.setColor(0, 0, 0, 0.45 * a)
        lg.rectangle("fill", x, y - 1, w, h, 4, 4)
        local tc = l.col or PAL.text
        lg.setColor(0, 0, 0, 0.7 * a)
        lg.printf(prefix .. l.text, x + 9, y + 2, w - 16, "left")
        lg.setColor(1, 1, 1, 1)
        lg.printf({ { 1, 0.82, 0.4, a }, prefix, { tc[1], tc[2], tc[3], a }, l.text }, x + 8, y + 1, w - 16, "left")
        shownN = shownN + 1
    end
    if not C.open and #C.log == 0 and stats and stats.time < 20 then
        shadowText("Press T to chat", x, sh - 30, 300, "left", { 1, 0.9, 0.7, 0.5 }, fonts.tiny)
    end
end

function drawHUD()
    if X.cut then X.drawCutUI() return end
    if X.BF and not X.BF.done and X.inArena(X.BF.A, me.x, me.y, -60) then X.drawBossHUD() return end
    local sw, sh = lg.getDimensions()
    sw, sh = sw / HUD_SCALE, sh / HUD_SCALE
    lg.push()
    lg.scale(HUD_SCALE, HUD_SCALE)
    local p = player

    -- Top-left: vitals
    panel(14, 14, 300, 196)
    shadowText("HEALTH", 28, 22, 200, "left", PAL.dim, fonts.tiny)
    local hpCol = p.hp / p.maxHp < 0.3 and { 0.95, 0.2 + 0.15 * sin(menuTime * 8), 0.15 } or PAL.red
    bar(28, 38, 272, 20, p.hp / p.maxHp, hpCol, p.hpLag / p.maxHp, string.format("%d / %d", math.ceil(p.hp), p.maxHp))
    X.drawShieldTag(28, 38, 272, 20)
    shadowText("STAMINA", 28, 64, 200, "left", PAL.dim, fonts.tiny)
    bar(28, 80, 272, 12, p.stamina / p.maxStamina, p.stamina < 25 and { 0.6, 0.6, 0.6 } or PAL.blue)
    shadowText("MANA", 28, 98, 200, "left", PAL.dim, fonts.tiny)
    bar(28, 114, 272, 16, p.mp / K.MP_MAX, { 0.45, 0.4, 1 }, nil, string.format("%d / %d MP", floor(p.mp), K.MP_MAX))
    -- level + XP bar
    local lvl = p.level or 0
    local maxed = lvl >= X.MAX_LEVEL
    shadowText(maxed and "LVL - MAX" or ("LVL - " .. lvl), 28, 136, 200, "left", { 1, 0.95, 0.85 }, fonts.small)
    if not maxed then shadowText((stats.kills % 10) .. " / 10 kills", 28, 138, 272, "right", PAL.dim, fonts.tiny) end
    bar(28, 156, 272, 9, maxed and 1 or (stats.kills % 10) / 10, { 1, 0.82, 0.1 })
    -- GOLD | Credits
    lg.setFont(fonts.medium)
    setC(PAL.gold)
    local gtxt = string.format("GOLD: %d", floor(p.gold))
    lg.print(gtxt, 28, 172)
    local gw = fonts.medium:getWidth(gtxt)
    lg.setFont(fonts.normal)
    setC(PAL.gold, 0.9)
    lg.print("|  Credits: " .. PROF.data.credits, 28 + gw + 10, 177)

    -- Status effects
    local sy = 218
    local function status(text, col)
        panel(14, sy, 300, 26)
        shadowText(text, 22, sy + 6, 290, "left", col, fonts.small)
        sy = sy + 32
    end
    status("Difficulty: " .. X.D.name .. (admin.on and "  -  ADMIN: no credits" or (X.D.credits == 0 and "  -  Practice mode: no credits" or "")),
        admin.on and { 1, 0.4, 0.4 } or X.D.col)
    if p.bootsOn then status("Feather Boots: +35% speed | +1.2% dmg taken", { 0.8, 0.9, 1 }) end
    if p.owned.vest then status("Reinforced Vest: +25 max HP", { 0.9, 0.85, 0.7 }) end
    if p.turtleT > 0 then status(string.format("Turtle Master: -50%% dmg, -50%% speed  %.1fs", p.turtleT), { 0.5, 1, 0.55 }) end
    if p.iciclesT > 0 then status(string.format("Cold Icicles: freezing bullets  %.1fs", p.iciclesT), { 0.6, 0.9, 1 }) end
    if p.chillT > 0 then status(string.format("Chilled: -15%% speed  %.1fs", p.chillT), { 0.6, 0.85, 1 }) end
    if p.onIce then status("On thin ice: slippery footing", { 0.75, 0.92, 1 }) end
    if p.poisonT > 0 then status(string.format("Poisoned: -2 HP/s  %.1fs", p.poisonT), { 0.8, 0.45, 1 }) end
    if p.spookT > 0 then status(string.format("SPOOKED: vision reduced  %.1fs", p.spookT), { 1, 0.55, 0.15 }) end
    if p.hasCursed and p.cursedCd > 0 then status("Cursed Spell recharging  " .. formatTime(p.cursedCd), { 0.95, 0.35, 0.4 }) end
    if (p.blazeT or 0) > 0 then status(string.format("Blaze Spell: flame bullets  %.1fs", p.blazeT), { 1, 0.55, 0.15 }) end
    if (p.slowT or 0) > 0 then status(string.format("SLOWNESS: -30%% speed  %.1fs", p.slowT), { 0.6, 0.75, 1 }) end
    if (p.weakT or 0) > 0 then status(string.format("WEAKNESS: +25%% damage taken  %.1fs", p.weakT), { 1, 0.45, 0.45 }) end
    if (p.fungusT or 0) > 0 then status(string.format("FUNGUS: green vision  %.1fs", p.fungusT), { 0.55, 1, 0.4 }) end
    if (p.serpSlowT or 0) > 0 then status(string.format("Scorched: -10%% speed  %.1fs", p.serpSlowT), { 1, 0.55, 0.2 }) end
    if p.inMurk then status(p.waders and "Murky water (Swamp Waders: no slow)" or "Murky water: -20% speed", { 0.4, 0.75, 0.35 }) end
    if (p.goldPotT or 0) > 0 then status("Potion of GOLD: +50% gold  " .. formatTime(p.goldPotT), { 1, 0.85, 0.25 }) end
    if (p.tonicT or 0) > 0 then status("Stamina Tonic: +50% recovery  " .. formatTime(p.tonicT), { 0.6, 0.9, 1 }) end
    if p.recallT then status(string.format("Recalling to the shed...  %.1fs", p.recallT), { 0.7, 0.6, 1 }) end
    if (p.maxShield or 0) > 0 and p.shield <= 0 then status("Shield broken - repair it with Metal Scraps (" .. (p.scraps or 0) .. ")", { 0.5, 0.7, 1 }) end
    if X.EV then
        if X.EV.k == "meteors" then status(string.format("METEOR SHOWER - dodge the circles  %ds", math.ceil(X.EV.t)), { 1, 0.45, 0.2 })
        elseif X.EV.k == "merchant" then status("Travelling merchant at the shed (E)  " .. formatTime(X.EV.t), { 1, 0.85, 0.45 })
        elseif X.EV.k == "goblin" then status(string.format("TREASURE GOBLIN on the loose!  %ds", math.ceil(max(0, X.EV.t))), { 1, 0.85, 0.2 }) end
    end
    if X.reviveTarget then status("Hold V to revive " .. (X.reviveTarget.name or "your teammate"), { 0.5, 1, 0.6 }) end
    if X.endless then
        status((world.wave or 1) >= X.LAST_WAVE and string.format("LAST WAVE  |  DAY %d  |  groups of %d", world.day or 1, X.groupSize())
            or string.format("WAVE %d  |  DAY %d  |  next wave: day %d", world.wave or 1, world.day or 1, X.nextWaveDay()),
            { 1, 0.75, 0.3 })
    end

    -- Top-center: objective progress
    local pw = 360
    panel(sw / 2 - pw / 2, 14, pw, 54)
    shadowText(world.kills >= K.KILLS_TO_WIN and string.format(MPS.online and "TEAM KILLS  %d" or "HOSTILES ELIMINATED  %d", world.kills)
        or string.format(MPS.online and "TEAM KILLS  %d / %d" or "HOSTILES ELIMINATED  %d / %d", world.kills, K.KILLS_TO_WIN),
        sw / 2 - pw / 2, 20, pw, "center", PAL.text, fonts.normal)
    bar(sw / 2 - pw / 2 + 14, 46, pw - 28, 10, min(1, world.kills / K.KILLS_TO_WIN), PAL.gold)
    -- gate markers on the kill bar
    for _, g in ipairs(X.gates()) do
        if g.kills < K.KILLS_TO_WIN then
            lg.setColor(g.col)
            local mx = sw / 2 - pw / 2 + 14 + (pw - 28) * g.kills / K.KILLS_TO_WIN
            lg.rectangle("fill", mx - 1, 43, 2, 16)
        end
    end

    -- Alert status under objective
    local hunting = 0
    for _, e in ipairs(enemies) do if not e.dead and e.hidden <= 0 and e.state ~= "patrol" then hunting = hunting + 1 end end
    if hunting > 0 then
        local a = 0.6 + 0.4 * sin(menuTime * 6)
        shadowText(string.format("! %d HOSTILE%s ALERTED !", hunting, hunting == 1 and "" or "S"),
            sw / 2 - 200, 76, 400, "center", { 1, 0.35, 0.25, a }, fonts.small)
    else
        shadowText("Undetected", sw / 2 - 200, 76, 400, "center", { 0.7, 0.9, 0.7, 0.8 }, fonts.small)
    end
    -- Region / next gate
    local nextG
    for _, g in ipairs(X.gates()) do if not g.open then nextG = g break end end
    local rname = X.REGION_NICE[p.region] or ""
    local gtxt = "All gates open"
    if nextG then
        if world.kills < nextG.kills then
            gtxt = string.format("%s opens at %d kills (%d to go)", X.titleCase(nextG.name), nextG.kills, nextG.kills - world.kills)
        elseif nextG.key and not world.hasKey then
            gtxt = "The Hollow Gate needs the Blaze Gatekeeper's key"
        end
    end
    shadowText("Region: " .. rname .. "   |   " .. gtxt, sw / 2 - 300, 94, 600, "center",
        { REGIONS[p.region].col[1], REGIONS[p.region].col[2], REGIONS[p.region].col[3], 0.85 }, fonts.tiny)
    -- Weather
    local w = weather[p.region]
    if w and (w.active or w.intensity > 0.05) then
        local info = WEATHER_INFO[REGIONS[p.region].weather]
        local txt = w.active and string.format("WEATHER: %s (%s)  %s", info.name, info.desc, formatTime(w.t)) or ("WEATHER: " .. info.name .. " clearing...")
        shadowText(txt, sw / 2 - 250, 110, 500, "center", p.region == "frozen" and { 0.9, 0.95, 1 } or { 0.65, 0.75, 1 }, fonts.tiny)
    end

    -- Top-right: minimap + time
    local ms = 190
    drawMinimap(sw - ms - 20, 20, ms)
    local dark = X.darkness()
    local icon = dark > 0.6 and "Night" or (dark > 0.05 and (X.clock() < "12:00" and "Dawn" or "Dusk") or "Day")
    shadowText(string.format("Day %d  %s  (%s)   Time %s", world.day or 1, X.clock(), icon, formatTime(stats.time)),
        sw - ms - 70, ms + 52, ms + 50, "right", dark > 0.6 and { 0.7, 0.75, 1 } or PAL.dim, fonts.small)

    -- Bottom-center: the HOTBAR (guns or utilities: mouse wheel selects, G switches, left click uses)
    X.drawHotbar(p, sw, sh)

    -- Multiplayer: 3 lives shown as hearts next to the vitals
    if MPS.online then
        panel(320, 14, 136, 72)
        for i = 1, 3 do X.drawHeart(348 + (i - 1) * 40, 40, 16, i <= (p.lives or 3)) end
        shadowText("LIVES", 320, 64, 136, "center", PAL.dim, fonts.tiny)
    end

    -- Left: compact stats, right under the vitals and status lines (chat uses the bottom-left)
    local sx2, sy2 = 14, sy + 2
    panel(sx2, sy2, 230, 134)
    lg.setFont(fonts.small)
    local acc = stats.shotsFired > 0 and stats.shotsHit / stats.shotsFired * 100 or 0
    local lines
    if world.spookyOpen then
        lines = {
            { "Desert kills", stats.banditKills + stats.scoutKills },
            { "Frozen kills", stats.frozenKills + stats.snowmanKills },
            { "Gourds / Bats / Witches", stats.gourdKills .. " / " .. stats.batKills .. " / " .. stats.witchKills },
            { "Accuracy", string.format("%.0f%%", acc) }, { "Kill streak", stats.streak .. " (best " .. stats.bestStreak .. ")" },
            { "Spells cast", stats.spellsCast },
        }
    elseif regionUnlocked then
        lines = {
            { "Bandits / Scouts", stats.banditKills .. " / " .. stats.scoutKills },
            { "Frozens / Snowmen", stats.frozenKills .. " / " .. stats.snowmanKills },
            { "Accuracy", string.format("%.0f%%", acc) }, { "Kill streak", stats.streak .. " (best " .. stats.bestStreak .. ")" },
            { "Spells cast", stats.spellsCast }, { "Alarms raised", stats.alertsRaised },
        }
    else
        lines = {
            { "Bandits", stats.banditKills }, { "Scouts", stats.scoutKills },
            { "Accuracy", string.format("%.0f%%", acc) }, { "Kill streak", stats.streak .. " (best " .. stats.bestStreak .. ")" },
            { "Loot boxes", stats.boxesOpened }, { "Alarms raised", stats.alertsRaised },
        }
    end
    for i, l in ipairs(lines) do
        setC(PAL.dim); lg.print(l[1], sx2 + 12, sy2 + 10 + (i - 1) * 19)
        setC(PAL.text); lg.printf(tostring(l[2]), sx2, sy2 + 10 + (i - 1) * 19, 218, "right")
    end

    -- Bottom-right: players (multiplayer)
    if MPS.online then
        local list = { { name = MPS.name, you = true, hp = p.hp, maxHp = p.maxHp, id = MPS.id, dead = p.dead, lives = p.lives, out = p.out } }
        for _, o in pairs(MPS.others) do
            if o.ready then list[#list + 1] = { name = o.name, hp = o.hp, maxHp = o.maxHp, id = o.id, dead = o.dead, lives = o.lives, out = o.out } end
        end
        local ph = 30 + #list * 24
        local px, py = sw - 250, sh - 14 - ph
        panel(px, py, 236, ph)
        shadowText((MPS.role == "host" and "HOSTING" or "PLAYERS") .. "  " .. #list .. "/4", px, py + 6, 236, "center", PAL.gold, fonts.small)
        for i, it in ipairs(list) do
            local y = py + 26 + (i - 1) * 24
            local c = X.PLAYER_COLORS[((it.id - 1) % #X.PLAYER_COLORS) + 1]
            lg.setColor(c[1], c[2], c[3])
            lg.circle("fill", px + 16, y + 9, 5)
            lg.setFont(fonts.small)
            setC(it.dead and PAL.red or PAL.text)
            local tag = it.out and " (out)" or (it.dead and " (down)" or (it.you and " (you)" or ""))
            local nm = it.name
            while #nm > 1 and fonts.small:getWidth(nm .. tag) > 122 do nm = nm:sub(1, -2) end
            lg.print(nm .. tag, px + 28, y + 1)
            for k = 1, 3 do X.drawHeart(px + 156 + (k - 1) * 13, y + 10, 5, k <= (it.lives or 3)) end
            bar(px + 196, y + 4, 30, 8, (it.hp or 0) / (it.maxHp or 100), PAL.red)
        end
    end

    lg.pop()
end

function drawBanner()
    if not banner then return end
    local sw = lg.getWidth()
    local a = clamp(min(banner.t, 4.5 - banner.t) * 1.5, 0, 1)
    local y = 150
    lg.setColor(0, 0, 0, 0.35 * a)
    lg.rectangle("fill", 0, y - 8, sw, 92)
    lg.setFont(fonts.large)
    lg.setColor(0, 0, 0, 0.7 * a)
    lg.printf(banner.title, 3, y + 3, sw, "center")
    lg.setColor(banner.col[1], banner.col[2], banner.col[3], a)
    lg.printf(banner.title, 0, y, sw, "center")
    lg.setFont(fonts.normal)
    lg.setColor(0.95, 0.95, 0.95, a)
    lg.printf(banner.sub, 0, y + 48, sw, "center")
end

local function drawFog(px, py, vis, col, strength)
    local sw, sh = lg.getDimensions()
    local R = 900 * vis                 -- clear radius shrinks with visibility
    local s = R * 1.35 / 128
    local half = 128 * s
    lg.setColor(col[1], col[2], col[3], strength)
    if fogImg then lg.draw(fogImg, px, py, 0, s, s, 128, 128) end
    local x0, y0, x1, y1 = px - half, py - half, px + half, py + half
    if y0 > 0 then lg.rectangle("fill", 0, 0, sw, y0) end
    if y1 < sh then lg.rectangle("fill", 0, y1, sw, sh - y1) end
    local top, bottom = max(0, y0), min(sh, y1)
    if x0 > 0 then lg.rectangle("fill", 0, top, x0, bottom - top) end
    if x1 < sw then lg.rectangle("fill", x1, top, sw - x1, bottom - top) end
end

-- Day / night: darkness with a light around the player, warm twilight, fireflies
function X.drawNight()
    local sw, sh = lg.getDimensions()
    local dark = X.darkness()
    local tw = X.twilight()
    if tw > 0.01 then
        lg.setColor(1, 0.45, 0.15, 0.13 * tw)
        lg.rectangle("fill", 0, 0, sw, sh)
    end
    if dark <= 0.01 then return end
    local px, py = X.ws(me.x, me.y)
    local col = me.region == "frozen" and { 0.02, 0.05, 0.18 } or (me.region == "spooky" and { 0.04, 0.02, 0.1 } or { 0.02, 0.04, 0.16 })
    lg.setColor(col[1], col[2], col[3], 0.3 * dark)
    lg.rectangle("fill", 0, 0, sw, sh)
    if me.headLamp then dark = dark * 0.7 end           -- Miner's Hat: the headlamp lights up the night
    drawFog(px, py, me.headLamp and 1.0 or 0.7, col, 0.45 * dark)   -- not VERY dark: the area around you stays visible
    lg.setBlendMode("add")
    local G = X.glowImg
    local function glow(x, y, radius, r, g, b, a)
        if not G then return end
        lg.setColor(r, g, b, a)
        lg.draw(G, x, y, 0, radius / 64, radius / 64, 64, 64)
    end
    -- the shed lantern
    local S = X.SHED
    local lx, ly = X.ws(S.x + S.w / 2, S.y + 30)
    if lx > -300 and lx < sw + 300 and ly > -300 and ly < sh + 300 then
        local fl = 0.9 + 0.1 * sin(menuTime * 9)
        glow(lx, ly, 190, 1, 0.65, 0.25, 0.5 * dark * fl)
        glow(lx, ly, 60, 1, 0.85, 0.5, 0.6 * dark * fl)
    end
    -- other players carry a small light too
    for _, o in pairs(MPS.others) do
        if o.ready and not o.dead then
            local gx, gy = X.ws(o.x, o.y)
            glow(gx, gy, 110, 1, 0.8, 0.5, 0.25 * dark)
        end
    end
    -- fireflies: plain little yellow dots
    for _, f in ipairs(X.fireflies) do
        local fx, fy = X.ws(f.x, f.y)
        local blink = clamp(0.5 + 0.7 * sin(menuTime * f.sp + f.ph), 0, 1) * min(1, f.life) * dark
        lg.setBlendMode("alpha")
        lg.setColor(1, 0.9, 0.2, blink)
        lg.circle("fill", fx, fy, 2.5)
    end
    lg.setBlendMode("alpha")
end

-- Full-screen jumpscare: a rotten jack-o'-lantern face (a = 1 -> 0 as it fades)
local function drawJumpscare(sw, sh, a)
    local cx, cy = sw / 2 + randRange(-10, 10), sh / 2 + randRange(-10, 10)
    local R = min(sw, sh) * 0.46 * (1.15 - a * 0.15)
    lg.setColor(0, 0, 0, 0.6 + 0.35 * a)
    lg.rectangle("fill", 0, 0, sw, sh)
    lg.setColor(0.45, 0.16, 0.03, a)
    lg.ellipse("fill", cx - R * 0.45, cy, R * 0.62, R)
    lg.ellipse("fill", cx + R * 0.45, cy, R * 0.62, R)
    lg.setColor(0.7, 0.28, 0.05, a)
    lg.ellipse("fill", cx, cy, R * 0.75, R * 1.02)
    lg.setColor(0.35, 0.12, 0.03, a)
    lg.setLineWidth(3)
    lg.line(cx - R * 0.3, cy - R * 0.95, cx - R * 0.2, cy - R * 0.7, cx - R * 0.32, cy - R * 0.55)
    lg.line(cx + R * 0.5, cy + R * 0.6, cx + R * 0.38, cy + R * 0.8)
    lg.setLineWidth(1)
    -- eyes
    lg.setColor(0.03, 0, 0, a)
    lg.polygon("fill", cx - R * 0.6, cy - R * 0.12, cx - R * 0.12, cy - R * 0.22, cx - R * 0.32, cy - R * 0.62)
    lg.polygon("fill", cx + R * 0.6, cy - R * 0.12, cx + R * 0.12, cy - R * 0.22, cx + R * 0.32, cy - R * 0.62)
    lg.setColor(1, 0.08, 0.04, a)
    lg.circle("fill", cx - R * 0.33, cy - R * 0.3, R * 0.07)
    lg.circle("fill", cx + R * 0.33, cy - R * 0.3, R * 0.07)
    lg.setColor(1, 1, 0.8, a)
    lg.circle("fill", cx - R * 0.31, cy - R * 0.32, R * 0.02)
    lg.circle("fill", cx + R * 0.35, cy - R * 0.32, R * 0.02)
    -- jagged mouth
    local mw, my = R * 0.62, cy + R * 0.12
    lg.setColor(0.03, 0, 0, a)
    lg.arc("fill", cx, my, mw, 0.05, pi - 0.05, 24)
    lg.setColor(0.92, 0.86, 0.68, a)
    for k = 0, 6 do
        local tx = cx - mw * 0.85 + k * (mw * 1.7 / 6)
        lg.polygon("fill", tx - R * 0.06, my, tx + R * 0.06, my, tx, my + R * 0.2)
    end
    for k = 0, 3 do
        local tx = cx - mw * 0.5 + k * (mw / 3)
        local by = my + mw * 0.75
        lg.polygon("fill", tx - R * 0.05, by, tx + R * 0.05, by, tx, by - R * 0.16)
    end
    lg.setFont(fonts.huge)
    lg.setColor(0.9, 0.05, 0.05, a)
    lg.printf("SPOOKED", 0, sh - 130 + randRange(-4, 4), sw, "center")
end

function drawWeather()
    local sw, sh = lg.getDimensions()
    local region = player.region
    local w = weather[region]
    local px, py = X.ws(player.x, player.y)
    if region == "desert" then
        local it = w.intensity
        if it > 0.01 then
            lg.setColor(0.1, 0.12, 0.2, 0.18 * it)
            lg.rectangle("fill", 0, 0, sw, sh)
            lg.setLineWidth(1.5)
            local n = floor(#rainDrops * it)
            for i = 1, n do
                local d = rainDrops[i]
                lg.setColor(0.72, 0.8, 0.95, 0.45)
                lg.line(d.x, d.y, d.x - d.len * 0.18, d.y + d.len)
            end
            lg.setLineWidth(1)
            drawFog(px, py, weatherVis("desert"), { 0.07, 0.08, 0.12 }, 0.4 * it)
        end
        if lightning > 0 then
            lg.setColor(0.9, 0.95, 1, lightning * 0.55)
            lg.rectangle("fill", 0, 0, sw, sh)
        end
    elseif region == "spooky" then
        -- permanent gloom, floating embers and will-o'-wisps
        lg.setColor(0.12, 0.04, 0.18, 0.22)
        lg.rectangle("fill", 0, 0, sw, sh)
        for i = 1, 80 do
            local f = snowFlakes[i]
            local glow = 0.4 + 0.4 * sin(menuTime * 3 + f.ph)
            if i % 3 == 0 then lg.setColor(0.5, 1, 0.55, glow * 0.7) else lg.setColor(1, 0.6, 0.2, glow * 0.6) end
            lg.circle("fill", f.x, f.y, f.s * 0.9)
        end
        drawFog(px, py, 0.82, { 0.06, 0.03, 0.09 }, 0.6)
    elseif region == "swamp" then
        -- humid green murk and little floating spores
        lg.setColor(0.05, 0.15, 0.03, 0.18)
        lg.rectangle("fill", 0, 0, sw, sh)
        for i = 1, 60 do
            local f = snowFlakes[i]
            lg.setColor(0.75, 0.95, 0.45, 0.25 + 0.2 * sin(menuTime * 2 + f.ph))
            lg.circle("fill", f.x, f.y, f.s * 0.6)
        end
        drawFog(px, py, 0.9, { 0.03, 0.1, 0.03 }, 0.35)
    elseif region == "volcanic" then
        -- always a few embers; an ash storm adds falling grey ash and a red haze
        local it = w and w.intensity or 0
        lg.setColor(0.35, 0.08, 0.02, 0.12 + 0.18 * it)
        lg.rectangle("fill", 0, 0, sw, sh)
        for i = 1, 50 do
            local f = snowFlakes[i]
            local glow = 0.5 + 0.5 * sin(menuTime * 4 + f.ph)
            lg.setColor(1, 0.45 + 0.3 * glow, 0.1, 0.55 * glow)
            lg.circle("fill", f.x, sh - f.y, f.s * 0.7)
        end
        if it > 0.01 then
            local n = floor(40 + 160 * it)
            for i = 1, min(n, #snowFlakes) do
                local f = snowFlakes[i]
                lg.setColor(0.45, 0.42, 0.4, 0.6)
                lg.circle("fill", f.x, f.y, f.s * f.z * 0.9)
            end
            drawFog(px, py, weatherVis("volcanic"), { 0.12, 0.08, 0.07 }, 0.7 * it)
        end
    else
        local it = w.intensity
        local n = floor(60 + (#snowFlakes - 60) * it)
        for i = 1, n do
            local f = snowFlakes[i]
            lg.setColor(1, 1, 1, 0.5 + 0.4 * (f.z - 0.6))
            if it > 0.3 then
                lg.setLineWidth(f.s * f.z)
                lg.line(f.x, f.y, f.x - 10 * it * f.z, f.y - 2 * it)
                lg.setLineWidth(1)
            else
                lg.circle("fill", f.x, f.y, f.s * f.z)
            end
        end
        if it > 0.01 then
            lg.setColor(0.85, 0.9, 0.96, 0.22 * it)
            lg.rectangle("fill", 0, 0, sw, sh)
            drawFog(px, py, weatherVis("frozen"), { 0.88, 0.92, 0.97 }, it)
        end
    end
    -- SPOOKED: jumpscare, then 3 seconds of darkness
    if player.spookT > 0 then
        drawFog(px, py, 0.3, { 0, 0, 0 }, 0.95 * min(1, player.spookT / 0.6))
        if player.spookT > 2.3 then drawJumpscare(sw, sh, (player.spookT - 2.3) / 0.7) end
    end
    -- THE CURSED SPELL: 2 seconds of total blindness
    if player.blindT > 0 then
        lg.setColor(0, 0, 0, min(1, player.blindT * 4))
        lg.rectangle("fill", 0, 0, sw, sh)
        lg.setFont(fonts.large)
        lg.setColor(0.6, 0.05, 0.1, 0.4 + 0.4 * sin(menuTime * 14))
        lg.printf(". . .", 0, sh / 2 - 20, sw, "center")
    end
    if snowFlash > 0 then
        lg.setColor(1, 1, 1, snowFlash * 0.85)
        lg.rectangle("fill", 0, 0, sw, sh)
    end
end

function drawCrosshair()
    if X.cut then return end
    local mx, my = love.mouse.getPosition()
    local wsp = player and WEAPONS[player.weapon] and WEAPONS[player.weapon].spread or 0
    local spread = 6 + (player and player.recoil or 0) * 8 + wsp * 40
    lg.setLineWidth(2)
    lg.setColor(0, 0, 0, 0.6)
    lg.circle("line", mx, my, spread + 5)
    if player and player.iciclesT > 0 then lg.setColor(0.6, 0.92, 1, 0.95) else lg.setColor(1, 0.95, 0.8, 0.95) end
    lg.line(mx - spread - 8, my, mx - spread, my)
    lg.line(mx + spread, my, mx + spread + 8, my)
    lg.line(mx, my - spread - 8, mx, my - spread)
    lg.line(mx, my + spread, mx, my + spread + 8)
    lg.circle("fill", mx, my, 1.5)
    lg.setLineWidth(1)
end

function drawVignette()
    local sw, sh = lg.getDimensions()
    local low = player.hp / player.maxHp < 0.3 and (0.25 + 0.15 * sin(menuTime * 5)) or 0
    local a = max(hurtFlash * 0.5, low)
    if a > 0.01 then
        for i = 1, 12 do
            local t = i / 12
            lg.setColor(0.7, 0, 0, a * (1 - t) * 0.35)
            lg.setLineWidth(20)
            lg.rectangle("line", (i - 1) * 10, (i - 1) * 10, sw - (i - 1) * 20, sh - (i - 1) * 20)
        end
        lg.setLineWidth(1)
    end
end
end

------------------------------------------------------------------------------
-- Drawing: overlays
------------------------------------------------------------------------------
local function dimScreen(a)
    local sw, sh = lg.getDimensions()
    lg.setColor(0, 0, 0, a or 0.6)
    lg.rectangle("fill", 0, 0, sw, sh)
end

------------------------------------------------------------------------------
-- Drawing: Treasure Goblin, merchant, falling rocks, revive markers,
-- the merchant's shop and achievement toasts
------------------------------------------------------------------------------
do
X.DRAW.goblin = function(e, alpha)
    local r = e.r
    local hop = abs(sin(e.hop)) * 4
    lg.setColor(0, 0, 0, 0.3 * alpha)
    lg.ellipse("fill", e.x, e.y + r * 0.8, r * 1.2, r * 0.45)
    -- sparkles of gold behind it
    for i = 1, 3 do
        local a = menuTime * 3 + i * 2.1
        lg.setColor(1, 0.85, 0.2, (0.5 + 0.5 * sin(menuTime * 9 + i)) * alpha)
        lg.circle("fill", e.x + cos(a) * r * 1.6, e.y + sin(a) * r * 1.2 - hop, 2)
    end
    lg.push()
    lg.translate(e.x, e.y - hop)
    lg.rotate(e.angle)
    -- the bag of loot on its back
    lg.setColor(0.55, 0.38, 0.18, alpha)
    lg.circle("fill", -r * 0.85, 0, r * 0.8)
    lg.setColor(1, 0.82, 0.2, alpha)
    lg.circle("fill", -r * 0.85, -r * 0.2, r * 0.25)
    lg.circle("fill", -r * 0.6, r * 0.25, r * 0.2)
    lg.setColor(0.35, 0.22, 0.1, alpha)
    lg.setLineWidth(2)
    lg.line(-r * 0.4, -r * 0.5, -r * 0.4, r * 0.5)
    lg.setLineWidth(1)
    -- body
    if e.hitFlash > 0 then lg.setColor(1, 1, 1, alpha) else lg.setColor(0.42, 0.62, 0.25, alpha) end
    lg.circle("fill", 0, 0, r * 0.8)
    -- big pointy ears
    lg.setColor(0.36, 0.55, 0.2, alpha)
    lg.polygon("fill", r * 0.1, -r * 0.6, -r * 0.2, -r * 1.5, r * 0.45, -r * 0.55)
    lg.polygon("fill", r * 0.1, r * 0.6, -r * 0.2, r * 1.5, r * 0.45, r * 0.55)
    -- greedy eyes
    lg.setColor(1, 0.9, 0.2, alpha)
    lg.circle("fill", r * 0.45, -r * 0.28, r * 0.2)
    lg.circle("fill", r * 0.45, r * 0.28, r * 0.2)
    lg.setColor(0.1, 0.05, 0, alpha)
    lg.circle("fill", r * 0.52, -r * 0.28, r * 0.09)
    lg.circle("fill", r * 0.52, r * 0.28, r * 0.09)
    lg.pop()
    -- timer above it
    if e.lifeT then
        lg.setFont(fonts.tiny)
        lg.setColor(0, 0, 0, 0.6 * alpha)
        lg.printf(string.format("%.0fs", max(0, e.lifeT)), e.x - 39, e.y - r - 29, 80, "center")
        lg.setColor(1, 0.85, 0.2, alpha)
        lg.printf(string.format("%.0fs", max(0, e.lifeT)), e.x - 40, e.y - r - 30, 80, "center")
    end
end

-- the travelling merchant next to the shed
local function drawMerchant()
    if not X.EV or X.EV.k ~= "merchant" then return end
    local x, y = X.merchantSpot()
    -- cart
    lg.setColor(0, 0, 0, 0.3)
    lg.ellipse("fill", x + 50, y + 26, 50, 14)
    lg.setColor(0.45, 0.3, 0.16)
    lg.rectangle("fill", x + 14, y - 14, 74, 34, 4, 4)
    lg.setColor(0.6, 0.42, 0.22)
    lg.rectangle("fill", x + 18, y - 10, 66, 10)
    lg.setColor(0.85, 0.25, 0.2)
    lg.polygon("fill", x + 10, y - 16, x + 92, y - 16, x + 84, y - 40, x + 18, y - 40)
    lg.setColor(0.95, 0.9, 0.8)
    for i = 0, 3 do lg.polygon("fill", x + 18 + i * 18, y - 40, x + 27 + i * 18, y - 40, x + 24 + i * 18, y - 16, x + 16 + i * 18, y - 16) end
    lg.setColor(0.25, 0.16, 0.08)
    lg.circle("fill", x + 28, y + 22, 9)
    lg.circle("fill", x + 74, y + 22, 9)
    lg.setColor(0.6, 0.45, 0.25)
    lg.circle("fill", x + 28, y + 22, 3)
    lg.circle("fill", x + 74, y + 22, 3)
    -- crates and potions on the cart
    lg.setColor(0.55, 1, 0.6)
    lg.circle("fill", x + 30, y - 18, 5)
    lg.setColor(1, 0.4, 0.4)
    lg.circle("fill", x + 44, y - 18, 5)
    -- the merchant (hooded, with a big backpack)
    local bob = sin(menuTime * 2) * 1.5
    lg.setColor(0, 0, 0, 0.3)
    lg.ellipse("fill", x - 14, y + 14, 16, 7)
    lg.setColor(0.5, 0.36, 0.2)
    lg.rectangle("fill", x - 30, y - 22 + bob, 18, 26, 4, 4)
    lg.setColor(0.3, 0.45, 0.55)
    lg.circle("fill", x - 14, y - 4 + bob, 14)
    lg.setColor(0.22, 0.34, 0.42)
    lg.circle("fill", x - 14, y - 18 + bob, 10)
    lg.setColor(0.95, 0.8, 0.6)
    lg.circle("fill", x - 10, y - 16 + bob, 6)
    lg.setColor(0.15, 0.1, 0.05)
    lg.circle("fill", x - 7, y - 17 + bob, 1.4)
    -- label
    local near = X.nearMerchant()
    lg.setFont(fonts.small)
    local txt = near and "MERCHANT  -  press E to trade" or "TRAVELLING MERCHANT"
    lg.setColor(0, 0, 0, 0.6)
    lg.printf(txt, x - 159, y - 69, 360, "center")
    lg.setColor(1, 0.85, 0.45, near and (0.75 + 0.25 * sin(menuTime * 5)) or 0.9)
    lg.printf(txt, x - 160, y - 70, 360, "center")
end

local function drawSkyRocks()
    for _, m in ipairs(X.skyRocks) do
        local p = 1 - clamp(m.t / m.maxT, 0, 1)
        lg.setColor(1, 0.15, 0.1, 0.12 + 0.3 * p)
        lg.circle("fill", m.x, m.y, X.METEOR_R)
        lg.setColor(1, 0.2, 0.1, 0.5 + 0.5 * p)
        lg.setLineWidth(2 + 2 * p)
        lg.circle("line", m.x, m.y, X.METEOR_R)
        lg.circle("line", m.x, m.y, X.METEOR_R * (1 - p) + 4)
        lg.setLineWidth(1)
        local h = (1 - p) * 640
        local rx, ry = m.x - h * 0.45, m.y - h
        lg.setColor(1, 0.5, 0.1, 0.35)
        lg.line(rx, ry, rx - 40, ry - 90)
        lg.setColor(1, 0.6, 0.15, 0.55)
        lg.circle("fill", rx - 6, ry - 12, 18)
        lg.setColor(0.35, 0.25, 0.2)
        lg.circle("fill", rx, ry, 15)
        lg.setColor(1, 0.45, 0.1)
        lg.circle("fill", rx + 4, ry + 4, 6)
    end
end

-- downed teammates: a pulsing marker, "hold V" and the progress ring
local function drawRevive()
    if not MPS.online then return end
    for id, o in pairs(MPS.others) do
        if o.ready and o.dead and not o.out and o.x then
            local pulse = 0.5 + 0.5 * sin(menuTime * 6)
            lg.setColor(1, 0.3, 0.3, 0.25 + 0.25 * pulse)
            lg.circle("line", o.x, o.y, 30 + 6 * pulse)
            lg.setFont(fonts.small)
            local near = X.reviveTarget == o
            local txt = near and "Hold V to revive" or ((o.name or "Teammate") .. " is DOWN")
            lg.setColor(0, 0, 0, 0.6)
            lg.printf(txt, o.x - 119, o.y - 61, 240, "center")
            lg.setColor(near and 0.5 or 1, near and 1 or 0.45, near and 0.6 or 0.4)
            lg.printf(txt, o.x - 120, o.y - 62, 240, "center")
            if X.rev and X.rev.id == id then
                local k = clamp(X.rev.t / X.REVIVE_TIME, 0, 1)
                lg.setColor(0, 0, 0, 0.5)
                lg.setLineWidth(6)
                lg.circle("line", o.x, o.y, 40)
                lg.setColor(0.5, 1, 0.6)
                lg.arc("line", "open", o.x, o.y, 40, -pi / 2, -pi / 2 + k * 2 * pi)
                lg.setLineWidth(1)
            end
        end
    end
end

function X.drawExtrasWorld()
    drawMerchant()
    drawSkyRocks()
    drawRevive()
end

-- the merchant's little shop (E)
function X.drawMerchantShop()
    local sw, sh = lg.getDimensions()
    dimScreen(0.6)
    local w, h = 620, 380
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("TRAVELLING MERCHANT", x, y + 14, w, "center", { 1, 0.85, 0.45 }, fonts.large)
    shadowText(string.format("Your gold: %dg   |   leaves in %s", floor(me.gold), formatTime(max(0, X.EV and X.EV.t or 0))),
        x, y + 56, w, "center", PAL.text, fonts.normal)
    for i, it in ipairs(X.merchantStock or X.MERCHANT_ITEMS) do
        local iy = y + 92 + (i - 1) * 76
        lg.setColor(1, 1, 1, 0.05)
        lg.rectangle("fill", x + 20, iy, w - 40, 68, 6, 6)
        lg.setFont(fonts.medium)
        setC(PAL.text)
        lg.print(i .. ". " .. it.name, x + 34, iy + 8)
        lg.setFont(fonts.small)
        setC(PAL.dim)
        lg.print(it.desc, x + 34, iy + 38)
        local sold = it.id == "potion" and X.potionBought
        button(sold and "SOLD" or (it.price .. "g"), x + w - 190, iy + 11, 150, 46, function() X.buyMerchant(i) end,
            not sold and me.gold >= it.price)
    end
    shadowText("Click an item or press 1-3.   E / ESC to close", x, y + h - 40, w, "center", PAL.dim, fonts.small)
end

-- achievement toasts (every screen)
function X.drawToasts()
    local T = X.toasts
    if #T == 0 or (gameState == "play" and X.cut) then return end   -- no pop-ups during cutscenes
    local sw = lg.getWidth()
    local a = T[1]
    a.t = a.t + love.timer.getDelta()
    local k = min(1, a.t / 0.35, (4 - a.t) / 0.35)
    if a.t >= 4 then table.remove(T, 1) return end
    local w, h = 380, 70
    local x, y = sw / 2 - w / 2, -h + (h + 20) * max(0, k)
    lg.setColor(0, 0, 0, 0.5)
    lg.rectangle("fill", x + 4, y + 5, w, h, 10, 10)
    lg.setColor(0.16, 0.12, 0.06, 0.97)
    lg.rectangle("fill", x, y, w, h, 10, 10)
    lg.setColor(1, 0.8, 0.25)
    lg.setLineWidth(2)
    lg.rectangle("line", x, y, w, h, 10, 10)
    lg.setLineWidth(1)
    X.drawBadge(a.a, x + 38, y + h / 2, 24, true)
    shadowText("ACHIEVEMENT UNLOCKED", x + 72, y + 10, w - 84, "left", { 1, 0.8, 0.3 }, fonts.tiny)
    shadowText(a.a.name, x + 72, y + 24, w - 84, "left", PAL.text, fonts.medium)
    shadowText(a.a.desc, x + 72, y + 50, w - 84, "left", PAL.dim, fonts.tiny)
end

-- a round badge with a small symbol (gold when unlocked)
function X.drawBadge(a, cx, cy, r, got)
    local g = got and 1 or 0
    lg.setColor(0, 0, 0, 0.4)
    lg.circle("fill", cx + 2, cy + 3, r)
    if got then lg.setColor(0.75, 0.55, 0.15) else lg.setColor(0.22, 0.2, 0.18) end
    lg.circle("fill", cx, cy, r)
    if got then lg.setColor(1, 0.85, 0.35) else lg.setColor(0.35, 0.32, 0.3) end
    lg.setLineWidth(2)
    lg.circle("line", cx, cy, r)
    lg.circle("line", cx, cy, r * 0.78)
    lg.setLineWidth(1)
    local c = got and { 0.3, 0.18, 0.05 } or { 0.45, 0.42, 0.4 }
    lg.setColor(c)
    local s = r * 0.42
    local id = a.id
    if id == "firstblood" then
        lg.circle("fill", cx, cy + s * 0.3, s * 0.6)
        lg.polygon("fill", cx - s * 0.55, cy + s * 0.1, cx + s * 0.55, cy + s * 0.1, cx, cy - s)
    elseif id == "centurion" then
        lg.setFont(fonts.small) lg.printf("100", cx - r, cy - 8, r * 2, "center")
    elseif id == "maxlevel" then
        lg.polygon("fill", cx, cy - s, cx + s, cy + s * 0.2, cx + s * 0.4, cy + s * 0.2, cx + s * 0.4, cy + s,
            cx - s * 0.4, cy + s, cx - s * 0.4, cy + s * 0.2, cx - s, cy + s * 0.2)
    elseif id == "infiltrator" then
        lg.rectangle("fill", cx - s, cy - s * 0.2, s * 2, s * 1.2)
        for i = -1, 1 do lg.rectangle("fill", cx + i * s * 0.7 - s * 0.25, cy - s, s * 0.5, s * 0.6) end
    elseif id == "gatekeeper" then
        lg.polygon("fill", cx, cy - s * 1.1, cx + s * 0.7, cy + s * 0.2, cx + s * 0.3, cy + s, cx - s * 0.3, cy + s, cx - s * 0.7, cy + s * 0.2)
    elseif id == "guardian" then
        lg.polygon("fill", cx - s * 1.1, cy + s * 0.2, cx + s * 1.1, cy + s * 0.2, cx, cy - s * 1.1)
        lg.ellipse("fill", cx, cy + s * 0.6, s * 0.9, s * 0.5)
    elseif id == "nightmare" then
        lg.circle("fill", cx, cy, s)
        if got then lg.setColor(0.75, 0.55, 0.15) else lg.setColor(0.22, 0.2, 0.18) end
        lg.circle("fill", cx + s * 0.45, cy - s * 0.3, s * 0.85)
    elseif id == "survivor" then
        lg.setFont(fonts.small) lg.printf("W5", cx - r, cy - 8, r * 2, "center")
    elseif id == "collector" then
        for i = -1, 1 do lg.rectangle("fill", cx - s + (i + 1) * s * 0.1, cy + i * s * 0.6 - s * 0.15, s * 2, s * 0.3) end
    elseif id == "lucky" then
        for i = 0, 3 do
            local an = i * pi / 2 + pi / 4
            lg.circle("fill", cx + cos(an) * s * 0.5, cy + sin(an) * s * 0.5, s * 0.45)
        end
    elseif id == "savior" then
        lg.rectangle("fill", cx - s * 0.3, cy - s, s * 0.6, s * 2)
        lg.rectangle("fill", cx - s, cy - s * 0.3, s * 2, s * 0.6)
    elseif id == "treasure" then
        lg.circle("fill", cx, cy + s * 0.2, s * 0.85)
        lg.rectangle("fill", cx - s * 0.3, cy - s, s * 0.6, s * 0.5)
    elseif id == "explorer" then
        lg.setLineWidth(2)
        lg.circle("line", cx, cy, s)
        lg.setLineWidth(1)
        lg.polygon("fill", cx, cy - s, cx + s * 0.3, cy, cx, cy + s, cx - s * 0.3, cy)
    elseif id == "spellbinder" then
        for i = 0, 4 do
            local a1, a2 = -pi / 2 + i * 2 * pi / 5, -pi / 2 + (i + 0.5) * 2 * pi / 5
            lg.polygon("fill", cx, cy, cx + cos(a1) * s * 1.1, cy + sin(a1) * s * 1.1, cx + cos(a2) * s * 0.45, cy + sin(a2) * s * 0.45)
            lg.polygon("fill", cx, cy, cx + cos(a1) * s * 1.1, cy + sin(a1) * s * 1.1, cx + cos(a1 - pi / 5) * s * 0.45, cy + sin(a1 - pi / 5) * s * 0.45)
        end
    end
end
end

------------------------------------------------------------------------------
-- Drawing: hotbar, shield, utilities in the world, the shed chest, the new inventory
------------------------------------------------------------------------------
do
-- name / icon / info of any item id (weapon, utility or armor)
function X.itemName(id)
    local it = WEAPONS[id] or X.UTIL[id] or X.ARMOR[id]
    return it and it.name or "?"
end

local function slotBox(x, y, w, h, sel, hov, empty)
    lg.setColor(0, 0, 0, 0.35)
    lg.rectangle("fill", x + 3, y + 4, w, h, 7, 7)
    if sel then lg.setColor(0.3, 0.22, 0.1, 0.96) elseif hov then lg.setColor(0.22, 0.16, 0.1, 0.95) else lg.setColor(0.11, 0.08, 0.06, empty and 0.75 or 0.93) end
    lg.rectangle("fill", x, y, w, h, 7, 7)
    lg.setLineWidth(sel and 3 or 1.5)
    if sel then setC(PAL.gold) elseif hov then lg.setColor(1, 0.8, 0.45, 0.9) else setC(PAL.border, empty and 0.4 or 0.75) end
    lg.rectangle("line", x, y, w, h, 7, 7)
    lg.setLineWidth(1)
end
X.slotBox = slotBox

-- the blue SHIELD tag at the right end of the health bar
function X.drawShieldTag(bx, by, bw, bh)
    local p = me
    if (p.maxShield or 0) <= 0 then return end
    local w = 86
    local x = bx + bw - w + 4
    lg.setColor(0.05, 0.1, 0.25, 0.95)
    lg.rectangle("fill", x - 2, by - 2, w + 4, bh + 4, 4, 4)
    lg.setColor(0.2, 0.35, 0.95)
    lg.rectangle("line", x - 2, by - 2, w + 4, bh + 4, 4, 4)
    local k = p.maxShield > 0 and p.shield / p.maxShield or 0
    lg.setColor(0.2, 0.55, 1, 0.95)
    lg.rectangle("fill", x + 2, by + 2, (w - 4) * k, bh - 4, 3, 3)
    shadowText(p.shield > 0 and ("+" .. math.ceil(p.shield)) or "BROKEN", x, by + bh / 2 - 7, w, "center",
        p.shield > 0 and { 1, 1, 1 } or { 0.6, 0.7, 0.9 }, fonts.small)
end

-- the HOTBAR (bottom centre): 4 guns or 4 utilities, mouse wheel selects, G switches
function X.drawHotbar(p, sw, sh)
    local hb = X.hb
    local util = hb.mode == "util"
    local n, w, h, gap = 4, 88, 66, 8
    local total = n * w + (n - 1) * gap
    local bx, by = sw / 2 - total / 2, sh - h - 14
    for i = 1, n do
        local x = bx + (i - 1) * (w + gap)
        local sel = util and hb.usel == i or (not util and hb.gsel == i)
        local id = util and (p.uslots and p.uslots[i]) or (not util and p.slots and p.slots[i])
        local y = by - (sel and 6 or 0)
        slotBox(x, y, w, h, sel, false, not id)
        lg.setFont(fonts.tiny)
        lg.setColor(1, 1, 1, 0.5)
        lg.print(tostring(i), x + 5, y + 3)
        if id then
            if util then
                X.drawWeaponIcon(id, x + w / 2, y + 28, 0.62)
                local uses = p.uses[id] or 0
                shadowText("x" .. uses, x, y + h - 18, w - 6, "right", uses > 0 and PAL.text or PAL.red, fonts.small)
                local cd = p.ucd[id] or 0
                if cd > 0 then
                    local k = cd / max(0.1, X.UTIL[id].cooldown)
                    lg.setColor(0, 0, 0, 0.55)
                    lg.rectangle("fill", x, y + h * (1 - k), w, h * k, 7, 7)
                    shadowText(tostring(math.ceil(cd)), x, y + 20, w, "center", { 0.7, 0.85, 1 }, fonts.medium)
                end
            else
                X.drawWeaponIcon(id, x + w / 2, y + 28, 0.5)
                shadowText(WEAPONS[id].name, x + 2, y + h - 16, w - 4, "center", sel and PAL.gold or PAL.dim, fonts.tiny)
            end
        else
            shadowText("empty", x, y + h / 2 - 7, w, "center", { 1, 1, 1, 0.25 }, fonts.tiny)
        end
    end
    -- above the hotbar: cooldown bar + ammo on its right
    local cy = by - 22
    local barW = total - 96
    local k, col
    if util then
        local id = p.uslots and p.uslots[hb.usel]
        local cd = id and (p.ucd[id] or 0) or 0
        k = id and (1 - cd / max(0.1, X.UTIL[id].cooldown)) or 0
        col = { 0.35, 0.65, 1 }
    else
        local wp = WEAPONS[p.weapon]
        k = p.unarmed and 0 or (1 - p.fireCd / wp.rate)
        col = PAL.gold
    end
    bar(bx, cy, barW, 10, clamp(k, 0, 1), col)
    shadowText(tostring(p.ammo), bx + barW + 6, cy - 12, 60, "right", p.ammo == 0 and PAL.red or PAL.text, fonts.medium)
    shadowText("AMMO", bx + barW + 70, cy - 4, 40, "left", PAL.dim, fonts.tiny)
    -- what is selected + how to switch
    local label
    if util then
        local id = p.uslots and p.uslots[hb.usel]
        label = "UTILITY: " .. (id and X.UTIL[id].name:upper() or "EMPTY") .. "   [G] guns"
    else
        local id = p.slots and p.slots[hb.gsel]
        local wp = id and WEAPONS[id]
        label = (wp and (wp.name:upper() .. string.format("  %d-%d DMG", wp.min, wp.max)
            .. (wp.spinup and string.format("  SPIN %d%%", floor((p.spin or 0) * 100)) or "")) or "NO WEAPON") .. "   [G] utilities"
    end
    shadowText(label, bx - 40, cy - 22, total + 80, "center", util and { 0.6, 0.8, 1 } or PAL.gold, fonts.small)
    local dashReady = p.dashCd <= 0 and p.stamina >= 25
    shadowText((dashReady and "DASH READY [SPACE]" or "DASH ...") .. "    [B] SPELLBOOK    [P] INVENTORY", bx - 80, cy - 40, total + 160, "center",
        dashReady and { 0.6, 0.9, 1, 0.8 } or { 0.6, 0.6, 0.6, 0.8 }, fonts.tiny)
    if not X.canSwitch() then
        shadowText("switching locked until your shot lands", bx - 40, cy - 56, total + 80, "center", { 1, 0.6, 0.4, 0.9 }, fonts.tiny)
    end
end

------------------------------------------------------------------------------
-- utilities in the world
------------------------------------------------------------------------------
local function drawChestWorld()
    local cx, cy = X.chestSpot()
    if dist(cx, cy, cam.x, cam.y) > 1400 then return end
    lg.setColor(0, 0, 0, 0.3)
    lg.ellipse("fill", cx + 2, cy + 14, 22, 7)
    lg.setColor(0.42, 0.26, 0.12)
    lg.rectangle("fill", cx - 20, cy - 12, 40, 26, 3, 3)
    lg.setColor(0.55, 0.35, 0.17)
    lg.rectangle("fill", cx - 20, cy - 16, 40, 10, 3, 3)
    lg.setColor(0.85, 0.7, 0.3)
    lg.rectangle("fill", cx - 20, cy - 8, 40, 3)
    lg.rectangle("fill", cx - 3, cy - 6, 6, 8)
    if X.nearChest() then
        lg.setFont(fonts.small)
        lg.setColor(0, 0, 0, 0.6)
        lg.printf("E - CHEST", cx - 79, cy - 41, 160, "center")
        lg.setColor(1, 0.85, 0.45, 0.75 + 0.25 * sin(menuTime * 5))
        lg.printf("E - CHEST", cx - 80, cy - 42, 160, "center")
    end
end

function X.drawKitWorld()
    drawChestWorld()
    -- bear traps
    for _, t in ipairs(X.traps) do
        local shut = t.sprung ~= nil
        lg.setColor(0, 0, 0, 0.25)
        lg.ellipse("fill", t.x, t.y + 4, 18, 7)
        lg.setColor(0.45, 0.45, 0.48, (t.armT or 0) > 0 and 0.6 or 1)
        lg.setLineWidth(3)
        lg.ellipse("line", t.x, t.y, shut and 8 or 15, shut and 4 or 8)
        lg.setLineWidth(1)
        lg.setColor(0.7, 0.7, 0.74)
        for k = -3, 3 do
            local ox = k * 4
            lg.line(t.x + ox, t.y - (shut and 3 or 7), t.x + ox, t.y - (shut and 6 or 11))
        end
        lg.setColor(0.6, 0.35, 0.15)
        lg.circle("fill", t.x, t.y, 3)
    end
    -- decoys: a scarecrow wearing a hat
    for _, d in ipairs(X.decoys) do
        local wob = sin(menuTime * 3 + d.id) * 0.06
        lg.setColor(0, 0, 0, 0.3)
        lg.ellipse("fill", d.x, d.y + 16, 16, 6)
        lg.push()
        lg.translate(d.x, d.y)
        lg.rotate(wob)
        lg.setColor(0.5, 0.35, 0.18)
        lg.rectangle("fill", -2, -20, 4, 36)
        lg.rectangle("fill", -18, -12, 36, 4)
        lg.setColor(0.7, 0.25, 0.2)
        lg.rectangle("fill", -9, -14, 18, 16, 3, 3)
        lg.setColor(0.85, 0.75, 0.45)
        lg.circle("fill", 0, -24, 8)
        lg.setColor(0.4, 0.25, 0.12)
        lg.ellipse("fill", 0, -31, 13, 4)
        lg.rectangle("fill", -7, -39, 14, 8, 2, 2)
        lg.pop()
        local k = d.hp / X.UTIL.decoy.hp
        lg.setColor(0, 0, 0, 0.5)
        lg.rectangle("fill", d.x - 18, d.y - 52, 36, 5)
        lg.setColor(0.95, 0.8, 0.4)
        lg.rectangle("fill", d.x - 18, d.y - 52, 36 * max(0, k), 5)
    end
    -- sentry turrets
    for _, tr in ipairs(X.turrets) do
        lg.setColor(0, 0, 0, 0.3)
        lg.ellipse("fill", tr.x, tr.y + 10, 18, 7)
        lg.setColor(0.3, 0.3, 0.33)
        lg.circle("fill", tr.x, tr.y, 15)
        lg.setColor(0.45, 0.47, 0.5)
        lg.circle("fill", tr.x, tr.y, 10)
        lg.push()
        lg.translate(tr.x, tr.y)
        lg.rotate(tr.ang)
        lg.setColor(0.22, 0.22, 0.25)
        lg.rectangle("fill", 2, -3, 22, 6, 2, 2)
        lg.pop()
        lg.setColor(1, 0.3, 0.2, 0.6 + 0.4 * sin(menuTime * 8))
        lg.circle("fill", tr.x, tr.y, 3)
        local k = tr.t / X.UTIL.turret.duration
        lg.setColor(0.4, 0.8, 1, 0.8)
        lg.arc("line", "open", tr.x, tr.y, 20, -pi / 2, -pi / 2 + 2 * pi * k)
    end
    -- thrown grenades / smoke bombs (with a shadow under the arc)
    for _, g in ipairs(X.thrown) do
        lg.setColor(0, 0, 0, 0.3)
        lg.ellipse("fill", g.x, g.y + 4, 7, 3)
        if g.kind == "grenade" then lg.setColor(0.3, 0.4, 0.22) else lg.setColor(0.3, 0.32, 0.35) end
        lg.circle("fill", g.x, g.y - (g.h or 0), 7)
        if g.kind == "grenade" then
            lg.setColor(1, 0.3, 0.2, 0.25 + 0.2 * sin(menuTime * 20))
            lg.circle("line", g.tx, g.ty, X.UTIL.grenade.radius)
        end
    end
    -- recall channel
    if me.recallT then
        local k = 1 - me.recallT / X.UTIL.recall.channel
        lg.setColor(0.55, 0.45, 1, 0.8)
        lg.setLineWidth(4)
        lg.arc("line", "open", me.x, me.y, 28, -pi / 2, -pi / 2 + 2 * pi * k)
        lg.setLineWidth(1)
    end
end

-- smoke clouds are drawn on top of everything in the world
function X.drawSmokes()
    for _, s in ipairs(X.smokes) do
        local a = min(1, s.t / 1.2, (s.maxT - s.t) / 0.4 + 0.15)
        for k = 0, 9 do
            local ang = k * 0.63 + menuTime * 0.15 * (k % 2 == 0 and 1 or -1)
            local d = s.r * (0.25 + 0.45 * ((k * 37) % 10) / 10)
            lg.setColor(0.62, 0.64, 0.67, 0.42 * a)
            lg.circle("fill", s.x + cos(ang) * d, s.y + sin(ang) * d, s.r * 0.45)
        end
        lg.setColor(0.68, 0.7, 0.72, 0.55 * a)
        lg.circle("fill", s.x, s.y, s.r * 0.6)
    end
end

------------------------------------------------------------------------------
-- the item info box (inventory, chest, shop)
------------------------------------------------------------------------------
-- execute weapons (fx "m", the Guided Missile) kill whatever they hit
function X.executes(w) return w.fx ~= nil and w.fx:find("m", 1, true) ~= nil end
-- "18-28 DMG", or "INSTANT KILL"
function X.dmgText(w)
    if X.executes(w) then return "INSTANT KILL" end
    return w.min .. "-" .. w.max .. " DMG"
end

function X.itemInfoLines(id)
    local w, u, a = WEAPONS[id], X.UTIL[id], X.ARMOR[id]
    if w then
        return w.name, string.format("%s  |  %.1f shots/s  |  %d px  |  speed %s%d%%", X.dmgText(w), 1 / w.rate, w.range,
            w.mod >= 0 and "+" or "", floor(w.mod * 100 + 0.5)), w.desc
    elseif u then
        return u.name, string.format("%d uses per run  |  cooldown %ds  |  %d credits", u.uses, u.cooldown, u.price), u.desc
    elseif a then
        if a.gold then return a.name, X.AR.SLOT_NAMES[a.slot] .. " slot  |  gold shop (H)", a.desc end
        return a.name, string.format("%s slot  |  +%d shield  |  speed %s%d%%  |  %d credits", X.AR.SLOT_NAMES[a.slot], a.shield,
            (a.speed or 0) >= 0 and "+" or "", floor((a.speed or 0) * 100 + 0.5), a.price), a.desc
    end
end

local function infoBox(x, y, w, h, id, fallback)
    lg.setColor(0.06, 0.08, 0.16, 0.9)
    lg.rectangle("fill", x, y, w, h, 8, 8)
    lg.setColor(0.25, 0.35, 0.85, 0.9)
    lg.setLineWidth(2)
    lg.rectangle("line", x, y, w, h, 8, 8)
    lg.setLineWidth(1)
    if id then
        local name, stat, desc = X.itemInfoLines(id)
        X.drawWeaponIcon(id, x + 50, y + h / 2, 0.55)
        shadowText(name or "", x + 100, y + 8, w - 110, "left", PAL.gold, fonts.medium)
        shadowText(stat or "", x + 100, y + 36, w - 110, "left", { 0.7, 0.85, 1 }, fonts.small)
        shadowText(desc or "", x + 100, y + 56, w - 110, "left", PAL.dim, fonts.tiny)
    else
        shadowText(fallback or "Hover over an item to see its info.", x, y + h / 2 - 8, w, "center", PAL.dim, fonts.small)
    end
end
X.infoBox = infoBox

------------------------------------------------------------------------------
-- the NEW INVENTORY (P): 4 weapon slots, 4 utility slots, armor, resources, info
------------------------------------------------------------------------------
local repairT = 0
function X.drawNewInventory()
    local p = me
    local sw, sh = lg.getDimensions()
    dimScreen(0.7)
    local w, h = min(sw - 20, 960), min(sh - 10, 600)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("INVENTORY", x, y + 14, w, "center", PAL.gold, fonts.large)
    -- the X in the corner
    local cx, cyy = x + w - 46, y + 14
    local mx, my = love.mouse.getPosition()
    local hx = mx >= cx and mx <= cx + 32 and my >= cyy and my <= cyy + 32
    lg.setColor(1, hx and 0.95 or 0.85, hx and 0.75 or 0.55)
    lg.setLineWidth(5)
    lg.line(cx + 4, cyy + 4, cx + 28, cyy + 28)
    lg.line(cx + 28, cyy + 4, cx + 4, cyy + 28)
    lg.setLineWidth(1)
    buttons[#buttons + 1] = { x = cx, y = cyy, w = 32, h = 32, enabled = true, fn = function() overlay = nil love.mouse.setVisible(false) end }

    local colW = floor((w - 120) / 3.3)
    local sx1, sx2, sx3 = x + 30, x + 50 + colW, x + 70 + colW * 2
    local slotH, slotGap, top = 62, 12, y + 96
    local hover
    shadowText("Weapons", sx1, top - 26, colW, "left", PAL.text, fonts.normal)
    shadowText("Utility", sx2, top - 26, colW, "left", PAL.text, fonts.normal)
    shadowText("Armor", sx3, top - 26, w - (sx3 - x) - 30, "center", PAL.text, fonts.normal)
    for i = 1, 4 do
        local yy = top + (i - 1) * (slotH + slotGap)
        -- weapon slot
        local id = p.slots[i]
        local hov = mx >= sx1 and mx <= sx1 + colW and my >= yy and my <= yy + slotH
        if hov and id then hover = id end
        slotBox(sx1, yy, colW, slotH, X.hb.mode == "gun" and X.hb.gsel == i, hov, not id)
        shadowText(i .. ".", sx1 + 8, yy + 6, 30, "left", PAL.dim, fonts.small)
        if id then
            X.drawWeaponIcon(id, sx1 + 70, yy + slotH / 2, 0.5)
            shadowText(WEAPONS[id].name, sx1 + 130, yy + slotH / 2 - 9, colW - 136, "left", PAL.text, fonts.small)
        else
            shadowText("empty", sx1, yy + slotH / 2 - 8, colW, "center", { 1, 1, 1, 0.3 }, fonts.small)
        end
        buttons[#buttons + 1] = { x = sx1, y = yy, w = colW, h = slotH, enabled = true, fn = function()
            if not X.canSwitch() then playSfx("deny") return end
            X.hb.mode = "gun"
            X.selectGun(i)
        end }
        -- utility slot
        local uid = p.uslots[i]
        hov = mx >= sx2 and mx <= sx2 + colW and my >= yy and my <= yy + slotH
        if hov and uid then hover = uid end
        slotBox(sx2, yy, colW, slotH, X.hb.mode == "util" and X.hb.usel == i, hov, not uid)
        shadowText(i .. ".", sx2 + 8, yy + 6, 30, "left", PAL.dim, fonts.small)
        if uid then
            X.drawWeaponIcon(uid, sx2 + 60, yy + slotH / 2, 0.6)
            shadowText(X.UTIL[uid].name, sx2 + 104, yy + 10, colW - 110, "left", PAL.text, fonts.small)
            local cd = p.ucd[uid] or 0
            shadowText((p.uses[uid] or 0) .. " uses left" .. (cd > 0 and ("  |  " .. math.ceil(cd) .. "s") or ""), sx2 + 104, yy + 34,
                colW - 110, "left", (p.uses[uid] or 0) > 0 and PAL.dim or PAL.red, fonts.tiny)
        else
            shadowText("empty", sx2, yy + slotH / 2 - 8, colW, "center", { 1, 1, 1, 0.3 }, fonts.small)
        end
        buttons[#buttons + 1] = { x = sx2, y = yy, w = colW, h = slotH, enabled = true, fn = function()
            if not X.canSwitch() then playSfx("deny") return end
            X.hb.mode, X.hb.usel = "util", i
        end }
    end
    -- ARMOR: 4 slots (head / chest / legs / feet), a symbol on the left of each.
    -- Hold a slot for 3 s to repair the shield with a Metal Scrap.
    local aw = w - (sx3 - x) - 30
    local symW = slotH
    local AR = X.AR
    local holding = false
    for i, sl in ipairs(AR.SLOTS) do
        local yy = top + (i - 1) * (slotH + slotGap)
        -- the slot symbol: tan outline on dark brown
        lg.setColor(0.16, 0.11, 0.07, 0.97)
        lg.rectangle("fill", sx3, yy, symW, slotH, 7, 7)
        lg.setColor(0.82, 0.68, 0.45)
        lg.setLineWidth(2)
        lg.rectangle("line", sx3, yy, symW, slotH, 7, 7)
        lg.setLineWidth(1)
        X.drawIconTinted("slot_" .. sl, sx3 + symW / 2, yy + slotH / 2, 0.62, { 0.82, 0.68, 0.45 })
        -- the slot itself
        local id = p.armorSet[sl]
        local ax = sx3 + symW + 8
        local axw = aw - symW - 8
        local hov = mx >= ax and mx <= ax + axw and my >= yy and my <= yy + slotH
        if hov and id then hover = id end
        local off = sl == "feet" and id and not p.bootsOn
        slotBox(ax, yy, axw, slotH, false, hov, not id)
        if id then
            X.drawWeaponIcon(id, ax + 34, yy + slotH / 2, 0.5, off and 0.4 or 1)
            local a = X.ARMOR[id]
            shadowText(i .. ". " .. a.name, ax + 66, yy + 10, axw - 70, "left", off and PAL.dim or PAL.text, fonts.small)
            local sub = (a.shield or 0) > 0 and ("+" .. a.shield .. " shield") or (sl == "feet" and (p.bootsOn and "worn - click to take off" or "off - click to wear")
                or (id == "vest" and "+25 max HP" or ""))
            shadowText(sub, ax + 66, yy + 34, axw - 70, "left", (a.shield or 0) > 0 and { 0.5, 0.75, 1 } or PAL.dim, fonts.tiny)
        else
            shadowText(i .. ". empty (" .. AR.SLOT_NAMES[sl] .. ")", ax + 12, yy + slotH / 2 - 8, axw - 20, "left", { 1, 1, 1, 0.3 }, fonts.small)
        end
        if sl == "feet" and id then
            buttons[#buttons + 1] = { x = ax, y = yy, w = axw, h = slotH, enabled = true, fn = X.toggleBoots }
        end
        if hov and id and (X.ARMOR[id].shield or 0) > 0 and love.mouse.isDown(1) and p.shield < p.maxShield and (p.scraps or 0) > 0 then
            holding = true
            repairT = repairT + love.timer.getDelta()
            if repairT >= AR.REPAIR_HOLD then repairT = 0 X.repairShield() end
            lg.setColor(0.45, 0.7, 1)
            lg.setLineWidth(4)
            lg.arc("line", "open", ax + 34, yy + slotH / 2, 26, -pi / 2, -pi / 2 + 2 * pi * repairT / AR.REPAIR_HOLD)
            lg.setLineWidth(1)
        end
    end
    if not holding then repairT = 0 end
    -- resources (the red box in the sketch), below the armor
    local ry = top + 4 * (slotH + slotGap) + 6
    local rh = y + h - ry - 16
    lg.setColor(0.1, 0.07, 0.05, 0.9)
    lg.rectangle("fill", sx3, ry, aw, rh, 8, 8)
    setC(PAL.border, 0.6)
    lg.rectangle("line", sx3, ry, aw, rh, 8, 8)
    local rows = {
        { "Ammo", tostring(p.ammo), PAL.text },
        { "Gold", floor(p.gold) .. "g", PAL.gold },
        { "Credits", tostring(PROF.data.credits), { 1, 0.85, 0.4 } },
        { "Shield", (p.maxShield or 0) > 0 and (math.ceil(p.shield) .. " / " .. p.maxShield) or "-", { 0.5, 0.75, 1 } },
        { "Metal Scraps", tostring(p.scraps or 0), { 0.6, 0.75, 1 } },
    }
    for i, r in ipairs(rows) do
        local yy = ry + 8 + (i - 1) * 21
        shadowText(r[1], sx3 + 14, yy, aw - 28, "left", PAL.dim, fonts.small)
        shadowText(r[2], sx3 + 14, yy, aw - 28, "right", r[3], fonts.small)
    end
    local by2 = ry + 8 + #rows * 21 + 2
    button("Bandage x" .. p.bandages .. "  (+50 HP)", sx3 + 12, by2, aw - 24, 32, X.useBandage, p.bandages > 0)
    if (p.scraps or 0) > 0 and (p.maxShield or 0) > 0 and p.shield < p.maxShield then
        shadowText("Hold an armor slot 3 s to repair (+10)", sx3, by2 + 36, aw, "center", { 0.5, 0.75, 1 }, fonts.tiny)
    end
    -- the info box (blue in the sketch)
    local iy = top + 4 * (slotH + slotGap) + 6
    infoBox(sx1, iy, sx2 + colW - sx1, y + h - iy - 16, hover,
        "Hover over an item for its info.  Click a slot to select it.  G switches guns / utilities in the game.")
end

------------------------------------------------------------------------------
-- the CHEST in the shed: 10 slots for weapons, kept for the whole run
------------------------------------------------------------------------------
function X.drawChest()
    local p = me
    if not X.nearChest() then overlay = nil love.mouse.setVisible(false) return end
    local sw, sh = lg.getDimensions()
    dimScreen(0.65)
    local w, h = min(sw - 20, 760), 480
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("SHED CHEST", x, y + 14, w, "center", PAL.gold, fonts.large)
    shadowText("Click a weapon to move it. The chest keeps your weapons until the run ends.", x, y + 56, w, "center", PAL.dim, fonts.small)
    local mx, my = love.mouse.getPosition()
    local hover
    local sw4 = (w - 60 - 30) / 4
    shadowText("YOUR WEAPON SLOTS", x + 30, y + 86, w, "left", PAL.text, fonts.small)
    for i = 1, 4 do
        local sx, sy = x + 30 + (i - 1) * (sw4 + 10), y + 108
        local id = p.slots[i]
        local hov = mx >= sx and mx <= sx + sw4 and my >= sy and my <= sy + 70
        if hov and id then hover = id end
        slotBox(sx, sy, sw4, 70, false, hov, not id)
        if id then
            X.drawWeaponIcon(id, sx + sw4 / 2, sy + 28, 0.55)
            shadowText(WEAPONS[id].name, sx, sy + 52, sw4, "center", PAL.text, fonts.tiny)
            buttons[#buttons + 1] = { x = sx, y = sy, w = sw4, h = 70, enabled = true, fn = function() X.storeGun(i) end }
        else
            shadowText("empty", sx, sy + 28, sw4, "center", { 1, 1, 1, 0.3 }, fonts.small)
        end
    end
    shadowText("CHEST  (" .. #p.chest .. " / " .. X.CHEST_SLOTS .. ")", x + 30, y + 196, w, "left", PAL.text, fonts.small)
    local cw5 = (w - 60 - 40) / 5
    for k = 1, X.CHEST_SLOTS do
        local sx = x + 30 + ((k - 1) % 5) * (cw5 + 10)
        local sy = y + 218 + floor((k - 1) / 5) * 80
        local id = p.chest[k]
        local hov = mx >= sx and mx <= sx + cw5 and my >= sy and my <= sy + 70
        if hov and id then hover = id end
        slotBox(sx, sy, cw5, 70, false, hov, not id)
        if id then
            X.drawWeaponIcon(id, sx + cw5 / 2, sy + 28, 0.45)
            shadowText(WEAPONS[id].name, sx, sy + 52, cw5, "center", PAL.text, fonts.tiny)
            buttons[#buttons + 1] = { x = sx, y = sy, w = cw5, h = 70, enabled = true, fn = function() X.takeGun(k) end }
        end
    end
    infoBox(x + 30, y + h - 92, w - 60, 76, hover, "E / ESC to close")
end
end

-- a compact hotbar for the boss HUD (right of your HP bar)
function X.drawHotbarMini(p, bx, by)
    local util = X.hb.mode == "util"
    local w, h, gap = 60, 46, 6
    for i = 1, 4 do
        local x = bx + (i - 1) * (w + gap)
        local sel = util and X.hb.usel == i or (not util and X.hb.gsel == i)
        local id = util and p.uslots[i] or (not util and p.slots[i])
        X.slotBox(x, by, w, h, sel, false, not id)
        if id then
            X.drawWeaponIcon(id, x + w / 2, by + h / 2 - 2, util and 0.42 or 0.34)
            if util then
                shadowText("x" .. (p.uses[id] or 0), x, by + h - 15, w - 4, "right", PAL.text, fonts.tiny)
                local cd = p.ucd[id] or 0
                if cd > 0 then
                    lg.setColor(0, 0, 0, 0.55)
                    lg.rectangle("fill", x, by, w, h, 7, 7)
                    shadowText(tostring(math.ceil(cd)), x, by + 14, w, "center", { 0.7, 0.85, 1 }, fonts.small)
                end
            end
        end
    end
    local id = util and p.uslots[X.hb.usel] or p.slots[X.hb.gsel]
    shadowText((id and X.itemName(id) or "empty") .. "   |   " .. p.ammo .. " AMMO   [G]", bx, by - 20, 4 * (w + gap), "left",
        util and { 0.6, 0.8, 1 } or PAL.gold, fonts.small)
end

local drawStatsPanel, drawPause, drawGuide, drawBook, drawShop, drawInventory
do
local function statLines()
    local acc = stats.shotsFired > 0 and stats.shotsHit / stats.shotsFired * 100 or 0
    return {
        { "Time survived", formatTime(stats.time) .. "  (day " .. (world.day or 1) .. ")" },
        { "Mode", X.endless and ("ENDLESS - wave " .. (world.wave or 0)) or "Story" },
        { "Level reached", (me.level or 0) >= 10 and "MAX" or tostring(me.level or 0) },
        { "Regions visited", (function() local n = 0 for _ in pairs(world.visited or {}) do n = n + 1 end return n .. " / 5" end)() },
        { "Total kills", stats.kills },
        { "Bandits / Scouts killed", stats.banditKills .. " / " .. stats.scoutKills },
        { "Frozens / Snowmen killed", stats.frozenKills .. " / " .. stats.snowmanKills },
        { "Gourds / Bats / Witches", stats.gourdKills .. " / " .. stats.batKills .. " / " .. stats.witchKills },
        { "Shots fired", stats.shotsFired },
        { "Accuracy", string.format("%.1f%%", acc) },
        { "Damage dealt", floor(stats.damageDealt) },
        { "Damage taken", string.format("%.1f", stats.damageTaken) },
        { "Damage blocked", floor(stats.damageBlocked) },
        { "Attacks dodged", stats.dodges },
        { "Best kill streak", stats.bestStreak },
        { "Alarms raised", stats.alertsRaised },
        { "MP earned", floor(stats.mpEarned) },
        { "Spells cast", stats.spellsCast },
        { "SnowGRAVE kills", stats.snowgraveKills },
        { "Frost (freeze) kills", stats.frostKills },
        { "Cursed Spell kills", stats.cursedKills },
        { "Times spooked", stats.spooked },
        { "FROZEN CHEST", stats.chestFound and "Found" or "Not found" },
        { "Loot boxes opened", stats.boxesOpened },
        { "Bandages used", stats.bandagesUsed },
        { "Gold earned / spent", stats.goldEarned .. " / " .. stats.goldSpent },
        { "Distance travelled", string.format("%.0f m", stats.distance / 32) },
        { "Deaths", stats.deaths },
        { "Credits earned", stats.creditsEarned .. "  (total " .. PROF.data.credits .. ")" },
    }
end

function drawStatsPanel(x, y, w)
    local lines = statLines()
    local row = 18
    local h = #lines * row + 46
    panel(x, y, w, h)
    shadowText("STATISTICS", x, y + 12, w, "center", PAL.gold, fonts.normal)
    lg.setFont(fonts.small)
    for i, l in ipairs(lines) do
        local ly = y + 38 + (i - 1) * row
        if i % 2 == 0 then lg.setColor(1, 1, 1, 0.04) lg.rectangle("fill", x + 8, ly - 2, w - 16, row) end
        setC(PAL.dim); lg.print(l[1], x + 18, ly)
        setC(PAL.text); lg.printf(tostring(l[2]), x, ly, w - 18, "right")
    end
    return h
end

function drawPause()
    local sw, sh = lg.getDimensions()
    dimScreen(0.65)
    if MPS.online then
        shadowText("MENU", 0, 40, sw, "center", PAL.gold, fonts.huge)
        shadowText("Multiplayer: the game is NOT paused - enemies and players keep moving!", 0, 140, sw, "center",
            { 1, 0.45, 0.35, 0.7 + 0.3 * sin(menuTime * 5) }, fonts.normal)
    else
        shadowText("PAUSED", 0, 40, sw, "center", PAL.gold, fonts.huge)
    end
    local cx = sw / 2
    local bw = 280
    local x = cx - bw - 30
    local y = 180
    button("Resume", x, y, bw, 52, function() overlay = nil love.mouse.setVisible(false) end)
    button("Keybind Guide", x, y + 66, bw, 52, function() overlay = "guide" end)
    button("Shop", x, y + 132, bw, 52, function() overlay = "shop" end)
    button("Inventory", x, y + 198, bw, 52, function() overlay = "inventory" end)
    button(MPS.online and "Leave Game" or "Main Menu", x, y + 264, bw, 52, function()
        X.quitToMenu()
    end)
    -- Volume
    lg.setFont(fonts.normal)
    setC(PAL.text)
    lg.printf(string.format("Volume: %d%%", floor(settings.volume * 100 + 0.5)), x, y + 340, bw, "center")
    button("-", x, y + 366, 60, 40, function() settings.volume = max(0, settings.volume - 0.1) updateAmbientVolume() end)
    button("+", x + bw - 60, y + 366, 60, 40, function() settings.volume = min(1, settings.volume + 0.1) updateAmbientVolume() end)
    button("Music: " .. (settings.music and "ON" or "OFF"), x + 70, y + 366, bw - 140, 40, function() settings.music = not settings.music writeSave() end)
    drawStatsPanel(cx + 30, 170, 360)
end

function drawGuide()
    local sw, sh = lg.getDimensions()
    dimScreen(0.7)
    local w, h = 720, min(sh - 10, 740)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("KEYBIND GUIDE", x, y + 14, w, "center", PAL.gold, fonts.large)
    local binds = {
        { "W A S D", "Move" },
        { "SPACE", "Dash (25 stamina, brief invulnerability)" },
        { "LEFT CLICK", "Shoot (hold for continuous fire)" },
        { "RIGHT CLICK", "Block - HOLD (-80% frontal dmg, icicles fully)" },
        { "MOUSE WHEEL", "Select a hotbar slot (locked while your shot flies)" },
        { "G", "Hotbar: switch between GUNS and UTILITIES" },
        { "B", "Spellbook - CLICK a spell to cast it" },
        { "V", "Revive a downed teammate (hold 3 s)" },
        { "R", "Respawn now when you are down (costs a heart)" },
        { "E", "Trade with the merchant / open the shed chest" },
        { "K", "Open / close this guide" },
        { "H", "Open / close the Shop" },
        { "P", "Open / close the Inventory" },
        { "T", "Chat (ENTER send, ESC cancel)" },
        { "F", "Toggle HUD" },
        { "ESC", "Pause / close menus" },
    }
    for i, b in ipairs(binds) do
        local ly = y + 56 + (i - 1) * 25
        lg.setColor(0.25, 0.18, 0.1)
        lg.rectangle("fill", x + 30, ly, 150, 22, 5, 5)
        setC(PAL.border)
        lg.rectangle("line", x + 30, ly, 150, 22, 5, 5)
        lg.setFont(fonts.normal)
        setC(i == 5 and { 0.6, 0.8, 1 } or PAL.gold)
        lg.printf(b[1], x + 30, ly + 3, 150, "center")
        setC(PAL.text)
        lg.print(b[2], x + 200, ly + 3)
    end
    local tips = {
        "Tips:",
        "- Walls & pine trees block bullets AND sight. Break line of sight to lose hunters.",
        "- Every kill gives 10 MP (max 100). At 100 MP the Magic Book (500g) unlocks in the Shop.",
        "- Scouts raise alarms. Blocking an icicle shatters it: no damage and no slow.",
        "- Snowmen swing branches up close (12 DMG) and throw snowballs (3 DMG + big knockback).",
        "- Frozen lakes are slippery. The FROZEN CHEST hides deep in the south of the Frozen Wastes.",
        "- Haunted Hollow (100 kills): Gourds may SPOOK you, Bats vanish after biting, Witches poison.",
        "- Multiplayer: you have 3 hearts (lives). Lose them all and you spectate your team.",
        "- Ammo is universal. Big weapons slow you down; light ones speed you up.",
    }
    lg.setFont(fonts.small)
    for i, t in ipairs(tips) do
        if i == 1 then setC(PAL.gold) else setC(PAL.dim) end
        lg.print(t, x + 30, y + 56 + #binds * 25 + 8 + (i - 1) * 19)
    end
    button("Close (K)", x + w / 2 - 90, y + h - 52, 180, 40, function() overlay = nil love.mouse.setVisible(false) end)
end

function drawBook()
    local sw, sh = lg.getDimensions()
    dimScreen(0.75)
    local w, h = 780, min(sh - 20, 580)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    local ink = { 0.25, 0.14, 0.08 }
    -- leather cover and two parchment pages
    lg.setColor(0, 0, 0, 0.4)
    lg.rectangle("fill", x + 6, y + 8, w, h, 14, 14)
    lg.setColor(0.3, 0.16, 0.1)
    lg.rectangle("fill", x, y, w, h, 14, 14)
    lg.setColor(0.6, 0.42, 0.2)
    lg.setLineWidth(2)
    lg.rectangle("line", x + 6, y + 6, w - 12, h - 12, 10, 10)
    lg.setLineWidth(1)
    local pw = w / 2 - 22
    lg.setColor(0.93, 0.87, 0.72)
    lg.rectangle("fill", x + 16, y + 16, pw, h - 32, 6, 6)
    lg.rectangle("fill", x + w / 2 + 6, y + 16, pw, h - 32, 6, 6)
    lg.setColor(0.7, 0.6, 0.45, 0.6)
    lg.line(x + w / 2, y + 16, x + w / 2, y + h - 16)

    lg.setFont(fonts.large)
    setC(ink)
    lg.printf("SPELLBOOK", x + 16, y + 26, pw, "center")
    lg.setFont(fonts.small)
    lg.printf(string.format("Mana %d / %d MP     Health %d / %d", floor(player.mp), K.MP_MAX, math.ceil(player.hp), player.maxHp),
        x + 16, y + 66, pw, "center")

    local anyKnown = false
    for _, sp in ipairs(SPELLS) do if spellUnlocked(sp) then anyKnown = true end end

    local mx, my = love.mouse.getPosition()
    local entryH = 142
    for i, sp in ipairs(SPELLS) do
        local ex, ey
        if i <= 3 then ex, ey = x + 28, y + 92 + (i - 1) * entryH
        else ex, ey = x + w / 2 + 18, y + 30 + (i - 4) * entryH end
        local ew = pw - 24
        local unlocked = spellUnlocked(sp)
        local cdLeft = sp.id == "cursed" and player.cursedCd or ((player.spellCds or {})[sp.id] or 0)
        local ready = unlocked and player.mp >= sp.cost and cdLeft <= 0
        local hov = ready and mx >= ex and mx <= ex + ew and my >= ey and my <= ey + entryH - 10
        if hov then lg.setColor(0.85, 0.7, 0.45, 0.45) else lg.setColor(0.8, 0.7, 0.5, 0.22) end
        lg.rectangle("fill", ex, ey, ew, entryH - 10, 6, 6)
        lg.setColor(ink[1], ink[2], ink[3], 0.5)
        lg.rectangle("line", ex, ey, ew, entryH - 10, 6, 6)

        lg.setFont(fonts.normal)
        if sp.id == "cursed" then lg.setColor(0.55, 0.05, 0.1, unlocked and 1 or 0.45)
        else lg.setColor(ink[1], ink[2], ink[3], unlocked and 1 or 0.45) end
        lg.setFont(fonts.small)
        local cost = sp.cost .. " MP" .. (sp.hpCost and (" + " .. sp.hpCost .. " HP") or "") .. "  |  cd " .. formatTime(sp.cooldown)
        lg.setFont(fonts.normal)
        local nm = sp.name
        if fonts.normal:getWidth(nm) + fonts.small:getWidth(cost) + 30 > ew then nm = sp.short end
        lg.print(nm, ex + 10, ey + 8)
        lg.setFont(fonts.small)
        if player.mp >= sp.cost then lg.setColor(0.15, 0.3, 0.7) else lg.setColor(0.7, 0.15, 0.1) end
        lg.printf(cost, ex, ey + 9, ew - 10, "right")
        lg.setFont(fonts.tiny)
        lg.setColor(ink[1], ink[2], ink[3], unlocked and 0.9 or 0.45)
        lg.printf(sp.desc, ex + 10, ey + 34, ew - 20, "left")
        lg.setFont(fonts.small)
        local status
        if not unlocked then
            status = sp.source == "book" and "Locked - buy the Magic Book in the Shop"
                or (sp.source == "chest" and "Locked - sealed in the FROZEN CHEST"
                or (sp.source == "gatekeeper" and "Locked - defeat the Blaze Gatekeeper" or "Locked - dropped by Witches (15%)"))
            lg.setColor(0.6, 0.2, 0.1)
        elseif cdLeft > 0 then
            status = "Recharging: " .. formatTime(cdLeft)
            lg.setColor(0.55, 0.05, 0.1)
        elseif player.mp < sp.cost then
            status = "Not enough mana"
            lg.setColor(0.6, 0.2, 0.1)
        else
            status = "Ready - click to cast"
            lg.setColor(0.1, 0.45, 0.15)
        end
        lg.print(status, ex + 10, ey + entryH - 34)
        if ready then
            buttons[#buttons + 1] = { x = ex, y = ey, w = ew, h = entryH - 10, enabled = true, fn = function()
                overlay = nil
                love.mouse.setVisible(false)
                castSpell(sp.id)
            end }
        end
    end
    if not anyKnown then
        lg.setFont(fonts.small)
        setC(ink)
        lg.printf("You don't know any spells yet.\n\nReach 100 MP and buy the Magic Book (500g),\nfind the FROZEN CHEST in the Frozen Wastes,\nor defeat Witches in the Haunted Hollow.",
            x + w / 2 + 18, y + 330, pw - 24, "center")
    end
    button("Close (B)", x + w / 2 - 90, y + h - 58, 180, 40, function() overlay = nil love.mouse.setVisible(false) end)
end

function drawShop()
    local sw, sh = lg.getDimensions()
    dimScreen(0.7)
    local w, h = 760, min(sh - 20, 600)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("FRONTIER TRADING POST", x, y + 14, w, "center", PAL.gold, fonts.large)
    shadowText(string.format("Your gold: %dg     Mana: %d / %d MP", floor(player.gold), floor(player.mp), K.MP_MAX),
        x, y + 54, w, "center", PAL.text, fonts.normal)
    for i, item in ipairs(SHOP) do
        local iy = y + 84 + (i - 1) * 72
        local owned = item.once and player.owned[item.id]
        local locked = item.needsMP and not player.mpUnlocked
        local afford = player.gold >= item.price
        lg.setColor(1, 1, 1, 0.04)
        lg.rectangle("fill", x + 20, iy, w - 40, 66, 6, 6)
        lg.setFont(fonts.medium)
        if item.id == "book" then setC(owned and PAL.dim or { 0.6, 0.75, 1 }) else setC(owned and PAL.dim or PAL.text) end
        lg.print(i .. ". " .. item.name, x + 34, iy + 6)
        lg.setFont(fonts.small)
        setC(PAL.dim)
        lg.printf(item.desc, x + 34, iy + 34, w - 270, "left")
        local label = owned and "OWNED" or (locked and "LOCKED" or (item.price .. "g"))
        button(label, x + w - 200, iy + 10, 160, 46, function() buyItem(item) end, not owned and not locked and afford)
    end
    shadowText("Click an item or press 1-" .. #SHOP .. " to buy.", x, y + h - 76, w, "center", PAL.dim, fonts.small)
    button("Close (H)", x + w / 2 - 90, y + h - 52, 180, 40, function() overlay = nil love.mouse.setVisible(false) end)
end

function drawInventory()
    if not admin.on then X.drawNewInventory() return end     -- admin mode keeps the old inventory
    local sw, sh = lg.getDimensions()
    dimScreen(0.7)
    local w, h = 820, min(sh - 10, 700)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("INVENTORY", x, y + 12, w, "center", PAL.gold, fonts.large)
    if MPS.online then
        shadowText("(the game keeps running while this is open)", x, y + 50, w, "center", { 1, 0.5, 0.4 }, fonts.tiny)
    end

    -- Weapons: 26 guns in a 7-column grid
    shadowText("WEAPONS  (click to equip, 1-9 for the first nine)", x + 30, y + 62, 500, "left", PAL.dim, fonts.small)
    shadowText("AMMO: " .. player.ammo .. "  (universal)", x + w - 330, y + 62, 300, "right", PAL.gold, fonts.small)
    local cols, gap = 7, 8
    local cw = (w - 60 - gap * (cols - 1)) / cols
    local ch = 70
    local mx, my = love.mouse.getPosition()
    local tip
    for i, id in ipairs(X.WEAPON_ORDER) do
        local wp = WEAPONS[id]
        local cx = x + 30 + ((i - 1) % cols) * (cw + gap)
        local cy = y + 84 + floor((i - 1) / cols) * (ch + gap)
        local owned = player.owned[id]
        local equipped = player.weapon == id
        local hov = mx >= cx and mx <= cx + cw and my >= cy and my <= cy + ch
        if equipped then lg.setColor(0.32, 0.24, 0.1, 0.95)
        elseif hov and owned then lg.setColor(0.25, 0.18, 0.1, 0.95)
        else lg.setColor(0.12, 0.09, 0.06, owned and 0.95 or 0.6) end
        lg.rectangle("fill", cx, cy, cw, ch, 6, 6)
        lg.setLineWidth(equipped and 3 or 1.5)
        if equipped then setC(PAL.gold) elseif owned then setC(PAL.border, 0.7) else lg.setColor(0.35, 0.3, 0.28, 0.6) end
        lg.rectangle("line", cx, cy, cw, ch, 6, 6)
        lg.setLineWidth(1)
        if i <= 9 then
            lg.setFont(fonts.tiny)
            lg.setColor(1, 1, 1, 0.6)
            lg.print(tostring(i), cx + 5, cy + 3)
        end
        X.drawWeaponIcon(id, cx + cw / 2, cy + 28, hov and 0.46 or 0.42, owned and 1 or 0.35, not owned)
        lg.setFont(fonts.tiny)
        if equipped then setC(PAL.gold) else setC(owned and PAL.text or PAL.dim) end
        lg.printf(wp.name, cx + 2, cy + ch - 18, cw - 4, "center")
        if hov then tip = wp end
        if owned then
            buttons[#buttons + 1] = { x = cx, y = cy, w = cw, h = ch, enabled = true, fn = function() equipWeapon(id) end }
        end
    end
    if tip then
        local own = player.owned[tip.id]
        local t = string.format("%s:  %d-%d DMG  |  %s%d%% speed  |  %s", tip.name, tip.min, tip.max,
            tip.mod >= 0 and "+" or "", floor(tip.mod * 100 + 0.5),
            own and tip.desc or (tip.price and "Credit Shop" or "Buy in the Shop (H)"))
        shadowText(t, x + 20, y + 84 + 4 * (ch + gap) - 4, w - 40, "center", own and PAL.gold or { 1, 0.6, 0.5 }, fonts.tiny)
    end

    -- Gear
    local gy = y + 84 + 4 * (ch + gap) + 14
    shadowText("GEAR & CONSUMABLES", x + 30, gy, 500, "left", PAL.dim, fonts.small)
    local bootsSub = player.owned.boots and (player.bootsOn and "WORN: +35% speed, +1.2% dmg taken" or "Not worn - click to wear") or "Not owned"
    button("Feather Boots", x + 30, gy + 22, (w - 70) / 2, 66, toggleBoots, player.owned.boots, bootsSub)
    button("Bandage x" .. player.bandages, x + 40 + (w - 70) / 2, gy + 22, (w - 70) / 2, 66, useBandage, player.bandages > 0,
        string.format("Heals 50 HP  (HP %d/%d)", math.ceil(player.hp), player.maxHp))

    -- Resources
    local ry = gy + 100
    panel(x + 30, ry, w - 60, 86, 0.6)
    lg.setFont(fonts.normal)
    local wp = WEAPONS[player.weapon]
    local info = {
        { "Ammo (universal)", player.ammo },
        { "Gold / Mana", floor(player.gold) .. "g  /  " .. floor(player.mp) .. " MP" },
        { "Credits (permanent)", PROF.data.credits .. "   (next in " .. (PROF.KILLS_PER_CREDIT - PROF.data.killBank) .. " kills)" },
        { "Movement speed", string.format("%d%%", floor(100 * (player.bootsOn and 1.35 or 1) * (1 + wp.mod) + 0.5)) },
    }
    for i, l in ipairs(info) do
        local col = (i - 1) % 2
        local row = floor((i - 1) / 2)
        local ix = x + 50 + col * 360
        local iy = ry + 8 + row * 38
        setC(PAL.dim); lg.print(l[1], ix, iy)
        setC(PAL.text); lg.print(tostring(l[2]), ix, iy + 17)
    end

    shadowText("Spells: press B for your spellbook" .. (player.owned.vest and "   |   Reinforced Vest: +25 max HP" or ""),
        x, ry + 96, w, "center", { 0.8, 0.7, 1 }, fonts.small)
    button("Close (P)", x + w / 2 - 90, y + h - 50, 180, 40, function() overlay = nil love.mouse.setVisible(false) end)
end
end

------------------------------------------------------------------------------
-- Drawing: menu & end screens
------------------------------------------------------------------------------
local drawMenu, drawHowTo, drawEndScreen
do
local function drawFrontierBackdrop()
    local sw, sh = lg.getDimensions()
    -- Sunset sky gradient
    for i = 0, 40 do
        local t = i / 40
        lg.setColor(lerp(0.18, 0.95, t), lerp(0.1, 0.55, t), lerp(0.22, 0.3, t))
        lg.rectangle("fill", 0, t * sh * 0.75, sw, sh * 0.75 / 40 + 1)
    end
    -- Sun
    lg.setColor(1, 0.8, 0.45, 0.9)
    lg.circle("fill", sw * 0.7, sh * 0.62, 90)
    lg.setColor(1, 0.9, 0.6, 0.25)
    lg.circle("fill", sw * 0.7, sh * 0.62, 130)
    -- Mesas / hills layers
    local layers = {
        { col = { 0.45, 0.22, 0.2 }, base = 0.62, amp = 40, f = 0.004, off = 0.0 },
        { col = { 0.33, 0.16, 0.14 }, base = 0.7, amp = 30, f = 0.007, off = 2 },
        { col = { 0.2, 0.1, 0.09 }, base = 0.8, amp = 20, f = 0.011, off = 5 },
    }
    for li, L in ipairs(layers) do
        setC(L.col)
        local pts = {}
        local scroll = menuTime * 8 * li
        for x = 0, sw + 20, 20 do
            local yv = sh * L.base - abs(sin((x + scroll) * L.f + L.off)) * L.amp - (sin((x + scroll) * L.f * 0.37 + L.off) > 0.6 and 40 or 0)
            pts[#pts + 1] = x; pts[#pts + 1] = yv
        end
        pts[#pts + 1] = sw + 20; pts[#pts + 1] = sh
        pts[#pts + 1] = 0; pts[#pts + 1] = sh
        local ok, tris = pcall(love.math.triangulate, pts)
        if ok then for _, tri in ipairs(tris) do lg.polygon("fill", tri) end end
    end
    lg.setColor(0.15, 0.08, 0.06)
    lg.rectangle("fill", 0, sh * 0.86, sw, sh * 0.14)
    -- Cacti silhouettes
    lg.setColor(0.08, 0.05, 0.04)
    for _, cx in ipairs({ 0.12, 0.3, 0.86 }) do
        local x, y = sw * cx, sh * 0.86
        lg.rectangle("fill", x - 8, y - 90, 16, 90, 7, 7)
        lg.rectangle("fill", x - 32, y - 62, 12, 34, 6, 6)
        lg.rectangle("fill", x - 32, y - 34, 30, 10, 5, 5)
        lg.rectangle("fill", x + 20, y - 74, 12, 34, 6, 6)
        lg.rectangle("fill", x + 4, y - 46, 28, 10, 5, 5)
    end
    -- Dust
    for _, d in ipairs(menuDust) do
        lg.setColor(1, 0.85, 0.6, 0.35)
        lg.circle("fill", d.x * sw, d.y * sh, d.s)
    end
end

X.drawBackdrop = drawFrontierBackdrop

local function drawAdminBox()
    local sw, sh = lg.getDimensions()
    local x, y, w, h = 20, sh - 64, 170, 40
    lg.setFont(fonts.tiny)
    lg.setColor(1, 0.9, 0.75, 0.6)
    lg.print("CODE", x + 2, y - 15)
    lg.setColor(0.08, 0.06, 0.05, 0.85)
    lg.rectangle("fill", x, y, w, h, 6, 6)
    if admin.pending then lg.setColor(0.4, 1, 0.5) else setC(PAL.border, 0.8) end
    lg.setLineWidth(2)
    lg.rectangle("line", x, y, w, h, 6, 6)
    lg.setLineWidth(1)
    local shown = ""
    for i = 1, 6 do shown = shown .. (i <= #admin.input and "*" or "x") end
    if admin.pending then shown = "******" end
    lg.setFont(fonts.medium)
    lg.setColor(1, 0.95, 0.85, 0.9)
    lg.printf("[" .. shown .. "]", x, y + 7, w, "center")
    if admin.msgT > 0 then
        lg.setFont(fonts.small)
        lg.setColor(admin.msgCol[1], admin.msgCol[2], admin.msgCol[3], min(1, admin.msgT))
        lg.print(admin.msg, x + w + 12, y + 12)
    elseif admin.pending then
        lg.setFont(fonts.small)
        lg.setColor(0.4, 1, 0.5, 0.8)
        lg.print("ADMIN ARMED - start a game", x + w + 12, y + 12)
    end
end

function drawMenu()
    local sw, sh = lg.getDimensions()
    drawFrontierBackdrop()
    local bob = sin(menuTime * 1.5) * 4
    lg.setFont(fonts.huge)
    lg.setColor(0, 0, 0, 0.5)
    lg.printf("FRONTIER", 6, 76 + bob + 6, sw, "center")
    lg.setColor(1, 0.82, 0.45)
    lg.printf("FRONTIER", 0, 76 + bob, sw, "center")
    shadowText("Survive the desert, the Frozen Wastes and the Haunted Hollow - and defeat the Guardian of the Hollow.", 0, 190, sw, "center", PAL.text, fonts.normal)

    local bw, bh = 300, 56
    local x = sw / 2 - bw / 2
    local y = 236
    button("Start Game", x, y, bw, bh, function() X.openDiff("solo") end)
    button("Multiplayer", x, y + 66, bw, bh, function() X.openMP() end)
    X.journalButton(sw - 102, 24)
    button("How to Play", x, y + 132, bw, bh, function() gameState = "howto" end)
    button(string.format("Volume: %d%%", floor(settings.volume * 100 + 0.5)), x, y + 198, bw, bh, function()
        settings.volume = settings.volume >= 0.99 and 0 or min(1, settings.volume + 0.2)
        updateAmbientVolume()
        writeSave()
    end)
    button("Quit", x, y + 264, bw, bh, function() love.event.quit() end)

    local rec = string.format("Best kills: %d    Wins: %d    Best win time: %s    Games played: %d    Credits: %d",
        save.bestKills, save.wins, save.bestTime > 0 and formatTime(save.bestTime) or "--:--", save.games, save.credits or 0)
    shadowText(rec, 0, sh - 40, sw, "center", { 1, 0.9, 0.75, 0.85 }, fonts.small)
    shadowText("Press ENTER to start", 0, y + 330, sw, "center", { 1, 0.9, 0.7, 0.5 + 0.5 * sin(menuTime * 3) }, fonts.small)
    drawAdminBox()
end

function drawHowTo()
    local sw, sh = lg.getDimensions()
    drawFrontierBackdrop()
    dimScreen(0.55)
    local w, h = 900, min(sh - 20, 700)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("HOW TO PLAY", x, y + 14, w, "center", PAL.gold, fonts.large)
    local pages = {
      {
        { PAL.gold, "TWO MODES" },
        { PAL.text, "STORY: fight through 5 regions, beat the BLAZE GATEKEEPER, then the GUARDIAN OF THE HOLLOW to win. ENDLESS: no final boss - every day a new WAVE comes (groups of 5 / 7 / 9 / 10 / 20). Wave 5 is the LAST WAVE: enemies see and move 15% faster, and it lasts until you die. Survive as long as you can; your best wave is saved per difficulty. Play alone or with up to 4 players over LAN (Wi-Fi)." },
        { PAL.gold, "THE MAP (kills open the gates)" },
        { PAL.text, "Dustbowl Frontier (start, safe shed) -> 50 kills: THE FROZEN WASTES (south) -> 150 kills: THE MURKY SWAMP (gate in the Frozen Wastes' east wall: murky water -20% speed, Shroomers, Toads, Crocodiles) -> 200 kills: THE VOLCANIC RIFT (lava 10 DMG/s, ash storms, Magma Slimes, Lava Serpents, BlazeShrooms) -> 250 kills + the Gatekeeper's KEY: THE HAUNTED HOLLOW. The Guardian's lair opens once the Hollow is open AND you infiltrated the Stronghold (walk up to its keep)." },
        { PAL.gold, "LEVELS" },
        { PAL.text, "You start at LVL 0. Every 10 kills = 1 level (up to LVL MAX = 10): +5 max HP, +5% speed and +5% gun / melee damage per level. At MAX: 150 HP (175 with the Vest), +50% speed and +50% damage. The yellow bar under your mana shows the next level." },
        { PAL.gold, "MANA & SPELLS" },
        { PAL.text, "Every kill gives 10 MP (max 100). Open the spellbook (B) and CLICK a spell to cast it; every spell has a cooldown. Magic Book (500g, at 100 MP): Turtle Master, Cold Icicles, SnowGRAVE (150 DMG). The FROZEN CHEST holds IceShock. Witches may drop THE CURSED SPELL (100 MP + 50 HP, 200 DMG). The Blaze Gatekeeper gives the BLAZE SPELL (80 MP, 10 s of flame bullets that burn 5 DMG/s for 8 s)." },
        { PAL.gold, "DAYS & WEATHER" },
        { PAL.text, "A day lasts 6 minutes (3 minutes of day, 3 minutes of night) - in Endless the LAST WAVE comes after about 30 minutes. Walls and trees block bullets and vision - stay out of the yellow vision cones. Storms: rain in the desert, blizzards in the Frozen Wastes, ash in the Volcanic Rift." },
      },
      {
        { PAL.gold, "RANDOM EVENTS" },
        { PAL.text, "Every few minutes something happens: a METEOR SHOWER (30 s - get out of the red circles!), a TRAVELLING MERCHANT at the shed for one day (press E next to him; in Endless he always comes on day 2 with 3 of 6 items, like the Battle Axe) or a TREASURE GOBLIN that runs away - catch it within 30 s for big gold and 3 loot boxes." },
        { PAL.gold, "MULTIPLAYER: HEARTS & REVIVE" },
        { PAL.text, "Everyone has 3 hearts. When you go DOWN, a teammate can hold V next to you for 3 s to revive you right there with half HP (no heart lost). Otherwise after 60 s (or press R) you lose a heart and respawn in the shed. No hearts left = out; the game ends when the whole team is out." },
        { PAL.gold, "LOOT, SHOP & CREDITS" },
        { PAL.text, "Loot boxes: +20 Ammo or a Bandage. Ammo is universal. Spend gold in the Shop (H). Kills earn permanent CREDITS (none on Easy or in admin mode, 1 per 10 kills on Normal/Hard, 2 on Nightmare) - buy weapons in the Credit Shop or gamble on Loot Crates. The Gatekeeper gives 5 credits, the Guardian 30." },
        { PAL.gold, "LOADOUT, UTILITIES & ARMOR" },
        { PAL.text, "Credit Shop tabs: WEAPONS, UTILITY, ARMOR and LOADOUT. Bring 4 weapons, 4 utilities and armor (one piece each for HEAD, CHEST, LEGS; FEET = gold-shop boots) into each run. The HOTBAR at the bottom shows your guns or your utilities (G switches, the mouse wheel selects, left click uses). Utilities are bought once and refill every run. The shields of your armor pieces add up into one SHIELD that takes damage first - repair it with Metal Scraps from loot boxes (Inventory: hold an armor slot for 3 s). Store spare weapons in the chest in the shed (E). 14 achievements are listed in Multiplayer > Statistics." },
        { PAL.gold, "CONTROLS" },
        { PAL.text, "WASD move | SPACE dash | LMB shoot / use | RMB block | WHEEL hotbar slot | G guns <-> utilities | B spellbook | V revive (hold) | E merchant / shed chest | R respawn now (when down) | K guide | H shop | P inventory | T chat | F HUD | ESC pause" },
      },
    }
    X.howPage = X.howPage or 1
    local text = pages[X.howPage]
    local ty = y + 62
    for _, t in ipairs(text) do
        lg.setFont(t[1] == PAL.gold and fonts.normal or fonts.small)
        setC(t[1])
        lg.printf(t[2], x + 34, ty, w - 68, "left")
        local _, wrapped = lg.getFont():getWrap(t[2], w - 68)
        ty = ty + #wrapped * lg.getFont():getHeight() + (t[1] == PAL.gold and 3 or 10)
    end
    shadowText("Page " .. X.howPage .. " / 2", x, y + h - 86, w, "center", PAL.dim, fonts.small)
    button(X.howPage == 1 and "Next page >" or "< Previous page", x + w - 230, y + h - 58, 200, 44, function()
        X.howPage = X.howPage == 1 and 2 or 1
    end)
    button("Back", x + 30, y + h - 58, 200, 44, function() gameState = "menu" end)
    button("Start Game", x + w / 2 - 100, y + h - 58, 200, 44, function() X.openDiff("solo") end)
end

function drawEndScreen(won)
    local sw, sh = lg.getDimensions()
    if won then drawFrontierBackdrop() else
        lg.setColor(0.12, 0.04, 0.04)
        lg.rectangle("fill", 0, 0, sw, sh)
    end
    dimScreen(0.45)
    local title = won and "FRONTIER CLEARED" or "YOU DIED"
    local wasMP = X.lastWasMP
    local col = won and { 1, 0.82, 0.45 } or { 0.9, 0.25, 0.2 }
    shadowText(title, 0, 30, sw, "center", col, fonts.huge)
    shadowText(won and "The Guardian of the Hollow has fallen. Legends will be told of you."
        or (X.endless and string.format("ENDLESS: you survived until WAVE %d (day %d) with %d kills.  Best wave: %d",
            world.wave or 0, world.day or 1, stats.kills, PROF.data["bestWave_" .. X.D.id] or 0)
        or string.format("The frontier claimed you after %d kill%s.", stats.kills, stats.kills == 1 and "" or "s")),
        0, 140, sw, "center", PAL.text, fonts.normal)
    local h = drawStatsPanel(sw / 2 - 360, 180, 400)
    local bx = sw / 2 + 70
    if wasMP then
        button("Multiplayer", bx, 200, 260, 56, function() X.openMP() end)
    else
        button("Play Again", bx, 200, 260, 56, function() newGame({ diff = X.D.id, endless = X.lastEndless }) end)
    end
    button("Main Menu", bx, 270, 260, 56, function() gameState = "menu" end)
    button("Quit", bx, 340, 260, 56, function() love.event.quit() end)
    local rec = string.format("Personal best: %d kills  |  Wins: %d  |  Best win time: %s",
        save.bestKills, save.wins, save.bestTime > 0 and formatTime(save.bestTime) or "--:--")
    shadowText(rec, 0, min(sh - 36, 200 + h), sw, "center", PAL.dim, fonts.small)
end
end

------------------------------------------------------------------------------
-- Screens: Multiplayer (LAN) tab, Credit Shop + loot crate, loading screen
------------------------------------------------------------------------------
do
X.mp = { ipCheckT = 0, ip = nil, editing = nil, ipText = "", errT = 0 }
X.cs = { scroll = 0, hover = nil, sel = "crate", zoom = {}, roll = nil, drag = nil, confirm = nil, confirmT = 0 }

-- The menu backdrop, blurred (rendered small, then scaled up with smoothing)
function X.drawBlurBackdrop()
    local sw, sh = lg.getDimensions()
    local f = 8
    local cw, ch = math.ceil(sw / f), math.ceil(sh / f)
    if not X.blurA or X.blurW ~= cw or X.blurH ~= ch then
        X.blurA = lg.newCanvas(cw, ch)
        X.blurB = lg.newCanvas(math.ceil(cw / 2), math.ceil(ch / 2))
        X.blurA:setFilter("linear", "linear")
        X.blurB:setFilter("linear", "linear")
        X.blurW, X.blurH = cw, ch
    end
    lg.setCanvas(X.blurA)
    lg.clear(0, 0, 0, 1)
    lg.push()
    lg.scale(1 / f, 1 / f)
    X.drawBackdrop()
    lg.pop()
    lg.setCanvas(X.blurB)
    lg.clear(0, 0, 0, 1)
    lg.setColor(1, 1, 1)
    lg.draw(X.blurA, 0, 0, 0, 0.5, 0.5)
    lg.setCanvas()
    -- several offset copies soften the upscaled image into a smooth blur
    local s2 = f * 2
    local offs = { { 0, 0 }, { -6, 0 }, { 6, 0 }, { 0, -6 }, { 0, 6 } }
    for i, o in ipairs(offs) do
        lg.setColor(1, 1, 1, i == 1 and 1 or 0.25)
        lg.draw(X.blurB, o[1], o[2], 0, s2, s2)
    end
end

local function textField(label, value, x, y, w, active, onClick, placeholder)
    local mx, my = love.mouse.getPosition()
    local hov = mx >= x and mx <= x + w and my >= y and my <= y + 38
    lg.setFont(fonts.tiny)
    lg.setColor(1, 0.92, 0.8, 0.8)
    lg.print(label, x + 2, y - 15)
    lg.setColor(0.07, 0.05, 0.04, 0.9)
    lg.rectangle("fill", x, y, w, 38, 6, 6)
    if active then lg.setColor(0.4, 1, 0.5) elseif hov then lg.setColor(1, 0.8, 0.45) else setC(PAL.border, 0.8) end
    lg.setLineWidth(2)
    lg.rectangle("line", x, y, w, 38, 6, 6)
    lg.setLineWidth(1)
    lg.setFont(fonts.normal)
    local shown = value
    if shown == "" and not active then
        lg.setColor(1, 1, 1, 0.35)
        shown = placeholder or ""
    else
        lg.setColor(1, 0.96, 0.88)
    end
    if active and floor(menuTime * 2) % 2 == 0 then shown = shown .. "_" end
    lg.print(shown, x + 12, y + 9)
    buttons[#buttons + 1] = { x = x, y = y, w = w, h = 38, enabled = true, fn = onClick }
end

------------------------------------------------------------------------------
-- MULTIPLAYER TAB
------------------------------------------------------------------------------
function X.drawMP()
    local sw, sh = lg.getDimensions()
    X.drawBlurBackdrop()
    dimScreen(0.38)
    local M = X.mp
    shadowText("MULTIPLAYER", 0, 34, sw, "center", { 1, 0.82, 0.45 }, fonts.large)
    shadowText("LAN - play together with up to 4 people on the same Wi-Fi network", 0, 78, sw, "center", PAL.text, fonts.small)

    -- network status (Wi-Fi / LAN is required)
    if not NET.available then
        shadowText("Networking isn't available in this LÖVE build.", 0, 102, sw, "center", { 1, 0.4, 0.35 }, fonts.normal)
    elseif M.ip then
        shadowText("Connected to network  -  your IP: " .. M.ip, 0, 102, sw, "center", { 0.45, 1, 0.55 }, fonts.normal)
    else
        shadowText("NOT CONNECTED - connect to Wi-Fi (or a LAN) to host or join games", 0, 102, sw, "center",
            { 1, 0.4, 0.35, 0.7 + 0.3 * sin(menuTime * 4) }, fonts.normal)
    end

    local online = M.ip ~= nil
    local servers = online and NET.servers or {}
    local listW = min(720, sw - 80)
    local lx, ly = sw / 2 - listW / 2, 140
    local listH = sh - 140 - 190
    if #servers == 0 then
        -- the blurred menu with a lonely message
        lg.setFont(fonts.huge)
        local a = 0.75 + 0.25 * sin(menuTime * 1.5)
        lg.setColor(0, 0, 0, 0.45)
        lg.printf("Nothing here...", 4, ly + listH / 2 - 56 + 4, sw, "center")
        lg.setColor(1, 0.95, 0.85, a)
        lg.printf("Nothing here...", 0, ly + listH / 2 - 56, sw, "center")
        shadowText(online and "No games found on your network. Host one, or wait for a friend to host."
            or "Connect to Wi-Fi to see games on your network.", 0, ly + listH / 2 + 52, sw, "center", PAL.dim, fonts.normal)
        local dots = string.rep(".", floor(menuTime * 2) % 4)
        if online then shadowText("Searching" .. dots, 0, ly + listH / 2 + 80, sw, "center", { 0.8, 0.8, 0.8, 0.7 }, fonts.small) end
    else
        panel(lx, ly, listW, listH, 0.85)
        shadowText("GAMES ON YOUR NETWORK", lx, ly + 10, listW, "center", PAL.gold, fonts.normal)
        local regionNames = { desert = "Dustbowl Frontier", frozen = "Frozen Wastes", spooky = "Haunted Hollow", swamp = "Murky Swamp", volcanic = "Volcanic Rift" }
        for i, sv in ipairs(servers) do
            local ry = ly + 40 + (i - 1) * 64
            if ry + 56 > ly + listH then break end
            lg.setColor(1, 1, 1, 0.05)
            lg.rectangle("fill", lx + 14, ry, listW - 28, 56, 6, 6)
            lg.setFont(fonts.medium)
            setC(PAL.text)
            lg.print(sv.name .. "'s game", lx + 28, ry + 6)
            lg.setFont(fonts.small)
            setC(PAL.dim)
            local sameVer = sv.version == NET.VERSION
            local D = X.DIFF_BY_ID[sv.diff or "easy"] or X.DIFFS[1]
            lg.print(string.format("%d / %d players   |   %s   |   %d kills   |   %s", sv.players, sv.max,
                regionNames[sv.region] or sv.region, sv.kills, sv.ip), lx + 28, ry + 34)
            setC(D.col)
            lg.setFont(fonts.medium)
            lg.printf((sv.mode == "endless" and "ENDLESS  " or "") .. D.name, lx, ry + 6, listW - 200, "right")
            local full = sv.players >= sv.max
            local label = not sameVer and "OTHER VERSION" or (full and "FULL" or "JOIN")
            button(label, lx + listW - 180, ry + 8, 150, 40, function() X.joinGame(sv.ip) end, sameVer and not full and not MPS.connecting)
        end
    end

    -- bottom: actions
    local bw, gap = 172, 12
    local total = bw * 5 + gap * 4
    local bx, by = sw / 2 - total / 2, sh - 160
    button("Host Game", bx, by, bw, 52, function() X.openDiff("host") end, online and not MPS.connecting)
    button("Refresh", bx + (bw + gap), by, bw, 52, function()
        NET.startBrowse()
        M.ipCheckT = 0
    end, NET.available)
    button("Credit Shop", bx + (bw + gap) * 2, by, bw, 52, function() X.openCredits() end)
    button("Statistics", bx + (bw + gap) * 3, by, bw, 52, function() gameState = "stats" end)
    button("Back", bx + (bw + gap) * 4, by, bw, 52, function()
        NET.stopBrowse()
        M.editing = nil
        gameState = "menu"
    end)

    -- name + direct IP
    local fy = sh - 80
    textField("YOUR NAME", PROF.data.name, bx, fy, 300, M.editing == "name", function() M.editing = "name" end)
    textField("JOIN BY IP (if your game isn't listed)", M.ipText, bx + 330, fy, 300, M.editing == "ip",
        function() M.editing = "ip" end, "e.g. 192.168.1.20")
    button("Join IP", bx + 650, fy, total - 650, 38, function()
        if #M.ipText >= 7 then X.joinGame(M.ipText) end
    end, online and #M.ipText >= 7 and not MPS.connecting)

    shadowText(string.format("Credits: %d", PROF.data.credits), sw - 230, 34, 200, "right", { 1, 0.85, 0.3 }, fonts.normal)
    X.journalButton(24, 20)

    if MPS.connecting then
        dimScreen(0.5)
        panel(sw / 2 - 260, sh / 2 - 70, 520, 140)
        shadowText(MPS.status or "Connecting...", sw / 2 - 250, sh / 2 - 50, 500, "center", PAL.text, fonts.normal)
        local dots = string.rep(".", floor(menuTime * 3) % 4)
        shadowText("Please wait" .. dots, sw / 2 - 250, sh / 2 - 20, 500, "center", PAL.dim, fonts.small)
        button("Cancel", sw / 2 - 80, sh / 2 + 14, 160, 40, function() X.leaveGame("Connection cancelled.") end)
    end
    if MPS.error and M.errT > 0 then
        local a = min(1, M.errT)
        lg.setFont(fonts.normal)
        local tw = fonts.normal:getWidth(MPS.error) + 40
        lg.setColor(0.35, 0.05, 0.04, 0.9 * a)
        lg.rectangle("fill", sw / 2 - tw / 2, 120, tw, 34, 6, 6)
        lg.setColor(1, 0.85, 0.8, a)
        lg.printf(MPS.error, 0, 128, sw, "center")
    end
end

------------------------------------------------------------------------------
-- CREDIT SHOP
------------------------------------------------------------------------------
function X.openCredits()
    gameState = "credits"
    X.mp.editing = nil
    X.cs.scroll, X.cs.roll, X.cs.confirm = 0, nil, nil
end

do
-- chance / pool helpers: "weapon" crates (Normal + Fictional guns) and "util" crates (utilities)
local function itemChance(id)
    local it = WEAPONS[id] or X.UTIL[id]
    return it and it.chance or 0
end
local function crateRoll(pool)
    local list = pool == "util" and X.UT.UTILITY_ORDER or X.CRATE_POOL
    local r = love.math.random()
    local acc = 0
    for _, id in ipairs(list) do              -- never Hall of Fame weapons
        acc = acc + itemChance(id)
        if r <= acc then return id end
    end
    return list[1]
end
X.crateRoll = crateRoll

local REEL_W, FINAL = 132, 46
X.REEL_FINAL = FINAL
X.CRATE_PRICE = 10
function X.openCrate(pool)
    pool = pool == "util" and "util" or "weapon"
    if X.cs.roll then return end
    local price = pool == "util" and X.UT.UTILITY_CRATE_PRICE or X.CRATE_PRICE
    if not PROF.spend(price) then playSfx("deny") return end
    local result = crateRoll(pool)
    local dup = PROF.owns(result)
    if not dup then PROF.grant(result) end      -- saved right away: the roll is permanent
    PROF.data.cratesOpened = (PROF.data.cratesOpened or 0) + 1
    if pool == "weapon" then
        local old = WEAPONS[PROF.data.rarest or ""]
        if not old or not old.chance or WEAPONS[result].chance < old.chance then PROF.data.rarest = result end
    end
    PROF.save()
    local reel = {}
    for i = 1, FINAL + 6 do reel[i] = crateRoll(pool) end
    reel[FINAL] = result
    X.cs.roll = { reel = reel, result = result, dup = dup, t = 0, dur = 5.2, done = false, lastIdx = 0, pool = pool,
        land = randRange(-0.32, 0.32) }
    playSfx("crate_open")
end

local function itemPrice(id)
    local it = WEAPONS[id] or X.UTIL[id] or X.ARMOR[id]
    return it and it.price
end

-- buy a weapon, utility or armor (click twice: price -> CONFIRM?)
function X.buyWeapon(id)
    local price = itemPrice(id)
    if not price or PROF.owns(id) then return end
    if PROF.data.credits < price then playSfx("deny") return end
    if X.cs.confirm ~= id then
        X.cs.confirm, X.cs.confirmT = id, 3
        playSfx("click")
        return
    end
    if PROF.spend(price) then
        PROF.grant(id)
        X.cs.confirm = nil
        playSfx("crate_win")
        X.cs.flash = { id = id, t = 2.2 }
        if X.achieveCheck then X.achieveCheck() end
    end
end

local SPECIAL = {
    laser = "Pierces every enemy in reach", sniper = "Pierces through 2 enemies", minigun = "Spins up for 0.7 s",
    crossbow = "Silent: hit enemies don't notice you", flamethrower = "Burns: 3 DMG every 0.5 s for 3 s",
    bubble = "Traps enemies for 2 s", boomerang = "Comes back - can hit twice", hammer = "Melee, huge knockback",
    void = "Bullets pass through walls", tesla = "Chains to up to 3 enemies", ghostbow = "Homing arrows",
    blackhole = "Pulls enemies in for 2 s, then implodes", meteor = "Lands on your cursor after 1 s",
    freezer = "Slows enemies for 2 s", cannon = "Knocks enemies back", golden = "+50% gold per kill",
    missile = "Homes in on its target - kills it whatever its health",
}
local SECTION = { normal = "Normal Shop", fictional = "Fictional Shop", fame = "Hall of Fame" }
local function pct(c) return (string.format("%.1f", c * 100):gsub("%.0$", "")) .. "%" end
local function statRows(id)
    local w = WEAPONS[id]
    if not w then
        local u, a = X.UTIL[id], X.ARMOR[id]
        if u then
            local rows = {
                { "Cost", u.price .. " credits (yours forever)" },
                { "Uses per run", tostring(u.uses) },
                { "Cooldown", u.cooldown > 0 and (u.cooldown .. " s") or "none" },
                { "Speed modifier", (u.mod or 0) == 0 and "0%" or (floor(u.mod * 100) .. "%") },
            }
            if u.dmg then rows[#rows + 1] = { "Damage", tostring(u.dmg) } end
            if u.range then rows[#rows + 1] = { "Range", u.range .. " px" } end
            if u.radius then rows[#rows + 1] = { "Radius", u.radius .. " px" } end
            if u.duration then rows[#rows + 1] = { "Duration", formatTime(u.duration) } end
            rows[#rows + 1] = { "Utility Crate chance", pct(u.chance) }
            return rows
        end
        local rows = {
            { "Cost", a.price .. " credits (yours forever)" },
            { "Slot", X.AR.SLOT_NAMES[a.slot] },
            { "Shield", "+" .. a.shield },
            { "Speed modifier", (a.speed or 0) == 0 and "0%" or (floor(a.speed * 100 + 0.5) .. "%") },
        }
        if a.fire then rows[#rows + 1] = { "Fire damage", floor(a.fire * 100 + 0.5) .. "%" } end
        if a.stealth then rows[#rows + 1] = { "Stealth", "+" .. floor(a.stealth * 100 + 0.5) .. "% (enemies see you later)" } end
        if a.waders then rows[#rows + 1] = { "Special", "No murky-water slow, Toad poison -50%" } end
        if a.cannonRange then rows[#rows + 1] = { "Special", "Cannon range +" .. floor(a.cannonRange * 100) .. "%" } end
        if a.lamp then rows[#rows + 1] = { "Special", "Headlamp: brighter nights around you" } end
        rows[#rows + 1] = { "Repair", "1 Metal Scrap = +10 shield" }
        return rows
    end
    local rows = {
        { "Damage", X.executes(w) and "Instant kill" or (w.min .. " - " .. w.max .. (w.blast and " (blast)" or "")) },
        { "Cost", w.price .. " credits  (" .. SECTION[w.shop] .. ")" },
        { "Speed modifier", (w.mod > 0 and "+" or "") .. floor(w.mod * 100 + 0.5) .. "%" },
        { "Range", w.range .. " px" },
        { "Fire rate", string.format(1 / w.rate >= 1 and "%.0f shots/s" or "%.1f shots/s", 1 / w.rate) },
    }
    if w.pellets == 1 and w.kind == "bullet" and w.spread >= math.rad(5) then rows[#rows + 1] = { "Spread", floor(math.deg(w.spread * 2) + 0.5) .. " degrees" } end
    if w.blast then rows[#rows + 1] = { "Explosion radius", w.blast .. " px" } end
    if SPECIAL[id] then rows[#rows + 1] = { "Special", SPECIAL[id] } end
    if X.BLAST[id] then rows[#rows + 1] = { "Blast weapon", "The Guardian is immune" } end
    if w.ammoCost and w.ammoCost < 1 then rows[#rows + 1] = { "Ammo use", "1 Ammo per 3 shots" } end
    if w.ammoCost and w.ammoCost > 1 then rows[#rows + 1] = { "Ammo use", w.ammoCost .. " Ammo per shot" } end
    rows[#rows + 1] = { "Loot Crate chance", w.chance and pct(w.chance) or "Never - buy only" }
    return rows
end
X.statRows = statRows

-- the 4 tabs (yellow symbols)
X.SHOP_TABS = {
    { id = "weapons", name = "WEAPONS", icon = "pistol" },
    { id = "utility", name = "UTILITY", icon = "grenade" },
    { id = "armor", name = "ARMOR", icon = "tab_armor" },
    { id = "loadout", name = "LOADOUT", icon = "tab_loadout" },
}

local function drawTabs(sw, y)
    local C = X.cs
    local n = #X.SHOP_TABS
    local gap = 14
    local tw = min(280, (sw - 80 - gap * (n - 1)) / n)
    local x0 = 40
    local mx, my = love.mouse.getPosition()
    local yellow = { 1, 0.78, 0.25 }
    for i, t in ipairs(X.SHOP_TABS) do
        local x = x0 + (i - 1) * (tw + gap)
        local h = 62
        local sel = C.tab == t.id
        local hov = mx >= x and mx <= x + tw and my >= y and my <= y + h and not C.roll
        lg.setColor(0, 0, 0, 0.35)
        lg.rectangle("fill", x + 3, y + 4, tw, h, 26, 26)
        if sel then lg.setColor(0.3, 0.2, 0.08, 0.96) elseif hov then lg.setColor(0.2, 0.14, 0.08, 0.95) else lg.setColor(0.11, 0.08, 0.06, 0.9) end
        lg.rectangle("fill", x, y, tw, h, 26, 26)
        lg.setLineWidth(sel and 4 or 2)
        lg.setColor(yellow[1], yellow[2], yellow[3], sel and 1 or (hov and 0.85 or 0.55))
        lg.rectangle("line", x, y, tw, h, 26, 26)
        lg.setLineWidth(1)
        shadowText(t.name, x + 22, y + h / 2 - 16, tw - 90, "left", sel and yellow or { 0.9, 0.75, 0.45 }, fonts.large)
        X.drawIconTinted(t.icon, x + tw - 46, y + h / 2, t.icon == "pistol" and 0.55 or 0.75, { yellow[1], yellow[2], yellow[3], sel and 1 or 0.75 })
        if sel then
            lg.setColor(yellow[1], yellow[2], yellow[3], 0.9)
            lg.rectangle("fill", x + 26, y + h + 8, tw - 52, 3, 2, 2)
        end
        buttons[#buttons + 1] = { x = x, y = y, w = tw, h = h, enabled = not C.roll, label = t.name, fn = function()
            if C.tab ~= t.id then C.tab, C.scroll, C.sel, C.confirm = t.id, 0, nil, nil end
        end }
    end
end

-- the list items of a shop tab
local function tabItems(tab)
    local items
    if tab == "utility" then
        items = { "#UTILITY CRATE", "ucrate", "#UTILITIES" }
        for _, id in ipairs(X.UT.UTILITY_ORDER) do items[#items + 1] = id end
    elseif tab == "armor" then
        items = { "#ARMOR" }
        for _, id in ipairs(X.AR.ARMOR_ORDER) do items[#items + 1] = id end
    else
        items = { "#LOOT CRATE", "crate", "#NORMAL SHOP" }
        for _, id in ipairs(X.SHOP_NORMAL) do items[#items + 1] = id end
        items[#items + 1] = "#FICTIONAL SHOP"
        for _, id in ipairs(X.SHOP_FICTION) do items[#items + 1] = id end
        items[#items + 1] = "#HALL OF FAME"
        for _, id in ipairs(X.SHOP_FAME) do items[#items + 1] = id end
    end
    return items
end

function X.drawCredits()
    local sw, sh = lg.getDimensions()
    local C = X.cs
    C.tab = C.tab or "weapons"
    X.drawBlurBackdrop()
    dimScreen(0.5)
    shadowText("CREDIT SHOP", 40, 20, 600, "left", { 1, 0.82, 0.45 }, fonts.large)
    shadowText("Everything here is permanent. Credits: Normal & Hard 1 per 10 kills, Nightmare 2, Easy none.", 42, 62, sw - 420, "left", PAL.dim, fonts.small)
    -- credits counter
    local d = PROF.data
    lg.setColor(1, 0.8, 0.25)
    lg.circle("fill", sw - 210, 40, 16)
    lg.setColor(0.75, 0.55, 0.1)
    lg.circle("line", sw - 210, 40, 16)
    lg.setFont(fonts.medium)
    lg.setColor(0.6, 0.42, 0.05)
    lg.printf("C", sw - 226, 27, 32, "center")
    shadowText(d.credits .. " CREDITS", sw - 186, 26, 170, "left", { 1, 0.9, 0.5 }, fonts.medium)
    shadowText(string.format("Next credit: %d / %d kills", d.killBank, PROF.KILLS_PER_CREDIT), sw - 330, 58, 310, "right", PAL.dim, fonts.small)

    drawTabs(sw, 92)
    local top = 178
    if C.tab == "loadout" then
        X.drawLoadout(top)
        button("Back", 40, sh - 70, 180, 48, function() X.openMP() end, not C.roll)
        return
    end

    local items = tabItems(C.tab)
    local listX, listY = 40, top
    local listW = min(600, floor(sw * 0.5))
    local listH = sh - listY - 90
    local cardH, gap, headH = 96, 10, 40
    local ys, contentH = {}, 0
    for i, id in ipairs(items) do
        ys[i] = contentH
        contentH = contentH + (id:sub(1, 1) == "#" and headH or cardH + gap)
    end
    local maxScroll = max(0, contentH - listH)
    C.maxScroll = maxScroll
    C.scroll = clamp(C.scroll, 0, maxScroll)
    C.list = { x = listX, y = listY, w = listW, h = listH }

    local mx, my = love.mouse.getPosition()
    local newHover
    lg.setScissor(listX, listY, listW + 2, listH)
    for i, id in ipairs(items) do
        local cy = listY + ys[i] - C.scroll
        if id:sub(1, 1) == "#" then
            if cy + headH > listY and cy < listY + listH then
                local fame = id == "#HALL OF FAME"
                local col = fame and { 1, 0.8, 0.3 } or (id == "#FICTIONAL SHOP" and { 0.75, 0.6, 1 } or PAL.gold)
                shadowText(id:sub(2), listX + 6, cy + 10, listW, "left", col, fonts.medium)
                lg.setColor(col[1], col[2], col[3], 0.5)
                lg.rectangle("fill", listX + 6, cy + headH - 6, listW - 12, 2)
                if fame then shadowText("Buy only - never in Loot Crates", listX, cy + 16, listW - 8, "right", PAL.dim, fonts.tiny) end
                if id == "#UTILITIES" then shadowText("Bought once - uses refill every run", listX, cy + 16, listW - 8, "right", PAL.dim, fonts.tiny) end
                if id == "#ARMOR" then shadowText("One piece per slot (head, chest, legs) - LOADOUT", listX, cy + 16, listW - 8, "right", PAL.dim, fonts.tiny) end
            end
        elseif cy + cardH > listY and cy < listY + listH then
            local hov = not C.roll and mx >= listX and mx <= listX + listW and my >= max(cy, listY) and my <= min(cy + cardH, listY + listH)
            if hov then newHover = id end
            C.zoom[id] = C.zoom[id] or 0
            local z = C.zoom[id]
            local isCrate = id == "crate" or id == "ucrate"
            local owned = not isCrate and PROF.owns(id)
            lg.setColor(0, 0, 0, 0.35)
            lg.rectangle("fill", listX + 4, cy + 5, listW, cardH, 10, 10)
            if hov then lg.setColor(0.26, 0.19, 0.11, 0.97) else lg.setColor(0.12, 0.09, 0.06, 0.93) end
            lg.rectangle("fill", listX, cy, listW, cardH, 10, 10)
            lg.setLineWidth(2)
            if isCrate then lg.setColor(1, 0.8, 0.3, 0.9) elseif owned then lg.setColor(0.4, 0.9, 0.5, 0.8) else setC(PAL.border, 0.7) end
            lg.rectangle("line", listX, cy, listW, cardH, 10, 10)
            lg.setLineWidth(1)
            if isCrate then
                X.drawCrateIcon(listX + 80, cy + cardH / 2 + 2, 0.95 + 0.25 * z, z)
            else
                X.drawWeaponIcon(id, listX + 80, cy + cardH / 2, (WEAPONS[id] and 0.95 or 1.15) + 0.4 * z)
            end
            local tx = listX + 160
            if isCrate then
                local util = id == "ucrate"
                local price = util and X.UT.UTILITY_CRATE_PRICE or X.CRATE_PRICE
                shadowText(util and "UTILITY CRATE" or "LOOT CRATE", tx, cy + 10, 300, "left", { 1, 0.85, 0.4 }, fonts.medium)
                shadowText(util and "A random utility" or "Normal & Fictional weapons", tx, cy + 40, listW - 340, "left", PAL.dim, fonts.small)
                shadowText("Rolling one you own = NOTHING", tx, cy + 68, listW - 340, "left", { 1, 0.55, 0.45 }, fonts.tiny)
                button("OPEN " .. price .. " CR", listX + listW - 170, cy + cardH / 2 - 22, 150, 44,
                    function() X.openCrate(util and "util" or "weapon") end, d.credits >= price and not C.roll)
            else
                local w, u, a = WEAPONS[id], X.UTIL[id], X.ARMOR[id]
                local name = (w or u or a).name
                shadowText(name, tx, cy + 10, listW - 340, "left", (w and w.shop == "fame") and { 1, 0.85, 0.4 } or PAL.text, fonts.medium)
                local l2, l3
                if w then
                    l2 = string.format("%s  |  %.1f/s  |  %s%d%%", X.dmgText(w), 1 / w.rate, w.mod >= 0 and "+" or "", floor(w.mod * 100 + 0.5))
                    l3 = w.chance and (pct(w.chance) .. " in Loot Crates") or (w.shop == "fame" and "Hall of Fame - buy only" or "Buy only")
                elseif u then
                    l2 = string.format("%d uses per run  |  cooldown %ds", u.uses, u.cooldown)
                    l3 = pct(u.chance) .. " in Utility Crates"
                else
                    l2 = string.format("+%d shield  |  speed %s%d%%", a.shield, (a.speed or 0) >= 0 and "+" or "", floor((a.speed or 0) * 100 + 0.5))
                    l3 = X.AR.SLOT_NAMES[a.slot]:upper() .. " slot  |  " .. (a.fire and "-10% fire damage" or (a.stealth and "+15% stealth"
                        or (a.waders and "No swamp slow" or (a.cannonRange and "Cannon range +20%" or (a.lamp and "Headlamp at night" or "Light armor")))))
                end
                shadowText(l2, tx, cy + 42, listW - 330, "left", PAL.dim, fonts.small)
                shadowText(l3, tx, cy + 66, listW - 330, "left", { 0.75, 0.7, 0.6 }, fonts.tiny)
                if owned then
                    shadowText("OWNED", listX + listW - 170, cy + cardH / 2 - 12, 150, "center", { 0.45, 1, 0.55 }, fonts.medium)
                else
                    local price = itemPrice(id)
                    local label = C.confirm == id and "CONFIRM?" or (price .. " CREDITS")
                    button(label, listX + listW - 170, cy + cardH / 2 - 22, 150, 44, function() X.buyWeapon(id) end,
                        d.credits >= price and not C.roll)
                end
            end
        end
    end
    lg.setScissor()
    -- scrollbar
    if maxScroll > 0 then
        local tx = listX + listW + 10
        lg.setColor(0, 0, 0, 0.4)
        lg.rectangle("fill", tx, listY, 8, listH, 4, 4)
        local th = max(40, listH * listH / contentH)
        local ty = listY + (listH - th) * (C.scroll / maxScroll)
        lg.setColor(1, 0.8, 0.45, (C.drag and 1 or 0.75))
        lg.rectangle("fill", tx, ty, 8, th, 4, 4)
        C.bar = { x = tx - 4, y = listY, w = 16, h = listH, th = th }
    else
        C.bar = nil
    end
    -- buttons that are scrolled out of view must not be clickable
    for i = #buttons, 1, -1 do
        local b = buttons[i]
        if b.x >= listX and b.x < listX + listW and b.y >= top - 2 and (b.y < listY or b.y + b.h > listY + listH) then table.remove(buttons, i) end
    end

    if newHover ~= C.hover then
        if newHover then playSfx("hover") end
        C.hover = newHover
        if newHover then C.sel = newHover end
    end
    local valid = false
    for _, id in ipairs(items) do if id == C.sel then valid = true end end
    if not valid then C.sel = items[2] end

    -- details panel
    local px = listX + listW + 40
    local pw = sw - px - 40
    if pw > 260 then
        panel(px, listY, pw, listH)
        local id = C.sel
        local z = C.zoom[id] or 0
        if id == "crate" or id == "ucrate" then
            local util = id == "ucrate"
            X.drawCrateIcon(px + pw / 2, listY + 62, 1.0 + 0.2 * z, 1)
            shadowText((util and "UTILITY CRATE  -  " .. X.UT.UTILITY_CRATE_PRICE or "LOOT CRATE  -  " .. X.CRATE_PRICE) .. " CREDITS",
                px, listY + 108, pw, "center", { 1, 0.85, 0.4 }, fonts.medium)
            local y0 = listY + 144
            local pool = util and X.UT.UTILITY_ORDER or X.CRATE_POOL
            local perCol = util and 8 or 10
            local colW = util and (pw - 30) or (pw - 30) / 2
            for i, wid in ipairs(pool) do
                local cx = px + 15 + (i > perCol and colW or 0)
                local y = y0 + ((i - 1) % perCol) * 25
                if (i - 1) % 2 == 0 then lg.setColor(1, 1, 1, 0.04) lg.rectangle("fill", cx, y - 2, colW - 6, 23) end
                X.drawWeaponIcon(wid, cx + 24, y + 10, util and 0.32 or 0.24, PROF.owns(wid) and 0.5 or 1)
                lg.setFont(fonts.tiny)
                setC(PROF.owns(wid) and PAL.dim or PAL.text)
                lg.print(X.itemName(wid) .. (PROF.owns(wid) and " (owned)" or ""), cx + 54, y + 3)
                local ch = itemChance(wid)
                setC(ch <= 0.03 and { 1, 0.75, 0.3 } or PAL.gold)
                lg.printf(pct(ch), cx, y + 3, colW - 14, "right")
            end
            local y = y0 + perCol * 25 + 6
            shadowText(util and "Every utility can be pulled." or "Normal shop (left) & Fictional shop (right). Hall of Fame weapons are never in crates.",
                px + 20, y, pw - 40, "center", PAL.dim, fonts.tiny)
            shadowText("If the crate lands on something you already own, you get NOTHING.", px + 20, y + 22, pw - 40, "center", { 1, 0.6, 0.5 }, fonts.small)
        elseif id then
            local isW = WEAPONS[id] ~= nil
            local bigScale = isW and (min(2.4, (pw - 60) / 140) * (1 + 0.08 * z) * 0.85) or (1.35 * (1 + 0.08 * z))
            X.drawWeaponIcon(id, px + pw / 2, listY + 70, bigScale * 0.85)
            local name, _, desc = X.itemInfoLines(id)
            shadowText(name:upper(), px, listY + 126, pw, "center", PAL.gold, fonts.large)
            shadowText(desc, px + 24, listY + 166, pw - 48, "center", PAL.dim, fonts.small)
            local _, wl = fonts.small:getWrap(desc, pw - 48)
            local y = listY + 176 + #wl * fonts.small:getHeight()
            for i, r in ipairs(statRows(id)) do
                if y > listY + listH - 52 then break end
                if i % 2 == 0 then lg.setColor(1, 1, 1, 0.05) lg.rectangle("fill", px + 16, y - 3, pw - 32, 25) end
                lg.setFont(fonts.small)
                setC(PAL.dim) lg.print(r[1], px + 28, y)
                setC(PAL.text) lg.printf(r[2], px + 190, y, pw - 218, "right")
                y = y + 26
            end
            if PROF.owns(id) then
                shadowText("OWNED - put it in your LOADOUT (4th tab) to bring it into a run", px, listY + listH - 36, pw, "center", { 0.45, 1, 0.55 }, fonts.small)
            end
        end
    end

    button("Back", 40, sh - 70, 180, 48, function() X.openMP() end, not C.roll)
    if C.flash then
        local a = min(1, C.flash.t)
        shadowText("PURCHASED: " .. X.itemName(C.flash.id) .. "!", 0, sh - 64, sw, "center", { 0.5, 1, 0.6, a }, fonts.medium)
    end

    if C.roll then X.drawRoll() end
end

------------------------------------------------------------------------------
-- LOADOUT: 4 weapons, 4 utilities and 1 armor for every run
------------------------------------------------------------------------------
X.lo = { kind = "w", i = 1 }
local function loClick(kind, id)
    local L = X.loadout()
    local list = kind == "w" and L.w or L.u
    for k = 1, 4 do
        if list[k] == id then X.setLoadout(kind, k, nil) playSfx("click") return end      -- already in: take it out
    end
    local target = (X.lo.kind == kind and not list[X.lo.i]) and X.lo.i or nil
    if not target then for k = 1, 4 do if not list[k] then target = k break end end end
    if not target and X.lo.kind == kind then target = X.lo.i end                          -- full: replace the selected slot
    if not target then playSfx("deny") return end
    X.setLoadout(kind, target, id)
    X.lo.kind, X.lo.i = kind, target
    playSfx("equip")
end

function X.drawLoadout(top)
    local sw, sh = lg.getDimensions()
    local L = X.loadout()
    local mx, my = love.mouse.getPosition()
    local hover
    local colW = (sw - 80 - 30) / 2
    local lx, rx = 40, 40 + colW + 30
    local slotH = 74
    local function slots(kind, x, y, w, list, n)
        local sw4 = (w - (n - 1) * 10) / n
        for i = 1, n do
            local sx = x + (i - 1) * (sw4 + 10)
            local id = list[i]
            local sel = X.lo.kind == kind and X.lo.i == i
            local hov = mx >= sx and mx <= sx + sw4 and my >= y and my <= y + slotH
            if hov and id then hover = id end
            X.slotBox(sx, y, sw4, slotH, sel, hov, not id)
            if kind ~= "a" then shadowText(tostring(i), sx + 6, y + 4, 20, "left", PAL.dim, fonts.tiny) end
            if id then
                X.drawWeaponIcon(id, sx + sw4 / 2, y + 30, kind == "w" and 0.5 or 0.62)
                shadowText(X.itemName(id), sx + 2, y + slotH - 18, sw4 - 4, "center", PAL.text, fonts.tiny)
            else
                shadowText("empty", sx, y + slotH / 2 - 8, sw4, "center", { 1, 1, 1, 0.3 }, fonts.small)
            end
            buttons[#buttons + 1] = { x = sx, y = y, w = sw4, h = slotH, enabled = true, fn = function()
                if sel and id then X.setLoadout(kind, i, nil) else X.lo.kind, X.lo.i = kind, i end
            end }
        end
    end
    local function tiles(kind, x, y, w, ids, perRow, th, inList)
        local tw = (w - (perRow - 1) * 6) / perRow
        for k, id in ipairs(ids) do
            local tx = x + ((k - 1) % perRow) * (tw + 6)
            local ty = y + floor((k - 1) / perRow) * (th + 6)
            local on = inList(id)
            local hov = mx >= tx and mx <= tx + tw and my >= ty and my <= ty + th
            if hov then hover = id end
            if on then lg.setColor(0.18, 0.3, 0.14, 0.95) elseif hov then lg.setColor(0.24, 0.17, 0.1, 0.95) else lg.setColor(0.1, 0.08, 0.06, 0.9) end
            lg.rectangle("fill", tx, ty, tw, th, 6, 6)
            if on then lg.setColor(0.45, 1, 0.5, 0.9) elseif hov then lg.setColor(1, 0.8, 0.45) else setC(PAL.border, 0.5) end
            lg.rectangle("line", tx, ty, tw, th, 6, 6)
            X.drawWeaponIcon(id, tx + tw / 2, ty + th / 2, kind == "w" and min(0.36, tw / 140) or 0.44)
            buttons[#buttons + 1] = { x = tx, y = ty, w = tw, h = th, enabled = true, fn = function()
                if kind == "a" then
                    X.setLoadout("a", 1, (L.a == id) and nil or id)
                    playSfx("equip")
                else
                    loClick(kind, id)
                end
            end }
        end
        return y + math.ceil(#ids / perRow) * (th + 6)
    end
    -- WEAPONS (left)
    local wids = {}
    for _, id in ipairs(X.WEAPON_ORDER) do if X.loadoutWeaponOK(id) then wids[#wids + 1] = id end end
    shadowText("WEAPONS  (4 slots)", lx, top, colW, "left", PAL.gold, fonts.medium)
    slots("w", lx, top + 32, colW, L.w, 4)
    shadowText("Your weapons - click one to add / remove it", lx, top + 32 + slotH + 10, colW, "left", PAL.dim, fonts.small)
    local inW = function(id) for k = 1, 4 do if L.w[k] == id then return true end end return false end
    tiles("w", lx, top + 32 + slotH + 34, colW, wids, 7, 50, inW)
    -- UTILITIES + ARMOR (right)
    local uids, aids = {}, {}
    for _, id in ipairs(X.UT.UTILITY_ORDER) do if PROF.owns(id) then uids[#uids + 1] = id end end
    for _, id in ipairs(X.AR.ARMOR_ORDER) do if PROF.owns(id) then aids[#aids + 1] = id end end
    shadowText("UTILITIES  (4 slots)", rx, top, colW, "left", { 0.6, 0.8, 1 }, fonts.medium)
    slots("u", rx, top + 32, colW, L.u, 4)
    local inU = function(id) for k = 1, 4 do if L.u[k] == id then return true end end return false end
    local yy = top + 32 + slotH + 10
    if #uids == 0 then
        shadowText("You own no utilities yet - see the UTILITY tab.", rx, yy, colW, "left", PAL.dim, fonts.small)
        yy = yy + 26
    else
        shadowText("Your utilities", rx, yy, colW, "left", PAL.dim, fonts.small)
        yy = tiles("u", rx, yy + 24, colW, uids, 8, 46, inU)
    end
    yy = yy + 6
    -- ARMOR: one piece per slot (the FEET slot is the gold-shop Feather Boots)
    shadowText("ARMOR  (one piece per slot)", rx, yy, colW, "left", { 0.75, 0.8, 0.9 }, fonts.medium)
    local AR = X.AR
    local aw4 = (colW - 30) / 4
    local ah = 62
    for k, sl in ipairs(AR.SLOTS) do
        local sx = rx + (k - 1) * (aw4 + 10)
        local sy = yy + 30
        local id = L.a[sl]
        local hov = mx >= sx and mx <= sx + aw4 and my >= sy and my <= sy + ah
        if hov and id then hover = id end
        lg.setColor(0.16, 0.11, 0.07, 0.97)
        lg.rectangle("fill", sx, sy, 30, ah, 6, 6)
        lg.setColor(0.82, 0.68, 0.45)
        lg.rectangle("line", sx, sy, 30, ah, 6, 6)
        X.drawIconTinted("slot_" .. sl, sx + 15, sy + ah / 2, 0.3, { 0.82, 0.68, 0.45 })
        X.slotBox(sx + 34, sy, aw4 - 34, ah, false, hov, not id)
        if id then
            X.drawWeaponIcon(id, sx + 34 + (aw4 - 34) / 2, sy + 24, 0.44)
            shadowText(X.ARMOR[id].name, sx + 34, sy + ah - 17, aw4 - 34, "center", PAL.text, fonts.tiny)
            buttons[#buttons + 1] = { x = sx + 34, y = sy, w = aw4 - 34, h = ah, enabled = true, fn = function()
                X.setLoadout("a", sl, nil) playSfx("click") end }
        else
            shadowText(sl == "feet" and "gold shop" or AR.SLOT_NAMES[sl], sx + 34, sy + ah / 2 - 7, aw4 - 34, "center", { 1, 1, 1, 0.3 }, fonts.tiny)
        end
    end
    if #aids == 0 then
        shadowText("No armor yet - see the ARMOR tab.", rx, yy + 30 + ah + 10, colW, "left", PAL.dim, fonts.small)
    else
        local tw = (colW - 5 * 6) / 6
        for k, id in ipairs(aids) do
            local tx, ty = rx + (k - 1) * (tw + 6), yy + 30 + ah + 8
            local a = X.ARMOR[id]
            local on = L.a[a.slot] == id
            local hov = mx >= tx and mx <= tx + tw and my >= ty and my <= ty + 46
            if hov then hover = id end
            if on then lg.setColor(0.18, 0.3, 0.14, 0.95) elseif hov then lg.setColor(0.24, 0.17, 0.1, 0.95) else lg.setColor(0.1, 0.08, 0.06, 0.9) end
            lg.rectangle("fill", tx, ty, tw, 46, 6, 6)
            if on then lg.setColor(0.45, 1, 0.5, 0.9) elseif hov then lg.setColor(1, 0.8, 0.45) else setC(PAL.border, 0.5) end
            lg.rectangle("line", tx, ty, tw, 46, 6, 6)
            X.drawWeaponIcon(id, tx + tw / 2, ty + 23, 0.4)
            buttons[#buttons + 1] = { x = tx, y = ty, w = tw, h = 46, enabled = true, fn = function()
                X.setLoadout("a", a.slot, on and nil or id)
                playSfx("equip")
            end }
        end
    end
    -- info box
    local iy = sh - 160
    X.infoBox(lx, iy, sw - 80 - 200, 74, hover, "Click a slot to select it, then click an item to put it there. Click a selected slot again to empty it.")
end

-- The crate reel: icons scroll past a marker and slow down onto the result
function X.drawRoll()
    local sw, sh = lg.getDimensions()
    local R = X.cs.roll
    local util = R.pool == "util"
    dimScreen(0.88)
    local bw, bh = min(sw - 80, 900), 190
    local bx, by = sw / 2 - bw / 2, sh / 2 - 150
    shadowText(util and "OPENING UTILITY CRATE" or "OPENING LOOT CRATE", 0, by - 60, sw, "center", { 1, 0.85, 0.4 }, fonts.large)
    panel(bx, by, bw, bh)
    local u = clamp(R.t / R.dur, 0, 1)
    local e = 1 - (1 - u) ^ 4
    local target = (FINAL - 1 + 0.5 + R.land * 0.8) * REEL_W
    local offset = e * target
    lg.setScissor(bx + 4, by + 4, bw - 8, bh - 8)
    local centerX = bx + bw / 2
    for i, id in ipairs(R.reel) do
        local x = centerX + (i - 1) * REEL_W - offset
        if x > bx - REEL_W and x < bx + bw + REEL_W then
            local rare = itemChance(id) <= 0.1
            if rare then lg.setColor(0.45, 0.25, 0.08, 0.9) else lg.setColor(0.18, 0.14, 0.1, 0.9) end
            lg.rectangle("fill", x + 4, by + 20, REEL_W - 8, bh - 40, 8, 8)
            if rare then lg.setColor(1, 0.75, 0.3) else lg.setColor(0.5, 0.45, 0.4) end
            lg.rectangle("line", x + 4, by + 20, REEL_W - 8, bh - 40, 8, 8)
            X.drawWeaponIcon(id, x + REEL_W / 2, by + bh / 2 - 12, util and 1 or 0.85)
            lg.setFont(fonts.tiny)
            lg.setColor(1, 0.95, 0.85)
            lg.printf(X.itemName(id), x + 4, by + bh - 46, REEL_W - 8, "center")
        end
    end
    lg.setScissor()
    -- the marker
    lg.setColor(1, 0.85, 0.3)
    lg.polygon("fill", centerX - 12, by - 2, centerX + 12, by - 2, centerX, by + 18)
    lg.polygon("fill", centerX - 12, by + bh + 2, centerX + 12, by + bh + 2, centerX, by + bh - 18)
    lg.setLineWidth(3)
    lg.line(centerX, by + 14, centerX, by + bh - 14)
    lg.setLineWidth(1)

    if R.done then
        local name = X.itemName(R.result)
        local ry = by + bh + 26
        if R.dup then
            shadowText("NOTHING...", 0, ry, sw, "center", { 1, 0.45, 0.4 }, fonts.large)
            shadowText("It landed on the " .. name .. ", which you already own.", 0, ry + 46, sw, "center", PAL.text, fonts.normal)
        else
            local pulse = 0.8 + 0.2 * sin(menuTime * 8)
            shadowText("YOU GOT: " .. name:upper() .. "!", 0, ry, sw, "center", { 1, 0.85 * pulse, 0.35 }, fonts.large)
            shadowText("Yours forever - put it in your LOADOUT to bring it into a run.", 0, ry + 46, sw, "center", PAL.text, fonts.normal)
        end
        button("Continue", sw / 2 - 100, ry + 86, 200, 46, function() X.cs.roll = nil end)
        if not R.dup then
            for k = 1, 3 do
                local a = menuTime * 2 + k * 2.1
                lg.setColor(1, 0.85, 0.3, 0.5)
                lg.circle("fill", sw / 2 + cos(a) * 260, by + bh / 2 + sin(a * 1.3) * 90, 4)
            end
        end
    end
end
end

------------------------------------------------------------------------------
-- DIFFICULTY PICKER (before every single-player game and before hosting)
------------------------------------------------------------------------------
-- Start Game / Host Game: first STORY or ENDLESS, then the difficulty
function X.openDiff(mode)
    X.diffMode = mode or "solo"
    gameState = "mode"
end

function X.pickMode(m)
    X.gameMode = m
    gameState = "diff"
end

function X.pickDiff(id)
    X.lastDiff = id
    if X.diffMode == "host" then
        gameState = "mp"
        X.hostGame(id)
    else
        newGame({ diff = id, endless = X.gameMode == "endless" })
    end
end

function X.drawMode()
    local sw, sh = lg.getDimensions()
    X.drawBlurBackdrop()
    dimScreen(0.45)
    shadowText("CHOOSE A MODE", 0, 40, sw, "center", { 1, 0.82, 0.45 }, fonts.large)
    local modes = {
        { id = "story", name = "STORY", col = { 1, 0.82, 0.45 },
          lines = { "Fight through 5 regions:", "Desert, Frozen Wastes, Murky Swamp,", "Volcanic Rift and the Haunted Hollow.",
                    "", "Beat the Blaze Gatekeeper,", "then the GUARDIAN OF THE HOLLOW", "to win the game." } },
        { id = "endless", name = "ENDLESS", col = { 0.95, 0.45, 0.3 },
          lines = { "No final boss - just survive.", "", "Every day a new WAVE comes:", "bandit groups of 5, 7, 9, 10", "and 20 at the LAST WAVE (5).",
                    "", "Game over when you (or your", "whole team) run out of lives." } },
    }
    local cw, ch, gap = min(420, (sw - 100) / 2), 380, 30
    local x0, y0 = sw / 2 - cw - gap / 2, 120
    local mx, my = love.mouse.getPosition()
    for i, m in ipairs(modes) do
        local x = x0 + (i - 1) * (cw + gap)
        local hov = mx >= x and mx <= x + cw and my >= y0 and my <= y0 + ch
        local y = y0 + (hov and -6 or 0)
        lg.setColor(0, 0, 0, 0.4)
        lg.rectangle("fill", x + 5, y + 7, cw, ch, 12, 12)
        lg.setColor(0.12, 0.09, 0.06, 0.95)
        lg.rectangle("fill", x, y, cw, ch, 12, 12)
        lg.setColor(m.col[1], m.col[2], m.col[3], hov and 1 or 0.6)
        lg.setLineWidth(hov and 4 or 2)
        lg.rectangle("line", x, y, cw, ch, 12, 12)
        lg.setLineWidth(1)
        shadowText(m.name, x, y + 50, cw, "center", m.col, fonts.large)
        for k, l in ipairs(m.lines) do
            shadowText(l, x + 20, y + 140 + (k - 1) * 26, cw - 40, "center", PAL.text, fonts.small)
        end
        if m.id == "endless" then
            local d = PROF.data
            local best = 0
            for _, D in ipairs(X.DIFFS) do best = max(best, d["bestWave_" .. D.id] or 0) end
            shadowText("Best wave: " .. best, x, y + ch - 34, cw, "center", PAL.dim, fonts.small)
        end
        buttons[#buttons + 1] = { x = x, y = y0, w = cw, h = ch, enabled = true, fn = function() X.pickMode(m.id) end }
    end
    shadowText("Click a mode  -  or press 1 / 2", 0, y0 + ch + 24, sw, "center", { 1, 0.9, 0.7, 0.6 + 0.4 * sin(menuTime * 3) }, fonts.small)
    button("Back", sw / 2 - 100, sh - 80, 200, 48, function() gameState = X.diffMode == "host" and "mp" or "menu" end)
end

function X.drawDiff()
    local sw, sh = lg.getDimensions()
    X.drawBlurBackdrop()
    dimScreen(0.45)
    shadowText("CHOOSE DIFFICULTY" .. (X.gameMode == "endless" and "  -  ENDLESS" or "  -  STORY"), 0, 40, sw, "center", { 1, 0.82, 0.45 }, fonts.large)
    shadowText(X.diffMode == "host" and "Everyone who joins your game plays on this difficulty." or "Records are kept separately for each difficulty.",
        0, 88, sw, "center", PAL.dim, fonts.small)
    local n = #X.DIFFS
    local gap = 16
    local cw = min(280, (sw - 60 - gap * (n - 1)) / n)
    local ch = 400
    local x0, y0 = sw / 2 - (cw * n + gap * (n - 1)) / 2, 130
    local mx, my = love.mouse.getPosition()
    for i, D in ipairs(X.DIFFS) do
        local x = x0 + (i - 1) * (cw + gap)
        local hov = mx >= x and mx <= x + cw and my >= y0 and my <= y0 + ch
        local lift = hov and -6 or 0
        local y = y0 + lift
        lg.setColor(0, 0, 0, 0.4)
        lg.rectangle("fill", x + 5, y + 7, cw, ch, 12, 12)
        lg.setColor(0.12, 0.09, 0.06, 0.95)
        lg.rectangle("fill", x, y, cw, ch, 12, 12)
        lg.setColor(D.col[1], D.col[2], D.col[3], hov and 1 or 0.6)
        lg.setLineWidth(hov and 4 or 2)
        lg.rectangle("line", x, y, cw, ch, 12, 12)
        lg.setLineWidth(1)
        lg.rectangle("fill", x, y, cw, 8, 12, 12)
        -- skulls = danger level
        for k = 1, i do
            local sx = x + cw / 2 + (k - (i + 1) / 2) * 26
            lg.setColor(D.col)
            lg.circle("fill", sx, y + 42, 9)
            lg.rectangle("fill", sx - 5, y + 46, 10, 7, 2, 2)
            lg.setColor(0.12, 0.09, 0.06)
            lg.circle("fill", sx - 3.5, y + 41, 2.5)
            lg.circle("fill", sx + 3.5, y + 41, 2.5)
        end
        shadowText(D.name, x, y + 64, cw, "center", D.col, fonts.large)
        local function pct(v) return v == 1 and "normal" or ((v > 1 and "+" or "") .. floor((v - 1) * 100 + 0.5) .. "%") end
        local rows = {
            { "Enemy damage", "x" .. D.dmg },
            { "Enemy HP", "x" .. D.hp },
            { "Enemy count", "x" .. D.count },
            { "Reaction speed", "x" .. D.react },
            { "Gold per kill", pct(D.gold) },
            { "Credits", D.credits == 0 and "none" or (D.credits .. " per 10 kills") },
        }
        local ry = y + 118
        for k, r in ipairs(rows) do
            if k % 2 == 1 then lg.setColor(1, 1, 1, 0.04) lg.rectangle("fill", x + 12, ry - 3, cw - 24, 24) end
            lg.setFont(fonts.small)
            setC(PAL.dim) lg.print(r[1], x + 20, ry)
            setC(PAL.text) lg.printf(r[2], x, ry, cw - 20, "right")
            ry = ry + 26
        end
        shadowText(D.desc, x + 16, ry + 10, cw - 32, "center", D.col, fonts.small)
        local d = PROF.data
        shadowText(string.format("Best: %d kills  |  Wins: %d", d["bestKills_" .. D.id] or 0, d["wins_" .. D.id] or 0),
            x, y + ch - 34, cw, "center", PAL.dim, fonts.tiny)
        buttons[#buttons + 1] = { x = x, y = y0, w = cw, h = ch, enabled = true, fn = function() X.pickDiff(D.id) end }
        if hov and X.diffHover ~= D.id then playSfx("hover") end
        if hov then X.diffHover = D.id end
    end
    shadowText("Click a difficulty  -  or press 1-4", 0, y0 + ch + 24, sw, "center", { 1, 0.9, 0.7, 0.6 + 0.4 * sin(menuTime * 3) }, fonts.small)
    button("Back", sw / 2 - 100, sh - 80, 200, 48, function() gameState = "mode" end)
end

------------------------------------------------------------------------------
-- STATISTICS (button in the Multiplayer tab)
------------------------------------------------------------------------------
function X.drawStats()
    local sw, sh = lg.getDimensions()
    X.drawBlurBackdrop()
    dimScreen(0.5)
    shadowText("STATISTICS", 0, 30, sw, "center", { 1, 0.82, 0.45 }, fonts.large)
    local d = PROF.data
    local w = min(860, sw - 60)
    local x, y = sw / 2 - w / 2, 80
    panel(x, y, w, 196)
    shadowText("RECORDS PER DIFFICULTY", x, y + 10, w, "center", PAL.gold, fonts.normal)
    local cols = { "", "Best kills", "Wins", "Best time", "Best wave" }
    local cw = (w - 40) / 5
    for i, c in ipairs(cols) do
        lg.setFont(fonts.small) setC(PAL.dim)
        lg.printf(c, x + 20 + (i - 1) * cw, y + 44, cw, i == 1 and "left" or "center")
    end
    for k, D in ipairs(X.DIFFS) do
        local ry = y + 66 + (k - 1) * 30
        if k % 2 == 1 then lg.setColor(1, 1, 1, 0.05) lg.rectangle("fill", x + 12, ry - 4, w - 24, 28, 6, 6) end
        local bt = d["bestTime_" .. D.id] or 0
        local vals = { D.name, tostring(d["bestKills_" .. D.id] or 0), tostring(d["wins_" .. D.id] or 0), bt > 0 and formatTime(bt) or "--:--",
            tostring(d["bestWave_" .. D.id] or 0) }
        for i, v in ipairs(vals) do
            lg.setFont(fonts.medium)
            if i == 1 then setC(D.col) else setC(PAL.text) end
            lg.printf(v, x + 20 + (i - 1) * cw, ry, cw, i == 1 and "left" or "center")
        end
    end

    local y2 = y + 206
    panel(x, y2, w, 150)
    shadowText("LIFETIME", x, y2 + 10, w, "center", PAL.gold, fonts.normal)
    local owned = 0
    for _, id in ipairs(X.WEAPON_ORDER) do
        if id == "pistol" or id == "shotgun" or PROF.owns(id) then owned = owned + 1 end
    end
    local rare = WEAPONS[d.rarest or ""]
    local rows = {
        { "Lifetime kills", tostring(d.lifetimeKills or 0) },
        { "Credits earned", tostring(d.creditsTotal or 0) },
        { "Loot crates opened", tostring(d.cratesOpened or 0) },
        { "Collection", owned .. " / " .. #X.WEAPON_ORDER .. " weapons" },
        { "Rarest pull", rare and (rare.name .. string.format("  (%.1f%%)", rare.chance * 100)) or "none yet" },
        { "Games played", (d.games or 0) .. "   (multiplayer: " .. (d.mpGames or 0) .. ")" },
    }
    for i, r in ipairs(rows) do
        local col = (i - 1) % 3
        local row = floor((i - 1) / 3)
        local ix = x + 24 + col * (w / 3)
        local iy = y2 + 40 + row * 52
        lg.setFont(fonts.small) setC(PAL.dim) lg.print(r[1], ix, iy)
        lg.setFont(fonts.medium) setC(i == 5 and rare and { 1, 0.8, 0.35 } or PAL.text) lg.print(r[2], ix, iy + 20)
    end
    -- ACHIEVEMENTS: 14 badges, saved forever (hover one for its description)
    local y3 = y2 + 160
    local ah = 168
    panel(x, y3, w, ah)
    shadowText("ACHIEVEMENTS  " .. X.achCount() .. " / " .. #X.ACH, x, y3 + 8, w, "center", PAL.gold, fonts.normal)
    local per = 7
    local cw2 = (w - 20) / per
    local mx, my = love.mouse.getPosition()
    local hov
    for i, a in ipairs(X.ACH) do
        local col = (i - 1) % per
        local row = floor((i - 1) / per)
        local cx, cy = x + 10 + cw2 * (col + 0.5), y3 + 58 + row * 62
        local got = X.hasAch(a.id)
        X.drawBadge(a, cx, cy, 20, got)
        shadowText(a.name, cx - cw2 / 2, cy + 22, cw2, "center", got and { 1, 0.85, 0.4 } or PAL.dim, fonts.tiny)
        if dist(mx, my, cx, cy) < 24 then hov = a end
    end
    if hov then
        local tw = fonts.small:getWidth(hov.desc) + 24
        local tx, ty = clamp(mx + 14, 4, sw - tw - 4), my - 34
        lg.setColor(0.08, 0.06, 0.04, 0.95)
        lg.rectangle("fill", tx, ty, tw, 26, 6, 6)
        lg.setColor(1, 0.8, 0.3)
        lg.rectangle("line", tx, ty, tw, 26, 6, 6)
        shadowText(hov.desc, tx, ty + 5, tw, "center", PAL.text, fonts.small)
    end
    button("Back", sw / 2 - 100, sh - 74, 200, 48, function() X.openMP() end)
end

------------------------------------------------------------------------------
-- JOURNAL: every enemy, its weapon and how it fights
------------------------------------------------------------------------------
X.jr = { scroll = 0, maxScroll = 0, back = "menu" }
function X.openJournal()
    X.jr.back = gameState
    X.jr.scroll = 0
    gameState = "journal"
end

-- the tiny square "Journal" button
function X.journalButton(x, y)
    local s = 78
    local mx, my = love.mouse.getPosition()
    local hov = mx >= x and mx <= x + s and my >= y and my <= y + s
    lg.setColor(0, 0, 0, 0.35)
    lg.rectangle("fill", x + 3, y + 4, s, s, 8, 8)
    lg.setColor(hov and 0.32 or 0.2, hov and 0.22 or 0.14, 0.08, 0.95)
    lg.rectangle("fill", x, y, s, s, 8, 8)
    setC(PAL.border, hov and 1 or 0.8)
    lg.setLineWidth(2)
    lg.rectangle("line", x, y, s, s, 8, 8)
    lg.setLineWidth(1)
    -- a little book
    lg.setColor(0.55, 0.2, 0.15)
    lg.rectangle("fill", x + s / 2 - 16, y + 12, 32, 34, 3, 3)
    lg.setColor(0.95, 0.88, 0.7)
    lg.rectangle("fill", x + s / 2 - 12, y + 15, 26, 28, 2, 2)
    lg.setColor(0.55, 0.2, 0.15)
    lg.line(x + s / 2 - 7, y + 22, x + s / 2 + 9, y + 22)
    lg.line(x + s / 2 - 7, y + 28, x + s / 2 + 9, y + 28)
    lg.line(x + s / 2 - 7, y + 34, x + s / 2 + 4, y + 34)
    lg.setFont(fonts.small)
    lg.setColor(1, 0.92, 0.75)
    lg.printf("Journal", x, y + s - 24, s, "center")
    buttons[#buttons + 1] = { x = x, y = y, w = s, h = s, enabled = true, fn = X.openJournal }
end

function X.drawJournal()
    local sw, sh = lg.getDimensions()
    X.drawBlurBackdrop()
    dimScreen(0.5)
    shadowText("JOURNAL", 0, 24, sw, "center", { 1, 0.82, 0.45 }, fonts.large)
    shadowText("Every enemy of the Frontier. Stats are for EASY - harder difficulties make them stronger.", 0, 68, sw, "center", PAL.dim, fonts.small)
    local J = X.jr
    local w = min(900, sw - 60)
    local x, y0 = sw / 2 - w / 2, 100
    local listH = sh - y0 - 96
    local gap = 10
    local list = X.EN.ORDER
    local ys, total, hs = {}, 0, {}
    local fh = fonts.small:getHeight()
    for i, kind in ipairs(list) do
        local je = X.EN.journal[kind]
        local tw = w - 138 - 20
        local _, l1 = fonts.small:getWrap(je.text, tw)
        local need = 64 + #l1 * fh + 16
        if je.how then
            local _, l2 = fonts.small:getWrap(je.how, tw)
            need = need + 8 + #l2 * fh
        end
        hs[i] = max(je.boss and 200 or 132, need)
        ys[i] = total
        total = total + hs[i] + gap
    end
    J.maxScroll = max(0, total - listH)
    J.scroll = clamp(J.scroll, 0, J.maxScroll)
    lg.setScissor(x - 4, y0, w + 8, listH)
    local regionCol = { desert = { 1, 0.8, 0.45 }, frozen = { 0.6, 0.9, 1 }, spooky = { 0.8, 0.55, 1 } }
    for i, kind in ipairs(list) do
        local je, st = X.EN.journal[kind], X.ESTATS[kind]
        local cardH = hs[i]
        local cy = y0 + ys[i] - J.scroll
        if cy + cardH > y0 and cy < y0 + listH then
            local rc = je.boss and { 1, 0.6, 0.2 } or (regionCol[X.EN.region[kind]] or PAL.gold)
            lg.setColor(0.12, 0.09, 0.06, 0.94)
            lg.rectangle("fill", x, cy, w, cardH, 10, 10)
            lg.setColor(rc[1], rc[2], rc[3], 0.7)
            lg.setLineWidth(2)
            lg.rectangle("line", x, cy, w, cardH, 10, 10)
            lg.setLineWidth(1)
            -- portrait
            lg.setColor(0.2, 0.16, 0.12)
            local ps = je.boss and 104 or 104
            lg.rectangle("fill", x + 14, cy + 14, ps, ps, 8, 8)
            if je.boss then
                lg.intersectScissor(x + 14, cy + 14, ps, ps)
                if kind == "gatekeeper" then
                    X.drawGatekeeper(x + 14 + ps / 2, cy + 14 + ps / 2 + 6, 34, -pi / 2 + 0.4, {})
                else
                    X.drawGuardian(x + 14 + ps / 2, cy + 14 + ps / 2, 30, -pi / 4, { eyes = 1 })
                end
                lg.setScissor(x - 4, y0, w + 8, listH)
                shadowText("BOSS", x + 14, cy + 124, ps, "center", { 1, 0.4, 0.3 }, fonts.medium)
            else
                lg.intersectScissor(x + 14, cy + 14, ps, ps)
                X.drawEnemyPortrait(kind, x + 14 + ps / 2, cy + 14 + ps / 2, 2.2)
                lg.setScissor(x - 4, y0, w + 8, listH)
            end
            local tx = x + 132 + 6
            shadowText(X.EN.names[kind], tx, cy + 10, 400, "left", rc, fonts.medium)
            shadowText(je.region, tx, cy + 12, w - (tx - x) - 24, "right", PAL.dim, fonts.tiny)
            lg.setFont(fonts.small)
            setC(PAL.gold)
            lg.print(string.format("%d HP   |   Weapon: %s   |   Speed %d", st.hp, je.weapon, st.hunt), tx, cy + 40)
            setC(PAL.text)
            local tw = w - (tx - x) - 20
            lg.printf(je.text, tx, cy + 64, tw, "left")
            if je.how then
                local _, lines = fonts.small:getWrap(je.text, tw)
                setC({ 1, 0.75, 0.3 })
                lg.printf(je.how, tx, cy + 72 + #lines * fonts.small:getHeight(), tw, "left")
            end
        end
    end
    lg.setScissor()
    if J.maxScroll > 0 then
        lg.setColor(0, 0, 0, 0.4)
        lg.rectangle("fill", x + w + 10, y0, 8, listH, 4, 4)
        local th = max(40, listH * listH / (listH + J.maxScroll))
        lg.setColor(1, 0.8, 0.45, 0.8)
        lg.rectangle("fill", x + w + 10, y0 + (listH - th) * (J.scroll / J.maxScroll), 8, th, 4, 4)
    end
    shadowText("Scroll with the mouse wheel", 0, sh - 88, sw, "center", PAL.dim, fonts.tiny)
    button("Back", sw / 2 - 100, sh - 70, 200, 48, function() gameState = J.back or "menu" end)
end

------------------------------------------------------------------------------
-- LOADING
------------------------------------------------------------------------------
local TIPS = {
    "Tip: every 10 kills earns you 1 permanent credit for the Credit Shop.",
    "Tip: the shed you spawn in is safe - enemies can't see you inside or get in.",
    "Tip: Ammo is universal - every gun uses the same pool.",
    "Tip: heavier weapons slow you down; the Swifter's Pistol makes you faster.",
    "Tip: at night it gets darker and fireflies come out.",
    "Tip: in multiplayer the game never pauses - not even in the shop!",
}
function X.drawLoading()
    local sw, sh = lg.getDimensions()
    X.drawBlurBackdrop()
    dimScreen(0.5)
    shadowText("GENERATING THE FRONTIER", 0, sh / 2 - 70, sw, "center", { 1, 0.82, 0.45 }, fonts.large)
    shadowText("Building three huge regions...", 0, sh / 2 - 20, sw, "center", PAL.text, fonts.normal)
    for k = 0, 7 do
        local a = menuTime * 5 + k * pi / 4
        lg.setColor(1, 0.85, 0.45, (k + 1) / 8)
        lg.circle("fill", sw / 2 + cos(a) * 26, sh / 2 + 40 + sin(a) * 26, 5)
    end
    shadowText(TIPS[floor(menuTime / 3) % #TIPS + 1], 0, sh - 80, sw, "center", PAL.dim, fonts.small)
end

------------------------------------------------------------------------------
-- per-frame logic for the menu screens
------------------------------------------------------------------------------
function X.updateScreens(dt)
    local M, C = X.mp, X.cs
    M.errT = max(0, M.errT - dt)
    if MPS.error and MPS.error ~= M.lastErr then M.errT = 5 end
    M.lastErr = MPS.error
    if M.errT <= 0 then MPS.error = nil end
    if gameState == "mp" or gameState == "credits" or gameState == "stats" or (gameState == "diff" and X.diffMode == "host") then
        M.ipCheckT = M.ipCheckT - dt
        if M.ipCheckT <= 0 then
            M.ipCheckT = 2
            M.ip = NET.localIP()
        end
        if M.ip then NET.pollBrowse() end
        if MPS.connecting then
            MPS.joinT = (MPS.joinT or 8) - dt
            if MPS.joinT <= 0 then X.leaveGame("Could not connect: no answer from that game.") end
        end
    end
    if gameState == "credits" then
        for id, z in pairs(C.zoom) do
            C.zoom[id] = lerp(z, (C.hover == id) and 1 or 0, min(1, dt * 10))
        end
        if C.confirm then
            C.confirmT = C.confirmT - dt
            if C.confirmT <= 0 then C.confirm = nil end
        end
        if C.flash then
            C.flash.t = C.flash.t - dt
            if C.flash.t <= 0 then C.flash = nil end
        end
        local R = C.roll
        if R and not R.done then
            R.t = R.t + dt
            local u = clamp(R.t / R.dur, 0, 1)
            local e = 1 - (1 - u) ^ 4
            local idx = floor(e * (X.REEL_FINAL - 1 + 0.5 + R.land * 0.8))
            if idx ~= R.lastIdx then
                R.lastIdx = idx
                playSfx("roll_tick", 0.05)
            end
            if R.t >= R.dur then
                R.done = true
                if R.pool ~= "util" and WEAPONS[R.result].chance <= 0.02 then X.achieve("lucky") end
                X.achieveCheck()
                if R.dup then playSfx("crate_nothing")
                elseif (WEAPONS[R.result] or X.UTIL[R.result]).chance <= 0.1 then playSfx("crate_rare")
                else playSfx("crate_win") end
            end
        end
        if C.drag and C.bar and C.maxScroll > 0 then
            local _, my = love.mouse.getPosition()
            local u = clamp((my - C.bar.y - C.bar.th / 2) / (C.bar.h - C.bar.th), 0, 1)
            C.scroll = u * C.maxScroll
        end
    end
end
end

------------------------------------------------------------------------------
-- LÖVE callback: draw
------------------------------------------------------------------------------
local drawAdminPanel
do
local function adminGrantAll()
    local p = player
    p.owned.shotgun, p.owned.boots, p.owned.vest, p.owned.book = true, true, true, true
    if p.maxHp < 125 then p.maxHp = 125 end
    p.hp = p.maxHp
    p.hasBook, p.hasIceShock, p.hasCursed, p.mpUnlocked = true, true, true, true
    p.cursedCd = 0
    p.ammo = p.ammo + 999
    for _, id in ipairs(X.WEAPON_ORDER) do p.owned[id] = true end
    p.bandages = p.bandages + 99
    p.mp = K.MP_MAX
    if frozenChest then frozenChest.opened = true end
    playSfx("chest_open")
    addMessage("ADMIN: all items and spells granted (incl. THE CURSED SPELL).", { 1, 0.4, 0.4 })
end

local ADMIN_TP = {
    { id = "desert", label = "DESERT" },
    { id = "frozen", label = "FROZEN" },
    { id = "swamp", label = "SWAMP" },
    { id = "volcanic", label = "VOLCANO" },
    { id = "spooky", label = "HOLLOW" },
    { id = "lair", label = "LAIR" },
}

function drawAdminPanel()
    local sw, sh = lg.getDimensions()
    dimScreen(0.7)
    local w, h = min(sw - 20, 820), min(sh - 10, 630)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    panel(x, y, w, h)
    shadowText("ADMIN PANEL", x, y + 12, w, "center", { 1, 0.4, 0.4 }, fonts.large)
    local function onoff(v) return v and "ON" or "OFF" end
    local bw, bx = w - 80, x + 40
    local function toggle(key, extra)
        return function()
            admin[key] = not admin[key]
            if extra then extra(admin[key]) end
        end
    end
    button("INF HP: " .. onoff(admin.hp), bx, y + 62, bw, 46, toggle("hp"), true)
    button("INF MP: " .. onoff(admin.mp), bx, y + 114, bw, 46, toggle("mp"), true)
    button("INF STEALTH: " .. onoff(admin.stealth), bx, y + 166, bw, 46, toggle("stealth", function(v)
        if v then
            for _, e in ipairs(enemies) do
                if not e.dead and e.state ~= "patrol" then
                    e.state, e.awareness = "patrol", 0
                    e.homeX, e.homeY = e.x, e.y
                end
            end
        end
    end), true)
    button("INF KILLS (one-hit kills): " .. onoff(admin.kills), bx, y + 218, bw, 46, toggle("kills"), true)
    button("ALL ITEMS AND SPELLS", bx, y + 270, bw, 46, adminGrantAll, true)
    local wlabel = admin.weather == "auto" and "AUTO" or (admin.weather == "clear" and "CLEAR" or "STORM (rain / blizzard)")
    button("OVERRIDE WEATHER: " .. wlabel, bx, y + 322, bw, 46, function()
        admin.weather = admin.weather == "auto" and "clear" or (admin.weather == "clear" and "storm" or "auto")
    end, true)
    -- Teleport to any region (all gates are open in admin mode)
    shadowText("TELEPORT TO REGION", bx, y + 378, bw, "center", PAL.dim, fonts.small)
    local tw = (bw - 10 * (#ADMIN_TP - 1)) / #ADMIN_TP
    for i, tp in ipairs(ADMIN_TP) do
        local here = player.region == tp.id
        button(tp.label, bx + (i - 1) * (tw + 10), y + 398, tw, 44, function()
            if tp.id == "desert" then
                player.x, player.y = X.shedSpot(1)
            elseif tp.id == "lair" then
                player.x, player.y = X.LAIR.gx, X.LAIR.y - 160
            else
                player.x, player.y = REGIONS[tp.id].x0 + K.WORLD_W / 2, REGIONS[tp.id].y0 + 260
            end
            player.kbx, player.kby, player.vx, player.vy = 0, 0, 0, 0
            cam.x, cam.y = player.x, player.y
            overlay = nil
            love.mouse.setVisible(false)
            addMessage("ADMIN: teleported to " .. (REGIONS[tp.id] and REGIONS[tp.id].name or "the Guardian's Lair") .. ".", { 1, 0.4, 0.4 })
        end, not here)
    end
    -- start a random event right now (host / single player)
    shadowText("START A RANDOM EVENT", bx, y + 454, bw, "center", PAL.dim, fonts.small)
    local evs = { { "meteors", "Meteors" }, { "merchant", "Merchant" }, { "goblin", "Goblin" } }
    local ew = (bw - 20) / 3
    for i, ev in ipairs(evs) do
        button(ev[2], bx + (i - 1) * (ew + 10), y + 474, ew, 40, function()
            overlay = nil
            love.mouse.setVisible(false)
            X.EV = nil
            X.hostEvent(ev[1])
        end, MPS.role ~= "client" and not X.EV)
    end
    shadowText("Debug mode ends when you return to the main menu and start a new game.", x + 20, y + 530, w - 40, "center", PAL.dim, fonts.small)
    button("Close (I)", x + w / 2 - 90, y + h - 54, 180, 40, function() overlay = nil love.mouse.setVisible(false) end)
end
end

function love.draw()
    buttons = {}
    lg.setLineWidth(1)

    if gameState == "menu" then drawMenu() return end
    if gameState == "howto" then drawHowTo() return end
    if gameState == "mp" then X.drawMP() return end
    if gameState == "credits" then X.drawCredits() return end
    if gameState == "diff" then X.drawDiff() return end
    if gameState == "mode" then X.drawMode() return end
    if gameState == "stats" then X.drawStats() return end
    if gameState == "journal" then X.drawJournal() return end
    if gameState == "loading" then X.drawLoading() return end
    if gameState == "win" then drawEndScreen(true) return end
    if gameState == "lose" then drawEndScreen(false) return end

    drawWorld()
    X.drawNight()
    drawWeather()
    drawVignette()
    if showUI then drawHUD() end
    if not X.cut then X.drawChat() end
    drawBanner()

    if overlay == "pause" then drawPause()
    elseif overlay == "guide" then drawGuide()
    elseif overlay == "shop" then drawShop()
    elseif overlay == "inventory" then drawInventory()
    elseif overlay == "admin" and admin.on then drawAdminPanel()
    elseif overlay == "book" then drawBook()
    elseif overlay == "merchant" then X.drawMerchantShop()
    elseif overlay == "chest" then X.drawChest()
    end

    if admin.on then
        lg.setFont(fonts.tiny)
        lg.setColor(1, 0.35, 0.35, 0.85)
        local sw, sh = lg.getDimensions()
        lg.printf("ADMIN MODE", 0, sh - 14, sw, "center")
    end
    if MPS.online and player.dead and player.out then
        local sw, sh = lg.getDimensions()
        lg.setColor(0.25, 0, 0, 0.25)
        lg.rectangle("fill", 0, 0, sw, sh)
        shadowText("GAME OVER", 0, sh / 2 - 150, sw, "center", { 1, 0.3, 0.25 }, fonts.huge)
        local spec = X.spectateTarget()
        shadowText(spec and ("You are out of hearts. Spectating " .. (spec.name or "your team") .. "...")
            or "You are out of hearts.", 0, sh / 2 - 50, sw, "center", PAL.text, fonts.medium)
        shadowText("The game ends when every player is out.  ESC > Leave Game to quit now.", 0, sh / 2 - 16, sw, "center", PAL.dim, fonts.small)
    elseif MPS.online and player.dead then
        local sw, sh = lg.getDimensions()
        lg.setColor(0.3, 0, 0, 0.35)
        lg.rectangle("fill", 0, 0, sw, sh)
        shadowText("YOU ARE DOWN", 0, sh / 2 - 60, sw, "center", { 1, 0.35, 0.3 }, fonts.large)
        for i = 1, 3 do X.drawHeart(sw / 2 - 40 + (i - 1) * 40, sh / 2 + 50, 14, i <= (player.lives or 3)) end
        shadowText(string.format("Respawning in the shed in %d...  (you will lose a heart)", math.ceil(max(0, player.respawnT))), 0, sh / 2 - 10, sw, "center", PAL.text, fonts.medium)
        shadowText("A teammate can REVIVE you: they hold V next to you for 3 s (half HP, no heart lost).   R = respawn now",
            0, sh / 2 + 80, sw, "center", { 0.6, 1, 0.65 }, fonts.small)
    end
    if not overlay then drawCrosshair() end
end

------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------
-- leave the current game for the main menu (also disconnects from multiplayer)
function X.quitToMenu()
    if MPS.online then
        NET.stopAnnounce()
        NET.close()
        MPS.online, MPS.inGame, MPS.connecting, MPS.role, MPS.id, MPS.others = false, false, false, "solo", 1, {}
    end
    if stats and stats.kills > save.bestKills then save.bestKills = stats.kills end
    if stats and gameState == "play" then X.recordDiff(false) end
    writeSave()
    overlay = nil
    gameState = "menu"
    love.mouse.setVisible(true)
end

local function toggleOverlay(name)
    if overlay == name then
        overlay = nil
        love.mouse.setVisible(false)
    elseif overlay == nil or overlay == "pause" then
        overlay = name
        love.mouse.setVisible(true)
    end
    playSfx("click")
end

function love.keypressed(key)
    if gameState == "menu" then
        if key == "return" or key == "kpenter" then X.openDiff("solo")
        elseif key == "j" then X.openJournal()
        elseif key == "backspace" then admin.input = admin.input:sub(1, -2)
        elseif key == "escape" then love.event.quit() end
        return
    elseif gameState == "howto" then
        if key == "escape" then gameState = "menu" elseif key == "return" then X.openDiff("solo") end
        return
    elseif gameState == "mode" then
        if key == "1" then X.pickMode("story") elseif key == "2" then X.pickMode("endless")
        elseif key == "escape" then gameState = X.diffMode == "host" and "mp" or "menu" end
        return
    elseif gameState == "diff" then
        local n = tonumber(key)
        if n and X.DIFFS[n] then X.pickDiff(X.DIFFS[n].id)
        elseif key == "escape" then gameState = "mode" end
        return
    elseif gameState == "stats" then
        if key == "escape" then X.openMP() end
        return
    elseif gameState == "journal" then
        if key == "escape" then gameState = X.jr.back or "menu" end
        return
    elseif gameState == "win" or gameState == "lose" then
        if key == "return" and not X.lastWasMP then newGame({ diff = X.D.id, endless = X.lastEndless }) elseif key == "escape" then gameState = "menu" end
        return
    elseif gameState == "mp" then
        local M = X.mp
        if M.editing then
            if key == "backspace" then
                if M.editing == "name" then PROF.data.name = PROF.data.name:sub(1, -2)
                else M.ipText = M.ipText:sub(1, -2) end
            elseif key == "return" or key == "kpenter" or key == "escape" or key == "tab" then
                if M.editing == "name" then
                    if #PROF.data.name == 0 then PROF.data.name = "Player" end
                    MPS.name = PROF.data.name
                    PROF.save()
                end
                M.editing = (key == "tab") and (M.editing == "name" and "ip" or "name") or nil
            end
        elseif key == "escape" then
            if MPS.connecting then X.leaveGame("Connection cancelled.")
            else NET.stopBrowse() gameState = "menu" end
        end
        return
    elseif gameState == "credits" then
        if key == "escape" then
            if X.cs.roll then
                if X.cs.roll.done then X.cs.roll = nil end
            else
                X.openMP()
            end
        elseif (key == "return" or key == "space") and X.cs.roll and X.cs.roll.done then
            X.cs.roll = nil
        end
        return
    elseif gameState == "loading" then
        return
    end

    -- In-game
    if X.cut then return end           -- no input during the cutscene
    if X.chat.open then X.chatKey(key) return end
    if key == "t" and not overlay then
        X.chat.open, X.chat.text, X.chat.skipT = true, "", love.timer.getTime()
        return
    end
    if key == "escape" then
        if overlay then overlay = nil love.mouse.setVisible(false)
        else overlay = "pause" love.mouse.setVisible(true) end
        playSfx("click")
        return
    end
    if key == "r" and MPS.online and player.dead and not player.out and (player.respawnT or 0) > 0 then
        player.respawnT = 0.001
        return
    end
    if player.dead or endTimer then return end

    if overlay == "merchant" then
        local n = tonumber(key)
        if n then X.buyMerchant(n) return end
        if key == "e" then overlay = nil love.mouse.setVisible(false) return end
    end
    if key == "e" and not overlay and X.nearMerchant() then
        overlay = "merchant"
        love.mouse.setVisible(true)
        playSfx("merchant_bell")
        return
    end
    if key == "e" and not overlay and X.nearChest() then
        overlay = "chest"
        love.mouse.setVisible(true)
        playSfx("chest_open", 0.1, 0.6)
        return
    end
    if overlay == "chest" and key == "e" then overlay = nil love.mouse.setVisible(false) return end
    if key == "g" and not overlay then X.toggleHotbar()
    elseif key == "k" then toggleOverlay("guide")
    elseif key == "h" then toggleOverlay("shop")
    elseif key == "p" then toggleOverlay("inventory")
    elseif key == "f" then showUI = not showUI playSfx("click")
    elseif key == "i" and admin.on then toggleOverlay("admin")
    elseif key == "space" and overlay ~= "pause" then tryDash()
    elseif key == "b" then toggleOverlay("book")
    elseif overlay == "shop" then
        local n = tonumber(key)
        if n and SHOP[n] then buyItem(SHOP[n]) end
    elseif overlay == "inventory" then
        local n = tonumber(key)
        if admin.on then
            if n and X.WEAPON_ORDER[n] then equipWeapon(X.WEAPON_ORDER[n]) end
        elseif n and n >= 1 and n <= 4 and X.canSwitch() then
            -- new inventory: 1-4 select a weapon slot (never copies a weapon into it)
            X.hb.mode = "gun"
            X.selectGun(n)
        end
    end
end

-- Typing the admin code on the main menu
function love.textinput(t)
    if gameState == "play" and X.chat.open then X.chatText(t) return end
    if gameState == "mp" and X.mp.editing then
        local M = X.mp
        if M.editing == "name" then
            if t:match("^[%w _%-]$") and #PROF.data.name < 16 then PROF.data.name = PROF.data.name .. t end
        elseif t:match("^[%d%.]$") and #M.ipText < 15 then
            M.ipText = M.ipText .. t
        end
        return
    end
    if gameState ~= "menu" or admin.pending then return end
    if not t:match("^%w$") or #admin.input >= 6 then return end
    admin.input = admin.input .. t:lower()
    playSfx("click")
    if #admin.input == 6 then
        if admin.input == ADMIN_CODE then
            admin.pending = true
            admin.msg, admin.msgCol, admin.msgT = "ADMIN MODE ARMED", { 0.4, 1, 0.5 }, 2.5
            playSfx("buy")
        else
            admin.msg, admin.msgCol, admin.msgT = "INVALID CODE", { 1, 0.35, 0.3 }, 2
            playSfx("deny")
        end
        admin.input = ""
    end
end

function love.mousepressed(x, y, btn)
    if gameState == "play" and not overlay then
        if X.cut then return end
        if btn == 1 and not player.dead and X.hb.mode == "util" then X.useUtility(me.uslots and me.uslots[X.hb.usel]) return end
        if btn == 1 and not player.dead and not love.mouse.isDown(2) then tryShoot(true) end
        return
    end
    if btn ~= 1 then return end
    if gameState == "mp" then X.mp.editing = nil end
    if gameState == "credits" then
        local C = X.cs
        if C.bar and not C.roll and x >= C.bar.x and x <= C.bar.x + C.bar.w and y >= C.bar.y and y <= C.bar.y + C.bar.h then
            C.drag = true
            return
        end
    end
    for _, b in ipairs(buttons) do
        if b.enabled and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            playSfx("click")
            b.fn()
            return
        end
    end
end

function love.mousereleased(x, y, btn)
    if btn == 1 then X.cs.drag = nil end
end

function love.wheelmoved(dx, dy)
    if gameState == "play" and not overlay and not X.cut and not me.dead and dy ~= 0 then
        X.scrollHotbar(dy > 0 and -1 or 1)
        return
    end
    if gameState == "credits" and not X.cs.roll then
        X.cs.scroll = clamp(X.cs.scroll - dy * 60, 0, X.cs.maxScroll or 0)
    elseif gameState == "journal" then
        X.jr.scroll = clamp(X.jr.scroll - dy * 60, 0, X.jr.maxScroll or 0)
    end
end

function love.quit()
    if MPS.online then NET.stopAnnounce() NET.close() end
    writeSave()
end

function love.focus(f)
    if not f and gameState == "play" and not overlay and not endTimer and not MPS.online then
        overlay = "pause"
        love.mouse.setVisible(true)
    end
end

-- achievement toasts are drawn on top of every screen
do
    local baseDraw = love.draw
    function love.draw()
        baseDraw()
        X.drawToasts()
    end
end
