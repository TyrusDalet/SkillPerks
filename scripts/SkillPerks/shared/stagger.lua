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
    stagger.lua

    Confirmed technique from SkillPerks_Magic.md's Shared Infrastructure,
    sourced from direct review of N'Garde's own creature.lua/fencer.lua by
    Arrean. Credit: Arrean. N'Garde is NOT a required dependency - this is
    an independent reimplementation.

    CRITICAL FINDING (already confirmed, repeated here since it governs
    this whole module): Stagger is NOT an engine concept. There is no
    native stagger state to read or set. What this actually does is:
      1. Play a hit-reaction animation at anim.PRIORITY.Scripted (pauses
         all non-Scripted animations while playing, reliably interrupting
         whatever the actor was doing).
      2. Separately track "is one of these animations currently playing"
         as a local flag, and while true, zero the target's own
         self.controls.use to suppress AI-driven attacks.

    Knockdown is handled through the same animation-driven path here.
    OpenMW exposes Actor.canMove(), which can report knocked-down actors, but
    the current Lua API does not expose a setKnockedDown() setter. N'Garde's
    working implementation also treats knockdown/knockout groups as stagger
    animations and suppresses attacks while they play.

    THIS MODULE MUST RUN ON THE TARGET'S OWN LOCAL SCRIPT (npc.lua /
    creature.lua), since self.controls is only writable for self, per
    openmw.self's documented "movement controls (only for actors)" scoping.

    N'GARDE INTEROP: when interfaces.NGardeFencer is present on this actor,
    SkillPerks' own suppression loop is skipped entirely for it, deferring
    to N'Garde's own isStaggered tracking, so the two systems don't fight
    over the same self.controls.use field. Forcing our own animation
    trigger is still safe to do alongside N'Garde being present, since
    N'Garde's own check is itself animation-driven and will naturally pick
    it up - confirmed reasoning from the design doc, though whether any
    ADDITIONAL explicit N'Garde call is needed beyond simply not running
    our own suppression is flagged as still untested (see design doc's
    "Outstanding flagged items").
]]

local anim = require("openmw.animation")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")

local Stagger = {}

Stagger.STAGGER_ANIMATIONS = {
    "hit1",
    "hit2",
    "hit3",
    "hit4",
    "hit5",
    "swimhit1",
    "swimhit2",
    "swimhit3",
    "knockdown",
    "knockout",
    "swimknockdown",
    "swimknockout",
}

--- Plays a forced hit-reaction (or "knockdown") animation at Scripted
--- priority across the whole body, interrupting whatever the actor was
--- doing. Must be called on the actor's own local script (uses `pself`).
--- @param animName string One of Stagger.STAGGER_ANIMATIONS, or "knockdown".
function Stagger.playForcedAnimation(animName)
    interfaces.AnimationController.playBlendedAnimation(animName, {
        startKey = 'start', stopKey = 'stop',
        priority = {
            [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Scripted,
            [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Scripted,
            [anim.BONE_GROUP.Torso] = anim.PRIORITY.Scripted,
            [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
        },
        autoDisable = true,
        blendMask = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.RightArm +
                    anim.BLEND_MASK.Torso + anim.BLEND_MASK.LowerBody,
        speed = 1,
    })
end

--- Call this every frame (e.g. from onUpdate or a dedicated onFrame) on
--- the TARGET's own local script. Detects whether a stagger or knockdown
--- animation is currently playing and, if so, suppresses this actor's
--- AI-driven attacks for that frame.
---
--- Deliberately a no-op whenever interfaces.NGardeFencer is present on
--- this actor - see module doc comment above.
function Stagger.checkStaggerState()
    if interfaces.NGardeFencer then
        return
    end

    local staggerPlaying = false
    for _, animName in ipairs(Stagger.STAGGER_ANIMATIONS) do
        if anim.isPlaying(pself, animName) then
            staggerPlaying = true
            break
        end
    end

    if staggerPlaying then
        pself.controls.use = 0
    end
end

--- Forces a knockdown-style interruption by playing the knockdown animation.
--- The per-frame stagger check suppresses attacks while the animation plays.
--- Must be called on the target's own local script.
function Stagger.forceKnockdown()
    Stagger.playForcedAnimation("knockdown")
end

--- Forces a plain (non-knockdown) stagger: a random hit-reaction animation
--- only, no real engine state change. Must be called on the target's own
--- local script.
function Stagger.forceStagger()
    local animName = Stagger.STAGGER_ANIMATIONS[math.random(1, #Stagger.STAGGER_ANIMATIONS)]
    Stagger.playForcedAnimation(animName)
end

return Stagger
