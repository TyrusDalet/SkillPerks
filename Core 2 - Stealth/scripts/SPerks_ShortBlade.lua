--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

--[[ Short Blade turns repeated contact into tempo, pressure, and blood. ]]

local core       = require("openmw.core")
local ambient    = require("openmw.ambient")
local interfaces = require("openmw.interfaces")
local self       = require("openmw.self")
local types      = require("openmw.types")
local ui         = require("openmw.ui")

local Common      = require("scripts.SkillPerks.stealth.common")
local CombatMath  = require("scripts.SkillPerks.shared.combat_math")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")

local SKILL_ID = "shortblade"
local ids = Common.ids("shortblade")

local tempoStats = StatTracker.newStatModTracker(self, "Short Blade Blade Tempo")
local tempoEffects = StatTracker.newActiveEffectTracker(self)
local tempoStacks = 0
local tempoTimer = 0
local openedTargets = {}
local vitalTargets = {}
local vitalTargetKey = nil
local bleeds = {}
local pendingShadowHits = {}
local lastHitDebug = nil
local lastFollowUpDebug = nil
local lastBleedDebug = nil
local paralyzeRequestSerial = 0

local A_SPEED = { [1] = 3, [2] = 5, [3] = 5, [4] = 5 }
local A_CAP = { [1] = 3, [2] = 3, [3] = 5, [4] = 8 }
local B_DIVISOR = { [1] = 5, [2] = 3 }
local C_CAP = { [1] = 5, [2] = 8 }
local C_DURATION = { [1] = 5, [2] = 8 }
local C_DAMAGE_RATE = { [1] = 0.04, [2] = 0.05 }
local D_CAP = { [1] = 3, [2] = 5 }
local D_PARALYZE_CHANCE = 0.10
local D_PARALYZE_DURATION = 1
local SHADOW_HIT_DELAY = 0.1
local SHADOW_HIT_VOLUME = 0.25
local LATE_STEALTH_DAMAGE_PRIORITY = 100000

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

--- Accepts the normal OpenMW success flag and the target bridge's resolved
--- positive-damage fallback. Some target-local callbacks omit `successful`
--- even though the weapon hit has already dealt health damage.
local function hitWasSuccessful(attack)
    return attack.successful == true or Common.healthDamage(attack) > 0
end

local function isShortBladeAttack(attack)
    return Common.isPlayerAttack(attack, self)
        and hitWasSuccessful(attack)
        and Common.isShortBlade(Common.weaponFromAttack(attack, self))
end

-- Keeps the visible Speed/Agility bonuses aligned to Blade Tempo stacks.
local function updateTempo()
    local rank = aRank()
    if rank > 0 then
        tempoStacks = math.min(tempoStacks, A_CAP[rank])
    end
    local speed = rank > 0 and tempoStacks * A_SPEED[rank] or 0
    local agility = rank >= 4 and tempoStacks >= A_CAP[rank] and 10 or 0
    tempoStats.apply("attributes", "speed", speed)
    tempoEffects.apply("fortifyattribute", "speed", speed)
    tempoStats.apply("attributes", "agility", agility)
    tempoEffects.apply("fortifyattribute", "agility", agility)
end

local function addTempo()
    local rank = aRank()
    if rank == 0 then
        return
    end
    tempoStacks = math.min(A_CAP[rank], tempoStacks + 1)
    tempoTimer = 4
    updateTempo()
end

local function isParalyzed(target)
    if not target or not target:isValid() then
        return false
    end
    local ok, effect = pcall(function()
        return types.Actor.activeEffects(target):getEffect("paralyze")
    end)
    return ok and effect ~= nil and (tonumber(effect.magnitude) or 0) > 0
end

local function targetMaximumHealth(target)
    if not target or not target:isValid() then
        return 0
    end
    local ok, health = pcall(types.Actor.stats.dynamic.health, target)
    if not ok or not health then
        return 0
    end
    return math.max(0, (tonumber(health.base) or 0) + (tonumber(health.modifier) or 0))
end

