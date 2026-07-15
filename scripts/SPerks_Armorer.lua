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
    SPerks_Armorer.lua

    Armorer rewards careful maintenance, durable equipment, and repairs that
    keep gear useful through long expeditions. See SkillPerks_Combat.md's
    Armorer section for the full spec.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")

-- Reads the framework's cached player perk set for quick rank checks.
local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local SKILL_ID = "armorer"

local ids = {
    A1 = ns .. "_armorer_a1",
    A2 = ns .. "_armorer_a2",
    A3 = ns .. "_armorer_a3",
    A4 = ns .. "_armorer_a4",
    B1 = ns .. "_armorer_b1",
    B2 = ns .. "_armorer_b2",
    C1 = ns .. "_armorer_c1",
    C2 = ns .. "_armorer_c2",
    D1 = ns .. "_armorer_d1",
    D2 = ns .. "_armorer_d2",
}

-- ============================================================
--  SHARED HELPERS
-- ============================================================

local REPAIRABLE_TYPES = { types.Weapon, types.Armor, types.Repair, types.Lockpick, types.Probe }

-- True for anything with condition that Armorer perks are allowed to preserve.
local function isRepairable(item)
    for _, t in ipairs(REPAIRABLE_TYPES) do
        if t.objectIsInstance(item) then
            return true
        end
    end
    return false
end

-- Returns the condition ceiling for repairable objects with different record fields.
local function getMaxCondition(item)
    local record = item.type.record(item)
    return record.health or record.maxCondition
end

-- Pauses condition polling while over-repair is deliberately shifting values.
local dSessionActive = false

-- ============================================================
--  A CHAIN - PRACTICED HAND
-- ============================================================

local function getARank()
    if hasPerk(ids.A4) then return 4
    elseif hasPerk(ids.A3) then return 3
    elseif hasPerk(ids.A2) then return 2
    elseif hasPerk(ids.A1) then return 1
    else return 0 end
end

local aFallbackTracker = StatTracker.newStatModTracker(self)

-- A1 uses a persistent skill bonus because repair-roll timing is not hookable.
local function updateA1Fallback()
    aFallbackTracker.apply("skills", "armorer", getARank() > 0 and 5 or 0)
end

-- Removes the A1 effective Armorer skill bonus.
local function clearA1Fallback()
    aFallbackTracker.apply("skills", "armorer", 0)
end

-- Live/polled perks do their work from UI or update handlers, not on add/remove.
local function noPersistentEffect() end

local A2_FLAT_RESTORE = 5
local ARMORER_POLL_INTERVAL = 0.2
local ARMORER_REPAIR_MODE = "Repair"

local armorerPollTimer = 0
local lastToolId = nil
local lastToolCondition = nil
local aConditionSnapshot = {}
local pendingRepairTargetId = nil
local inventoryExtenderHandlersRegistered = false

-- Finds a carried item by OpenMW's unique object id.
local function findCarriedItemById(itemId)
    if not itemId then
        return nil
    end
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if item.id == itemId then
            return item
        end
    end
    return nil
end

-- Inventory Extender exposes the clicked repair target, which vanilla UI hooks do not.
local function captureRepairTarget(row)
    if interfaces.UI.getMode() == ARMORER_REPAIR_MODE and row and row.item and isRepairable(row.item) then
        pendingRepairTargetId = row.item.id
    end
    return true
end

-- Registers once with Inventory Extender so A2 can restore the actual failed item.
local function ensureInventoryExtenderHandlers()
    if inventoryExtenderHandlersRegistered then
        return
    end

    local inventoryExtender = interfaces.InventoryExtender
    if not inventoryExtender then
        return
    end

    inventoryExtender.registerRowUseHandler("SkillPerks_ArmorerRepairTarget", captureRepairTarget)
    inventoryExtender.registerRowPickupHandler("SkillPerks_ArmorerRepairTarget", captureRepairTarget)
    inventoryExtenderHandlersRegistered = true
end

-- Captures current carried item condition so repair attempts can be detected.
local function refreshAConditionSnapshot()
    local snapshot = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isRepairable(item) then
            local itemData = types.Item.itemData(item)
            if itemData and itemData.condition ~= nil then
                snapshot[item.id] = itemData.condition
            end
        end
    end
    return snapshot
