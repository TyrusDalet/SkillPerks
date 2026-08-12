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

    ============================================================
    PERFORMANCE NOTE (added after reports of severe FPS loss in
    NPC/creature-dense areas - Vivec, Old Ebonheart, Anvil, Narsis, and
    large dungeons):

    checkStaggerState() is called from npc.lua/creature.lua's onUpdate,
    which means it runs EVERY SIMULATION FRAME for EVERY NPC AND CREATURE
    OpenMW is actively simulating nearby - not just ones interacting with
    the player. The original implementation called the native
    anim.isPlaying() check up to 12 times (once per entry in
    STAGGER_ANIMATIONS) per actor, per frame, unconditionally. In a
    crowded city this multiplies into tens of thousands of native calls
    per second and was confirmed as a major contributor to reported FPS
    collapse and, in some cases, crashes.

    Three independent gates are now applied, cheapest-first, and ALL must
    pass before the expensive anim.isPlaying scan runs:

      1. RELEVANCE GATE (checked first - cheapest, a plain table read):
         this mechanism is currently used ONLY by Mysticism's Telekinetic
         Force/Invisible Hammer (D1/D2). Any perk that depends on
         Stagger.forceStagger()/forceKnockdown() must call
         Stagger.setRelevant(reasonKey, true/false) when its owned rank
         changes (see SPerks_Mysticism.lua). When no registered reason is
         currently active - i.e. the player owns none of the perks that
         use this module - checkStaggerState() skips ALL further work for
         EVERY actor in the world, since nothing could be forcing a
         stagger/knockdown animation via this system.
         CONFIRMED SAFE: natural/vanilla actor staggers are handled by the
         engine's own hit-reaction logic and are unaffected by any of this.
         The suppression this module performs exists only to patch the
         fact that our own FORCED (animation-only, not a real engine
         stagger) staggers don't otherwise stop AI attacks on their own -
         so when no perk that forces one is owned, this module has
         nothing to do, and gating it costs nothing in gameplay terms.

      2. COMBAT GATE: even when the mechanism is relevant, an actor that
         isn't currently in an AI Combat package cannot be mid-stagger
         from this system, so the scan is skipped for it. This reuses the
         same interfaces.AI.forEachPackage package-type inspection already
         established elsewhere in this codebase (see shared/hit.lua's
         Hit.isUnawareOfPlayer and FactionPerks/actor.lua's Follow-package
         check), just testing for the presence of a Combat package rather
         than a specific target.

      3. POLL INTERVAL: even for a relevant, in-combat actor, the
         expensive scan only runs once every STAGGER_POLL_INTERVAL seconds
         (see staggerPollTimer), not every frame. The cheap suppression
         WRITE (pself.controls.use = 0) still happens every frame using
         the cached result from the last scan, so suppression itself
         stays continuous once active - only the expensive detection is
         throttled.
    ============================================================
]]

local anim = require("openmw.animation")
local interfaces = require("openmw.interfaces")
local pself = require("openmw.self")
local storage = require("openmw.storage")

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

-- ============================================================
--  RELEVANCE GATE
--  Perks that use Stagger.forceStagger()/forceKnockdown() register their
--  ownership state here under a stable reason key, from their own PLAYER
--  script. Storage sections are keyed by name rather than script
--  identity, so this is written from e.g. SPerks_Mysticism.lua and read
--  here on each actor's own target-local script, matching the existing
--  cross-context pattern used by ErnPerkFramework's own mwVars global
--  section (written in global.lua, read in requirements.lua).
-- ============================================================

local RELEVANCE_SECTION_NAME = "SkillPerksStaggerRelevance"
local relevanceSection = storage.playerSection(RELEVANCE_SECTION_NAME)
pcall(function()
    relevanceSection:setLifeTime(storage.LIFE_TIME.Temporary)
end)

--- Registers or clears one perk's need for this module's suppression
--- mechanism. Multiple independent perks may each hold their own reason
--- key active at once; the mechanism stays enabled as long as at least
--- one reason is true. Call this whenever the calling perk's owned rank
--- changes (e.g. from a periodic onUpdate poll, since onAdd/onRemove
--- timing around framework perk sync can be unreliable - see the
--- Athletics A-chain comment in SPerks_Athletics.lua for why).
--- @param reasonKey string Stable identifier for the calling perk/rank.
--- @param active boolean True while that perk currently needs Stagger.
function Stagger.setRelevant(reasonKey, active)
    relevanceSection:set(reasonKey, active == true)
end

local function isMechanicRelevant()
    for _, enabled in pairs(relevanceSection:asTable()) do
        if enabled == true then
            return true
        end
    end
    return false
end

-- ============================================================
--  COMBAT GATE
--  Reuses the same interfaces.AI.forEachPackage package-type inspection
--  already established in shared/hit.lua and FactionPerks/actor.lua,
--  testing only for the presence of a Combat package rather than a
--  specific target. Fails open (treats the actor as "in combat") if the
--  AI interface is unavailable or the check errors, so this gate can
--  only ever ADD safety margin, never silently disable suppression.
-- ============================================================

local function isInCombat()
    local aiInterface = interfaces.AI
    if not aiInterface or type(aiInterface.forEachPackage) ~= "function" then
        return true
    end

    local inCombat = false
    local ok = pcall(aiInterface.forEachPackage, function(package)
        if inCombat or package == nil then
            return
        end
        local packageOk, packageType = pcall(function() return package.type end)
        if packageOk and tostring(packageType):lower() == "combat" then
            inCombat = true
        end
    end)
    if not ok then
        return true
    end
    return inCombat
end

-- ============================================================
--  POLL THROTTLE + MAIN ENTRY POINT
-- ============================================================

local STAGGER_POLL_INTERVAL = 0.1
local staggerPollTimer = 0
local staggerPlayingCached = false

--- Call this every frame (e.g. from onUpdate or a dedicated onFrame) on
--- the TARGET's own local script. Detects whether a stagger or knockdown
--- animation is currently playing and, if so, suppresses this actor's
--- AI-driven attacks for that frame.
---
--- Deliberately a no-op whenever interfaces.NGardeFencer is present on
--- this actor - see module doc comment above.
---
--- The expensive per-animation anim.isPlaying scan is gated behind the
--- relevance and combat checks above and throttled to once every
--- STAGGER_POLL_INTERVAL seconds (see the PERFORMANCE NOTE in the module
--- doc comment). The cheap AI-suppression write still applies every frame
--- from the last cached scan result, so suppression itself does not
--- develop gaps between polls once active.
--- @param dt number|nil Frame delta time in seconds.
function Stagger.checkStaggerState(dt)
    if interfaces.NGardeFencer then
        return
    end

    staggerPollTimer = staggerPollTimer - (dt or 0)
    if staggerPollTimer > 0 then
        if staggerPlayingCached then
            pself.controls.use = 0
        end
        return
    end
    staggerPollTimer = STAGGER_POLL_INTERVAL

    if not isMechanicRelevant() then
        staggerPlayingCached = false
        return
    end

    if not isInCombat() then
        staggerPlayingCached = false
        return
    end

    local staggerPlaying = false
    for _, animName in ipairs(Stagger.STAGGER_ANIMATIONS) do
        if anim.isPlaying(pself, animName) then
            staggerPlaying = true
            break
        end
    end
    staggerPlayingCached = staggerPlaying

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
