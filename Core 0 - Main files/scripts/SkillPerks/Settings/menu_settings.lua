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

local async = require("openmw.async")
local interfaces = require("openmw.interfaces")
local ui = require("openmw.ui")
local util = require("openmw.util")

local markTexture = ui.texture({ path = "textures/menu_map_smark.dds" })

-- Small screen-position picker adapted from Attend Me's settings UI. The
-- saved value is both anchor and relativePosition, so dragging the mark
-- toward an edge also makes the HUD grow inward from that edge.
interfaces.Settings.registerRenderer("SkillPerksScreenPosition", function(value, set)
    local buttonSize = util.vector2(20, 20)
    local containerSize = util.vector2(50, 50)
    local update = async:callback(function(e)
        if e.button ~= 1 then
            return
        end
        local relativeOffset = (e.offset - buttonSize / 2):ediv(containerSize)
        set(util.vector2(
            util.clamp(relativeOffset.x, 0, 1),
            util.clamp(relativeOffset.y, 0, 1)
        ))
    end)

    return {
        template = interfaces.MWUI.templates.box,
        content = ui.content({
            {
                props = {
                    size = containerSize + buttonSize,
                },
                content = ui.content({
                    {
                        template = interfaces.MWUI.templates.borders,
                        props = {
                            anchor = value,
                            relativePosition = value,
                            size = buttonSize,
                        },
                        content = ui.content({
                            {
                                type = ui.TYPE.Image,
                                props = {
                                    resource = markTexture,
                                    relativeSize = util.vector2(1, 1),
                                    color = util.color.rgb(202 / 255, 165 / 255, 96 / 255),
                                },
                            },
                        }),
                    },
                }),
                events = {
                    mouseMove = update,
                    mousePress = update,
                },
            },
        }),
    }
end)

return {}
