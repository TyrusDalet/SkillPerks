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
local animation  = require("openmw.animation")
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
local wasDrawing = false
local preparedShotPending = false
local preparedShotTimer = 0
local pendingAimStacks = 0
local steadyAimStacks = 0
local releaseDebounce = 0
local pendingRecoveries = {}
local steadyAimBonus = 0
local crossbowBonusActive = false
local crossbowAnimationAccelerated = false
local crossbowLoaded = false
local crossbowReloading = false
local crossbowWasEquipped = false
local lastMarksmanHit = nil

local A_STACK_CAP = { [1] = 2, [2] = 4, [3] = 6, [4] = 8 }
local A_STARTUP = { [1] = 1, [2] = 1, [3] = 0.5, [4] = 0.5 }
local A_INTERVAL = { [1] = 1, [2] = 1, [3] = 0.5, [4] = 0.5 }
local B_CHANCE = { [1] = 0.25, [2] = 0.50 }
local C_DRAW_SPEED = { [1] = 1.25, [2] = 1.50 }
local C_AGILITY = { [1] = 10, [2] = 20 }
local C_SPEED = { [1] = 25, [2] = 50 }
local D_MULT = { [1] = 1.5, [2] = 2.0 }

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

--- Classifies the three physical projectile weapon families used by Marksman.
--- Keeping the distinction explicit makes aiming and release diagnostics useful
--- for bows, loaded crossbows, and held thrown weapons alike.
--- @param weapon GameObject|nil Equipped or reported attack weapon.
--- @return string|nil kind
local function rangedWeaponKind(weapon)
    if not weapon or not types.Weapon.objectIsInstance(weapon) then
        return nil
    end
    local weaponType = types.Weapon.record(weapon).type
    if weaponType == types.Weapon.TYPE.MarksmanBow then
        return "bow"
    elseif weaponType == types.Weapon.TYPE.MarksmanCrossbow then
        return "crossbow"
    elseif weaponType == types.Weapon.TYPE.MarksmanThrown then
        return "thrown"
    end
    return nil
end

local function equippedRanged()
    return rangedWeaponKind(Common.weaponFromAttack(nil, self)) ~= nil
end

--- Returns true when the player's right-hand weapon is a crossbow.
--- @return boolean crossbow
local function equippedCrossbow()
    local weapon = Common.weaponFromAttack(nil, self)
    return weapon ~= nil
        and types.Weapon.objectIsInstance(weapon)
        and types.Weapon.record(weapon).type == types.Weapon.TYPE.MarksmanCrossbow
end

--- Returns true while a crossbow has ammunition available in its equipment
--- slot. OpenMW exposes the equipped bolt rather than a separate loaded flag.
--- @return boolean loaded
local function crossbowHasBolt()
    return types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.Ammunition) ~= nil
end

--- Tracks the mechanical loaded state separately from equipped ammunition.
--- The bolt equipment slot remains populated throughout firing and reloading,
--- so the crossbow animation's release/attach keys provide the useful state.
interfaces.AnimationController.addTextKeyHandler("crossbow", function(_, key)
    if key == "shoot release" then
        crossbowLoaded = false
        crossbowReloading = true
    elseif key == "shoot attach" then
        crossbowLoaded = true
        crossbowReloading = false
    end
end)

--- Keeps Steady Aim's mechanical Marksman modifier, AAM report, and visible
--- Fortify Marksman entry aligned to the same computed draw bonus.
--- @param value number Total Marksman bonus currently earned.
local function setSteadyAimStacks(value)
    local rank = aRank()
    steadyAimStacks = math.max(0, math.min(
        A_STACK_CAP[rank] or 0,
        math.floor(tonumber(value) or 0)
    ))
    steadyAimBonus = steadyAimStacks * 5
    aimStats.apply("skills", SKILL_ID, steadyAimBonus)
    aimEffects.apply("fortifyskill", SKILL_ID, steadyAimBonus)
