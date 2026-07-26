--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Restoration turns otherwise-wasted recovery into two explicit damage buffers.
The framework calculation pipeline reserves buffer at hit time, before the
remaining damage is committed to the actor.
]]

local interfaces = require("openmw.interfaces")
local core = require("openmw.core")
local types = require("openmw.types")
local self = require("openmw.self")
local ui = require("openmw.ui")

local Common = require("scripts.SkillPerks.magic.common")
local MagicDetection = require("scripts.SkillPerks.shared.magic_detection")
local WardHud = require("scripts.SkillPerks.hud.ward")
local settings = require("scripts.SkillPerks.Settings.settings")

settings.registerWardHudSettings()

local ids = Common.ids("restoration")
local states = {
    health={buffer=0,drain=0,window=0,idle=0},
    fatigue={buffer=0,drain=0,window=0,idle=0},
}
local updateTimer = 0
local clearMindTimer = 1
local debugState = {
    lastCast = nil,
    lastRestoreEffect = nil,
    lastSpellforgeEffect = nil,
}
local spellforgeSnapshots = {}
local spellforgeAuthorized = {}
local spellforgeInstantHandled = {}
local pendingSpellforgeCast = nil

local function rank(chain) return Common.rank(ids, chain) end
local function maximum(resource)
    local stat = types.Actor.stats.dynamic[resource](self)
    return math.max(0, (stat.base or 0) + (stat.modifier or 0))
end
local function cap(resource)
    local a = rank("A")
    if a == 0 or (resource == "fatigue" and a < 3) then return 0 end
    local fraction = a >= 4 and 1 or a >= 2 and 0.5 or 0.25
    return maximum(resource) * fraction
end
local function inflictionTime()
    local a = rank("A")
    return a >= 4 and 5 or a >= 2 and 3 or 2
end

--- Packages Restoration's live reserve values for its mod-owned HUD.
--- Available reserve and dissipating reserve remain separate so the player can
--- tell how much protection can answer the next hit.
local function getWardHudState()
    local a = rank("A")
    local healthCap = cap("health")
    local result = {
        enabled = a > 0 and healthCap > 0,
        health = {
            label = "Health",
            available = states.health.buffer,
            dissipating = states.health.drain,
            maximum = healthCap,
        },
    }
    if a >= 3 then
        result.fatigue = {
            label = "Fatigue",
            available = states.fatigue.buffer,
            dissipating = states.fatigue.drain,
            maximum = cap("fatigue"),
        }
    end
    return result
end

-- Overflow first cancels outstanding Drain, then becomes settled Buffer.
local function addOverflow(resource, amount)
    local state = states[resource]
    local allowed = cap(resource)
    if allowed <= 0 or amount <= 0 then return end
    local cancel = math.min(state.drain, amount)
    state.drain = state.drain - cancel
    amount = amount - cancel
    state.buffer = math.min(allowed, state.buffer + amount)
    state.idle = 0
end

local function bufferDamage(resource, incoming)
    local state = states[resource]
    if incoming <= 0 or state.buffer <= 0 or cap(resource) <= 0 then return incoming end
    local queued = incoming * 0.5
    local reserved = math.min(queued, state.buffer)
    state.buffer = state.buffer - reserved
    if state.drain <= 0 then state.window = inflictionTime() end
    state.drain = state.drain + reserved
    return incoming - reserved
end

local function registerBufferCalculation(resource,calculation)
    interfaces.ErnPerkFramework.registerCalculationHandler({
        id="SkillPerks_restoration_ward_" .. resource,
        calculation=calculation,
        operation=interfaces.ErnPerkFramework.CALCULATION_OPERATION.Modifier,
        priority=700,
        handler=function(data) return bufferDamage(resource, data.value) end,
    })
end
registerBufferCalculation("health",interfaces.ErnPerkFramework.CALCULATION.HIT_DAMAGE_HEALTH)
registerBufferCalculation("fatigue",interfaces.ErnPerkFramework.CALCULATION.HIT_DAMAGE_FATIGUE)

