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

    Shared global-only operations, reused by perks across Combat, Stealth,
    and Magic rather than every perk defining its own bespoke global.lua
    handler for what is structurally the same operation. The design docs'
    own inline code examples (Alteration D's Kinetic Shell discharge,
    Illusion D's Total Devotion Command application, Alchemy C/D's potion/
    ingredient preservation, Enchant C's scroll duplication, Block B/C/D
    cross-actor writes) each sketch this ad hoc per-perk; consolidating
    them here means later Core work can send a focused event instead of
    re-deriving global-context boilerplate every time.

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

    Security activation bridge
        Records exact lock/trap targets for the player Security script and
        synchronously intercepts Master Locksmith's empty-hand activation.
        Successful rolls return here to weaken, unlock, and activate the
        object in the context where those writes are legal.

    Dialogue and merchant bridge
        Relays Inventory Extender's actor-specific UI lifecycle to SkillPerks
        player scripts, and owns NPC Mercantile, disposition, and barter-gold
        writes used by the Mercantile and Speechcraft trees.

    Spell Framework Plus bridge
        Spellforge applies its generated spell helpers through Spell Framework
        Plus rather than OpenMW's ordinary player-cast path. SFP exposes an
        explicit magic-hit event immediately before application and an effect
        lifecycle event immediately afterwards. The bridge pairs those events
        and relays an authoritative pre-effect resource snapshot to the player,
        allowing Magic perks to recognize genuine Spellforge casts without
        admitting abilities, enchantments, or unrelated scripted effects.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local world = require("openmw.world")
local types = require("openmw.types")

-- Security's player script owns perk state and the actual skill roll. This
-- small registry lets the synchronous global activation handler know whether
-- it should suppress vanilla's locked-door response and hand the activation
-- to Master Locksmith instead.
local securityMasteryRanks = {}
local spellforgeCastWindows = {}

local function playerKey(player)
    return player and tostring(player.id) or nil
end

--- Returns a castable spell record while excluding abilities and enchantments.
--- SFP accepts several source record types, so this check remains necessary
--- even after Spellforge has identified the launch in its user data.
local function castableSpellRecord(spellId)
    local spell = spellId and core.magic.spells.records[spellId] or nil
    if not spell then
        return nil
    end
    if spell.type ~= core.magic.SPELL_TYPE.Spell
            and spell.type ~= core.magic.SPELL_TYPE.Power then
        return nil
    end
    return spell
end

--- Captures player resources before SFP applies a self-targeted Spellforge
--- cast. SFP fires MagExp_OnMagicHit before activeSpells:add, which makes this
--- the reliable point at which to distinguish healing from true overflow.
local function relaySpellforgeMagicHit(data)
    data = data or {}
    local actor = data.actor or data.target
    local userData = data.userData
    if type(userData) ~= "table" or userData.spellforge ~= true
            or not actor or not actor:isValid()
            or not types.Player.objectIsInstance(actor)
            or data.attacker ~= actor
            or not castableSpellRecord(data.spellId) then
        return
    end

    local health = types.Actor.stats.dynamic.health(actor)
    local fatigue = types.Actor.stats.dynamic.fatigue(actor)
    local key = playerKey(actor) .. "\0" .. tostring(data.spellId)
    spellforgeCastWindows[key] = core.getSimulationTime() + 1
    actor:sendEvent("SPerks_SpellforgeMagicHit", {
        spellId = data.spellId,
        healthMissing = math.max(0, health.base + health.modifier - health.current),
        fatigueMissing = math.max(0, fatigue.base + fatigue.modifier - fatigue.current),
    })
end

--- Relays SFP's authoritative application metadata only when it follows a
--- Spellforge launch captured above. This pairing avoids treating arbitrary
--- SFP-applied scripted spells as deliberate player casts.
local function relaySpellforgeEffectApplied(data)
    data = data or {}
    local actor = data.actor
    local effect = data.effect or {}
    if not actor or not actor:isValid()
            or not types.Player.objectIsInstance(actor)
            or effect.caster ~= actor
            or not castableSpellRecord(effect.spellId) then
        return
    end

    local key = playerKey(actor) .. "\0" .. tostring(effect.spellId)
    local expires = spellforgeCastWindows[key]
    if not expires or expires < core.getSimulationTime() then
        spellforgeCastWindows[key] = nil
        return
    end

    actor:sendEvent("SPerks_SpellforgeEffectApplied", {
        spellId = effect.spellId,
        effectId = effect.id,
        magnitude = effect.magnitude,
        duration = effect.duration,
        index = effect.index,
    })
end