end

--- Plays one of the thunderstorm weather record's native thunder sounds.
--- Reading the record avoids hard-coding sound IDs that content patches may
--- replace while retaining the requested variation between prepared shots.
--- @return string|nil soundId
local function playRandomThunder()
    local weather = core.weather and core.weather.records
        and core.weather.records["thunderstorm"]
    local sounds = weather and weather.thunderSoundID
    local count = sounds and #sounds or 0
    if count <= 0 then
        return nil
    end
    local soundId = sounds[math.random(count)]
    if soundId then
        ambient.playSound(soundId)
    end
    return soundId
end

--- Clears the one-shot aiming snapshot after the projectile resolves, whether
--- the attack hit or missed. This prevents an earlier release from lending its
--- stacks or Certain Shot state to a later projectile.
local function consumeReleasedAim()
    stationaryTime = 0
    readyShot = false
    preparedShotPending = false
    preparedShotTimer = 0
    pendingAimStacks = 0
    releasedAimGrace = 0
    setSteadyAimStacks(0)
end

--- Captures Steady Aim at the weapon's release key so crossbows and thrown
--- weapons receive the same next-shot state as bows. Polling remains as a
--- fallback for replacement animations that omit the native release key.
local function queueReleasedAim()
    if releaseDebounce > 0 or aRank() == 0 or not equippedRanged() then
        return
    end
    local certainShot = aRank() >= 4 and readyShot
    if steadyAimStacks <= 0 and not certainShot then
        return
    end

    pendingAimStacks = steadyAimStacks
    preparedShotPending = certainShot
    preparedShotTimer = 10
    releaseDebounce = 0.20

    local soundId = nil
    if certainShot then
        soundId = playRandomThunder()
    end
    SkillDebug.traceEvent(SKILL_ID, "aim released", {
        certainShot = certainShot,
        pendingSeconds = preparedShotTimer,
        sound = soundId,
        stacks = pendingAimStacks,
        weaponKind = rangedWeaponKind(Common.weaponFromAttack(nil, self)),
    })
end

for _, groupName in ipairs({ "bowandarrow", "crossbow", "throwweapon" }) do
    interfaces.AnimationController.addTextKeyHandler(groupName, function(_, key)
        if key == "shoot release" then
            queueReleasedAim()
        end
    end)
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
        wasDrawing = false
        setSteadyAimStacks(0)
        return
    end

    if drawing then
        wasDrawing = true
        stationaryTime = stationaryTime + dt
        releasedAimGrace = 0.30
    else
        if wasDrawing then
            queueReleasedAim()
        end
        wasDrawing = false
        readyShot = false
        if releasedAimGrace > 0 then
            releasedAimGrace = math.max(0, releasedAimGrace - dt)
        else
            stationaryTime = 0
            setSteadyAimStacks(0)
        end
        return
    end

    local stackCount = 0
    if stationaryTime >= A_STARTUP[rank] then
        local elapsedAfterStartup = stationaryTime - A_STARTUP[rank]
        stackCount = math.floor(elapsedAfterStartup / A_INTERVAL[rank] + 0.000001) + 1
    end
    setSteadyAimStacks(stackCount)
    local newlyReady = rank >= 4 and stationaryTime >= 3
    if newlyReady and not readyShot then
        SkillDebug.traceEvent(SKILL_ID, "Certain Shot armed", {
            stationarySeconds = stationaryTime,
        })
    end
    readyShot = newlyReady
end