local ATTRIBUTE_LINK = {
    strength="health", endurance="health", intelligence="magicka",
    agility="fatigue", speed="fatigue", willpower="fatigue",
}
local attributeSessions = {}

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id="SkillPerks_restoration_linked_restore",
    skill="restoration", playerCastOnly=true,
    handler=function(event)
        local restoreEffects = {}
        for _, effect in ipairs(event.spell and event.spell.effects or {}) do
            if effect.id == "restorehealth" or effect.id == "restorefatigue" then
                table.insert(restoreEffects, {
                    id=effect.id,
                    magnitude=Common.averageMagnitude(effect),
                    duration=tonumber(effect.duration) or 0,
                    range=effect.range,
                })
            end
        end
        debugState.lastCast = {
            id=event.spell and event.spell.id or nil,
            name=event.spell and event.spell.name or nil,
            spellforge=MagicDetection.isSpellforgeRecord(event.spell),
            effectCount=#restoreEffects,
            effects=restoreEffects,
        }
        if debugState.lastCast.spellforge then
            pendingSpellforgeCast = {
                healthMissing=math.max(
                    0,
                    maximum("health") - types.Actor.stats.dynamic.health(self).current
                ),
                fatigueMissing=math.max(
                    0,
                    maximum("fatigue") - types.Actor.stats.dynamic.fatigue(self).current
                ),
                expires=core.getSimulationTime() + 3,
            }
        end

        local b = rank("B")
        if b == 0 or not event.spell then return end
        for _, effect in ipairs(event.spell.effects or {}) do
            if effect.id == "restoreattribute" and ATTRIBUTE_LINK[effect.affectedAttribute] then
                local attribute = effect.affectedAttribute
                local damaged = types.Actor.stats.attributes[attribute](self).damage or 0
                if damaged > 0 then
                    local magnitude = Common.averageMagnitude(effect)
                    local current = attributeSessions[attribute]
                    if not current or magnitude > current.magnitude then
                        attributeSessions[attribute] = {
                            resource=ATTRIBUTE_LINK[attribute], magnitude=magnitude,
                            ratio=b == 2 and 2 or 1, remaining=math.max(1,effect.duration or 1),
                            tick=1,
                        }
                    end
                end
            end
        end
    end,
})

local function playerRestorePerSecond(resource)
    local id = "restore" .. resource
    local total = 0
    local now = core.getSimulationTime()
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        local spellId = tostring(spell.id or "")
        local qualifies = Common.isPlayerCastActiveSpell(self, spell)
            or (spellforgeAuthorized[spellId] or 0) >= now
        local instantHandled = (spellforgeInstantHandled[spellId] or 0) >= now
        for _, effect in pairs(spell.effects or {}) do
            if effect.id == id then
                local source = MagicDetection.describeActiveSpellSource(self, spell)
                source.spellforgeAuthorized = (spellforgeAuthorized[spellId] or 0) >= now
                source.spellforgeInstantHandled = instantHandled
                source.effectId = effect.id
                source.magnitude = effect.magnitudeThisFrame
                source.duration = effect.duration
                source.durationLeft = effect.durationLeft
                debugState.lastRestoreEffect = source
                if qualifies and not instantHandled then
                    total = total + math.max(0, tonumber(effect.magnitudeThisFrame) or 0)
                end
            end
        end
    end
    return total
end

-- Restoration overflow has no direct engine callback, so this short poll
-- measures the full player-cast restore rate against the missing resource.
local function collectOverflow(dt)
    for _, resource in ipairs({"health","fatigue"}) do
        local rate = playerRestorePerSecond(resource)
        if rate > 0 and cap(resource) > 0 then
            local stat = types.Actor.stats.dynamic[resource](self)
            local missing = math.max(0, maximum(resource) - stat.current)
            local delivered = rate * dt
            addOverflow(resource, math.max(0, delivered - missing))
        end
    end
end

--- Remembers the exact amount missing immediately before Spell Framework Plus
--- applies a self-targeted Spellforge spell. Instant effects can disappear
--- before the normal active-spell poll, so this snapshot is required to
--- separate actual healing from Ward-generating overflow.
local function onSpellforgeMagicHit(data)
    data = data or {}
    if not data.spellId then return end
    local now = core.getSimulationTime()
    if pendingSpellforgeCast and pendingSpellforgeCast.expires >= now then
        spellforgeSnapshots[tostring(data.spellId)] = pendingSpellforgeCast
        return
    end
    spellforgeSnapshots[tostring(data.spellId)] = {
        healthMissing=math.max(0, tonumber(data.healthMissing) or 0),
        fatigueMissing=math.max(0, tonumber(data.fatigueMissing) or 0),
        expires=now + 1,
    }
