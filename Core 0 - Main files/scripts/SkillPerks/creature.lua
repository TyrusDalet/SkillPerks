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
    creature.lua

    Attached to every Creature via SkillPerks.omwscripts (CREATURE: line).
    Deliberately identical in shape to npc.lua - see that file's doc
    comment for the full rationale on SPerks_TakeDamage/TakeFatigue and
    stagger wiring. Kept as a separate file so future creature-only hooks
    can diverge cleanly without changing the NPC attachment path.

    types.Actor.stats.dynamic (health/fatigue) is common to both NPC and
    Creature, so takeDamage/takeFatigue resolve through the same framework
    resource calculation channels here.
]]

local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local nearby = require("openmw.nearby")
local pself = require("openmw.self")

local Stagger = require("scripts.SkillPerks.shared.stagger")
local MagicTarget = require("scripts.SkillPerks.shared.magic_target")
local SharedHit = require("scripts.SkillPerks.shared.hit")

--- Returns the single-player actor object from the world player list.
--- @return GameObject|nil player
local function getPlayer()
    return nearby.players[1]
end

--- Classifies whether the target-local hit payload belongs to the player.
--- Stable object ids handle distinct userdata wrappers for the same actor.
--- @param attack table OpenMW combat hit payload.
--- @param player GameObject Player actor.
--- @return string|nil source Player-attribution route.
local function playerHitSource(attack, player)
    return SharedHit.playerAttackSource(attack, player)
end

--- Sends player-owned hits on this creature back to the player script.
--- This mirrors npc.lua so player-owned combat perks can keep their state
--- in the player script while still reacting to target-local hit callbacks.
--- Rejected player-like hits send only a primitive trace event; accepted hits
--- carry the same trace alongside the normal gameplay payload.
--- @param attack table OpenMW combat hit payload.
--- @param context table Framework hit context.
local function forwardPlayerHit(attack, context)
    local player = getPlayer()
    local ownershipSource = playerHitSource(attack, player)
    local trace = SharedHit.tracePayload(
        attack,
        player,
        pself,
        "creature",
        context and context.direction or nil
    )
    if not ownershipSource then
        if player and SharedHit.isPotentialPlayerAttack(attack, player) then
            player:sendEvent("SPerks_HitBridgeTrace", trace)
        end
        return
    end
    player:sendEvent("SPerks_PlayerHitActor", {
        attacker = attack.attacker or player,
        skillPerksPlayerOwned = true,
        skillPerksOwnershipSource = ownershipSource,
        target = attack.target or attack.victim or attack.defender or pself,
        victim = attack.victim,
        defender = attack.defender,
        weapon = attack.weapon,
        ammo = attack.ammo,
        successful = attack.successful,
        damage = attack.damage,
        strength = attack.strength,
        type = attack.type,
        sourceType = attack.sourceType,
        critical = attack.critical,
        isCritical = attack.isCritical,
        perkFrameworkPreHitResources = attack.perkFrameworkPreHitResources,
        skillPerksBridgeTrace = trace,
    })
end

local playerHitForwarderRegistered = false

--- Registers the target bridge through PerkFramework's sole engine hit hook.
--- Local interfaces may attach after this script starts, so onUpdate retries
--- quietly until the Framework actor interface is available.
local function ensurePlayerHitForwarder()
    if playerHitForwarderRegistered then
        return
    end
    local fw = interfaces.ErnPerkFramework
    if not fw or (type(fw.registerRawOnHitObserver) ~= "function"
            and type(fw.registerOnHitHandler) ~= "function") then
        return
    end

    if type(fw.registerRawOnHitObserver) == "function" then
        fw.registerRawOnHitObserver({
            id = "SkillPerks_core0_raw_player_hit",
            priority = 100,
        }, function(attack, context)
            forwardPlayerHit(attack, context)
        end)
    else
        -- Compatibility path for Framework versions predating raw observers.
        fw.registerOnHitHandler({
            id = "SkillPerks_core0_forward_player_hit",
            priority = 9000,
            direction = fw.HIT_DIRECTION.Any,
        }, function(attack, context)
            context.afterResolve(function()
                forwardPlayerHit(attack, context)
            end)
        end)
    end
    playerHitForwarderRegistered = true
end

ensurePlayerHitForwarder()

--- Returns the framework interface after local actor interfaces have attached.
--- Creature scripts can start before another local script's interface is visible,
--- so this must not be resolved at file load time.
local function framework()
    return interfaces.ErnPerkFramework
end

--- Applies direct health damage through `direct.damage.health`.
--- @param data table|nil Event payload with amount and optional source/context data.
local function takeDamage(data)
    data = data or {}
    local fw = framework()
    if fw == nil then
        return
    end
    fw.applyActorResourceDelta({
        actor = pself,
        resource = "health",
        operation = fw.RESOURCE_OPERATION.Damage,
        amount = data.amount or 0,
        source = data.source,
        sourceEffect = data.sourceEffect,
        damageType = data.damageType,
        context = data,
    })
end

--- Applies direct fatigue damage through `direct.damage.fatigue`.
--- @param data table|nil Event payload with amount and optional source/context data.
local function takeFatigue(data)
    data = data or {}
    local fw = framework()
    if fw == nil then
        return
    end
    fw.applyActorResourceDelta({
        actor = pself,
        resource = "fatigue",
        operation = fw.RESOURCE_OPERATION.Damage,
        amount = data.amount or 0,
        source = data.source,
        sourceEffect = data.sourceEffect,
        damageType = data.damageType,
        context = data,
    })
end

--- Applies direct Magicka damage through the shared resource pipeline.
local function takeMagicka(data)
    data = data or {}
    local fw = framework()
    if fw == nil then return end
    fw.applyActorResourceDelta({
        actor = pself, resource = "magicka",
        operation = fw.RESOURCE_OPERATION.Damage,
        amount = data.amount or 0, source = data.source,
        sourceEffect = data.sourceEffect, damageType = data.damageType,
        context = data,
    })
end

local function onUpdate(dt)
    ensurePlayerHitForwarder()
    Stagger.checkStaggerState()
    MagicTarget.onUpdate(dt)
end

local magicHandlers = MagicTarget.eventHandlers()
magicHandlers.SPerks_TakeDamage = takeDamage
magicHandlers.SPerks_TakeFatigue = takeFatigue
magicHandlers.SPerks_TakeMagicka = takeMagicka

return {
    eventHandlers = magicHandlers,
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
