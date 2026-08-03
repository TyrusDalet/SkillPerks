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
    chain_requirements.lua

    All SkillPerks skills share the same 10-perk slot table:

        A1 (25) -> A2 (50) -> A3 (75) -> A4 (100)
        B1 (50) -> B2 (100)
        A3 -> C1 (75) / D1 (75)  <- mutually exclusive
        A4 + C1 -> C2 (100) / A4 + D1 -> D2 (100)

    Rather than hand-write this prerequisite chain for every skill,
    ChainRequirements.forSlot() builds it once from a skill id and a table of
    that skill's own perk ids. A3 opens the mutually exclusive branches, while
    A4 rejoins the chosen branch before its final perk. This is the Option 2
    route shown by every authored SkillPerks constellation.

    Exclusivity is implemented the same way FactionPerks' dummy.lua demo
    perks 11-13 already demonstrate (invert(hasPerk(other))), not some new
    mechanism - ErnPerkFramework's own sync loop re-evaluates every perk's
    requirements continuously, so this is sufficient without needing any
    extra bookkeeping here.

    Every returned requirement list is the FULL slot's requirement list,
    including the minimumSkillLevel gate - callers should append any
    additional perk-specific requirements (attribute minimums, N'Garde
    checks, etc.) to the returned table rather than replacing it.
]]

local interfaces = require("openmw.interfaces")
local self = require("openmw.self")
local types = require("openmw.types")
local MOD_NAME = require("scripts.SkillPerks.namespace")
local settings = require("scripts.SkillPerks.Settings.settings")

local ChainRequirements = {}

-- Skill level required to unlock each slot. C1 and D1 open alongside A3 at
-- skill 75; their final upgrades still require A4 and mastery-level skill.
local SLOT_LEVEL = {
    A1 = 25, A2 = 50, A3 = 75, A4 = 100,
    B1 = 50, B2 = 100,
    C1 = 75, C2 = 100,
    D1 = 75, D2 = 100,
}

--- Reads SkillPerks menu visibility with a defensive default.
--- @return number mode Visibility mode selected in SkillPerks settings.
local function currentVisibilityMode()
    return tonumber(settings.perkVisibilityMode) or 3
end

--- Returns the player's base value for a skill.
--- SkillPerks uses base skill for acquisition, matching Framework
--- minimumSkillLevel requirements and avoiding temporary buff unlocks.
--- @param skillId string OpenMW skill id.
--- @return number value Player base skill value.
local function getSkillBase(skillId)
    local getter = types.NPC.stats.skills[skillId]
    if not getter then
        return 0
    end
    local ok, stat = pcall(getter, self)
    if not ok or not stat then
        return 0
    end
    return tonumber(stat.base) or 0
end

--- Checks whether the player currently owns a perk id.
--- @param perkId string|nil Full Framework perk id.
--- @return boolean owned True when the player has the perk.
local function hasPerk(perkId)
    return perkId ~= nil and interfaces.ErnPerkFramework.playerHasPerk(perkId) == true
end

--- Checks direct chain prerequisites for visibility mode 4.
--- This intentionally ignores later perk-specific requirements appended by
--- individual files; mode 5 handles those by evaluating the final list.
--- @param perkIds table Skill perk id map.
--- @param slot string Chain slot.
--- @return boolean reachable True when the chain path is open.
local function chainPathReachable(perkIds, slot)
    if slot == "A2" then
        return hasPerk(perkIds.A1)
    elseif slot == "A3" then
        return hasPerk(perkIds.A2)
    elseif slot == "A4" then
        return hasPerk(perkIds.A3)
    elseif slot == "B2" then
        return hasPerk(perkIds.B1)
    elseif slot == "C1" then
        return hasPerk(perkIds.A3) and not hasPerk(perkIds.D1)
    elseif slot == "D1" then
        return hasPerk(perkIds.A3) and not hasPerk(perkIds.C1)
    elseif slot == "C2" then
        return hasPerk(perkIds.A4) and hasPerk(perkIds.C1)
    elseif slot == "D2" then
        return hasPerk(perkIds.A4) and hasPerk(perkIds.D1)
    end

    return true
end

--- Checks the final requirement list, including perk-specific appended gates.
--- @param reqs table Requirement list returned by forSlot().
--- @return boolean satisfied True when every non-omitted requirement passes.
local function allRequirementsSatisfied(reqs)
    for _, req in ipairs(reqs) do
        local omitted = false
        if type(req.omit) == "function" then
            omitted = req.omit()
        else
            omitted = req.omit == true
        end

        if not omitted and type(req.check) == "function" and not req.check() then
            return false
        end
    end
    return true
