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

    COMBAT HIT HANDLING: OpenMW delivers onHit callbacks to the target's
    local script. For player-owned perk state such as Long Blade Momentum,
    this file forwards player outgoing hits back to the player's SkillPerks
    scripts after the framework's target-side hit pipeline sees them.
]]

local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local types = require("openmw.types")

local Stagger = require("scripts.SkillPerks.shared.stagger")
local hitForwarderRegistered = false

--- Returns the framework interface after local actor interfaces have attached.
--- NPC scripts can start before another local script's interface is visible,
--- so this must not be resolved at file load time.
local function framework()
    return interfaces.ErnPerkFramework
end

--- Applies direct health damage to self through the framework resource
--- pipeline, allowing other mods to adjust `direct.damage.health` before
--- the final damage is applied.
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

--- Applies direct fatigue damage to self through the framework resource
--- pipeline, allowing other mods to adjust `direct.damage.fatigue` before
--- the final damage is applied.
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

--- Registers a target-side onHit bridge once the framework actor interface
--- exists. The forwarded payload is intentionally small and serializable:
--- player scripts only need hit metadata and object references, not the live
--- mutable attack table.
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
