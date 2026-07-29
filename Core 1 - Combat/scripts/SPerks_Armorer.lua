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
local core       = require("openmw.core")
local async      = require("openmw.async")
local ui         = require("openmw.ui")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local SkillDebug        = require("scripts.SkillPerks.shared.debug")

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
local OVERREPAIR_TYPES = { types.Weapon, types.Armor }

-- True for anything with condition that Armorer perks are allowed to preserve.
local function isRepairable(item)
    for _, t in ipairs(REPAIRABLE_TYPES) do
        if t.objectIsInstance(item) then
            return true
        end
    end
    return false
end

-- Over-repair should only raise combat gear above its normal ceiling.
-- Tools still need A-chain durability tracking, but should never be
-- temporarily damaged just because the repair menu opened.
local function canOverRepair(item)
    for _, t in ipairs(OVERREPAIR_TYPES) do
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

-- Item condition writes are global/self scoped. Player scripts can read
-- carried item condition, but must ask Core 0's global script to change it.
local function modifyItemCondition(item, amount, maxCondition, minCondition)
    core.sendGlobalEvent("SPerks_ModifyItemCondition", {
        item = item,
        amount = amount,
        maxCondition = maxCondition,
        minCondition = minCondition,
    })
end

local function setItemCondition(item, value, maxCondition, minCondition)
    core.sendGlobalEvent("SPerks_ModifyItemCondition", {
        item = item,
        value = value,
        maxCondition = maxCondition,
        minCondition = minCondition,
    })
end

local function removeItem(item)
    core.sendGlobalEvent("SPerks_RemoveItem", {
        item = item,
        count = 1,
    })
end

-- Inventory Extender can keep repair-window row data cached after a global
-- condition write. Refreshing shortly after the write makes A3/A4 tool saves
-- visible before the player leaves the repair menu.
local function refreshInventoryExtenderSoon()
    local inventoryExtender = interfaces.InventoryExtender
    if not inventoryExtender or not inventoryExtender.update then
        return
    end

    async:newUnsavableSimulationTimer(0.03, function()
        pcall(inventoryExtender.update)
    end)
    async:newUnsavableSimulationTimer(0.12, function()
        pcall(inventoryExtender.update)
    end)
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

local ARMORER_TOOLKIT = {
    [1] = { recordId = "SPerks Repair Tongs", name = "Repair Tongs" },
    [2] = { recordId = "SPerks Journeyman Repair Hammer", name = "Journeyman Repair Hammer" },
    [3] = { recordId = "SPerks Master Repair Hammer", name = "Master Repair Hammer" },
    [4] = { recordId = "Sperks SMaster Repair Hammer", name = "Secret Master's Repair Hammer" },
}

local ARMORER_TOOLKIT_RECORDS = {}
for _, tool in pairs(ARMORER_TOOLKIT) do
    ARMORER_TOOLKIT_RECORDS[tool.recordId:lower()] = true
end

local A2_FLAT_RESTORE = 5
local ARMORER_POLL_INTERVAL = 0.2
local ARMORER_REPAIR_MODE = "Repair"
local MASTER_TINKERER_MIN_QUALITY = 0.5
local MASTER_TINKERER_MAX_QUALITY = 2.0
local MASTER_TINKERER_MIN_CHANCE = 0.10
local MASTER_TINKERER_MAX_CHANCE = 0.75
local TOOL_SAFETY_CONDITION = 2

local armorerPollTimer = 0
local toolkitPollTimer = 0
local lastToolId = nil
local lastToolCondition = nil
local aConditionSnapshot = {}
local pendingRepairTargetId = nil
local pendingRepairAttempts = {}
local maintainedToolkitItemId = nil
local maintainedToolkitRecordId = nil
local toolkitCreatePending = false
local toolkitLastGrantDay = nil
local toolkitClockNeedsBaseline = true
local repairToolSafetyReserves = {}
local inventoryExtenderHandlersRegistered = false
local onRepairUIOpened
local refreshAConditionSnapshot
local queueRepairAttempt

