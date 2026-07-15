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
    stat_tracker.lua

    Every perk in all three SkillPerks design docs that grants a scaling
    bonus needs the same discipline every single time:
      - never double-apply the same bonus on a re-fired onAdd
      - always be able to cleanly reverse EXACTLY what was applied,
        nothing more, nothing less
      - survive onSave/onLoad without leaking or duplicating

    This generalises the pattern FactionPerks established piecemeal and
    independently in several different files (FPerks_HR/FG/IL's
    appliedHealthMod/appliedFatigueMod, FPerks_MG/HR/FG/IL/TT/MT/IC/EEC/HH's
    appliedStats attribute+skill tables, and FPerks_HT's
    activeCastOnUseBonuses/activeConstantBoosts tracking) into one shared
    utility, so individual SkillPerks perk files don't hand-roll it again
    27 times over.

    Two trackers are provided, covering the two families of engine-mutable
    stat field used throughout every design doc:

      newActiveEffectTracker(actor)
        For types.Actor.activeEffects(actor):modify(delta, effectId, extraParam).
        Used by anything applying Fortify/Resist/Sanctuary/Chameleon/etc.
        as an ACTIVE EFFECT rather than a base stat write - i.e. anything
        that should show up as a labelled entry in the active-effects list,
        not just quietly move a number.

      newStatModTracker(actor)
        For direct stat.modifier writes on attributes, skills, and dynamic
        stats (health/magicka/fatigue). Used for the "Fortify Health via
        stat.modifier so the maximum is raised correctly" pattern used
        throughout FactionPerks, and for the flat attribute/skill grants
        every A-chain in Combat/Stealth/Magic hands out.

    BOTH trackers work the same way: apply(key, newValue) sets the TOTAL
    value this tracker is currently responsible for at that key, and
    internally computes+applies only the delta against whatever it last
    set. This makes it always safe to call apply() repeatedly (e.g. once
    per onUpdate tick, recalculating from scratch every time) without
    re-summing or needing to track "did I already apply this" separately.

    ============================================================
    ONLOAD USAGE (important, matches the FactionPerks lesson directly)
    ============================================================
    stat.modifier and activeEffects magnitudes both persist in the save
    file as part of the actor's serialized state. That means WITHOUT
    reversing a tracker's saved contribution on load, the framework
    re-firing onAdd for every held perk would double every bonus.

    The correct onLoad sequence, matching FactionPerks' documented pattern
    exactly (FPerks_HR/FG/IL/MG/TT/MT/IC/EEC/HH all do this):

        local tracker = StatTracker.newStatModTracker(self)
        local function onLoad(data)
            data = data or {}
            tracker.restoreAndReverse(data.trackerSnapshot)
            -- tracker is now bookkeeping-empty AND the live stat.modifier
            -- values are back to a clean zero baseline. The framework's
            -- own re-fired onAdd calls will now apply() cleanly from
            -- scratch with no risk of double-counting.
        end
        local function onSave()
            return { trackerSnapshot = tracker.snapshot() }
        end
]]

local types = require("openmw.types")

local StatTracker = {}

