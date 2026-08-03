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
    SPerks_Spear.lua

    Spear - "Progressive denial, sustained charged attack engagement."
    Spear attacks stack attribute pressure on enemies, then turn those
    weaknesses into extra damage through the framework calculation pipeline.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local core       = require("openmw.core")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local SkillDebug        = require("scripts.SkillPerks.shared.debug")
local SharedHit         = require("scripts.SkillPerks.shared.hit")

local SKILL_ID = "spear"
local CALCULATION = interfaces.ErnPerkFramework.CALCULATION
local OPERATION = interfaces.ErnPerkFramework.CALCULATION_OPERATION

local ids = {
    A1 = ns .. "_spear_a1",
    A2 = ns .. "_spear_a2",
    A3 = ns .. "_spear_a3",
    A4 = ns .. "_spear_a4",
    B1 = ns .. "_spear_b1",
    B2 = ns .. "_spear_b2",
    C1 = ns .. "_spear_c1",
    C2 = ns .. "_spear_c2",
    D1 = ns .. "_spear_d1",
    D2 = ns .. "_spear_d2",
}

local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local function getARank()
    if hasPerk(ids.A4) then return 4
    elseif hasPerk(ids.A3) then return 3
    elseif hasPerk(ids.A2) then return 2
    elseif hasPerk(ids.A1) then return 1
    else return 0 end
end

local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

local function getCRank()
    if hasPerk(ids.C2) then return 2
    elseif hasPerk(ids.C1) then return 1
    else return 0 end
end

local function getDRank()
    if hasPerk(ids.D2) then return 2
    elseif hasPerk(ids.D1) then return 1
    else return 0 end
end

local function noPersistentEffect() end

-- ============================================================
--  SHARED HIT HELPERS
-- ============================================================

local CHARGED_THRESHOLD = 0.95
local A_STACK_TIMER = 5
local D_STACK_TIMER = 5

local A_MAGNITUDE = { [1] = 3, [2] = 5, [3] = 8, [4] = 10 }
local A_MAX_STACKS = { [1] = 1, [2] = 1, [3] = 3, [4] = 5 }
local D_MAX_STACKS = 3
local D_SPEED_MAGNITUDE = 25

local agilityStacksByTarget = {}
local speedStacksByTarget = {}

local function getAttackTarget(attack)
    return attack.target or attack.victim or attack.defender
end

local function isPlayerAttack(attack)
    return SharedHit.isPlayerAttack(attack, self)
end

local function isPlayerSpearAttack(attack)
    if not isPlayerAttack(attack) or not attack.weapon or not types.Weapon.objectIsInstance(attack.weapon) then
        return false
    end
    return types.Weapon.record(attack.weapon).type == types.Weapon.TYPE.SpearTwoWide
end

local function getChargeRatio(attack)
    local strength = attack.strength
    if type(strength) ~= "number" then
        return 0
    end
    if strength > 1 then
        strength = strength / 100
    end
    return math.max(0, math.min(strength, 1))
end

local function isChargedAttack(attack)
    return getChargeRatio(attack) >= CHARGED_THRESHOLD
end

local function isThrustAttack(attack)
    return attack.type == 2 or attack.type == "thrust" or attack.type == "Thrust"
end

-- Replaces one perk-owned attribute drain on the target. The target's Core 0
-- script owns the actual modifier and expiry, avoiding global aggregate writes.
local function setAttributeDrain(target, key, attribute, amount, duration, sourceEffect)
    target:sendEvent("SPerks_SetTimedEffectBundle", {
        caster=self,
        sourceEffect=sourceEffect,
        effects={{
            key=key,id="drainattribute",affectedAttribute=attribute,
            magnitudeMin=math.max(0,amount or 0),duration=duration or 1,
        }},
    })
end

local function applyDamageAttribute(target, attribute, magnitude, duration, spellName)
    SkillDebug.traceEvent(SKILL_ID, "attribute damage applied", {
        attribute = attribute,
        duration = duration,
        magnitude = magnitude,
        target = SkillDebug.objectId(target),
    })
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = self,
        preferredSpellId = attribute=="agility"
            and "SPerks_Spear_Damage_Agility" or "SPerks_Spear_Damage_Speed",
        spellName = spellName,
        effects = {
            {
                id = "damageattribute",
                range = core.magic.RANGE.Target,
                magnitudeMin = magnitude,
                duration = duration,
                affectedAttribute = attribute,
            },
        },
        activeSpellOptions = {
            ignoreResistances = false,
            quiet = true,
        },
    })
