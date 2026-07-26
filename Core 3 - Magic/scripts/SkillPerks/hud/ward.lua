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

--[[
    Ward of Delay HUD

    Restoration owns the underlying reserve state. This module only turns that
    state into a compact HUD: the solid segment remains available to absorb
    damage, while the pale segment is reserve currently dissipating after a
    hit. Fatigue is omitted until Second Reservoir unlocks it.
]]

local async = require("openmw.async")
local interfaces = require("openmw.interfaces")
local ui = require("openmw.ui")
local util = require("openmw.util")

local settings = require("scripts.SkillPerks.Settings.settings")

local barTexture = ui.texture({ path = "textures/menu_bar_gray.dds" })

local BAR_SIZE = util.vector2(112, 12)
local BAR_EMPTY_COLOR = util.color.rgba(0.05, 0.04, 0.03, 0.76)
local HEALTH_COLOR = util.color.rgba(0.72, 0.16, 0.13, 0.88)
local FATIGUE_COLOR = util.color.rgba(0.12, 0.57, 0.20, 0.88)
local DISSIPATING_COLOR = util.color.rgba(0.58, 0.80, 1.00, 0.82)
local TEXT_COLOR = util.color.rgb(0.86, 0.74, 0.50)
local WHITE = util.color.rgb(1, 1, 1)

local hudElement = nil
local hudLayout = nil
local lastState = nil
local lastSignature = nil
local frameCounter = 0

local function interval()
    return { template = interfaces.MWUI.templates.interval }
end

--- Clamps a displayed reserve component to the current capacity.
local function clampComponent(value, maximum)
    return math.max(0, math.min(tonumber(value) or 0, maximum))
end

--- Converts fractional engine values into stable HUD labels.
local function displayNumber(value)
    return math.floor(math.max(0, tonumber(value) or 0) + 0.5)
end

local function shouldShow(state)
    return settings.wardHudEnable
        and state ~= nil
        and state.enabled == true
        and state.health ~= nil
        and (state.health.maximum or 0) > 0
end

--- Builds one segmented reserve bar.
--- The first segment is immediately available; the adjoining pale segment is
--- already committed to a recent hit and is currently dissipating.
local function renderReserveBar(resource)
    local maximum = math.max(tonumber(resource.maximum) or 0, 1)
    local available = clampComponent(resource.available, maximum)
    local dissipating = clampComponent(resource.dissipating, maximum - available)
    local fillColor = resource.label == "Fatigue" and FATIGUE_COLOR or HEALTH_COLOR
    local availableWidth = BAR_SIZE.x * available / maximum
    local dissipatingWidth = BAR_SIZE.x * dissipating / maximum
    local layers = {
        {
            type = ui.TYPE.Image,
            props = {
                size = BAR_SIZE,
                resource = barTexture,
                color = BAR_EMPTY_COLOR,
            },
        },
    }

    if availableWidth > 0 then
        table.insert(layers, {
            type = ui.TYPE.Image,
            props = {
                size = util.vector2(availableWidth, BAR_SIZE.y),
                resource = barTexture,
                color = fillColor,
            },
        })
    end
    if dissipatingWidth > 0 then
        table.insert(layers, {
            type = ui.TYPE.Image,
            props = {
                position = util.vector2(availableWidth, 0),
                size = util.vector2(dissipatingWidth, BAR_SIZE.y),
                resource = barTexture,
                color = DISSIPATING_COLOR,
            },
        })
    end

    table.insert(layers, {
        type = ui.TYPE.Text,
        props = {
            relativePosition = util.vector2(0.5, 0.5),
            anchor = util.vector2(0.5, 0.5),
            text = ("%d/%d"):format(displayNumber(available), displayNumber(maximum)),
            textColor = WHITE,
            textSize = 12,
        },
    })

    return {
        type = ui.TYPE.Flex,
        props = {
            horizontal = true,
            arrange = ui.ALIGNMENT.Center,
        },
        content = ui.content({
            {
                type = ui.TYPE.Text,
                props = {
                    size = util.vector2(52, 16),
                    text = resource.label,
                    textColor = TEXT_COLOR,
                    textSize = 14,
                },
            },
            interval(),
            {
                template = interfaces.MWUI.templates.boxTransparent,
                content = ui.content({
                    {
                        props = { size = BAR_SIZE },
                        content = ui.content(layers),
                    },
                }),
            },
        }),
    }
end

--- Keeps pending reserve visible as numbers without making the bars or widget
--- change size when a hit begins or finishes dissipating.
local function renderDissipatingText(state)
    local text = "Dissipating: H " .. displayNumber(state.health.dissipating)
    if state.fatigue then
        text = text .. "  F " .. displayNumber(state.fatigue.dissipating)
    end
    return {
        type = ui.TYPE.Text,
        props = {
            text = text,
            textColor = DISSIPATING_COLOR,
            textSize = 13,
        },
    }
end

local function buildLayout(state)
    local rows = {
        {
            template = interfaces.MWUI.templates.textHeader,
            props = { text = "Ward of Delay" },
        },
        interval(),
        renderReserveBar(state.health),
    }
    if state.fatigue then
        table.insert(rows, interval())
        table.insert(rows, renderReserveBar(state.fatigue))
    end
    table.insert(rows, interval())
    table.insert(rows, renderDissipatingText(state))

    local hudPosition = settings.wardHudPosition
    return {
        layer = "HUD",
        name = "SkillPerksWardHud",
        template = interfaces.MWUI.templates.boxTransparent,
        props = {
            relativePosition = hudPosition,
            anchor = hudPosition,
            position = (util.vector2(1, 1) - hudPosition * 2):emul(util.vector2(13, 13)),
        },
        content = ui.content({
            {
                template = interfaces.MWUI.templates.padding,
                content = ui.content({
                    {
                        type = ui.TYPE.Flex,
                        props = {
                            arrange = ui.ALIGNMENT.Center,
                        },
                        content = ui.content(rows),
                    },
                }),
            },
        }),
    }
end

--- Produces a display-level signature so sub-point changes do not rebuild the
--- complete widget every frame.
local function signature(state)
    if not shouldShow(state) then return "hidden" end
    local parts = {
        displayNumber(state.health.available),
        displayNumber(state.health.dissipating),
        displayNumber(state.health.maximum),
    }
    if state.fatigue then
        table.insert(parts, displayNumber(state.fatigue.available))
        table.insert(parts, displayNumber(state.fatigue.dissipating))
        table.insert(parts, displayNumber(state.fatigue.maximum))
    end
    return table.concat(parts, ":")
end

local function forceUpdate(state)
    lastState = state
    local nextSignature = signature(state)
    if not shouldShow(state) then
        if hudElement then hudElement:destroy() end
        hudElement = nil
        hudLayout = nil
        lastSignature = nextSignature
        return
    end
    if hudElement and nextSignature == lastSignature then return end

    local nextLayout = buildLayout(state)
    if hudElement and hudLayout then
        hudLayout.props = nextLayout.props
        hudLayout.template = nextLayout.template
        hudLayout.content = nextLayout.content
        hudElement:update()
    else
        hudLayout = nextLayout
        hudElement = ui.create(hudLayout)
    end
    lastSignature = nextSignature
end

local function update(state)
    lastState = state
    frameCounter = frameCounter + 1
    if frameCounter >= math.max(1, settings.wardHudUpdateEvery) then
        frameCounter = 0
        forceUpdate(state)
    end
end

settings.wardHudSection:subscribe(async:callback(function()
    lastSignature = nil
    forceUpdate(lastState)
end))

return {
    forceUpdate = forceUpdate,
    update = update,
}