-- Live/polled perks do their work from UI or update handlers, not on add/remove.
local function noPersistentEffect() end

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

local function removePendingRepairAttempt(attempt)
    for i = #pendingRepairAttempts, 1, -1 do
        if pendingRepairAttempts[i] == attempt then
            table.remove(pendingRepairAttempts, i)
            return
        end
    end
end

-- Scales Master Tinkerer from ordinary tools to high-quality tools without
-- making exceptional 5.0+ tools the basis of the whole curve.
local function getMasterTinkererSaveChance(tool)
    local quality = types.Repair.record(tool).quality or MASTER_TINKERER_MIN_QUALITY
    if quality >= MASTER_TINKERER_MAX_QUALITY then
        return MASTER_TINKERER_MAX_CHANCE
    end
    if quality <= MASTER_TINKERER_MIN_QUALITY then
        return MASTER_TINKERER_MIN_CHANCE
    end

    local t = (quality - MASTER_TINKERER_MIN_QUALITY)
        / (MASTER_TINKERER_MAX_QUALITY - MASTER_TINKERER_MIN_QUALITY)
    local smooth = t * t * (3 - (2 * t))
    return MASTER_TINKERER_MIN_CHANCE
        + ((MASTER_TINKERER_MAX_CHANCE - MASTER_TINKERER_MIN_CHANCE) * smooth)
end

-- Keeps one-use repair tools alive until A3/A4 can decide whether the use
-- should be saved. Without this reserve, vanilla destroys the tool at zero
-- condition before the delayed repair-result resolver can restore it.
local function ensureRepairToolSafetyReserve(tool)
    if getARank() < 3 or not tool or not types.Repair.objectIsInstance(tool) then
        return
    end
    if repairToolSafetyReserves[tool.id] then
        return
    end

    local toolData = types.Item.itemData(tool)
    local condition = toolData and toolData.condition
    if not condition or condition <= 0 or condition >= TOOL_SAFETY_CONDITION then
        return
    end

    local reserve = TOOL_SAFETY_CONDITION - condition
    repairToolSafetyReserves[tool.id] = reserve
    setItemCondition(tool, TOOL_SAFETY_CONDITION, nil, false)
    refreshInventoryExtenderSoon()
end

local function getRepairToolSafetyReserve(tool)
    if not tool then
        return 0
    end
    return repairToolSafetyReserves[tool.id] or 0
end

local function getLogicalToolCondition(tool, actualCondition)
    if actualCondition == nil then
        return nil
    end
    local reserve = getRepairToolSafetyReserve(tool)
    if reserve <= 0 then
        return actualCondition
    end
    if actualCondition <= reserve then
        return actualCondition
    end
    return actualCondition - reserve
end

local function clearRepairToolSafetyReserves()
    for itemId, reserve in pairs(repairToolSafetyReserves) do
        local tool = findCarriedItemById(itemId)
        if tool and types.Repair.objectIsInstance(tool) then
            local toolData = types.Item.itemData(tool)
            local condition = toolData and toolData.condition
            if condition then
                local logicalCondition = condition - reserve
                if logicalCondition <= 0 then
                    removeItem(tool)
                else
                    setItemCondition(tool, logicalCondition, nil, false)
                end
            end
        end
    end
    repairToolSafetyReserves = {}
    refreshInventoryExtenderSoon()
end

local function isArmorerToolkitRecord(recordId)
    return recordId and ARMORER_TOOLKIT_RECORDS[recordId:lower()] == true
end

local function isProtectedToolkitItem(item)
    return item and isArmorerToolkitRecord(item.recordId)
end

local function blockProtectedToolkitAction()
    ui.showMessage("This tool is part of your Armorer kit.")
    return false
end

