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
    SPerks_Athletics.lua

    Athletics - "Endurance, movement economy, and fatigue management."
    See SkillPerks_Combat.md's Athletics section for the full design spec.

    NAMING NOTE: the design doc only gives slot-level mechanical
    descriptions (A1, B2, etc.), not individual perk display names, unlike
    FactionPerks where every perk was hand-named ("Redoran Pledge", etc.).
    Names below (First Wind, Second Breath, Iron Lungs, Boundless Stamina,
    Road-Hardened, Seasoned Traveller, Swift Traveller, Fleet of Foot,
    Momentum, Second Wind) are invented here and not locked anywhere else -
    flag if you want different ones.

    LOCALIZATION NOTE: uses plain literal strings for
    localizedName/localizedFlavour/localizedDescription rather than
    core.l10n(ns) + l10n/SkillPerks/en.yaml keys, unlike every FactionPerks
    perk file. Deliberate call for iteration speed across 27 skills x 10
    perks x 3 text fields - converting to full l10n later is a mechanical,
    template-able pass once the text itself is settled, rather than
    something worth doing 27 times by hand up front. Flag if you'd rather
    do it properly per-file from the start instead.
]]

local ns          = require("scripts.SkillPerks.namespace")
local interfaces  = require("openmw.interfaces")
local types       = require("openmw.types")
local self        = require("openmw.self")
local ui          = require("openmw.ui")

local StatTracker       = require("scripts.SkillPerks.shared.stat_tracker")
local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local log                = require("scripts.SkillPerks.shared.log")

local SKILL_ID = "athletics"

local ids = {
    A1 = ns .. "_athletics_a1",
    A2 = ns .. "_athletics_a2",
    A3 = ns .. "_athletics_a3",
    A4 = ns .. "_athletics_a4",
    B1 = ns .. "_athletics_b1",
    B2 = ns .. "_athletics_b2",
    C1 = ns .. "_athletics_c1",
    C2 = ns .. "_athletics_c2",
    D1 = ns .. "_athletics_d1",
    D2 = ns .. "_athletics_d2",
}

-- Same lightweight "does the player currently hold this perk" check
-- FactionPerks' player.lua uses internally, rather than constructing a
-- full requirement object just to test membership.
local function hasPerk(id)
    for _, foundID in ipairs(interfaces.ErnPerkFramework.getPlayerPerks()) do
        if foundID == id then
            return true
        end
    end
    return false
end

local function isMoving()
    return self.controls.movement ~= 0 or self.controls.sideMovement ~= 0
end

-- ============================================================
--  TRACKERS
--  One independent tracker per chain. Independent instances are
--  intentional, not an oversight - see shared/stat_tracker.lua's own
--  doc comment: activeEffects:modify() is additive at the engine level,
--  so multiple trackers can safely target the same underlying effect id
--  (e.g. both C and D chains contribute to "fortifyattribute:speed")
--  without stepping on each other's bookkeeping.
-- ============================================================

local aTracker = StatTracker.newStatModTracker(self)      -- A: Fortify Fatigue (dynamic stat)
local bTracker = StatTracker.newActiveEffectTracker(self)  -- B: Feather
local cTracker = StatTracker.newActiveEffectTracker(self)   -- C: Fortify Speed + Swift Swim
local dTracker = StatTracker.newActiveEffectTracker(self)    -- D: Fortify Speed stacks + Fortify Agility

-- ============================================================
--  A CHAIN - TIRELESS
--  Fortify Fatigue (flat, stat.modifier) + movement-gated fatigue regen.
-- ============================================================

local A_RANK_DATA = {
    [1] = { fortifyFatigue = 5,  regenMode = "flat",    flatRate = 0.5 },
    [2] = { fortifyFatigue = 10, regenMode = "flat",    flatRate = 1.0 },
    [3] = { fortifyFatigue = 15, regenMode = "scaling", baseRate = 1.0, maxRate = 3.0 },
    [4] = { fortifyFatigue = 25, regenMode = "scaling", baseRate = 1.0, maxRate = 5.0 },
}