end

--- Builds the hidden predicate shared by every standard SkillPerks slot.
---
--- Visibility modes:
--- 1: never hidden
--- 2: hide until the relevant skill reaches 25
--- 3: hide until the relevant skill reaches this slot's skill tier
--- 4: hide until skill tier and chain path are reachable
--- 5: hide until all requirements, including custom appended gates, are met
--- @param skillId string OpenMW skill id.
--- @param perkIds table Skill perk id map.
--- @param slot string Chain slot.
--- @param reqs table Requirement list returned by forSlot().
--- @return function hidden Predicate suitable for Framework menu filtering.
local function hiddenForSlot(skillId, perkIds, slot, reqs)
    local slotLevel = SLOT_LEVEL[slot] or 100

    return function()
        local mode = currentVisibilityMode()
        if mode == 1 then
            return false
        end

        local skillBase = getSkillBase(skillId)
        if mode == 2 then
            return skillBase < SLOT_LEVEL.A1
        elseif mode == 3 then
            return skillBase < slotLevel
        elseif mode == 4 then
            return skillBase < slotLevel or not chainPathReachable(perkIds, slot)
        elseif mode == 5 then
            return not allRequirementsSatisfied(reqs)
        end

        return skillBase < slotLevel
    end
end

--- @param skillId string OpenMW skill id, e.g. "longblade", "destruction"
--- @param perkIds table Map of slot name -> full perk id string for THIS skill's
---   own perks, e.g. { A1 = "SPerks_LongBlade_A1", A2 = "...", ..., C1 = "...", D1 = "..." }
---   Only the slots that exist on this skill's chosen chain shape need be present
---   (e.g. Alchemy/Enchant/Unarmored are exempt from the four-slot Magic framework
---   but still use this same A/B/C/D prerequisite table).
--- @param slot string One of "A1".."A4", "B1", "B2", "C1", "C2", "D1", "D2".
--- @return table A list of requirement objects, ready to insert into `requirements = {...}`.
function ChainRequirements.forSlot(skillId, perkIds, slot)
    local level = SLOT_LEVEL[slot]
    if not level then
        error("chain_requirements: unknown slot '" .. tostring(slot) .. "'", 2)
    end

    local R = interfaces.ErnPerkFramework.requirements()
    local reqs = { R.minimumSkillLevel(skillId, level) }

    if slot == "A2" then
        table.insert(reqs, R.hasPerk(perkIds.A1))
    elseif slot == "A3" then
        table.insert(reqs, R.hasPerk(perkIds.A2))
    elseif slot == "A4" then
        table.insert(reqs, R.hasPerk(perkIds.A3))
    elseif slot == "B2" then
        table.insert(reqs, R.hasPerk(perkIds.B1))
    elseif slot == "C1" then
        table.insert(reqs, R.hasPerk(perkIds.A3))
        -- Mutually exclusive with D1. If the skill has no D chain at all
        -- (shouldn't happen given the framework, but guard anyway),
        -- perkIds.D1 being nil would make hasPerk() error, so only add
        -- the exclusion when a D1 id was actually supplied.
        if perkIds.D1 then
            table.insert(reqs, R.invert(R.hasPerk(perkIds.D1)))
        end
    elseif slot == "D1" then
        table.insert(reqs, R.hasPerk(perkIds.A3))
        if perkIds.C1 then
            table.insert(reqs, R.invert(R.hasPerk(perkIds.C1)))
        end
    elseif slot == "C2" then
        table.insert(reqs, R.hasPerk(perkIds.A4))
        table.insert(reqs, R.hasPerk(perkIds.C1))
    elseif slot == "D2" then
        table.insert(reqs, R.hasPerk(perkIds.A4))
        table.insert(reqs, R.hasPerk(perkIds.D1))
    end

    reqs.hidden = hiddenForSlot(skillId, perkIds, slot, reqs)

    return reqs
end

--- Builds a Framework category table using the expanded mod/type/group/order
--- shape. Future SkillPerks perk files should use this rather than legacy
--- three-part categories so the Framework UI places them under the
--- SkillPerks top-level tab.
--- @param discipline string "Combat", "Stealth", or "Magic".
--- @param skillName string Display name for the skill group.
--- @param order number Sort order inside the skill group.
--- @return table category Framework category metadata.
function ChainRequirements.category(discipline, skillName, order)
    return {
        mod = MOD_NAME,
        type = discipline,
        group = skillName,
        order = order,
    }
end

return ChainRequirements
