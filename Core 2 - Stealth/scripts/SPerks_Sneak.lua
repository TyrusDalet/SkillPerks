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
    SPerks_Sneak.lua

    Sneak is patience made mechanical: the longer the player commits to
    moving unseen, the more the world has to work to find them. Unaware-hit
    bonuses use the engine's critical/sneak-attack signal instead of an
    unverified AI package query.
]]

local interfaces = require("openmw.interfaces")
local core       = require("openmw.core")
local types      = require("openmw.types")
local self       = require("openmw.self")

local Common            = require("scripts.SkillPerks.stealth.common")
local StatTracker       = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug        = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "sneak"
local ids = Common.ids("sneak")
local skillTracker = StatTracker.newStatModTracker(self, "Sneak Shadow Step")
local effectTracker = StatTracker.newActiveEffectTracker(self)
local phantomTracker = StatTracker.newActiveEffectTracker(self)
local lastSneaking = false
local phantomTimer = 0
local phantomExtended = false
local struckTargets = {}
local combatTargets = {}
local appliedSilentSpeed = 0
local lastSilentMovement = nil
local lastOpportunistDebug = nil

local A_BONUS = { [1] = 5, [2] = 10, [3] = 15, [4] = 20 }
local C_MULT = { [1] = 1.5, [2] = 2.0 }
local D_CHAMELEON = { [1] = 40, [2] = 60 }

local MIN_WALK_SPEED = tonumber(core.getGMST("fMinWalkSpeed")) or 100
local MAX_WALK_SPEED = tonumber(core.getGMST("fMaxWalkSpeed")) or 300
local ENCUMBERED_MOVE_EFFECT = tonumber(core.getGMST("fEncumberedMoveEffect")) or 0.5
local SNEAK_SPEED_MULTIPLIER = tonumber(core.getGMST("fSneakSpeedMultiplier")) or 0.75
SNEAK_SPEED_MULTIPLIER = math.max(0.05, math.min(1, SNEAK_SPEED_MULTIPLIER))

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function isSneaking()
    return Common.controlActive(self, "sneak")
end

-- Applies the visible and mechanical Sneak bonus while the player is sneaking.
local function updateSneakBonus()
    local rank = isSneaking() and aRank() or 0
    local value = A_BONUS[rank] or 0
    skillTracker.apply("skills", SKILL_ID, value)
    effectTracker.apply("fortifyskill", SKILL_ID, value)
end

-- This inversion of Morrowind's walk-speed equation is adapted, with
-- permission, from Ownlyme's Shadowdancer blessing in Roguelite. Solving for
-- the required Speed modifier avoids the error produced by treating movement
-- speed as directly proportional to the Speed attribute.
local function calculateSilentSpeedBonus(rank, currentSpeed)
    local capacity = tonumber(types.Actor.getCapacity(self)) or 0
    local encumbrance = math.max(0, tonumber(types.Actor.getEncumbrance(self)) or 0)
    local encumbranceRatio = capacity > 0 and math.min(1, encumbrance / capacity) or (encumbrance > 0 and 1 or 0)
    local encumbranceFactor = math.max(0, 1 - ENCUMBERED_MOVE_EFFECT * encumbranceRatio)
    local speedRange = MAX_WALK_SPEED - MIN_WALK_SPEED
    if encumbranceFactor <= 0 or math.abs(speedRange) < 0.001 then
        return 0, encumbranceRatio, 0, 0, currentSpeed
    end

    local normalWalkSpeed = math.max(0,
        (MIN_WALK_SPEED + 0.01 * currentSpeed * speedRange) * encumbranceFactor)
    local desiredMultiplier = rank >= 2
        and 1
        or ((1 + SNEAK_SPEED_MULTIPLIER) / 2)
    local targetSneakSpeed = normalWalkSpeed * desiredMultiplier
    local requiredWalkSpeed = targetSneakSpeed / SNEAK_SPEED_MULTIPLIER
    local requiredUnencumberedSpeed = requiredWalkSpeed / encumbranceFactor
    local requiredAttribute = (requiredUnencumberedSpeed - MIN_WALK_SPEED) / (0.01 * speedRange)
    return math.max(0, math.ceil(requiredAttribute - currentSpeed)),
        encumbranceRatio,
        normalWalkSpeed,
        targetSneakSpeed,
        requiredAttribute
end

-- Offsets the engine's Sneak movement penalty without changing base Speed.
local function updateSilentMovement()
    local rank = isSneaking() and bRank() or 0
    local value = 0
    local state = {
        rank = rank,
        sneaking = isSneaking(),
        sprinting = Common.controlActive(self, "sprint"),
        swimming = types.Actor.isSwimming(self),
    }
    if rank > 0 and not state.swimming then
        local speed = types.Actor.stats.attributes.speed(self)
        local unmodifiedByPerk = math.max(0, (speed.modified or speed.base or 0) - appliedSilentSpeed)
        local encumbranceRatio, normalWalkSpeed, targetSneakSpeed, requiredAttribute
        value, encumbranceRatio, normalWalkSpeed, targetSneakSpeed, requiredAttribute =
            calculateSilentSpeedBonus(rank, unmodifiedByPerk)
        state.currentSpeed = unmodifiedByPerk
        state.encumbranceRatio = encumbranceRatio
        state.normalWalkSpeed = normalWalkSpeed
        state.requiredAttribute = requiredAttribute
        state.targetSneakSpeed = targetSneakSpeed
    end
    local previous = appliedSilentSpeed
    appliedSilentSpeed = value
    skillTracker.apply("attributes", "speed", value)
    effectTracker.apply("fortifyattribute", "speed", value)
    state.appliedSpeed = value
    lastSilentMovement = state
    if math.abs(previous - value) >= 0.01 then
        SkillDebug.traceEvent(SKILL_ID, "sneak movement compensation changed", state)
    end
