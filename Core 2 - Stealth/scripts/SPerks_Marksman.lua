--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

--[[
    SPerks_Marksman.lua

    Marksman rewards preparation. The reliable implementation uses
    stationary/equipment polling for visible skill bonuses and routes ranged
    precision damage through Core 0's target-local resource pipeline.
]]

local core       = require("openmw.core")
local ambient    = require("openmw.ambient")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local Common     = require("scripts.SkillPerks.stealth.common")
local CombatMath = require("scripts.SkillPerks.shared.combat_math")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "marksman"
local ids = Common.ids("marksman")

local aimStats = StatTracker.newStatModTracker(self, "Marksman Steady Aim")
local aimEffects = StatTracker.newActiveEffectTracker(self)
local masteryTracker = StatTracker.newStatModTracker(self, "Marksman Ranged Mastery")
local masteryEffects = StatTracker.newActiveEffectTracker(self)

local lastPos = self.position
local stationaryTime = 0
local readyShot = false
local releasedAimGrace = 0
local pendingRecoveries = {}
local steadyAimBonus = 0

local A_CAP = { [1] = 10, [2] = 20, [3] = 30, [4] = 40 }
local A_DELAY = { [1] = 1, [2] = 1, [3] = 0.5, [4] = 0.5 }
local B_CHANCE = { [1] = 0.25, [2] = 0.50 }
local C_MARKSMAN = { [1] = 10, [2] = 20 }
local D_MULT = { [1] = 1.5, [2] = 2.0 }

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function equippedRanged()
    return Common.isRangedWeapon(Common.weaponFromAttack(nil, self))
end

--- Keeps Steady Aim's mechanical Marksman modifier, AAM report, and visible
--- Fortify Marksman entry aligned to the same computed draw bonus.
--- @param value number Total Marksman bonus currently earned.
local function setSteadyAimBonus(value)
    steadyAimBonus = math.max(0, value or 0)
    aimStats.apply("skills", SKILL_ID, steadyAimBonus)
    aimEffects.apply("fortifyskill", SKILL_ID, steadyAimBonus)
end

-- Builds the Steady Aim bonus from time spent stationary with a ranged weapon ready.
local function updateSteadyAim(dt)
    local moved = (self.position - lastPos):length() > 3
    lastPos = self.position
    local rank = aRank()
    local drawing = Common.controlActive(self, "use")
    if rank == 0 or moved or not equippedRanged() then
        stationaryTime = 0
        readyShot = false
        releasedAimGrace = 0
        setSteadyAimBonus(0)
        return
    end

    if drawing then
        stationaryTime = stationaryTime + dt
        releasedAimGrace = 0.30
    elseif releasedAimGrace > 0 then
        releasedAimGrace = math.max(0, releasedAimGrace - dt)
    else
        stationaryTime = 0
        readyShot = false
        setSteadyAimBonus(0)
        return
    end
    local effectiveTime = math.max(0, stationaryTime - A_DELAY[rank])
    local value = math.min(A_CAP[rank], math.floor(effectiveTime) * 5)
    setSteadyAimBonus(value)
    local newlyReady = rank >= 4 and stationaryTime >= 3
    if newlyReady and not readyShot then
        ambient.playSound("critical attack")
    end
    readyShot = newlyReady
end

-- Applies Ranged Mastery while a bow or crossbow is equipped.
local function updateRangedMastery()
    local rank = cRank()
    local active = rank > 0 and Common.isBowOrCrossbow(Common.weaponFromAttack(nil, self))
    masteryTracker.apply("skills", SKILL_ID, active and C_MARKSMAN[rank] or 0)
    masteryEffects.apply("fortifyskill", SKILL_ID, active and C_MARKSMAN[rank] or 0)
    masteryTracker.apply("attributes", "agility", active and rank >= 2 and 5 or 0)
    masteryEffects.apply("fortifyattribute", "agility", active and rank >= 2 and 5 or 0)
end

local function queueAmmoRecovery(attack, target)
    local rank = bRank()
    local ammo = attack and attack.ammo
    if rank == 0 or not ammo or not target or not target:isValid() then
        return
    end
    local recordId = ammo.recordId
    if not recordId and types.Weapon.objectIsInstance(ammo) then
        recordId = types.Weapon.record(ammo).id
    end
    if not recordId then
        return
    end
    table.insert(pendingRecoveries, {
        target = target,
        recordId = recordId,
        chance = B_CHANCE[rank],
        timer = 0.15,
    })