-- Bleed stores its per-stack damage when the triggering hit lands. Each
-- stack deals one percent of the target's current maximum Health, with a
-- floor of one damage per stack. D2 independently rolls its paralysis gate
-- on every hit which reaches or maintains five stacks.
local function addBleed(target)
    local rank = dRank()
    local key = Common.targetKey(target)
    if rank == 0 or not key then
        return nil
    end
    local entry = bleeds[key] or { target = target, stacks = 0, tick = 1, timer = 0 }
    entry.target = target
    local oldStacks = entry.stacks
    entry.stacks = math.min(D_CAP[rank], entry.stacks + 1)
    entry.damagePerStack = math.max(1, targetMaximumHealth(target) * 0.01)
    entry.timer = 5
    entry.tick = 1
    bleeds[key] = entry

    local eligible = rank >= 2 and entry.stacks >= D_CAP[rank]
    local alreadyParalyzed = eligible and isParalyzed(target) or false
    local roll = eligible and not alreadyParalyzed and math.random() or nil
    local triggered = roll ~= nil and roll < D_PARALYZE_CHANCE
    lastBleedDebug = {
        target = SkillDebug.objectId(target),
        rank = rank,
        stacksBefore = oldStacks,
        stacksAfter = entry.stacks,
        cap = D_CAP[rank],
        maximumHealth = targetMaximumHealth(target),
        damagePerStack = entry.damagePerStack,
        damagePerTick = entry.damagePerStack * entry.stacks,
        timer = entry.timer,
        paralysisEligible = eligible,
        alreadyParalyzed = alreadyParalyzed,
        paralysisChance = eligible and D_PARALYZE_CHANCE or nil,
        paralysisRoll = roll,
        paralysisTriggered = triggered,
        paralysisResult = not eligible and "below five stacks"
            or alreadyParalyzed and "target already paralysed"
            or not triggered and "roll failed"
            or "Paralyze queued",
    }

    if triggered then
        paralyzeRequestSerial = paralyzeRequestSerial + 1
        local requestId = "SkillPerks_ShortBlade_Paralyze_"
            .. tostring(paralyzeRequestSerial)
        lastBleedDebug.requestId = requestId
        core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
            target = target,
            caster = self,
            preferredSpellId = "SPerks_Native_Paralyze_1s",
            spellName = "SkillPerks Bleeding Stagger",
            effects = {
                { id = "paralyze", magnitudeMin = 1, duration = D_PARALYZE_DURATION },
            },
            activeSpellOptions = {
                ignoreReflect = true,
                ignoreResistances = false,
                ignoreSpellAbsorption = true,
                quiet = true,
            },
            resultTarget = self,
            resultEvent = "SPerks_ShortBladeParalyzeApplied",
            requestId = requestId,
            skipIfEffectActive = "paralyze",
        })
    end
    SkillDebug.traceEvent(SKILL_ID, "Bleed stack applied", lastBleedDebug)
    return lastBleedDebug
end

