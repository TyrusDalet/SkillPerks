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
-- reference artwork. The texture and clickable node therefore share one
-- coordinate source and cannot drift when registration order changes.
local constellations = {
    Acrobatics = {
        texture = "textures/SkillPerks/constellations/stealth_acrobatics.dds",
        prefix = "acrobatics",
        points = {
            A1 = { .5078, .8867 }, A2 = { .4609, .7266 },
            A3 = { .5000, .5586 }, A4 = { .5000, .3828 },
            B1 = { .5469, .7383 }, B2 = { .6914, .6250 },
            C1 = { .6133, .4180 }, D1 = { .4258, .4141 },
            C2 = { .7695, .4531 }, D2 = { .2148, .4336 },
        },
    },
    ["Hand-to-Hand"] = {
        texture = "textures/SkillPerks/constellations/stealth_handtohand.dds",
        prefix = "handtohand",
        points = {
            A1 = { .2422, .3984 }, A2 = { .1914, .5977 },
            A3 = { .3672, .6875 }, A4 = { .5391, .6367 },
            B1 = { .7070, .2930 }, B2 = { .7617, .5625 },
            C1 = { .5859, .7227 }, D1 = { .4453, .5312 },
            C2 = { .7930, .7188 }, D2 = { .4883, .4414 },
        },
    },
    ["Light Armor"] = {
        texture = "textures/SkillPerks/constellations/stealth_lightarmor.dds",
        prefix = "lightarmor",
        points = {
            A1 = { .3047, .8477 }, A2 = { .7305, .8750 },
            A3 = { .5078, .5820 }, A4 = { .5078, .2266 },
            B1 = { .3320, .5078 }, B2 = { .7031, .5078 },
            C1 = { .6211, .2109 }, D1 = { .3633, .2148 },
            C2 = { .8516, .2852 }, D2 = { .1641, .2695 },
        },
    },
    Marksman = {
        texture = "textures/SkillPerks/constellations/stealth_marksman.dds",
        prefix = "marksman",
        points = {
            A1 = { .3438, .2227 }, A2 = { .4336, .4219 },
            A3 = { .5430, .6094 }, A4 = { .6172, .7188 },
            B1 = { .2617, .0859 }, B2 = { .4102, .1602 },
            C1 = { .7578, .7227 }, D1 = { .5977, .7969 },
            C2 = { .8125, .8711 }, D2 = { .6953, .9180 },
        },
    },
    Mercantile = {
        texture = "textures/SkillPerks/constellations/stealth_mercantile.dds",
        prefix = "mercantile",
        points = {
            A1 = { .2461, .8672 }, A2 = { .6914, .8828 },
            A3 = { .4531, .6562 }, A4 = { .4531, .3359 },
            B1 = { .3242, .1094 }, B2 = { .6094, .1211 },
            C1 = { .5742, .2812 }, D1 = { .3398, .2734 },
            C2 = { .6641, .1562 }, D2 = { .2500, .1406 },
        },
    },
    Security = {
        texture = "textures/SkillPerks/constellations/stealth_security.dds",
        prefix = "security",
        points = {
            A1 = { .6602, .9141 }, A2 = { .5742, .6602 },
            A3 = { .4844, .4531 }, A4 = { .4219, .2344 },
            B1 = { .7070, .8047 }, B2 = { .8281, .7812 },
            C1 = { .4844, .1562 }, D1 = { .3867, .3789 },
            C2 = { .5781, .2812 }, D2 = { .3125, .2148 },
        },
    },
    ["Short Blade"] = {
        texture = "textures/SkillPerks/constellations/stealth_shortblade.dds",
        prefix = "shortblade",
        points = {
            A1 = { .2734, .1094 }, A2 = { .3398, .3203 },
            A3 = { .4453, .5000 }, A4 = { .5664, .6445 },
            B1 = { .6250, .7305 }, B2 = { .7109, .9023 },
            C1 = { .6523, .5977 }, D1 = { .4805, .6914 },
            C2 = { .7188, .5312 }, D2 = { .3945, .7969 },
        },
    },
    Sneak = {
        texture = "textures/SkillPerks/constellations/stealth_sneak.dds",
        prefix = "sneak",
        points = {
            A1 = { .5469, .8906 }, A2 = { .7891, .9023 },
            A3 = { .6641, .7539 }, A4 = { .6484, .5195 },
            B1 = { .1406, .0820 }, B2 = { .4688, .2578 },
            C1 = { .7617, .5430 }, D1 = { .5391, .5391 },
            C2 = { .7930, .3945 }, D2 = { .5469, .3789 },
        },
    },
    Speechcraft = {
        texture = "textures/SkillPerks/constellations/stealth_speechcraft.dds",
        prefix = "speechcraft",
        points = {
            A1 = { .8047, .8828 }, A2 = { .7852, .6289 },
            A3 = { .7930, .4141 }, A4 = { .8008, .2812 },
            B1 = { .1133, .5859 }, B2 = { .4219, .8945 },
            C1 = { .5938, .6016 }, D1 = { .4375, .3828 },
            C2 = { .5039, .9102 }, D2 = { .1016, .5117 },
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
