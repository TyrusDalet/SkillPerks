--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

--[[ Hand-to-Hand wins by taking away stamina, weapons, and finally options. ]]

local core       = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "handtohand"
local ids = Common.ids("handtohand")

local defenseTracker = StatTracker.newActiveEffectTracker(self)

local A_DIVISOR = { [1] = 10, [2] = 7, [3] = 5, [4] = 5 }
local B_RESIST_CAP = { [1] = 20, [2] = 30 }
local C_CHANCE = { [1] = 0.10, [2] = 0.20 }
local D_CHANCE = { [1] = 0.10, [2] = 0.25 }
local D_DURATION = { [1] = 1, [2] = 3 }

local appliedDefense = { resist = 0, sanctuary = 0 }
local lastBridgeDebug = nil
local lastHitDebug = nil
local lastDisarmDebug = nil
local lastKnockoutDebug = nil
local knockoutRequestSerial = 0

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

--- Returns whether any currently active effect is already paralysing the actor.
--- Knockout never refreshes or overlaps paralysis, regardless of its source.
--- @param actor GameObject|nil Actor to inspect.
--- @return boolean paralyzed
local function isParalyzed(actor)
    if not actor or not actor:isValid() then
        return false
    end
    local ok, effect = pcall(function()
        return types.Actor.activeEffects(actor):getEffect("paralyze")
    end)
    return ok and effect ~= nil and (tonumber(effect.magnitude) or 0) > 0
end

--- Treats a bridged hit as successful when OpenMW reports either a successful
--- roll or actual resource damage. Some target-local payloads preserve damage
--- while exposing `successful=false`, so the flag alone is not authoritative.
--- @param attack table OpenMW or Core 0 hit payload.
--- @return boolean successful
local function hitWasSuccessful(attack)
    local damage = attack and attack.damage or {}
    return attack and (attack.successful == true
        or (tonumber(damage.health) or 0) > 0
        or (tonumber(damage.fatigue) or 0) > 0)
end

local function isUnarmedPlayerHit(attack)
    return Common.isPlayerAttack(attack, self)
        and hitWasSuccessful(attack)
        and Common.isUnarmed(self)
end

--- Reads a target resource ratio from the Framework's pre-damage snapshot.
--- Older payloads fall back to the actor's live value for compatibility.
--- @param attack table Hit payload.
--- @param target GameObject Target actor.
--- @param resource string Dynamic resource id.
--- @return number ratio
--- @return boolean snapshot True when the preserved pre-hit value was used.
local function preHitRatio(attack, target, resource)
    local resources = attack and attack.perkFrameworkPreHitResources
    local snapshot = resources and resources[resource]
    if snapshot and tonumber(snapshot.ratio) then
        return tonumber(snapshot.ratio), true
    end
    if not target or not target:isValid() then
        return 1, false
    end
    return Common.dynamicRatio(target, resource), false
end

-- Iron Skin is intentionally self-only: it updates every frame and clears on unequip.
local function updateIronSkin()
    local rank = bRank()
    local active = rank > 0 and Common.isUnarmed(self)
    local skill = Common.skill(self, SKILL_ID)
    appliedDefense.resist = active and math.min(B_RESIST_CAP[rank], skill / 5) or 0
    appliedDefense.sanctuary = active and rank >= 2 and math.min(10, skill / 10) or 0
    defenseTracker.apply("resistnormalweapons", nil, appliedDefense.resist)
    defenseTracker.apply("sanctuary", nil, appliedDefense.sanctuary)
end