end

-- A target-side miss has no engine-applied damage to promote after the roll.
-- Reconstruct a conservative post-armour ranged hit so Certain Shot remains a
-- real guarantee when only the target bridge sees the attack.
local function estimatePreparedDamage(attack, weapon, target)
    if not weapon or not types.Weapon.objectIsInstance(weapon) or not target then
        return 0
    end
    local record = types.Weapon.record(weapon)
    local charge = tonumber(attack and attack.strength) or 1
    if charge > 1 then
        charge = charge / 100
    end
    charge = math.max(0, math.min(1, charge))
    local damage = record.chopMinDamage
        + (record.chopMaxDamage - record.chopMinDamage) * charge
    local ammo = attack and attack.ammo
    if ammo and types.Weapon.objectIsInstance(ammo) then
        local ammoRecord = types.Weapon.record(ammo)
        damage = damage + ammoRecord.chopMinDamage
            + (ammoRecord.chopMaxDamage - ammoRecord.chopMinDamage) * charge
    end
    local critical = Common.isUnawareHit(attack) and CombatMath.CRIT_MODIFIER.RANGED
        or CombatMath.CRIT_MODIFIER.NONE
    local ok, armorRating = pcall(CombatMath.getArmorRating, target)
    return CombatMath.applyDamageFormula(
        damage,
        CombatMath.getStrengthModifier(self),
        CombatMath.getConditionModifier(weapon),
        critical,
        ok and armorRating or 0
    )
end

local function resolveAmmoRecoveries(dt)
    for i = #pendingRecoveries, 1, -1 do
        local entry = pendingRecoveries[i]
        entry.timer = entry.timer - dt
        if entry.timer <= 0 then
            local target = entry.target
            if target and target:isValid() and Common.dynamicRatio(target, "health") <= 0 and math.random() < entry.chance then
                core.sendGlobalEvent("SPerks_DuplicateItem", {
                    target = self,
                    recordId = entry.recordId,
                    count = 1,
                })
            end
            table.remove(pendingRecoveries, i)
        end
    end
end

--- Resolves prepared shots, ammo recovery, and Sniper through the shared
--- Framework hit path. A prepared miss is reproduced as direct post-armour
--- damage when the target-side bridge cannot mutate the original attack.
local function handleOutgoingHit(attack, source)
    SkillDebug.traceEvent(SKILL_ID, "outgoing hit received", {
        charge = attack and attack.strength,
        source = source,
        successful = attack and attack.successful,
        weapon = attack and SkillDebug.objectId(attack.weapon),
    })
    local weapon = Common.weaponFromAttack(attack, self)
    if not Common.isRangedWeapon(weapon) then
        return
    end

    local prepared = readyShot and aRank() >= 4
    local successful = attack.successful == true
    local resolvedDamage = Common.healthDamage(attack)
    if prepared and not successful then
        if source == "direct" then
            attack.successful = true
            successful = true
        else
            resolvedDamage = math.max(resolvedDamage,
                estimatePreparedDamage(attack, weapon, Common.attackTarget(attack)))
            successful = Common.applyBonusHealthDamage(
                attack,
                resolvedDamage,
                self,
                ids.A4,
                "marksman.certainShot")
        end
    end
    if not successful then
        return
    end

    local target = Common.attackTarget(attack)
    queueAmmoRecovery(attack, target)

    local rankD = dRank()
    if rankD > 0 and Common.isUnawareHit(attack) then
        Common.applyBonusHealthDamage(
            attack,
            resolvedDamage * (D_MULT[rankD] - 1),
            self,
            ids["D" .. tostring(rankD)],
            "marksman.sniper")
    end

    if prepared then
        stationaryTime = 0
        readyShot = false
        releasedAimGrace = 0
        setSteadyAimBonus(0)
    end
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, handleOutgoingHit)

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ids.A1 .. "_marksman_hit",
    priority = 410,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack)
        routeOutgoingHit(attack, attack.skillPerksHitSource or "framework")
    end,
})

