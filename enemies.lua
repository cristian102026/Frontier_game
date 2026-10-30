--[[
    FRONTIER - enemy data (stats, rewards, colors and the Journal entries)
    HP and damage shown here are for EASY; harder difficulties multiply them.
]]

local rad = math.rad

local E = {}

E.ORDER = { "bandit", "scout", "bowman", "frozen", "snowman", "shroomer", "toad", "croc", "slime", "serpent", "blazeshroom",
            "gatekeeper", "gourd", "bat", "witch", "guardian" }

E.stats = {
    bandit  = { r = 15, hp = 80,  speed = 115, hunt = 165, vision = 480, fov = rad(65) },
    scout   = { r = 12, hp = 50,  speed = 140, hunt = 235, vision = 600, fov = rad(80) },
    bowman  = { r = 14, hp = 90,  speed = 150, hunt = 231, vision = 560, fov = rad(75) },   -- 10% faster than the player
    frozen  = { r = 14, hp = 70,  speed = 105, hunt = 150, vision = 460, fov = rad(70) },
    snowman = { r = 17, hp = 100, speed = 80,  hunt = 120, vision = 420, fov = rad(60) },
    gourd   = { r = 13, hp = 38,  speed = 90,  hunt = 155, vision = 400, fov = rad(70) },
    bat     = { r = 9,  hp = 20,  speed = 150, hunt = 255, vision = 175, fov = math.pi },
    witch   = { r = 14, hp = 60,  speed = 110, hunt = 156, vision = 520, fov = rad(70) },
    -- the Murky Swamp
    shroomer = { r = 14, hp = 31, speed = 70,  hunt = 105, vision = 520, fov = rad(70) },
    toad     = { r = 15, hp = 44, speed = 95,  hunt = 150, vision = 900, fov = rad(80) },
    croc     = { r = 18, hp = 52, speed = 85,  hunt = 120, vision = 650, fov = rad(70) },   -- 3x faster in the water
    -- the Volcanic Rift
    slime    = { r = 13, hp = 21, speed = 90,  hunt = 150, vision = 480, fov = rad(90) },
    slimelet = { r = 8,  hp = 7,  speed = 130, hunt = 200, vision = 420, fov = math.pi },
    serpent  = { r = 13, hp = 38, speed = 130, hunt = 230, vision = 600, fov = rad(80) },
    blazeshroom = { r = 19, hp = 70, speed = 55, hunt = 75, vision = 620, fov = rad(80) },
    -- BOSS: guards the Hollow gate (half the Guardian's HP)
    gatekeeper = { r = 46, hp = 2250, speed = 221, hunt = 221, vision = 99999, fov = math.pi },
    -- THE BOSS: huge, slow (30% slower than you) and it sees you through walls
    guardian = { r = 105, hp = 4500, speed = 147, hunt = 147, vision = 99999, fov = math.pi },
}

E.names = { bandit = "Bandit", scout = "Scout", bowman = "Bow Wielder", frozen = "Frozen", snowman = "Snowman Soldier",
            gourd = "Gourd", bat = "Bat", witch = "Witch", guardian = "Guardian of the Hollow" , shroomer = "Shroomer", toad = "Toad", croc = "Crocodile", slime = "Magma Slime", slimelet = "Small Magma Slime", serpent = "Lava Serpent", blazeshroom = "BlazeShroom", gatekeeper = "Blaze Gatekeeper" }

E.region = { bandit = "desert", scout = "desert", bowman = "desert", frozen = "frozen", snowman = "frozen",
             gourd = "spooky", bat = "spooky", witch = "spooky", guardian = "spooky" , shroomer = "swamp", toad = "swamp", croc = "swamp", slime = "volcanic", slimelet = "volcanic", serpent = "volcanic", blazeshroom = "volcanic", gatekeeper = "volcanic" }

E.reward = { bandit = { 26, 36 }, scout = { 16, 24 }, bowman = { 32, 44 }, frozen = { 30, 40 }, snowman = { 34, 46 },
             gourd = { 24, 32 }, bat = { 14, 20 }, witch = { 38, 50 }, guardian = { 400, 500 } , shroomer = { 22, 30 }, toad = { 26, 34 }, croc = { 32, 42 }, slime = { 18, 26 }, slimelet = { 6, 10 }, serpent = { 30, 40 }, blazeshroom = { 40, 52 }, gatekeeper = { 250, 320 } }

E.statKey = { bandit = "banditKills", scout = "scoutKills", bowman = "bowmanKills", frozen = "frozenKills",
              snowman = "snowmanKills", gourd = "gourdKills", bat = "batKills", witch = "witchKills", guardian = "guardianKills" , shroomer = "shroomerKills", toad = "toadKills", croc = "crocKills", slime = "slimeKills", slimelet = "slimeKills", serpent = "serpentKills", blazeshroom = "blazeshroomKills", gatekeeper = "gatekeeperKills" }

E.killColor = { bandit = { 1, 0.55, 0.45 }, scout = { 0.55, 0.8, 1 }, bowman = { 0.6, 0.9, 0.45 },
                frozen = { 0.7, 0.92, 1 }, snowman = { 0.92, 0.95, 1 },
                gourd = { 1, 0.6, 0.2 }, bat = { 0.75, 0.65, 0.85 }, witch = { 0.8, 0.5, 1 }, guardian = { 1, 0.7, 0.2 } , shroomer = { 1, 0.4, 0.4 }, toad = { 0.6, 0.85, 0.3 }, croc = { 0.4, 0.7, 0.35 }, slime = { 1, 0.5, 0.15 }, slimelet = { 1, 0.6, 0.25 }, serpent = { 1, 0.65, 0.3 }, blazeshroom = { 1, 0.6, 0.15 }, gatekeeper = { 1, 0.45, 0.1 } }

E.mapColor = { bandit = { 0.95, 0.3, 0.2 }, scout = { 0.4, 0.75, 1 }, bowman = { 0.45, 0.85, 0.3 },
               frozen = { 0.3, 0.95, 1 }, snowman = { 1, 1, 1 },
               gourd = { 1, 0.55, 0.1 }, bat = { 0.75, 0.6, 0.9 }, witch = { 0.8, 0.3, 1 }, guardian = { 1, 0.45, 0 } , shroomer = { 0.95, 0.2, 0.2 }, toad = { 0.55, 0.85, 0.2 }, croc = { 0.3, 0.6, 0.25 }, slime = { 1, 0.45, 0.05 }, slimelet = { 1, 0.6, 0.2 }, serpent = { 1, 0.85, 0.5 }, blazeshroom = { 1, 0.55, 0.1 }, gatekeeper = { 1, 0.3, 0 } }

E.hpColor = { bandit = { 0.9, 0.25, 0.2 }, scout = { 0.4, 0.7, 1 }, bowman = { 0.45, 0.85, 0.3 },
              frozen = { 0.55, 0.9, 1 }, snowman = { 0.85, 0.9, 0.95 },
              gourd = { 1, 0.55, 0.15 }, bat = { 0.7, 0.6, 0.8 }, witch = { 0.75, 0.4, 1 }, guardian = { 0.75, 0.05, 0.12 } , shroomer = { 0.9, 0.25, 0.25 }, toad = { 0.55, 0.85, 0.25 }, croc = { 0.35, 0.7, 0.3 }, slime = { 1, 0.5, 0.1 }, slimelet = { 1, 0.6, 0.2 }, serpent = { 1, 0.7, 0.3 }, blazeshroom = { 1, 0.55, 0.1 }, gatekeeper = { 0.85, 0.2, 0.05 } }

E.spotSound = { bandit = "spot", bowman = "spot", frozen = "yeti_growl", snowman = "snowman_spot",
                gourd = "gourd_spot", bat = "bat_screech", witch = "spot", guardian = "boss_laugh" , shroomer = "spot", toad = "toad_croak", croc = "croc_snap", slime = "slime_hop", slimelet = "slime_hop", serpent = "spot", blazeshroom = "spot", gatekeeper = "boss_laugh" }

-- The Journal (opened from the main menu)
E.journal = {
    bandit = { region = "Dustbowl Frontier", weapon = "Pistol - 18-28 DMG",
        text = "Patrols the plains in groups of five. Once it spots you it hunts you down, strafes sideways and keeps firing. Searches your last known position when it loses sight of you." },
    scout = { region = "Dustbowl Frontier", weapon = "None - binoculars",
        text = "Fast and wide-eyed. Never fights: when it sees you it runs away and raises an ALARM that sends every bandit within 750 px after you." },
    bowman = { region = "The Stronghold (Dustbowl Frontier)", weapon = "Bow - 20 DMG, 1 arrow every 2 s",
        text = "Guards the rare Stronghold and never leaves it. Very agile (10% faster than you): it stops, shoots, then moves to a new spot - stop, shoot, move. 5 more appear inside the Stronghold every 5 minutes." },
    frozen = { region = "The Frozen Wastes", weapon = "Icicles - 7 DMG + 15% slow",
        text = "A small yeti that throws icicles. Getting hit slows you for 3 seconds. Blocking an icicle shatters it completely." },
    snowman = { region = "The Frozen Wastes", weapon = "Branch 12 DMG / Snowballs 3 DMG",
        text = "Swings a branch up close with a short wind-up you can dodge. From range it throws snowballs that knock you far back." },
    gourd = { region = "The Haunted Hollow", weapon = "Bite - 18 DMG",
        text = "A hopping pumpkin. Its lunge has a 10% chance to SPOOK you: a jumpscare, a creepy song and 3 seconds of darkness." },
    bat = { region = "The Haunted Hollow", weapon = "Bite - 5 DMG",
        text = "Flies over walls but can only see you up close. After a bite it vanishes for 10 seconds and returns to the exact spot." },
    witch = { region = "The Haunted Hollow", weapon = "Poison potion - 2 DMG/s for 5 s",
        text = "Fast, and she dashes sideways when you aim at her. Cackles before throwing a purple potion - blocking it stops the poison. "
            .. "Its puddle stays for 30 s and poisons you again if you step in it. 15% chance to drop THE CURSED SPELL." },
    shroomer = { region = "The Murky Swamp", weapon = "Bite - 16 DMG / Mushroom (no damage)",
        text = "Throws mushrooms that do no damage but curse you (1 in 3 each): SLOWNESS (-30% speed, 5 s), WEAKNESS (+25% damage taken, 5 s) or FUNGUS (green vision, 10 s). Your shield can't stop them. Bites up close." },
    toad = { region = "The Murky Swamp", weapon = "Tongue - 11 DMG (300 px) / Poison spit",
        text = "Sprints after you for 1 second, then lashes its tongue up to 300 px. If you are more than 600 px away it spits poison (2 DMG/s for 6 s) that your shield can't stop." },
    croc = { region = "The Murky Swamp", weapon = "Bite - 32 DMG",
        text = "Hides in the murky water with only its eyes showing. Very fast while swimming, slower on land. Murky water also slows YOU by 20%." },
    slime = { region = "The Volcanic Rift", weapon = "Bite - 18 DMG (25%: 24 FIREBURN)",
        text = "A hopping blob of magma. 25% chance to deal 24 instead of 18. When killed it SPLITS into two small slimes (7 HP, 6 DMG)." },
    serpent = { region = "The Volcanic Rift", weapon = "Bite - 31 DMG / Pass-through 5 DMG",
        text = "A burning fish skeleton that swims through the air and over walls. It darts THROUGH you (5 DMG, -10% speed) and bites hard up close." },
    blazeshroom = { region = "The Volcanic Rift", weapon = "Fire spit - 20 DMG, 500 px",
        text = "A big glowing mushroom. Slow, but it spits a flame every 0.9 seconds. Lava pools burn you for 10 DMG/s - watch your step." },
    gatekeeper = { region = "The Volcanic Rift (in front of the Hollow gate)", weapon = "4 attacks", boss = true,
        text = "BOSS guarding the Hollow gate. BLAZE ROD: 25 DMG up close. FIRE SPIT: 30 DMG flames (Easy 3, Normal 5, Hard 6, Nightmare 8). "
            .. "FIRE SWIRL: spins for 2 s, then flames in every direction (10 / 15 / 20 / 25). FIRE SHIELD: 3.5 s at half speed - it deflects EVERYTHING back at you, even your spells. Drops the KEY to the Hollow and teaches you the BLAZE SPELL (+5 credits).",
        how = "HOW TO ENCOUNTER: open the Volcanic Rift (200 kills) and walk into his arena at the far south of it, right in front of the Hollow gate." },
    guardian = { region = "The Guardian's Lair (far south of the Haunted Hollow)", weapon = "4 attacks", boss = true,
        text = "THE FINAL BOSS - defeat it to win the game (+30 credits). A giant gourd in a witch hat. Slow, strafes from side to side and sees you through walls. "
            .. "IMMUNE to blast weapons (RPG, Meteor Caller, Black Hole, Cannon, Bubble Blaster, Grenades). "
            .. "THE LAUGHTER: waves of fast spooky faces, 20 DMG each.  JUMP: shakes for 1 s, then lands on you for 50 DMG and an earthquake "
            .. "(-10% speed for 5 s) - dash to dodge!  NECROMANCER: brings back the Gourds you killed (up to 15).  "
            .. "BOOMERANG HAT: a spinning hat thrown 1200 px and back, 3 times, 20 DMG. Your shield works against everything. "
            .. "Harder difficulties: faster attacks (Normal 1.5x, Hard 2x, Nightmare 2.5x) and more waves of faces (5 / 7 / 9 / 11).",
        how = "HOW TO ENCOUNTER (Story mode): open the Haunted Hollow (250 kills + the Blaze Gatekeeper's key) AND infiltrate the Stronghold "
            .. "(walk up to its keep). Then the Lair at the far south of the Hollow opens - walk in, and the gate closes behind you." },
}

-- the TREASURE GOBLIN (random event): runs away, catch it within 30 s for big gold and loot
E.stats.goblin = { r = 13, hp = 60, speed = 160, hunt = 250, vision = 99999, fov = math.pi }
E.names.goblin = "Treasure Goblin"
E.region.goblin = "desert"
E.reward.goblin = { 150, 220 }
E.killColor.goblin = { 1, 0.85, 0.2 }
E.mapColor.goblin = { 1, 0.85, 0.1 }
E.hpColor.goblin = { 1, 0.8, 0.1 }
E.spotSound.goblin = "goblin_giggle"
E.journal.goblin = { region = "Any region (random event)", weapon = "None - it runs away",
    text = "Sometimes a Treasure Goblin appears near a player with a big bag of gold. It never fights - it giggles and runs away, "
        .. "zig-zagging around obstacles. Catch it within 30 seconds: it drops 150-220 gold and 3 loot boxes. Otherwise it escapes." }
table.insert(E.ORDER, #E.ORDER, "goblin")   -- before the Guardian

return E
