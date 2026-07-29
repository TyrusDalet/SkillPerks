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
    SkillPerks stealth/common.lua

    Shared registration and combat helpers for Core 2. This deliberately
    keeps only Stealth-wide patterns here: stable IDs, rank lookups, target
    extraction, weapon classification, and the standard 10-slot perk
    registration shape. Skill-specific state and effects stay in each skill
    file so the behaviour remains easy to audit.
]]

local ns = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local SkillDebug = require("scripts.SkillPerks.shared.debug")
local StealthConstellations = require("scripts.SkillPerks.constellations.stealth")
local SharedHit = require("scripts.SkillPerks.shared.hit")

local Common = {}

local SLOT_ORDER = {
    "A1", "A2", "A3", "A4",
    "B1", "B2",
    "C1", "C2",
    "D1", "D2",
}

local SLOT_MENU_ORDER = {
    A1 = 1, A2 = 2, A3 = 3, A4 = 4,
    B1 = 5, B2 = 6,
    C1 = 7, C2 = 9,
    D1 = 8, D2 = 10,
}

local RANGED_TYPES = {
    [types.Weapon.TYPE.MarksmanBow] = true,
    [types.Weapon.TYPE.MarksmanCrossbow] = true,
    [types.Weapon.TYPE.MarksmanThrown] = true,
}

--- Safely identifies an equipped weapon object. Forwarded hit payloads may
--- contain a record id or an unavailable object in their `weapon` field;
--- callers should fall back to the player's current equipment in that case.
--- @param value any Candidate hit-source value.
--- @return boolean weapon
local function isWeaponObject(value)
    local ok, result = pcall(types.Weapon.objectIsInstance, value)
    return ok and result == true
end

--- Builds the standard SkillPerks id table for one skill.
--- @param skillKey string Lowercase key used inside the id.
--- @return table ids Slot -> full perk id.
function Common.ids(skillKey)
    return {
        A1 = ns .. "_" .. skillKey .. "_a1",
        A2 = ns .. "_" .. skillKey .. "_a2",
        A3 = ns .. "_" .. skillKey .. "_a3",
        A4 = ns .. "_" .. skillKey .. "_a4",
        B1 = ns .. "_" .. skillKey .. "_b1",
        B2 = ns .. "_" .. skillKey .. "_b2",
        C1 = ns .. "_" .. skillKey .. "_c1",
        C2 = ns .. "_" .. skillKey .. "_c2",
        D1 = ns .. "_" .. skillKey .. "_d1",
        D2 = ns .. "_" .. skillKey .. "_d2",
    }
end

--- Returns whether the player owns a perk id, using the framework cache.
--- @param id string Perk id.
--- @return boolean owned
function Common.hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

--- Returns the strongest owned rank in one chain.
--- @param ids table Slot -> perk id.
--- @param chain string "A", "B", "C", or "D".
--- @return number rank A=0..4, B/C/D=0..2.
function Common.rank(ids, chain)
    if chain == "A" then
        if Common.hasPerk(ids.A4) then return 4 end
        if Common.hasPerk(ids.A3) then return 3 end
        if Common.hasPerk(ids.A2) then return 2 end
        if Common.hasPerk(ids.A1) then return 1 end
        return 0
    end
    if Common.hasPerk(ids[chain .. "2"]) then return 2 end
    if Common.hasPerk(ids[chain .. "1"]) then return 1 end
    return 0
end

--- Extracts the target actor from an OpenMW hit table.
--- @param attack table Hit table.
--- @return GameObject|nil target
function Common.attackTarget(attack)
    if not attack then
        return nil
    end
    return attack.target or attack.victim or attack.defender
end

--- Returns true when the attack is an outgoing player hit.
--- @param attack table Hit table.
--- @param player GameObject Player actor.
--- @return boolean result
function Common.isPlayerAttack(attack, player)
    return SharedHit.isPlayerAttack(attack, player)