--- Creates a tracker for types.Actor.activeEffects(actor):modify(...) calls.
--- @param actor table The actor (usually `self`) whose active effects will be modified.
--- @return table tracker
function StatTracker.newActiveEffectTracker(actor)
    local applied = {} -- key -> currently-applied TOTAL value (not a delta)

    local function keyOf(effectId, extraParam)
        return extraParam and (effectId .. "|" .. extraParam) or effectId
    end

    -- Reverses the key naming above. Effect IDs never contain "|" themselves
    -- (they're always plain lowercase engine effect ids), so this split is safe.
    local function splitKey(key)
        local effectId, extraParam = key:match("^(.-)|(.+)$")
        return effectId or key, extraParam
    end

    local tracker = {}

    --- @param effectId string e.g. "sanctuary", "fortifyattribute", "chameleon"
    --- @param extraParam string|nil e.g. "strength" for attribute/skill-targeted effects
    --- @param newValue number The new TOTAL value this tracker should be responsible for.
    function tracker.apply(effectId, extraParam, newValue)
        local key = keyOf(effectId, extraParam)
        local old = applied[key] or 0
        local delta = newValue - old
        if delta == 0 then
            return
        end
        local activeEffects = types.Actor.activeEffects(actor)
        if extraParam then
            activeEffects:modify(delta, effectId, extraParam)
        else
            activeEffects:modify(delta, effectId)
        end
        if newValue == 0 then
            applied[key] = nil
        else
            applied[key] = newValue
        end
    end

    --- Convenience: zero out one specific key.
    function tracker.clear(effectId, extraParam)
        tracker.apply(effectId, extraParam, 0)
    end

    --- Zeroes every key this tracker currently owns, reversing each one's
    --- live contribution. Call this from a perk's onRemove.
    function tracker.clearAll()
        for key, value in pairs(applied) do
            if value ~= 0 then
                local effectId, extraParam = splitKey(key)
                local activeEffects = types.Actor.activeEffects(actor)
                if extraParam then
                    activeEffects:modify(-value, effectId, extraParam)
                else
                    activeEffects:modify(-value, effectId)
                end
            end
        end
        applied = {}
    end

    --- Returns the raw bookkeeping table for onSave. Store this verbatim.
    function tracker.snapshot()
        return applied
    end

    --- Restores bookkeeping ONLY (does not touch live engine values, and
    --- does not reverse anything). Prefer restoreAndReverse for onLoad -
    --- this low-level form exists for the rare case FactionPerks' HT chain
    --- documents, where a perk deliberately does NOT want its saved
    --- contribution reversed on load (e.g. tracking-only state kept purely
    --- for expiry detection, where the underlying value is intentionally
    --- left exactly as the save file already has it).
    function tracker.restore(savedApplied)
        applied = savedApplied or {}
    end

    --- The normal onLoad call: restores bookkeeping, then immediately
    --- reverses every restored key's live contribution, leaving both the
    --- tracker and the actor's real stats at a clean zero baseline ready
    --- for the framework's re-fired onAdd calls to rebuild from scratch.
    function tracker.restoreAndReverse(savedApplied)
        tracker.restore(savedApplied)
        tracker.clearAll()
    end

    return tracker
end

--- Creates a tracker for stat.modifier writes on attributes, skills, and
--- dynamic stats (health/magicka/fatigue).
--- @param actor table The actor (usually `self`) whose stats will be modified.
--- @return table tracker
function StatTracker.newStatModTracker(actor)
    local applied = { attributes = {}, skills = {}, dynamic = {} }

    -- Categories intentionally mirror the three getter families exposed by
    -- openmw.types - see types.lua's ActorStats/NpcStats documentation.
    local getters = {
        attributes = function(id) return types.Actor.stats.attributes[id] end,
        skills     = function(id) return types.NPC.stats.skills[id] end,
        dynamic    = function(id) return types.Actor.stats.dynamic[id] end,
    }

    local tracker = {}

    --- @param category string One of "attributes", "skills", "dynamic".
    --- @param id string e.g. "strength", "longblade", "health"
    --- @param newValue number The new TOTAL modifier value this tracker owns for that stat.
    function tracker.apply(category, id, newValue)
        local getter = getters[category]
        if not getter then
            error("stat_tracker: unknown category '" .. tostring(category) .. "'", 2)
        end
        local statGetter = getter(id)
        if not statGetter then
            return
        end
        local old = applied[category][id] or 0
        local delta = newValue - old
        if delta == 0 then
            return
        end
        local stat = statGetter(actor)
        stat.modifier = stat.modifier + delta

        -- Dynamic stats (health/magicka/fatigue) need `current` adjusted
        -- the same way FactionPerks FG/HR/IL/MG's applyHealthMod/
        -- applyMagickaMod/applyFatigueMod do: growing the cap also grows
        -- current by the same delta (matching vanilla Fortify's "you get
        -- the extra pool immediately" feel), shrinking it just clamps
        -- current down to the new cap rather than draining anything extra.
        if category == "dynamic" then
            local newMax = stat.base + stat.modifier
            if delta > 0 then
                stat.current = math.min(stat.current + delta, newMax)
            else
                stat.current = math.min(stat.current, newMax)
            end
        end

        if newValue == 0 then
            applied[category][id] = nil
        else
            applied[category][id] = newValue
        end
    end

    function tracker.clear(category, id)
        tracker.apply(category, id, 0)
    end

    --- Reverses every stat.modifier this tracker currently owns.
    function tracker.clearAll()
        for category, ids in pairs(applied) do
            for id, value in pairs(ids) do
                if value ~= 0 then
                    local statGetter = getters[category](id)
                    if statGetter then
                        local stat = statGetter(actor)
                        stat.modifier = stat.modifier - value
                        if category == "dynamic" then
                            stat.current = math.min(stat.current, stat.base + stat.modifier)
                        end
                    end
                end
            end
        end
        applied = { attributes = {}, skills = {}, dynamic = {} }
    end

    function tracker.snapshot()
        return applied
    end

    function tracker.restore(savedApplied)
        applied = savedApplied or { attributes = {}, skills = {}, dynamic = {} }
    end

    --- The normal onLoad call - see the module-level doc comment above.
    function tracker.restoreAndReverse(savedApplied)
        tracker.restore(savedApplied)
        tracker.clearAll()
    end

    return tracker
end

return StatTracker