end

--- Accepts SFP's confirmed application of a Spellforge effect. Duration
--- effects authorize the ordinary active-spell poll; instant restores are
--- resolved immediately from the pre-application snapshot because OpenMW may
--- remove them before the next player-script update.
local function onSpellforgeEffectApplied(data)
    data = data or {}
    local spellId = tostring(data.spellId or "")
    local effectId = tostring(data.effectId or ""):lower()
    local duration = math.max(0, tonumber(data.duration) or 0)
    local magnitude = math.max(0, tonumber(data.magnitude) or 0)
    local now = core.getSimulationTime()
    local snapshot = spellforgeSnapshots[spellId]
    if spellId == "" or not snapshot or snapshot.expires < now then
        return
    end

    spellforgeAuthorized[spellId] = now + math.max(1, duration + 0.5)
    debugState.lastSpellforgeEffect = {
        spellId = spellId,
        effectId = effectId,
        magnitude = magnitude,
        duration = duration,
        snapshotFound = true,
    }

    local resource = effectId == "restorehealth" and "health"
        or effectId == "restorefatigue" and "fatigue"
        or nil
    if not resource or duration > 0 then
        return
    end

    local missingKey = resource .. "Missing"
    local missing = math.max(0, tonumber(snapshot[missingKey]) or 0)
    local restored = math.min(missing, magnitude)
    snapshot[missingKey] = missing - restored
    addOverflow(resource, magnitude - restored)

    -- Suppress the polling fallback if OpenMW keeps this zero-duration effect
    -- visible for one frame; its full magnitude was already resolved above.
    spellforgeInstantHandled[spellId] = now + 0.5
end

local function updateStates(dt)
    for resource, state in pairs(states) do
        state.idle = state.idle + dt
        local allowed = cap(resource)
        state.buffer = math.min(state.buffer, allowed)
        if state.idle >= 10 and state.buffer > 0 then
            state.buffer = math.max(0, state.buffer - allowed * 0.05 * dt)
        end
        if state.drain > 0 and state.window > 0 then
            local faded = math.min(state.drain, state.drain / state.window * dt)
            state.drain = state.drain - faded
            state.window = math.max(0, state.window - dt)
            if state.drain < 0.01 then state.drain, state.window = 0, 0 end
        end
    end
end

local function updateAttributeSessions(dt)
    for attribute, session in pairs(attributeSessions) do
        session.remaining, session.tick = session.remaining - dt, session.tick - dt
        if session.tick <= 0 then
            session.tick = 1
            local damaged = types.Actor.stats.attributes[attribute](self).damage or 0
            local amount = math.min(damaged, session.magnitude) * session.ratio
            Common.restoreResource(self, session.resource, amount, ids["B" .. rank("B")])
        end
        if session.remaining <= 0 or (types.Actor.stats.attributes[attribute](self).damage or 0) <= 0 then
            attributeSessions[attribute] = nil
        end
    end
end

local function clearMind()
    local c = rank("C")
    if c == 0 then return end
    local health = types.Actor.stats.dynamic.health(self)
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    if health.current < maximum("health") or fatigue.current < maximum("fatigue") then return end
    local rate = 1
    if c == 2 then
        for _, resource in ipairs({"health","fatigue"}) do
            local state, allowed = states[resource], cap(resource)
            if allowed > 0 and state.buffer + state.drain > allowed * 0.5 then rate = rate + 1 end
        end
    end
    Common.restoreResource(self, "magicka", rate, ids["C" .. c])
end

local SWAP = {
    firedamage={resist="resistfire",reflect="frostdamage"},
    frostdamage={resist="resistfrost",reflect="firedamage"},
    shockdamage={resist="resistshock",reflect="poison"},
    poison={resist="resistpoison",reflect="shockdamage"},
    damagehealth={resist="resistmagicka",reflect="damagehealth"},
    drainhealth={resist="resistmagicka",reflect="damagehealth"},
    absorbhealth={resist="resistmagicka",reflect="damagehealth"},
}

