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

--- Returns the single-player actor object from the world player list.
--- @return GameObject|nil player
local function getPlayer()
    return nearby.players[1]
end

--- Returns true when the target-local hit payload belongs to the player.
--- @param attack table OpenMW combat hit payload.
--- @param player GameObject Player actor.
--- @return boolean result
local function isPlayerOwnedHit(attack, player)
    if not attack or not player then
        return false
    end
    if attack.attacker == player then
        return true
    end
    if attack.attacker ~= nil or not attack.weapon then
        return false
    end
    return attack.weapon == types.Actor.getEquipment(player, types.Actor.EQUIPMENT_SLOT.CarriedRight)
end

--- Sends player-owned hits on this creature back to the player script.
--- This mirrors npc.lua so player-owned combat perks can keep their state
--- in the player script while still reacting to target-local hit callbacks.
--- @param attack table OpenMW combat hit payload.
local function forwardPlayerHit(attack)
    local player = getPlayer()
    if not isPlayerOwnedHit(attack, player) then
        return
    end
    player:sendEvent("SPerks_PlayerHitActor", {
        attacker = attack.attacker or player,
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
    })
end

if interfaces.Combat and interfaces.Combat.addOnHitHandler then
    interfaces.Combat.addOnHitHandler(forwardPlayerHit)
end

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

local function onUpdate()
    Stagger.checkStaggerState()
end

return {
    eventHandlers = {
        SPerks_TakeDamage = takeDamage,
        SPerks_TakeFatigue = takeFatigue,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
