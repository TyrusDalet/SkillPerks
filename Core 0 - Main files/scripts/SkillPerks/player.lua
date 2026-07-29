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

local BRIDGE_DUPLICATE_WINDOW = 0.20
local lastReceivedBridgeHit = nil

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

--- Suppresses the same native hit when both Framework's built-in unarmed
--- bridge and Core 0's compatibility observer deliver it to the player.
--- @param attack table Normalized player-hit payload.
--- @return boolean duplicate
local function duplicateBridgeHit(attack)
    local now = core.getSimulationTime()
    local target = SharedHit.target(attack)
    local damage = attack.damage or {}
    local previous = lastReceivedBridgeHit
    local duplicate = previous ~= nil
        and now - previous.time <= BRIDGE_DUPLICATE_WINDOW
        and SharedHit.sameObject(previous.target, target)
        and previous.successful == attack.successful
        and previous.health == (tonumber(damage.health) or 0)
        and previous.fatigue == (tonumber(damage.fatigue) or 0)
        and previous.strength == tonumber(attack.strength)
        and previous.attackType == attack.type

    if not duplicate then
        lastReceivedBridgeHit = {
            time = now,
            target = target,
            successful = attack.successful,
            health = tonumber(damage.health) or 0,
            fatigue = tonumber(damage.fatigue) or 0,
            strength = tonumber(attack.strength),
            attackType = attack.type,
        }
    end
    return duplicate
end

--- Returns the perk ids that contributed to one resolved resource channel.
--- Keeping this metadata small makes the target acknowledgement useful without
--- forwarding the complete OpenMW attack payload through two more event hops.
local function resourceContributors(attack, resource)
    local out = {}
    for _, contribution in ipairs(attack.perkFrameworkDamageContributors or {}) do
        local metadata = contribution.metadata or {}
        if contribution.resource == resource and metadata.sourceEffect ~= nil then
            out[#out + 1] = metadata.sourceEffect
        end
    end
    return out
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
        local difference = damageValue(attack, resource) - (originalDamage[resource] or 0)
        applied[resource] = difference
        if difference > 0 then
            resourceRequestSerial = resourceRequestSerial + 1
            local contributors = resourceContributors(attack, resource)
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
    if attack.perkFrameworkTargetBridge then
        trace = SharedHit.tracePayload(
            attack,
            self,
            SharedHit.target(attack),
            "framework",
            "outgoing"
        )
        trace.ownershipSource = attack.perkFrameworkTargetBridge
        trace.reason = "Framework target-local Combat.onHit bridge"
    end
    publishBridgeTrace("player-received", trace)

    if duplicateBridgeHit(attack) then
        logBridgeTrace("framework-dispatched", trace, "processed=false bridge-duplicate=true")
        return
    end

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

--- Retains an engine payload that reached the Framework while the player was
--- unarmed but did not qualify for the authoritative H2H bridge. It is
--- diagnostic only and never activates a perk.
local function onRawUnarmedCandidate(attack)
    local trace = SharedHit.tracePayload(
        attack,
        self,
        SharedHit.target(attack),
        "framework-raw-candidate",
        "unknown"
    )
    trace.reason = "Combat.onHit reached Framework but did not qualify for player H2H bridge"
    trace.bridgeRevision = attack and attack.perkFrameworkBridgeRevision
    publishBridgeTrace("framework-raw-candidate", trace)
end

return {
    eventHandlers = {
        ErnPerkFramework_PlayerUnarmedHit = onPlayerHitActor,
        ErnPerkFramework_RawUnarmedCandidate = onRawUnarmedCandidate,
        SPerks_PlayerHitActor = onPlayerHitActor,
        SPerks_HitBridgeTrace = onHitBridgeTrace,
    },
}