local function updateBleeds(dt)
    for key, entry in pairs(bleeds) do
        entry.timer = entry.timer - dt
        entry.tick = entry.tick - dt
        if not entry.target or not entry.target:isValid() then
            bleeds[key] = nil
        else
            while entry.tick <= 0 do
                entry.tick = entry.tick + 1
                local damage = (entry.damagePerStack or 1) * entry.stacks
                entry.target:sendEvent("SPerks_TakeDamage", {
                    amount = damage,
                    source = self,
                    sourceEffect = ids.D1,
                    context = "shortblade.bleed",
                })
                SkillDebug.traceEvent(SKILL_ID, "Bleed tick queued", {
                    target = SkillDebug.objectId(entry.target),
                    stacks = entry.stacks,
                    damagePerStack = entry.damagePerStack,
                    damage = damage,
                    remaining = math.max(0, entry.timer),
                })
            end
            if entry.timer <= 0 then
                bleeds[key] = nil
            end
        end
    end
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, function(attack, source)
    local weapon = Common.weaponFromAttack(attack, self)
    local weaponRecord = weapon and types.Weapon.record(weapon) or nil
    lastHitDebug = {
        source = source,
        sourceType = attack.sourceType,
        successful = attack.successful,
        healthDamage = Common.healthDamage(attack),
        weaponId = weaponRecord and weaponRecord.id or nil,
        weaponType = weaponRecord and weaponRecord.type or nil,
        shortBlade = Common.isShortBlade(weapon),
        playerOwned = attack.skillPerksPlayerOwned == true,
        aRank = aRank(),
        stacksBefore = tempoStacks,
    }
    if not isShortBladeAttack(attack) then
        lastHitDebug.result = "rejected by Short Blade hit check"
        return false
    end
    local target = Common.attackTarget(attack)
    local key = Common.targetKey(target)
    local vitalBonus = 0

    local openingRank = bRank()
    if openingRank > 0 and key and not openedTargets[key] then
        openedTargets[key] = true
        local opening = Common.skill(self, SKILL_ID) / B_DIVISOR[openingRank]
        local unaware = Common.isUnawareHit(attack)
        attack.skillPerksShortBladeOpeningDamage = opening
        attack.skillPerksShortBladeOpeningMultiplier = openingRank >= 2 and unaware and 2 or 1
        attack.skillPerksShortBladeOpeningCriticalMultiplier = unaware
            and CombatMath.CRIT_MODIFIER.MELEE or CombatMath.CRIT_MODIFIER.NONE
        attack.skillPerksShortBladeOpeningDebug = lastHitDebug
        lastHitDebug.openingRank = openingRank
        lastHitDebug.openingDamage = opening
        lastHitDebug.openingMultiplier = attack.skillPerksShortBladeOpeningMultiplier
        lastHitDebug.openingCriticalMultiplier = attack.skillPerksShortBladeOpeningCriticalMultiplier
    end

    local vitalRank = cRank()
    if vitalTargetKey and vitalTargetKey ~= key then
        vitalTargets = {}
    end
    vitalTargetKey = key
    local vital = key and vitalTargets[key]
    if vitalRank > 0 and vital then
        vitalBonus = Common.healthDamage(attack)
            * vital.stacks * C_DAMAGE_RATE[vitalRank]
        Common.applyBonusHealthDamage(
            attack,
            vitalBonus,
            self,
            ids["C" .. tostring(vitalRank)],
            "shortblade.vitalStrike")
    end

    addTempo()
    lastHitDebug.stacksAfter = tempoStacks
    lastHitDebug.result = "Tempo applied"
    if vitalRank > 0 and key then
        vital = vital or { stacks = 0, timer = 0 }
        local vitalBefore = vital.stacks
        vital.stacks = math.min(C_CAP[vitalRank], vital.stacks + 1)
        vital.timer = C_DURATION[vitalRank]
        vitalTargets[key] = vital
        lastHitDebug.vitalRank = vitalRank
        lastHitDebug.vitalStacksBefore = vitalBefore
        lastHitDebug.vitalStacksAfter = vital.stacks
        lastHitDebug.vitalCap = C_CAP[vitalRank]
        lastHitDebug.vitalRate = C_DAMAGE_RATE[vitalRank]
        lastHitDebug.vitalBonus = vitalBonus
        attack.skillPerksShortBladeFollowUpReady = vitalRank >= 2
            and vital.stacks >= C_CAP[vitalRank]
            and attack.skillPerksShortBladeFollowUp ~= true
    end
    lastHitDebug.bleed = addBleed(target)
    return true
end)

