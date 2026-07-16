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
    global.lua

    Shared global-only operations, each reused by several different
    perks across the Magic design doc (and potentially Combat/Stealth
    later), rather than every perk defining its own bespoke global.lua
    handler for what is structurally the same operation. The design docs'
    own inline code examples (Alteration D's Kinetic Shell discharge,
    Illusion D's Total Devotion Command application, Alchemy C/D's potion/
    ingredient preservation, Enchant C's scroll duplication, Block B/C/D
    cross-actor writes) each sketch this ad hoc per-perk; consolidating
    them here means later Core work
    just sends one of these two events instead of re-deriving the
    boilerplate every time.

    SPerks_CreateAndApplySpell
        world.createRecord is global-only, so any perk needing to apply a
        dynamically-computed magnitude/duration spell effect (rather than
        a fixed-magnitude one that could live in the ESP) must round-trip
        through here. Builds a Spells.createRecordDraft from a caller-
        supplied effect list, registers it, and applies it to the target
        via activeSpells:add. Covers: Alteration D (Kinetic Shell elemental
        discharge), Illusion D (Total Devotion's dynamic Command
        magnitude), and any future perk with the same shape.

    SPerks_DuplicateItem
        world.createObject is global-only. Creates N of a record and moves
        it into a target's inventory, with an optional re-select-as-active-
        enchanted-item step for the scroll case. Covers: Enchant C
        (Preserved Scroll), Alchemy C (Preserved Dose), Alchemy D
        (bonus potions / preserved ingredients).

    SPerks_DamageItemCondition
        types.Item.itemData is global/self-write scoped. Applies direct
        condition loss to a supplied item object. Covers: Block B1 and
        future armor/weapon durability perks.

    SPerks_ModifyItemCondition
        Global-only item condition write helper for player scripts that
        need to add, subtract, or set condition on carried/equipped items.

    SPerks_RemoveItem
        Removes a supplied item object. Used when a perk temporarily keeps an
        item alive long enough to decide whether vanilla durability loss
        should really destroy it.

    SPerks_ModifyActorActiveEffect
        Actor.activeEffects writes are global/self-scoped. Applies a flat
        active effect delta to an arbitrary actor. Covers: Block B2 and
        future cross-actor buff/debuff effects.

    SPerks_ApplyExistingSpell
        Applies an already-existing spell id to a target actor. Unlike
        SPerks_CreateAndApplySpell, this does not create a dynamic spell
        record. Covers: Block C stored-spell firing and Block D reflection.
]]

local core = require("openmw.core")
local world = require("openmw.world")
local types = require("openmw.types")

-- ============================================================
--  DYNAMIC SPELL CREATION + APPLICATION
-- ============================================================

--- @param data table {
---   target = GameObject (required, the actor the spell is applied to),
---   caster = GameObject|nil,
---   spellName = string|nil,
---   effects = list of {
---     id = string (magic effect id, e.g. "firedamage"),
---     range = number|nil (core.magic.RANGE.*, defaults to Target),
---     magnitudeMin = number,
---     magnitudeMax = number|nil (defaults to magnitudeMin, i.e. fixed magnitude),
---     duration = number|nil,
---     area = number|nil,
---     affectedAttribute = string|nil,
---     affectedSkill = string|nil,
---   },
---   activeSpellOptions = {
---     ignoreReflect = boolean|nil,
---     ignoreResistances = boolean|nil,
---     ignoreSpellAbsorption = boolean|nil,
---     stackable = boolean|nil,
---     quiet = boolean|nil,
---   }|nil,
--- }
local function createAndApplySpell(data)
    if not data.target or not data.target:isValid() then
        return
    end
    if not data.effects or #data.effects == 0 then
        return
    end

    local draftEffects = {}
    local effectIndices = {}
    for i, e in ipairs(data.effects) do
        table.insert(draftEffects, {
            id = e.id,
            range = e.range or core.magic.RANGE.Target,
            magnitudeMin = e.magnitudeMin,
            magnitudeMax = e.magnitudeMax or e.magnitudeMin,
            duration = e.duration,
            area = e.area,
            affectedAttribute = e.affectedAttribute,
            affectedSkill = e.affectedSkill,
        })
        -- activeSpells:add expects 0-based effect indices into the
        -- record's own effect list, per the confirmed ActiveEffect.index
        -- semantics documented in openmw.core - NOT 1-based Lua indices.
        table.insert(effectIndices, i - 1)
    end

    -- Uniqueness: simulation time + a random component, same style as the
    -- design doc's own "SPerks_Illusion_D_Command_" .. tostring(core.getSimulationTime())
    -- example. Dynamically created records are never reused/cached - each
    -- discharge/application gets its own throwaway record.
    local draftId = "SPerks_Dynamic_" .. tostring(core.getSimulationTime()) .. "_" .. tostring(math.random(1, 999999))

    local draft = core.magic.spells.createRecordDraft({
        id = draftId,
        name = data.spellName or "SkillPerks Effect",
        type = core.magic.SPELL_TYPE.Spell,
        effects = draftEffects,
    })
    local newSpell = world.createRecord(draft)

    local addOptions = data.activeSpellOptions or {}
    types.Actor.activeSpells(data.target):add({
        id = newSpell.id,
        effects = effectIndices,
        caster = data.caster,
        ignoreReflect = addOptions.ignoreReflect,
        ignoreResistances = addOptions.ignoreResistances,
        ignoreSpellAbsorption = addOptions.ignoreSpellAbsorption,
        stackable = addOptions.stackable,
        quiet = addOptions.quiet,
    })