--- Records whether a player currently owns Master Locksmith.
--- @param data table { player = GameObject, rank = number }
local function setSecurityMasteryRank(data)
    data = data or {}
    local key = playerKey(data.player)
    if not key then
        return
    end
    local rank = math.max(0, math.floor(tonumber(data.rank) or 0))
    securityMasteryRanks[key] = rank > 0 and rank or nil
end

-- Every lockable activation is reported to the player's Security script so
-- tool wear can be matched to the exact lock or trap. An eligible empty-hand
-- activation is consumed here because Activation handlers must decide
-- synchronously whether vanilla activation should continue.
local function onSecurityLockableActivated(target, actor)
    if not actor or not types.Player.objectIsInstance(actor)
            or not target or not types.Lockable.objectIsInstance(target) then
        return true
    end

    actor:sendEvent("SPerks_SecurityLockTarget", {
        target = target,
        wasLocked = types.Lockable.isLocked(target),
        hadTrap = types.Lockable.getTrapSpell(target) ~= nil,
        lockLevel = types.Lockable.getLockLevel(target),
    })

    local rank = securityMasteryRanks[playerKey(actor)] or 0
    if rank == 0 or not types.Lockable.isLocked(target) then
        return true
    end

    local held = types.Actor.getEquipment(actor, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if held ~= nil then
        return true
    end

    actor:sendEvent("SPerks_SecurityBareHandAttempt", {
        target = target,
        lockLevel = types.Lockable.getLockLevel(target),
        rank = rank,
    })
    return false
end

-- Completes a successful bare-hand attempt in global context. D2's lock
-- damage is represented by lowering the retained lock level before unlocking;
-- that matters if another script later relocks the same object.
local function resolveSecurityBareHandAttempt(data)
    data = data or {}
    local target = data.target
    local player = data.player
    if not target or not target:isValid() or not player or not player:isValid()
            or not types.Lockable.objectIsInstance(target) then
        return
    end

    if data.success then
        local currentLevel = types.Lockable.getLockLevel(target)
        local weakenedLevel = math.max(1, currentLevel - math.max(0, data.weakenBy or 0))
        if weakenedLevel < currentLevel then
            types.Lockable.lock(target, weakenedLevel)
        end
        types.Lockable.unlock(target)
        world._runStandardActivationAction(target, player)
    end
end

-- Inventory Extender receives UI mode changes in its global bridge. Relaying
-- them to the affected player gives SkillPerks player scripts a supported,
-- actor-specific dialogue/barter/rest lifecycle event.
local function relayUiModeChanged(data)
    data = data or {}
    if data.actor and data.actor:isValid() then
        data.actor:sendEvent("SPerks_UiModeChanged", {
            oldMode = data.oldMode,
            newMode = data.newMode,
            arg = data.arg,
        })
    end
end

--- Adds a temporary or persistent modifier to an NPC skill.
--- @param data table { npc = GameObject, skill = string, amount = number }
local function modifyNpcSkill(data)
    data = data or {}
    if not data.npc or not data.npc:isValid() or not types.NPC.objectIsInstance(data.npc)
            or not data.skill then
        return
    end
    local stat = types.NPC.stats.skills[data.skill](data.npc)
    if stat then
        stat.modifier = stat.modifier + (data.amount or 0)
    end
end

--- Changes one NPC's base disposition toward a specific player.
--- @param data table { npc = GameObject, player = GameObject, amount = number }
local function modifyNpcDisposition(data)
    data = data or {}
    if not data.npc or not data.npc:isValid() or not data.player or not data.player:isValid()
            or not types.NPC.objectIsInstance(data.npc) then
        return
    end
    types.NPC.modifyBaseDisposition(data.npc, data.player, data.amount or 0)
end

--- Adds to an NPC's current barter gold, clamped at zero.
--- @param data table { npc = GameObject, amount = number }
local function modifyNpcBarterGold(data)
    data = data or {}
    if not data.npc or not data.npc:isValid() or not types.NPC.objectIsInstance(data.npc) then
        return
    end
    local current = types.Actor.getBarterGold(data.npc)
    types.Actor.setBarterGold(data.npc, math.max(0, current + (data.amount or 0)))
end

interfaces.Activation.addHandlerForType(types.Door, onSecurityLockableActivated)
interfaces.Activation.addHandlerForType(types.Container, onSecurityLockableActivated)

--- Relays actor activation to the activating player. Mysticism decides
--- player-locally whether Telekinetic Force is active and whether the actor
--- is hostile, so this global bridge never suppresses vanilla activation.
local function onMagicActorActivated(target, actor)
    if actor and types.Player.objectIsInstance(actor) then
        actor:sendEvent("SPerks_MagicActorActivated", { target = target })
    end
    return true
end

interfaces.Activation.addHandlerForType(types.NPC, onMagicActorActivated)
interfaces.Activation.addHandlerForType(types.Creature, onMagicActorActivated)

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
---   skipIfEffectActive = string|nil (do not apply while this effect has
---     positive magnitude on the target),
--- }
local function reportSpellApplication(data, result)
    local recipient = data.resultTarget
    if recipient == nil or not recipient:isValid() or data.resultEvent == nil then
        return
    end
    recipient:sendEvent(data.resultEvent, result)