-- Resolves the two Stealth-special damage stages after every ordinary hit
-- operation. OpenMW has already included its critical multiplier in the bridged
-- base hit, so multiplication commutes for Opportunist. Opening Strike is a
-- separate flat contribution and is explicitly scaled by the melee critical
-- multiplier to produce the same result as adding it before the engine crit.
interfaces.ErnPerkFramework.registerCalculationHandler({
    id = "SkillPerks_stealth_late_damage",
    calculation = interfaces.ErnPerkFramework.CALCULATION.HIT_DAMAGE_HEALTH,
    operation = interfaces.ErnPerkFramework.CALCULATION_OPERATION.Modifier,
    priority = LATE_STEALTH_DAMAGE_PRIORITY,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(data)
        local attack = data.context
        if type(attack) ~= "table" then
            return nil
        end
        local opportunistMultiplier = tonumber(attack.skillPerksSneakOpportunistMultiplier) or 1
        local openingDamage = tonumber(attack.skillPerksShortBladeOpeningDamage) or 0
        if opportunistMultiplier == 1 and openingDamage <= 0 then
            return nil
        end

        local regularDamage = math.max(0, tonumber(data.value) or 0)
        local openingMultiplier = tonumber(attack.skillPerksShortBladeOpeningMultiplier) or 1
        local criticalMultiplier = tonumber(attack.skillPerksShortBladeOpeningCriticalMultiplier) or 1
        local regularAfterOpportunist = regularDamage * opportunistMultiplier
        local openingAfterOpportunist = openingDamage * opportunistMultiplier
        local openingAfterFirstBlood = openingAfterOpportunist * openingMultiplier
        local openingAfterCritical = openingAfterFirstBlood * criticalMultiplier
        local finalDamage = regularAfterOpportunist + openingAfterCritical

        local resolution = {
            afterRegularDamage = regularDamage,
            openingDamage = openingDamage,
            opportunistMultiplier = opportunistMultiplier,
            openingAfterOpportunist = openingAfterOpportunist,
            openingMultiplier = openingMultiplier,
            openingAfterFirstBlood = openingAfterFirstBlood,
            criticalMultiplier = criticalMultiplier,
            openingAfterCritical = openingAfterCritical,
            finalDamage = finalDamage,
        }
        attack.skillPerksLateStealthDamage = resolution

        local shortBladeDebug = attack.skillPerksShortBladeOpeningDebug
        if shortBladeDebug then
            for key, value in pairs(resolution) do
                shortBladeDebug[key] = value
            end
            shortBladeDebug.lateDamageResult = "Opening -> Opportunist -> First Blood -> critical"
            SkillDebug.traceEvent(SKILL_ID, "late Stealth damage resolved", shortBladeDebug)
        end
        local sneakDebug = attack.skillPerksSneakOpportunistDebug
        if sneakDebug then
            sneakDebug.afterRegularDamage = regularDamage
            sneakDebug.openingDamage = openingDamage
            sneakDebug.openingAfterCritical = openingAfterCritical
            sneakDebug.finalDamage = finalDamage
            sneakDebug.result = "late multiplier resolved before conceptual critical stage"
            SkillDebug.traceEvent("sneak", "Opportunist damage resolved", sneakDebug)
        end
        return finalDamage
    end,
})

-- OpenMW normally chooses one of these impact sounds from the struck armour
-- location. The hit payload does not consistently expose that location, so a
-- supplied engine sound id is preferred and the target's cuirass class is the
-- stable fallback used by the project's other automatic weapon attacks.
local function triggeringHitSound(attack, target)
    for _, key in ipairs({ "hitSound", "sound", "impactSound" }) do
        if type(attack[key]) == "string" and attack[key] ~= "" then
            return attack[key]
        end
    end
    local cuirass = target and target:isValid()
        and types.Actor.getEquipment(target, types.Actor.EQUIPMENT_SLOT.Cuirass)
        or nil
    if cuirass and types.Armor.objectIsInstance(cuirass) then
        local weight = types.Armor.record(cuirass).weight
        if weight < 10 then return "light armor hit" end
        if weight < 25 then return "medium armor hit" end
        return "heavy armor hit"
    end
    return "health damage"
end

-- Resolves a queued shadow-hit through the Framework so inherited on-hit
-- effects, final damage, and impact audio all occur after the visible strike.
-- The queue entry is removed first so nested hit callbacks cannot resolve it
-- for a second time.
local function resolveCruelPrecisionFollowUp(entry)
    local followUp = entry.attack
    local target = followUp.target
    local debugData = entry.debugData
    lastFollowUpDebug = debugData
    debugData.remainingDelay = 0
    if not target or not target:isValid() then
        debugData.processed = false
        debugData.result = "delayed target no longer valid"
        SkillDebug.traceEvent(SKILL_ID, "Cruel Precision follow-up rejected", debugData)
        return
    end

    local framework = interfaces.ErnPerkFramework
    local processed = framework.dispatchOnHit(followUp, {
        source = "SkillPerks.shortblade.followUp",
        direction = framework.HIT_DIRECTION.Outgoing,
        target = target,
        forwarded = true,
        resolveDamage = true,
        deduplicate = false,
    })
    local resolvedDamage = processed and Common.healthDamage(followUp) or 0
    debugData.processed = processed
    debugData.resolvedDamage = resolvedDamage
    debugData.onHitContributions = followUp.perkFrameworkDamageContributors
        and #followUp.perkFrameworkDamageContributors or 0
    debugData.result = processed and resolvedDamage > 0
        and "delayed damage queued" or "Framework rejected delayed follow-up"
    if resolvedDamage > 0 then
        target:sendEvent("SPerks_TakeDamage", {
            amount = resolvedDamage,
            source = self,
            sourceEffect = ids.C2,
            context = "shortblade.cruelPrecisionFollowUp",
        })
        ambient.playSound(entry.hitSound, { volume = SHADOW_HIT_VOLUME })
    end
    SkillDebug.traceEvent(SKILL_ID, "Cruel Precision follow-up resolved", debugData)
