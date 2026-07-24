--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Target-local Magic bridge. It reports newly-landed player spells once and
owns effects that must mutate the struck actor in its own script context.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local pself = require("openmw.self")

local Stagger = require("scripts.SkillPerks.shared.stagger")

local MagicTarget = {}
local seen = {}
local initialized = false
local pollTimer = 0
local mindThefts = {}
local tether = nil
local echoed = false
local poisonConsequence = nil
local destructionDrain = nil

local function copyEffects(spell)
    local result = {}
    for _, effect in pairs(spell.effects or {}) do
        table.insert(result, {
            id = effect.id,
            index = effect.index,
            affectedAttribute = effect.affectedAttribute,
            affectedSkill = effect.affectedSkill,
            magnitude = effect.magnitudeThisFrame,
            minMagnitude = effect.minMagnitude,
            maxMagnitude = effect.maxMagnitude,
            duration = effect.duration,
            durationLeft = effect.durationLeft,
        })
    end
    return result
end

local function activeSpellIds()
    local current = {}
    for _, spell in pairs(types.Actor.activeSpells(pself)) do
        current[spell.activeSpellId or spell.id] = spell
    end
    return current
end

local function reportNewPlayerSpells(current)
    for key, spell in pairs(current) do
        if not seen[key] and spell.caster and spell.caster:isValid()
                and types.Player.objectIsInstance(spell.caster) then
            spell.caster:sendEvent("SPerks_MagicEffectLanded", {
                target = pself,
                spellId = spell.id,
                activeSpellId = spell.activeSpellId,
                item = spell.item,
                effects = copyEffects(spell),
            })
        end
    end
    seen = {}
    for key in pairs(current) do seen[key] = true end
end

local function reverseMindTheft(id, state)
    for attribute, amount in pairs(state.drains or {}) do
        local stat = types.Actor.stats.attributes[attribute](pself)
        stat.modifier = stat.modifier + amount
    end
    if state.caster and state.caster:isValid() then
        state.caster:sendEvent("SPerks_IllusionMindTheftDelta", {
            key = tostring(pself) .. ":" .. tostring(id),
            drains = state.drains,
            remove = true,
        })
    end
end

local function updateMindThefts(current)
    for id, state in pairs(mindThefts) do
        if not current[id] then
            reverseMindTheft(id, state)
            mindThefts[id] = nil
        end
    end
end

function MagicTarget.onUpdate(dt)
    pollTimer = pollTimer - dt
    if pollTimer > 0 then return end
    pollTimer = 0.1
    local current = activeSpellIds()
    if initialized then
        reportNewPlayerSpells(current)
    else
        seen = {}
        for key in pairs(current) do seen[key] = true end
        initialized = true
    end
    updateMindThefts(current)

    if poisonConsequence then
        poisonConsequence.remaining = poisonConsequence.remaining - 0.1
        poisonConsequence.tick = poisonConsequence.tick - 0.1
        if poisonConsequence.tick <= 0 and poisonConsequence.remaining > 0 then
            poisonConsequence.tick = 1
            poisonConsequence.stacks = math.min(
                poisonConsequence.cap,
                poisonConsequence.stacks + 1
            )
            local weakness = poisonConsequence.stacks * poisonConsequence.weakness
            local speed = poisonConsequence.stacks * poisonConsequence.speed
            types.Actor.activeEffects(pself):modify(
                weakness - poisonConsequence.appliedWeakness,
                "weaknesstomagicka"
            )
            types.Actor.activeEffects(pself):modify(
                -(speed - poisonConsequence.appliedSpeed),
                "fortifyattribute",
                "speed"
            )
            poisonConsequence.appliedWeakness = weakness
            poisonConsequence.appliedSpeed = speed
        elseif poisonConsequence.remaining <= -5 then
            types.Actor.activeEffects(pself):modify(
                -poisonConsequence.appliedWeakness,
                "weaknesstomagicka"
            )
            types.Actor.activeEffects(pself):modify(
                poisonConsequence.appliedSpeed,
                "fortifyattribute",
                "speed"
            )
            poisonConsequence = nil
        end
    end
end

local function applyMindTheft(data)
    if not data or not data.activeSpellId or mindThefts[data.activeSpellId] then return end
    local drains = {}
    for _, attribute in ipairs({ "strength", "endurance", "agility", "speed" }) do
        local stat = types.Actor.stats.attributes[attribute](pself)
        local amount = math.max(0, math.floor((stat.modified or 0) * 0.5))
        stat.modifier = stat.modifier - amount
        drains[attribute] = amount
    end
    mindThefts[data.activeSpellId] = { caster = data.caster, drains = drains }
    if data.caster and data.caster:isValid() then
        data.caster:sendEvent("SPerks_IllusionMindTheftDelta", {
            key = tostring(pself) .. ":" .. tostring(data.activeSpellId),
            drains = drains,
        })
    end
