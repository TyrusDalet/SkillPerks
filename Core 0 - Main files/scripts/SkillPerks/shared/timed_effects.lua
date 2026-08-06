--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Reproduces simple temporary magic effects with actor-local stat writes. This
avoids creating permanent world records for effects whose behaviour does not
need the engine's spell resistance, reflection, absorption, VFX, or AI rules.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local TimedEffects = {}
local MAX_ACTIVE_EFFECTS = 256

local DYNAMIC_FORTIFY = {
    fortifyhealth = "health",
    fortifymagicka = "magicka",
    fortifyfatigue = "fatigue",
}

local RESOURCE_RESTORE = {
    restorehealth = "health",
    restoremagicka = "magicka",
    restorefatigue = "fatigue",
}

local NATIVE_ONLY = {
    absorbhealth=true,absorbmagicka=true,absorbattribute=true,absorbskill=true,
    commandcreature=true,commandhumanoid=true,disintegratearmor=true,
    disintegrateweapon=true,dispel=true,lock=true,mark=true,open=true,
    paralyze=true,recall=true,soultrap=true,
}

-- These continuous aggregate modifiers are safe to reproduce with
-- ActorActiveEffects.modify. Listing them explicitly avoids iterating the
-- engine-backed magic-effect record map, which is unsafe in OpenMW 0.51.
local SAFE_AGGREGATE_EFFECT = {
    blind = true,
    burden = true,
    sound = true,
}

local function needsNativeSpell(id,record)
    return NATIVE_ONLY[id]==true
        or id:find("^summon")~=nil
        or id:find("^bound")~=nil
        or (record and record.isAppliedOnce==true)
end

local function magnitude(effect)
    return tonumber(effect and (effect.magnitudeMin or effect.magnitude)) or 0
end

local function effectIdentity(effect)
    return table.concat({
        tostring(effect and effect.id or ""):lower(),
        tostring(effect and effect.affectedAttribute or ""):lower(),
        tostring(effect and effect.affectedSkill or ""):lower(),
    }, "|")
end

