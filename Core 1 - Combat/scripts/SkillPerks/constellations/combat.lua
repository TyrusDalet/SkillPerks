--[[
SkillPerks Combat constellation definitions.
Copyright (C) 2025 Erin Pentecost
2026 Robbie Barker

Core 1 owns these symbols and coordinates. ErnPerkFramework renders the data
without needing any knowledge of SkillPerks' skill list or asset layout.
]]

local interfaces = require("openmw.interfaces")

-- These colours match the authored DDS branches: advancement, technique,
-- aggression, and control for the A, B, C, and D chains respectively.
local chainColors = {
    A = { 0.929, 0.710, 0.078 },
    B = { 0.224, 0.396, 0.882 },
    C = { 0.902, 0.259, 0.208 },
    D = { 0.294, 0.800, 0.341 },
}

local chainRanks = {
    A = { "A1", "A2", "A3", "A4" },
    B = { "B1", "B2" },
    C = { "C1", "C2" },
    D = { "D1", "D2" },
}

-- Every position is keyed by perk ID and normalized from the approved 256px
-- Option 2 artwork. A3 opens C1/D1, while A4 rejoins the chosen branch before
-- C2/D2. The texture and clickable node share the same authored coordinates.
local constellations = {
    Armorer = {
        texture = "textures/SkillPerks/constellations/combat_armorer.dds",
        prefix = "armorer",
        points = {
            A1 = { .3086, .7695 }, A2 = { .7773, .8477 },
            A3 = { .5430, .7227 }, A4 = { .5273, .4609 },
            B1 = { .1602, .2031 }, B2 = { .8867, .2813 },
            C1 = { .6875, .6250 }, D1 = { .4102, .6797 },
            C2 = { .8828, .4414 }, D2 = { .1055, .5391 },
        },
    },
    Athletics = {
        texture = "textures/SkillPerks/constellations/combat_athletics.dds",
        prefix = "athletics",
        points = {
            A1 = { .4531, .2266 }, A2 = { .4961, .5117 },
            A3 = { .5117, .6680 }, A4 = { .5195, .8359 },
            B1 = { .3438, .4297 }, B2 = { .6016, .3906 },
            C1 = { .8047, .7344 }, D1 = { .3320, .6953 },
            C2 = { .6328, .7930 }, D2 = { .3867, .8828 },
        },
    },
    Axe = {
        texture = "textures/SkillPerks/constellations/combat_axe.dds",
        prefix = "axe",
        points = {
            A1 = { .7148, .9453 }, A2 = { .6406, .6797 },
            A3 = { .5586, .3945 }, A4 = { .5313, .2656 },
            B1 = { .6094, .2969 }, B2 = { .8242, .2695 },
            C1 = { .3242, .5430 }, D1 = { .1719, .2539 },
            C2 = { .2383, .4492 }, D2 = { .1953, .1523 },
        },
    },
    Block = {
        texture = "textures/SkillPerks/constellations/combat_block.dds",
        prefix = "block",
        points = {
            A1 = { .5000, .9180 }, A2 = { .5000, .6484 },
            A3 = { .5156, .3516 }, A4 = { .5039, .0977 },
            B1 = { .3203, .4922 }, B2 = { .6953, .4961 },
            C1 = { .7930, .5938 }, D1 = { .1797, .6172 },
            C2 = { .8438, .2070 }, D2 = { .1602, .2109 },
        },
    },
    ["Blunt Weapon"] = {
        texture = "textures/SkillPerks/constellations/combat_blunt.dds",
        prefix = "blunt",
        points = {
            A1 = { .7969, .9375 }, A2 = { .6172, .6680 },
            A3 = { .4883, .4414 }, A4 = { .3281, .1328 },
            B1 = { .2344, .4883 }, B2 = { .6836, .2617 },
            C1 = { .7500, .6133 }, D1 = { .5117, .7305 },
            C2 = { .5273, .1484 }, D2 = { .2383, .2695 },
        },
    },
    ["Heavy Armor"] = {
        texture = "textures/SkillPerks/constellations/combat_heavyarmor.dds",
        prefix = "heavyarmor",
        points = {
            A1 = { .2539, .8906 }, A2 = { .7305, .8750 },
            A3 = { .6172, .5000 }, A4 = { .1875, .6133 },
            B1 = { .2500, .1758 }, B2 = { .8281, .3828 },
            C1 = { .2578, .4648 }, D1 = { .2148, .7930 },
            C2 = { .4297, .3398 }, D2 = { .4766, .7617 },
        },
    },
    ["Long Blade"] = {
        texture = "textures/SkillPerks/constellations/combat_longblade.dds",
        prefix = "longblade",
        points = {
            A1 = { .7891, .9414 }, A2 = { .5742, .6328 },
            A3 = { .3828, .3633 }, A4 = { .1641, .0859 },
            B1 = { .5313, .8789 }, B2 = { .8086, .6758 },
            C1 = { .5820, .4961 }, D1 = { .4063, .6172 },
            C2 = { .3320, .1719 }, D2 = { .1719, .2539 },
        },
    },
    ["Medium Armor"] = {
        texture = "textures/SkillPerks/constellations/combat_mediumarmor.dds",
        prefix = "mediumarmor",
        points = {
            A1 = { .2930, .8594 }, A2 = { .7031, .8555 },
            A3 = { .5039, .4141 }, A4 = { .4961, .1719 },
            B1 = { .2969, .6484 }, B2 = { .7188, .6445 },
            C1 = { .8008, .5273 }, D1 = { .2227, .5391 },
            C2 = { .7578, .1797 }, D2 = { .2305, .1836 },
        },
    },
    Spear = {
        texture = "textures/SkillPerks/constellations/combat_spear.dds",
        prefix = "spear",
        points = {
            A1 = { .7266, .9453 }, A2 = { .5664, .7070 },
            A3 = { .4727, .5625 }, A4 = { .1953, .1055 },
            B1 = { .4688, .8477 }, B2 = { .7305, .6992 },
            C1 = { .6016, .4961 }, D1 = { .3594, .6289 },
            C2 = { .3594, .2422 }, D2 = { .2422, .2734 },
        },
    },
}