local function forgetMaintainedToolkitItem()
    maintainedToolkitItemId = nil
    maintainedToolkitRecordId = nil
end

local function removeMaintainedToolkitItem()
    local item = findCarriedItemById(maintainedToolkitItemId)
    if item and isArmorerToolkitRecord(item.recordId) then
        removeItem(item)
    end
    forgetMaintainedToolkitItem()
end

-- Returns any perk-granted Armorer tool in the player's inventory. The four
-- A-chain tools form one shared pool: owning an older tool prevents a newer
-- rank from preparing another until the existing tool has been spent.
local function findExistingToolkitItem()
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if isArmorerToolkitRecord(item.recordId) then
            return item
        end
    end
    return nil
end

local function rememberToolkitItem(item)
    if not item then
        return
    end
    maintainedToolkitItemId = item.id
    maintainedToolkitRecordId = item.recordId
end

-- Returns the current whole in-game day. Game time is monotonic seconds, so
-- this remains stable across month/year boundaries and advances through rest
-- and travel without depending on calendar globals.
local function currentGameDay()
    return math.floor(core.getGameTime() / (24 * 60 * 60))
end

-- Grants at most one A-chain tool per in-game day, and only while none of the
-- four perk tools remains in the player's inventory. Loading establishes a
-- fresh baseline day, so this polling function cannot create a tool merely
-- because Lua reloaded or the player changed cell.
local function maintainArmorerToolkit()
    local rank = getARank()
    SkillDebug.traceEvent(SKILL_ID, "daily toolkit check", {
        day = currentGameDay(),
        pending = toolkitCreatePending,
        rank = rank,
    })
    if rank == 0 then
        removeMaintainedToolkitItem()
        toolkitCreatePending = false
        return
    end

    local desired = ARMORER_TOOLKIT[rank]
    if not desired then
        return
    end

    local day = currentGameDay()
    if toolkitClockNeedsBaseline then
        toolkitLastGrantDay = day
        toolkitClockNeedsBaseline = false
    end

    local existing = findExistingToolkitItem()
    if existing then
        rememberToolkitItem(existing)
        toolkitCreatePending = false
        return
    end
    forgetMaintainedToolkitItem()

    if toolkitLastGrantDay == nil or day <= toolkitLastGrantDay then
        return
    end

    if toolkitCreatePending then
        existing = findExistingToolkitItem()
        if existing then
            rememberToolkitItem(existing)
            toolkitCreatePending = false
        end
        return
    end

    toolkitLastGrantDay = day
    toolkitCreatePending = true
    core.sendGlobalEvent("SPerks_DuplicateItem", {
        target = self,
        recordId = desired.recordId,
        count = 1,
    })
    ui.showMessage("You prepare a " .. desired.name .. ".")
end

-- Remembers the repair tool selected in Inventory Extender for A-chain polling.
local function rememberRepairTool(tool, keepSnapshot)
    if not tool or not types.Repair.objectIsInstance(tool) then
        return
    end

    local toolData = types.Item.itemData(tool)
    lastToolId = tool.id
    lastToolCondition = toolData and getLogicalToolCondition(tool, toolData.condition) or nil
    if not keepSnapshot and refreshAConditionSnapshot then
        aConditionSnapshot = refreshAConditionSnapshot()
    end
end

-- Inventory Extender exposes the clicked repair target, which vanilla UI hooks do not.
local function captureRepairTarget(row, ctx, windowType)
    if not row or not row.item then
        return true
    end

    if isProtectedToolkitItem(row.item) then
        return blockProtectedToolkitAction()
    end

    -- Repair-tool use opens the vanilla repair UI after row handlers return.
    -- Prepare over-repair here so the item list is built from the lowered
    -- condition values instead of waiting for UiModeChanged, which is too late.
    if interfaces.UI.getMode() ~= ARMORER_REPAIR_MODE and types.Repair.objectIsInstance(row.item) then
        rememberRepairTool(row.item)
        onRepairUIOpened(row.item)
        return true
    end

    if interfaces.UI.getMode() == ARMORER_REPAIR_MODE and isRepairable(row.item) then
        pendingRepairTargetId = row.item.id
        if queueRepairAttempt then
            queueRepairAttempt(row.item)
        end
    end
    return true