end

local function applyParalyze(target)
    SkillDebug.traceEvent(SKILL_ID, "paralysis applied", {
        target = SkillDebug.objectId(target),
    })
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = self,
        preferredSpellId = "SPerks_Native_Paralyze_1s",
        spellName = "Pinned Nerve",
        effects = {
            {
                id = "paralyze",
                range = core.magic.RANGE.Target,
                magnitudeMin = 1,
                duration = 1,
            },
        },
        activeSpellOptions = {
            ignoreResistances = false,
            quiet = true,
        },
    })
end

-- Counts hostile attribute pressure already present on the target. Drain
-- and Damage Attribute use positive magnitudes but are negative effects
-- semantically, so the effect id matters more than the sign.
local function countNegativeAttributeEffects(target)
    local count = 0
    for _, effect in pairs(types.Actor.activeEffects(target)) do
        if effect.affectedAttribute ~= nil then
            if effect.id == "drainattribute" or effect.id == "damageattribute" or (effect.magnitude or 0) < 0 then
                count = count + 1
            end
        end
    end
    return count
end

-- ============================================================
--  A CHAIN - PINNING POINT
-- ============================================================

local function removeAgilityStacksForKey(key)
    local entry = agilityStacksByTarget[key]
    if not entry then
        return
    end
    if entry.target and entry.target:isValid() and entry.stacks > 0 then
        setAttributeDrain(entry.target,"SkillPerks_SpearPinning","agility",0,1,ids.A1)
    end
    agilityStacksByTarget[key] = nil
end

-- All Agility stacks on one target share a single timer. A rank upgrade
-- changes stack magnitude, so existing old-magnitude stacks are cleared
-- before new ones are applied.
local function handlePinningPoint(target)
    local rank = getARank()
    SkillDebug.traceEvent(SKILL_ID, "Pinning Point check", {
        rank = rank,
        target = SkillDebug.objectId(target),
    })
    if rank == 0 then
        return
    end

    local key = target.id
    local magnitude = A_MAGNITUDE[rank]
    local entry = agilityStacksByTarget[key]
    if entry and entry.magnitude ~= magnitude then
        removeAgilityStacksForKey(key)
        entry = nil
    end
    if not entry then
        entry = { target = target, stacks = 0, magnitude = magnitude, timer = A_STACK_TIMER }
        agilityStacksByTarget[key] = entry
    end

    if entry.stacks < A_MAX_STACKS[rank] then
        entry.stacks = entry.stacks + 1
    end
    entry.timer = A_STACK_TIMER
    setAttributeDrain(target,"SkillPerks_SpearPinning","agility",
        entry.stacks*entry.magnitude,entry.timer,ids.A1)
end

local function tickAgilityStacks(dt)
    for key, entry in pairs(agilityStacksByTarget) do
        entry.timer = entry.timer - dt
        if entry.timer <= 0 or not entry.target or not entry.target:isValid() then
            removeAgilityStacksForKey(key)
        end
    end
end

local function clearAgilityStacks()
    for key in pairs(agilityStacksByTarget) do
        removeAgilityStacksForKey(key)
    end
end

-- ============================================================
--  B/C CHAINS - EXPLOITING NEGATIVE ATTRIBUTES
-- ============================================================

local function getNegativeAttributeBonus(attack, target)
    local bonus = 0
    local negativeCount = countNegativeAttributeEffects(target)
    local value = negativeCount * (3 + getChargeRatio(attack) * 2)

    if getBRank() > 0 and isPlayerSpearAttack(attack) and isChargedAttack(attack) then
        bonus = bonus + value
    end
    if getCRank() > 0 and isPlayerAttack(attack) and isThrustAttack(attack) then
        bonus = bonus + value
    end

    return bonus
end

interfaces.ErnPerkFramework.registerCalculationHandler({
    id = ns .. "_spear_hit_damage_health",
    calculation = CALCULATION.HIT_DAMAGE_HEALTH,
    operation = OPERATION.Addition,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
}, function(data)
    local attack = data.context
    if not attack or attack.successful ~= true then
        return false
    end
    local target = getAttackTarget(attack)
    if not target or not target:isValid() then
        return false
    end
    local bonus = getNegativeAttributeBonus(attack, target)
    return bonus > 0 and bonus or false
end)

-- ============================================================
--  D CHAIN - HAMSTRINGING POINT
-- ============================================================

