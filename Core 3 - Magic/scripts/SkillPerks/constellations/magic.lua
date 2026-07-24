--[[
SkillPerks Magic constellation definitions.
Copyright (C) 2026 Robbie Barker

Coordinates are normalized from the approved Magic preview artwork.
]]

local interfaces = require("openmw.interfaces")

local chainColors = {
    A = { 0.929, 0.710, 0.078 },
    B = { 0.224, 0.396, 0.882 },
    C = { 0.902, 0.259, 0.208 },
    D = { 0.294, 0.800, 0.341 },
}
local chainRanks = {
    A = { "A1", "A2", "A3", "A4" },
    B = { "B1", "B2" }, C = { "C1", "C2" }, D = { "D1", "D2" },
}
local definitions = {
    Alchemy = { prefix = "alchemy", points = {
        A1={.3516,.6562},A2={.4922,.9062},A3={.6523,.6641},A4={.5000,.2812},
        B1={.4844,.5078},B2={.4961,.7734},C1={.4062,.2344},C2={.3086,.1289},
        D1={.5664,.2383},D2={.6914,.1133},
    }},
    Alteration = { prefix = "alteration", points = {
        A1={.2148,.8906},A2={.7422,.8789},A3={.5039,.6250},A4={.5039,.1641},
        B1={.3633,.2656},B2={.6211,.2617},C1={.3164,.1836},C2={.3242,.7812},
        D1={.6641,.1914},D2={.6836,.7578},
    }},
    Conjuration = { prefix = "conjuration", points = {
        A1={.1875,.3867},A2={.5039,.0859},A3={.7852,.3828},A4={.4922,.4766},
        B1={.5117,.6016},B2={.4883,.8867},C1={.2617,.5469},C2={.2734,.8867},
        D1={.7578,.5391},D2={.7266,.9102},
    }},
    Destruction = { prefix = "destruction", points = {
        A1={.2266,.3828},A2={.8047,.2852},A3={.5117,.4531},A4={.5234,.8164},
        B1={.6562,.1328},B2={.6602,.2500},C1={.6797,.8281},C2={.6875,.6953},
        D1={.4219,.6992},D2={.3320,.8516},
    }},
    Enchant = { prefix = "enchant", points = {
        A1={.1523,.6133},A2={.4961,.8359},A3={.4414,.6016},A4={.6836,.2422},
        B1={.1719,.2305},B2={.3867,.5586},C1={.4531,.1836},C2={.4414,.4844},
        D1={.8633,.6602},D2={.6289,.7070},
    }},
    Illusion = { prefix = "illusion", points = {
        A1={.1953,.4844},A2={.7500,.4766},A3={.5078,.6445},A4={.4844,.4688},
        B1={.2344,.1562},B2={.4805,.2734},C1={.3672,.6719},C2={.2656,.8281},
        D1={.6523,.3281},D2={.7930,.1562},
    }},
    Mysticism = { prefix = "mysticism", points = {
        A1={.1914,.3047},A2={.5039,.1055},A3={.8086,.3008},A4={.5078,.8984},
        B1={.1719,.7539},B2={.8438,.7656},C1={.3047,.6875},C2={.3203,.4023},
        D1={.7227,.6992},D2={.6914,.3867},
    }},
    Restoration = { prefix = "restoration", points = {
        A1={.2734,.7500},A2={.7383,.7773},A3={.4844,.4648},A4={.5000,.1836},
        B1={.3789,.8984},B2={.6133,.8867},C1={.2344,.1172},C2={.2148,.5938},
        D1={.7734,.1211},D2={.7539,.5703},
    }},
    Unarmored = { prefix = "unarmored", points = {
        A1={.2461,.2031},A2={.7070,.1875},A3={.6758,.7695},A4={.3398,.7773},
        B1={.3398,.2617},B2={.3359,.6484},C1={.4414,.6094},C2={.4297,.4219},
        D1={.5977,.6133},D2={.5859,.4062},
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