--- Contributes the A-chain resource damage to the shared hit and reports the
--- exact amounts accepted by the Framework for diagnostics.
--- @param attack table Shared hit payload.
--- @param target GameObject Target actor.
--- @return table result
local function applyIronFists(attack, target)
    local rank = aRank()
    if rank == 0 or not target or not target:isValid() then
        return { fatigue = 0, health = 0, fatigueAdded = false, healthAdded = false }
    end
    local skill = Common.skill(self, SKILL_ID)
    local amount = skill / A_DIVISOR[rank]
    local fatigueAdded = interfaces.ErnPerkFramework.addHitDamage(attack, "fatigue", amount, {
        source = self,
        sourceEffect = ids["A" .. tostring(rank)],
        context = "handtohand.ironFists",
    })
    local fatigueRatio, usedSnapshot = preHitRatio(attack, target, "fatigue")
    local healthAmount = 0
    local healthAdded = false
    if rank >= 4 and fatigueRatio <= 0.25 then
        healthAmount = math.floor(skill / 10)
        healthAdded = interfaces.ErnPerkFramework.addHitDamage(attack, "health", healthAmount, {
            source = self,
            sourceEffect = ids.A4,
            context = "handtohand.lowFatigueHealth",
        })
    end
    return {
        fatigue = amount,
        health = healthAmount,
        fatigueAdded = fatigueAdded,
        healthAdded = healthAdded,
        fatigueRatio = fatigueRatio,
        snapshot = usedSnapshot,
    }
end

--- Rolls Disarming Blow against the target's currently equipped weapon and
--- stores every gate, roll, and condition value for the debug command.
--- @param target GameObject Target actor.
local function damageTargetWeapon(target)
    local rank = cRank()
    lastDisarmDebug = {
        rank = rank,
        target = target and target.id or nil,
        eligible = false,
        reason = rank == 0 and "C chain inactive" or "target unavailable",
    }
    if rank == 0 or not target or not target:isValid() then
        return
    end
    local weapon = types.Actor.getEquipment(target, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not weapon or not weapon:isValid() or not types.Weapon.objectIsInstance(weapon) then
        lastDisarmDebug.reason = "target has no weapon"
        return
    end
    local itemData = types.Item.itemData(weapon)
    local weaponRecord = types.Weapon.record(weapon)
    local condition = itemData and tonumber(itemData.condition) or nil
    local maximum = tonumber(weaponRecord.health) or 0
    local chance = C_CHANCE[rank]
    local lowCondition = condition ~= nil and condition / math.max(maximum, 1) < 0.25
    if rank >= 2 and lowCondition then
            chance = chance * 2
    end
    local roll = math.random()
    local amount = Common.skill(self, SKILL_ID) / 3
    local triggered = roll < chance
    lastDisarmDebug = {
        rank = rank,
        target = target.id,
        eligible = true,
        reason = triggered and "condition damage queued" or "roll failed",
        weapon = weapon,
        weaponId = weaponRecord.id,
        condition = condition,
        maximum = maximum,
        lowCondition = lowCondition,
        chance = chance,
        roll = roll,
        triggered = triggered,
        amount = amount,
    }
    if triggered then
        core.sendGlobalEvent("SPerks_ModifyItemCondition", {
            item = weapon,
            amount = -amount,
        })
    end
end

--- Rolls Knockout Blow using the target's fatigue at the instant before the
--- hit. Its threshold, chance, roll, and queued duration remain inspectable.
--- @param attack table Shared hit payload.
--- @param target GameObject Target actor.
local function tryKnockout(attack, target)
    local rank = dRank()
    local fatigueRatio, usedSnapshot = preHitRatio(attack, target, "fatigue")
    local alreadyParalyzed = isParalyzed(target)
    lastKnockoutDebug = {
        rank = rank,
        target = target and target.id or nil,
        fatigueRatio = fatigueRatio,
        snapshot = usedSnapshot,
        alreadyParalyzed = alreadyParalyzed,
        eligible = false,
        reason = rank == 0 and "D chain inactive" or "target above 15% fatigue",
    }
    if rank == 0 or not target or not target:isValid() or fatigueRatio > 0.15 then
        return
    end
    if alreadyParalyzed then
        lastKnockoutDebug.reason = "target is already paralysed"
        return
    end
    local roll = math.random()
    local chance = D_CHANCE[rank]
    local triggered = roll < chance
    lastKnockoutDebug.chance = chance
    lastKnockoutDebug.roll = roll
    lastKnockoutDebug.eligible = true
    lastKnockoutDebug.triggered = triggered
    lastKnockoutDebug.duration = D_DURATION[rank]
    lastKnockoutDebug.reason = triggered and "Paralyze queued" or "roll failed"
    if not triggered then
        return
    end
    knockoutRequestSerial = knockoutRequestSerial + 1
    local requestId = "SkillPerks_H2H_Knockout_" .. tostring(knockoutRequestSerial)
    lastKnockoutDebug.requestId = requestId
    lastKnockoutDebug.applied = false
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = self,
        preferredSpellId = "SPerks_Native_Paralyze_"..tostring(D_DURATION[rank]).."s",
        spellName = "SkillPerks Knockout",
        effects = { { id = "paralyze", magnitudeMin = 1, duration = D_DURATION[rank] } },
        -- Knockout's perk chance is the first gate, followed by OpenMW's
        -- ordinary Willpower and Resist Paralysis resolution. As a martial
        -- strike, it cannot be absorbed as a spell or reflected at the player.
        activeSpellOptions = {
            ignoreReflect = true,
            ignoreResistances = false,
            ignoreSpellAbsorption = true,
            quiet = true,
        },
        resultTarget = self,
        resultEvent = "SPerks_H2HKnockoutApplied",
        requestId = requestId,
        skipIfEffectActive = "paralyze",
    })
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, function(attack, source)
    if not isUnarmedPlayerHit(attack) then
        return false
    end
    local target = Common.attackTarget(attack)
    local ironFists = applyIronFists(attack, target)
    lastHitDebug.accepted = true
    lastHitDebug.reason = "unarmed hit processed"
    lastHitDebug.target = target
    lastHitDebug.targetId = target and target.id or nil
    lastHitDebug.ironFists = ironFists
    damageTargetWeapon(target)
    tryKnockout(attack, target)
    return true