end

local function protectToolkitPickup(row, ctx, windowType)
    if row and isProtectedToolkitItem(row.item) then
        if interfaces.UI.getMode() == "Interface" and windowType == "Inventory" then
            return true
        end
        if windowType ~= "Inventory" then
            removeItem(row.item)
            refreshInventoryExtenderSoon()
        end
        return blockProtectedToolkitAction()
    end
    return captureRepairTarget(row, ctx, windowType)
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
    inventoryExtender.registerRowPickupHandler("SkillPerks_ArmorerRepairTarget", protectToolkitPickup)
    inventoryExtenderHandlersRegistered = true
end

-- Captures current carried item condition so repair attempts can be detected.
refreshAConditionSnapshot = function()
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

-- Returns the remembered repair tool, falling back to the carried-right slot.
local function getActiveRepairTool()
    local tool = findCarriedItemById(lastToolId)
    if tool and types.Repair.objectIsInstance(tool) then
        return tool
    end

    tool = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if tool and types.Repair.objectIsInstance(tool) then
        return tool
    end

    return nil
end

local function resolveRepairAttempt(attempt)
    SkillDebug.traceEvent(SKILL_ID, "repair attempt resolving", {
        target = attempt and attempt.targetId,
        tool = attempt and attempt.toolId,
    })
    removePendingRepairAttempt(attempt)

    local tool = findCarriedItemById(attempt.toolId)
    local toolExists = tool and types.Repair.objectIsInstance(tool)
    local rank = getARank()

    local toolData = toolExists and types.Item.itemData(tool) or nil
    local toolAfter = toolData and toolData.condition
    local toolWasUsed = (not toolExists and attempt.toolActualBefore ~= nil)
        or (toolAfter and attempt.toolActualBefore and toolAfter < attempt.toolActualBefore)

    local target = findCarriedItemById(attempt.targetId)
    local targetData = target and types.Item.itemData(target)
    local targetAfter = targetData and targetData.condition
    local succeeded = targetAfter and attempt.targetBefore and targetAfter > attempt.targetBefore
    local expectedToolCondition = nil

    if not toolWasUsed then
        if toolExists then
            lastToolId = tool.id
            lastToolCondition = getLogicalToolCondition(tool, toolAfter)
        end
        aConditionSnapshot = refreshAConditionSnapshot()
        return
    end

    if succeeded then
        if toolExists and rank >= 4 and math.random() < getMasterTinkererSaveChance(tool) then
            setItemCondition(tool, attempt.toolActualBefore, nil, false)
            refreshInventoryExtenderSoon()
            expectedToolCondition = attempt.toolBefore
        end
    else
        if toolExists and rank >= 3 then
            setItemCondition(tool, attempt.toolActualBefore, nil, false)
            refreshInventoryExtenderSoon()
            expectedToolCondition = attempt.toolBefore
        end
        if rank >= 2 and target then
            local maxCond = getMaxCondition(target)
            if maxCond then
                modifyItemCondition(target, A2_FLAT_RESTORE, maxCond)
            end
        end
    end

    if toolExists then
        local reserve = getRepairToolSafetyReserve(tool)
        if expectedToolCondition == nil and reserve > 0 and toolAfter <= reserve then
            removeItem(tool)
            repairToolSafetyReserves[tool.id] = nil
            refreshInventoryExtenderSoon()
            lastToolId = nil
            lastToolCondition = nil
        else
            lastToolId = tool.id
            lastToolCondition = expectedToolCondition or getLogicalToolCondition(tool, toolAfter)
        end
    end
    aConditionSnapshot = refreshAConditionSnapshot()
    pendingRepairTargetId = nil