local function getARank()
    if hasPerk(ids.A4) then return 4
    elseif hasPerk(ids.A3) then return 3
    elseif hasPerk(ids.A2) then return 2
    elseif hasPerk(ids.A1) then return 1
    else return 0 end
end

local function updateAStats()
    local rank = getARank()
    aTracker.apply("dynamic", "fatigue", rank > 0 and A_RANK_DATA[rank].fortifyFatigue or 0)
end

-- IMPORTANT - why onRemove is a separate, unconditional function rather
-- than just reusing updateAStats():
--
-- ErnPerkFramework's syncPerks() (player.lua) calls onRemove() for every
-- perk being dropped BEFORE it calls _setPlayerPerks() with the finalized
-- list - meaning getPlayerPerks() (and therefore getARank()) is STALE
-- and still reports the perk-being-removed as held at the moment onRemove
-- fires. AFTER _setPlayerPerks() runs, syncPerks() unconditionally
-- re-fires onAdd() for every perk that's STILL held. So the safe pattern,
-- confirmed against player.lua's syncPerks() (and mirrored by
-- FactionPerks' own setRank(nil)-then-setRank(N) sequencing) is:
--   onRemove = unconditional clear (never queries the perk list)
--   onAdd    = full recompute from the current, by-then-finalized list
-- If some perk in this chain survives the removal, its onAdd fires right
-- after in the same sync pass and correctly restores the lower rank's
-- value. If nothing survives, the clear is all that's needed. The same
-- pattern is applied to B/C/D chains below - see clearBStats,
-- clearCStats, clearDStats.
local function clearAStats()
    aTracker.apply("dynamic", "fatigue", 0)
end

-- Fractional-point accumulator so per-frame regen doesn't get lost to
-- flooring every tick - see the design doc's own recovery formula, which
-- is expressed as a continuous points/second rate, not a per-tick amount.
local fatigueRegenAccumulator = 0

local function tickFatigueRegen(dt)
    local rank = getARank()
    if rank == 0 or not isMoving() then
        return
    end

    local rankData = A_RANK_DATA[rank]
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local maxFatigue = fatigue.base + fatigue.modifier
    if maxFatigue <= 0 or fatigue.current >= maxFatigue then
        return
    end

    local rate
    if rankData.regenMode == "flat" then
        rate = rankData.flatRate
    else
        local missingPct = 1 - (fatigue.current / maxFatigue)
        rate = rankData.baseRate + (rankData.maxRate - rankData.baseRate) * missingPct
    end

    fatigueRegenAccumulator = fatigueRegenAccumulator + rate * dt
    if fatigueRegenAccumulator >= 1 then
        local wholePoints = math.floor(fatigueRegenAccumulator)
        fatigueRegenAccumulator = fatigueRegenAccumulator - wholePoints
        fatigue.current = math.min(fatigue.current + wholePoints, maxFatigue)
    end
end

-- ============================================================
--  B CHAIN - ROAD-HARDENED
--  Feather scaled off encumbrance above a rank-dependent threshold
--  percentage of carry capacity. Recalculated on a throttled timer in
--  onUpdate (see the shared recalcTimer below) - encumbrance only
--  changes on pickup/drop, so this doesn't need per-frame precision.
-- ============================================================

local B_RANK_DATA = {
    [1] = { thresholdPct = 0.50, overflowPct = 0.25 },
    [2] = { thresholdPct = 0.25, overflowPct = 0.33 },
}

local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

local function updateBStats()
    local rank = getBRank()
    if rank == 0 then
        bTracker.apply("feather", nil, 0)
        return
    end

    local rankData = B_RANK_DATA[rank]
    local encumbrance = types.Actor.getEncumbrance(self)
    local capacity = types.Actor.getCapacity(self)
    if capacity <= 0 then
        bTracker.apply("feather", nil, 0)
        return
    end

    local thresholdWeight = capacity * rankData.thresholdPct
    local excess = math.max(0, encumbrance - thresholdWeight)
    local featherAmount = math.floor(excess * rankData.overflowPct)
    bTracker.apply("feather", nil, featherAmount)
end

