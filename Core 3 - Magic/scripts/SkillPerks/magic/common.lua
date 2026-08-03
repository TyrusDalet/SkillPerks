--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Shared Core 3 registration and magic-effect helpers. School scripts keep
their own state; this module owns only patterns every Magic tree repeats.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local ns = require("scripts.SkillPerks.namespace")
local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local SkillDebug = require("scripts.SkillPerks.shared.debug")
local MagicConstellations = require("scripts.SkillPerks.constellations.magic")
local MagicDetection = require("scripts.SkillPerks.shared.magic_detection")

local Common = {}
local dynamicSpellRequestSerial = 0
local SLOT_ORDER = { "A1", "A2", "A3", "A4", "B1", "B2", "C1", "C2", "D1", "D2" }
local SLOT_MENU_ORDER = {
    A1 = 1, A2 = 2, A3 = 3, A4 = 4,
    B1 = 5, B2 = 6, C1 = 7, D1 = 8, C2 = 9, D2 = 10,
}

function Common.ids(skill)
    local ids = {}
    for _, slot in ipairs(SLOT_ORDER) do
        ids[slot] = ns .. "_" .. skill .. "_" .. slot:lower()
    end
    return ids
end

function Common.hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id) == true
end

function Common.rank(ids, chain)
    if chain == "A" then
        for rank = 4, 1, -1 do
            if Common.hasPerk(ids["A" .. rank]) then return rank end
        end
        return 0
    end
    if Common.hasPerk(ids[chain .. "2"]) then return 2 end
    if Common.hasPerk(ids[chain .. "1"]) then return 1 end
    return 0
end

function Common.averageMagnitude(effect)
    local minimum = tonumber(effect and (effect.minMagnitude or effect.magnitudeMin)) or 0
    local maximum = tonumber(effect and (effect.maxMagnitude or effect.magnitudeMax)) or minimum
    return (minimum + maximum) * 0.5
end

function Common.getEffectMagnitude(actor, effectId, extraParam)
    local effects = types.Actor.activeEffects(actor)
    local ok, effect
    if extraParam ~= nil then
        ok, effect = pcall(effects.getEffect, effects, effectId, extraParam)
    else
        ok, effect = pcall(effects.getEffect, effects, effectId)
    end
    return ok and effect and tonumber(effect.magnitude) or 0
end

--- Collects several qualifying player-cast effects in one active-spell pass.
--- School scripts should use this when they need multiple effect values at
--- once; repeatedly traversing OpenMW's live ActiveSpells collection during
--- the same update is both expensive and unsafe while spells are changing.
--- @param actor GameObject
--- @param effectIds table Array of lowercase magic-effect IDs.
--- @return table effects Values keyed by effect ID.
--- @return table diagnostics Numbers of live and qualifying spells inspected.
function Common.playerSpellEffectSnapshot(actor,effectIds)
    local requested={}
    local result={}
    for _,effectId in ipairs(effectIds or {}) do
        effectId=tostring(effectId):lower()
        requested[effectId]=true
        result[effectId]={magnitude=0,present=false}
    end

    local diagnostics={qualifyingSpells=0,scannedSpells=0}
    for _,spell in pairs(types.Actor.activeSpells(actor)) do
        diagnostics.scannedSpells=diagnostics.scannedSpells+1
        if MagicDetection.isPlayerCastActiveSpell(actor,spell) then
            diagnostics.qualifyingSpells=diagnostics.qualifyingSpells+1
            for _,effect in pairs(spell.effects or {}) do
                local effectId=tostring(effect.id or ""):lower()
                local state=requested[effectId] and result[effectId] or nil
                if state then
                    state.present=true
                    state.magnitude=state.magnitude
                        +(tonumber(effect.magnitudeThisFrame) or 0)
                end
            end
        end
    end
    return result,diagnostics
end

function Common.playerSpellEffectMagnitude(actor, effectId, extraParam)
    local total = 0
    for _, spell in pairs(types.Actor.activeSpells(actor)) do
        if MagicDetection.isPlayerCastActiveSpell(actor, spell) then
            for _, effect in pairs(spell.effects or {}) do
                if effect.id == effectId
                        and (extraParam == nil
                            or effect.affectedAttribute == extraParam
                            or effect.affectedSkill == extraParam) then
                    total = total + (tonumber(effect.magnitudeThisFrame) or 0)
                end
            end
        end
    end
    return total
end

--- Tests for a qualifying player-cast effect by presence rather than numeric
--- magnitude. Effects such as Water Breathing have no magnitude and therefore
--- legitimately report zero even while active.
--- @param actor GameObject Actor whose active spells are inspected.
--- @param effectId string Magic effect id.
--- @param extraParam string|nil Optional affected attribute or skill.
--- @return boolean active
function Common.hasPlayerSpellEffect(actor, effectId, extraParam)
    for _, spell in pairs(types.Actor.activeSpells(actor)) do
        if MagicDetection.isPlayerCastActiveSpell(actor, spell) then
            for _, effect in pairs(spell.effects or {}) do
                if effect.id == effectId
                        and (extraParam == nil
                            or effect.affectedAttribute == extraParam
                            or effect.affectedSkill == extraParam) then
                    return true
                end
            end
        end
    end
    return false