--- Applies the C-chain's permanent crossbow animation acceleration and its
--- loaded-weapon attribute bonuses. Stats use the shared tracker so AAM
--- receives the same reversible values.
local function updateCrossbowTraining()
    local rank = cRank()
    local equipped = equippedCrossbow() and crossbowHasBolt()
    local playing = animation.isPlaying(self, "crossbow")

    if not equipped then
        crossbowLoaded = false
        crossbowReloading = false
    elseif not crossbowWasEquipped then
        -- A newly equipped crossbow begins loaded in normal gameplay.
        crossbowLoaded = true
        crossbowReloading = false
    elseif crossbowReloading and not playing then
        -- Some replacement animations omit "shoot attach". Completing the
        -- reload animation is therefore accepted as the fallback load point.
        crossbowLoaded = true
        crossbowReloading = false
    end
    crossbowWasEquipped = equipped

    -- Attribute bonuses represent bracing a loaded crossbow for a shot rather
    -- than carrying one indefinitely. Reload acceleration remains permanent.
    local active = rank > 0
        and equipped
        and crossbowLoaded
        and Common.controlActive(self, "use")
    if active ~= crossbowBonusActive then
        SkillDebug.traceEvent(SKILL_ID, "crossbow training state", {
            active = active,
            agility = active and C_AGILITY[rank] or 0,
            drawMultiplier = active and C_DRAW_SPEED[rank] or 1,
            speed = active and C_SPEED[rank] or 0,
        })
    end
    crossbowBonusActive = active

    local agility = active and C_AGILITY[rank] or 0
    local speed = active and C_SPEED[rank] or 0
    masteryTracker.apply("attributes", "agility", agility)
    masteryTracker.apply("attributes", "speed", speed)
    masteryEffects.apply("fortifyattribute", "agility", agility)
    masteryEffects.apply("fortifyattribute", "speed", speed)

    if rank > 0 and equipped and playing then
        animation.setSpeed(self, "crossbow", C_DRAW_SPEED[rank])
        crossbowAnimationAccelerated = true
    elseif crossbowAnimationAccelerated then
        if playing then
            animation.setSpeed(self, "crossbow", 1)
        end
        crossbowAnimationAccelerated = false
    end
end

local function queueAmmoRecovery(attack, target)
    local rank = bRank()
    local ammo = attack and attack.ammo
    if rank == 0 or not ammo or not target or not target:isValid() then
        return
    end
    local recordId
    if type(ammo) == "string" then
        recordId = ammo
    else
        local fieldOk, fieldId = pcall(function() return ammo.recordId end)
        if fieldOk then
            recordId = fieldId
        end
        local weaponOk, isWeapon = pcall(types.Weapon.objectIsInstance, ammo)
        if not recordId and weaponOk and isWeapon then
            recordId = types.Weapon.record(ammo).id
        end
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
    local ammoOk, ammoIsWeapon = pcall(types.Weapon.objectIsInstance, ammo)
    if ammoOk and ammoIsWeapon then
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
    local weaponKind = rangedWeaponKind(weapon)
    if not weaponKind then
        return
    end

    local prepared = aRank() >= 4 and (readyShot or preparedShotPending)
    local shotStacks = pendingAimStacks > 0 and pendingAimStacks or steadyAimStacks
    attack.skillPerksSteadyAimStacks = shotStacks
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
        lastMarksmanHit = {
            source = source,
            successful = false,
            prepared = prepared,
            steadyAimStacks = shotStacks,
            weaponKind = weaponKind,
            unaware = Common.isUnawareHit(attack),
            awarenessReason = attack.skillPerksTargetAwarenessReason,
            baseDamage = resolvedDamage,
            result = "miss remained unresolved",
        }
        if prepared or pendingAimStacks > 0 then
            consumeReleasedAim()
        end
        return
    end

    local target = Common.attackTarget(attack)
    queueAmmoRecovery(attack, target)

    local rankD = dRank()
    local unaware = Common.isUnawareHit(attack)
    local sniperBonus = 0
    local sniperAdded = false
    if rankD > 0 and unaware then
        sniperBonus = resolvedDamage * (D_MULT[rankD] - 1)
        sniperAdded = Common.applyBonusHealthDamage(
            attack,
            sniperBonus,
            self,
            ids["D" .. tostring(rankD)],
            "marksman.sniper")
    end
    lastMarksmanHit = {
        source = source,
        successful = successful,
        prepared = prepared,
        steadyAimStacks = shotStacks,
        weaponKind = weaponKind,
        unaware = unaware,
        awarenessReason = attack.skillPerksTargetAwarenessReason,
        baseDamage = resolvedDamage,
        sniperRank = rankD,
        sniperBonus = sniperBonus,
        sniperAdded = sniperAdded,
        resourceResult = nil,
        result = sniperAdded and "Sniper bonus queued" or "no Sniper bonus",
    }
    SkillDebug.traceEvent(SKILL_ID, "ranged hit resolved", lastMarksmanHit)

    if prepared or pendingAimStacks > 0 then
        consumeReleasedAim()
    end