end

-- Watches repair-tool wear to detect attempts, then applies A2-A4 benefits.
local function tickArmorerDetection(dt)
    if getARank() < 2 then
        return
    end
    armorerPollTimer = armorerPollTimer - dt
    if armorerPollTimer > 0 then
        return
    end
    armorerPollTimer = ARMORER_POLL_INTERVAL

    local tool = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not tool or not types.Repair.objectIsInstance(tool) then
        lastToolId = nil
        lastToolCondition = nil
        aConditionSnapshot = refreshAConditionSnapshot()
        return
    end

    local toolData = types.Item.itemData(tool)
    local toolCondition = toolData and toolData.condition

    if tool.id ~= lastToolId then
        lastToolId = tool.id
        lastToolCondition = toolCondition
        aConditionSnapshot = refreshAConditionSnapshot()
        return
    end

    if toolCondition == nil or lastToolCondition == nil or toolCondition >= lastToolCondition then
        return
    end

    local succeeded = false

    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isRepairable(item) then
            local itemData = types.Item.itemData(item)
            local newCond = itemData and itemData.condition
            local oldCond = aConditionSnapshot[item.id]
            if newCond and oldCond and newCond > oldCond then
                succeeded = true
            end
        end
    end

    if succeeded then
        if getARank() >= 4 then
            local quality = types.Repair.record(tool).quality or 1
            local saveChance = math.min(0.75, quality * 0.15)
            if math.random() < saveChance then
                toolData.condition = lastToolCondition
            end
        end
    else
        if getARank() >= 3 then
            toolData.condition = lastToolCondition
        end
        local target = findCarriedItemById(pendingRepairTargetId)
        if getARank() >= 2 and target then
            local itemData = types.Item.itemData(target)
            local maxCond = getMaxCondition(target)
            if itemData and maxCond then
                itemData.condition = math.min(maxCond, itemData.condition + A2_FLAT_RESTORE)
            end
        end
    end

    local refreshedToolData = types.Item.itemData(tool)
    lastToolCondition = refreshedToolData and refreshedToolData.condition
    aConditionSnapshot = refreshAConditionSnapshot()
    pendingRepairTargetId = nil
end

-- ============================================================
--  B CHAIN - DURABLE CRAFT
-- ============================================================

local B_REDUCTION = { [1] = 0.25, [2] = 0.50 }
local B_POLL_INTERVAL = 0.5

local bPollTimer = 0
local bConditionSnapshot = {}

-- Returns the current gear-condition loss reduction rank.
local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

-- Captures current carried item condition for later loss comparison.
local function refreshBSnapshot()
    local snapshot = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isRepairable(item) then
            local itemData = types.Item.itemData(item)
            if itemData and itemData.condition ~= nil then
                snapshot[item.id] = itemData.condition
            end
        end
    end
    return snapshot
end

-- Refunds part of any condition loss observed since the last snapshot.
local function tickDurableCraft(dt)
    local rank = getBRank()
    if rank == 0 then
        bConditionSnapshot = {}
        return
    end
    if dSessionActive then
        return
    end
    bPollTimer = bPollTimer - dt
    if bPollTimer > 0 then
        return
    end
    bPollTimer = B_POLL_INTERVAL

    local reduction = B_REDUCTION[rank]
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isRepairable(item) then
            local itemData = types.Item.itemData(item)
            local newCond = itemData and itemData.condition
            local oldCond = bConditionSnapshot[item.id]
            if newCond and oldCond and newCond < oldCond then
                local lost = oldCond - newCond
                local maxCond = getMaxCondition(item)
                local refund = lost * reduction
                if maxCond then
                    itemData.condition = math.min(maxCond, newCond + refund)
                else
                    itemData.condition = newCond + refund
                end
            end
        end
    end
    bConditionSnapshot = refreshBSnapshot()
end

-- ============================================================
--  C CHAIN - FIELD MAINTENANCE
-- ============================================================

local C_MULT = { [1] = 1, [2] = 2 }

-- Returns whether rest-based field repairs are active and doubled.
local function getCRank()
    if hasPerk(ids.C2) then return 2
    elseif hasPerk(ids.C1) then return 1
    else return 0 end
end

