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

local function effectMaximum(effect)
    return math.max(0, tonumber(
        effect and (
            effect.maxMagnitude or effect.magnitudeMax
            or effect.magnitude or effect.magnitudeMin or effect.minMagnitude
        )
    ) or 0)
end

local function normalizeEffectIds(effectIds)
    local requested = {}
    for _, effectId in ipairs(effectIds or {}) do
        requested[tostring(effectId):lower()] = true
    end
    return requested
end

--- Creates a cache of player-cast spell records that can be checked later via
--- activeSpells:isSpellActive(id). This avoids repeated pairs(activeSpells)
--- iteration in hot polling paths, which has caused native OpenMW crashes.
--- @param effectIds table Array of lowercase magic-effect IDs to track.
--- @return table cache Tracked-spell cache with track/snapshot helpers.
function Common.newTrackedSpellCache(effectIds)
    local requested = normalizeEffectIds(effectIds)
    local trackedSpells = {}

    local cache = {}

    function cache.track(spell)
        if not spell or spell.id == nil then return false end
        local tracked = { id = tostring(spell.id), effects = {} }
        for _, effect in pairs(spell.effects or {}) do
            local effectId = tostring(effect.id or ""):lower()
            if requested[effectId] then
                local state = tracked.effects[effectId]
                if not state then
                    state = { present = true, maximum = 0 }
                    tracked.effects[effectId] = state
                end
                state.maximum = state.maximum + effectMaximum(effect)
            end
        end
        if next(tracked.effects) == nil then return false end
        trackedSpells[tracked.id] = tracked
        return true
    end

    function cache.snapshot(actor, wantedEffectIds)
        local wanted = wantedEffectIds and normalizeEffectIds(wantedEffectIds) or requested
        local result = {}
        for effectId in pairs(wanted) do
            result[effectId] = { magnitude = 0, present = false, maximum = 0 }
        end
        local diagnostics = {
            qualifyingSpells = 0,
            scannedSpells = 0,
            expiredSpells = 0,
            failedChecks = 0,
        }
        local activeSpells = types.Actor.activeSpells(actor)
        local expired = {}
        for spellId, tracked in pairs(trackedSpells) do
            diagnostics.scannedSpells = diagnostics.scannedSpells + 1
            local ok, active = pcall(activeSpells.isSpellActive, activeSpells, spellId)
            if not ok then
                diagnostics.failedChecks = diagnostics.failedChecks + 1
            elseif active then
                diagnostics.qualifyingSpells = diagnostics.qualifyingSpells + 1
                for effectId, state in pairs(tracked.effects or {}) do
                    local aggregate = result[effectId]
                    if aggregate then
                        aggregate.present = true
                        aggregate.maximum = aggregate.maximum
                            + math.max(0, tonumber(state.maximum) or 0)
                    end
                end
            else
                expired[#expired + 1] = spellId
            end
        end
        for _, spellId in ipairs(expired) do
            trackedSpells[spellId] = nil
            diagnostics.expiredSpells = diagnostics.expiredSpells + 1
        end
        for effectId, state in pairs(result) do
            if state.present and state.maximum > 0 then
                state.magnitude = math.min(
                    state.maximum,
                    math.max(0, Common.getEffectMagnitude(actor, effectId))
                )
            end
            state.maximum = nil
        end
        return result, diagnostics
    end

    function cache.magnitude(actor, effectId, extraParam)
        local snapshot = cache.snapshot(actor, { effectId })
        local state = snapshot[tostring(effectId):lower()]
        if not state or not state.present then return 0 end
        if extraParam ~= nil then
            return Common.getEffectMagnitude(actor, effectId, extraParam)
        end
        return state.magnitude or 0
    end

    function cache.has(actor, effectId, extraParam)
        local snapshot = cache.snapshot(actor, { effectId })
        local state = snapshot[tostring(effectId):lower()]
        if not state or not state.present then return false end
        if extraParam ~= nil then
            local effects = types.Actor.activeEffects(actor)
            local ok, effect = pcall(effects.getEffect, effects, effectId, extraParam)
            return ok and effect ~= nil
        end
        return true
    end

    function cache.snapshotData()
        return trackedSpells
    end

    function cache.restore(saved)
        trackedSpells = {}
        for spellId, entry in pairs(saved or {}) do
            local restored = { id = tostring(spellId), effects = {} }
            for effectId, state in pairs(entry and entry.effects or {}) do
                effectId = tostring(effectId):lower()
                if requested[effectId] then
                    restored.effects[effectId] = {
                        present = true,
                        maximum = math.max(0, tonumber(state and state.maximum) or 0),
                    }
                end
            end
            if next(restored.effects) ~= nil then
                trackedSpells[restored.id] = restored
            end
        end
    end

    function cache.count()
        return SkillDebug.count(trackedSpells)
    end

    return cache
end

--- Collects several qualifying player-cast effects in one active-spell pass.
--- School scripts should use this when they need multiple effect values at
--- once; repeatedly traversing OpenMW's live ActiveSpells collection during
--- the same update is both expensive and unsafe while spells are changing.
--- @param actor GameObject
--- @param effectIds table Array of lowercase magic-effect IDs.
--- @param tracker table|nil Optional Common.newTrackedSpellCache instance.
--- @return table effects Values keyed by effect ID.
--- @return table diagnostics Numbers of live and qualifying spells inspected.
function Common.playerSpellEffectSnapshot(actor,effectIds,tracker)
    if tracker and tracker.snapshot then
        return tracker.snapshot(actor,effectIds)
    end
    local requested={}
    local result={}
    for _,effectId in ipairs(effectIds or {}) do
        effectId=tostring(effectId):lower()
        requested[effectId]=true
        result[effectId]={
            magnitude=Common.getEffectMagnitude(actor,effectId),
            present=Common.getEffectMagnitude(actor,effectId)>0,
        }
    end
    return result,{qualifyingSpells=0,scannedSpells=0,untrackedFallback=true}
end

function Common.playerSpellEffectMagnitude(actor, effectId, extraParam, tracker)
    if tracker and tracker.magnitude then
        return tracker.magnitude(actor,effectId,extraParam)
    end
    return Common.getEffectMagnitude(actor,effectId,extraParam)
end

--- Tests for a qualifying player-cast effect by presence rather than numeric
--- magnitude. Effects such as Water Breathing have no magnitude and therefore
--- legitimately report zero even while active.
--- @param actor GameObject Actor whose active spells are inspected.
--- @param effectId string Magic effect id.
--- @param extraParam string|nil Optional affected attribute or skill.
--- @param tracker table|nil Optional Common.newTrackedSpellCache instance.
--- @return boolean active
function Common.hasPlayerSpellEffect(actor, effectId, extraParam, tracker)
    if tracker and tracker.has then
        return tracker.has(actor,effectId,extraParam)
    end
    local effects = types.Actor.activeEffects(actor)
    local ok, effect
    if extraParam ~= nil then
        ok, effect = pcall(effects.getEffect, effects, effectId, extraParam)
    else
        ok, effect = pcall(effects.getEffect, effects, effectId)
    end
    return ok and effect ~= nil
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
