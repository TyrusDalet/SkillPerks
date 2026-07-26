--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Shared classification for effects that genuinely came from player spellcasting.
Perks may deliberately support other sources, but ordinary spellcasting perks
should use this module instead of inferring source from the player's spellbook.
]]

local core = require("openmw.core")
local types = require("openmw.types")

local SpellSource = {}

--- Resolves either a spell record or record ID to a live spell record.
--- Generated records, including Spellforge helpers, resolve through the same
--- database as vanilla and player-created spells.
local function spellRecord(spellOrId)
    if spellOrId == nil then return nil end
    local id = type(spellOrId) == "string" and spellOrId or spellOrId.id
    if not id then return nil end
    return core.magic.spells.records[id]
end

--- Recognizes generated records that represent a Spellforge cast rather than
--- a secondary scripted effect. Spellforge's front-end records are added to
--- the spellbook; its runtime helper records retain this ID or name marker.
local function isSpellforgeRecord(record)
    if not record then return false end
    local id = tostring(record.id or ""):lower()
    local name = tostring(record.name or ""):lower()
    return id:find("^spellforge_") ~= nil
        or name:find("^spellforge ") ~= nil
end

--- Returns whether a record represents magic that the player actively casts.
--- Powers are deliberate casts; passive abilities, diseases, blights, and
--- curses are not.
function SpellSource.isCastableSpellRecord(spellOrId)
    local record = spellRecord(spellOrId)
    if not record then return false end
    return record.type == core.magic.SPELL_TYPE.Spell
        or record.type == core.magic.SPELL_TYPE.Power
end

--- Returns whether an active effect came from a qualifying cast by `actor`.
--- Caster identity rejects casterless abilities. Spellbook membership admits
--- ordinary casts, while the explicit Spellforge marker admits its runtime
--- helpers without admitting unrelated scripted secondary effects.
function SpellSource.isPlayerCastActiveSpell(actor, activeSpell)
    if actor == nil or activeSpell == nil or activeSpell.item ~= nil
            or activeSpell.caster ~= actor then
        return false
    end
    local record = spellRecord(activeSpell.id)
    if not SpellSource.isCastableSpellRecord(record) then return false end
    return types.Actor.spells(actor)[record.id] ~= nil
        or isSpellforgeRecord(record)
end

--- Returns whether a landed-effect event represents qualifying player magic.
--- Core 0's target bridge computes this once from the complete ActiveSpell,
--- preserving the same source decision for every school that receives it.
function SpellSource.isPlayerCastLandedSpell(data)
    return data ~= nil and data.isPlayerCast == true
end

--- Returns whether the actor knows the selected castable spell.
--- This is appropriate while observing a cast animation, before an active
--- effect exists and exposes its caster.
function SpellSource.actorKnowsCastableSpell(actor, spell)
    if actor == nil or not SpellSource.isCastableSpellRecord(spell) then
        return false
    end
    return types.Actor.spells(actor)[spell.id] ~= nil
end

return SpellSource