end

local function inCombat()
    return next(combatTargets) ~= nil
end

-- Starts the short Phantom window when the player deliberately drops low.
local function maybeStartPhantom()
    local sneaking = isSneaking()
    if sneaking and not lastSneaking and inCombat() then
        local rank = dRank()
        if rank > 0 then
            phantomTimer = 3
            phantomExtended = false
            phantomTracker.apply("chameleon", nil, D_CHAMELEON[rank])
        end
    end
    lastSneaking = sneaking
end

--- Tracks the engine's music-combat target notifications. These provide a
--- cheaper and more precise encounter boundary than polling every nearby AI
--- package from the player script.
local function onCombatTargetsChanged(data)
    SkillDebug.traceEvent(SKILL_ID, "combat targets changed", {
        actor = data and SkillDebug.objectId(data.actor),
        targets = data and data.targets and #data.targets or 0,
    })
    if not data or not data.actor then
        return
    end
    local key = Common.targetKey(data.actor)
    if not key then
        return
    end
    local targetsPlayer = false
    for _, target in ipairs(data.targets or {}) do
        if target == self then
            targetsPlayer = true
            break
        end
    end
    if targetsPlayer then
        combatTargets[key] = data.actor
    else
        combatTargets[key] = nil
        struckTargets[key] = nil
    end
    if dRank() >= 2 and phantomTimer > 0 and not phantomExtended and not inCombat() then
        phantomTimer = phantomTimer + 5
        phantomExtended = true
    end
end

local function tickPhantom(dt)
    if phantomTimer <= 0 then
        return
    end
    phantomTimer = math.max(0, phantomTimer - dt)
    if phantomTimer == 0 then
        phantomTracker.apply("chameleon", nil, 0)
    end
end

--- Marks the first unaware strike for Core 2's late damage resolver.
--- The resolver runs after ordinary Framework arithmetic, allowing the
--- multiplier to include other perk damage while retaining critical damage as
--- the conceptual final stage.
local function handleOutgoingHit(attack)
    local rank = cRank()
    local target = Common.attackTarget(attack)
    local unaware = Common.isUnawareHit(attack)
    lastOpportunistDebug = {
        rank = rank,
        successful = attack and attack.successful,
        unaware = unaware,
        target = SkillDebug.objectId(target),
        baseDamage = Common.healthDamage(attack),
    }
    SkillDebug.traceEvent(SKILL_ID, "Opportunist check", {
        successful = attack and attack.successful,
        unaware = unaware,
        rank = rank,
        target = SkillDebug.objectId(target),
    })
    if rank == 0 or attack.successful ~= true or not target or not target:isValid()
        or not unaware then
        lastOpportunistDebug.result = rank == 0 and "C chain inactive"
            or attack.successful ~= true and "hit unsuccessful"
            or (not target or not target:isValid()) and "target invalid"
            or "target aware"
        return
    end
    local key = Common.targetKey(target)
    if not key or struckTargets[key] then
        lastOpportunistDebug.result = not key and "target key unavailable"
            or "already used against this target"
        return
    end
    struckTargets[key] = true
    attack.skillPerksSneakOpportunistMultiplier = C_MULT[rank]
    attack.skillPerksSneakOpportunistDebug = lastOpportunistDebug
    lastOpportunistDebug.multiplier = C_MULT[rank]
    lastOpportunistDebug.result = "queued for late damage resolution"
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, handleOutgoingHit)

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ids.C1 .. "_sneak_hit",
    priority = 350,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack)
        routeOutgoingHit(attack, attack.skillPerksHitSource or "framework")
    end,
})

local function clearSneakState()
    skillTracker.clearAll()
    effectTracker.clearAll()
    phantomTracker.clearAll()
    phantomTimer = 0
    phantomExtended = false
    struckTargets = {}
    combatTargets = {}
    appliedSilentSpeed = 0
    lastSilentMovement = nil
    lastOpportunistDebug = nil
end

local function onUpdate(dt)
    updateSneakBonus()
    updateSilentMovement()
    maybeStartPhantom()
    tickPhantom(dt)
end

local function onSave()
    return {
        skill = skillTracker.snapshot(),
        effects = effectTracker.snapshot(),
        phantom = phantomTracker.snapshot(),
        phantomTimer = phantomTimer,
        struckTargets = struckTargets,
    }
end

