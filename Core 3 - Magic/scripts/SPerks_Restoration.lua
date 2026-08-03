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
local SkillDebug = require("scripts.SkillPerks.shared.debug")

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
    local trace=SkillDebug.beginTrace("restoration","Ward of Delay","restore overflow observed",{
        amount = amount,
        bufferBefore=state.buffer,
        cap = allowed,
        drainBefore=state.drain,
        resource = resource,
    })
    if allowed <= 0 then return trace:reject("resource has no active Ward capacity") end
    if amount <= 0 then return trace:reject("restore produced no overflow") end
    local cancel = math.min(state.drain, amount)
    state.drain = state.drain - cancel
    amount = amount - cancel
    state.buffer = math.min(allowed, state.buffer + amount)
    state.idle = 0
    trace:finish("overflow stored",{
        bufferAfter=state.buffer,cancelledDrain=cancel,drainAfter=state.drain,
        overflowStored=amount,
    })
end

-- Reserves up to half of one incoming resource hit and records the exact
-- Health amount caught on the shared attack payload. Warding Reprisal reads
-- that value after every calculation has resolved, so unrelated mitigation
-- cannot be mistaken for Ward absorption.
local function bufferDamage(resource, incoming, calculationData)
    local state = states[resource]
    local trace=SkillDebug.beginTrace("restoration","Ward of Delay","incoming damage calculation",{
        buffer = state.buffer,
        cap=cap(resource),
        incoming = incoming,
        resource = resource,
    })
    if incoming <= 0 then trace:reject("incoming damage is zero") return incoming end
    if state.buffer <= 0 then trace:reject("Ward buffer is empty") return incoming end
    if cap(resource) <= 0 then trace:reject("resource has no active Ward capacity") return incoming end
    local queued = incoming * 0.5
    local reserved = math.min(queued, state.buffer)
    state.buffer = state.buffer - reserved
    if state.drain <= 0 then state.window = inflictionTime() end
    state.drain = state.drain + reserved
    if resource == "health" and calculationData and type(calculationData.context) == "table" then
        local attack = calculationData.context
        attack.skillPerksRestorationWardAbsorbedHealth =
            (tonumber(attack.skillPerksRestorationWardAbsorbedHealth) or 0) + reserved
    end
    local remaining=incoming-reserved
    trace:finish("damage reserved",{
        bufferAfter=state.buffer,drainAfter=state.drain,inflictionWindow=state.window,
        maximumReservation=queued,remainingDamage=remaining,reserved=reserved,
    })
    return remaining
end

local function registerBufferCalculation(resource,calculation)
    interfaces.ErnPerkFramework.registerCalculationHandler({
        id="SkillPerks_restoration_ward_" .. resource,
        calculation=calculation,
        operation=interfaces.ErnPerkFramework.CALCULATION_OPERATION.Modifier,
        priority=700,
        direction=interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
        handler=function(data) return bufferDamage(resource, data.value, data) end,
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
        local trace=SkillDebug.beginTrace("restoration","Restoration cast","Restoration skill-use event",{
            cost = event and event.cost,
            spell = event and event.spell and event.spell.id,
        })
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
        trace:step("restore effects catalogued",{
            effectCount=#restoreEffects,spellforge=debugState.lastCast.spellforge,
        })
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
            trace:step("Spellforge pre-application snapshot captured",pendingSpellforgeCast)
        end

        local b = rank("B")
        if b == 0 then
            return trace:finish("cast recorded; linked restoration inactive",{bRank=b})
        end
        if not event.spell then return trace:reject("skill-use event has no spell") end
        local sessionsAdded=0
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
                        sessionsAdded=sessionsAdded+1
                        trace:step("attribute-linked session stored",{
                            attribute=attribute,damaged=damaged,duration=math.max(1,effect.duration or 1),
                            magnitude=magnitude,ratio=b==2 and 2 or 1,
                            resource=ATTRIBUTE_LINK[attribute],
                        })
                    end
                end
            end
        end
        trace:finish("cast processing complete",{attributeSessionsAdded=sessionsAdded,bRank=b})
    end,
})