end)

--- Records every incoming Framework payload before the shared router filters
--- it, making player ownership, success, and equipment failures visible.
--- @param attack table|nil Shared hit payload.
--- @param source string Delivery source.
local function observeAndRouteHit(attack, source)
    attack = attack or {}
    local damage = attack.damage or {}
    lastDisarmDebug = nil
    lastKnockoutDebug = nil
    lastHitDebug = {
        source = source,
        ownershipSource = attack.skillPerksOwnershipSource,
        accepted = false,
        reason = "rejected by outgoing-hit router",
        playerOwned = Common.isPlayerAttack(attack, self),
        successful = attack.successful,
        healthDamage = tonumber(damage.health) or 0,
        fatigueDamage = tonumber(damage.fatigue) or 0,
        unarmed = Common.isUnarmed(self),
    }
    local routed = routeOutgoingHit(attack, source)
    if not routed then
        if not lastHitDebug.playerOwned then
            lastHitDebug.reason = "hit was not attributed to player"
        elseif not hitWasSuccessful(attack) then
            lastHitDebug.reason = "hit carried no successful roll or resource damage"
        elseif not lastHitDebug.unarmed then
            lastHitDebug.reason = "right hand was armed"
        end
    end
    SkillDebug.trace(SKILL_ID, function()
        return string.format(
            "SkillPerks H2H hit handler: source=%s ownership=%s playerOwned=%s "
                .. "success=%s damage(H/F)=%s/%s unarmed=%s accepted=%s reason=%s",
            tostring(lastHitDebug.source),
            tostring(lastHitDebug.ownershipSource),
            tostring(lastHitDebug.playerOwned),
            tostring(lastHitDebug.successful),
            tostring(lastHitDebug.healthDamage),
            tostring(lastHitDebug.fatigueDamage),
            tostring(lastHitDebug.unarmed),
            tostring(lastHitDebug.accepted),
            tostring(lastHitDebug.reason)
        )
    end)
end

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ids.A1 .. "_handtohand_hit",
    priority = 440,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack)
        observeAndRouteHit(attack, attack.skillPerksHitSource or "framework")
    end,
})

local function clearHandToHand()
    defenseTracker.clearAll()
    appliedDefense.resist = 0
    appliedDefense.sanctuary = 0