end

--- Records the actor-local resource write produced by Sniper or Certain Shot.
--- `addHitDamage=true` only means the arithmetic pipeline accepted a bonus;
--- this acknowledgement contains the amount actually observed on the target.
--- @param data table Framework resource result payload.
local function onHitResolutionApplied(data)
    data = data or {}
    if not lastMarksmanHit or data.resource ~= "health" then
        return
    end

    local relevant = data.sourceEffect == ids.A4
        or data.sourceEffect == ids.D1
        or data.sourceEffect == ids.D2
    for _, contributor in ipairs(data.contributors or {}) do
        if contributor == ids.A4 or contributor == ids.D1 or contributor == ids.D2 then
            relevant = true
            break
        end
    end
    if not relevant then
        return
    end

    local marksmanContribution = 0
    for _, contribution in ipairs(data.contributionDetails or {}) do
        local sourceEffect = contribution.sourceEffect
        if sourceEffect == ids.A4 or sourceEffect == ids.D1 or sourceEffect == ids.D2 then
            marksmanContribution = marksmanContribution
                + (tonumber(contribution.amount) or 0)
        end
    end
    data.marksmanContribution = marksmanContribution
    data.otherModifiersTotal = (tonumber(data.totalResolved) or 0)
        - (tonumber(data.baseDamage) or 0)
        - marksmanContribution

    lastMarksmanHit.resourceResult = data
    lastMarksmanHit.result = data.success
        and "bonus damage observed on target"
        or "target-local bonus damage failed"
    SkillDebug.traceEvent(SKILL_ID, "bonus damage delivery", {
        base = data.baseDamage,
        error = data.error,
        marksman = marksmanContribution,
        observedTotal = data.totalObserved,
        otherModifiers = data.otherModifiersTotal,
        requestedTotal = data.totalRequested,
        resolvedTotal = data.totalResolved,
        success = data.success,
    })
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
    wasDrawing = false
    preparedShotPending = false
    preparedShotTimer = 0
    pendingAimStacks = 0
    steadyAimStacks = 0
    releaseDebounce = 0
    pendingRecoveries = {}
    steadyAimBonus = 0
    crossbowBonusActive = false
    crossbowLoaded = false
    crossbowReloading = false
    crossbowWasEquipped = false
    if crossbowAnimationAccelerated and animation.isPlaying(self, "crossbow") then
        animation.setSpeed(self, "crossbow", 1)
    end
    crossbowAnimationAccelerated = false
    lastMarksmanHit = nil
end

local function onUpdate(dt)
    releaseDebounce = math.max(0, releaseDebounce - dt)
    if preparedShotTimer > 0 then
        preparedShotTimer = math.max(0, preparedShotTimer - dt)
        if preparedShotTimer == 0 then
            preparedShotPending = false
            pendingAimStacks = 0
        end
    end
    updateSteadyAim(dt)
    updateCrossbowTraining()
    resolveAmmoRecoveries(dt)
end

