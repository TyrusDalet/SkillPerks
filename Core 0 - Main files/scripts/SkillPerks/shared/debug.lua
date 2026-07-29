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

-- Shared presentation helpers keep every skill's console command predictable.
-- Skill-specific files still decide which live fields prove their effects ran.

local interfaces = require("openmw.interfaces")
local storage = require("openmw.storage")
local types = require("openmw.types")
local ui = require("openmw.ui")

local Log = require("scripts.SkillPerks.shared.log")

local Debug = {}
local traceSection = storage.playerSection("SkillPerksDebugTrace")

pcall(function()
    traceSection:setLifeTime(storage.LIFE_TIME.GameSession)
end)

--- Normalizes a skill identifier before using it as a trace-state key.
--- @param skillId any
--- @return string
local function traceKey(skillId)
    return tostring(skillId or "unknown"):lower()
end

--- Reports whether live trace output is enabled for one skill.
--- Verbosity is enforced by the shared logger when a trace is emitted.
--- @param skillId any
--- @return boolean
function Debug.isTraceEnabled(skillId)
    return traceSection:get(traceKey(skillId)) == true
end

--- Reports whether any skill currently needs Core 0 boundary diagnostics.
--- An optional list limits the check to skills which consume that boundary.
--- @param skillIds table|nil
--- @return boolean
function Debug.anyTraceEnabled(skillIds)
    if skillIds then
        for _, skillId in ipairs(skillIds) do
            if Debug.isTraceEnabled(skillId) then
                return true
            end
        end
        return false
    end
    for _, enabled in pairs(traceSection:asTable()) do
        if enabled == true then
            return true
        end
    end
    return false
end

--- Changes the temporary live-trace state for one skill.
--- @param skillId any
--- @param enabled boolean
function Debug.setTraceEnabled(skillId, enabled)
    traceSection:set(traceKey(skillId), enabled == true)
end

--- Emits one per-activation diagnostic when this skill's trace is enabled.
--- The shared logger additionally requires SkillPerks verbosity 3.
--- @param skillId any
--- @param message string|fun():string
function Debug.trace(skillId, message)
    if not Debug.isTraceEnabled(skillId) then
        return
    end
    Log(3, nil, message)
end

