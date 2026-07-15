--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

--[[
    SPerks_HeavyArmor.lua

    Heavy Armor rewards committing to weight, impact, and full-set defence.
    See SkillPerks_Combat.md's Heavy Armor section for the full spec.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local StatTracker       = require("scripts.SkillPerks.shared.stat_tracker")
local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local ArmorPoints        = require("scripts.SkillPerks.shared.armor_points")
local CombatMath         = require("scripts.SkillPerks.shared.combat_math")

-- Reads the framework's cached player perk set for quick rank checks.
local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local SKILL_ID = "heavyarmor"

local ids = {
    A1 = ns .. "_heavyarmor_a1",
    A2 = ns .. "_heavyarmor_a2",
    A3 = ns .. "_heavyarmor_a3",
    A4 = ns .. "_heavyarmor_a4",
    B1 = ns .. "_heavyarmor_b1",
    B2 = ns .. "_heavyarmor_b2",
    C1 = ns .. "_heavyarmor_c1",
    C2 = ns .. "_heavyarmor_c2",
    D1 = ns .. "_heavyarmor_d1",
    D2 = ns .. "_heavyarmor_d2",
}

--- Totals the Heavy Armor the player is actually wearing right now.
--- @return number totalWeight
--- @return number pieceCount
local function getHeavyArmorInfo()
    local _, breakdown = ArmorPoints.getPoints(self)
    local totalWeight = 0
    local pieceCount = 0
    for _, entry in pairs(breakdown) do
        if entry.armorClass == "heavyarmor" then
            pieceCount = pieceCount + 1
            totalWeight = totalWeight + (types.Armor.record(entry.item).weight or 0)
        end
    end
    return totalWeight, pieceCount
end

local aTracker  = StatTracker.newActiveEffectTracker(self) -- A: Feather
local bTracker  = StatTracker.newStatModTracker(self)       -- B: Fortify Fatigue (dynamic)
local c1Tracker = StatTracker.newActiveEffectTracker(self)    -- C1: flat Resist Normal Weapons
local c2Tracker = StatTracker.newActiveEffectTracker(self)     -- C2: per-piece Resist Normal Weapons
local dTracker  = StatTracker.newActiveEffectTracker(self)      -- D: Resist trio (D1) OR Shield trio (D2)

-- ============================================================
--  A CHAIN - BURDEN CARRIED
--  Feather = a rank-scaled percentage of TOTAL EQUIPPED HEAVY ARMOR
--  WEIGHT specifically (not carry capacity, unlike Athletics B) -
--  recalculated on the shared equipment-change poll below.
-- ============================================================

local A_FEATHER_PCT = { [1] = 0.10, [2] = 0.20, [3] = 0.30, [4] = 0.40 }

-- Returns the strongest owned A-chain perk so lower ranks naturally upgrade.
local function getARank()
    if hasPerk(ids.A4) then return 4
    elseif hasPerk(ids.A3) then return 3
    elseif hasPerk(ids.A2) then return 2
    elseif hasPerk(ids.A1) then return 1
    else return 0 end
end

-- Converts equipped Heavy Armor weight into a Feather effect.
local function updateAStats()
    local rank = getARank()
    if rank == 0 then
        aTracker.apply("feather", nil, 0)
        return
    end
    local totalWeight = getHeavyArmorInfo()
    aTracker.apply("feather", nil, math.floor(totalWeight * A_FEATHER_PCT[rank]))
end

-- Removes the A-chain Feather contribution without checking current rank.
local function clearAStats()
    aTracker.apply("feather", nil, 0)
end

-- ============================================================
--  B CHAIN - IRON CONSTITUTION
--  B1: passive Fortify Fatigue scaling with pieces worn, gated on 3+
--  pieces. B2: the pool formula is unchanged ("Pool increase remains" -
--  the doc doesn't grow the pool further at B2), and adds a new restore-
--  portion-of-fatigue-spent mechanic on weapon swings and jumps.
-- ============================================================

local B_MIN_PIECES = 3
local B_FATIGUE_PER_PIECE = 5
local B_SWING_RESTORE_PCT = 0.30
local B_JUMP_SAMPLE_DELAY = 0.15 -- seconds after jump input before sampling the fatigue cost

-- Returns whether the Fatigue pool exists and whether B2's refund is active.
local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

-- Rebuilds the Fortify Fatigue pool from the number of Heavy Armor pieces worn.
local function updateBFatiguePool()
    local rank = getBRank()
    if rank == 0 then
        bTracker.apply("dynamic", "fatigue", 0)
        return
    end
    local _, pieceCount = getHeavyArmorInfo()
    if pieceCount < B_MIN_PIECES then
        bTracker.apply("dynamic", "fatigue", 0)
        return
    end
    bTracker.apply("dynamic", "fatigue", pieceCount * B_FATIGUE_PER_PIECE)
end

-- Removes the B-chain Fatigue pool.
local function clearBStats()
    bTracker.apply("dynamic", "fatigue", 0)
end

local wasAttacking = false
local fatigueBeforeSwing = 0
local jumpPending = false
local jumpPendingTimer = 0
local fatigueBeforeJump = 0

-- Clears one-shot swing/jump sampling state when B2 is inactive or removed.
local function clearB2State()
    wasAttacking = false
    fatigueBeforeSwing = 0
    jumpPending = false
    jumpPendingTimer = 0
    fatigueBeforeJump = 0
end

-- Gives back a portion of the Fatigue just spent, capped by the current max.
local function restoreFatiguePortion(spent)
    if spent <= 0 then
        return
    end
    local restoreAmount = spent * B_SWING_RESTORE_PCT
    if restoreAmount <= 0 then
        return
    end
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local maxFatigue = fatigue.base + fatigue.modifier
    fatigue.current = math.min(fatigue.current + restoreAmount, maxFatigue)
end

-- Watches swings and jumps, then refunds part of their observed Fatigue cost.
local function tickB2Restore(dt)
    if getBRank() < 2 then
        if wasAttacking or jumpPending then
            clearB2State()
        end
        return
    end
    local _, pieceCount = getHeavyArmorInfo()
    if pieceCount < B_MIN_PIECES then
        if wasAttacking or jumpPending then
            clearB2State()
        end
        return
    end

    local fatigue = types.Actor.stats.dynamic.fatigue(self)

    -- Weapon swings have a clear start/end edge, so compare before and after.
    local isAttacking = self.controls.use ~= 0
    if isAttacking and not wasAttacking then
        fatigueBeforeSwing = fatigue.current
    elseif not isAttacking and wasAttacking then
        restoreFatiguePortion(fatigueBeforeSwing - fatigue.current)
    end
    wasAttacking = isAttacking

    -- Jumps spend Fatigue shortly after input, so compare after a brief delay.
    if self.controls.jump and not jumpPending then
        jumpPending = true
        jumpPendingTimer = B_JUMP_SAMPLE_DELAY
        fatigueBeforeJump = fatigue.current
    end
    if jumpPending then
        jumpPendingTimer = jumpPendingTimer - dt
        if jumpPendingTimer <= 0 then
            jumpPending = false
            restoreFatiguePortion(fatigueBeforeJump - types.Actor.stats.dynamic.fatigue(self).current)
        end
    end
end

-- ============================================================
--  C CHAIN - TEMPERED FLESH
-- ============================================================

local C1_FLAT_RESIST = 10
local C2_PER_PIECE_PCT = 2
local C2_CAP = 20

-- Returns whether the flat C1 resist or the per-piece C2 bonus is active.
local function getCRank()
    if hasPerk(ids.C2) then return 2
    elseif hasPerk(ids.C1) then return 1
    else return 0 end
end

-- Applies the normal-weapon resistance from C1 and C2 as separate contributions.
local function updateCStats()
    local rank = getCRank()
    c1Tracker.apply("resistnormalweapons", nil, rank >= 1 and C1_FLAT_RESIST or 0)

    if rank >= 2 then
        local _, pieceCount = getHeavyArmorInfo()
        c2Tracker.apply("resistnormalweapons", nil, math.min(C2_CAP, pieceCount * C2_PER_PIECE_PCT))
    else
        c2Tracker.apply("resistnormalweapons", nil, 0)
    end
end

-- Removes the flat C1 resistance contribution.
local function clearC1Stats()
    c1Tracker.apply("resistnormalweapons", nil, 0)
end

-- Removes the per-piece C2 resistance contribution.
local function clearC2Stats()
    c2Tracker.apply("resistnormalweapons", nil, 0)
end

-- ============================================================
--  D CHAIN - ELEMENTAL FORTRESS
-- ============================================================

local D1_RESIST_CAP = 30
local D2_SHIELD_CAP = 45
local AC_DIVISOR = 10

local D_ELEMENTS = { "fire", "frost", "shock" }
local D1_RESIST_EFFECT = { fire = "resistfire",  frost = "resistfrost",  shock = "resistshock" }
local D2_SHIELD_EFFECT = { fire = "fireshield",  frost = "frostshield", shock = "lightningshield" }

-- Returns whether the elemental defence should be Resist or Shield.
local function getDRank()
    if hasPerk(ids.D2) then return 2
    elseif hasPerk(ids.D1) then return 1
    else return 0 end
end

-- Uses the shared weighted armor-rating formula for D-chain scaling.
local function getHeavyArmorRating()
    return CombatMath.getArmorRating(self)
end

-- Applies Resist at D1 or Shield at D2 while the full-set gate is satisfied.
local function updateDStats()
    local rank = getDRank()
    if rank == 0 or not ArmorPoints.isFullHeavySet(self) then
        for _, elem in ipairs(D_ELEMENTS) do
            dTracker.apply(D1_RESIST_EFFECT[elem], nil, 0)
            dTracker.apply(D2_SHIELD_EFFECT[elem], nil, 0)
        end
        return
    end

    local scaled = getHeavyArmorRating() / AC_DIVISOR

    if rank == 1 then
        local value = math.min(D1_RESIST_CAP, scaled)
        for _, elem in ipairs(D_ELEMENTS) do
            dTracker.apply(D1_RESIST_EFFECT[elem], nil, value)
            dTracker.apply(D2_SHIELD_EFFECT[elem], nil, 0)
        end
    else -- rank == 2: D2 fully replaces D1's effect type
        local value = math.min(D2_SHIELD_CAP, scaled)
        for _, elem in ipairs(D_ELEMENTS) do
            dTracker.apply(D1_RESIST_EFFECT[elem], nil, 0)
            dTracker.apply(D2_SHIELD_EFFECT[elem], nil, value)
        end
    end
end

-- Removes whichever elemental package the D-chain last applied.
local function clearDStats()
    for _, elem in ipairs(D_ELEMENTS) do
        dTracker.apply(D1_RESIST_EFFECT[elem], nil, 0)
        dTracker.apply(D2_SHIELD_EFFECT[elem], nil, 0)
    end
end

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local recalcTimer = 0
local RECALC_INTERVAL = 1.0

-- Samples equipment-sensitive effects on a throttle and watches B2 action refunds.
local function onUpdate(dt)
    tickB2Restore(dt)

    recalcTimer = recalcTimer - dt
    if recalcTimer <= 0 then
        recalcTimer = RECALC_INTERVAL
        updateAStats()
        updateBFatiguePool()
        updateCStats()
        updateDStats()
    end
end

-- Persists only applied stat/effect deltas; transient swing/jump state is rebuilt.
local function onSave()
    return {
        aSnapshot = aTracker.snapshot(),
        bSnapshot = bTracker.snapshot(),
        c1Snapshot = c1Tracker.snapshot(),
        c2Snapshot = c2Tracker.snapshot(),
        dSnapshot = dTracker.snapshot(),
    }
end

-- Reverses saved deltas before the framework re-applies currently owned perks.
local function onLoad(data)
    data = data or {}
    aTracker.restoreAndReverse(data.aSnapshot)
    bTracker.restoreAndReverse(data.bSnapshot)
    c1Tracker.restoreAndReverse(data.c1Snapshot)
    c2Tracker.restoreAndReverse(data.c2Snapshot)
    dTracker.restoreAndReverse(data.dSnapshot)
    clearB2State()
end

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Broad Shoulders",
    category = ChainRequirements.category("Combat", "Heavy Armor", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The first lesson of plate is not strength, but surrender: let the weight settle, then make it obey.",
    localizedDescription = "Feather equal to 10% of your total equipped Heavy Armor weight.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Load-Bearing Frame",
    category = ChainRequirements.category("Combat", "Heavy Armor", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Straps bite, hinges grind, and still your stance holds. The armor has learned your shape as much as you have learned its weight.",
    localizedDescription = "Feather increases to 20% of your total equipped Heavy Armor weight.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Battle-Forged Back",
    category = ChainRequirements.category("Combat", "Heavy Armor", 3),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Every march in iron has hammered endurance into your bones; burdens that once dragged at you now find no purchase.",
    localizedDescription = "Feather increases to 30% of your total equipped Heavy Armor weight.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Immovable",
    category = ChainRequirements.category("Combat", "Heavy Armor", 4),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Plate, mail, leather, and flesh move as one siege engine. The battlefield must make room for you.",
    localizedDescription = "Feather increases to 40% of your total equipped Heavy Armor weight.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Iron Constitution",
    category = ChainRequirements.category("Combat", "Heavy Armor", 5),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Long hours under steel have taught your lungs patience and your legs refusal. You do not tire quickly, because you cannot afford to.",
    localizedDescription = "While wearing 3 or more pieces of Heavy Armor, gain Fortify Fatigue "
        .. "scaling with the number of pieces worn.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = updateBFatiguePool,
    onRemove = clearBStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Battle Rhythm",
    category = ChainRequirements.category("Combat", "Heavy Armor", 6),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The rhythm of heavy war is measured, brutal, and exact. Every swing spends strength, and every recovery claims some of it back.",
    localizedDescription = "Effect 1: \n The Fortify Fatigue pool from Iron Constitution is unchanged.\f"
        .. "Effect 2: \n Each weapon swing and jump now recovers a portion of the fatigue it costs.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = updateBFatiguePool,
    -- Losing B2 should also clear any half-finished swing or jump sample.
    onRemove = function()
        clearBStats()
        clearB2State()
    end,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Tempered Flesh",
    category = ChainRequirements.category("Combat", "Heavy Armor", 7),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You have been struck often enough to know the music of a bad angle. Blades skid, hafts jar, and your footing remains.",
    localizedDescription = "Resist Normal Weapons +10%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = updateCStats,
    onRemove = clearC1Stats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Ironclad",
    category = ChainRequirements.category("Combat", "Heavy Armor", 9),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Each plate is a sworn guard standing between you and the killing blow, and you have learned to make them stand together.",
    localizedDescription = "Each worn Heavy Armor piece adds a further ~2% Resist Normal Weapons, "
        .. "capped at an additional 20%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = updateCStats,
    onRemove = clearC2Stats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Elemental Fortress",
    category = ChainRequirements.category("Combat", "Heavy Armor", 8),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Sealed behind a wall of steel, you become a fortress with a heartbeat. Flame gutters, frost dulls, and lightning crawls across the shell.",
    localizedDescription = "While wearing a full Heavy Armor set (Cuirass, Greaves, both Pauldrons, "
        .. "both Gauntlets, and Boots if your race can wear them - Helmet and Shield don't count), "
        .. "gain Fire, Frost, and Shock Resist scaling with your armor rating, capped at 30% each.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = updateDStats,
    onRemove = clearDStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Elemental Bulwark",
    category = ChainRequirements.category("Combat", "Heavy Armor", 10),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The fortress no longer waits for the storm to pass. It catches the fury on its walls and answers in kind.",
    localizedDescription = "Replaces Elemental Fortress: while wearing the full Heavy Armor set, "
        .. "gain Fire, Frost, and Shock Shield instead of Resist, at the same scaling, capped at "
        .. "45 points each.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = updateDStats,
    onRemove = clearDStats,
})

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
