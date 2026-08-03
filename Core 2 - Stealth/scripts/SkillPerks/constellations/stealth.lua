--[[
SkillPerks Stealth constellation definitions.
Copyright (C) 2025 Erin Pentecost
2026 Robbie Barker

Core 2 owns these symbols and coordinates. ErnPerkFramework renders the data
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

-- Every point is keyed by perk rank and normalized from the approved 256px
-- Option 2 artwork. A3 opens C1/D1, while A4 rejoins the chosen branch before
-- C2/D2. The texture and clickable node share the same authored coordinates.
local constellations = {
    Acrobatics = {
        texture = "textures/SkillPerks/constellations/stealth_acrobatics.dds",
        prefix = "acrobatics",
        points = {
            A1 = { .4883, .1172 }, A2 = { .5039, .2969 },
            A3 = { .5156, .5469 }, A4 = { .5430, .9141 },
            B1 = { .1992, .4258 }, B2 = { .7773, .4297 },
            C1 = { .4258, .5938 }, D1 = { .7070, .6172 },
            C2 = { .4375, .8594 }, D2 = { .5938, .6914 },
        },
    },
    ["Hand-to-Hand"] = {
        texture = "textures/SkillPerks/constellations/stealth_handtohand.dds",
        prefix = "handtohand",
        points = {
            A1 = { .2266, .3711 }, A2 = { .1719, .6211 },
            A3 = { .3438, .7070 }, A4 = { .7422, .5547 },
            B1 = { .3398, .3281 }, B2 = { .6641, .2578 },
            C1 = { .3359, .5000 }, D1 = { .5547, .7422 },
            C2 = { .6211, .3750 }, D2 = { .7813, .7227 },
        },
    },
    ["Light Armor"] = {
        texture = "textures/SkillPerks/constellations/stealth_lightarmor.dds",
        prefix = "lightarmor",
        points = {
            A1 = { .2734, .8672 }, A2 = { .7656, .8633 },
            A3 = { .3047, .5430 }, A4 = { .4883, .1641 },
            B1 = { .4922, .2617 }, B2 = { .4961, .4375 },
            C1 = { .2891, .2734 }, D1 = { .6992, .5352 },
            C2 = { .3711, .0898 }, D2 = { .6172, .0938 },
        },
    },
    Marksman = {
        texture = "textures/SkillPerks/constellations/stealth_marksman.dds",
        prefix = "marksman",
        points = {
            A1 = { .2656, .0820 }, A2 = { .4258, .3867 },
            A3 = { .5938, .6406 }, A4 = { .7539, .9258 },
            B1 = { .3516, .0859 }, B2 = { .5469, .1836 },
            C1 = { .5625, .7773 }, D1 = { .7227, .6836 },
            C2 = { .6406, .9141 }, D2 = { .8281, .8398 },
        },
    },
    Mercantile = {
        texture = "textures/SkillPerks/constellations/stealth_mercantile.dds",
        prefix = "mercantile",
        points = {
            A1 = { .1719, .6484 }, A2 = { .4414, .3516 },
            A3 = { .7383, .6172 }, A4 = { .4531, .8750 },
            B1 = { .2539, .1250 }, B2 = { .6563, .1484 },
            C1 = { .5625, .6016 }, D1 = { .8008, .7266 },
            C2 = { .5234, .7344 }, D2 = { .7891, .9141 },
        },
    },
    Security = {
        texture = "textures/SkillPerks/constellations/stealth_security.dds",
        prefix = "security",
        points = {
            A1 = { .6445, .8945 }, A2 = { .5352, .5898 },
            A3 = { .4453, .3164 }, A4 = { .3438, .0977 },
            B1 = { .6797, .8203 }, B2 = { .8125, .7617 },
            C1 = { .3398, .3906 }, D1 = { .5781, .2773 },
            C2 = { .2617, .2383 }, D2 = { .4961, .1484 },
        },
    },
    ["Short Blade"] = {
        texture = "textures/SkillPerks/constellations/stealth_shortblade.dds",
        prefix = "shortblade",
        points = {
            A1 = { .6836, .8984 }, A2 = { .4258, .4844 },
            A3 = { .3633, .3750 }, A4 = { .2695, .0820 },
            B1 = { .4219, .7539 }, B2 = { .6914, .5352 },
            C1 = { .2617, .3203 }, D1 = { .4531, .2773 },
            C2 = { .2109, .1914 }, D2 = { .3672, .1875 },
        },
    },
    Sneak = {
        texture = "textures/SkillPerks/constellations/stealth_sneak.dds",
        prefix = "sneak",
        points = {
            A1 = { .4961, .7070 }, A2 = { .8203, .7266 },
            A3 = { .6680, .4922 }, A4 = { .6523, .9141 },
            B1 = { .1172, .0703 }, B2 = { .5664, .2813 },
            C1 = { .5703, .3594 }, D1 = { .7500, .3789 },
            C2 = { .5195, .6211 }, D2 = { .8047, .6133 },
        },
    },
    Speechcraft = {
        texture = "textures/SkillPerks/constellations/stealth_speechcraft.dds",
        prefix = "speechcraft",
        points = {
            A1 = { .7734, .5273 }, A2 = { .7734, .2500 },
            A3 = { .5273, .4492 }, A4 = { .2227, .7578 },
            B1 = { .7852, .6406 }, B2 = { .7852, .8984 },
            C1 = { .4102, .3867 }, D1 = { .6133, .5898 },
            C2 = { .0977, .4922 }, D2 = { .5000, .9063 },
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

--- Registers one Stealth skill's visual definition immediately before that
--- skill registers its perks. Keeping both registrations in the same player
--- script lifecycle prevents startup ordering from leaving a fallback graph.
--- @param skillName string Exact category group used by the skill's perks.
--- @return boolean registered True when the skill has an authored definition.
local function registerStealthConstellation(skillName)
    local definition = constellations[skillName]
    if not definition then
        return false
    end
    local positions = {}
    for rank, point in pairs(definition.points) do
        positions[perkId(definition, rank)] = point
    end
    local ownedNodeColors = buildOwnershipHighlights(definition)
    interfaces.ErnPerkFramework.registerConstellation({
        mod = "SkillPerks",
        type = "Stealth",
        group = skillName,
        shapeSize = { 220, 220 },
        texture = definition.texture,
        completedTexture = completedTexture(definition.texture),
        positions = positions,
        ownedNodeColors = ownedNodeColors,
        suppressInternalDependencyLines = true,
    })
    return true
end

return {
    register = registerStealthConstellation,
}