--- Scans active magic once for both Ward resources. This remains a frame-level
--- poll because continuous healing must stop Ward decay immediately, but it
--- avoids traversing the ActiveSpells collection separately for each resource.
local function playerRestoreRates()
    local rates = {health=0,fatigue=0}
    local now = core.getSimulationTime()
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        local spellId = tostring(spell.id or "")
        local qualifies = Common.isPlayerCastActiveSpell(self, spell)
            or (spellforgeAuthorized[spellId] or 0) >= now
        local instantHandled = (spellforgeInstantHandled[spellId] or 0) >= now
        for _, effect in pairs(spell.effects or {}) do
            local resource = effect.id == "restorehealth" and "health"
                or effect.id == "restorefatigue" and "fatigue" or nil
            if resource then
                local source = MagicDetection.describeActiveSpellSource(self, spell)
                source.spellforgeAuthorized = (spellforgeAuthorized[spellId] or 0) >= now
                source.spellforgeInstantHandled = instantHandled
                source.effectId = effect.id
                source.magnitude = effect.magnitudeThisFrame
                source.duration = effect.duration
                source.durationLeft = effect.durationLeft
                source.qualifies = qualifies
                debugState.lastRestoreEffect = source
                if qualifies and not instantHandled then
                    rates[resource] = rates[resource]
                        + math.max(0, tonumber(effect.magnitudeThisFrame) or 0)
                end
            end
        end
    end
    SkillDebug.traceState("restoration","Ward restore-source poll","restore-source",{
        activeSpell=debugState.lastRestoreEffect and debugState.lastRestoreEffect.activeSpellId,
        qualifies=debugState.lastRestoreEffect and debugState.lastRestoreEffect.qualifies,
        fatiguePerSecond=rates.fatigue,
        healthPerSecond=rates.health,
    })
    return rates
end

-- Restoration overflow has no direct engine callback, so this short poll
-- measures the full player-cast restore rate against the missing resource.
local function collectOverflow(dt)
    local a=rank("A")
    if a<=0 then return end
    local rates=playerRestoreRates()
    local resources=a>=3 and {"health","fatigue"} or {"health"}
    for _, resource in ipairs(resources) do
        local rate = rates[resource]
        if rate > 0 and cap(resource) > 0 then
            local stat = types.Actor.stats.dynamic[resource](self)
            local missing = math.max(0, maximum(resource) - stat.current)
            local delivered = rate * dt
            local overflow=math.max(0,delivered-missing)
            local trace=SkillDebug.beginTrace("restoration","Ward overflow collection","restore poll tick",{
                cap=cap(resource),delivered=delivered,dt=dt,missing=missing,
                overflow=overflow,rate=rate,resource=resource,
            })
            if overflow>0 then
                addOverflow(resource,overflow)
                trace:finish("overflow forwarded to Ward")
            else
                trace:reject("restore was consumed by missing resource")
            end
        end
    end
end

--- Remembers the exact amount missing immediately before Spell Framework Plus
--- applies a self-targeted Spellforge spell. Instant effects can disappear
--- before the normal active-spell poll, so this snapshot is required to
--- separate actual healing from Ward-generating overflow.
local function onSpellforgeMagicHit(data)
    data = data or {}
    local trace=SkillDebug.beginTrace("restoration","Spellforge bridge","magic-hit event",{
        spell = data.spellId,
    })
    if not data.spellId then return trace:reject("event has no spell id") end
    local now = core.getSimulationTime()
    if pendingSpellforgeCast and pendingSpellforgeCast.expires >= now then
        spellforgeSnapshots[tostring(data.spellId)] = pendingSpellforgeCast
        return trace:finish("pending cast snapshot matched",pendingSpellforgeCast)
    end
    spellforgeSnapshots[tostring(data.spellId)] = {
        healthMissing=math.max(0, tonumber(data.healthMissing) or 0),
        fatigueMissing=math.max(0, tonumber(data.fatigueMissing) or 0),
        expires=now + 1,
    }
    trace:finish("event fallback snapshot stored",spellforgeSnapshots[tostring(data.spellId)])
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
    local trace=SkillDebug.beginTrace("restoration","Spellforge bridge","effect-applied event",{
        duration = duration,
        effect = effectId,
        magnitude = magnitude,
        snapshot = snapshot ~= nil,
        spell = spellId,
    })
    if spellId == "" or not snapshot or snapshot.expires < now then
        return trace:reject("no live pre-application snapshot",{
            now=now,snapshotExpires=snapshot and snapshot.expires,
        })
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
        return trace:finish("duration effect authorized for active-spell polling",{
            authorizationExpires=spellforgeAuthorized[spellId],resource=resource,
        })
    end

    local missingKey = resource .. "Missing"
    local missing = math.max(0, tonumber(snapshot[missingKey]) or 0)
    local restored = math.min(missing, magnitude)
    snapshot[missingKey] = missing - restored
    addOverflow(resource, magnitude - restored)

    -- Suppress the polling fallback if OpenMW keeps this zero-duration effect
    -- visible for one frame; its full magnitude was already resolved above.
    spellforgeInstantHandled[spellId] = now + 0.5
    trace:finish("instant restore resolved",{
        missingBefore=missing,overflow=magnitude-restored,resource=resource,
        restored=restored,suppressionExpires=spellforgeInstantHandled[spellId],
    })
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
        SkillDebug.traceState("restoration","Ward state","ward-state-"..resource,{
            buffer=state.buffer,cap=allowed,drain=state.drain,idle=state.idle,
            resource=resource,window=state.window,
        })
    end
end

