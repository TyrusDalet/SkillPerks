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
    magic_detection.lua

    Confirmed detection patterns from SkillPerks_Magic.md's Shared
    Infrastructure section. Nearly every Magic-school A/B/D chain needs
    "did the player genuinely cast THIS spell themselves" (excluding
    enchanted items, scrolls, and NPC-applied effects).

    For normal "a skill was used" triggers, prefer
    ErnPerkFramework.registerSkillUseHandler. The framework owns the single
    SkillProgression listener and already reports spell/enchantment source
    information to registered handlers. The lower-level trackers in this
    module remain available for SkillPerks-specific cases that need
    animation-window state or scroll completion data that the framework
    dispatcher intentionally does not persist.

    Not relevant to Combat at all, but the shared runtime owns these
    helpers up front rather than forcing the later Magic skill files to
    patch common infrastructure.
]]

local core = require("openmw.core")
local types = require("openmw.types")
local interfaces = require("openmw.interfaces")

local MagicDetection = {}

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
function MagicDetection.isSpellforgeRecord(spellOrId)
    local record = spellRecord(spellOrId)
    if not record then return false end
    local id = tostring(record.id or ""):lower()
    local name = tostring(record.name or ""):lower()
    return id:find("^spellforge_") ~= nil
        or name:find("^spellforge ") ~= nil
end

--- Returns whether a record represents magic that the player actively casts.
--- Powers are deliberate casts; passive abilities, diseases, blights, and
--- curses are not.
function MagicDetection.isCastableSpellRecord(spellOrId)
    local record = spellRecord(spellOrId)
    if not record then return false end
    return record.type == core.magic.SPELL_TYPE.Spell
        or record.type == core.magic.SPELL_TYPE.Power
end

--- Returns whether an active effect came from a qualifying cast by `actor`.
--- Spellbook membership admits ordinary casts, while the explicit Spellforge
--- marker admits its runtime helpers without admitting unrelated scripted
--- secondary effects.
function MagicDetection.isPlayerCastActiveSpell(actor, activeSpell)
    if actor == nil or activeSpell == nil or activeSpell.item ~= nil
            or activeSpell.caster ~= actor then
        return false
    end
    local record = spellRecord(activeSpell.id)
    if not MagicDetection.isCastableSpellRecord(record) then return false end
    local shared=interfaces.SkillPerksMagic
    local authorized=false
    if shared and type(shared.isSpellforgeSpellAuthorized)=="function" then
        local ok,result=pcall(shared.isSpellforgeSpellAuthorized,record.id)
        authorized=ok and result==true
    end
    return types.Actor.spells(actor)[record.id] ~= nil
        or MagicDetection.isSpellforgeRecord(record)
        or authorized
end

--- Describes every field used by the shared source decision. This keeps
--- school-specific diagnostics readable without duplicating classification.
function MagicDetection.describeActiveSpellSource(actor, activeSpell)
    local record = activeSpell and spellRecord(activeSpell.id) or nil
    local known = actor ~= nil and record ~= nil
        and types.Actor.spells(actor)[record.id] ~= nil or false
    local shared=interfaces.SkillPerksMagic
    local authorized=false
    if shared and type(shared.isSpellforgeSpellAuthorized)=="function"
            and record then
        local ok,result=pcall(shared.isSpellforgeSpellAuthorized,record.id)
        authorized=ok and result==true
    end
    return {
        id = activeSpell and activeSpell.id or nil,
        name = activeSpell and activeSpell.name or nil,
        activeSpellId = activeSpell and activeSpell.activeSpellId or nil,
        caster = activeSpell and activeSpell.caster or nil,
        casterIsActor = activeSpell ~= nil and activeSpell.caster == actor,
        item = activeSpell and activeSpell.item or nil,
        recordFound = record ~= nil,
        recordType = record and record.type or nil,
        recordName = record and record.name or nil,
        known = known,
        spellforge = MagicDetection.isSpellforgeRecord(record),
        spellforgeAuthorized = authorized,
        qualifies = MagicDetection.isPlayerCastActiveSpell(actor, activeSpell),
    }
end

--- Returns whether a landed-effect event represents qualifying player magic.
--- Core 0's target bridge computes this once from the complete ActiveSpell,
--- preserving the same source decision for every school that receives it.
function MagicDetection.isPlayerCastLandedSpell(data)
    return data ~= nil and data.isPlayerCast == true
end

--- Returns whether the actor knows the selected castable spell.
--- This is appropriate while observing a cast animation, before an active
--- effect exists and exposes its caster.
function MagicDetection.actorKnowsCastableSpell(actor, spell)
    if actor == nil or not MagicDetection.isCastableSpellRecord(spell) then
        return false
    end
    return types.Actor.spells(actor)[spell.id] ~= nil
end

-- ============================================================
--  ENCHANTMENT RECORD HELPERS
--  Originally established in FactionPerks' FPerks_HT.lua
--  (getEnchantmentRecord). Resolves an item's enchantment record
--  regardless of item type.
-- ============================================================

