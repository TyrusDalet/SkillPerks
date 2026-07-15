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
    spells.lua

    safeAddSpell/safeRemoveSpell: identical idempotent pattern to
    scripts/FactionPerks/utils.lua's own functions of the same name.
    Needed here too since the framework re-fires onAdd for every held perk
    on every load, and several SkillPerks perks grant powers/spells the
    same way FactionPerks' IL3/FG3/TT/MT/EEC4/IC4 perks do.
]]

local Spells = {}

--- @param actor table The actor (usually `self`) to grant the spell to.
--- @param spellId string
function Spells.safeAddSpell(actor, spellId)
    local types = require("openmw.types")
    local spellList = types.Actor.spells(actor)
    if not spellList[spellId] then
        spellList:add(spellId)
    end
end

--- @param actor table The actor (usually `self`) to remove the spell from.
--- @param spellId string
function Spells.safeRemoveSpell(actor, spellId)
    local types = require("openmw.types")
    local spellList = types.Actor.spells(actor)
    if spellList[spellId] then
        spellList:remove(spellId)
    end
end

return Spells