local function updateAttributeSessions(dt)
    for attribute, session in pairs(attributeSessions) do
        session.remaining, session.tick = session.remaining - dt, session.tick - dt
        if session.tick <= 0 then
            session.tick = 1
            local damaged = types.Actor.stats.attributes[attribute](self).damage or 0
            local amount = math.min(damaged, session.magnitude) * session.ratio
            local trace=SkillDebug.beginTrace("restoration","Attribute-Linked Restoration","session tick",{
                attribute=attribute,damaged=damaged,magnitude=session.magnitude,
                ratio=session.ratio,remaining=session.remaining,resource=session.resource,
            })
            local resolved=Common.restoreResource(self,session.resource,amount,ids["B"..rank("B")])
            trace:finish("linked resource restored",{requested=amount,resolved=resolved})
        end
        if session.remaining <= 0 or (types.Actor.stats.attributes[attribute](self).damage or 0) <= 0 then
            attributeSessions[attribute] = nil
        end
    end
end

local function clearMind()
    local c = rank("C")
    local trace=SkillDebug.beginTrace("restoration","Clear Mind","one-second recovery tick",{
        cRank=c,
    })
    if c == 0 then return trace:reject("C chain inactive") end
    local health = types.Actor.stats.dynamic.health(self)
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    if health.current < maximum("health") or fatigue.current < maximum("fatigue") then
        return trace:reject("Health or Fatigue is not full",{
            fatigueCurrent=fatigue.current,fatigueMaximum=maximum("fatigue"),
            healthCurrent=health.current,healthMaximum=maximum("health"),
        })
    end
    local rate = 1
    if c == 2 then
        for _, resource in ipairs({"health","fatigue"}) do
            local state, allowed = states[resource], cap(resource)
            if allowed > 0 and state.buffer + state.drain > allowed * 0.5 then rate = rate + 1 end
        end
    end
    local resolved=Common.restoreResource(self,"magicka",rate,ids["C"..c])
    trace:finish("Magicka restored",{requested=rate,resolved=resolved})
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
    direction=interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
    handler=function(attack, context)
        local trace=SkillDebug.beginTrace("restoration","Warding Reprisal","incoming hit",{
            attacker = attack and SkillDebug.objectId(attack.attacker),
            healthDamage = attack and attack.damage and attack.damage.health,
        })
        local d=rank("D")
        if d == 0 then return trace:reject("D chain inactive") end
        if not attack.attacker then return trace:reject("attack has no attacker") end
        if attack.attacker == self then return trace:reject("attack is self-authored") end
        if not attack.attacker:isValid() then return trace:reject("attacker unavailable") end
        if not attack.damage then return trace:reject("attack has no damage payload") end
        if attack.target and attack.target ~= self then return trace:reject("player is not target") end
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
                            trace:step("resisted spell damage converted",{
                                incomingEffect=effect.id,landed=landed,reflectedAmount=amount,
                                reflectedEffect=swap.reflect,resistance=resisted,
                            })
                        end
                    end
                end
            end
        end

        -- D2 depends on the amount this specific hit adds to the Ward, which
        -- does not exist until the Health calculation handler has run.
        local function applyReprisal(resolvedAttack)
            if not attack.attacker or not attack.attacker:isValid() then
                return trace:reject("attacker unavailable after calculations")
            end
            local absorbed = tonumber(resolvedAttack.skillPerksRestorationWardAbsorbedHealth) or 0
            if rank("D") >= 2 and absorbed > 0 then
                attack.attacker:sendEvent("SPerks_TakeDamage",{
                    amount=absorbed,source=self,
                    sourceEffect=ids.D2,damageType="wardingreprisal",
                })
                trace:step("absorbed ward damage returned directly",{
                    amount=absorbed,target=SkillDebug.objectId(attack.attacker),
                })
            end
            if #reflected > 0 then
                Common.applyDynamicSpell(attack.attacker,self,"Warding Reprisal",reflected)
                return trace:finish("reprisal spell queued",{
                    absorbedHealth=absorbed,effects=#reflected,
                })
            end
            if absorbed>0 then
                return trace:finish("direct ward reprisal delivered",{
                    absorbedHealth=absorbed,effects=0,
                })
            end
            trace:reject("no reflected or absorbed damage qualified",{absorbedHealth=absorbed})
        end

        if context and type(context.afterResolve) == "function" then
            context.afterResolve(applyReprisal)
            trace:step("post-resolution callback registered",{precomputedEffects=#reflected})
        else
            trace:step("resolving immediately; no post-resolution callback",{precomputedEffects=#reflected})
            applyReprisal(attack)
        end
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
    if SkillDebug.handleTraceCommand({
        name = "Restoration",
        skillId = "restoration",
        commands = { "luarest debug", "luarestoration debug" },
    }, command) then
        return
    end
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "luarest debug" and command ~= "luarestoration debug" then return end
    SkillDebug.describe({ name = "Restoration", skillId = "restoration", actor = self, ids = ids })

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
            .. " casterMatch=" .. tostring(active.casterMatchReason)
            .. " casterRecord=" .. tostring(active.casterRecordId)
            .. " playerRecord=" .. tostring(active.actorRecordId)
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