local function removeOneSpeedStack(key, index)
    local entry = speedStacksByTarget[key]
    if not entry then
        return
    end
    local stack = table.remove(entry.stacks, index)
    local target=entry.target
    if #entry.stacks == 0 then
        speedStacksByTarget[key] = nil
    end
    if stack and target and target:isValid() then
        local remaining=0
        for _,state in ipairs(entry.stacks) do remaining=math.max(remaining,state.timer or 0) end
        setAttributeDrain(target,"SkillPerks_SpearHamstring","speed",
            #entry.stacks*D_SPEED_MAGNITUDE,math.max(remaining,0.01),ids.D1)
    end
end

local function addSpeedStack(target)
    if getDRank() == 0 then
        return
    end

    local key = target.id
    local entry = speedStacksByTarget[key]
    if not entry then
        entry = { target = target, stacks = {} }
        speedStacksByTarget[key] = entry
    end
    if #entry.stacks >= D_MAX_STACKS then
        removeOneSpeedStack(key, 1)
    end

    table.insert(entry.stacks, { timer = D_STACK_TIMER })
    setAttributeDrain(target,"SkillPerks_SpearHamstring","speed",
        #entry.stacks*D_SPEED_MAGNITUDE,D_STACK_TIMER,ids.D1)

    if getDRank() >= 2 then
        applyDamageAttribute(target, "speed", 5, 2, "Hamstringing Point")
    end
end

local function tickSpeedStacks(dt)
    for key, entry in pairs(speedStacksByTarget) do
        for i = #entry.stacks, 1, -1 do
            entry.stacks[i].timer = entry.stacks[i].timer - dt
            if entry.stacks[i].timer <= 0 or not entry.target or not entry.target:isValid() then
                removeOneSpeedStack(key, i)
            end
        end
    end
end

local function clearSpeedStacks()
    for key, entry in pairs(speedStacksByTarget) do
        while entry and #entry.stacks > 0 do
            removeOneSpeedStack(key, #entry.stacks)
            entry = speedStacksByTarget[key]
        end
    end
end

-- ============================================================
--  SHARED HIT HANDLER
-- ============================================================

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_spear_on_hit",
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack)
        if not isPlayerAttack(attack) or attack.successful ~= true then
            return
        end
        local target = getAttackTarget(attack)
        if not target or not target:isValid() then
            return
        end

        if isPlayerSpearAttack(attack) and isChargedAttack(attack) then
            handlePinningPoint(target)
            if getBRank() >= 2 and countNegativeAttributeEffects(target) >= 3 then
                applyParalyze(target)
            end
            addSpeedStack(target)
        end

        if getCRank() >= 2 and isThrustAttack(attack) then
            applyDamageAttribute(target, "agility", 1, 2, "Opening Wound")
        end
    end,
})

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local function onUpdate(dt)
    tickAgilityStacks(dt)
    tickSpeedStacks(dt)
end

local function serializeAgilityStacks()
    local out = {}
    for key, entry in pairs(agilityStacksByTarget) do
        if entry.target and entry.target:isValid() and entry.stacks > 0 then
            out[key] = {
                target = entry.target,
                stacks = entry.stacks,
                magnitude = entry.magnitude,
                timer = entry.timer,
            }
        end
    end
    return out
end

local function serializeSpeedStacks()
    local out = {}
    for key, entry in pairs(speedStacksByTarget) do
        if entry.target and entry.target:isValid() and #entry.stacks > 0 then
            out[key] = {
                target = entry.target,
                stacks = entry.stacks,
            }
        end
    end
    return out
end

local function onSave()
    return {
        agilityStacksByTarget = serializeAgilityStacks(),
        speedStacksByTarget = serializeSpeedStacks(),
        targetTimedEffects = true,
    }
end

local function onLoad(data)
    agilityStacksByTarget = data and data.agilityStacksByTarget or {}
    speedStacksByTarget = data and data.speedStacksByTarget or {}
    if not data or data.targetTimedEffects==true then return end
    for _,entry in pairs(agilityStacksByTarget) do
        if entry.target and entry.target:isValid() and entry.stacks and entry.stacks>0 then
            local amount=entry.stacks*(entry.magnitude or 0)
            core.sendGlobalEvent("SPerks_ModifyActorActiveEffect",{
                target=entry.target,effectId="drainattribute",
                extraParam="agility",amount=-amount,
            })
            setAttributeDrain(entry.target,"SkillPerks_SpearPinning","agility",
                amount,entry.timer or A_STACK_TIMER,ids.A1)
        end
    end
    for _,entry in pairs(speedStacksByTarget) do
        if entry.target and entry.target:isValid() and entry.stacks and #entry.stacks>0 then
            local amount=#entry.stacks*D_SPEED_MAGNITUDE
            local remaining=0
            for _,state in ipairs(entry.stacks) do remaining=math.max(remaining,state.timer or 0) end
            core.sendGlobalEvent("SPerks_ModifyActorActiveEffect",{
                target=entry.target,effectId="drainattribute",
                extraParam="speed",amount=-amount,
            })
            setAttributeDrain(entry.target,"SkillPerks_SpearHamstring","speed",
                amount,math.max(remaining,0.01),ids.D1)
        end
    end
