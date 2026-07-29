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
    SPerks_MediumArmor.lua

    Medium Armor rewards timing, recovery, and controlled reaction after impact.
    See SkillPerks_Combat.md's Medium Armor section for the full spec.

    All chains share one cooldown started by incoming hits. While the
    cooldown is down, A/C provide armor-rating bonuses through Shield. While
    it is up, B/D provide recovery and defensive reactions.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local core       = require("openmw.core")

local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local ArmorPoints = require("scripts.SkillPerks.shared.armor_points")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

-- Reads the framework's cached player perk set for quick rank checks.
local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local SKILL_ID = "mediumarmor"

local ids = {
    A1 = ns .. "_mediumarmor_a1",
    A2 = ns .. "_mediumarmor_a2",
    A3 = ns .. "_mediumarmor_a3",
    A4 = ns .. "_mediumarmor_a4",
    B1 = ns .. "_mediumarmor_b1",
    B2 = ns .. "_mediumarmor_b2",
    C1 = ns .. "_mediumarmor_c1",
    C2 = ns .. "_mediumarmor_c2",
    D1 = ns .. "_mediumarmor_d1",
    D2 = ns .. "_mediumarmor_d2",
}

-- ============================================================
--  PER-PIECE ARMOR RATING
-- ============================================================

local AR_LOCATIONS = {
    { slot = types.Actor.EQUIPMENT_SLOT.Cuirass,       weight = 0.3  },
    { slot = types.Actor.EQUIPMENT_SLOT.CarriedLeft,   weight = 0.1  }, -- Shield
    { slot = types.Actor.EQUIPMENT_SLOT.Helmet,        weight = 0.1  },
    { slot = types.Actor.EQUIPMENT_SLOT.Greaves,       weight = 0.1  }, -- Legs
    { slot = types.Actor.EQUIPMENT_SLOT.Boots,         weight = 0.1  }, -- Feet
    { slot = types.Actor.EQUIPMENT_SLOT.RightPauldron, weight = 0.1  },
    { slot = types.Actor.EQUIPMENT_SLOT.LeftPauldron,  weight = 0.1  },
    { slot = types.Actor.EQUIPMENT_SLOT.RightGauntlet, weight = 0.05 },
    { slot = types.Actor.EQUIPMENT_SLOT.LeftGauntlet,  weight = 0.05 },
}

--- Builds the armor-rating contribution of each worn armor piece separately.
--- Medium Armor needs the per-piece split so A and C can apply different
--- percentages to different pieces before the final Shield value is summed.
--- @return table Map of slot -> { item, armorClass, weightedAR }
local function getPerPieceAR()
    local result = {}
    for _, location in ipairs(AR_LOCATIONS) do
        local item = types.Actor.getEquipment(self, location.slot)
        if item and types.Armor.objectIsInstance(item) then
            local record = types.Armor.record(item)
            local armorClass = interfaces.Combat.getArmorSkill(item)
            local skillValue = armorClass and types.NPC.stats.skills[armorClass](self).modified or 0
            local conditionRatio = 1.0
            local itemData = types.Item.itemData(item)
            if itemData and itemData.condition ~= nil and record.health and record.health > 0 then
                conditionRatio = itemData.condition / record.health
            end
            local pieceAR = record.baseArmor * (skillValue / 30) * conditionRatio
            result[location.slot] = {
                item = item,
                armorClass = armorClass,
                weightedAR = pieceAR * location.weight,
            }
        end
    end
    return result
end

-- Returns the strongest owned A-chain perk.
local function getARank()
    if hasPerk(ids.A4) then return 4
    elseif hasPerk(ids.A3) then return 3
    elseif hasPerk(ids.A2) then return 2
    elseif hasPerk(ids.A1) then return 1
    else return 0 end
end

-- Returns whether Sanctuary is active and whether misses shorten cooldown.
local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

