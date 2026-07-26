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
local util = require("openmw.util")
local MOD_NAME = require("scripts.SkillPerks.namespace")

local SECTION = "Settings" .. MOD_NAME
local LONG_BLADE_HUD_SECTION = SECTION .. "LongBladeHUD"
local WARD_HUD_SECTION = SECTION .. "WardHUD"

local DEFAULTS = {
    enableLogging = false,
    debugVerbosity = 0,
    perkVisibilityMode = 3,
    disable = false,
}

local LONG_BLADE_HUD_DEFAULTS = {
    longBladeHudEnable = true,
    longBladeHudPosition = util.vector2(0, 0.45),
    longBladeHudUpdateEvery = 1,
}

local WARD_HUD_DEFAULTS = {
    wardHudEnable = true,
    wardHudPosition = util.vector2(1, 0.45),
    wardHudUpdateEvery = 2,
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
                key = "perkVisibilityMode",
                name = "perkVisibilityModeName",
                description = "perkVisibilityModeDescription",
                default = DEFAULTS.perkVisibilityMode,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 1,
                    max = 5,
                },
            },
            {
                key = "debugVerbosity",
                name = "debugVerbosityName",
                description = "debugVerbosityDescription",
                default = DEFAULTS.debugVerbosity,
                renderer = "number",
                argument = {
                    integer = true,
                    min = 0,
                    max = 3,
                },
            },
        },
    }

end

local function registerLongBladeHudSettings()
    interfaces.Settings.registerGroup {
        key = LONG_BLADE_HUD_SECTION,
        page = MOD_NAME,
        l10n = MOD_NAME,
        name = "longBladeHudSettings",
        permanentStorage = true,
        settings = {
            {
                key = "longBladeHudEnable",
                name = "longBladeHudEnableName",
                description = "longBladeHudEnableDescription",
                default = LONG_BLADE_HUD_DEFAULTS.longBladeHudEnable,
                renderer = "checkbox",
            },
            {
                key = "longBladeHudPosition",
                name = "longBladeHudPositionName",
                description = "longBladeHudPositionDescription",
                default = LONG_BLADE_HUD_DEFAULTS.longBladeHudPosition,
                renderer = "SkillPerksScreenPosition",
            },
            {
                key = "longBladeHudUpdateEvery",
                name = "longBladeHudUpdateEveryName",
                description = "longBladeHudUpdateEveryDescription",
                default = LONG_BLADE_HUD_DEFAULTS.longBladeHudUpdateEvery,
                renderer = "number",
                argument = {
                    min = 1,
                    integer = true,
                },
            },
        },
    }
end

--- Registers Ward of Delay's HUD controls when Core 3 is installed.
--- Keeping registration in the Restoration script prevents Magic-specific
--- settings from appearing for players who only installed the earlier cores.
local function registerWardHudSettings()
    interfaces.Settings.registerGroup {
        key = WARD_HUD_SECTION,
        page = MOD_NAME,
        l10n = MOD_NAME,
        name = "wardHudSettings",
        permanentStorage = true,
        settings = {
            {
                key = "wardHudEnable",
                name = "wardHudEnableName",
                description = "wardHudEnableDescription",
                default = WARD_HUD_DEFAULTS.wardHudEnable,
                renderer = "checkbox",
            },
            {
                key = "wardHudPosition",
                name = "wardHudPositionName",
                description = "wardHudPositionDescription",
                default = WARD_HUD_DEFAULTS.wardHudPosition,
                renderer = "SkillPerksScreenPosition",
            },
            {
                key = "wardHudUpdateEvery",
                name = "wardHudUpdateEveryName",
                description = "wardHudUpdateEveryDescription",
                default = WARD_HUD_DEFAULTS.wardHudUpdateEvery,
                renderer = "number",
                argument = {
                    min = 1,
                    integer = true,
                },
            },
        },
    }
end

local section = storage.playerSection(SECTION)
local longBladeHudSection = storage.playerSection(LONG_BLADE_HUD_SECTION)
local wardHudSection = storage.playerSection(WARD_HUD_SECTION)

local lookup = {
    __index = function(tbl, key)
        if key == "init" then
            return init
        elseif key == "registerLongBladeHudSettings" then
            return registerLongBladeHudSettings
        elseif key == "registerWardHudSettings" then
            return registerWardHudSettings
        elseif key == "MOD_NAME" then
            return MOD_NAME
        elseif DEFAULTS[key] ~= nil then
            local val = tbl.section:get(key)
            if val ~= nil then
                return val
            end
            return DEFAULTS[key]
        elseif LONG_BLADE_HUD_DEFAULTS[key] ~= nil then
            local val = tbl.longBladeHudSection:get(key)
            if val ~= nil then
                return val
            end
            return LONG_BLADE_HUD_DEFAULTS[key]
        elseif WARD_HUD_DEFAULTS[key] ~= nil then
            local val = tbl.wardHudSection:get(key)
            if val ~= nil then
                return val
            end
            return WARD_HUD_DEFAULTS[key]
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
    longBladeHudSection = longBladeHudSection,
    wardHudSection = wardHudSection,
}
setmetatable(container, lookup)

return container