local function onSave()
    return {
        aimStats = aimStats.snapshot(),
        aimEffects = aimEffects.snapshot(),
        mastery = masteryTracker.snapshot(),
        masteryEffects = masteryEffects.snapshot(),
        stationaryTime = stationaryTime,
        preparedShotPending = preparedShotPending,
        preparedShotTimer = preparedShotTimer,
        pendingAimStacks = pendingAimStacks,
        crossbowLoaded = crossbowLoaded,
        crossbowReloading = crossbowReloading,
        crossbowWasEquipped = crossbowWasEquipped,
    }
end

local function onLoad(data)
    data = data or {}
    aimStats.restoreAndReverse(data.aimStats)
    aimEffects.restoreAndReverse(data.aimEffects or data.aim)
    masteryTracker.restoreAndReverse(data.mastery)
    masteryEffects.restoreAndReverse(data.masteryEffects)
    stationaryTime = data.stationaryTime or 0
    preparedShotPending = data.preparedShotPending == true
    preparedShotTimer = math.max(0, tonumber(data.preparedShotTimer) or 0)
    pendingAimStacks = math.max(0, tonumber(data.pendingAimStacks) or 0)
    pendingRecoveries = {}
    steadyAimBonus = 0
    steadyAimStacks = 0
    releaseDebounce = 0
    readyShot = false
    wasDrawing = false
    crossbowBonusActive = false
    crossbowAnimationAccelerated = false
    crossbowLoaded = data.crossbowLoaded == true
    crossbowReloading = data.crossbowReloading == true
    crossbowWasEquipped = data.crossbowWasEquipped == true
    lastMarksmanHit = nil
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
        local delivery = lastMarksmanHit and lastMarksmanHit.resourceResult
        return {
            string.format(
                "Aim: weapon=%s kind=%s ranged=%s drawing=%s stationary=%s stacks=%d/%d bonus=%d readyShot=%s pendingShot=%s pendingTime=%s releaseGrace=%s",
                SkillDebug.objectId(weapon),
                tostring(rangedWeaponKind(weapon)),
                tostring(Common.isRangedWeapon(weapon)),
                tostring(Common.controlActive(self, "use")),
                SkillDebug.number(stationaryTime),
                steadyAimStacks,
                A_STACK_CAP[aRank()] or 0,
                steadyAimBonus,
                tostring(readyShot),
                tostring(preparedShotPending),
                SkillDebug.number(preparedShotTimer),
                SkillDebug.number(releasedAimGrace)
            ),
            string.format("Released aim snapshot: pendingStacks=%d", pendingAimStacks),
            string.format(
                "Crossbow: equipped=%s bolt=%s loaded=%s reloading=%s bonuses=%s animation=%s speed=%s",
                tostring(equippedCrossbow()),
                tostring(crossbowHasBolt()),
                tostring(crossbowLoaded),
                tostring(crossbowReloading),
                tostring(crossbowBonusActive),
                tostring(animation.isPlaying(self, "crossbow")),
                SkillDebug.number(animation.getSpeed(self, "crossbow"))
            ),
            lastMarksmanHit and string.format(
                "Last hit: source=%s weaponKind=%s success=%s prepared=%s aimStacks=%s unaware=%s awareness=%s baseDamage=%s sniperRank=%s bonus=%s added=%s result=%s",
                tostring(lastMarksmanHit.source),
                tostring(lastMarksmanHit.weaponKind),
                tostring(lastMarksmanHit.successful),
                tostring(lastMarksmanHit.prepared),
                tostring(lastMarksmanHit.steadyAimStacks),
                tostring(lastMarksmanHit.unaware),
                tostring(lastMarksmanHit.awarenessReason),
                SkillDebug.number(lastMarksmanHit.baseDamage),
                tostring(lastMarksmanHit.sniperRank),
                SkillDebug.number(lastMarksmanHit.sniperBonus),
                tostring(lastMarksmanHit.sniperAdded),
                tostring(lastMarksmanHit.result)
            ) or "Last hit: none observed.",
            delivery and string.format(
                "Bonus delivery: total requested=%s resolved=%s observed=%s success=%s error=%s",
                SkillDebug.number(delivery.totalRequested),
                SkillDebug.number(delivery.totalResolved),
                SkillDebug.number(delivery.totalObserved),
                tostring(delivery.success),
                SkillDebug.value(delivery.error)
            ) or "Bonus delivery: no target acknowledgement.",
            delivery and string.format(
                "Damage breakdown: base=%s Marksman=%s other modifiers=%s (calculation=%s resource=%s)",
                SkillDebug.number(delivery.baseDamage),
                SkillDebug.number(delivery.marksmanContribution),
                SkillDebug.number(delivery.otherModifiersTotal),
                SkillDebug.number(delivery.calculationAdjustment),
                SkillDebug.number(delivery.resourceAdjustment)
            ) or "Damage breakdown: unavailable.",
            string.format("Ammunition recoveries pending=%d", #pendingRecoveries),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Marksman", ids, {
    A1 = { localizedName = "Steady Aim", localizedFlavour = "You let the world narrow to breath, string, and distance. The shot waits until your hands become still.", localizedDescription = "While aiming a bow or crossbow, or holding back a thrown weapon, without moving, gain +5 Marksman after 1 second and another +5 every second, up to 2 stacks (+10).", onRemove = clearMarksman },
    A2 = { localizedName = "Held Line", localizedFlavour = "The longer you hold, the less the bow trembles. Even the wind starts to feel negotiable.", localizedDescription = "Steady Aim can build up to 4 stacks (+20 Marksman).", onRemove = clearMarksman },
    A3 = { localizedName = "Dead Calm", localizedFlavour = "Your patience sharpens faster than doubt can reach you.", localizedDescription = "Steady Aim can build up to 6 stacks (+30 Marksman). Its first stack and each subsequent stack now take 0.5 seconds.", onRemove = clearMarksman },
    A4 = { localizedName = "Certain Shot", localizedFlavour = "For one perfect instant, distance stops being protection.", localizedDescription = "Steady Aim can build up to 8 stacks (+40 Marksman). After aiming for 3 seconds without moving, your next shot is guaranteed to hit.", onRemove = clearMarksman },
    B1 = { localizedName = "Efficient Quiver", localizedFlavour = "A clean kill wastes nothing. Even spent arrows find their way back to purpose.", localizedDescription = "Ranged kills have a 25% chance to recover the fired ammunition when the hit table reports it.", onRemove = clearMarksman },
    B2 = { localizedName = "Hunter's Return", localizedFlavour = "You leave fewer shafts in the dead than others lose in the grass.", localizedDescription = "Ammunition recovery chance increases to 50%.", onRemove = clearMarksman },
    C1 = { localizedName = "Crank Discipline", localizedFlavour = "The windlass bites, the stock settles, and practiced hands turn dead weight into sudden violence.", localizedDescription = "Crossbows ready 25% faster. When preparing to fire a loaded crossbow, gain +10 Agility and +25 Speed.", onRemove = clearMarksman },
    C2 = { localizedName = "Snaplock", localizedFlavour = "Your crossbow is loaded before the enemy understands that the first bolt was not the last.", localizedDescription = "Crossbows ready 50% faster. When preparing to fire a loaded crossbow, gain +20 Agility and +50 Speed.", onRemove = clearMarksman },
    D1 = { localizedName = "Sniper", localizedFlavour = "The best shot is not the hardest one. It is the one they never knew existed.", localizedDescription = "Unaware ranged hits deal 150% damage.", onRemove = clearMarksman },
    D2 = { localizedName = "Last Thing Seen", localizedFlavour = "By the time the target hears the string, the lesson is already buried deep.", localizedDescription = "Sniper increases to 200% damage.", onRemove = clearMarksman },
})

return {
    eventHandlers = {
        SPerks_HitResolutionApplied = onHitResolutionApplied,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