end

local function onUpdate()
    updateIronSkin()
end

local function onSave()
    return { defense = defenseTracker.snapshot() }
end

local function onLoad(data)
    defenseTracker.restoreAndReverse(data and data.defense)
end

--- Retains target-side bridge failures even when they never reach the
--- Framework's outgoing H2H handler.
--- @param trace table|nil Core 0 bridge trace.
local function onHitBridgeDiagnostic(trace)
    lastBridgeDebug = trace or {}
end

--- Records the target-local resource write produced by Iron Fists.
--- `addHitDamage=true` only confirms arithmetic registration; this event proves
--- that the resolved difference was actually written to the target actor.
local function onHitResolutionApplied(data)
    data = data or {}
    local relevant = false
    for _, contributor in ipairs(data.contributors or {}) do
        for rank = 1, 4 do
            if contributor == ids["A" .. tostring(rank)] then
                relevant = true
                break
            end
        end
        if relevant then break end
    end
    if not relevant then
        for rank = 1, 4 do
            if data.sourceEffect == ids["A" .. tostring(rank)] then
                relevant = true
                break
            end
        end
    end
    if not relevant or lastHitDebug == nil then
        return
    end
    lastHitDebug.resourceResults = lastHitDebug.resourceResults or {}
    lastHitDebug.resourceResults[data.resource] = data
end

--- Replaces the optimistic "queued" status with confirmation from the global
--- dynamic-spell helper after it verifies the active spell on the target.
local function onKnockoutApplied(data)
    data = data or {}
    if lastKnockoutDebug == nil or data.requestId ~= lastKnockoutDebug.requestId then
        return
    end
    lastKnockoutDebug.applied = data.success == true
    lastKnockoutDebug.active = data.active == true
    lastKnockoutDebug.spellId = data.spellId
    lastKnockoutDebug.stage = data.stage
    lastKnockoutDebug.error = data.error
    if data.skipped == true and data.stage == "effect-already-active" then
        lastKnockoutDebug.alreadyParalyzed = true
        lastKnockoutDebug.reason = "target became paralysed before application"
    elseif data.stage == "verify-active" and data.active ~= true then
        lastKnockoutDebug.reason = "Paralyze resisted"
    else
        lastKnockoutDebug.reason = data.success == true
            and "Paralyze applied"
            or ("Paralyze failed at " .. tostring(data.stage))
    end
end

