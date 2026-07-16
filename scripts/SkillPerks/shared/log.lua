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

--- @param category string|nil A dedupe key. Consecutive calls with the same
---   category are silently dropped so one noisy onUpdate loop doesn't spam
---   the console. Pass nil to always print regardless of the last category.
--- @param message string|fun():string A literal string, or a function
---   returning one - use the function form for anything even slightly
---   expensive to build, since it's only evaluated when logging is on.
local function Log(category, message)
    if not settings.enableLogging then
        return
    end
    if (category ~= nil) and (lastLoggedMessageCategory == category) then
        return
    end
    if type(message) == "function" then
        print(message())
    else
        print(message)
    end
    lastLoggedMessageCategory = category
end

return Log