-- Returns whether mixed-armor coverage and durability reduction are active.
local function getCRank()
    if hasPerk(ids.C2) then return 2
    elseif hasPerk(ids.C1) then return 1
    else return 0 end
end

-- Returns how many cooldown-window hits can trigger D-chain restoration.
local function getDMaxTriggers()
    if hasPerk(ids.D2) then return 2
    elseif hasPerk(ids.D1) then return 1
    else return 0 end
end

-- Lets the hit handler exit cheaply when the player owns no Medium Armor perks.
local function anyRankOwned()
    return getARank() > 0 or getBRank() > 0 or getCRank() > 0 or getDMaxTriggers() > 0
end

-- ============================================================
--  SHARED COOLDOWN STATE
-- ============================================================

local cooldownRemaining = 0
local dTriggersUsedThisWindow = 0
local pendingDurabilityRefunds = {}

local A_RANK_PCT = { [1] = 0.05, [2] = 0.10, [3] = 0.15, [4] = 0.20 }
local C_RANK_PCT = { [1] = 0.50, [2] = 0.75 }
local B_SANCTUARY = { [1] = 20, [2] = 35 }
local COOLDOWN_CAP = 12
local DURABILITY_REFUND_DELAY = 0.1

-- A4 shortens the recovery window between incoming hits.
local function getBaseCooldown()
    return hasPerk(ids.A4) and 6 or 8
end

-- ============================================================
--  A + C CHAINS - ARMOR RATING BONUS (SHIELD)
-- ============================================================

local arTrackerA = StatTracker.newActiveEffectTracker(self)
local arTrackerC = StatTracker.newActiveEffectTracker(self)

-- Rebuilds the Shield bonus from the current armor mix and cooldown state.
local function updateArmorBonus()
    SkillDebug.traceEvent(SKILL_ID, "armor bonus refresh", {
        aRank = getARank(),
        cRank = getCRank(),
    })
    if cooldownRemaining > 0 then
        arTrackerA.apply("shield", nil, 0)
        arTrackerC.apply("shield", nil, 0)
        return
    end

    local aRank = getARank()
    local cRank = getCRank()
    local isMostlyMedium = ArmorPoints.isMostly(self, "mediumarmor")
    local perPieceAR = getPerPieceAR()

    local aTotal, cTotal = 0, 0
    for _, entry in pairs(perPieceAR) do
        local isMediumUnderA = entry.armorClass == "mediumarmor" and isMostlyMedium and aRank > 0
        if cRank == 0 then
            if isMediumUnderA then
                aTotal = aTotal + entry.weightedAR * A_RANK_PCT[aRank]
            end
        else
            if isMediumUnderA then
                aTotal = aTotal + entry.weightedAR * A_RANK_PCT[aRank]
            else
                cTotal = cTotal + entry.weightedAR * C_RANK_PCT[cRank]
            end
        end
    end

    arTrackerA.apply("shield", nil, math.floor(aTotal))
    arTrackerC.apply("shield", nil, math.floor(cTotal))
end

-- Removes only the A-chain portion of the Shield bonus.
local function clearArmorBonusA()
    arTrackerA.apply("shield", nil, 0)
end

-- Removes only the C-chain portion of the Shield bonus.
local function clearArmorBonusC()
    arTrackerC.apply("shield", nil, 0)
end

-- ============================================================
--  B CHAIN - REACTIVE GUARD (SANCTUARY WHILE ON COOLDOWN)
-- ============================================================

local bTracker = StatTracker.newActiveEffectTracker(self)

--- Applies Sanctuary only while the reactive cooldown is running.
local function refreshSanctuaryIfOnCooldown()
    if cooldownRemaining <= 0 then
        return
    end
    local rank = getBRank()
    bTracker.apply("sanctuary", nil, rank > 0 and B_SANCTUARY[rank] or 0)
end

-- Removes the B-chain Sanctuary contribution.
local function clearSanctuary()
    bTracker.apply("sanctuary", nil, 0)