-- Unconditional clear for onRemove - see the A chain comment above for
-- why this can't just call updateBStats() (getBRank() is stale mid-removal).
local function clearBStats()
    bTracker.apply("feather", nil, 0)
end

-- ============================================================
--  C CHAIN - SWIFT TRAVELLER
--  Fortify Speed = base Speed * free-carry percentage. C2 adds Swift
--  Swim at the same value, capped at 50. Deliberately reads Speed's
--  `.base` rather than `.modified` - using modified would let this
--  perk's own granted bonus feed back into its next recalculation.
-- ============================================================

local function getCRank()
    if hasPerk(ids.C2) then return 2
    elseif hasPerk(ids.C1) then return 1
    else return 0 end
end

local function updateCStats()
    local rank = getCRank()
    if rank == 0 then
        cTracker.apply("fortifyattribute", "speed", 0)
        cTracker.apply("swiftswim", nil, 0)
        return
    end

    local encumbrance = types.Actor.getEncumbrance(self)
    local capacity = types.Actor.getCapacity(self)
    local freePct = capacity > 0 and math.max(0, 1 - (encumbrance / capacity)) or 0
    local baseSpeed = types.Actor.stats.attributes.speed(self).base
    local speedBonus = math.floor(freePct * baseSpeed)

    cTracker.apply("fortifyattribute", "speed", speedBonus)

    if rank >= 2 then
        cTracker.apply("swiftswim", nil, math.min(50, speedBonus))
    else
        cTracker.apply("swiftswim", nil, 0)
    end
end

-- Unconditional clear for onRemove - see the A chain comment above for
-- why this can't just call updateCStats() (getCRank() is stale mid-removal).
local function clearCStats()
    cTracker.apply("fortifyattribute", "speed", 0)
    cTracker.apply("swiftswim", nil, 0)
end

-- ============================================================
--  D CHAIN - MOMENTUM AND SECOND WIND
--  Momentum: +10 Fortify Speed per stack after 3s continuous movement,
--  max 3 stacks (5 at D2). All current stacks fall off together after 3s
--  of continuous stopping (see interpretation note below).
--  D2: at max stacks, also +25 Fortify Agility. Second Wind: once per
--  rest, dropping below 20% fatigue triggers a full restore.
--
--  INTERPRETATION NOTE (flagging an ambiguity in the source doc, not
--  silently resolving it): "Each falls off individually after 3s of
--  stopping" could mean per-stack staggered decay. Implemented here as
--  ALL stacks falling off together 3s after movement stops, since every
--  currently-held stack was gained during the same continuous-movement
--  window and would therefore all start "stopping" at the same instant -
--  the two readings are behaviourally identical for how stacks are
--  actually gained (only while moving), so this is the simpler
--  implementation of the same outcome, not a different one. Flag if you
--  intended genuinely staggered per-stack timers instead.
-- ============================================================

local D_STACK_BONUS = 10
local D2_MAX_STACK_AGILITY_BONUS = 25
local STACK_BUILD_TIME = 3.0
local STACK_FALLOFF_TIME = 3.0

local dStackCount = 0
local dContinuousMoveTimer = 0
local dStoppedTimer = 0

local function getDRank()
    if hasPerk(ids.D2) then return 2
    elseif hasPerk(ids.D1) then return 1
    else return 0 end
end

local function dStackCap(rank)
    return rank >= 2 and 5 or 3
end

local function updateDEffects()
    local rank = getDRank()
    if rank == 0 or dStackCount == 0 then
        dTracker.apply("fortifyattribute", "speed", 0)
        dTracker.apply("fortifyattribute", "agility", 0)
        return
    end

    dTracker.apply("fortifyattribute", "speed", dStackCount * D_STACK_BONUS)

    if rank >= 2 and dStackCount >= dStackCap(rank) then
        dTracker.apply("fortifyattribute", "agility", D2_MAX_STACK_AGILITY_BONUS)
    else
        dTracker.apply("fortifyattribute", "agility", 0)
    end
end