end

local function clearAlarm()
    if types.NPC.objectIsInstance(pself) then
        local alarm = types.Actor.stats.ai.alarm(pself)
        if alarm then alarm.base = 0 end
    end
end

local function staggerAttempt(data)
    data = data or {}
    local fatigue = types.Actor.stats.dynamic.fatigue(pself)
    local framework = interfaces.ErnPerkFramework
    if framework then
        framework.applyActorResourceDelta({
            actor=pself,resource="fatigue",
            operation=framework.RESOURCE_OPERATION.Damage,
            amount=math.max(0,data.drainAmount or 0),
            sourceEffect="SkillPerks_mysticism_d1",
            context={telekineticForce=true},
        })
    end
    if not data.isD2 then
        Stagger.forceStagger()
        return
    end
    local willpower = types.Actor.stats.attributes.willpower(pself).modified
    local maximum = math.max(fatigue.base + fatigue.modifier, 1)
    local factor = 0.2 + 0.8 * math.max(0, math.min(1, fatigue.current / maximum))
    local resist = math.max(0, math.min(1, 0.10 * (willpower / 10) * factor))
    if math.random() < resist then Stagger.forceStagger() else Stagger.forceKnockdown() end
end

local function setTether(data)
    tether = data
end

function MagicTarget.onDeath()
    if tether and tether.burst and tether.caster and tether.caster:isValid()
            and core.getSimulationTime() <= (tether.expiresAt or 0) then
        tether.caster:sendEvent("SPerks_MysticismSoulTetherBurst", {
            amount = math.ceil((tether.soulValue or 0) * 0.20),
        })
    end
    if destructionDrain and destructionDrain.caster
            and destructionDrain.caster:isValid()
            and core.getSimulationTime() <= (destructionDrain.expiresAt or 0) then
        local duration = math.max(1, destructionDrain.duration or 1)
        local remaining = math.max(0, destructionDrain.expiresAt - core.getSimulationTime())
        destructionDrain.caster:sendEvent("SPerks_DestructionDrainKillRefund", {
            amount = (destructionDrain.cost or 0)
                * math.min(1, remaining / duration)
                * (destructionDrain.refundRatio or 0),
        })
    end
end

local function confirmEcho(data)
    if echoed then return end
    echoed = true
    if data and data.caster and data.caster:isValid() then
        data.caster:sendEvent("SPerks_MysticismEchoConfirmed", { target = pself })
    end
end

-- Poison exposure owns its stacking debuffs on the poisoned actor, allowing
-- the player script to send one compact instruction instead of polling every
-- target for the effect's full duration.
local function startPoisonConsequence(data)
    data = data or {}
    if poisonConsequence then
        types.Actor.activeEffects(pself):modify(
            -poisonConsequence.appliedWeakness,
            "weaknesstomagicka"
        )
        types.Actor.activeEffects(pself):modify(
            poisonConsequence.appliedSpeed,
            "fortifyattribute",
            "speed"
        )
    end
    poisonConsequence = {
        remaining=math.max(1,tonumber(data.duration) or 1),
        tick=0, stacks=0, cap=math.max(1,tonumber(data.cap) or 10),
        weakness=math.max(0,tonumber(data.weakness) or 5),
        speed=math.max(0,tonumber(data.speed) or 5),
        appliedWeakness=0, appliedSpeed=0,
    }
end

local function setDestructionDrain(data)
    data = data or {}
    destructionDrain = {
        caster=data.caster,
        cost=math.max(0,tonumber(data.cost) or 0),
        duration=math.max(1,tonumber(data.duration) or 1),
        expiresAt=core.getSimulationTime()+math.max(1,tonumber(data.duration) or 1),
        refundRatio=math.max(0,tonumber(data.refundRatio) or 0),
    }
end

function MagicTarget.eventHandlers()
    return {
        SPerks_IllusionMindTheft = applyMindTheft,
        SPerks_IllusionClearAlarm = clearAlarm,
        SPerks_MysticismStaggerAttempt = staggerAttempt,
        SPerks_MysticismSetTether = setTether,
        SPerks_MysticismConfirmEcho = confirmEcho,
        SPerks_DestructionPoisonConsequence = startPoisonConsequence,
        SPerks_DestructionSetDrainKill = setDestructionDrain,
    }
end

return MagicTarget