end

-- Inventory Extender tells us exactly which item the player clicked in the
-- repair UI. Resolve A2-A4 from that click instead of relying only on a
-- later poll of whichever repair tool OpenMW still exposes.
queueRepairAttempt = function(target)
    SkillDebug.traceEvent(SKILL_ID, "repair click observed", {
        rank = getARank(),
        target = SkillDebug.objectId(target),
    })
    if getARank() < 1 then
        return
    end

    local tool = getActiveRepairTool()
    if not tool or not target then
        return
    end

    local toolData = types.Item.itemData(tool)
    local targetData = types.Item.itemData(target)
    if not toolData or toolData.condition == nil or not targetData or targetData.condition == nil then
        return
    end

    local attempt = {
        toolId = tool.id,
        targetId = target.id,
        toolActualBefore = toolData.condition,
        toolBefore = getLogicalToolCondition(tool, toolData.condition),
        targetBefore = targetData.condition,
    }
    table.insert(pendingRepairAttempts, attempt)

    async:newUnsavableSimulationTimer(0.12, function()
        resolveRepairAttempt(attempt)
    end)
end

-- Watches repair-tool wear to detect attempts, then applies A2-A4 benefits.
local function tickArmorerDetection(dt)
    if getARank() < 2 then
        return
    end
    if #pendingRepairAttempts > 0 then
        return
    end
    armorerPollTimer = armorerPollTimer - dt
    if armorerPollTimer > 0 then
        return
    end
    armorerPollTimer = ARMORER_POLL_INTERVAL

    local tool = getActiveRepairTool()
    if not tool then
        lastToolId = nil
        lastToolCondition = nil
        aConditionSnapshot = refreshAConditionSnapshot()
        return
    end

    local toolData = types.Item.itemData(tool)
    local toolCondition = toolData and toolData.condition
    local logicalToolCondition = getLogicalToolCondition(tool, toolCondition)

    if tool.id ~= lastToolId then
        lastToolId = tool.id
        lastToolCondition = logicalToolCondition
        aConditionSnapshot = refreshAConditionSnapshot()
        return
    end

    if logicalToolCondition == nil or lastToolCondition == nil or logicalToolCondition >= lastToolCondition then
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

    local expectedToolCondition = nil
    if succeeded then
        if getARank() >= 4 then
            local saveChance = getMasterTinkererSaveChance(tool)
            if math.random() < saveChance then
                setItemCondition(tool, lastToolCondition + getRepairToolSafetyReserve(tool), nil, false)
                refreshInventoryExtenderSoon()
                expectedToolCondition = lastToolCondition
            end
        end
    else
        if getARank() >= 3 then
            setItemCondition(tool, lastToolCondition + getRepairToolSafetyReserve(tool), nil, false)
            refreshInventoryExtenderSoon()
            expectedToolCondition = lastToolCondition
        end
        local target = findCarriedItemById(pendingRepairTargetId)
        if getARank() >= 2 and target then
            local itemData = types.Item.itemData(target)
            local maxCond = getMaxCondition(target)
            if itemData and maxCond then
                modifyItemCondition(target, A2_FLAT_RESTORE, maxCond)
            end
        end
    end

    if expectedToolCondition ~= nil then
        lastToolCondition = expectedToolCondition
    else
        local refreshedToolData = types.Item.itemData(tool)
        lastToolCondition = refreshedToolData and getLogicalToolCondition(tool, refreshedToolData.condition)
    end
    aConditionSnapshot = refreshAConditionSnapshot()
    pendingRepairTargetId = nil
end

-- ============================================================
--  B CHAIN - DURABLE CRAFT
-- ============================================================

local B_REDUCTION = { [1] = 0.25, [2] = 0.50 }
local B_POLL_INTERVAL = 0.5
local OVERREPAIR_CLAMP_MIN_LOSS = 1