end

-- ============================================================
--  C CHAIN - DURABILITY REFUND
-- ============================================================

local OVERREPAIR_CLAMP_MIN_LOSS = 1

-- OpenMW can clamp over-repaired armor to base max when condition damage
-- lands. Preserve the over-repair buffer and only count visible damage.
local function sendDurabilityCorrection(item, before, current, maxCond, reductionPct)
    if before > maxCond and current <= maxCond then
        local visibleLoss = math.max(0, maxCond - current)
        local estimatedLoss = math.max(OVERREPAIR_CLAMP_MIN_LOSS, visibleLoss)
        core.sendGlobalEvent("SPerks_ModifyItemCondition", {
            item = item,
            value = before - (estimatedLoss * (1 - reductionPct)),
            maxCondition = before,
        })
        return
    end

    core.sendGlobalEvent("SPerks_ModifyItemCondition", {
        item = item,
        amount = (before - current) * reductionPct,
        maxCondition = before,
    })
end

-- Records an armor piece at the moment of impact so damage can be refunded.
local function queueDurabilityRefund(item)
    if not item or not item:isValid() then
        return
    end
    local itemData = types.Item.itemData(item)
    if not itemData then
        return
    end
    local reductionPct = getCRank() >= 2 and 0.75 or 0.50
    table.insert(pendingDurabilityRefunds, {
        item = item,
        before = itemData.condition,
        delay = DURABILITY_REFUND_DELAY,
        reductionPct = reductionPct,
    })
end

-- Waits for engine condition damage to land, then restores the reduced portion.
local function tickDurabilityRefunds(dt)
    for i = #pendingDurabilityRefunds, 1, -1 do
        local entry = pendingDurabilityRefunds[i]
        entry.delay = entry.delay - dt
        if entry.delay <= 0 then
            if entry.item:isValid() and entry.before ~= nil then
                local itemData = types.Item.itemData(entry.item)
                local record = types.Armor.record(entry.item)
                local current = itemData.condition or entry.before
                local maxCond = record.health or record.maxCondition
                local lost = entry.before - current
                if lost > 0 and maxCond then
                    sendDurabilityCorrection(entry.item, entry.before, current, maxCond, entry.reductionPct)
                end
            end
            table.remove(pendingDurabilityRefunds, i)
        end
    end
end

-- Restores a tenth of maximum Health and Fatigue for D-chain hit reactions.
local function restoreHealthAndFatigueD()
    local health = types.Actor.stats.dynamic.health(self)
    local maxHealth = health.base + health.modifier
    health.current = math.min(health.current + maxHealth * 0.10, maxHealth)

    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local maxFatigue = fatigue.base + fatigue.modifier
    fatigue.current = math.min(fatigue.current + maxFatigue * 0.10, maxFatigue)
end

-- Handles every successful incoming hit that starts or extends the cooldown.
local function handleHitReceived(attack)
    SkillDebug.traceEvent(SKILL_ID, "incoming hit received", {
        damage = attack and attack.damage and attack.damage.health,
        successful = attack and attack.successful,
    })
    local wasOnCooldown = cooldownRemaining > 0

    if not wasOnCooldown then
        cooldownRemaining = getBaseCooldown()
    else
        local extension = hasPerk(ids.D2) and 1 or 2
        cooldownRemaining = math.min(cooldownRemaining + extension, COOLDOWN_CAP)
    end

    if not wasOnCooldown then
        refreshSanctuaryIfOnCooldown()
    end
    updateArmorBonus()

    if not wasOnCooldown and getCRank() >= 1 and attack.armor then
        queueDurabilityRefund(attack.armor)
    end

    local maxTriggers = getDMaxTriggers()
    if maxTriggers > 0 and dTriggersUsedThisWindow < maxTriggers then
        dTriggersUsedThisWindow = dTriggersUsedThisWindow + 1
        restoreHealthAndFatigueD()
    end
