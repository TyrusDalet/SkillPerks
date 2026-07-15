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

local Stagger = require("scripts.SkillPerks.shared.stagger")
local RESOURCE_OPERATION = interfaces.ErnPerkFramework.RESOURCE_OPERATION

--- Applies direct health damage through `direct.damage.health`.
--- @param data table|nil Event payload with amount and optional source/context data.
local function takeDamage(data)
    data = data or {}
    interfaces.ErnPerkFramework.applyActorResourceDelta({
        actor = pself,
        resource = "health",
        operation = RESOURCE_OPERATION.Damage,
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
    interfaces.ErnPerkFramework.applyActorResourceDelta({
        actor = pself,
        resource = "fatigue",
        operation = RESOURCE_OPERATION.Damage,
        amount = data.amount or 0,
        source = data.source,
        sourceEffect = data.sourceEffect,
        damageType = data.damageType,
        context = data,
    })
end

local function onUpdate(dt)
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