end

--- Returns true when the attack target is the player.
--- @param attack table Hit table.
--- @param player GameObject Player actor.
--- @return boolean result
function Common.isIncomingAttack(attack, player)
    return Common.attackTarget(attack) == player
end

--- Treats engine critical hits as the reliable "unaware target" signal.
--- In Morrowind, sneak attacks are already the engine's proof that the target
--- did not notice the player at the moment of contact.
--- @param attack table Hit table.
--- @return boolean unaware
function Common.isUnawareHit(attack)
    if not attack then
        return false
    end
    if attack.critical == true or attack.isCritical == true then
        return true
    end
    return attack.skillPerksTargetUnaware == true
end

--- Returns true when a weapon object is a bow, crossbow, or thrown weapon.
--- @param weapon GameObject|nil Weapon instance.
--- @return boolean result
function Common.isRangedWeapon(weapon)
    if not isWeaponObject(weapon) then
        return false
    end
    return RANGED_TYPES[types.Weapon.record(weapon).type] == true
end

--- Returns true when a weapon object is a bow or crossbow.
--- @param weapon GameObject|nil Weapon instance.
--- @return boolean result
function Common.isBowOrCrossbow(weapon)
    if not isWeaponObject(weapon) then
        return false
    end
    local weaponType = types.Weapon.record(weapon).type
    return weaponType == types.Weapon.TYPE.MarksmanBow
        or weaponType == types.Weapon.TYPE.MarksmanCrossbow
end

--- Returns true when a weapon object is a one-handed short blade.
--- @param weapon GameObject|nil Weapon instance.
--- @return boolean result
function Common.isShortBlade(weapon)
    return isWeaponObject(weapon)
        and types.Weapon.record(weapon).type == types.Weapon.TYPE.ShortBladeOneHand
end

--- Returns true when the player has no right-hand weapon equipped.
--- @param actor GameObject Actor to inspect.
--- @return boolean result
function Common.isUnarmed(actor)
    return types.Actor.getEquipment(actor, types.Actor.EQUIPMENT_SLOT.CarriedRight) == nil
end

--- Returns the player-facing weapon from a hit table or actor equipment.
--- @param attack table|nil Hit table.
--- @param actor GameObject|nil Fallback actor to inspect.
--- @return GameObject|nil weapon
function Common.weaponFromAttack(attack, actor)
    if attack and isWeaponObject(attack.weapon) then
        return attack.weapon
    end
    if actor then
        local equipped = types.Actor.getEquipment(actor, types.Actor.EQUIPMENT_SLOT.CarriedRight)
        if isWeaponObject(equipped) then
            return equipped
        end
    end
    return nil
end

--- Returns an actor's modified skill value, or zero when the actor cannot have skills.
--- @param actor GameObject Actor to inspect.
--- @param skillId string OpenMW skill id.
--- @return number value
function Common.skill(actor, skillId)
    local getter = types.NPC.stats.skills[skillId]
    if not getter then
        return 0
    end
    local ok, stat = pcall(getter, actor)
    if not ok or not stat then
        return 0
    end
    return stat.modified or stat.base or 0
end

--- Returns current/max ratio for a dynamic actor resource.
--- @param actor GameObject Actor to inspect.
--- @param resource string "health", "fatigue", or "magicka".
--- @return number ratio
function Common.dynamicRatio(actor, resource)
    local getter = types.Actor.stats.dynamic[resource]
    if not getter then
        return 1
    end
    local ok, stat = pcall(getter, actor)
    if not ok or not stat then
        return 1
    end
    local maxValue = math.max((stat.base or 0) + (stat.modifier or 0), 1)
    return math.max(0, math.min(1, (stat.current or maxValue) / maxValue))
end

--- Builds a stable-enough runtime key for per-target combat tables.
--- @param target GameObject|nil Target actor.
--- @return string|nil key
function Common.targetKey(target)
    if not target then
        return nil
    end
    return tostring(target.id) .. ":" .. tostring(target)