--- Creates an actor-local owner for temporary values.
--- The actor must be `openmw.self` in the script calling update/apply.
--- @param actor GameObject
--- @param sourceName string|nil External-modifier report label for player use.
function TimedEffects.new(actor,sourceName)
    local instances = {}
    local serial = 0

    local manager = {}

    local function activeCount()
        local count = 0
        for _ in pairs(instances) do count = count + 1 end
        return count
    end

    local function reportExternalModifiers()
        local framework=interfaces.ErnPerkFramework
        if not sourceName or not framework or not framework.reportExternalModifiers then return end
        local report={}
        for _,state in pairs(instances) do
            local id=state.effectId
            local statId
            local value
            if id=="fortifyattribute" or id=="fortifyskill" then
                statId=state.extraParam
                value=state.amount
            elseif id=="drainattribute" then
                statId=state.extraParam
                value=-state.amount
            elseif DYNAMIC_FORTIFY[id] then
                statId=DYNAMIC_FORTIFY[id]
                value=state.amount
            end
            if statId and value then report[statId]=(report[statId] or 0)+value end
        end
        local ok,errorMessage=pcall(
            framework.reportExternalModifiers,
            sourceName,
            next(report) and report or nil
        )
        if not ok then
            print("SkillPerks timed-effect modifier report failed ("
                ..tostring(sourceName).."): "..tostring(errorMessage))
        end
    end

    local function activeEffectDelta(effectId, extraParam, delta)
        local activeEffects = types.Actor.activeEffects(actor)
        if extraParam then
            activeEffects:modify(delta, effectId, extraParam)
        else
            activeEffects:modify(delta, effectId)
        end
    end

    --- Applies or reverses the persistent portion of one mimicked effect.
    local function writePersistent(state, direction)
        local id = state.effectId
        local amount = state.amount * direction
        if id == "fortifyattribute" then
            local getter = types.Actor.stats.attributes[state.extraParam]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier + amount
            return true
        elseif id == "drainattribute" then
            local getter = types.Actor.stats.attributes[state.extraParam]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier - amount
            return true
        elseif id == "fortifyskill" and types.NPC.objectIsInstance(actor) then
            local getter = types.NPC.stats.skills[state.extraParam]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier + amount
            return true
        end

        local resource = DYNAMIC_FORTIFY[id]
        if resource then
            local stat = types.Actor.stats.dynamic[resource](actor)
            stat.modifier = stat.modifier + amount
            local maximum = math.max(0, (tonumber(stat.base) or 0) + (tonumber(stat.modifier) or 0))
            if direction > 0 then
                stat.current = math.min(maximum, (tonumber(stat.current) or 0) + state.amount)
            else
                stat.current = math.min(tonumber(stat.current) or 0, maximum)
            end
            return true
        end

        -- Creature skills and ordinary magical modifiers are accurately
        -- represented by the actor's aggregate active-effect values.
        if id == "fortifyskill" then
            activeEffectDelta(id, state.extraParam, amount)
        else
            activeEffectDelta(id, state.extraParam, amount)
        end
        return true
    end

    --- Applies one permanent repair/damage operation that has no timed state.
    local function applyOnce(effect)
        local id = tostring(effect.id or ""):lower()
        local amount = math.max(0, magnitude(effect))
        local extra = effect.affectedAttribute or effect.affectedSkill
        if id == "restoreattribute" then
            local getter = types.Actor.stats.attributes[extra]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier + math.min(amount, math.max(0, -(tonumber(stat.modifier) or 0)))
            return true
        elseif id == "restoreskill" and types.NPC.objectIsInstance(actor) then
            local getter = types.NPC.stats.skills[extra]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier + math.min(amount, math.max(0, -(tonumber(stat.modifier) or 0)))
            return true
        elseif id == "damageattribute" then
            local getter = types.Actor.stats.attributes[extra]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier - amount
            return true
        elseif id == "damageskill" and types.NPC.objectIsInstance(actor) then
            local getter = types.NPC.stats.skills[extra]
            if not getter then return false end
            local stat = getter(actor)
            stat.modifier = stat.modifier - amount
            return true
        end
        return false
    end

    --- Returns whether a non-stacking logical key currently exists.
    function manager.isActive(key)
        return key ~= nil and instances[tostring(key)] ~= nil
    end

    --- Removes one named temporary effect and reverses exactly its contribution.
    --- @param key string Logical key supplied when the effect was applied.
    --- @return boolean removed True when an active effect was found.
    function manager.clear(key)
        key=tostring(key or "")
        local state=instances[key]
        if not state then return false end
        if not state.restoreResource then writePersistent(state,-1) end
        instances[key]=nil
        reportExternalModifiers()
        return true
    end

    --- Applies one effect without creating a spell record.
    --- Returns false only when the effect needs native spell semantics.
    function manager.apply(effect, options)
        effect = effect or {}
        options = options or {}
        local id = tostring(effect.id or ""):lower()
        local amount = magnitude(effect)
        if id == "" or amount == 0 then return false, "empty effect" end

        if applyOnce(effect) then return true, "applied once" end

        local isRestore = RESOURCE_RESTORE[id] ~= nil
        local effectRecord=core.magic.effects.records[id]
        local isSupported = isRestore
            or id == "fortifyattribute" or id == "drainattribute"
            or id == "fortifyskill" or DYNAMIC_FORTIFY[id] ~= nil
            or SAFE_AGGREGATE_EFFECT[id] == true
            or (effectRecord ~= nil and not needsNativeSpell(id,effectRecord))
        if not isSupported then return false, "unsupported effect" end

        local logicalKey = tostring(options.key or effectIdentity(effect))
        local key = logicalKey
        if options.stackable == true then
            serial = serial + 1
            key = logicalKey .. "#" .. tostring(serial)
        elseif instances[key] then
            return false, "already active"
        end
        if activeCount() >= MAX_ACTIVE_EFFECTS then
            return false, "active effect limit reached"
        end

        local duration = math.max(0.01, tonumber(effect.duration) or 1)
        local state = {
            amount = amount,
            effectId = id,
            expiresAt = core.getSimulationTime() + duration,
            extraParam = effect.affectedAttribute or effect.affectedSkill,
            logicalKey = logicalKey,
            restoreResource = RESOURCE_RESTORE[id],
            restoreAccumulator = 0,
            sourceEffect = options.sourceEffect,
        }
        instances[key] = state
        if not isRestore and not writePersistent(state, 1) then
            instances[key] = nil
            return false, "stat is unavailable"
        end
        reportExternalModifiers()
        return true, key
    end

    --- Replaces a named effect's total magnitude and refreshes its duration.
    --- This is used by perks whose stacks share one timer. Passing magnitude
    --- zero clears the contribution without manufacturing a spell record.
    function manager.set(effect,options)
        effect=effect or {}
        options=options or {}
        local key=tostring(options.key or effectIdentity(effect))
        if magnitude(effect)==0 then
            manager.clear(key)
            return true,"cleared"
        end
        manager.clear(key)
        options.key=key
        options.stackable=false
        return manager.apply(effect,options)
    end

    --- Advances periodic restores and reverses expired temporary modifiers.
    function manager.update(dt)
        local now = core.getSimulationTime()
        local reportChanged = false
        for key, state in pairs(instances) do
            if state.restoreResource and now < state.expiresAt then
                state.restoreAccumulator = (state.restoreAccumulator or 0) + dt
                if state.restoreAccumulator >= 0.1 then
                    local elapsed = state.restoreAccumulator
                    state.restoreAccumulator = 0
                    local framework = interfaces.ErnPerkFramework
                    if framework then
                        framework.applyActorResourceDelta({
                            actor = actor,
                            resource = state.restoreResource,
                            operation = framework.RESOURCE_OPERATION.Restore,
                            amount = state.amount * elapsed,
                            source = actor,
                            sourceEffect = state.sourceEffect,
                            context = { mimickedSpellEffect = true },
                        })
                    end
                end
            end
            if now >= state.expiresAt then
                if not state.restoreResource then writePersistent(state, -1) end
                instances[key] = nil
                reportChanged = true
            end
        end
        if reportChanged then reportExternalModifiers() end
    end

    function manager.count()
        return activeCount()
    end

    function manager.snapshot()
        if next(instances) == nil then return nil end
        return { instances = instances, serial = serial }
    end

    --- Restores bookkeeping only: actor values themselves already persist.
    function manager.restore(data)
        data = data or {}
        instances = data.instances or {}
        serial = tonumber(data.serial) or 0
        manager.update(0)
        reportExternalModifiers()
    end

    return manager
end

return TimedEffects