end

-- Cruel Precision makes its own vanilla-style hit roll immediately, then
-- snapshots the triggering hit into a fresh payload. The payload waits briefly
-- before visiting outgoing onHit handlers; its marker prevents another shadow-
-- hit when those inherited effects are evaluated.
local function attemptCruelPrecisionFollowUp(triggeringAttack)
    local target = Common.attackTarget(triggeringAttack)
    local weapon = Common.weaponFromAttack(triggeringAttack, self)
    local baseDamage = Common.healthDamage(triggeringAttack) * 0.5
    local hitSound = triggeringHitSound(triggeringAttack, target)
    local hitChance = target and target:isValid()
        and math.max(0, math.min(100,
            CombatMath.getHitChance(self, target, SKILL_ID))) or 0
    local roll = math.random(100)
    local landed = target and target:isValid() and weapon
        and Common.isShortBlade(weapon) and baseDamage > 0 and roll <= hitChance

    local debugData = {
        target = SkillDebug.objectId(target),
        weapon = SkillDebug.objectId(weapon),
        triggeringDamage = Common.healthDamage(triggeringAttack),
        baseDamage = baseDamage,
        hitChance = hitChance,
        roll = roll,
        landed = landed == true,
        hitSound = hitSound,
        hitSoundVolume = SHADOW_HIT_VOLUME,
        delay = SHADOW_HIT_DELAY,
        remainingDelay = landed and SHADOW_HIT_DELAY or nil,
        result = landed and "follow-up queued" or "follow-up missed or invalid",
    }
    lastFollowUpDebug = debugData
    SkillDebug.traceEvent(SKILL_ID, "Cruel Precision follow-up attempted", debugData)
    if not landed then
        return
    end

    local followUp = {
        attacker = self,
        target = target,
        weapon = weapon,
        sourceType = triggeringAttack.sourceType or "melee",
        successful = true,
        strength = triggeringAttack.strength,
        type = triggeringAttack.type,
        attackType = triggeringAttack.attackType,
        damage = { health = baseDamage, fatigue = 0, magicka = 0 },
        skillPerksPlayerOwned = true,
        skillPerksHitSource = "shortblade-follow-up",
        skillPerksShortBladeFollowUp = true,
    }
    pendingShadowHits[#pendingShadowHits + 1] = {
        timer = SHADOW_HIT_DELAY,
        attack = followUp,
        hitSound = hitSound,
        debugData = debugData,
    }
end

-- Advances independent shadow-hit delays in reverse order so removing an
-- expired entry cannot skip the next pending strike.
local function updatePendingShadowHits(dt)
    for index = #pendingShadowHits, 1, -1 do
        local entry = pendingShadowHits[index]
        entry.timer = entry.timer - dt
        entry.debugData.remainingDelay = math.max(0, entry.timer)
        if entry.timer <= 0 then
            table.remove(pendingShadowHits, index)
            resolveCruelPrecisionFollowUp(entry)
        end
    end
end

--- Records hit payloads before the shared router filters them, making missing
--- player ownership or weapon classification visible to the debug command.
local function observeAndRouteHit(attack, source)
    attack = attack or {}
    SkillDebug.traceEvent(SKILL_ID, "outgoing hit received", {
        source = source,
        successful = attack.successful,
        weapon = SkillDebug.objectId(attack.weapon),
    })
    local routed = routeOutgoingHit(attack, source)
    if not routed then
        local weapon = Common.weaponFromAttack(attack, self)
        local weaponRecord = weapon and types.Weapon.record(weapon) or nil
        lastHitDebug = {
            source = source,
            sourceType = attack.sourceType,
            successful = attack.successful,
            healthDamage = Common.healthDamage(attack),
            weaponId = weaponRecord and weaponRecord.id or nil,
            weaponType = weaponRecord and weaponRecord.type or nil,
            shortBlade = Common.isShortBlade(weapon),
            playerOwned = attack.skillPerksPlayerOwned == true,
            aRank = aRank(),
            stacksBefore = tempoStacks,
            result = "rejected by outgoing-hit router",
        }
    end
    SkillDebug.traceEvent(SKILL_ID, routed and "outgoing hit accepted" or "outgoing hit rejected", lastHitDebug)
