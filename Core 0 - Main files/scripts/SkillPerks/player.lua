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

-- Core 0 owns the only player-side listener for target-forwarded weapon hits.
-- It feeds those observations into the Framework's ordered hit dispatcher, so
-- later cores register normal Framework handlers instead of separate events.

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local self = require("openmw.self")

local Log = require("scripts.SkillPerks.shared.log")
local SkillDebug = require("scripts.SkillPerks.shared.debug")
local SharedHit = require("scripts.SkillPerks.shared.hit")

Log(3, nil, "SkillPerks Core 0 hit diagnostics loaded (raw bridge trace v2).")

local RESOURCE_DELTA_EVENT = "ErnPerkFramework_ApplyActorResourceDelta"
local RESOURCE_RESULT_EVENT = "SPerks_HitResolutionApplied"
local resourceRequestSerial = 0
local spellforgeAuthorizations = {}
local spellforgeCleanupTimer = 0

local HIT_TRACE_SKILLS = {
    "acrobatics",
    "axe",
    "block",
    "bluntweapon",
    "handtohand",
    "lightarmor",
    "longblade",
    "marksman",
    "mediumarmor",
    "shortblade",
    "sneak",
    "spear",
}

--- Returns a numeric damage field, treating absent secondary resources as 0.
local function damageValue(attack, resource)
    return attack and attack.damage and tonumber(attack.damage[resource]) or 0
end

--- Formats a target-bridge trace consistently at SkillPerks verbosity 3.
--- @param stage string Bridge stage.
--- @param trace table|nil Primitive trace payload.
--- @param suffix string|nil Additional dispatch result.
local function logBridgeTrace(stage, trace, suffix)
    if not SkillDebug.anyTraceEnabled(HIT_TRACE_SKILLS) then
        return
    end
    trace = trace or {}
    Log(3, nil, function()
        return string.format(
            "SkillPerks hit bridge [%s/%s]: accepted=%s ownership=%s reason=%s "
                .. "direction=%s attacker(id=%s record=%s type=%s isPlayer=%s) player=%s "
                .. "target(id=%s record=%s) weapon(id=%s record=%s) "
                .. "success=%s damage(H/F)=%s/%s strength=%s attackType=%s%s",
            tostring(trace.targetKind or "unknown"),
            tostring(stage),
            tostring(trace.accepted),
            tostring(trace.ownershipSource),
            tostring(trace.reason),
            tostring(trace.frameworkDirection),
            tostring(trace.attackerId),
            tostring(trace.attackerRecordId),
            tostring(trace.attackerType),
            tostring(trace.attackerIsPlayer),
            tostring(trace.playerId),
            tostring(trace.targetId),
            tostring(trace.targetRecordId),
            tostring(trace.weaponId),
            tostring(trace.weaponRecordId),
            tostring(trace.successful),
            tostring(trace.healthDamage),
            tostring(trace.fatigueDamage),
            tostring(trace.strength),
            tostring(trace.attackType),
            suffix and (" " .. suffix) or ""
        )
    end)
end

--- Publishes the most recent bridge boundary to skill scripts as well as the
--- trace log, so commands such as `luah2h debug` retain rejected-hit details.
--- @param stage string Bridge stage.
--- @param trace table|nil Primitive trace payload.
local function publishBridgeTrace(stage, trace)
    trace = trace or {}
    trace.stage = stage
    logBridgeTrace(stage, trace)
    self:sendEvent("SPerks_HitBridgeDiagnostic", trace)
end

