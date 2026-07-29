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

-- Deliberately mirrors ErnPerkFramework/log.lua's shape (category +
-- de-duplication of consecutive identical-category spam) rather than
-- inventing a new logging convention, since every perk file in this mod
-- is already going to be printing a lot of "X applied / Y removed" noise
-- during testing, same as FactionPerks does.

local settings = require("scripts.SkillPerks.Settings.settings")

local lastLoggedMessageCategory = nil
local lastLoggedMessage = nil

--- Returns the active debug verbosity.
--- `enableLogging` is kept as a legacy fallback for existing saves/configs.
--- @return number verbosity 0 off, 1 important, 2 detailed, 3 trace.
local function configuredVerbosity()
    local verbosity = tonumber(settings.debugVerbosity) or 0
    if verbosity <= 0 and settings.enableLogging then
        verbosity = 1
    end
    return verbosity
end

--- Normalizes old and new logging signatures.
--- Supported forms:
---   log(category, message)           -> level 1
---   log(level, category, message)    -> explicit level
local function normalizeArgs(a, b, c)
    if type(a) == "number" then
        return a, b, c
    end
    return 1, a, b
end

--- @param category string|nil A dedupe key. Below trace verbosity, only an
---   immediately repeated identical category/message pair is suppressed.
---   Trace-level calls always print every observation.
--- @param message string|fun():string A literal string, or a function
---   returning one - use the function form for anything even slightly
---   expensive to build, since it's only evaluated when logging is on.
local function Log(a, b, c)
    local level, category, message = normalizeArgs(a, b, c)
    if configuredVerbosity() < level then
        return
    end
    local rendered
    if type(message) == "function" then
        rendered = message()
    else
        rendered = message
    end
    if level < 3
            and category ~= nil
            and lastLoggedMessageCategory == category
            and lastLoggedMessage == rendered then
        return
    end
    print(rendered)
    lastLoggedMessageCategory = category
    lastLoggedMessage = rendered
end

return Log