end

--- Safely checks a boolean-ish player control field.
--- @param actor GameObject Player actor.
--- @param key string Control field name.
--- @return boolean active
function Common.controlActive(actor, key)
    local ok, value = pcall(function()
        return actor.controls[key]
    end)
    return ok and value ~= nil and value ~= false and value ~= 0
end

--- Returns the resolved health damage carried by a hit payload.
--- The target bridge runs after the target's Framework calculation handler,
--- so this value is normally the final post-armour damage used by the engine.
--- @param attack table|nil OpenMW combat hit payload.
--- @return number damage Non-negative health damage.
function Common.healthDamage(attack)
    local value = attack and attack.damage and tonumber(attack.damage.health) or 0
    return math.max(0, value or 0)
end

--- Contributes additional health damage to the current shared hit resolution.
--- Core 0 applies the combined difference after every subscribed perk has
--- contributed, producing one target resource event instead of one per perk.
--- @param attack table OpenMW combat hit payload.
--- @param amount number Additional damage to apply.
--- @param player GameObject Source player.
--- @param sourceEffect string Perk or effect id used for interop diagnostics.
--- @param context string Short reason for debug and modifier handlers.
--- @return boolean added True when a positive contribution was recorded.
function Common.applyBonusHealthDamage(attack, amount, player, sourceEffect, context)
    local target = Common.attackTarget(attack)
    amount = math.max(0, tonumber(amount) or 0)
    if amount <= 0 or not target or not target:isValid() then
        return false
    end
    return interfaces.ErnPerkFramework.addHitDamage(attack, "health", amount, {
        source = player,
        sourceEffect = sourceEffect,
        context = context,
    })
end

--- Creates a consistent outgoing-hit entry point for Stealth perks.
--- Core 0 and ErnPerkFramework now own delivery and duplicate suppression;
--- this helper only validates player ownership before calling the skill.
--- @param player GameObject Player actor.
--- @param handler function Called as handler(attack, source).
--- @return function route Call with `(attack, source)`.
function Common.newOutgoingHitRouter(player, handler)
    return function(attack, source)
        attack = attack or {}
        source = source or "framework"
        if not Common.isPlayerAttack(attack, player) then
            return false
        end
        local handled = handler(attack, source)
        if handled == false then
            return false
        end
        return true
    end
end

--- Registers all supplied slot records for one Stealth skill.
--- Each entry needs localizedName, localizedFlavour, and localizedDescription.
--- Optional onAdd/onRemove fields default to no-ops.
--- @param skillId string OpenMW skill id.
--- @param skillName string Display name for the menu group.
--- @param ids table Slot -> perk id.
--- @param entries table Slot -> perk text/callback data.
function Common.registerStealthPerks(skillId, skillName, ids, entries)
    -- Register presentation metadata from the same script lifecycle that owns
    -- these perks. This avoids depending on a separate player script starting
    -- before the framework builds its constellation registry.
    StealthConstellations.register(skillName)
    for _, slot in ipairs(SLOT_ORDER) do
        local entry = entries[slot]
        if entry then
            interfaces.ErnPerkFramework.registerPerk({
                id = ids[slot],
                localizedName = entry.localizedName,
                category = ChainRequirements.category("Stealth", skillName, SLOT_MENU_ORDER[slot]),
                art = entry.art or "textures\\levelup\\thief",
                localizedFlavour = entry.localizedFlavour,
                localizedDescription = entry.localizedDescription,
                requirements = ChainRequirements.forSlot(skillId, ids, slot),
                onAdd = SkillDebug.wrapCallback(skillId, slot .. " applied/resynced", entry.onAdd),
                onRemove = SkillDebug.wrapCallback(skillId, slot .. " removed", entry.onRemove),
            })
        end
    end
end

return Common