local bPollTimer = 0
local bConditionSnapshot = {}

-- Returns the current gear-condition loss reduction rank.
local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

-- OpenMW can snap over-repaired items back to base max on the first
-- condition hit. Treat that as a tiny real loss, not a 25/50-point crash.
local function restoreDurabilityLoss(item, oldCond, newCond, reduction)
    local maxCond = getMaxCondition(item)
    if maxCond and oldCond > maxCond and newCond <= maxCond then
        local visibleLoss = math.max(0, maxCond - newCond)
        local estimatedLoss = math.max(OVERREPAIR_CLAMP_MIN_LOSS, visibleLoss)
        local targetCondition = oldCond - (estimatedLoss * (1 - reduction))
        setItemCondition(item, targetCondition, oldCond)
        return
    end

    local lost = oldCond - newCond
    local refund = lost * reduction
    modifyItemCondition(item, refund, oldCond)
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
                restoreDurabilityLoss(item, oldCond, newCond, reduction)
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
    SkillDebug.traceEvent(SKILL_ID, "rest completed", {
        interior = self.cell ~= nil and not self.cell.isExterior,
        rank = rank,
    })
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
            modifyItemCondition(entry.item, applied, entry.maxCond)
            leftoverPool = leftoverPool + (perItemRestore - applied)
        end
        if #unequipped > 0 then
            local perUnequipped = perItemRestore + (leftoverPool / #unequipped)
            for _, entry in ipairs(unequipped) do
                modifyItemCondition(entry.item, perUnequipped, entry.maxCond)
            end
        end
    else
        for _, entry in ipairs(damagedItems) do
            modifyItemCondition(entry.item, perItemRestore, entry.maxCond)
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
onRepairUIOpened = function(tool)
    SkillDebug.traceEvent(SKILL_ID, "repair UI opened", {
        dRank = getDRank(),
        tool = SkillDebug.objectId(tool),
    })
    pendingRepairTargetId = nil

    if tool then
        ensureRepairToolSafetyReserve(tool)
        rememberRepairTool(tool)
    end

    local rank = getDRank()
    if rank == 0 or dSessionActive then
        return
    end
    dSessionActive = true
    dSubtractedAmounts = {}

    local ratio = D_RATIO[rank]
    aConditionSnapshot = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll()) do
        if canOverRepair(item) then
            local itemData = types.Item.itemData(item)
            local maxCond = getMaxCondition(item)
            if itemData and itemData.condition and maxCond then
                local subtract = maxCond * ratio
                modifyItemCondition(item, -subtract, nil, false)
                dSubtractedAmounts[item.id] = (dSubtractedAmounts[item.id] or 0) + subtract
                aConditionSnapshot[item.id] = itemData.condition - subtract
            end
        end
    end

    tool = tool or getActiveRepairTool()
    if tool then
        ensureRepairToolSafetyReserve(tool)
        rememberRepairTool(tool, true)
    end
end

-- Restores the temporary subtraction after the player leaves self-repair.
local function onRepairUIClosed()
    SkillDebug.traceEvent(SKILL_ID, "repair UI closed", {
        overRepairSession = dSessionActive,
        pendingAttempts = #pendingRepairAttempts,
    })
    pendingRepairTargetId = nil
    clearRepairToolSafetyReserves()

    if dSessionActive then
        dSessionActive = false

        for _, item in ipairs(types.Actor.inventory(self):getAll()) do
            local subtracted = dSubtractedAmounts[item.id]
            if subtracted and subtracted > 0 then
                local itemData = types.Item.itemData(item)
                if itemData and itemData.condition then
                    modifyItemCondition(item, subtracted)
                end
            end
        end
        dSubtractedAmounts = {}
    end

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
    toolkitPollTimer = toolkitPollTimer - dt
    if toolkitPollTimer <= 0 then
        toolkitPollTimer = 1.0
        maintainArmorerToolkit()
    end
    tickArmorerDetection(dt)
    tickDurableCraft(dt)
