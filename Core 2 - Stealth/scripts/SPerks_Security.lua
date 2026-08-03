--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

-- Inventory Extender identifies the exact tool selected by the player, while
-- Core 0's activation bridge identifies the lock or trap it was used on. The
-- next condition change can therefore be classified as a success or failure
-- instead of treating every spent tool use as the same event.

local core       = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local ui         = require("openmw.ui")

local Common      = require("scripts.SkillPerks.stealth.common")
local CombatMath  = require("scripts.SkillPerks.shared.combat_math")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "security"
local ids = Common.ids("security")

local patternStats = StatTracker.newStatModTracker(self, "Security Pattern Recognition")
local patternEffects = StatTracker.newActiveEffectTracker(self)
local trackedTool = nil
local targetedLock = nil
local patternStacks = 0
local patternLockId = nil
local masterLocksmithUses = 0
local registeredIE = false
local reportedMasteryRank = -1
local reportedMasteryUses = -1

local A_REDUCTION = { [1] = 0.20, [2] = 0.40, [3] = 0.60, [4] = 0.80 }
local B_CAP = { [1] = 3, [2] = 6 }
local C_PRESERVE = { [1] = 0.25, [2] = 0.50 }

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function rememberTool(item)
    if not item or not item:isValid() then
        return
    end
    if not types.Lockpick.objectIsInstance(item) and not types.Probe.objectIsInstance(item) then
        return
    end
    local itemData = types.Item.itemData(item)
    trackedTool = itemData and itemData.condition and {
        item = item,
        condition = itemData.condition,
        isLockpick = types.Lockpick.objectIsInstance(item),
        isProbe = types.Probe.objectIsInstance(item),
    } or nil
end

local function registerInventoryExtender()
    if registeredIE or not interfaces.InventoryExtender then
        return
    end
    registeredIE = true
    interfaces.InventoryExtender.registerRowUseHandler("SkillPerks_SecurityToolUse", function(row)
        SkillDebug.traceEvent(SKILL_ID, "security tool used", {
            item = row and SkillDebug.objectId(row.item),
        })
        if row and row.item then
            rememberTool(row.item)
        end
        return true
    end)
end

local function updatePatternBonus()
    local value = patternStacks * 5
    patternStats.apply("skills", SKILL_ID, value)
    patternEffects.apply("fortifyskill", SKILL_ID, value)
end

local function clearPattern()
    patternStacks = 0
    patternLockId = nil
    updatePatternBonus()
end

local function addPatternStack(lockId)
    local rank = bRank()
    if rank == 0 then
        return
    end
    if patternLockId ~= lockId then
        patternStacks = 0
        patternLockId = lockId
    end
    patternStacks = math.min(B_CAP[rank], patternStacks + 1)
    updatePatternBonus()
end

local function currentTargetResult(tool)
    local target = targetedLock and targetedLock.target
    if not target or not target:isValid() or not types.Lockable.objectIsInstance(target) then
        return nil, nil
    end
    if tool.isLockpick and targetedLock.wasLocked then
        return not types.Lockable.isLocked(target), tostring(target.id)
    end
    if tool.isProbe and targetedLock.hadTrap then
        return types.Lockable.getTrapSpell(target) == nil, tostring(target.id)
    end
    return nil, tostring(target.id)
end

-- Restores only the wear covered by the relevant success/failure rule. The
-- write is global because carried item condition cannot be changed directly
-- by a player script.
local function reconcileToolCondition()
    if not trackedTool or not trackedTool.item or not trackedTool.item:isValid() then
        trackedTool = nil
        return
    end
    local itemData = types.Item.itemData(trackedTool.item)
    if not itemData or not itemData.condition then
        trackedTool = nil
        return
    end
    local loss = trackedTool.condition - itemData.condition
    if loss <= 0 then
        trackedTool.condition = itemData.condition
        return
    end

    local restore = 0
    local succeeded, lockId = currentTargetResult(trackedTool)
    SkillDebug.traceEvent(SKILL_ID, "tool result observed", {
        lock = lockId,
        loss = loss,
        succeeded = succeeded,
    })
    if trackedTool.isLockpick then
        if succeeded == false then
            restore = restore + loss * (A_REDUCTION[aRank()] or 0)
            addPatternStack(lockId)
        elseif succeeded == true then
            clearPattern()
        end
    elseif trackedTool.isProbe then
        local rank = cRank()
        if rank > 0 then
            if succeeded == false then
                restore = restore + loss * 0.50
            elseif succeeded == true and math.random() < C_PRESERVE[rank] then
                restore = restore + loss
            end
        end
    end

    if restore > 0 then
        core.sendGlobalEvent("SPerks_ModifyItemCondition", {
            item = trackedTool.item,
            amount = restore,
        })
    end
    trackedTool.condition = itemData.condition + restore
    targetedLock = nil