end

--- Creates a dynamic spell, applies its selected effects, and optionally
--- confirms that the resulting active spell is present on the target.
local function createAndApplySpell(data)
    data = data or {}
    if not data.target or not data.target:isValid() then
        reportSpellApplication(data, {
            requestId = data.requestId,
            success = false,
            stage = "validate-target",
            error = "target is unavailable",
        })
        return
    end
    if not data.effects or #data.effects == 0 then
        reportSpellApplication(data, {
            requestId = data.requestId,
            success = false,
            stage = "validate-effects",
            error = "no effects supplied",
        })
        return
    end

    -- Some proc effects should neither stack nor refresh. Callers opt into
    -- this last-moment guard because the target can change after a player-local
    -- eligibility check but before the queued global event is handled.
    if data.skipIfEffectActive ~= nil then
        local effectOk, activeEffect = pcall(function()
            return types.Actor.activeEffects(data.target):getEffect(data.skipIfEffectActive)
        end)
        if effectOk and activeEffect ~= nil and (tonumber(activeEffect.magnitude) or 0) > 0 then
            reportSpellApplication(data, {
                requestId = data.requestId,
                target = data.target,
                targetId = data.target.id,
                effectId = data.skipIfEffectActive,
                success = false,
                active = true,
                skipped = true,
                stage = "effect-already-active",
            })
            return
        end
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

    local draftOk, draft = pcall(core.magic.spells.createRecordDraft, {
        id = draftId,
        name = data.spellName or "SkillPerks Effect",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 0,
        isAutocalc = false,
        alwaysSucceedFlag = true,
        effects = draftEffects,
    })
    if not draftOk then
        reportSpellApplication(data, {
            requestId = data.requestId,
            success = false,
            stage = "create-draft",
            error = tostring(draft),
        })
        return
    end

    local recordOk, newSpell = pcall(world.createRecord, draft)
    if not recordOk or newSpell == nil or newSpell.id == nil then
        reportSpellApplication(data, {
            requestId = data.requestId,
            success = false,
            stage = "create-record",
            error = recordOk and "world.createRecord returned no spell id" or tostring(newSpell),
        })
        return
    end

    local addOptions = data.activeSpellOptions or {}
    local activeSpells = types.Actor.activeSpells(data.target)
    local addOk, addError = pcall(function()
        activeSpells:add({
            id = newSpell.id,
            effects = effectIndices,
            caster = data.caster,
            ignoreReflect = addOptions.ignoreReflect,
            ignoreResistances = addOptions.ignoreResistances,
            ignoreSpellAbsorption = addOptions.ignoreSpellAbsorption,
            stackable = addOptions.stackable,
            quiet = addOptions.quiet,
        })
    end)
    local activeOk, active = pcall(function()
        return activeSpells:isSpellActive(newSpell.id)
    end)
    local success = addOk and activeOk and active == true
    reportSpellApplication(data, {
        requestId = data.requestId,
        target = data.target,
        targetId = data.target.id,
        spellId = newSpell.id,
        spellName = data.spellName,
        effectId = data.effects[1] and data.effects[1].id or nil,
        success = success,
        active = activeOk and active or false,
        stage = success and "active" or (addOk and "verify-active" or "add-active-spell"),
        error = not addOk and tostring(addError)
            or (not activeOk and tostring(active) or nil),
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
        SPerks_SetSecurityMasteryRank = setSecurityMasteryRank,
        SPerks_ResolveSecurityBareHandAttempt = resolveSecurityBareHandAttempt,
        SPerks_ModifyNpcSkill = modifyNpcSkill,
        SPerks_ModifyNpcDisposition = modifyNpcDisposition,
        SPerks_ModifyNpcBarterGold = modifyNpcBarterGold,
        IE_UIModeChanged = relayUiModeChanged,
        MagExp_OnMagicHit = relaySpellforgeMagicHit,
        MagExp_OnEffectApplied = relaySpellforgeEffectApplied,

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