local function onLoad(data)
    data = data or {}
    skillTracker.restoreAndReverse(data.skill)
    effectTracker.restoreAndReverse(data.effects)
    phantomTracker.restoreAndReverse(data.phantom)
    phantomTimer = data.phantomTimer or 0
    -- Reloading ends the current encounter boundary; no target should remain
    -- permanently marked as already struck after combat state is rebuilt.
    struckTargets = {}
    combatTargets = {}
    lastSilentMovement = nil
    lastOpportunistDebug = nil
end

-- Shows sneak transitions, combat awareness, and first-strike target memory.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Sneak",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luasneak debug" },
    snapshot = function()
        return {
            string.format(
                "Movement: sneaking=%s silentSpeed=%s phantomTimer=%s extended=%s",
                tostring(lastSneaking),
                SkillDebug.number(appliedSilentSpeed),
                SkillDebug.number(phantomTimer),
                tostring(phantomExtended)
            ),
            lastSilentMovement and string.format(
                "Sneak compensation: rank=%d sprinting=%s swimming=%s encumbrance=%.2f normalWalk=%.2f targetSneak=%.2f requiredSpeed=%.2f applied=%.2f",
                tonumber(lastSilentMovement.rank) or 0,
                tostring(lastSilentMovement.sprinting),
                tostring(lastSilentMovement.swimming),
                tonumber(lastSilentMovement.encumbranceRatio) or 0,
                tonumber(lastSilentMovement.normalWalkSpeed) or 0,
                tonumber(lastSilentMovement.targetSneakSpeed) or 0,
                tonumber(lastSilentMovement.requiredAttribute) or 0,
                tonumber(lastSilentMovement.appliedSpeed) or 0
            ) or "Sneak compensation: no update observed.",
            string.format(
                "Target memory: struck=%d combatTargets=%d",
                SkillDebug.count(struckTargets),
                SkillDebug.count(combatTargets)
            ),
            lastOpportunistDebug and string.format(
                "Opportunist: rank=%s target=%s success=%s unaware=%s base=%.2f multiplier=%s afterRegular=%s final=%s result=%s",
                tostring(lastOpportunistDebug.rank),
                tostring(lastOpportunistDebug.target),
                tostring(lastOpportunistDebug.successful),
                tostring(lastOpportunistDebug.unaware),
                tonumber(lastOpportunistDebug.baseDamage) or 0,
                tostring(lastOpportunistDebug.multiplier),
                tostring(lastOpportunistDebug.afterRegularDamage),
                tostring(lastOpportunistDebug.finalDamage),
                tostring(lastOpportunistDebug.result)
            ) or "Opportunist: no hit observed.",
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Sneak", ids, {
    A1 = { localizedName = "Shadow Step", localizedFlavour = "You learn to move where attention is thinnest, letting silence gather around every careful footfall.", localizedDescription = "While sneaking, gain +5 Sneak.", onRemove = clearSneakState },
    A2 = { localizedName = "Soft Footfall", localizedFlavour = "Your steps stop asking the world for permission. Dust settles louder than you do.", localizedDescription = "Shadow Step increases to +10 Sneak.", onRemove = clearSneakState },
    A3 = { localizedName = "Held Breath", localizedFlavour = "You become a pause in the room: present, patient, and almost impossible to place.", localizedDescription = "Shadow Step increases to +15 Sneak.", onRemove = clearSneakState },
    A4 = { localizedName = "Absent Shape", localizedFlavour = "Even when eyes pass over you, they find nothing worth remembering.", localizedDescription = "Shadow Step increases to +20 Sneak.", onRemove = clearSneakState },
    B1 = { localizedName = "Silenced Movement", localizedFlavour = "Caution no longer shackles you. You flow low and quiet, quick enough to matter.", localizedDescription = "While sneaking, half of the normal movement speed penalty is offset, including while sprinting.", onRemove = clearSneakState },
    B2 = { localizedName = "Noiseless Haste", localizedFlavour = "Speed and silence stop arguing. The dark makes room and you take it.", localizedDescription = "The normal sneaking movement penalty is fully offset, including while sprinting.", onRemove = clearSneakState },
    C1 = { localizedName = "Opportunist", localizedFlavour = "The first wound is a thesis: precise, cruel, and delivered before the lesson begins.", localizedDescription = "The first unaware hit against a target deals 150% damage.", onRemove = clearSneakState },
    C2 = { localizedName = "Knife in the Quiet", localizedFlavour = "When you strike from nothing, the moment does not bend. It breaks.", localizedDescription = "Opportunist increases to 200% damage.", onRemove = clearSneakState },
    D1 = { localizedName = "Phantom", localizedFlavour = "You do not vanish. You teach the eye to doubt itself.", localizedDescription = "Entering sneak while in combat grants Chameleon 40% for 3 seconds.", onRemove = clearSneakState },
    D2 = { localizedName = "Vanishing Point", localizedFlavour = "By the time danger has a shape, yours has already left the room.", localizedDescription = "Phantom increases to Chameleon 60%. Breaking combat during the initial window extends it by 5 seconds.", onRemove = clearSneakState },
})

return {
    eventHandlers = {
        OMWMusicCombatTargetsChanged = onCombatTargetsChanged,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
