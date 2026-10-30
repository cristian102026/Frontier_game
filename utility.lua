--[[
    FRONTIER - utility data (Credit Shop: UTILITY tab). Armor lives in armor.lua.

    UTILITIES are bought ONCE with credits and are yours forever. Put up to 4 in your
    LOADOUT; every run you start with `uses` charges of each one.
      price    = Credit Shop price               uses   = charges per run
      cooldown = seconds between two uses        chance = Utility Crate odds (%)
      mod      = movement speed modifier while it is selected in the hotbar
      range    = throw distance (px)             radius = area of effect (px)

]]

local U = {}

U.UTILITY = {
    grenade = { name = "Grenade", price = 15, uses = 5, cooldown = 15, chance = 22, mod = 0,
        dmg = 60, range = 400, radius = 110,
        desc = "Throw it at your cursor (400 px): 60 DMG blast. A blast weapon - the Guardian is immune." },
    medkit = { name = "Medkit", price = 20, uses = 5, cooldown = 20, chance = 16, mod = 0,
        heal = 100,
        desc = "Heals 100 HP (never above your max HP)." },
    goldpot = { name = "Potion of GOLD", price = 30, uses = 5, cooldown = 0, chance = 10, mod = 0,
        duration = 120, gold = 0.5,
        desc = "+50% gold from kills for 2:00. Drinking another one resets the timer." },
    smoke = { name = "Smoke Bomb", price = 15, uses = 5, cooldown = 20, chance = 18, mod = 0,
        range = 400, radius = 250, duration = 8,
        desc = "A thick 250 px cloud for 8 s: enemies can't see into it or through it and lose track of you." },
    trap = { name = "Bear Trap", price = 20, uses = 5, cooldown = 5, chance = 14, mod = 0,
        dmg = 25, hold = 4, max = 3,
        desc = "Placed at your feet. The first enemy that steps on it takes 25 DMG and is stuck for 4 s. Max 3 at once." },
    decoy = { name = "Decoy Dummy", price = 25, uses = 5, cooldown = 30, chance = 10, mod = 0,
        hp = 100, duration = 8, radius = 600,
        desc = "A scarecrow in your hat: every enemy within 600 px attacks it instead of you for 8 s (100 HP)." },
    turret = { name = "Sentry Turret", price = 40, uses = 3, cooldown = 60, chance = 4, mod = 0,
        dmg = 12, rate = 1 / 3, range = 500, duration = 20,
        desc = "Deploys a small turret for 20 s: shoots the nearest enemy (12 DMG, 3 shots/s, 500 px)." },
    recall = { name = "Recall Scroll", price = 30, uses = 3, cooldown = 90, chance = 6, mod = 0,
        channel = 2,
        desc = "Channel for 2 s, then teleport back to the shed. Taking damage cancels it. Not in boss fights." },
}
U.UTILITY_ORDER = { "grenade", "medkit", "goldpot", "smoke", "trap", "decoy", "turret", "recall" }
U.UTILITY_CRATE_PRICE = 10

for _, id in ipairs(U.UTILITY_ORDER) do
    local u = U.UTILITY[id]
    u.id, u.isUtility = id, true
    u.chance = u.chance / 100
end
return U