end

-- ============================================================
--  ITEM DUPLICATION
-- ============================================================

--- @param data table {
---   target = GameObject (required, whose inventory receives the item),
---   recordId = string (required),
---   count = number|nil (defaults to 1),
---   reselectAsActive = boolean|nil (if true, the new item is immediately
---     set as the target's selected enchanted item - used by Enchant C so
---     a preserved scroll doesn't need to be manually re-equipped),
--- }
local function duplicateItem(data)
    if not data.target or not data.target:isValid() then
        return
    end
    if not data.recordId then
        return
    end

    local newItem = world.createObject(data.recordId, data.count or 1)
    newItem:moveInto(types.Actor.inventory(data.target))

    if data.reselectAsActive then
        types.Actor.setSelectedEnchantedItem(data.target, newItem)
    end
end

-- ============================================================
--  CROSS-ACTOR ITEM / EFFECT / SPELL WRITES
-- ============================================================

--- Applies direct condition damage to an item object.
--- @param data table { item = GameObject, amount = number }
local function damageItemCondition(data)
    data = data or {}
    if not data.item or not data.item:isValid() then
        return
    end

    local itemData = types.Item.itemData(data.item)
    if itemData and itemData.condition ~= nil then
        itemData.condition = math.max(0, itemData.condition - (data.amount or 0))
    end
end

--- Adds to or sets an item's condition from a global script.
--- @param data table { item = GameObject, amount = number|nil, value = number|nil, maxCondition = number|nil, minCondition = number|nil }
local function modifyItemCondition(data)
    data = data or {}
    if not data.item or not data.item:isValid() then
        return
    end

    local itemData = types.Item.itemData(data.item)
    if not itemData or itemData.condition == nil then
        return
    end

    local newCondition
    if data.value ~= nil then
        newCondition = data.value
    else
        newCondition = itemData.condition + (data.amount or 0)
    end
    if data.minCondition ~= false then
        newCondition = math.max(data.minCondition or 0, newCondition)
    end
    if data.maxCondition then
        newCondition = math.min(data.maxCondition, newCondition)
    end
    itemData.condition = newCondition
end

--- Removes an item object from the world/inventory.
--- @param data table { item = GameObject, count = number|nil }
local function removeItem(data)
    data = data or {}
    if not data.item or not data.item:isValid() then
        return
    end
    data.item:remove(data.count or 1)
end

--- Applies a flat active-effect delta to an arbitrary actor.
--- @param data table { target = GameObject, effectId = string, amount = number, extraParam = any|nil }
local function modifyActorActiveEffect(data)
    data = data or {}
    if not data.target or not data.target:isValid() then
        return
    end
    if not data.effectId then
        return
    end

    local activeEffects = types.Actor.activeEffects(data.target)
    if data.extraParam ~= nil then
        activeEffects:modify(data.amount or 0, data.effectId, data.extraParam)
    else
        activeEffects:modify(data.amount or 0, data.effectId)
    end
end

--- Applies an existing spell record to a target actor.
--- @param data table {
---   target = GameObject,
---   spellId = string,
---   caster = GameObject|nil,
---   ignoreReflect = boolean|nil,
---   ignoreResistances = boolean|nil,
---   ignoreSpellAbsorption = boolean|nil,
---   stackable = boolean|nil,
---   quiet = boolean|nil,
--- }
local function applyExistingSpell(data)
    data = data or {}
    if not data.target or not data.target:isValid() then
        return
    end
    if not data.spellId then
        return
    end

    types.Actor.activeSpells(data.target):add({
        id = data.spellId,
        caster = data.caster,
        ignoreReflect = data.ignoreReflect,
        ignoreResistances = data.ignoreResistances,
        ignoreSpellAbsorption = data.ignoreSpellAbsorption,
        stackable = data.stackable,
        quiet = data.quiet,
    })
end

return {
    eventHandlers = {
        SPerks_CreateAndApplySpell = createAndApplySpell,
        SPerks_DuplicateItem = duplicateItem,
        SPerks_DamageItemCondition = damageItemCondition,
        SPerks_ModifyItemCondition = modifyItemCondition,
        SPerks_RemoveItem = removeItem,
        SPerks_ModifyActorActiveEffect = modifyActorActiveEffect,
        SPerks_ApplyExistingSpell = applyExistingSpell,

        -- Compatibility aliases for early Block drafts that shipped with a
        -- temporary per-skill global script.
        SPerks_Block_DamageWeaponCondition = damageItemCondition,
        SPerks_Block_DrainFatigue = function(data)
            data = data or {}
            data.effectId = data.effectId or "drainfatigue"
            modifyActorActiveEffect(data)
        end,
        SPerks_Block_ApplySpellToTarget = function(data)
            data = data or {}
            data.spellId = data.spellId or data.id
            applyExistingSpell(data)
        end,
    },
}