end


-- Keeps Core 0's synchronous activation handler aligned with current perk
-- ownership and remaining rest-limited attempts without global polling.
local function reportMasteryState()
    local rank = dRank()
    if rank == reportedMasteryRank and masterLocksmithUses == reportedMasteryUses then
        return
    end
    reportedMasteryRank = rank
    reportedMasteryUses = masterLocksmithUses
    core.sendGlobalEvent("SPerks_SetSecurityMasteryRank", {
        player = self,
        rank = rank,
        uses = masterLocksmithUses,
    })
end


-- Resolves Master Locksmith as a quality-1 version of the normal Security
-- roll: skill, Agility, Luck, and fatigue oppose the target's lock level.
local function attemptMasterLocksmith(data)
    local rank = dRank()
    if rank == 0 or not data or not data.target or not data.target:isValid() then
        return
    end
    local cap = rank >= 2 and 2 or 1
    if masterLocksmithUses >= cap then
        ui.showMessage("Master Locksmith has already been used " .. (cap == 1 and "this rest." or "twice this rest."))
        return
    end

    masterLocksmithUses = masterLocksmithUses + 1
    reportMasteryState()
    local security = types.NPC.stats.skills.security(self).modified
    local agility = types.Actor.stats.attributes.agility(self).modified
    local luck = types.Actor.stats.attributes.luck(self).modified
    local chance = math.max(0, math.min(100,
        (security + agility / 5 + luck / 10) * CombatMath.getFatigueTerm(self)
            - math.max(0, data.lockLevel or 0)))
    local success = math.random() * 100 < chance
    SkillDebug.traceEvent(SKILL_ID, "Master Locksmith attempt", {
        chance = chance,
        rank = rank,
        success = success,
        target = SkillDebug.objectId(data.target),
    })

    core.sendGlobalEvent("SPerks_ResolveSecurityMasterLocksmithAttempt", {
        player = self,
        target = data.target,
        success = success,
        weakenFraction = not success and rank >= 2 and 0.25 or 0,
    })
    if success then
        ui.showMessage("The lock yields to your practiced touch.")
    elseif rank >= 2 then
        ui.showMessage("The lock does not yield, but you are more aware of its weaknesses.")
    else
        ui.showMessage("The lock remains fast.")
    end
end

local function rememberTarget(data)
    SkillDebug.traceEvent(SKILL_ID, "lock target observed", {
        target = data and SkillDebug.objectId(data.target),
    })
    if not data or not data.target or not data.target:isValid() then
        return
    end
    local nextId = tostring(data.target.id)
    if patternLockId and patternLockId ~= nextId then
        clearPattern()
    end
    targetedLock = data
end

local function onUiModeChanged(data)
    if data and data.oldMode == "Rest" then
        masterLocksmithUses = 0
        reportMasteryState()
    end
end

local function clearSecurity()
    patternStats.clearAll()
    patternEffects.clearAll()
    trackedTool = nil
    targetedLock = nil
    patternStacks = 0
    patternLockId = nil
    masterLocksmithUses = 0
    reportedMasteryRank = -1
    reportedMasteryUses = -1
    reportMasteryState()
end

local function onUpdate(dt)
    registerInventoryExtender()
    local held = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if held and (types.Lockpick.objectIsInstance(held) or types.Probe.objectIsInstance(held))
            and (not trackedTool or trackedTool.item ~= held) then
        rememberTool(held)
    end
    reconcileToolCondition()
    reportMasteryState()
end

local function onSave()
    return {
        patternStats = patternStats.snapshot(),
        patternEffects = patternEffects.snapshot(),
        patternStacks = patternStacks,
        patternLockId = patternLockId,
        masterLocksmithUses = masterLocksmithUses,
    }
end

