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
local pself = require("openmw.self")
local types = require("openmw.types")

local Stagger = require("scripts.SkillPerks.shared.stagger")
local hitForwarderRegistered = false

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

--- Bridges target-local player hit callbacks back to the player's SkillPerks
--- scripts. OpenMW sends this callback to the actor being hit, but player
--- perks own state such as Long Blade Momentum on the player script.
local function registerPlayerHitForwarder()
    if hitForwarderRegistered then
        return
    end
    if interfaces.Combat == nil then
        return
    end
    hitForwarderRegistered = true
    interfaces.Combat.addOnHitHandler(function(attack)
        local attacker = attack.attacker
        if not attacker or not attacker:isValid() or not types.Player.objectIsInstance(attacker) then
            return
        end
        attacker:sendEvent("SPerks_PlayerHitActor", {
            target = pself,
            weapon = attack.weapon,
            armor = attack.armor,
            successful = attack.successful,
            strength = attack.strength,
            sourceType = attack.sourceType,
            type = attack.type,
            damage = attack.damage and {
                health = attack.damage.health,
                fatigue = attack.damage.fatigue,
                magicka = attack.damage.magicka,
            } or nil,
        })
    end)
end

local function onUpdate(dt)
    registerPlayerHitForwarder()
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
