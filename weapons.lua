--[[
    FRONTIER - weapon data

    Every gun uses the same universal "Ammo".
      range  = how far a shot travels (px)        mod    = movement speed modifier while held
      rate   = seconds between shots              price  = Credit Shop price (permanent weapon)
      chance = Loot Crate odds (Hall of Fame weapons can never be pulled from crates)
      shop   = "normal" | "fictional" | "fame"   (nil = not sold for credits)
      kind   = how the weapon fires:
               bullet, rocket, laser, flame, boomerang, hammer, tesla, blackhole, meteor
      fx     = effects on hit: b = burn, u = bubble (trapped), f = freeze (slow),
               k = knockback, g = golden (+50% gold), s = silent (doesn't alert)
]]

local rad = math.rad

local W = {
    -- starting / gold-shop weapons ----------------------------------------
    pistol = { name = "Pistol", min = 18, max = 28, rate = 0.28, spread = 0.035, speed = 1150, range = 920, mod = 0,
        kind = "bullet", sound = "pistol", shake = 2.5, len = 15, desc = "Reliable sidearm. You always start with it." },
    shotgun = { name = "Shotgun", min = 45, max = 62, rate = 0.85, pellets = 7, spread = 0.26, speed = 860, range = 310, mod = 0,
        kind = "bullet", sound = "shotgun", shake = 8, kick = 90, len = 24,
        desc = "Close-range blast. Bought with gold in the Shop (H)." },

    -- NORMAL SHOP -----------------------------------------------------------
    revolver = { shop = "normal", name = "Revolver", min = 16, max = 20, rate = 0.24, spread = 0.03, speed = 1250, range = 820,
        mod = 0.10, kind = "bullet", sound = "revolver", shake = 3.5, len = 17, price = 25, chance = 14,
        desc = "Light and quick. Keeps you nimble." },
    swifter = { shop = "normal", name = "Swifter's Pistol", min = 25, max = 40, rate = 0.22, spread = 0.05, speed = 1300, range = 650,
        mod = 0.25, kind = "bullet", sound = "swifter", shake = 2, len = 13, price = 40, chance = 10,
        desc = "A featherweight pistol for hit-and-run fighters." },
    uzi = { shop = "normal", name = "Uzi", min = 8, max = 10, rate = 1 / 12, spread = 0.09, speed = 1200, range = 800,
        mod = 0.05, kind = "bullet", sound = "uzi", shake = 1, len = 14, price = 40, chance = 10,
        desc = "Sprays a stream of small bullets." },
    spray = { shop = "normal", name = "Spray Gun", min = 6, max = 10, rate = 1 / 16, spread = rad(9), speed = 950, range = 500,
        mod = 0, kind = "bullet", sound = "spray", shake = 0.5, len = 18, ammoCost = 1 / 3, price = 40, chance = 8,
        desc = "Hoses an 18-degree cone of pellets. 1 Ammo per 3 shots." },
    crossbow = { shop = "normal", name = "Crossbow", min = 40, max = 55, rate = 1 / 1.2, spread = 0.01, speed = 1000, range = 620,
        mod = 0, kind = "bullet", look = "bolt", fx = "s", sound = "bow", shake = 1.5, len = 18, price = 80, chance = 7,
        desc = "Silent: enemies you hit don't notice you unless they die." },
    flamethrower = { shop = "normal", name = "Flamethrower", min = 4, max = 6, rate = 1 / 12, spread = 0.14, speed = 420, range = 210,
        mod = -0.10, kind = "flame", fx = "b", sound = "flame", shake = 0.4, len = 22, price = 140, chance = 5,
        desc = "Sets enemies on fire: they keep burning for 3 seconds." },
    rifle = { shop = "normal", name = "Assault Rifle", min = 17, max = 20, rate = 1 / 8, spread = 0.045, speed = 1500, range = 960,
        mod = -0.25, kind = "bullet", sound = "rifle", shake = 2.2, len = 28, price = 140, chance = 5,
        desc = "Fully automatic and long range." },
    sniper = { shop = "normal", name = "Sniper Rifle", min = 90, max = 110, rate = 1 / 0.6, spread = 0.004, speed = 2600, range = 1200,
        mod = -0.15, kind = "bullet", pierce = 2, sound = "sniper", shake = 6, kick = 30, len = 34, price = 160, chance = 3,
        desc = "Huge range. Each bullet pierces through 2 enemies." },
    minigun = { shop = "normal", name = "Minigun", min = 10, max = 14, rate = 1 / 20, spread = 0.08, speed = 1400, range = 720,
        mod = -0.25, kind = "bullet", spinup = 0.7, sound = "uzi", shake = 1.2, len = 30, price = 170, chance = 2,
        desc = "Spins up for a moment, then shreds everything." },
    rpg = { shop = "normal", name = "RPG", min = 80, max = 100, rate = 1.25, spread = 0.01, speed = 560, range = 600,
        mod = -0.20, kind = "rocket", blast = 100, sound = "rpg_fire", shake = 7, kick = 60, len = 30, price = 150, chance = 3,
        desc = "Explodes on contact or after 500 px. 100 px blast radius." },

    -- FICTIONAL SHOP --------------------------------------------------------
    bubble = { shop = "fictional", name = "Bubble Blaster", min = 5, max = 8, rate = 0.2, spread = 0.05, speed = 600, range = 500,
        mod = 0.05, kind = "bullet", look = "bubble", fx = "u", sound = "bubble", shake = 0.5, len = 18, price = 50, chance = 7,
        desc = "Traps enemies in a bubble for 2 seconds." },
    laser = { shop = "fictional", name = "Laser Gun", min = 125, max = 140, rate = 1 / 1.3, speed = 0, range = 300,
        mod = 0.05, kind = "laser", sound = "laser", shake = 4, len = 20, price = 60, chance = 3,
        desc = "Point-blank beam that pierces every enemy in its reach." },
    boomerang = { shop = "fictional", name = "Boomerang Blade", min = 35, max = 50, rate = 1 / 1.5, speed = 620, range = 400,
        mod = 0.10, kind = "boomerang", sound = "boomerang", shake = 1, len = 16, price = 70, chance = 6,
        desc = "Flies out and comes back - it can hit each enemy twice." },
    hammer = { shop = "fictional", name = "Gravity Hammer", min = 70, max = 90, rate = 1.0, range = 100,
        mod = -0.15, kind = "hammer", fx = "k", sound = "hammer", shake = 6, len = 20, price = 100, chance = 4,
        desc = "Melee smash with huge knockback." },
    void = { shop = "fictional", name = "Void Pistol", min = 28, max = 36, rate = 1 / 3, spread = 0.02, speed = 900, range = 500,
        mod = 0, kind = "bullet", ghost = true, look = "void", sound = "void", shake = 2, len = 15, price = 120, chance = 3,
        desc = "Its bullets pass straight through walls." },
    plasma = { shop = "fictional", name = "Plasma Rifle", min = 60, max = 79, rate = 1 / 6, spread = 0.03, speed = 1200, range = 900,
        mod = -0.10, kind = "bullet", look = "plasma", sound = "plasma", shake = 2, len = 26, price = 160, chance = 3,
        desc = "Fires glowing plasma bolts." },
    tesla = { shop = "fictional", name = "Tesla Gun", min = 20, max = 30, rate = 0.5, range = 800,
        mod = -0.05, kind = "tesla", chain = 3, sound = "tesla", shake = 3, len = 20, price = 140, chance = 2,
        desc = "Lightning jumps between up to 3 enemies." },
    ghostbow = { shop = "fictional", name = "Ghost Bow", min = 45, max = 60, rate = 1 / 1.4, spread = 0.02, speed = 750, range = 800,
        mod = 0.10, kind = "bullet", homing = true, look = "ghost", sound = "bow", shake = 1, len = 18, price = 160, chance = 2,
        desc = "Its arrows home in on the nearest enemy." },
    blackhole = { shop = "fictional", name = "Black Hole Launcher", min = 60, max = 80, rate = 2.5, spread = 0, speed = 420, range = 450,
        mod = -0.25, kind = "blackhole", sound = "blackhole", shake = 3, len = 26, price = 220, chance = 1.5,
        desc = "Opens a black hole that pulls enemies in for 2 s, then implodes." },
    meteor = { shop = "fictional", name = "Meteor Caller", min = 100, max = 130, rate = 8, range = 700,
        mod = -0.20, kind = "meteor", blast = 120, sound = "meteor", shake = 2, len = 22, price = 250, chance = 1.5,
        desc = "A meteor crashes down on your cursor 1 second later." },

    -- sold by the travelling merchant in Endless (gold, this run only) ---------
    axe = { name = "Battle Axe", min = 50, max = 50, rate = 0.8, range = 90, noAmmo = true,
        mod = 0, kind = "hammer", sound = "hammer", shake = 4, len = 20,
        desc = "A heavy melee axe: 50 DMG in a wide arc, 90 px reach. No ammo needed." },

    -- HALL OF FAME (buy-only, never in Loot Crates) -------------------------
    freezer = { shop = "fame", name = "Freezing Gun", min = 8, max = 10, rate = 1 / 8, spread = 0.06, speed = 1000, range = 850,
        mod = -0.10, kind = "bullet", look = "ice", fx = "f", sound = "freeze_gun", shake = 0.6, len = 20, price = 75,
        desc = "Freezing shots slow enemies for 2 seconds." },
    huntsman = { shop = "fame", name = "Huntsman Rifle", min = 60, max = 75, rate = 1.0, spread = 0.008, speed = 2000, range = 900,
        mod = -0.10, kind = "bullet", sound = "sniper", shake = 4, kick = 20, len = 30, price = 90,
        desc = "A trusty hunting rifle. Hits hard, fires slowly." },
    cannon = { shop = "fame", name = "Cannon", min = 80, max = 100, rate = 6, spread = 0.01, speed = 650, range = 500,
        mod = -0.25, kind = "bullet", look = "ball", fx = "k", sound = "cannon", shake = 8, kick = 80, len = 26, price = 90,
        desc = "Heavy cannonballs that knock enemies back." },
    golden = { shop = "fame", name = "Golden Shooter", min = 30, max = 45, rate = 1 / 3, spread = 0.03, speed = 1200, range = 760,
        mod = -0.20, kind = "bullet", look = "gold", fx = "g", sound = "revolver", shake = 3, len = 18, price = 100,
        desc = "Kills made with it give +50% gold." },
}

-- display order of the shop sections and the inventory
W.ORDER = {
    "pistol", "shotgun",
    "revolver", "swifter", "uzi", "spray", "crossbow", "flamethrower", "rifle", "sniper", "minigun", "rpg",
    "bubble", "laser", "boomerang", "hammer", "void", "plasma", "tesla", "ghostbow", "blackhole", "meteor",
    "freezer", "huntsman", "cannon", "golden", "axe",
}

for _, id in ipairs(W.ORDER) do
    local w = W[id]
    w.id = id
    w.pellets = w.pellets or 1
    w.spread = w.spread or 0
    w.speed = w.speed or 0
    w.kick = w.kick or 0
    w.life = w.speed > 0 and w.range / w.speed or 0
    if w.chance then w.chance = w.chance / 100 end
end

-- the merchant's BATTLE AXE (Endless mode, bought with gold for one run - never sold for credits)
W.axe = { name = "Battle Axe", min = 50, max = 50, rate = 0.8, range = 90, mod = 0, kind = "hammer", noAmmo = true,
    sound = "hammer", shake = 4, len = 20, desc = "Melee swing: 50 DMG to everything in a 90 px arc. Uses no ammo." }
W.axe.id, W.axe.pellets, W.axe.spread, W.axe.speed, W.axe.kick, W.axe.life = "axe", 1, 0, 0, 0, 0

return W
