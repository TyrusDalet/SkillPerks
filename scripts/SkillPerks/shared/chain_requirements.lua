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

    All 27 skills across all three design docs (Combat/Stealth/Magic)
    share the exact same 10-perk slot table:

        A1 (25) -> A2 (50) -> A3 (75) -> A4 (100)
        B1 (50) -> B2 (100)
        C1 (75) / D1 (75)  <- mutually exclusive
        C2 (100, requires A4+C1) / D2 (100, requires A4+D1)

    See the "Perk Tree Structure" section repeated verbatim at the top of
    all three SkillPerks_*.md docs. Rather than hand-write this identical
    prerequisite chain 27 times, ChainRequirements.forSlot() builds it once
    from a skill id + a table of that skill's own perk ids.

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
local MOD_NAME = require("scripts.SkillPerks.namespace")

local ChainRequirements = {}

-- Skill level required to unlock each slot. Identical across every skill
-- in every one of the three docs - see each doc's "Perk Tree Structure" table.
local SLOT_LEVEL = {
    A1 = 25, A2 = 50, A3 = 75, A4 = 100,
    B1 = 50, B2 = 100,
    C1 = 75, C2 = 100,
    D1 = 75, D2 = 100,
}

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
        -- Mutually exclusive with D1. If the skill has no D chain at all
        -- (shouldn't happen given the framework, but guard anyway),
        -- perkIds.D1 being nil would make hasPerk() error, so only add
        -- the exclusion when a D1 id was actually supplied.
        if perkIds.D1 then
            table.insert(reqs, R.invert(R.hasPerk(perkIds.D1)))
        end
    elseif slot == "D1" then
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
