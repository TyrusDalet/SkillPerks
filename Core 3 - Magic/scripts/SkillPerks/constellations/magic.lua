--[[
SkillPerks Magic constellation definitions.
Copyright (C) 2026 Robbie Barker

Coordinates are normalized from the approved Magic Option 2 artwork. A3 opens
C1/D1, while A4 rejoins the chosen branch before C2/D2.
]]

local interfaces = require("openmw.interfaces")

local chainColors = {
    A = { 0.929, 0.710, 0.078 },
    B = { 0.224, 0.396, 0.882 },
    C = { 0.294, 0.800, 0.341 },
    D = { 0.902, 0.259, 0.208 },
}
local chainRanks = {
    A = { "A1", "A2", "A3", "A4" },
    B = { "B1", "B2" }, C = { "C1", "C2" }, D = { "D1", "D2" },
}
local definitions = {
    Alchemy = { prefix = "alchemy", points = {
        A1={.3086,.8477},A2={.6680,.8477},A3={.4648,.6484},A4={.4922,.2305},
        B1={.3438,.1016},B2={.6289,.1016},C1={.5859,.5391},C2={.5859,.2891},
        D1={.3867,.5273},D2={.4023,.2813},
    }},
    Alteration = { prefix = "alteration", points = {
        A1={.5000,.8828},A2={.4844,.6289},A3={.4805,.3672},A4={.4727,.1094},
        B1={.1680,.4453},B2={.8047,.4453},C1={.6758,.8750},C2={.6602,.1289},
        D1={.3125,.8867},D2={.2930,.1289},
    }},
    Conjuration = { prefix = "conjuration", points = {
        A1={.1680,.3906},A2={.7813,.3945},A3={.4805,.9141},A4={.4688,.0859},
        B1={.1055,.5078},B2={.8477,.5156},C1={.7344,.9141},C2={.7266,.5508},
        D1={.2734,.8984},D2={.2656,.5781},
    }},
    Destruction = { prefix = "destruction", points = {
        A1={.1680,.3125},A2={.8008,.2852},A3={.4883,.4336},A4={.5156,.8477},
        B1={.3203,.1992},B2={.6445,.1875},C1={.7617,.5000},C2={.6641,.7578},
        D1={.1797,.4805},D2={.3633,.7695},
    }},
    Enchant = { prefix = "enchant", points = {
        A1={.1445,.5898},A2={.4727,.8164},A3={.4219,.6094},A4={.4531,.1680},
        B1={.2852,.8750},B2={.6953,.8789},C1={.8555,.6797},C2={.6563,.2461},
        D1={.3828,.3867},D2={.1563,.2070},
    }},
    Illusion = { prefix = "illusion", points = {
        A1={.1758,.4961},A2={.7344,.5273},A3={.5156,.9102},A4={.4883,.0742},
        B1={.1563,.3359},B2={.8516,.3438},C1={.8125,.8164},C2={.8008,.1523},
        D1={.2422,.8281},D2={.2305,.1250},
    }},
    Mysticism = { prefix = "mysticism", points = {
        A1={.1367,.2813},A2={.8398,.2773},A3={.4883,.9180},A4={.5000,.0742},
        B1={.2500,.4883},B2={.7383,.4805},C1={.8438,.6953},C2={.8438,.4766},
        D1={.1445,.7227},D2={.1484,.4766},
    }},
    Restoration = { prefix = "restoration", points = {
        A1={.2383,.7578},A2={.7383,.7930},A3={.4883,.5469},A4={.5039,.1094},
        B1={.3320,.8477},B2={.6328,.8477},C1={.7734,.5781},C2={.7500,.1172},
        D1={.2148,.5820},D2={.2148,.1094},
    }},
    Unarmored = { prefix = "unarmored", points = {
        A1={.4883,.8711},A2={.4805,.5664},A3={.4922,.2656},A4={.4883,.0703},
        B1={.2227,.3867},B2={.7539,.3984},C1={.6641,.6133},C2={.6641,.2734},
        D1={.3203,.6250},D2={.3281,.2734},
    }},
}

local function perkId(definition, rank)
    return "SkillPerks_" .. definition.prefix .. "_" .. rank:lower()
end

local function register(skillName)
    local definition = definitions[skillName]
    if not definition then return false end
    local positions, colors = {}, {}
    for rank, point in pairs(definition.points) do
        positions[perkId(definition, rank)] = point
    end
    for chain, ranks in pairs(chainRanks) do
        for _, rank in ipairs(ranks) do
            colors[perkId(definition, rank)] = chainColors[chain]
        end
    end
    local texture = "textures/SkillPerks/constellations/magic_" .. definition.prefix .. ".dds"
    interfaces.ErnPerkFramework.registerConstellation({
        mod = "SkillPerks", type = "Magic", group = skillName,
        shapeSize = { 220, 220 },
        texture = texture,
        completedTexture = texture:gsub("%.dds$", "_complete.dds"),
        positions = positions,
        ownedNodeColors = colors,
        suppressInternalDependencyLines = true,
    })
    return true
end

return { register = register }