end

-- Reports the target-local stack maps used by the Spear A and D chains.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Spear",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luaspear debug" },
    snapshot = function()
        local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
        local weaponRecord = weapon and types.Weapon.objectIsInstance(weapon)
            and types.Weapon.record(weapon) or nil
        return {
            string.format(
                "Weapon: id=%s spear=%s",
                SkillDebug.objectId(weapon),
                tostring(weaponRecord and weaponRecord.type == types.Weapon.TYPE.SpearTwoWide)
            ),
            string.format(
                "Tracked targets: agilityStacks=%d speedStacks=%d",
                SkillDebug.count(agilityStacksByTarget),
                SkillDebug.count(speedStacksByTarget)
            ),
        }
    end,
})

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Pinning Point",
    category = ChainRequirements.category("Combat", "Spear", 1),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "You learn to place the point where motion begins. The wound is small; the hesitation is not.",
    localizedDescription = "Charged Spear hits apply one 5 second Drain Agility stack at magnitude 3.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = noPersistentEffect,
    onRemove = clearAgilityStacks,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Narrowing Point",
    category = ChainRequirements.category("Combat", "Spear", 2),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "Every thrust teaches the enemy that space is a privilege you can revoke.",
    localizedDescription = "Pinning Point's Drain Agility magnitude rises to 5.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = noPersistentEffect,
    onRemove = clearAgilityStacks,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Hobbling Point",
    category = ChainRequirements.category("Combat", "Spear", 3),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "You do not chase. You make escape expensive, then impossible.",
    localizedDescription = "Pinning Point's Drain Agility magnitude rises to 8 and can stack up to 3 times.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = noPersistentEffect,
    onRemove = clearAgilityStacks,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Impaling Point",
    category = ChainRequirements.category("Combat", "Spear", 4),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "The spear writes a command into muscle and balance: stay there.",
    localizedDescription = "Pinning Point's Drain Agility magnitude rises to 10 and can stack up to 5 times.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = noPersistentEffect,
    onRemove = clearAgilityStacks,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Exploit Weakness",
    category = ChainRequirements.category("Combat", "Spear", 5),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "A weakened enemy is a map. You read each failing limb and drive the point where the body can no longer answer.",
    localizedDescription = "Charged Spear hits deal bonus damage per negative attribute effect on the target equal to 3 plus charge strength times 2.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Pinned Nerve",
    category = ChainRequirements.category("Combat", "Spear", 6),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "When enough weaknesses gather, one clean thrust can switch the whole body off.",
    localizedDescription = "Charged Spear hits against targets with 3 or more negative attribute effects apply a 1 second Paralyze effect. Resistance applies.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Driving Thrust",
    category = ChainRequirements.category("Combat", "Spear", 7),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "The lesson of the spear follows the motion, not the shaft. Any weapon can become a point if driven cleanly enough.",
    localizedDescription = "Thrust attacks with any weapon gain the same charge-scaled bonus damage per negative attribute effect. Spear thrusts can benefit from both bonuses.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Opening Wound",
    category = ChainRequirements.category("Combat", "Spear", 9),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "Every thrust leaves something behind: a limp, a stagger, a debt the body pays over the next breath.",
    localizedDescription = "Thrust attacks with any weapon apply Damage Agility 1 point for 2 seconds.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Hamstringing Point",
    category = ChainRequirements.category("Combat", "Spear", 8),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "The spear owns distance. Each charged hit takes a little more road away from the enemy.",
    localizedDescription = "Charged Spear hits apply Drain Speed 25 for 5 seconds, stacking independently up to 3 times.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = noPersistentEffect,
    onRemove = clearSpeedStacks,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Severing Point",
    category = ChainRequirements.category("Combat", "Spear", 10),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "The point passes and the leg remembers it forever. Speed does not return all at once.",
    localizedDescription = "Each new Drain Speed stack also applies Damage Speed 5 points for 2 seconds.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = noPersistentEffect,
    onRemove = clearSpeedStacks,
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
