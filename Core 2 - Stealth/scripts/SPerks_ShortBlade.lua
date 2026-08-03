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
local interfaces = require("openmw.interfaces")
local self       = require("openmw.self")
local types      = require("openmw.types")
local ui         = require("openmw.ui")

local Common      = require("scripts.SkillPerks.stealth.common")
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
local lastHitDebug = nil

local A_SPEED = { [1] = 3, [2] = 5, [3] = 5, [4] = 5 }
local A_CAP = { [1] = 3, [2] = 3, [3] = 5, [4] = 8 }
local B_DIVISOR = { [1] = 5, [2] = 3 }
local C_CAP = { [1] = 5, [2] = 8 }
local C_DURATION = { [1] = 5, [2] = 8 }
local D_CAP = { [1] = 3, [2] = 5 }

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

local function addBleed(target)
    local rank = dRank()
    local key = Common.targetKey(target)
    if rank == 0 or not key then
        return
    end
    local entry = bleeds[key] or { target = target, stacks = 0, tick = 1, timer = 0 }
    entry.target = target
    local paralyzeNow = entry.paralyzeReady == true
    entry.paralyzeReady = false
    local oldStacks = entry.stacks
    entry.stacks = math.min(D_CAP[rank], entry.stacks + 1)
    entry.timer = 5
    entry.tick = 1
    bleeds[key] = entry
    if rank >= 2 and paralyzeNow then
        core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
            target = target,
            caster = self,
            preferredSpellId = "SPerks_Native_Paralyze_1s",
            spellName = "SkillPerks Bleeding Stagger",
            effects = { { id = "paralyze", magnitudeMin = 1, duration = 1 } },
            activeSpellOptions = { ignoreResistances = false, quiet = true },
        })
    end
    if rank >= 2 and oldStacks < D_CAP[rank] and entry.stacks >= D_CAP[rank] then
        entry.paralyzeReady = true
    end
end

local function updateBleeds(dt)
    for key, entry in pairs(bleeds) do
        entry.timer = entry.timer - dt
        entry.tick = entry.tick - dt
        if entry.timer <= 0 or not entry.target or not entry.target:isValid() then
            bleeds[key] = nil
        elseif entry.tick <= 0 then
            entry.tick = 1
            entry.target:sendEvent("SPerks_TakeDamage", {
                amount = entry.stacks,
                source = self,
                sourceEffect = ids.D1,
                context = "shortblade.bleed",
            })
        end
    end
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, function(attack, source)
    local weapon = Common.weaponFromAttack(attack, self)
    local weaponRecord = weapon and types.Weapon.record(weapon) or nil
    lastHitDebug = {
        source = source,
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
    local bonus = 0

    local openingRank = bRank()
    if openingRank > 0 and key and not openedTargets[key] then
        openedTargets[key] = true
        local opening = Common.skill(self, SKILL_ID) / B_DIVISOR[openingRank]
        if openingRank >= 2 and Common.isUnawareHit(attack) then
            opening = opening * 2
        end
        bonus = bonus + opening
    end

    local vitalRank = cRank()
    if vitalTargetKey and vitalTargetKey ~= key then
        vitalTargets = {}
    end
    vitalTargetKey = key
    local vital = key and vitalTargets[key]
    if vitalRank > 0 and vital then
        bonus = bonus + Common.healthDamage(attack) * vital.stacks * 0.03
    end
    Common.applyBonusHealthDamage(attack, bonus, self, ids.B1, "shortblade.bonusDamage")

    addTempo()
    lastHitDebug.stacksAfter = tempoStacks
    lastHitDebug.result = "Tempo applied"
    if vitalRank > 0 and key then
        vital = vital or { stacks = 0, timer = 0 }
        vital.stacks = math.min(C_CAP[vitalRank], vital.stacks + 1)
        vital.timer = C_DURATION[vitalRank]
        vitalTargets[key] = vital
    end
    addBleed(target)
    return true
end)

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
    handler = function(attack)
        observeAndRouteHit(attack, attack.skillPerksHitSource or "framework")
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
    -- restoreAndReverse removes the serialized modifier to prevent doubling;
    -- rebuild it immediately from the restored Tempo state.
    updateTempo()
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
    if not lastHitDebug then
        consolePrint("Short Blade last hit: none seen.")
        return
    end
    consolePrint("Short Blade last hit: source=" .. tostring(lastHitDebug.source)
        .. " success=" .. tostring(lastHitDebug.successful)
        .. " damage=" .. tostring(lastHitDebug.healthDamage)
        .. " weapon=" .. tostring(lastHitDebug.weaponId)
        .. " type=" .. tostring(lastHitDebug.weaponType)
        .. " shortBlade=" .. tostring(lastHitDebug.shortBlade)
        .. " playerOwned=" .. tostring(lastHitDebug.playerOwned)
        .. " A=" .. tostring(lastHitDebug.aRank)
        .. " stacks=" .. tostring(lastHitDebug.stacksBefore)
        .. "->" .. tostring(lastHitDebug.stacksAfter)
        .. " result=" .. tostring(lastHitDebug.result))