end

-- Medium Armor is purely defensive. The framework hit callback fires for
-- player attacks too, so reject outgoing swings before cooldown, refund, or
-- D-chain recovery logic can treat them as hits received.
local function isIncomingAttackAgainstPlayer(attack)
    if not attack.attacker or not attack.attacker:isValid() then
        return false
    end
    if attack.attacker == self then
        return false
    end
    if attack.target and attack.target ~= self then
        return false
    end
    return true
end

-- Registers Medium Armor's reactive effects with the framework hit pipeline.
interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_mediumarmor_on_hit",
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
    handler = function(attack)
        if not anyRankOwned() then
            return
        end
        if not isIncomingAttackAgainstPlayer(attack) then
            return
        end

        if attack.successful == false then
            if getBRank() >= 2 and cooldownRemaining > 0 then
                cooldownRemaining = math.max(2, cooldownRemaining - 1)
            end
            return
        end

        handleHitReceived(attack)
    end,
})

-- Ticks down the shared cooldown and restores the no-cooldown armor bonus.
local function tickCooldown(dt)
    if cooldownRemaining <= 0 then
        return
    end
    cooldownRemaining = math.max(0, cooldownRemaining - dt)
    if cooldownRemaining <= 0 then
        dTriggersUsedThisWindow = 0
        clearSanctuary()
        updateArmorBonus()
    end
end

local recalcTimer = 0
local RECALC_INTERVAL = 1.0

-- Updates cooldown, delayed durability refunds, and equipment-sensitive bonuses.
local function onUpdate(dt)
    tickCooldown(dt)
    tickDurabilityRefunds(dt)

    recalcTimer = recalcTimer - dt
    if recalcTimer <= 0 then
        recalcTimer = RECALC_INTERVAL
        if cooldownRemaining <= 0 then
            updateArmorBonus()
        end
    end
end

-- Persists only active stat/effect deltas; live cooldown state is rebuilt.
local function onSave()
    return {
        arASnapshot = arTrackerA.snapshot(),
        arCSnapshot = arTrackerC.snapshot(),
        bSnapshot = bTracker.snapshot(),
    }
end

-- Reverses saved deltas before the framework re-applies currently owned perks.
local function onLoad(data)
    data = data or {}
    arTrackerA.restoreAndReverse(data.arASnapshot)
    arTrackerC.restoreAndReverse(data.arCSnapshot)
    bTracker.restoreAndReverse(data.bSnapshot)
    cooldownRemaining = 0
    dTriggersUsedThisWindow = 0
    pendingDurabilityRefunds = {}
end

