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
    Long Blade Momentum HUD

    This is intentionally SkillPerks-side UI, not a Framework widget. The
    Framework owns shared mechanics and interop; this module only presents
    Long Blade state owned by SPerks_LongBlade.lua.
]]

local async = require("openmw.async")
local interfaces = require("openmw.interfaces")
local ui = require("openmw.ui")
local util = require("openmw.util")

local settings = require("scripts.SkillPerks.Settings.settings")

local interval = { template = interfaces.MWUI.templates.interval }
local barTexture = ui.texture({ path = "textures/menu_bar_gray.dds" })

local BAR_SIZE = util.vector2(92, 12)
local BAR_COLOR = util.color.rgb(202 / 255, 165 / 255, 96 / 255)
local BAR_EMPTY_COLOR = util.color.rgba(0.05, 0.04, 0.03, 0.72)
local TEXT_COLOR = util.color.rgb(0.86, 0.74, 0.50)
local WHITE = util.color.rgb(1, 1, 1)

local hudElement = nil
local hudLayout = nil
local lastState = nil
local frameCounter = 0

local function shouldShow(state)
    return settings.longBladeHudEnable
        and state ~= nil
        and state.enabled == true
        and (state.max or 0) > 0
end

local function renderMomentumBar(state)
    local maxStacks = math.max(state.max or 0, 1)
    local current = math.max(0, math.min(state.current or 0, maxStacks))
    local ratio = current / maxStacks

    return {
        template = interfaces.MWUI.templates.boxTransparent,
        content = ui.content({
            {
                props = { size = BAR_SIZE },
                content = ui.content({
                    {
                        type = ui.TYPE.Image,
                        props = {
                            size = BAR_SIZE,
                            resource = barTexture,
                            color = BAR_EMPTY_COLOR,
                        },
                    },
                    {
                        type = ui.TYPE.Image,
                        props = {
                            size = BAR_SIZE:emul(util.vector2(ratio, 1)),
                            resource = barTexture,
                            color = BAR_COLOR,
                        },
                    },
                    {
                        type = ui.TYPE.Text,
                        props = {
                            relativePosition = util.vector2(0.5, 0.5),
                            anchor = util.vector2(0.5, 0.5),
                            text = ("%d/%d"):format(current, maxStacks),
                            textColor = WHITE,
                            textSize = 12,
                        },
                    },
                }),
            },
        }),
    }
end

local function renderStateLine(state)
    local text = "Poise: " .. (state.poise and "Active" or "Building")
    if state.overdrive and state.overdrive > 0 then
        text = ("Killing Measure: %.0fs"):format(math.ceil(state.overdrive))
    elseif (state.current or 0) <= 0 then
        text = "Momentum: Ready"
    end

    return {
        type = ui.TYPE.Text,
        props = {
            text = text,
            textColor = TEXT_COLOR,
            textSize = 14,
        },
    }
end

local function buildLayout(state)
    local hudPosition = settings.longBladeHudPosition
    return {
        layer = "HUD",
        name = "SkillPerksLongBladeHud",
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
                        content = ui.content({
                            {
                                template = interfaces.MWUI.templates.textHeader,
                                props = { text = "Long Blade" },
                            },
                            interval,
                            {
                                type = ui.TYPE.Text,
                                props = {
                                    text = "Momentum",
                                    textColor = TEXT_COLOR,
                                    textSize = 14,
                                },
                            },
                            renderMomentumBar(state),
                            interval,
                            renderStateLine(state),
                        }),
                    },
                }),
            },
        }),
    }
end

local function forceUpdate(state)
    lastState = state
    if not shouldShow(state) then
        if hudElement then
            hudElement:destroy()
        end
        hudElement = nil
        hudLayout = nil
        return
    end

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
end

local function update(state)
    lastState = state
    if frameCounter == 0 then
        forceUpdate(state)
    end

    frameCounter = frameCounter + 1
    if frameCounter >= math.max(1, settings.longBladeHudUpdateEvery) then
        frameCounter = 0
    end
end

settings.longBladeHudSection:subscribe(async:callback(function()
    forceUpdate(lastState)
end))

return {
    forceUpdate = forceUpdate,
    update = update,
}