interfaces.ErnPerkFramework.registerOnHitHandler({
    id="SkillPerks_restoration_warding_reprise", priority=675,
    handler=function(attack)
        if rank("D") == 0 or not attack.attacker or attack.attacker == self
                or not attack.attacker:isValid() or not attack.damage then return end
        if attack.target and attack.target ~= self then return end
        local reflected = {}
        for _, spell in pairs(types.Actor.activeSpells(self)) do
            if spell.caster == attack.attacker then
                for _, effect in pairs(spell.effects or {}) do
                    local swap = SWAP[effect.id]
                    if swap then
                        local resisted = math.max(0, Common.getEffectMagnitude(self, swap.resist))
                        local landed = math.max(0, tonumber(effect.magnitudeThisFrame) or 0)
                        if resisted > 0 and landed > 0 then
                            local amount = landed * math.min(resisted, 95) / math.max(100 - math.min(resisted,95), 5)
                            table.insert(reflected,{id=swap.reflect,magnitudeMin=amount,duration=1})
                        end
                    end
                end
            end
        end
        if rank("D") >= 2 and states.health.drain > 0 then
            table.insert(reflected,{id="damagehealth",magnitudeMin=math.min(states.health.drain,attack.damage.health or 0),duration=1})
        end
        Common.applyDynamicSpell(attack.attacker,self,"Warding Reprisal",reflected)
    end,
})

local function clear()
    states={health={buffer=0,drain=0,window=0,idle=0},fatigue={buffer=0,drain=0,window=0,idle=0}}
    attributeSessions={}
    spellforgeSnapshots={}
    spellforgeAuthorized={}
    spellforgeInstantHandled={}
    pendingSpellforgeCast=nil
    WardHud.forceUpdate(getWardHudState())
end