-- Resting indoors lets the player perform light maintenance on damaged gear.
local function onRestComplete()
    local rank = getCRank()
    if rank == 0 then
        return
    end
    if self.cell == nil or self.cell.isExterior then
        return
    end

    local armorerSkill = types.NPC.stats.skills.armorer(self).modified

    local damagedItems = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isRepairable(item) then
            local itemData = types.Item.itemData(item)
            local maxCond = getMaxCondition(item)
            if itemData and itemData.condition and maxCond and itemData.condition < maxCond then
                table.insert(damagedItems, { item = item, itemData = itemData, maxCond = maxCond })
            end
        end
    end
    if #damagedItems == 0 then
        return
    end

    local perItemRestore = (armorerSkill / #damagedItems) * C_MULT[rank]

    if rank >= 2 then
        local equipped, unequipped = {}, {}
        for _, entry in ipairs(damagedItems) do
            if types.Actor.hasEquipped(self, entry.item) then
                table.insert(equipped, entry)
            else
                table.insert(unequipped, entry)
            end
        end

        local leftoverPool = 0
        for _, entry in ipairs(equipped) do
            local needed = entry.maxCond - entry.itemData.condition
            local applied = math.min(needed, perItemRestore)
            entry.itemData.condition = entry.itemData.condition + applied
            leftoverPool = leftoverPool + (perItemRestore - applied)
        end
        if #unequipped > 0 then
            local perUnequipped = perItemRestore + (leftoverPool / #unequipped)
            for _, entry in ipairs(unequipped) do
                entry.itemData.condition = math.min(entry.maxCond, entry.itemData.condition + perUnequipped)
            end
        end
    else
        for _, entry in ipairs(damagedItems) do
            entry.itemData.condition = math.min(entry.maxCond, entry.itemData.condition + perItemRestore)
        end
    end
end

-- ============================================================
--  D CHAIN - OVER-REPAIR
-- ============================================================

local D_RATIO = { [1] = 0.25, [2] = 0.50 } -- +25%/+50% over base = 125%/150% total

-- Returns the active over-repair ceiling.
local function getDRank()
    if hasPerk(ids.D2) then return 2
    elseif hasPerk(ids.D1) then return 1
    else return 0 end
end

local dSubtractedAmounts = {}

-- Copies pending over-repair adjustments into save data without sharing state.
local function copyNumberMap(map)
    local out = {}
    for key, value in pairs(map or {}) do
        out[key] = value
    end
    return out
end

-- Temporarily lowers item condition so vanilla repair can push it past base max.
local function onRepairUIOpened()
    pendingRepairTargetId = nil

    local rank = getDRank()
    if rank == 0 or dSessionActive then
        return
    end
    dSessionActive = true
    dSubtractedAmounts = {}

    local ratio = D_RATIO[rank]
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isRepairable(item) then
            local itemData = types.Item.itemData(item)
            local maxCond = getMaxCondition(item)
            if itemData and itemData.condition and maxCond then
                local subtract = maxCond * ratio
                itemData.condition = itemData.condition - subtract
                dSubtractedAmounts[item.id] = (dSubtractedAmounts[item.id] or 0) + subtract
            end
        end
    end
    aConditionSnapshot = refreshAConditionSnapshot()

    local tool = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    local toolData = tool and types.Item.itemData(tool)
    lastToolId = tool and tool.id or nil
    lastToolCondition = toolData and toolData.condition or nil
end

-- Restores the temporary subtraction after the player leaves self-repair.
local function onRepairUIClosed()
    pendingRepairTargetId = nil
    if not dSessionActive then
        return
    end
    dSessionActive = false

    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        local subtracted = dSubtractedAmounts[item.id]
        if subtracted and subtracted > 0 then
            local itemData = types.Item.itemData(item)
            if itemData and itemData.condition then
                itemData.condition = itemData.condition + subtracted
            end
        end
    end
    dSubtractedAmounts = {}
end

-- Routes rest and self-repair UI transitions into Armorer perk handlers.
local function onUiModeChanged(data)
    if data.oldMode == 'Rest' then
        onRestComplete()
    end

    if data.newMode == ARMORER_REPAIR_MODE and data.oldMode ~= ARMORER_REPAIR_MODE then
        onRepairUIOpened()
    elseif data.oldMode == ARMORER_REPAIR_MODE and data.newMode ~= ARMORER_REPAIR_MODE then
        onRepairUIClosed()
    end
end

-- Polls condition changes that OpenMW does not expose as direct events.
local function onUpdate(dt)
    ensureInventoryExtenderHandlers()
    tickArmorerDetection(dt)
    tickDurableCraft(dt)
end

-- Persists the skill bonus and any temporary over-repair subtraction.
local function onSave()
    return {
        aFallbackSnapshot = aFallbackTracker.snapshot(),
        dSessionActive = dSessionActive,
        dSubtractedAmounts = copyNumberMap(dSubtractedAmounts),
    }
end

-- Reverses saved deltas and clears in-progress condition tracking.
local function onLoad(data)
    data = data or {}
    aFallbackTracker.restoreAndReverse(data.aFallbackSnapshot)

    if data.dSessionActive then
        dSessionActive = true
        dSubtractedAmounts = data.dSubtractedAmounts or {}
        onRepairUIClosed()
    end

    lastToolId = nil
    lastToolCondition = nil
    aConditionSnapshot = {}
    bConditionSnapshot = {}
    dSessionActive = false
    dSubtractedAmounts = {}
end

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Practiced Hand",
    category = ChainRequirements.category("Combat", "Armorer", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A hammer, a strap, a loose rivet: each has a voice, and your hands have learned to listen.",
    localizedDescription = "Your repairs are more effective - a passive +5 to your effective "
        .. "Armorer skill.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = updateA1Fallback,
    onRemove = clearA1Fallback,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Salvage Sense",
    category = ChainRequirements.category("Combat", "Armorer", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Even a failed repair leaves evidence behind. A bent plate, a stubborn seam, a lesson worth taking.",
    localizedDescription = "Failed repairs still restore a small amount of condition to the "
        .. "item you attempted to repair.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Careful Craftsman",
    category = ChainRequirements.category("Combat", "Armorer", 3),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You no longer strike blindly at the work. If the metal refuses, your tool comes away whole.",
    localizedDescription = "Failed repairs no longer consume durability from your repair tool.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Master Tinkerer",
    category = ChainRequirements.category("Combat", "Armorer", 4),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Fine tools deserve fine hands. Under your care, a good hammer lasts long past the work that should have spent it.",
    localizedDescription = "Successful repairs have a chance not to degrade your repair tool, "
        .. "scaling with the tool's own quality.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Durable Craft",
    category = ChainRequirements.category("Combat", "Armorer", 5),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You know where gear fails: the hairline crack, the tired hinge, the strap that will betray its owner in rain.",
    localizedDescription = "All your equipped and carried gear loses 25% less condition from "
        .. "use and damage.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Reinforced Craft",
    category = ChainRequirements.category("Combat", "Armorer", 6),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your repairs do not merely close damage. They teach the item how to resist the next insult.",
    localizedDescription = "Condition loss reduction increases to 50%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Field Maintenance",
    category = ChainRequirements.category("Combat", "Armorer", 7),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A dry room, a little lamplight, and enough patience can turn a night's rest into a working bench.",
    localizedDescription = "Resting in an interior cell partially restores condition to all "
        .. "damaged items in your inventory, split evenly among them.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Traveling Workshop",
    category = ChainRequirements.category("Combat", "Armorer", 9),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your workshop is no longer a place. It is a habit you carry, unfolding wherever the road finally lets you stop.",
    localizedDescription = "The restored amount doubles, and equipped gear is repaired to its "
        .. "full share before whatever's left is split among the rest of your inventory.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Over-Repair",
    category = ChainRequirements.category("Combat", "Armorer", 8),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A maker's limit is not always the item's limit. You have learned where the hidden strength still waits.",
    localizedDescription = "Items you repair can now be restored beyond their base maximum "
        .. "condition, up to 125%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Beyond Perfection",
    category = ChainRequirements.category("Combat", "Armorer", 10),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Perfect condition was never the ceiling. It was only the point where lesser craftsmen stopped asking questions.",
    localizedDescription = "Items can now be repaired up to 150% of their base maximum condition.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

return {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onInit = ensureInventoryExtenderHandlers,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
