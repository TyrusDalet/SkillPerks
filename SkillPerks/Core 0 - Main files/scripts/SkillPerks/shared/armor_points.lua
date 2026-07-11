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
    armor_points.lua

    The weighted-point "Mostly Light/Medium/Heavy Armor" system, defined
    identically in SkillPerks_Combat.md and SkillPerks_Stealth.md's own
    Shared Infrastructure sections. Used by Medium Armor's whole tree,
    Heavy Armor A-D, Light Armor A/B/D, and referenced by name from several
    other skills' flavour text.

    Point table (Slot -> Light/Medium/Heavy points):
        Cuirass          3 / 3 / 3
        Greaves          2 / 3 / 3
        Shield           2 / 2 / 2  (3 for Heavy Tower Shield - see below)
        Helmet           1 / 2 / 2
        Left Pauldron    1 / 1 / 1
        Right Pauldron   1 / 1 / 1
        Left Gauntlet    1 / 1 / 1
        Right Gauntlet   1 / 1 / 1
        Boots            1 / 1 / 1
        TOTAL           13 /15 /15 (Heavy: 16 with Tower Shield)

    Thresholds: Mostly Light 7+, Mostly Medium 8+, Mostly Heavy 8+.

    ARMOR CLASS DETECTION: uses the built-in interfaces.Combat.getArmorSkill(item),
    confirmed present via direct source review of Inventory Extender
    (helpers.lua's getItemSound calls it to pick light/medium/heavy hit
    sounds) - NOT something this mod needs to infer from record fields by
    hand. Returns 'lightarmor' / 'mediumarmor' / 'heavyarmor'.

    TOWER SHIELD DETECTION: vanilla's Armor.TYPE enum has no distinct Tower
    Shield entry (only Shield) - see openmw's types.lua ArmorTYPE doc. There
    is no direct API field for this. Detected here via a record-id substring
    heuristic, same style as FactionPerks HR's Sixth House check. FLAGGED
    FOR VALIDATION, same as the design doc's own "Tower shield detection -
    validate weight threshold approach" implementation note; the substring
    list below is a starting point, not a guarantee of full coverage across
    every mod's tower shield naming.
]]

local types = require("openmw.types")
local interfaces = require("openmw.interfaces")

local ArmorPoints = {}

local POINTS = {
    lightarmor = {
        Cuirass = 3, Greaves = 2, Shield = 2, Helmet = 1,
        LeftPauldron = 1, RightPauldron = 1,
        LeftGauntlet = 1, RightGauntlet = 1, Boots = 1,
    },
    mediumarmor = {
        Cuirass = 3, Greaves = 3, Shield = 2, Helmet = 2,
        LeftPauldron = 1, RightPauldron = 1,
        LeftGauntlet = 1, RightGauntlet = 1, Boots = 1,
    },
    heavyarmor = {
        Cuirass = 3, Greaves = 3, Shield = 2, Helmet = 2,
        LeftPauldron = 1, RightPauldron = 1,
        LeftGauntlet = 1, RightGauntlet = 1, Boots = 1,
    },
}

ArmorPoints.THRESHOLD = {
    lightarmor = 7,
    mediumarmor = 8,
    heavyarmor = 8,
}

-- Slots participating in the point system, mapped to their EQUIPMENT_SLOT
-- constant. Left/Right Bracer (Armor.TYPE.LBracer/RBracer, used by some
-- content) map onto the Gauntlet slots per Armor's own record.type ->
-- equipment slot relationship, so no separate table entries are needed
-- for those - they occupy the same physical slot as Gauntlets.
local TRACKED_SLOTS = {
    Cuirass        = types.Actor.EQUIPMENT_SLOT.Cuirass,
    Greaves        = types.Actor.EQUIPMENT_SLOT.Greaves,
    Shield         = types.Actor.EQUIPMENT_SLOT.CarriedLeft,
    Helmet         = types.Actor.EQUIPMENT_SLOT.Helmet,
    LeftPauldron   = types.Actor.EQUIPMENT_SLOT.LeftPauldron,
    RightPauldron  = types.Actor.EQUIPMENT_SLOT.RightPauldron,
    LeftGauntlet   = types.Actor.EQUIPMENT_SLOT.LeftGauntlet,
    RightGauntlet  = types.Actor.EQUIPMENT_SLOT.RightGauntlet,
    Boots          = types.Actor.EQUIPMENT_SLOT.Boots,
}

-- Heuristic substrings for Tower Shield detection. Lower-cased record id
-- match, same style as FactionPerks HR's SIXTH_HOUSE_CREATURES table.
local TOWER_SHIELD_HINTS = {
    "tower_shield",
    "tower shield",
    "towershield",
}

local function isTowerShield(item)
    local id = (item.recordId or ""):lower()
    for _, hint in ipairs(TOWER_SHIELD_HINTS) do
        if id:find(hint, 1, true) then
            return true
        end
    end
    return false
end

--- Computes the weighted armor-class point totals for everything the actor
--- currently has equipped in the 9 tracked slots.
--- @param actor table
--- @return table points { lightarmor = n, mediumarmor = n, heavyarmor = n }
--- @return table breakdown Per-slot info for callers that need it (e.g.
---   Heavy Armor D chain's "full set" check, which needs to know WHICH
---   slots are heavy, not just the total).
function ArmorPoints.getPoints(actor)
    local points = { lightarmor = 0, mediumarmor = 0, heavyarmor = 0 }
    local breakdown = {}

    for slotName, slotId in pairs(TRACKED_SLOTS) do
        local item = types.Actor.getEquipment(actor, slotId)
        if item and types.Armor.objectIsInstance(item) then
            local armorClass = interfaces.Combat.getArmorSkill(item)
            if armorClass and POINTS[armorClass] then
                local slotPoints = POINTS[armorClass][slotName] or 0
                -- Heavy Tower Shield exception: 3 points instead of 2.
                if slotName == "Shield" and armorClass == "heavyarmor" and isTowerShield(item) then
                    slotPoints = 3
                end
                points[armorClass] = points[armorClass] + slotPoints
                breakdown[slotName] = { item = item, armorClass = armorClass, points = slotPoints }
            end
        end
    end

    return points, breakdown
end

--- @param actor table
--- @param armorClass string One of "lightarmor", "mediumarmor", "heavyarmor"
--- @return boolean True if the actor meets that class's "Mostly X" threshold.
function ArmorPoints.isMostly(actor, armorClass)
    local points = ArmorPoints.getPoints(actor)
    return (points[armorClass] or 0) >= ArmorPoints.THRESHOLD[armorClass]
end

--- Heavy Armor D chain's "full set" check: Cuirass, Greaves, both
--- Pauldrons, both Gauntlets, and Boots must ALL be Heavy Armor. Helmet
--- and Shield are explicitly excluded per the design doc.
--- @param actor table
--- @return boolean
function ArmorPoints.isFullHeavySet(actor)
    local _, breakdown = ArmorPoints.getPoints(actor)
    local requiredSlots = {
        "Cuirass", "Greaves", "LeftPauldron", "RightPauldron",
        "LeftGauntlet", "RightGauntlet", "Boots",
    }
    for _, slotName in ipairs(requiredSlots) do
        local entry = breakdown[slotName]
        if not entry or entry.armorClass ~= "heavyarmor" then
            return false
        end
    end
    return true
end

return ArmorPoints
