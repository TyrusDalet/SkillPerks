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
    npc.lua

    Attached to every NPC via SkillPerks.omwscripts (NPC: line). Mirrors
    FactionPerks' actor-local resource routing pattern:

      SPerks_TakeDamage / SPerks_TakeFatigue
        Target-side health/fatigue application events. Individual
        Combat/Stealth/Magic perk files send these events at the target
        rather than writing to target stats directly, since a local script
        can only safely mutate ITS OWN stats. The actual amount is resolved
        through ErnPerkFramework.applyActorResourceDelta first, so other
        mods can contribute to the shared direct.damage.* calculation
        channels before the final resource change is applied.

      Stagger state
        Wires up shared/stagger.lua's per-frame suppression check. This is
        Magic-only functionality (Mysticism D chain) but lives in the
        shared runtime so the later Magic skill files won't need to touch
        this actor attachment again.
        Harmless no-op overhead until a perk actually forces a stagger/
        knockdown animation on this actor.

    COMBAT HIT HANDLING: deliberately NOT registered here. Combat/Stealth
    perk files that need to react to hits should register through
    ErnPerkFramework.registerOnHitHandler for detection/side effects, and
    through ErnPerkFramework.registerCalculationHandler for damage-changing
    contributions. That keeps all incoming-hit logic in the shared ordered
    pipeline instead of installing independent OpenMW onHit callbacks.
]]

local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")

local Stagger = require("scripts.SkillPerks.shared.stagger")
local RESOURCE_OPERATION = interfaces.ErnPerkFramework.RESOURCE_OPERATION

--- Applies direct health damage to self through the framework resource
--- pipeline, allowing other mods to adjust `direct.damage.health` before
--- the final damage is applied.
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

--- Applies direct fatigue damage to self through the framework resource
--- pipeline, allowing other mods to adjust `direct.damage.fatigue` before
--- the final damage is applied.
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