-- Confirms the unarmed equipment gate and exposes both resources affected by hits.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Hand-to-Hand",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luahandtohand debug", "luah2h debug" },
    snapshot = function()
        local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
        local framework = interfaces.ErnPerkFramework
        local bridgeRevision = framework and framework.HIT_BRIDGE_REVISION or nil
        local hit = lastHitDebug
        local iron = hit and hit.ironFists or nil
        local resourceResults = hit and hit.resourceResults or {}
        local fatigueResult = resourceResults and resourceResults.fatigue or nil
        local healthResult = resourceResults and resourceResults.health or nil
        local disarm = lastDisarmDebug
        local knockout = lastKnockoutDebug
        local liveWeaponCondition = nil
        if disarm and disarm.weapon then
            local ok, condition = pcall(function()
                if not disarm.weapon:isValid() then
                    return nil
                end
                local itemData = types.Item.itemData(disarm.weapon)
                return itemData and itemData.condition or nil
            end)
            liveWeaponCondition = ok and condition or nil
        end
        return {
            "Framework hit bridge revision: " .. SkillDebug.value(bridgeRevision),
            lastBridgeDebug and string.format(
                "Bridge: stage=%s revision=%s accepted=%s ownership=%s reason=%s direction=%s attacker(id/record/type/player)=%s/%s/%s/%s target=%s weapon=%s sourceType=%s success=%s damage(H/F)=%s/%s",
                SkillDebug.value(lastBridgeDebug.stage),
                SkillDebug.value(lastBridgeDebug.bridgeRevision or bridgeRevision),
                tostring(lastBridgeDebug.accepted),
                SkillDebug.value(lastBridgeDebug.ownershipSource),
                SkillDebug.value(lastBridgeDebug.reason),
                SkillDebug.value(lastBridgeDebug.frameworkDirection),
                SkillDebug.value(lastBridgeDebug.attackerId),
                SkillDebug.value(lastBridgeDebug.attackerRecordId),
                SkillDebug.value(lastBridgeDebug.attackerType),
                tostring(lastBridgeDebug.attackerIsPlayer),
                SkillDebug.value(lastBridgeDebug.targetRecordId or lastBridgeDebug.targetId),
                SkillDebug.value(lastBridgeDebug.weaponRecordId or lastBridgeDebug.weaponId),
                SkillDebug.value(lastBridgeDebug.sourceType),
                SkillDebug.value(lastBridgeDebug.successful),
                SkillDebug.number(lastBridgeDebug.healthDamage),
                SkillDebug.number(lastBridgeDebug.fatigueDamage)
            ) or "Bridge: no player-owned outgoing hit observed by Core 0.",
            string.format("Equipment: rightHand=%s unarmed=%s", SkillDebug.objectId(weapon), tostring(weapon == nil)),
            string.format(
                "Iron Skin: Resist Normal Weapons=%s Sanctuary=%s",
                SkillDebug.number(appliedDefense.resist),
                SkillDebug.number(appliedDefense.sanctuary)
            ),
            hit and string.format(
                "Last hit: source=%s ownership=%s playerOwned=%s successFlag=%s baseHealth=%s baseFatigue=%s unarmed=%s accepted=%s result=%s",
                SkillDebug.value(hit.source),
                SkillDebug.value(hit.ownershipSource),
                tostring(hit.playerOwned),
                SkillDebug.value(hit.successful),
                SkillDebug.number(hit.healthDamage),
                SkillDebug.number(hit.fatigueDamage),
                tostring(hit.unarmed),
                tostring(hit.accepted),
                hit.reason
            ) or "Last hit: none observed by handler.",
            iron and string.format(
                "Iron Fists: fatigueBonus=%s added=%s healthBonus=%s added=%s targetPreFatigue=%s snapshot=%s",
                SkillDebug.number(iron.fatigue),
                tostring(iron.fatigueAdded),
                SkillDebug.number(iron.health),
                tostring(iron.healthAdded),
                SkillDebug.number(iron.fatigueRatio),
                tostring(iron.snapshot)
            ) or "Iron Fists: no accepted unarmed hit.",
            iron and string.format(
                "Iron Fists delivery: fatigue(requested/resolved/observed)=%s/%s/%s success=%s; health=%s/%s/%s success=%s",
                SkillDebug.number(fatigueResult and fatigueResult.requested),
                SkillDebug.number(fatigueResult and fatigueResult.resolved),
                SkillDebug.number(fatigueResult and fatigueResult.observed),
                tostring(fatigueResult and fatigueResult.success == true),
                SkillDebug.number(healthResult and healthResult.requested),
                SkillDebug.number(healthResult and healthResult.resolved),
                SkillDebug.number(healthResult and healthResult.observed),
                tostring(healthResult and healthResult.success == true)
            ) or "Iron Fists delivery: no target acknowledgement.",
            disarm and string.format(
                "Disarm: eligible=%s weapon=%s condition(before/live/max)=%s/%s/%s chance=%s roll=%s proc=%s damage=%s result=%s",
                tostring(disarm.eligible),
                SkillDebug.value(disarm.weaponId),
                SkillDebug.value(disarm.condition),
                SkillDebug.value(liveWeaponCondition),
                SkillDebug.value(disarm.maximum),
                SkillDebug.value(disarm.chance),
                SkillDebug.value(disarm.roll),
                SkillDebug.value(disarm.triggered),
                SkillDebug.value(disarm.amount),
                disarm.reason
            ) or "Disarm: no accepted unarmed hit.",
            knockout and string.format(
                "Knockout: preFatigue=%s snapshot=%s alreadyParalysed=%s eligible=%s chance=%s roll=%s proc=%s duration=%s applied=%s active=%s stage=%s result=%s error=%s",
                SkillDebug.number(knockout.fatigueRatio),
                tostring(knockout.snapshot),
                tostring(knockout.alreadyParalyzed == true),
                tostring(knockout.eligible),
                SkillDebug.value(knockout.chance),
                SkillDebug.value(knockout.roll),
                SkillDebug.value(knockout.triggered),
                SkillDebug.value(knockout.duration),
                tostring(knockout.applied == true),
                tostring(knockout.active == true),
                SkillDebug.value(knockout.stage),
                knockout.reason,
                SkillDebug.value(knockout.error)
            ) or "Knockout: no accepted unarmed hit.",
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Hand-to-Hand", ids, {
    A1 = { localizedName = "Iron Fists", localizedFlavour = "Your hands stop being empty. Every strike lands with the weight of breath stolen and balance ruined.", localizedDescription = "Unarmed hits deal bonus fatigue damage equal to Hand-to-Hand / 10.", onRemove = clearHandToHand },
    A2 = { localizedName = "Body Breaker", localizedFlavour = "You strike the places armor forgets to guard.", localizedDescription = "Iron Fists improves to Hand-to-Hand / 7 fatigue damage.", onRemove = clearHandToHand },
    A3 = { localizedName = "Breath Thief", localizedFlavour = "Every blow taxes the lungs until standing becomes the enemy's hardest decision.", localizedDescription = "Iron Fists improves to Hand-to-Hand / 5 fatigue damage.", onRemove = clearHandToHand },
    A4 = { localizedName = "Empty-Hand Judgment", localizedFlavour = "When their strength is gone, your hands find the line between mercy and silence.", localizedDescription = "Iron Fists remains at Hand-to-Hand / 5. Targets below 25% fatigue also take Health damage equal to Hand-to-Hand / 10, rounded down.", onRemove = clearHandToHand },
    B1 = { localizedName = "Iron Skin", localizedFlavour = "Unarmed does not mean unguarded. You meet steel with bone, timing, and refusal.", localizedDescription = "While unarmed, gain Resist Normal Weapons equal to Hand-to-Hand / 5, capped at 20%.", onRemove = clearHandToHand },
    B2 = { localizedName = "Bare-Knuckle Ward", localizedFlavour = "You move inside the weapon's reach and make its advantage smaller.", localizedDescription = "Iron Skin's cap rises to 30%. While unarmed, also gain Sanctuary equal to Hand-to-Hand / 10, capped at 10%.", onRemove = clearHandToHand },
    C1 = { localizedName = "Disarming Blow", localizedFlavour = "A wrist, a knuckle, a bad angle. Weapons fail long before their owners understand why.", localizedDescription = "Unarmed hits against armed opponents have a 10% chance to damage their weapon condition by Hand-to-Hand / 3.", onRemove = clearHandToHand },
    C2 = { localizedName = "Breaker Grip", localizedFlavour = "Once a weapon starts to fail, every strike knows exactly where to continue.", localizedDescription = "Disarming Blow chance rises to 20%, doubled against weapons below 25% condition.", onRemove = clearHandToHand },
    D1 = { localizedName = "Knockout Blow", localizedFlavour = "You wait for fatigue to hollow them out, then place one clean answer where their body cannot argue.", localizedDescription = "Unarmed hits against non-paralysed targets below 15% fatigue have a 10% chance to attempt a 1-second paralysis. Natural paralysis resistance applies.", onRemove = clearHandToHand },
    D2 = { localizedName = "Lights Out", localizedFlavour = "The fight ends in a blink, and the floor explains the rest.", localizedDescription = "Knockout Blow chance rises to 25% and duration to 3 seconds.", onRemove = clearHandToHand },
})

return {
    eventHandlers = {
        SPerks_HitBridgeDiagnostic = onHitBridgeDiagnostic,
        SPerks_HitResolutionApplied = onHitResolutionApplied,
        SPerks_H2HKnockoutApplied = onKnockoutApplied,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