end

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ids.A1 .. "_shortblade_hit",
    priority = 430,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack, context)
        observeAndRouteHit(attack, attack.skillPerksHitSource or "framework")
        if attack.skillPerksShortBladeFollowUpReady == true
                and context and type(context.afterResolve) == "function" then
            context.afterResolve(function(resolvedAttack)
                attemptCruelPrecisionFollowUp(resolvedAttack)
            end)
        end
    end,
})

-- Opening Strike becomes available again when that actor leaves combat with
-- the player, matching the design's per-encounter rather than per-save gate.
local function onCombatTargetsChanged(data)
    if not data or not data.actor then
        return
    end
    for _, target in ipairs(data.targets or {}) do
        if target == self then
            return
        end
    end
    local key = Common.targetKey(data.actor)
    if key then
        openedTargets[key] = nil
    end
end

local function clearShortBlade()
    tempoStats.clearAll()
    tempoEffects.clearAll()
    tempoStacks = 0
    tempoTimer = 0
    openedTargets = {}
    vitalTargets = {}
    vitalTargetKey = nil
    bleeds = {}
    pendingShadowHits = {}
    lastFollowUpDebug = nil
    lastBleedDebug = nil
end

local function onUpdate(dt)
    if tempoStacks > 0 then
        tempoTimer = tempoTimer - dt
        if tempoTimer <= 0 then
            tempoStacks = tempoStacks - 1
            tempoTimer = tempoStacks > 0 and 4 or 0
            updateTempo()
        end
    end
    for key, entry in pairs(vitalTargets) do
        entry.timer = entry.timer - dt
        if entry.timer <= 0 then
            vitalTargets[key] = nil
        end
    end
    updatePendingShadowHits(dt)
    updateBleeds(dt)
end

local function onSave()
    return { tempo = tempoStats.snapshot(), tempoEffects = tempoEffects.snapshot(), tempoStacks = tempoStacks, tempoTimer = tempoTimer }
end

local function onLoad(data)
    data = data or {}
    tempoStats.restoreAndReverse(data.tempo)
    tempoEffects.restoreAndReverse(data.tempoEffects)
    tempoStacks = data.tempoStacks or 0
    tempoTimer = data.tempoTimer or 0
    openedTargets = {}
    vitalTargets = {}
    vitalTargetKey = nil
    bleeds = {}
    pendingShadowHits = {}
    -- restoreAndReverse removes the serialized modifier to prevent doubling;
    -- rebuild it immediately from the restored Tempo state.
    updateTempo()
end

-- Replaces the optimistic D2 queue result with the global spell helper's
-- verified outcome, including natural resistance or an intervening source of
-- Paralysis which made the non-stacking request unnecessary.
local function onParalyzeApplied(data)
    data = data or {}
    if not lastBleedDebug or data.requestId ~= lastBleedDebug.requestId then
        return
    end
    lastBleedDebug.paralysisApplied = data.success == true
    lastBleedDebug.paralysisActive = data.active == true
    lastBleedDebug.paralysisStage = data.stage
    lastBleedDebug.paralysisError = data.error
    if data.skipped == true and data.stage == "effect-already-active" then
        lastBleedDebug.paralysisResult = "target became paralysed before application"
    elseif data.stage == "verify-active" and data.active ~= true then
        lastBleedDebug.paralysisResult = "Paralyze resisted"
    else
        lastBleedDebug.paralysisResult = data.success == true
            and "Paralyze applied"
            or ("Paralyze failed at " .. tostring(data.stage))
    end
    SkillDebug.traceEvent(SKILL_ID, "Red Silence result", lastBleedDebug)
end