--- Emits a compact, stable key/value trace for one observed activation.
--- @param skillId any
--- @param label string
--- @param fields table|nil
function Debug.traceEvent(skillId, label, fields)
    Debug.trace(skillId, function()
        local keys = {}
        for key in pairs(fields or {}) do
            keys[#keys + 1] = tostring(key)
        end
        table.sort(keys)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = key .. "=" .. Debug.value(fields[key])
        end
        local suffix = #parts > 0 and (": " .. table.concat(parts, " ")) or ""
        return "SkillPerks " .. tostring(skillId) .. " [" .. tostring(label) .. "]" .. suffix
    end)
end

--- Wraps a lifecycle callback so resync, acquisition, and removal are visible.
--- @param skillId any
--- @param label string
--- @param callback fun(...):any|nil
--- @return function
function Debug.wrapCallback(skillId, label, callback)
    callback = callback or function() end
    return function(...)
        Debug.trace(skillId, "SkillPerks " .. tostring(skillId) .. ": " .. tostring(label))
        return callback(...)
    end
end

--- Prints diagnostic text to the visible OpenMW console.
--- @param message any
function Debug.print(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

--- Formats numbers compactly without hiding useful fractional values.
--- @param value any
--- @param decimals number|nil
--- @return string
function Debug.number(value, decimals)
    local numeric = tonumber(value)
    if not numeric then
        return tostring(value)
    end
    local places = decimals or 2
    return string.format("%." .. tostring(places) .. "f", numeric)
end

--- Produces a stable readable representation for common diagnostic values.
--- @param value any
--- @return string
function Debug.value(value)
    if value == nil then return "nil" end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "number" then return Debug.number(value) end
    return tostring(value)
end

--- Reads an object's record id without letting an unavailable object break debug.
--- @param object any
--- @return string
function Debug.objectId(object)
    if object == nil then return "nil" end
    local ok, id = pcall(function() return object.recordId end)
    if ok and id then return tostring(id) end
    return "<unavailable>"
end

--- Counts entries in either an array or a keyed runtime-state table.
--- @param values table|nil
--- @return number
function Debug.count(values)
    local count = 0
    for _ in pairs(values or {}) do
        count = count + 1
    end
    return count
end

--- Safely reads one dynamic resource from an actor.
--- @param actor GameObject
--- @param resource string
--- @return string
function Debug.resourceSummary(actor, resource)
    local ok, stat = pcall(function()
        return types.Actor.stats.dynamic[resource](actor)
    end)
    if not ok or not stat then
        return "unavailable"
    end
    return string.format(
        "base=%s modifier=%s current=%s",
        Debug.number(stat.base),
        Debug.number(stat.modifier),
        Debug.number(stat.current)
    )
end

--- Returns the highest owned rank in one standard SkillPerks chain.
--- @param ids table
--- @param chain string
--- @return number
function Debug.rank(ids, chain)
    local framework = interfaces.ErnPerkFramework
    if not framework or type(framework.playerHasPerk) ~= "function" then
        return 0
    end

    local maximum = chain == "A" and 4 or 2
    for rank = maximum, 1, -1 do
        local id = ids[chain .. tostring(rank)]
        if id then
            local ok, owned = pcall(framework.playerHasPerk, id)
            if ok and owned then
                return rank
            end
        end
    end
    return 0
end

--- Returns all four standard chain ranks.
--- @param ids table
--- @return table
function Debug.ranks(ids)
    return {
        A = Debug.rank(ids, "A"),
        B = Debug.rank(ids, "B"),
        C = Debug.rank(ids, "C"),
        D = Debug.rank(ids, "D"),
    }
end

--- Safely reads a player's current skill values.
--- @param actor GameObject
--- @param skillId string
--- @return string
function Debug.skillSummary(actor, skillId)
    local ok, skill = pcall(function()
        return types.NPC.stats.skills[skillId](actor)
    end)
    if not ok or not skill then
        return "unavailable"
    end
    return string.format(
        "base=%s modifier=%s modified=%s",
        Debug.number(skill.base),
        Debug.number(skill.modifier),
        Debug.number(skill.modified)
    )
end

--- Tests whether a console command matches one of a skill's aliases.
--- @param command any
--- @param commands table
--- @return boolean
function Debug.matches(command, commands)
    local normalized = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    for _, candidate in ipairs(commands or {}) do
        if normalized == tostring(candidate):lower() then
            return true
        end
    end
    return false
end

--- Prints the standard header and a skill-provided live-state snapshot.
--- Snapshot callbacks return an array of already-labelled lines.
--- @param config table
function Debug.describe(config)
    local ranks = Debug.ranks(config.ids or {})
    Debug.print(string.format(
        "%s: skill(%s) chains A=%d B=%d C=%d D=%d",
        config.name or config.skillId or "Skill",
        Debug.skillSummary(config.actor, config.skillId),
        ranks.A,
        ranks.B,
        ranks.C,
        ranks.D
    ))

    if type(config.snapshot) ~= "function" then
        return
    end

    local ok, lines = pcall(config.snapshot, ranks)
    if not ok then
        Debug.print((config.name or config.skillId or "Skill") .. " debug snapshot failed: " .. tostring(lines))
        return
    end
    if type(lines) == "string" then
        Debug.print(lines)
        return
    end
    for _, line in ipairs(lines or {}) do
        Debug.print(line)
    end
end

--- Handles the ` trace` variant of one skill's console command.
--- @param config table
--- @param command any
--- @return boolean
function Debug.handleTraceCommand(config, command)
    local normalized = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    for _, candidate in ipairs(config.commands or {}) do
        local traceCommand = tostring(candidate):lower() .. " trace"
        if normalized == traceCommand then
            local skillId = config.traceId or config.skillId
            local enabled = not Debug.isTraceEnabled(skillId)
            Debug.setTraceEnabled(skillId, enabled)
            Debug.print(string.format(
                "%s live trace %s. Trace output requires SkillPerks verbosity 3.",
                config.name or config.skillId or "Skill",
                enabled and "enabled" or "disabled"
            ))
            return true
        end
    end
    return false
end

--- Creates an onConsoleCommand-compatible handler.
--- @param config table
--- @return fun(mode:any, command:any):boolean
function Debug.makeHandler(config)
    return function(mode, command)
        if Debug.handleTraceCommand(config, command) then
            return true
        end

        if Debug.matches(command, config.commands) then
            Debug.describe(config)
            return true
        end
        return false
    end
end

return Debug