local function clearMarksman()
    aimStats.clearAll()
    aimEffects.clearAll()
    masteryTracker.clearAll()
    masteryEffects.clearAll()
    stationaryTime = 0
    readyShot = false
    releasedAimGrace = 0
    pendingRecoveries = {}
    steadyAimBonus = 0
end

local function onUpdate(dt)
    updateSteadyAim(dt)
    updateRangedMastery()
    resolveAmmoRecoveries(dt)
end

local function onSave()
    return {
        aimStats = aimStats.snapshot(),
        aimEffects = aimEffects.snapshot(),
        mastery = masteryTracker.snapshot(),
        masteryEffects = masteryEffects.snapshot(),
        stationaryTime = stationaryTime,
    }
end

local function onLoad(data)
    data = data or {}
    aimStats.restoreAndReverse(data.aimStats)
    aimEffects.restoreAndReverse(data.aimEffects or data.aim)
    masteryTracker.restoreAndReverse(data.mastery)
    masteryEffects.restoreAndReverse(data.masteryEffects)
    stationaryTime = data.stationaryTime or 0
    pendingRecoveries = {}
    steadyAimBonus = 0
end

-- Shows whether steady aim is building and whether Certain Shot is armed.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Marksman",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luamarksman debug", "luamark debug" },
    snapshot = function()
        local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
        return {
            string.format(
                "Aim: weapon=%s ranged=%s stationary=%s bonus=%d readyShot=%s releaseGrace=%s",
                SkillDebug.objectId(weapon),
                tostring(Common.isRangedWeapon(weapon)),
                SkillDebug.number(stationaryTime),
                steadyAimBonus,
                tostring(readyShot),
                SkillDebug.number(releasedAimGrace)
            ),
            string.format("Ammunition recoveries pending=%d", #pendingRecoveries),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Marksman", ids, {
    A1 = { localizedName = "Steady Aim", localizedFlavour = "You let the world narrow to breath, string, and distance. The shot waits until your hands become still.", localizedDescription = "Standing still with a ranged weapon builds +5 Marksman per second after 1 second, up to +10.", onRemove = clearMarksman },
    A2 = { localizedName = "Held Line", localizedFlavour = "The longer you hold, the less the bow trembles. Even the wind starts to feel negotiable.", localizedDescription = "Steady Aim can build up to +20 Marksman.", onRemove = clearMarksman },
    A3 = { localizedName = "Dead Calm", localizedFlavour = "Your patience sharpens faster than doubt can reach you.", localizedDescription = "Steady Aim can build up to +30 Marksman and starts building after 0.5 seconds.", onRemove = clearMarksman },
    A4 = { localizedName = "Certain Shot", localizedFlavour = "For one perfect instant, distance stops being protection.", localizedDescription = "Steady Aim can build up to +40 Marksman. After drawing for 3 seconds without moving, your next shot is guaranteed to hit.", onRemove = clearMarksman },
    B1 = { localizedName = "Efficient Quiver", localizedFlavour = "A clean kill wastes nothing. Even spent arrows find their way back to purpose.", localizedDescription = "Ranged kills have a 25% chance to recover the fired ammunition when the hit table reports it.", onRemove = clearMarksman },
    B2 = { localizedName = "Hunter's Return", localizedFlavour = "You leave fewer shafts in the dead than others lose in the grass.", localizedDescription = "Ammunition recovery chance increases to 50%.", onRemove = clearMarksman },
    C1 = { localizedName = "Ranged Mastery", localizedFlavour = "Bow and body settle into one practiced line.", localizedDescription = "While a bow or crossbow is equipped, gain +10 Marksman.", onRemove = clearMarksman },
    C2 = { localizedName = "Unbroken Sight", localizedFlavour = "Your stance is steady enough that the shot begins before the arrow leaves.", localizedDescription = "Ranged Mastery increases to +20 Marksman and also grants +5 Agility.", onRemove = clearMarksman },
    D1 = { localizedName = "Sniper", localizedFlavour = "The best shot is not the hardest one. It is the one they never knew existed.", localizedDescription = "Unaware ranged hits deal 150% damage.", onRemove = clearMarksman },
    D2 = { localizedName = "Last Thing Seen", localizedFlavour = "By the time the target hears the string, the lesson is already buried deep.", localizedDescription = "Sniper increases to 200% damage.", onRemove = clearMarksman },
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