local function consolePrint(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

--- Prints the live Tempo state and the most recent routed hit to the regular
--- console. This remains silent during normal play.
local function onConsoleCommand(mode, command)
    if SkillDebug.handleTraceCommand({
        name = "Short Blade",
        skillId = SKILL_ID,
        commands = { "luasb debug", "luashortblade debug" },
    }, command) then
        return
    end
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "luasb debug" and command ~= "luashortblade debug" then
        return
    end
    SkillDebug.describe({ name = "Short Blade", skillId = SKILL_ID, actor = self, ids = ids })

    local speed = types.Actor.stats.attributes.speed(self)
    local agility = types.Actor.stats.attributes.agility(self)
    consolePrint("Short Blade Tempo: A=" .. tostring(aRank())
        .. " stacks=" .. tostring(tempoStacks)
        .. " timer=" .. tostring(tempoTimer)
        .. " Speed(base/mod/modified)=" .. tostring(speed.base)
        .. "/" .. tostring(speed.modifier)
        .. "/" .. tostring(speed.modified)
        .. " Agility(modified)=" .. tostring(agility.modified))
    local vital = vitalTargetKey and vitalTargets[vitalTargetKey] or nil
    consolePrint("Vital Strike: C=" .. tostring(cRank())
        .. " target=" .. tostring(vitalTargetKey)
        .. " stacks=" .. tostring(vital and vital.stacks or 0)
        .. "/" .. tostring(C_CAP[cRank()] or 0)
        .. " rate=" .. tostring(C_DAMAGE_RATE[cRank()] or 0)
        .. " timer=" .. tostring(vital and vital.timer or 0))
    consolePrint("Bleed: D=" .. tostring(dRank())
        .. " activeTargets=" .. tostring(SkillDebug.count(bleeds))
        .. " cap=" .. tostring(D_CAP[dRank()] or 0)
        .. " paralyzeChance=" .. tostring(dRank() >= 2 and D_PARALYZE_CHANCE or 0))
    consolePrint("Cruel Precision pending shadow-hits=" .. tostring(#pendingShadowHits)
        .. " delay=" .. tostring(SHADOW_HIT_DELAY) .. "s")
    if not lastHitDebug then
        consolePrint("Short Blade last hit: none seen.")
        return
    end
    consolePrint("Short Blade last hit: source=" .. tostring(lastHitDebug.source)
        .. " sourceType=" .. tostring(lastHitDebug.sourceType)
        .. " success=" .. tostring(lastHitDebug.successful)
        .. " damage=" .. tostring(lastHitDebug.healthDamage)
        .. " weapon=" .. tostring(lastHitDebug.weaponId)
        .. " type=" .. tostring(lastHitDebug.weaponType)
        .. " shortBlade=" .. tostring(lastHitDebug.shortBlade)
        .. " playerOwned=" .. tostring(lastHitDebug.playerOwned)
        .. " A=" .. tostring(lastHitDebug.aRank)
        .. " stacks=" .. tostring(lastHitDebug.stacksBefore)
        .. "->" .. tostring(lastHitDebug.stacksAfter)
        .. " vital=" .. tostring(lastHitDebug.vitalStacksBefore)
        .. "->" .. tostring(lastHitDebug.vitalStacksAfter)
        .. " vitalBonus=" .. tostring(lastHitDebug.vitalBonus)
        .. " opening=" .. tostring(lastHitDebug.openingDamage)
        .. " opportunist=" .. tostring(lastHitDebug.opportunistMultiplier)
        .. " firstBlood=" .. tostring(lastHitDebug.openingMultiplier)
        .. " critical=" .. tostring(lastHitDebug.criticalMultiplier)
        .. " final=" .. tostring(lastHitDebug.finalDamage)
        .. " lateOrder=" .. tostring(lastHitDebug.lateDamageResult)
        .. " result=" .. tostring(lastHitDebug.result))
    if lastFollowUpDebug then
        consolePrint("Cruel Precision shadow-hit: target="
            .. tostring(lastFollowUpDebug.target)
            .. " triggerDamage=" .. tostring(lastFollowUpDebug.triggeringDamage)
            .. " base=" .. tostring(lastFollowUpDebug.baseDamage)
            .. " hitChance=" .. tostring(lastFollowUpDebug.hitChance)
            .. " roll=" .. tostring(lastFollowUpDebug.roll)
            .. " landed=" .. tostring(lastFollowUpDebug.landed)
            .. " processed=" .. tostring(lastFollowUpDebug.processed)
            .. " onHitContributions=" .. tostring(lastFollowUpDebug.onHitContributions)
            .. " resolvedDamage=" .. tostring(lastFollowUpDebug.resolvedDamage)
            .. " sound=" .. tostring(lastFollowUpDebug.hitSound)
            .. " volume=" .. tostring(lastFollowUpDebug.hitSoundVolume)
            .. " delay=" .. tostring(lastFollowUpDebug.delay)
            .. " remaining=" .. tostring(lastFollowUpDebug.remainingDelay)
            .. " recursiveFlag=true"
            .. " result=" .. tostring(lastFollowUpDebug.result))
    else
        consolePrint("Cruel Precision shadow-hit: none attempted.")
    end
    if lastBleedDebug then
        consolePrint("Last Bleed: target=" .. tostring(lastBleedDebug.target)
            .. " stacks=" .. tostring(lastBleedDebug.stacksBefore)
            .. "->" .. tostring(lastBleedDebug.stacksAfter)
            .. " maxHealth=" .. tostring(lastBleedDebug.maximumHealth)
            .. " perStack=" .. tostring(lastBleedDebug.damagePerStack)
            .. " perTick=" .. tostring(lastBleedDebug.damagePerTick)
            .. " paraEligible=" .. tostring(lastBleedDebug.paralysisEligible)
            .. " chance=" .. tostring(lastBleedDebug.paralysisChance)
            .. " roll=" .. tostring(lastBleedDebug.paralysisRoll)
            .. " triggered=" .. tostring(lastBleedDebug.paralysisTriggered)
            .. " result=" .. tostring(lastBleedDebug.paralysisResult))
    else
        consolePrint("Last Bleed: none applied.")
    end
end

Common.registerStealthPerks(SKILL_ID, "Short Blade", ids, {
    A1 = { localizedName = "Blade Tempo", localizedFlavour = "The first cut starts the rhythm. The second teaches your feet where the fight is going.", localizedDescription = "Successful Short Blade hits grant +3 Speed per stack, up to 3 stacks. Stacks decay after 4 seconds without a hit.", onAdd = updateTempo, onRemove = clearShortBlade },
    A2 = { localizedName = "Quickened Edge", localizedFlavour = "Your hand moves before hesitation has a name.", localizedDescription = "Blade Tempo grants +5 Speed per stack.", onAdd = updateTempo, onRemove = clearShortBlade },
    A3 = { localizedName = "Knife Rhythm", localizedFlavour = "Each wound pulls the next one closer.", localizedDescription = "Blade Tempo stack cap rises to 5.", onAdd = updateTempo, onRemove = clearShortBlade },
    A4 = { localizedName = "Eightfold Motion", localizedFlavour = "At full speed, the blade is less a weapon than a weather pattern.", localizedDescription = "Blade Tempo stack cap rises to 8. At maximum stacks, gain +10 Agility.", onAdd = updateTempo, onRemove = clearShortBlade },
    B1 = { localizedName = "Opening Strike", localizedFlavour = "The first touch decides how much room the enemy has left to make mistakes.", localizedDescription = "The first Short Blade hit against each target deals bonus damage equal to Short Blade / 5.", onRemove = clearShortBlade },
    B2 = { localizedName = "First Blood Lesson", localizedFlavour = "A surprised enemy does not get a warning. They get a conclusion.", localizedDescription = "Opening Strike increases to Short Blade / 3, doubled if the hit is an unaware strike.", onRemove = clearShortBlade },
    C1 = { localizedName = "Vital Strike", localizedFlavour = "You stop aiming for the body and start aiming for decisions the body cannot survive.", localizedDescription = "Successive hits against the same target within 5 seconds deal +4% damage per stack, up to 5 stacks.", onRemove = clearShortBlade },
    C2 = { localizedName = "Cruel Precision", localizedFlavour = "The wound remembers where you placed it, and your next cut agrees.", localizedDescription = "Vital Strike deals +5% damage per stack, its cap rises to 8, and its timer extends to 8 seconds. At maximum stacks, each attack attempts a shadow-hit after 0.1 seconds for 50% damage which inherits your on-hit effects.", onRemove = clearShortBlade },
    D1 = { localizedName = "Bleed", localizedFlavour = "Small wounds become a ledger the enemy pays one heartbeat at a time.", localizedDescription = "Short Blade hits apply up to 3 Bleed stacks for 5 seconds. Each stack deals 1% of the target's maximum Health per second, with a minimum of 1 damage per stack.", onRemove = clearShortBlade },
    D2 = { localizedName = "Red Silence", localizedFlavour = "When the bleeding reaches its cadence, even defiance forgets to stand.", localizedDescription = "Bleed's stack cap rises to 5. Attacks which reach or maintain 5 stacks have a 10% chance to attempt a resistible 1-second Paralysis.", onRemove = clearShortBlade },
})

return {
    eventHandlers = {
        OMWMusicCombatTargetsChanged = onCombatTargetsChanged,
        SPerks_ShortBladeParalyzeApplied = onParalyzeApplied,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onConsoleCommand = onConsoleCommand,
    },
}