end

--- Shared source policy for school scripts handling target-landed effects.
--- Item-source exceptions should remain explicit in the owning perk.
function Common.isPlayerCastLandedSpell(data)
    return MagicDetection.isPlayerCastLandedSpell(data)
end

--- Shared source policy for school scripts polling the player's active magic.
function Common.isPlayerCastActiveSpell(actor, activeSpell)
    return MagicDetection.isPlayerCastActiveSpell(actor, activeSpell)
end

--- Exposes the shared source decision for school-specific diagnostics.
function Common.describeActiveSpellSource(actor, activeSpell)
    return MagicDetection.describeActiveSpellSource(actor, activeSpell)
end

--- Cast-window helper for selected spells that have not landed yet.
function Common.actorKnowsCastableSpell(actor, spell)
    return MagicDetection.actorKnowsCastableSpell(actor, spell)
end

function Common.dynamicRatio(actor, resource)
    local stat = types.Actor.stats.dynamic[resource](actor)
    local maximum = math.max((stat.base or 0) + (stat.modifier or 0), 1)
    return math.max(0, math.min(1, (stat.current or maximum) / maximum))
end

function Common.restoreResource(actor, resource, amount, sourceEffect)
    amount = math.max(0, tonumber(amount) or 0)
    if amount <= 0 then return 0 end
    return interfaces.ErnPerkFramework.applyActorResourceDelta({
        actor = actor,
        resource = resource,
        operation = interfaces.ErnPerkFramework.RESOURCE_OPERATION.Restore,
        amount = amount,
        source = actor,
        sourceEffect = sourceEffect,
        context = { school = "Magic", perk = sourceEffect },
    })
end

function Common.applyDynamicSpell(target, caster, name, effects, options)
    if not target or not target:isValid() or not effects or #effects == 0 then
        return false
    end
    options = options or {}
    local traceSkill = options.traceSkill
    if traceSkill == nil then
        local normalized=tostring(name or ""):lower()
        if normalized:find("alchemical",1,true) or normalized:find("raw ingestion",1,true) then traceSkill="alchemy"
        elseif normalized:find("burden",1,true) or normalized:find("kinetic",1,true) then traceSkill="alteration"
        elseif normalized:find("servant",1,true) then traceSkill="conjuration"
        elseif normalized:find("enchant",1,true) then traceSkill="enchant"
        elseif normalized:find("devotion",1,true) then traceSkill="illusion"
        elseif normalized:find("tether",1,true) then traceSkill="mysticism"
        elseif normalized:find("element",1,true) or normalized:find("drain mastery",1,true)
                or normalized:find("frozen finish",1,true) then traceSkill="destruction"
        elseif normalized:find("reprisal",1,true) then traceSkill="restoration" end
    end
    dynamicSpellRequestSerial=dynamicSpellRequestSerial+1
    local requestId="SkillPerks_MagicSpell_"..tostring(dynamicSpellRequestSerial)
    local traced=traceSkill~=nil
        and SkillDebug.isTraceEnabled(traceSkill)
        and SkillDebug.isVerbosityEnabled(3)
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = caster,
        spellName = name,
        effects = effects,
        preferredSpellId = options.preferredSpellId,
        activeSpellOptions = options,
        requestId = requestId,
        resultTarget = traced and caster or nil,
        resultEvent = traced and "SPerks_MagicSpellApplicationResult" or nil,
        traceSkill = traceSkill,
        traceEffect = name,
    })
    return true,requestId
end

function Common.effectIndexList(spell, predicate)
    local indices = {}
    for index, effect in ipairs(spell and spell.effects or {}) do
        if predicate(effect) then table.insert(indices, index - 1) end
    end
    return indices
end

function Common.skillUseType(event)
    return event and event.params and event.params.useType
end

function Common.useType(name)
    local progression = interfaces.SkillProgression
    return progression and progression.SKILL_USE_TYPES
        and progression.SKILL_USE_TYPES[name] or nil
end

function Common.isUseType(event, name)
    local expected = Common.useType(name)
    return expected ~= nil and Common.skillUseType(event) == expected
end

function Common.registerMagicPerks(skillId, skillName, ids, entries)
    MagicConstellations.register(skillName)
    for _, slot in ipairs(SLOT_ORDER) do
        local entry = entries[slot]
        if entry then
            local requirements = ChainRequirements.forSlot(skillId, ids, slot)
            interfaces.ErnPerkFramework.registerPerk({
                id = ids[slot],
                localizedName = entry.localizedName,
                localizedFlavour = entry.localizedFlavour,
                localizedDescription = entry.localizedDescription,
                category = ChainRequirements.category("Magic", skillName, SLOT_MENU_ORDER[slot]),
                art = entry.art or "textures\\levelup\\mage",
                requirements = requirements,
                onAdd = SkillDebug.wrapCallback(skillId, slot .. " applied/resynced", entry.onAdd),
                onRemove = SkillDebug.wrapCallback(skillId, slot .. " removed", entry.onRemove),
            })
        end
    end
end

return Common
