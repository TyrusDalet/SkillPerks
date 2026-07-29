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

local A_BONUS = { [1] = 5, [2] = 10, [3] = 15, [4] = 20 }
local C_MULT = { [1] = 1.5, [2] = 2.0 }
local D_CHAMELEON = { [1] = 40, [2] = 60 }

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

-- Softens the movement penalty by adding Speed while sneaking.
local function updateSilentMovement()
    local rank = isSneaking() and bRank() or 0
    local value = 0
    if rank > 0 and not Common.controlActive(self, "sprint") then
        local speed = types.Actor.stats.attributes.speed(self)
        local unmodifiedByPerk = math.max(0, (speed.modified or speed.base or 0) - appliedSilentSpeed)
        local ok, gmst = pcall(core.getGMST, "fSneakSpeedMultiplier")
        local sneakMultiplier = ok and tonumber(gmst) or 0.75
        sneakMultiplier = math.max(0.05, math.min(1, sneakMultiplier))
        local desiredMultiplier = rank >= 2 and 1 or ((1 + sneakMultiplier) / 2)
        value = unmodifiedByPerk * ((desiredMultiplier / sneakMultiplier) - 1)
    end
    appliedSilentSpeed = value
    skillTracker.apply("attributes", "speed", value)
    effectTracker.apply("fortifyattribute", "speed", value)
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

--- Opportunist adds the missing share of the first unaware strike after the
--- target's normal post-armour damage has resolved.
local function handleOutgoingHit(attack)
    SkillDebug.traceEvent(SKILL_ID, "Opportunist check", {
        successful = attack and attack.successful,
        unaware = attack and Common.isUnawareHit(attack),
    })
    local rank = cRank()
    local target = Common.attackTarget(attack)
    if rank == 0 or attack.successful ~= true or not target or not target:isValid()
        or not Common.isUnawareHit(attack) then
        return
    end
    local key = Common.targetKey(target)
    if not key or struckTargets[key] then
        return
    end
    struckTargets[key] = true
    Common.applyBonusHealthDamage(
        attack,
        Common.healthDamage(attack) * (C_MULT[rank] - 1),
        self,
        ids["C" .. tostring(rank)],
        "sneak.opportunist")
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
            string.format(
                "Target memory: struck=%d combatTargets=%d",
                SkillDebug.count(struckTargets),
                SkillDebug.count(combatTargets)
            ),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Sneak", ids, {
    A1 = { localizedName = "Shadow Step", localizedFlavour = "You learn to move where attention is thinnest, letting silence gather around every careful footfall.", localizedDescription = "While sneaking, gain +5 Sneak.", onRemove = clearSneakState },
    A2 = { localizedName = "Soft Footfall", localizedFlavour = "Your steps stop asking the world for permission. Dust settles louder than you do.", localizedDescription = "Shadow Step increases to +10 Sneak.", onRemove = clearSneakState },
    A3 = { localizedName = "Held Breath", localizedFlavour = "You become a pause in the room: present, patient, and almost impossible to place.", localizedDescription = "Shadow Step increases to +15 Sneak.", onRemove = clearSneakState },
    A4 = { localizedName = "Absent Shape", localizedFlavour = "Even when eyes pass over you, they find nothing worth remembering.", localizedDescription = "Shadow Step increases to +20 Sneak.", onRemove = clearSneakState },
    B1 = { localizedName = "Silenced Movement", localizedFlavour = "Caution no longer shackles you. You flow low and quiet, quick enough to matter.", localizedDescription = "While sneaking, half of the normal movement speed penalty is offset. Sprint remains penalized.", onRemove = clearSneakState },
    B2 = { localizedName = "Noiseless Haste", localizedFlavour = "Speed and silence stop arguing. The dark makes room and you take it.", localizedDescription = "The normal sneaking movement penalty is fully offset. Sprint remains penalized.", onRemove = clearSneakState },
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