local function perkId(definition, rank)
    return "SkillPerks_" .. definition.prefix .. "_" .. rank:lower()
end

--- Uses the Core's paired naming convention while keeping both texture paths
--- explicit in the Framework registration returned to other renderers.
local function completedTexture(texture)
    return texture:gsub("%.dds$", "_complete.dds")
end

--- Builds restrained progressive star lighting from the same four chains
--- represented in the DDS. The authored texture already contains its routes,
--- so SkillPerks does not add a second set of ownership connection lines.
local function buildOwnershipHighlights(definition)
    local nodeColors = {}
    for chain, ranks in pairs(chainRanks) do
        local color = chainColors[chain]
        for _, rank in ipairs(ranks) do
            local id = perkId(definition, rank)
            nodeColors[id] = color
        end
    end
    return nodeColors
end

--- Registers every installed Combat skill as a separate SkillPerks
--- constellation. Registration is presentation-only and does not alter perk
--- requirements, costs, ownership, or effect handlers.
local function registerCombatConstellations()
    for skillName, definition in pairs(constellations) do
        local positions = {}
        for rank, point in pairs(definition.points) do
            positions[perkId(definition, rank)] = point
        end
        local ownedNodeColors = buildOwnershipHighlights(definition)
        interfaces.ErnPerkFramework.registerConstellation({
            mod = "SkillPerks",
            type = "Combat",
            group = skillName,
            shapeSize = { 220, 220 },
            texture = definition.texture,
            completedTexture = completedTexture(definition.texture),
            positions = positions,
            ownedNodeColors = ownedNodeColors,
            suppressInternalDependencyLines = true,
        })
    end
end

registerCombatConstellations()

return {}