end

Common.registerStealthPerks(SKILL_ID, "Short Blade", ids, {
    A1 = { localizedName = "Blade Tempo", localizedFlavour = "The first cut starts the rhythm. The second teaches your feet where the fight is going.", localizedDescription = "Successful Short Blade hits grant +3 Speed per stack, up to 3 stacks. Stacks decay after 4 seconds without a hit.", onAdd = updateTempo, onRemove = clearShortBlade },
    A2 = { localizedName = "Quickened Edge", localizedFlavour = "Your hand moves before hesitation has a name.", localizedDescription = "Blade Tempo grants +5 Speed per stack.", onAdd = updateTempo, onRemove = clearShortBlade },
    A3 = { localizedName = "Knife Rhythm", localizedFlavour = "Each wound pulls the next one closer.", localizedDescription = "Blade Tempo stack cap rises to 5.", onAdd = updateTempo, onRemove = clearShortBlade },
    A4 = { localizedName = "Eightfold Motion", localizedFlavour = "At full speed, the blade is less a weapon than a weather pattern.", localizedDescription = "Blade Tempo stack cap rises to 8. At maximum stacks, gain +10 Agility.", onAdd = updateTempo, onRemove = clearShortBlade },
    B1 = { localizedName = "Opening Strike", localizedFlavour = "The first touch decides how much room the enemy has left to make mistakes.", localizedDescription = "The first Short Blade hit against each target deals bonus damage equal to Short Blade / 5.", onRemove = clearShortBlade },
    B2 = { localizedName = "First Blood Lesson", localizedFlavour = "A surprised enemy does not get a warning. They get a conclusion.", localizedDescription = "Opening Strike increases to Short Blade / 3, doubled if the hit is an unaware strike.", onRemove = clearShortBlade },
    C1 = { localizedName = "Vital Strike", localizedFlavour = "You stop aiming for the body and start aiming for decisions the body cannot survive.", localizedDescription = "Successive hits against the same target within 5 seconds deal +3% damage per stack, up to 5 stacks.", onRemove = clearShortBlade },
    C2 = { localizedName = "Cruel Precision", localizedFlavour = "The wound remembers where you placed it, and your next cut agrees.", localizedDescription = "Vital Strike stack cap rises to 8 and the timer extends to 8 seconds.", onRemove = clearShortBlade },
    D1 = { localizedName = "Bleed", localizedFlavour = "Small wounds become a ledger the enemy pays one heartbeat at a time.", localizedDescription = "Short Blade hits apply stacking damage over time: 1 health per second per stack for 5 seconds, up to 3 stacks.", onRemove = clearShortBlade },
    D2 = { localizedName = "Red Silence", localizedFlavour = "When the bleeding reaches its cadence, even defiance forgets to stand.", localizedDescription = "Bleed stack cap rises to 5. After reaching maximum stacks, your next hit attempts a brief paralysis.", onRemove = clearShortBlade },
})

return {
    eventHandlers = {
        OMWMusicCombatTargetsChanged = onCombatTargetsChanged,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onConsoleCommand = onConsoleCommand,
    },
}