-- Called from D1/D2's onADD only. getDRank() reflects the finalized perk
-- list here (safe - see the A chain comment above), so this can clamp an
-- over-cap stack count down correctly (e.g. respec-ing from D2's 5-stack
-- cap back to D1's 3-stack cap while keeping D1) without disturbing
-- momentum that's still validly held.
local function onDChainAdded()
    local rank = getDRank()
    local cap = dStackCap(rank)
    if dStackCount > cap then
        dStackCount = cap
    end
    updateDEffects()
end

-- Called from D1/D2's onREMOVE only. Unconditional hard reset - does NOT
-- query getDRank() (stale mid-removal, see the A chain comment above).
-- Accepted simplification: losing D2 while keeping D1 (or any respec
-- touching this chain) resets momentum to 0 rather than trying to
-- preserve a partial stack count across the transition. If D1 is still
-- held, its onAdd fires right after this in the same sync pass and will
-- correctly re-enable the mechanic from a clean zero.
local function clearDStats()
    dStackCount = 0
    dContinuousMoveTimer = 0
    dStoppedTimer = 0
    -- dStackCount is already 0 here, so updateDEffects()'s internal
    -- getDRank() call is harmless even though it's also reading a stale
    -- list - the "dStackCount == 0" branch short-circuits before rank is
    -- ever used for anything.
    updateDEffects()
end

local function tickDChain(dt)
    local rank = getDRank()
    if rank == 0 then
        return
    end

    if isMoving() then
        dStoppedTimer = 0
        dContinuousMoveTimer = dContinuousMoveTimer + dt
        if dContinuousMoveTimer >= STACK_BUILD_TIME then
            dContinuousMoveTimer = dContinuousMoveTimer - STACK_BUILD_TIME
            local cap = dStackCap(rank)
            if dStackCount < cap then
                dStackCount = dStackCount + 1
                updateDEffects()
                log("athletics_d_stack", function()
                    return "SkillPerks Athletics D: gained momentum stack (" .. dStackCount .. "/" .. cap .. ")"
                end)
            end
        end
    else
        dContinuousMoveTimer = 0
        if dStackCount > 0 then
            dStoppedTimer = dStoppedTimer + dt
            if dStoppedTimer >= STACK_FALLOFF_TIME then
                dStoppedTimer = 0
                dStackCount = 0
                updateDEffects()
                log("athletics_d_stack", "SkillPerks Athletics D: momentum lost.")
            end
        end
    end
end

-- Second Wind (D2 only). "Once per rest" mirrors the same
-- UiModeChanged/oldMode=='Rest' reset pattern already used by FactionPerks'
-- FPerks_IL3_Prowess-style once-per-day powers and several Stealth doc
-- perks (Speechcraft D, Security D).
local secondWindUsed = false

local function tickSecondWind()
    if not hasPerk(ids.D2) or secondWindUsed then
        return
    end
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local maxFatigue = fatigue.base + fatigue.modifier
    if maxFatigue <= 0 then
        return
    end
    if (fatigue.current / maxFatigue) < 0.20 then
        fatigue.current = maxFatigue
        secondWindUsed = true
        ui.showMessage("Second Wind!")
        log(nil, "SkillPerks Athletics D2: Second Wind triggered.")
    end
end

local function onUiModeChanged(data)
    if data.oldMode == 'Rest' then
        secondWindUsed = false
    end
end

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local recalcTimer = 0
local RECALC_INTERVAL = 1.0

local function onUpdate(dt)
    tickFatigueRegen(dt)
    tickDChain(dt)

    recalcTimer = recalcTimer - dt
    if recalcTimer <= 0 then
        recalcTimer = RECALC_INTERVAL
        updateBStats()
        updateCStats()
        tickSecondWind()
    end
end

local function onSave()
    return {
        aSnapshot = aTracker.snapshot(),
        bSnapshot = bTracker.snapshot(),
        cSnapshot = cTracker.snapshot(),
        dSnapshot = dTracker.snapshot(),
        dStackCount = dStackCount,
        secondWindUsed = secondWindUsed,
    }
end

local function onLoad(data)
    data = data or {}
    aTracker.restoreAndReverse(data.aSnapshot)
    bTracker.restoreAndReverse(data.bSnapshot)
    cTracker.restoreAndReverse(data.cSnapshot)
    dTracker.restoreAndReverse(data.dSnapshot)

    -- Momentum stacks deliberately do NOT persist across a reload - this
    -- is a moment-to-moment mechanic, not a banked resource (same
    -- reasoning FactionPerks' EEC Factor's Promise already uses: "lasts
    -- 30s and cannot survive a load"). Requiring the player to rebuild it
    -- by moving after a load is correct, not a bug.
    dStackCount = 0
    dContinuousMoveTimer = 0
    dStoppedTimer = 0

    secondWindUsed = data.secondWindUsed or false
end

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "First Wind",
    category = ChainRequirements.category("Combat", "Athletics", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Every soldier learns to pace themselves, or they don't last a season.",
    localizedDescription = "Fortify Fatigue +5. While moving, slowly regenerate fatigue "
        .. "(1pt every 2 seconds).",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Second Breath",
    category = ChainRequirements.category("Combat", "Athletics", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your wind no longer runs out halfway up the hill.",
    localizedDescription = "Fortify Fatigue +10. Fatigue regeneration while moving "
        .. "improves to 1pt per second.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Iron Lungs",
    category = ChainRequirements.category("Combat", "Athletics", 3),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The harder you're pushed, the harder your body works to keep up.",
    localizedDescription = "Fortify Fatigue +15. Fatigue regeneration while moving now scales "
        .. "with how depleted you are - 1pt/s at high fatigue, rising to 3pts/s when critically low.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Boundless Stamina",
    category = ChainRequirements.category("Combat", "Athletics", 4),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You have long since stopped counting the miles.",
    localizedDescription = "Fortify Fatigue +25. Fatigue regeneration while moving now scales "
        .. "up to 5pts/s at critically low fatigue.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = updateAStats,
    onRemove = clearAStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Road-Hardened",
    category = ChainRequirements.category("Combat", "Athletics", 5),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A pack that would break a lesser back is just another day's march to you.",
    localizedDescription = "Carrying more than half your capacity feels lighter than it should - "
        .. "25% of the weight above that threshold is offset by Feather.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = updateBStats,
    onRemove = clearBStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Seasoned Traveller",
    category = ChainRequirements.category("Combat", "Athletics", 6),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You've long since learned exactly how much a body can carry, and how "
        .. "to carry more of it anyway.",
    localizedDescription = "The Feather threshold drops to a quarter of your capacity, and the "
        .. "offset improves to 33% of everything carried beyond it.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = updateBStats,
    onRemove = clearBStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Swift Traveller",
    category = ChainRequirements.category("Combat", "Athletics", 7),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Travel light, travel fast - the two have always gone together.",
    localizedDescription = "Fortify Speed, scaling with how much of your carry capacity is "
        .. "currently free. Travel unburdened and you'll notice the difference immediately.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = updateCStats,
    onRemove = clearCStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Fleet of Foot",
    category = ChainRequirements.category("Combat", "Athletics", 9),
    art = "textures\\levelup\\knight",
    localizedFlavour = "On land or in the water, an unburdened body is a fast one.",
    localizedDescription = "As Swift Traveller, and the same scaling bonus now also applies to "
        .. "your swimming speed, capped at 50 points.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = updateCStats,
    onRemove = clearCStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Momentum",
    category = ChainRequirements.category("Combat", "Athletics", 8),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A body in motion tends to stay that way.",
    localizedDescription = "Sustaining continuous movement for 3 seconds builds a stack of "
        .. "Fortify Speed +10, up to 3 stacks. Stacks are lost together after 3 seconds "
        .. "of standing still.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = onDChainAdded,
    onRemove = clearDStats,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Second Wind",
    category = ChainRequirements.category("Combat", "Athletics", 10),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Even at the very end of your strength, there is always one more step in you.",
    localizedDescription = "Effect 1: \n Momentum's stack cap rises to 5. At maximum stacks, "
        .. "also gain Fortify Agility +25.\f"
        .. "Effect 2: \n Second Wind: once per rest, the moment your fatigue drops below 20% "
        .. "it is instantly restored to full.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = onDChainAdded,
    onRemove = clearDStats,
})

return {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
