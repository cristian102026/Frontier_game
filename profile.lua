--[[
    FRONTIER - permanent player data (survives every game, single-player and multiplayer)

    Stored in LÖVE's save directory as frontier_profile.txt (with a .bak copy):
      credits, kills towards the next credit, permanently owned weapons,
      player name, records and audio settings.
]]

local P = {}

local FILE, BACKUP, OLD_SAVE = "frontier_profile.txt", "frontier_profile.bak", "frontier_save.txt"
P.KILLS_PER_CREDIT = 10

local function defaults()
    return {
        credits = 0, killBank = 0, lifetimeKills = 0, cratesOpened = 0,
        bestKills = 0, bestTime = 0, wins = 0, games = 0, mpGames = 0,
        volume = 0.8, music = 1, creditsTotal = 0,
        name = "Player" .. love.math.random(100, 999),
        rarest = "",         -- rarest weapon ever pulled from a Loot Crate
        owned = {},          -- weaponId -> true (permanent weapons from the Credit Shop)
        util = {},           -- utilityId -> true (Credit Shop > UTILITY)
        arm = {},            -- armorId -> true (Credit Shop > ARMOR)
        lo = { w1 = "pistol" },   -- LOADOUT: w1..w4 weapons, u1..u4 utilities, a = armor
    }
end

-- records are kept per difficulty: bestKills_easy, wins_hard, bestTime_nightmare ...
P.DIFFS = { "easy", "normal", "hard", "nightmare" }
P.ACH_IDS = { "firstblood", "centurion", "maxlevel", "infiltrator", "gatekeeper", "guardian", "nightmare", "survivor",
              "collector", "lucky", "savior", "treasure", "explorer", "spellbinder" }
P.SPELL_IDS = { "turtle", "icicles", "snowgrave", "iceshock", "cursed", "blaze" }
local function withDiffs(d)
    for _, id in ipairs(P.DIFFS) do
        d["bestKills_" .. id], d["wins_" .. id], d["bestTime_" .. id] = 0, 0, 0
        d["bestWave_" .. id] = 0                         -- Endless mode
    end
    -- achievements (ach_<id> = 1 once unlocked) and spells ever cast (cast_<id> = 1)
    for _, id in ipairs(P.ACH_IDS) do d["ach_" .. id] = 0 end
    for _, id in ipairs(P.SPELL_IDS) do d["cast_" .. id] = 0 end
    -- the LOADOUT (indices into the weapon / utility / armor order lists, 0 = empty): the Pistol in slot 1
    d.lw1, d.lw2, d.lw3, d.lw4 = 1, 0, 0, 0
    d.lu1, d.lu2, d.lu3, d.lu4 = 0, 0, 0, 0
    d.lah, d.lac, d.lal = 0, 0, 0           -- armor: head / chest / legs (feet = gold-shop boots)
    return d
end

local base = defaults
defaults = function() return withDiffs(base()) end
P.data = defaults()

local function parse(text)
    if type(text) ~= "string" or not text:find("end=1", 1, true) then return nil end
    local d = defaults()
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_%.]+)=(.*)$")
        if k then
            local w = k:match("^own%.(.+)$")
            local ut, ar, lo = k:match("^util%.(.+)$"), k:match("^arm%.(.+)$"), k:match("^lo%.(%w+)$")
            if w then
                if v == "1" then d.owned[w] = true end
            elseif ut then
                if v == "1" then d.util[ut] = true end
            elseif ar then
                if v == "1" then d.arm[ar] = true end
            elseif lo then
                v = v:gsub("[^%w]", ""):sub(1, 20)
                d.lo[lo] = #v > 0 and v or nil
            elseif k == "name" then
                v = v:gsub("[^%w _%-]", ""):sub(1, 16)
                if #v > 0 then d.name = v end
            elseif k == "rarest" then
                d.rarest = v:gsub("[^%w]", ""):sub(1, 20)
            elseif k ~= "end" and type(d[k]) == "number" then
                d[k] = tonumber(v) or d[k]
            end
        end
    end
    return d
end

function P.load()
    local d
    if love.filesystem.getInfo(FILE) then d = parse(love.filesystem.read(FILE)) end
    if not d and love.filesystem.getInfo(BACKUP) then d = parse(love.filesystem.read(BACKUP)) end
    if not d then
        d = defaults()
        -- migrate records from the old save file
        if love.filesystem.getInfo(OLD_SAVE) then
            local old = love.filesystem.read(OLD_SAVE) or ""
            for k, v in old:gmatch("(%w+)=([%d%.]+)") do
                if type(d[k]) == "number" then d[k] = tonumber(v) or d[k] end
            end
        end
    end
    -- keep the same table so references held elsewhere stay valid
    for k in pairs(P.data) do P.data[k] = nil end
    for k, v in pairs(d) do P.data[k] = v end
    return P.data
end

function P.save()
    local d = P.data
    local out = {}
    for k, v in pairs(d) do
        if type(v) == "number" then out[#out + 1] = k .. "=" .. tostring(v)
        elseif k == "name" or k == "rarest" then out[#out + 1] = k .. "=" .. tostring(v) end
    end
    for w, own in pairs(d.owned) do
        if own then out[#out + 1] = "own." .. w .. "=1" end
    end
    for u, own in pairs(d.util or {}) do
        if own then out[#out + 1] = "util." .. u .. "=1" end
    end
    for a, own in pairs(d.arm or {}) do
        if own then out[#out + 1] = "arm." .. a .. "=1" end
    end
    for slot, id in pairs(d.lo or {}) do
        out[#out + 1] = "lo." .. slot .. "=" .. tostring(id)
    end
    table.sort(out)
    out[#out + 1] = "end=1"
    local text = table.concat(out, "\n")
    -- keep the previous good file as a backup before overwriting
    if love.filesystem.getInfo(FILE) then
        local prev = love.filesystem.read(FILE)
        if prev and prev:find("end=1", 1, true) then love.filesystem.write(BACKUP, prev) end
    end
    love.filesystem.write(FILE, text)
end

-- Count a kill. Returns true when it completed a new credit.
function P.addKill()
    local d = P.data
    d.lifetimeKills = d.lifetimeKills + 1
    d.killBank = d.killBank + 1
    if d.killBank >= P.KILLS_PER_CREDIT then
        d.killBank = d.killBank - P.KILLS_PER_CREDIT
        d.credits = d.credits + 1
        P.save()
        return true
    end
    return false
end

function P.owns(id) return P.data.owned[id] == true end
function P.hasUtil(id) return P.data.util[id] == true end
function P.hasArmor(id) return P.data.arm[id] == true end
function P.grantUtil(id) P.data.util[id] = true P.save() end
function P.grantArmor(id) P.data.arm[id] = true P.save() end

function P.grant(id)
    P.data.owned[id] = true
    P.save()
end

function P.spend(n)
    if P.data.credits < n then return false end
    P.data.credits = P.data.credits - n
    P.save()
    return true
end

return P