-- Shows armor coverage plus the hit-response cooldown and durability queue.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Medium Armor",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luamediumarmor debug", "luama debug" },
    snapshot = function()
        local totalAR = 0
        local pieces = 0
        for _, entry in pairs(getPerPieceAR()) do
            totalAR = totalAR + (entry.weightedAR or 0)
            pieces = pieces + 1
        end
        return {
            string.format(
                "Equipped set: pieces=%s weightedAR=%s",
                SkillDebug.value(pieces),
                SkillDebug.number(totalAR)
            ),
            string.format(
                "Hit response: cooldown=%s/%s triggers=%d/%d durabilityRefunds=%d",
                SkillDebug.number(cooldownRemaining),
                SkillDebug.number(getBaseCooldown()),
                dTriggersUsedThisWindow,
                getDMaxTriggers(),
                #pendingDurabilityRefunds
            ),
        }
    end,
})

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Tempered Guard",
    category = ChainRequirements.category("Combat", "Medium Armor", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You have learned the art of the middle weight: enough steel to trust, enough freedom to answer the next blow.",
    localizedDescription = "While wearing mostly Medium Armor, your Medium Armor pieces "
        .. "contribute an extra 5% to their own armor rating. Disabled for 8 seconds after "
        .. "any hit is received.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = updateArmorBonus,
    onRemove = clearArmorBonusA,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Honed Reflexes",
    category = ChainRequirements.category("Combat", "Medium Armor", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The armor no longer argues with your footwork. It turns with your hips, rises with your guard, and settles before the strike lands.",
    localizedDescription = "The armor rating bonus increases to 10%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = updateArmorBonus,
    onRemove = clearArmorBonusA,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Practiced Deflection",
    category = ChainRequirements.category("Combat", "Medium Armor", 3),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You wear every plate at a purpose-made angle, inviting blows to slide away instead of meeting them square.",
    localizedDescription = "The armor rating bonus increases to 15%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = updateArmorBonus,
    onRemove = clearArmorBonusA,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Master's Guard",
    category = ChainRequirements.category("Combat", "Medium Armor", 4),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A blade may find an opening, but only for a heartbeat. By the time it arrives, your guard has already moved on.",
    localizedDescription = "The armor rating bonus increases to 20%. The post-hit cooldown "
        .. "is reduced from 8 seconds to 6.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = updateArmorBonus,
    onRemove = clearArmorBonusA,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Reactive Guard",
    category = ChainRequirements.category("Combat", "Medium Armor", 5),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The moment after impact is where panic lives. You have trained there until it became a place of calm.",
    localizedDescription = "While your armor rating bonus is on cooldown from a recent hit, "
        .. "gain Sanctuary +20.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = refreshSanctuaryIfOnCooldown,
    onRemove = clearSanctuary,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Read the Opening",
    category = ChainRequirements.category("Combat", "Medium Armor", 6),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A missed swing is a confession. You read the overreach, relax the guard, and step back into tempo.",
    localizedDescription = "Sanctuary increases to +35. Each attack that misses you while on "
        .. "cooldown shortens the remaining cooldown by 1 second, to a minimum of 2.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = refreshSanctuaryIfOnCooldown,
    onRemove = clearSanctuary,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Efficient Absorption",
    category = ChainRequirements.category("Combat", "Medium Armor", 7),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Mismatched plates, borrowed mail, and old leather all become part of the same answer when you know how to receive the blow.",
    localizedDescription = "Effect 1: \n The armor rating bonus now extends to ALL worn armor "
        .. "pieces at 50% effectiveness, and is active regardless of your armor composition "
        .. "(no longer requires wearing mostly Medium Armor).\f"
        .. "Effect 2: \n The hit that triggers your cooldown deals 50% reduced durability "
        .. "damage to the piece it struck.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = updateArmorBonus,
    onRemove = clearArmorBonusC,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Total Coverage",
    category = ChainRequirements.category("Combat", "Medium Armor", 9),
    art = "textures\\levelup\\knight",
    localizedFlavour = "No strap is wasted, no plate is ornamental. Every piece has a job, and every job is done under pressure.",
    localizedDescription = "Effectiveness increases to 75%, and the durability reduction on "
        .. "your triggering hit increases to 75%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = updateArmorBonus,
    onRemove = clearArmorBonusC,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Second Skin",
    category = ChainRequirements.category("Combat", "Medium Armor", 8),
    art = "textures\\levelup\\knight",
    localizedFlavour = "When the hit lands, your armor teaches your body how to survive the shock and spend it forward.",
    localizedDescription = "The first hit you receive during your cooldown restores 10% of "
        .. "your maximum health and fatigue, once per cooldown window.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    -- D-chain restoration is handled live by the hit handler.
    onAdd = function() end,
    onRemove = function() end,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Living Armor",
    category = ChainRequirements.category("Combat", "Medium Armor", 10),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The second strike finds you braced. The third finds you moving. What should have broken your rhythm only feeds it.",
    localizedDescription = "The restoration can now trigger twice within the same cooldown "
        .. "window. Hits received while on cooldown now extend it by only 1 second instead of 2.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    -- D-chain restoration is handled live by the hit handler.
    onAdd = function() end,
    onRemove = function() end,
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