--- Summarizes every raw perk addition made before the Framework's arithmetic
--- calculation handlers resolve the final hit total.
--- @param attack table Resolved shared hit payload.
--- @param resource string Dynamic resource channel.
--- @return table ids Contributor effect ids.
--- @return table details Primitive source/amount records.
--- @return number rawTotal Sum of raw additions before calculation modifiers.
local function resourceContributors(attack, resource)
    local ids = {}
    local details = {}
    local rawTotal = 0
    for _, contribution in ipairs(attack.perkFrameworkDamageContributors or {}) do
        local metadata = contribution.metadata or {}
        if contribution.resource == resource then
            local amount = tonumber(contribution.amount) or 0
            rawTotal = rawTotal + amount
            if metadata.sourceEffect ~= nil then
                ids[#ids + 1] = metadata.sourceEffect
            end
            details[#details + 1] = {
                sourceEffect = metadata.sourceEffect,
                context = metadata.context,
                amount = amount,
            }
        end
    end
    return ids, details, rawTotal
end

--- Applies only the arithmetic difference added by Framework hit handlers.
--- The engine has already committed the base hit on the target. The additional
--- amount therefore travels through the Framework's global-to-actor resource
--- bridge, which performs the final write in the target's legal local context.
local function applyResolvedDifference(target, attack, originalDamage)
    local applied = {}
    if not target or not target:isValid() then
        return applied
    end

    local framework = interfaces.ErnPerkFramework
    for _, resource in ipairs({ "health", "fatigue", "magicka" }) do
        local baseDamage = tonumber(originalDamage[resource]) or 0
        local requestedTotal = damageValue(attack, resource)
        local difference = requestedTotal - baseDamage
        applied[resource] = difference
        if difference > 0 then
            resourceRequestSerial = resourceRequestSerial + 1
            local contributors, contributionDetails, rawContributionTotal =
                resourceContributors(attack, resource)
            local preHit = attack.perkFrameworkPreHitResources
                and attack.perkFrameworkPreHitResources[resource]
            core.sendGlobalEvent(RESOURCE_DELTA_EVENT, {
                actor = target,
                resource = resource,
                operation = framework.RESOURCE_OPERATION.Damage,
                amount = difference,
                source = attack.attacker,
                sourceEffect = #contributors == 1
                    and contributors[1]
                    or "SkillPerks_SharedHitResolution",
                context = {
                    kind = "skillperks.sharedHitResolution",
                    direction = framework.HIT_DIRECTION.Outgoing,
                },
                metadata = {
                    contributors = contributors,
                    contributionDetails = contributionDetails,
                    rawContributionTotal = rawContributionTotal,
                    calculationAdjustment =
                        requestedTotal - baseDamage - rawContributionTotal,
                    baseDamage = baseDamage,
                    requestedTotal = requestedTotal,
                    preHitCurrent = preHit and tonumber(preHit.current) or nil,
                },
                resultTarget = self,
                resultEvent = RESOURCE_RESULT_EVENT,
                requestId = "SkillPerks_Hit_" .. tostring(resourceRequestSerial),
            })
        end
    end
    return applied
end

--- Routes one target-local hit observation through the Framework exactly once.
--- The copied base damage cannot alter the completed engine hit, so Core 0
--- applies only the combined arithmetic difference after dispatch completes.
--- @param attack table|nil Normalized payload from npc.lua or creature.lua.
local function onPlayerHitActor(attack)
    if type(attack) ~= "table" then
        Log(1, nil, "SkillPerks hit bridge: rejected non-table player event payload.")
        return
    end

    local trace = attack.skillPerksBridgeTrace or {}
    publishBridgeTrace("player-received", trace)

    local framework = interfaces.ErnPerkFramework
    if not framework or type(framework.dispatchOnHit) ~= "function" then
        Log(1, nil, "SkillPerks hit bridge: player event arrived but Framework dispatchOnHit is unavailable.")
        return
    end

    attack.skillPerksPlayerOwned = true
    attack.skillPerksHitSource = "target-bridge"
    local target = attack.target or attack.victim or attack.defender
    local originalDamage = {
        health = damageValue(attack, "health"),
        fatigue = damageValue(attack, "fatigue"),
        magicka = damageValue(attack, "magicka"),
    }
    local processed = framework.dispatchOnHit(attack, {
        source = "SkillPerks.target-bridge",
        direction = framework.HIT_DIRECTION.Outgoing,
        target = target,
        forwarded = true,
        resolveDamage = true,
    })
    if processed then
        local applied = applyResolvedDifference(target, attack, originalDamage)
        logBridgeTrace("framework-dispatched", trace, string.format(
            "processed=true resolvedDifference(H/F/M)=%s/%s/%s",
            tostring(applied.health or 0),
            tostring(applied.fatigue or 0),
            tostring(applied.magicka or 0)
        ))
    else
        logBridgeTrace("framework-dispatched", trace, "processed=false duplicate-suppressed=true")
    end
end

--- Receives a player-like hit rejected by the target ownership classifier.
--- @param trace table Primitive target-local trace payload.
local function onHitBridgeTrace(trace)
    publishBridgeTrace("target-rejected", trace)
end

--- Relays target-local Magic decisions into the owning skill's gated trace.
--- Target scripts cannot print selectively for the player's chosen school,
--- so they send compact primitive payloads here and Core 0 applies the same
--- verbosity-3 plus `debug trace` gate as player-side perk code.
--- @param data table|nil
local function onMagicTargetTrace(data)
    data = data or {}
    SkillDebug.traceEvent(
        data.skillId or "magic",
        "TARGET " .. tostring(data.effectName or "Magic") .. " / "
            .. tostring(data.stage or "step"),
        data.fields
    )
end

--- Reports the global dynamic-spell service's final application result.
--- This closes the diagnostic gap between a school queuing an effect and
--- OpenMW confirming that the generated ActiveSpell exists on its target.
--- @param data table|nil
local function onMagicSpellApplicationResult(data)
    data = data or {}
    SkillDebug.traceEvent(
        data.traceSkill or "magic",
        "GLOBAL " .. tostring(data.traceEffect or data.spellName or "dynamic spell")
            .. " / " .. tostring(data.stage or "unknown"),
        {
            active=data.active,effect=data.effectId,error=data.error,
            requestId=data.requestId,skipped=data.skipped,spell=data.spellId,
            success=data.success,target=data.targetId,
        }
    )
end

--- Retains authoritative Spellforge self-cast authorization long enough for
--- all Magic school scripts to classify the resulting ActiveSpell. The
--- global bridge has already excluded abilities, items, and non-player casts.
local function authorizeSpellforgeSelfEffect(data)
    data=data or {}
    local target=data.target
    if target and tostring(target.id)~=tostring(self.id) then return end
    local spellId=tostring(data.spellId or ""):lower()
    if spellId=="" then return end
    local duration=math.max(0,tonumber(data.duration) or 0)
    local expiresAt=core.getSimulationTime()+math.max(1,duration+0.5)
    spellforgeAuthorizations[spellId]=math.max(
        spellforgeAuthorizations[spellId] or 0,
        expiresAt
    )
end

local function clearExpiredSpellforgeAuthorizations()
    local now=core.getSimulationTime()
    for spellId,expiresAt in pairs(spellforgeAuthorizations) do
        if expiresAt<now then spellforgeAuthorizations[spellId]=nil end
    end
end

--- Returns whether Core 0 observed an authenticated Spellforge self-cast for
--- this generated helper record and its authorization remains live.
local function isSpellforgeSpellAuthorized(spellId)
    clearExpiredSpellforgeAuthorizations()
    return (spellforgeAuthorizations[tostring(spellId or ""):lower()] or 0)
        >= core.getSimulationTime()
end

local function onUpdate(dt)
    spellforgeCleanupTimer=spellforgeCleanupTimer-dt
    if spellforgeCleanupTimer>0 then return end
    spellforgeCleanupTimer=0.5
    clearExpiredSpellforgeAuthorizations()
end

local function onSave()
    local now=core.getSimulationTime()
    local saved={}
    for spellId,expiresAt in pairs(spellforgeAuthorizations) do
        local remaining=expiresAt-now
        if remaining>0 then saved[spellId]=remaining end
    end
    return {spellforgeAuthorizations=saved}
end

local function onLoad(data)
    local now=core.getSimulationTime()
    spellforgeAuthorizations={}
    for spellId,remaining in pairs(
            data and data.spellforgeAuthorizations or {}) do
        remaining=math.max(0,tonumber(remaining) or 0)
        if remaining>0 then
            spellforgeAuthorizations[spellId]=now+remaining
        end
    end
end

return {
    interfaceName = "SkillPerksMagic",
    interface = {
        isSpellforgeSpellAuthorized = isSpellforgeSpellAuthorized,
    },
    eventHandlers = {
        SPerks_PlayerHitActor = onPlayerHitActor,
        SPerks_HitBridgeTrace = onHitBridgeTrace,
        SPerks_MagicTargetTrace = onMagicTargetTrace,
        SPerks_MagicSpellApplicationResult = onMagicSpellApplicationResult,
        SPerks_SpellforgeMagicHit = authorizeSpellforgeSelfEffect,
        SPerks_SpellforgeEffectApplied = authorizeSpellforgeSelfEffect,
    },
    engineHandlers = {
        onLoad=onLoad,
        onSave=onSave,
        onUpdate=onUpdate,
    },
}