local function consolePrint(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

--- Reports the successful cast and active-effect sides of Ward collection.
--- Use after casting a Restore spell to diagnose generated-spell interop.
local function onConsoleCommand(mode, command)
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "luarest debug" then return end

    local cast = debugState.lastCast
    if cast then
        consolePrint("Restoration last cast:"
            .. " id=" .. tostring(cast.id)
            .. " name=" .. tostring(cast.name)
            .. " spellforge=" .. tostring(cast.spellforge)
            .. " restoreEffects=" .. tostring(cast.effectCount))
        for _, effect in ipairs(cast.effects or {}) do
            consolePrint("  cast effect:"
                .. " id=" .. tostring(effect.id)
                .. " magnitude=" .. tostring(effect.magnitude)
                .. " duration=" .. tostring(effect.duration)
                .. " range=" .. tostring(effect.range))
        end
    else
        consolePrint("Restoration last cast: none received by framework.")
    end

    local active = debugState.lastRestoreEffect
    if active then
        consolePrint("Restoration last active Restore effect:"
            .. " id=" .. tostring(active.id)
            .. " name=" .. tostring(active.name)
            .. " activeId=" .. tostring(active.activeSpellId)
            .. " caster=" .. tostring(active.caster)
            .. " casterIsPlayer=" .. tostring(active.casterIsActor)
            .. " item=" .. tostring(active.item)
            .. " recordFound=" .. tostring(active.recordFound)
            .. " recordType=" .. tostring(active.recordType)
            .. " recordName=" .. tostring(active.recordName))
        consolePrint("  source:"
            .. " known=" .. tostring(active.known)
            .. " spellforge=" .. tostring(active.spellforge)
            .. " sfpAuthorized=" .. tostring(active.spellforgeAuthorized)
            .. " sfpInstantHandled=" .. tostring(active.spellforgeInstantHandled)
            .. " qualifies=" .. tostring(active.qualifies)
            .. " effect=" .. tostring(active.effectId)
            .. " magnitude=" .. tostring(active.magnitude)
            .. " duration=" .. tostring(active.duration)
            .. " left=" .. tostring(active.durationLeft))
    else
        consolePrint("Restoration active Restore effect: none observed by Ward polling.")
    end
    local sfp = debugState.lastSpellforgeEffect
    if sfp then
        consolePrint("Restoration last Spellforge/SFP effect:"
            .. " spellId=" .. tostring(sfp.spellId)
            .. " effect=" .. tostring(sfp.effectId)
            .. " magnitude=" .. tostring(sfp.magnitude)
            .. " duration=" .. tostring(sfp.duration)
            .. " snapshot=" .. tostring(sfp.snapshotFound))
    else
        consolePrint("Restoration Spellforge/SFP effect: none relayed.")
    end
    consolePrint("Ward buffers:"
        .. " health=" .. tostring(states.health.buffer)
        .. " healthDrain=" .. tostring(states.health.drain)
        .. " fatigue=" .. tostring(states.fatigue.buffer)
        .. " fatigueDrain=" .. tostring(states.fatigue.drain))
end

local function onUpdate(dt)
    local now = core.getSimulationTime()
    for spellId, snapshot in pairs(spellforgeSnapshots) do
        if snapshot.expires < now then spellforgeSnapshots[spellId] = nil end
    end
    for spellId, expires in pairs(spellforgeAuthorized) do
        if expires < now then spellforgeAuthorized[spellId] = nil end
    end
    for spellId, expires in pairs(spellforgeInstantHandled) do
        if expires < now then spellforgeInstantHandled[spellId] = nil end
    end
    if pendingSpellforgeCast and pendingSpellforgeCast.expires < now then
        pendingSpellforgeCast = nil
    end
    collectOverflow(dt)
    updateStates(dt)
    updateAttributeSessions(dt)
    clearMindTimer=clearMindTimer-dt
    if clearMindTimer<=0 then
        clearMindTimer=1
        clearMind()
    end
    updateTimer = updateTimer + dt
    WardHud.update(getWardHudState())
end

Common.registerMagicPerks("restoration", "Restoration", ids, {
    A1={localizedName="Ward of Delay",localizedFlavour="No healing is wasted. What the flesh cannot take now waits faithfully at its threshold.",localizedDescription="Restore Health overflow fills a 25%-maximum Buffer. Half of incoming damage may be reserved and dissipated over 2 seconds.",onRemove=clear},
    A2={localizedName="Deep Reserve",localizedFlavour="Your ward learns patience enough to hold back wounds that would overwhelm a lesser blessing.",localizedDescription="Health Buffer cap rises to 50%; reserved damage dissipates over 3 seconds.",onRemove=clear},
    A3={localizedName="Second Reservoir",localizedFlavour="Breath and blood now answer to the same covenant of preservation.",localizedDescription="Restore Fatigue overflow gains an independent Buffer using the same rules.",onRemove=clear},
    A4={localizedName="Perfect Intercession",localizedFlavour="Your restoration stands between harm and consequence until the last possible moment.",localizedDescription="Both Buffer caps rise to 100%; reserved damage dissipates over 5 seconds.",onRemove=clear},
    B1={localizedName="Attribute-Linked Restoration",localizedFlavour="Mend the faculty and the strength it governs remembers how to flow.",localizedDescription="Restoring a damaged linked attribute also restores its Health, Magicka, or Fatigue at a 1:1 ratio.",onRemove=clear},
    B2={localizedName="Harmonic Recovery",localizedFlavour="One act of mending resonates through every part of the self that depended upon it.",localizedDescription="Linked dynamic-stat restoration rises to a 2:1 ratio.",onRemove=clear},
    C1={localizedName="Clear Mind",localizedFlavour="When body and breath are whole, magicka gathers in the silence between needs.",localizedDescription="At full Health and Fatigue, restore 1 Magicka per second.",onRemove=clear},
    C2={localizedName="Abundant Clarity",localizedFlavour="Every full ward becomes another still pool from which thought may drink.",localizedDescription="Each Ward of Delay Buffer above half capacity adds 1 more Magicka per second.",onRemove=clear},
    D1={localizedName="Warding Reprisal",localizedFlavour="A ward does not merely refuse hostile power. It teaches that power where it should have gone.",localizedDescription="Spell damage reduced by your resistances is reflected at its caster as a paired damage type.",onRemove=clear},
    D2={localizedName="Cushioned Vengeance",localizedFlavour="Even the wound caught inside your deepest reserve returns an answer.",localizedDescription="Damage caught by the Health Buffer also contributes direct reflected damage.",onRemove=clear},
})

return {
    eventHandlers={
        SPerks_SpellforgeMagicHit=onSpellforgeMagicHit,
        SPerks_SpellforgeEffectApplied=onSpellforgeEffectApplied,
    },
    engineHandlers={
        onUpdate=onUpdate,
        onConsoleCommand=onConsoleCommand,
        onSave=function() return {states=states,sessions=attributeSessions} end,
        onLoad=function(data)
            states=(data and data.states) or states
            attributeSessions=(data and data.sessions) or {}
            WardHud.forceUpdate(getWardHudState())
        end,
    },
}