end

-- Persists temporary repair state and the daily toolkit allowance.
local function onSave()
    return {
        dSessionActive = dSessionActive,
        dSubtractedAmounts = copyNumberMap(dSubtractedAmounts),
        repairToolSafetyReserves = copyNumberMap(repairToolSafetyReserves),
        maintainedToolkitItemId = maintainedToolkitItemId,
        maintainedToolkitRecordId = maintainedToolkitRecordId,
        toolkitLastGrantDay = toolkitLastGrantDay,
    }
end

-- Reverses saved deltas, clears in-progress condition tracking, and forces
-- the next update to baseline the loaded day without granting a tool.
local function onLoad(data)
    data = data or {}
    maintainedToolkitItemId = data.maintainedToolkitItemId
    maintainedToolkitRecordId = data.maintainedToolkitRecordId
    toolkitCreatePending = false
    toolkitLastGrantDay = data.toolkitLastGrantDay
    toolkitClockNeedsBaseline = true

    if data.dSessionActive then
        dSessionActive = true
        dSubtractedAmounts = data.dSubtractedAmounts or {}
        onRepairUIClosed()
    end
    repairToolSafetyReserves = data.repairToolSafetyReserves or {}
    clearRepairToolSafetyReserves()

    lastToolId = nil
    lastToolCondition = nil
    aConditionSnapshot = {}
    bConditionSnapshot = {}
    dSessionActive = false
    dSubtractedAmounts = {}
end

-- Reports both repair-session tracking and the once-per-day toolkit state.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Armorer",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luaarmorer debug", "luaarm debug" },
    snapshot = function()
        return {
            string.format(
                "Repair UI: active=%s target=%s attempts=%d lastTool=%s condition=%s",
                tostring(dSessionActive),
                tostring(pendingRepairTargetId),
                #pendingRepairAttempts,
                tostring(lastToolId),
                SkillDebug.value(lastToolCondition)
            ),
            string.format(
                "Toolkit: item=%s record=%s pending=%s lastGrantDay=%s baselineNeeded=%s",
                tostring(maintainedToolkitItemId),
                tostring(maintainedToolkitRecordId),
                tostring(toolkitCreatePending),
                SkillDebug.value(toolkitLastGrantDay),
                tostring(toolkitClockNeedsBaseline)
            ),
            string.format(
                "Protection: safetyReserves=%d overrepairItems=%d InventoryExtender=%s",
                SkillDebug.count(repairToolSafetyReserves),
                SkillDebug.count(dSubtractedAmounts),
                tostring(inventoryExtenderHandlersRegistered)
            ),
        }
    end,
})

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Practiced Hand",
    category = ChainRequirements.category("Combat", "Armorer", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A hammer, a strap, a loose rivet: each has a voice, and your hands have learned to listen.",
    localizedDescription = "Once per new day, if none of your perk-granted repair tools remain, "
        .. "you prepare a free Repair Tongs.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Salvage Sense",
    category = ChainRequirements.category("Combat", "Armorer", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Even a failed repair leaves evidence behind. A bent plate, a stubborn seam, a lesson worth taking.",
    localizedDescription = "The next daily tool you prepare improves to a Journeyman Repair Hammer. "
        .. "Failed repairs still restore a small amount of condition to the item you attempted to repair.",
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
    localizedDescription = "The next daily tool you prepare improves to a Master's Repair Hammer. "
        .. "Failed repairs no longer consume durability from your repair tool.",
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
    localizedDescription = "The next daily tool you prepare improves to the Secret Master's Repair Hammer. "
        .. "Successful repairs have a chance to restore the durability spent by your repair tool once the repair is resolved. "
        .. "This chance scales with the tool's own quality.",
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
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