local function onLoad(data)
    data = data or {}
    patternStats.restoreAndReverse(data.patternStats)
    patternEffects.restoreAndReverse(data.patternEffects)
    -- A reload leaves the active lock interaction, so per-lock learning does
    -- not carry into an unrelated attempt after loading.
    patternStacks = 0
    patternLockId = nil
    masterLocksmithUses = data.masterLocksmithUses or data.bareHandUses or 0
    trackedTool = nil
    targetedLock = nil
    registeredIE = false
    reportedMasteryRank = -1
    reportedMasteryUses = -1
    updatePatternBonus()
end

-- Exposes the exact tool, lock, pattern, and rest-limited mastery state.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Security",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luasecurity debug", "luasec debug" },
    snapshot = function()
        return {
            string.format(
                "Targeting: tool=%s lock=%s patternLock=%s",
                SkillDebug.objectId(trackedTool),
                SkillDebug.objectId(targetedLock),
                tostring(patternLockId)
            ),
            string.format(
                "Pattern: stacks=%d MasterLocksmithUses=%d InventoryExtender=%s masteryRank=%d",
                patternStacks,
                masterLocksmithUses,
                tostring(registeredIE),
                reportedMasteryRank
            ),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Security", ids, {
    A1 = { localizedName = "Deft Hands", localizedFlavour = "A failed pick is not wasted if your fingers remember why it failed.", localizedDescription = "Lockpick condition loss on a failed attempt is reduced by 20%.", onRemove = clearSecurity },
    A2 = { localizedName = "Soft Pressure", localizedFlavour = "You stop forcing the lock and begin listening to it complain.", localizedDescription = "Deft Hands improves to 40% reduced condition loss on failure.", onRemove = clearSecurity },
    A3 = { localizedName = "Patient Tension", localizedFlavour = "Pins move because you asked correctly, not because you pushed harder.", localizedDescription = "Deft Hands improves to 60% reduced condition loss on failure.", onRemove = clearSecurity },
    A4 = { localizedName = "Lock Whisperer", localizedFlavour = "The mechanism gives up secrets before it gives up steel.", localizedDescription = "Deft Hands improves to 80% reduced condition loss on failure.", onRemove = clearSecurity },
    B1 = { localizedName = "Pattern Recognition", localizedFlavour = "Every failed turn maps another tooth of the lock in your mind.", localizedDescription = "Each failed attempt on the same lock grants +5 Security for later attempts, up to 3 stacks. Stacks end on success or when you change locks.", onRemove = clearSecurity },
    B2 = { localizedName = "Known Mechanism", localizedFlavour = "By the final attempt, the lock feels less like an obstacle than an old argument.", localizedDescription = "Pattern Recognition stack cap rises to 6.", onRemove = clearSecurity },
    C1 = { localizedName = "Trap Mastery", localizedFlavour = "A trap is only a threat until you learn where its patience ends.", localizedDescription = "Probe condition loss on a failed disarm is reduced by 50%. Successful disarms have a 25% chance to preserve the use.", onRemove = clearSecurity },
    C2 = { localizedName = "Wire-Seer", localizedFlavour = "You read pressure, spring, and poison as if the trap wrote them down for you.", localizedDescription = "Trap Mastery's successful-disarm preservation chance rises to 50%.", onRemove = clearSecurity },
    D1 = { localizedName = "Master Locksmith", localizedFlavour = "Tools help, but mastery begins when every lock answers to your touch.", localizedDescription = "Once per rest, activating a locked object attempts to open it using a normal Security roll with tool quality 1. Failure has no penalty.", onRemove = clearSecurity },
    D2 = { localizedName = "Hands Like Keys", localizedFlavour = "Some locks open because metal meets metal. Others open because you have learned their name.", localizedDescription = "Master Locksmith can be attempted twice per rest. A failed attempt permanently reduces the lock's level by 25%.", onRemove = clearSecurity },
})

return {
    eventHandlers = {
        SPerks_UiModeChanged = onUiModeChanged,
        SPerks_SecurityLockTarget = rememberTarget,
        SPerks_SecurityMasterLocksmithAttempt = attemptMasterLocksmith,
        -- Legacy alias for Core 0 builds from before the interaction rename.
        SPerks_SecurityBareHandAttempt = attemptMasterLocksmith,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
