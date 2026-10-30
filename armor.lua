--[[
    FRONTIER - armor data (Credit Shop: ARMOR tab)

    Armor has 4 SLOTS: HEAD, CHEST, LEGS and FEET - wear one piece in each (choose
    them in the LOADOUT tab). Every piece gives SHIELD points; the shields of all
    pieces add up into one SHIELD that takes damage before your HP. A broken shield
    does not come back by itself: repair it with Metal Scraps (found in loot boxes) -
    in the inventory (P), hold an armor slot for 3 s = 1 scrap = +10 shield.
    The FEET slot and the Reinforced Vest come from the gold shop (H) during a run.
      slot   = head | chest | legs | feet        price  = Credit Shop price
      shield = shield points                     speed  = movement speed modifier
      fire   = fire damage modifier              stealth = enemies see you this much later
]]

local A = {}

A.SLOTS = { "head", "chest", "legs", "feet" }
A.SLOT_NAMES = { head = "Head", chest = "Chest", legs = "Legs", feet = "Feet" }

A.ARMOR = {
    miner = { slot = "head", name = "Miner's Hat", price = 15, shield = 10, speed = 0, lamp = true,
        desc = "+10 shield. Its headlamp lights up the night around you (you see farther in the dark)." },
    leather = { slot = "chest", name = "Leather Jacket", price = 18, shield = 15, speed = 0,
        desc = "Simple and light: +15 shield." },
    fireproof = { slot = "chest", name = "Fireproof Cloak", price = 21, shield = 20, speed = 0, fire = -0.10,
        desc = "+20 shield and -10% fire damage (flames, Fireburn, lava)." },
    shadow = { slot = "chest", name = "Shadow Cloak", price = 21, shield = 11, speed = -0.10, stealth = 0.15,
        desc = "+11 shield. Enemies spot you 15% later (shorter vision against you). -10% speed." },
    tanky = { slot = "chest", name = "Tanky Plate", price = 25, shield = 30, speed = -0.25, cannonRange = 0.20,
        desc = "+30 shield, -25% speed, but your Cannon shoots 20% farther." },
    waders = { slot = "legs", name = "Swamp Waders", price = 7, shield = 8, speed = 0, waders = true,
        desc = "+8 shield. Murky water no longer slows you and the Toad's poison lasts half as long." },
}
A.ARMOR_ORDER = { "miner", "leather", "fireproof", "shadow", "tanky", "waders" }
-- the gold-shop pieces (bought with gold during a run, never with credits)
A.ARMOR.vest = { slot = "chest", name = "Reinforced Vest", shield = 0, speed = 0, gold = true, id = "vest", isArmor = true,
    desc = "Gold shop (H): +25 max HP for this run. Takes the CHEST slot." }
A.ARMOR.boots = { slot = "feet", name = "Feather Boots", shield = 0, speed = 0, gold = true, id = "boots", isArmor = true,
    desc = "Gold shop (H): +35% speed, +1.2% damage taken while worn. Click the FEET slot to wear / remove them." }
A.SCRAP_REPAIR = 10          -- one Metal Scrap repairs this much shield
A.REPAIR_HOLD = 3            -- seconds to hold an armor slot in the inventory

for _, id in ipairs(A.ARMOR_ORDER) do
    local a = A.ARMOR[id]
    a.id, a.isArmor = id, true
end

return A