local ENCHANTABLE_TYPES = {
    types.Weapon, types.Armor, types.Clothing,
    types.Miscellaneous, types.Book,
}

--- @param item table
--- @return table|nil The item's Enchantment record, or nil if unenchanted/invalid.
function MagicDetection.getEnchantmentRecord(item)
    if not item or not item:isValid() then
        return nil
    end
    for _, t in ipairs(ENCHANTABLE_TYPES) do
        if t.objectIsInstance(item) then
            local r = t.record(item)
            if r and r.enchant and r.enchant ~= "" then
                return core.magic.enchantments.records[r.enchant]
            end
            break
        end
    end
    return nil
end

--- Max charge CAPACITY for an item (Enchantment.charge), distinct from
--- ItemData.enchantmentCharge which is CURRENT charge. Returns nil for
--- unenchanted items.
--- @param item table
--- @return number|nil
function MagicDetection.getMaxChargeOf(item)
    local enchRecord = MagicDetection.getEnchantmentRecord(item)
    return enchRecord and enchRecord.charge or nil
end

-- ============================================================
--  PLAYER-CAST SPELL DETECTION
--  Excludes enchanted item casts, scroll casts, and NPC-applied spells -
--  only a genuine cast of a spell in the player's OWN spell list counts.
--  Confirmed pattern from SkillPerks_Magic.md's Shared Infrastructure.
-- ============================================================

--- Creates a tracker that maintains `.currentSpell` (the openmw.core#Spell
--- record, or nil) reflecting whichever player-cast spell is currently
--- mid-cast. Most perk files should instead use
--- ErnPerkFramework.registerSkillUseHandler with `playerCastOnly = true`;
--- use this tracker only when the perk needs to inspect the live cast
--- window outside the framework skill-use event payload.
---
--- IMPORTANT: this must be created ONCE per script (module-scope), not
--- inside a handler, since addTextKeyHandler registration should only
--- happen once.
--- @param actor table Usually `self`.
--- @return table tracker with fields: currentSpell, currentCost
function MagicDetection.newCastTracker(actor)
    local tracker = { currentSpell = nil, currentCost = 0 }

    interfaces.AnimationController.addTextKeyHandler('', function(groupname, key)
        if groupname ~= "spellcast" then
            return
        end
        if key == "self start" or key == "touch start" or key == "target start" then
            local spell = types.Actor.getSelectedSpell(actor)
            if spell
                and MagicDetection.actorKnowsCastableSpell(actor, spell)
                and types.Actor.getSelectedEnchantedItem(actor) == nil then
                tracker.currentSpell = spell
                tracker.currentCost = spell.cost or 0
            end
        elseif key == "self stop" or key == "touch stop" or key == "target stop" then
            tracker.currentSpell = nil
            tracker.currentCost = 0
        end
    end)

    return tracker
end

-- ============================================================
--  SCROLL-CAST DETECTION
--  Scrolls are enchanted items with Enchantment.type ==
--  ENCHANTMENT_TYPE.CastOnce, read via getSelectedEnchantedItem (NOT
--  getSelectedSpell). Destruction is intrinsic to CastOnce - there is no
--  way to intercept/negate consumption, only duplicate after the fact
--  (see Enchant C chain for the confirmed duplicate-on-consume pattern).
-- ============================================================

--- Creates a tracker that maintains `.pendingScrollRecordId` (captured at
--- cast start, since the item itself will not survive the cast) while a
--- scroll cast is in progress, and calls `onScrollCastComplete(recordId)`
--- when the cast finishes.
--- @param actor table Usually `self`.
--- @param onScrollCastComplete fun(recordId: string) Called once the cast
---   completes, with the captured scroll's recordId. Only called if a
---   qualifying CastOnce item was actually selected at cast start.
--- @return table tracker with field: pendingScrollRecordId
function MagicDetection.newScrollCastTracker(actor, onScrollCastComplete)
    local tracker = { pendingScrollRecordId = nil }

    interfaces.AnimationController.addTextKeyHandler('', function(groupname, key)
        if groupname ~= "spellcast" then
            return
        end
        if key == "self start" or key == "touch start" or key == "target start" then
            local selectedItem = types.Actor.getSelectedEnchantedItem(actor)
            if selectedItem and selectedItem:isValid() then
                local enchRecord = MagicDetection.getEnchantmentRecord(selectedItem)
                if enchRecord and enchRecord.type == core.magic.ENCHANTMENT_TYPE.CastOnce then
                    tracker.pendingScrollRecordId = selectedItem.recordId
                end
            end
        elseif key == "self stop" or key == "touch stop" or key == "target stop" then
            if tracker.pendingScrollRecordId and onScrollCastComplete then
                onScrollCastComplete(tracker.pendingScrollRecordId)
            end
            tracker.pendingScrollRecordId = nil
        end
    end)

    return tracker
end

return MagicDetection
