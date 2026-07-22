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
-- reference artwork. The texture and clickable node therefore share one
-- coordinate source and cannot drift when registration order changes.
local constellations = {
    Armorer = {
        texture = "textures/SkillPerks/constellations/combat_armorer.dds",
        prefix = "armorer",
        points = {
            A1 = { .3750, .8398 }, A2 = { .7422, .8359 },
            A3 = { .5469, .7148 }, A4 = { .5156, .4883 },
            B1 = { .2188, .2070 }, B2 = { .8594, .2734 },
            C1 = { .3125, .5352 }, D1 = { .6953, .4805 },
            C2 = { .1172, .5430 }, D2 = { .8672, .4492 },
        },
    },
    Athletics = {
        texture = "textures/SkillPerks/constellations/combat_athletics.dds",
        prefix = "athletics",
        points = {
            A1 = { .4570, .2852 }, A2 = { .4023, .4688 },
            A3 = { .5469, .4453 }, A4 = { .5078, .6523 },
            B1 = { .3203, .4258 }, B2 = { .6211, .3906 },
            C1 = { .3398, .6992 }, D1 = { .6367, .7773 },
            C2 = { .3672, .8750 }, D2 = { .8086, .7461 },
        },
    },
    Axe = {
        texture = "textures/SkillPerks/constellations/combat_axe.dds",
        prefix = "axe",
        points = {
            A1 = { .6914, .9336 }, A2 = { .6367, .7109 },
            A3 = { .5977, .5312 }, A4 = { .5273, .3125 },
            B1 = { .6406, .2852 }, B2 = { .8320, .2656 },
            C1 = { .3945, .2812 }, D1 = { .4219, .4375 },
            C2 = { .1953, .1758 }, D2 = { .3320, .5469 },
        },
    },
    Block = {
        texture = "textures/SkillPerks/constellations/combat_block.dds",
        prefix = "block",
        points = {
            A1 = { .5000, .8711 }, A2 = { .4922, .6211 },
            A3 = { .5078, .3906 }, A4 = { .5000, .1445 },
            B1 = { .2734, .4961 }, B2 = { .7148, .4883 },
            C1 = { .3125, .1523 }, D1 = { .7148, .1758 },
            C2 = { .1641, .2852 }, D2 = { .8594, .2461 },
        },
    },
    ["Blunt Weapon"] = {
        texture = "textures/SkillPerks/constellations/combat_blunt.dds",
        prefix = "blunt",
        points = {
            A1 = { .7773, .8984 }, A2 = { .6250, .6641 },
            A3 = { .3359, .1797 }, A4 = { .5039, .4375 },
            B1 = { .3281, .4609 }, B2 = { .6484, .3203 },
            C1 = { .4375, .5469 }, D1 = { .5508, .2656 },
            C2 = { .3359, .3320 }, D2 = { .6836, .4883 },
        },
    },
    ["Heavy Armor"] = {
        texture = "textures/SkillPerks/constellations/combat_heavyarmor.dds",
        prefix = "heavyarmor",
        points = {
            A1 = { .2852, .8711 }, A2 = { .6992, .8594 },
            A3 = { .5078, .3555 }, A4 = { .4844, .5430 },
            B1 = { .3164, .1562 }, B2 = { .7852, .4258 },
            C1 = { .3516, .5273 }, D1 = { .3867, .6172 },
            C2 = { .2305, .5586 }, D2 = { .2070, .6523 },
        },
    },
    ["Long Blade"] = {
        texture = "textures/SkillPerks/constellations/combat_longblade.dds",
        prefix = "longblade",
        points = {
            A1 = { .7812, .9141 }, A2 = { .5508, .6211 },
            A3 = { .4062, .4102 }, A4 = { .1953, .1133 },
            B1 = { .5078, .8555 }, B2 = { .7969, .6523 },
            C1 = { .2500, .2734 }, D1 = { .3477, .2461 },
            C2 = { .4414, .5508 }, D2 = { .5391, .4883 },
        },
    },
    ["Medium Armor"] = {
        texture = "textures/SkillPerks/constellations/combat_mediumarmor.dds",
        prefix = "mediumarmor",
        points = {
            A1 = { .4961, .8711 }, A2 = { .5000, .6719 },
            A3 = { .5117, .4766 }, A4 = { .5039, .2539 },
            B1 = { .3086, .8438 }, B2 = { .7070, .8477 },
            C1 = { .3555, .2891 }, D1 = { .7109, .3047 },
            C2 = { .1992, .4375 }, D2 = { .8281, .4570 },
        },
    },
    Spear = {
        texture = "textures/SkillPerks/constellations/combat_spear.dds",
        prefix = "spear",
        points = {
            A1 = { .7070, .9141 }, A2 = { .5859, .7344 },
            A3 = { .4297, .4844 }, A4 = { .2031, .1250 },
            B1 = { .2695, .7031 }, B2 = { .7070, .4062 },
            C1 = { .2266, .3008 }, D1 = { .3477, .2148 },
            C2 = { .3398, .6055 }, D2 = { .5898, .4727 },
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

--- Builds progressive lighting metadata from the same four chains represented
--- in the DDS. Consecutive owned ranks illuminate their connecting stroke, and
--- the mutually exclusive C and D branches both begin at A4.
local function buildOwnershipHighlights(definition)
    local nodeColors = {}
    local links = {}
    for chain, ranks in pairs(chainRanks) do
        local color = chainColors[chain]
        for index, rank in ipairs(ranks) do
            local id = perkId(definition, rank)
            nodeColors[id] = color
            if index > 1 then
                table.insert(links, {
                    from = perkId(definition, ranks[index - 1]),
                    to = id,
                    color = color,
                })
            end
        end
    end
    for _, branch in ipairs({ "C", "D" }) do
        table.insert(links, {
            from = perkId(definition, "A4"),
            to = perkId(definition, branch .. "1"),
            color = chainColors[branch],
        })
    end
    return nodeColors, links
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
        local ownedNodeColors, ownedLinks = buildOwnershipHighlights(definition)
        interfaces.ErnPerkFramework.registerConstellation({
            mod = "SkillPerks",
            type = "Combat",
            group = skillName,
            shapeSize = { 220, 220 },
            texture = definition.texture,
            completedTexture = completedTexture(definition.texture),
            positions = positions,
            ownedNodeColors = ownedNodeColors,
            ownedLinks = ownedLinks,
            suppressInternalDependencyLines = true,
        })
    end
end

registerCombatConstellations()

return {}
