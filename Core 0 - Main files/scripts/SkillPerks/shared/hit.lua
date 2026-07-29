--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Shared hit-payload ownership helpers.

OpenMW can deliver the same logical player attack in different local-script
contexts. A forwarded GameObject is not guaranteed to compare identically with
openmw.self, so gameplay Cores should use these helpers rather than repeating
strict actor-identity checks.
]]

local types = require("openmw.types")

local Hit = {}

--- Recognizes the player through OpenMW's native GameObject type field, with
--- the type API predicate retained for wrapper variants.
--- @param object GameObject|nil Candidate object.
--- @return boolean isPlayer
function Hit.isPlayerObject(object)
    if object == nil then
        return false
    end
    local fieldOk, objectType = pcall(function() return object.type end)
    if fieldOk and objectType == types.Player then
        return true
    end
    local predicateOk, isPlayer = pcall(types.Player.objectIsInstance, object)
    return predicateOk and isPlayer == true
end

--- Reads a GameObject field without allowing an unavailable handle to break
--- combat diagnostics.
--- @param object GameObject|nil Object handle.
--- @param key string Field name.
--- @return any value
local function objectField(object, key)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function() return object[key] end)
    return ok and value or nil
end

--- Returns true when two GameObject handles refer to the same world object.
--- OpenMW can expose the same actor through different userdata wrappers when
--- an engine hit crosses local-script contexts, so strict userdata equality is
--- only the fast path. GameObject.id is the documented stable unique identity.
--- @param left GameObject|nil First object handle.
--- @param right GameObject|nil Second object handle.
--- @return boolean same
function Hit.sameObject(left, right)
    if left == nil or right == nil then
        return false
    end
    if left == right then
        return true
    end

    local leftOk, leftId = pcall(function() return left.id end)
    local rightOk, rightId = pcall(function() return right.id end)
    if leftOk and rightOk and leftId ~= nil and leftId == rightId then
        return true
    end

    -- The player can cross local-script boundaries through a distinct
    -- userdata wrapper whose id is unavailable. Single-player OpenMW has
    -- exactly one Player instance, so two Player handles are the same actor.
    return Hit.isPlayerObject(left) and Hit.isPlayerObject(right)
end

--- Returns the actor struck by an attack payload.
--- @param attack table|nil OpenMW or Core 0 hit payload.
--- @return GameObject|nil target
function Hit.target(attack)
    return attack and (attack.target or attack.victim or attack.defender) or nil
end

--- Explains how an attack payload was attributed to the player.
--- The source is retained in bridged payloads for per-skill diagnostics.
--- @param attack table|nil OpenMW or Core 0 hit payload.
--- @param player GameObject Player-local actor.
--- @return string|nil source Attribution route, or nil for a non-player hit.
--- @return string reason Human-readable accepted or rejected gate.
function Hit.playerAttackSource(attack, player)
    if not attack then
        return nil, "missing attack payload"
    end
    if not player then
        return nil, "nearby player unavailable"
    end
    if attack.skillPerksPlayerOwned == true then
        return attack.skillPerksOwnershipSource or "core0-bridge", "authoritative Core 0 marker"
    end
    if Hit.sameObject(attack.attacker, player) then
        return "attacker-id", "attacker id matches player"
    end
    if attack.attacker ~= nil then
        if Hit.isPlayerObject(attack.attacker) then
            return "attacker-player-type", "attacker is a Player instance"
        end
        return nil, "attacker is not player"
    end

    local target = Hit.target(attack)
    if target == nil then
        return nil, "attacker and target are absent"
    end
    if Hit.sameObject(target, player) then
        return nil, "player is the target"
    end
    if attack.weapon == nil then
        return nil, "attacker and weapon are absent"
    end
    local equipped = types.Actor.getEquipment(player, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if equipped ~= nil and Hit.sameObject(attack.weapon, equipped) then
        return "equipped-weapon-id", "weapon id matches player's right hand"
    end
    if equipped == nil then
        return nil, "payload has weapon while player is unarmed"
    end
    return nil, "payload weapon does not match player's right hand"
end

--- Returns whether a rejected payload could plausibly be an unattributed
--- player hit and therefore deserves trace delivery at verbosity level 3.
--- @param attack table|nil OpenMW hit payload.
--- @param player GameObject|nil Nearby player.
--- @return boolean candidate
function Hit.isPotentialPlayerAttack(attack, player)
    if not attack or not player then
        return false
    end
    if Hit.playerAttackSource(attack, player) ~= nil then
        return true
    end

    if Hit.isPlayerObject(attack.attacker) then
        return true
    end
    if attack.attacker ~= nil then
        -- Keep ambiguous unarmed payloads visible to diagnostics. This does
        -- not grant ownership; it only lets the player's trace explain why
        -- the authoritative check rejected the event.
        local equipped = types.Actor.getEquipment(player, types.Actor.EQUIPMENT_SLOT.CarriedRight)
        return attack.weapon == nil and equipped == nil
    end

    local equipped = types.Actor.getEquipment(player, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    return (attack.weapon == nil and equipped == nil)
        or (attack.weapon ~= nil and Hit.sameObject(attack.weapon, equipped))
end

--- Builds a primitive-only trace record that can safely cross from a target
--- local script to the player script.
--- @param attack table OpenMW hit payload.
--- @param player GameObject|nil Nearby player.
--- @param target GameObject|nil Actor receiving the engine hit.
--- @param targetKind string "npc" or "creature".
--- @param frameworkDirection string|nil Direction assigned by the Framework.
--- @return table trace
function Hit.tracePayload(attack, player, target, targetKind, frameworkDirection)
    attack = attack or {}
    local source, reason = Hit.playerAttackSource(attack, player)
    local damage = attack.damage or {}
    local attackerIsPlayer = Hit.isPlayerObject(attack.attacker)
    return {
        accepted = source ~= nil,
        ownershipSource = source,
        reason = reason,
        targetKind = targetKind,
        frameworkDirection = frameworkDirection,
        attackerId = objectField(attack.attacker, "id"),
        attackerRecordId = objectField(attack.attacker, "recordId"),
        attackerType = tostring(objectField(attack.attacker, "type")),
        attackerIsPlayer = attackerIsPlayer,
        playerId = objectField(player, "id"),
        targetId = objectField(target, "id"),
        targetRecordId = objectField(target, "recordId"),
        weaponId = objectField(attack.weapon, "id"),
        weaponRecordId = objectField(attack.weapon, "recordId"),
        successful = attack.successful,
        sourceType = attack.sourceType,
        healthDamage = tonumber(damage.health) or 0,
        fatigueDamage = tonumber(damage.fatigue) or 0,
        strength = tonumber(attack.strength),
        attackType = attack.type,
    }
end

--- Returns true when a hit belongs to the player in the current script.
--- Core 0's ownership marker is authoritative after the target-side bridge.
--- Native hits use stable object identity, with an attacker-less equipment
--- fallback for OpenMW payload variants that omit the source actor.
--- @param attack table|nil OpenMW or Core 0 hit payload.
--- @param player GameObject Player-local actor.
--- @return boolean owned
function Hit.isPlayerAttack(attack, player)
    return Hit.playerAttackSource(attack, player) ~= nil
end

return Hit
