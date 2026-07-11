--[[
    SkillPerks settings.lua

    Registers the mod settings page and exposes the current values.
    Structure mirrors scripts/FactionPerks/Settings/settings.lua exactly,
    since that lookup-metatable pattern already proved itself there.

    Kept deliberately small for the shared runtime. Individual Combat,
    Stealth, and Magic files can register their own settings groups on this
    same page later via interfaces.Settings.registerGroup, the same way
    FactionPerks and ErnPerkFramework each own a single page but nothing
    stops additional groups being added to it from other files.
]]

local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local MOD_NAME = require("scripts.SkillPerks.namespace")

local SECTION = "Settings" .. MOD_NAME

local DEFAULTS = {
    enableLogging = false,
    disable = false,
}

local function init()
    interfaces.Settings.registerPage {
        key = MOD_NAME,
        l10n = MOD_NAME,
        name = "name",
    }

    interfaces.Settings.registerGroup {
        key = SECTION,
        page = MOD_NAME,
        l10n = MOD_NAME,
        name = "settings",
        permanentStorage = true,
        settings = {
            -- Master kill switch. Individual perk files should check this
            -- (via settings.disable) before registering, same as
            -- ErnPerkFramework's own "disable" setting, so a player can
            -- turn the whole mod off without unloading it.
            {
                key = "disable",
                name = "disableName",
                description = "disableDescription",
                default = DEFAULTS.disable,
                renderer = "checkbox",
            },
            {
                key = "enableLogging",
                name = "enableLoggingName",
                description = "enableLoggingDescription",
                default = DEFAULTS.enableLogging,
                renderer = "checkbox",
            },
        },
    }
end

local section = storage.playerSection(SECTION)

local lookup = {
    __index = function(tbl, key)
        if key == "init" then
            return init
        elseif key == "MOD_NAME" then
            return MOD_NAME
        elseif DEFAULTS[key] ~= nil then
            local val = tbl.section:get(key)
            if val ~= nil then
                return val
            end
            return DEFAULTS[key]
        end

        local val = tbl.section:get(key)
        if val ~= nil then
            return val
        end
        error("unknown setting " .. tostring(key))
    end,
}

local container = {
    section = section,
}
setmetatable(container, lookup)

return container
