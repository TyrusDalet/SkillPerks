--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

local core       = require("openmw.core")
local types      = require("openmw.types")
local ui         = require("openmw.ui")
local self       = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")

local SKILL_ID = "mercantile"
local ids = Common.ids(SKILL_ID)

local wealthTracker = StatTracker.newStatModTracker(self, "Mercantile Wealth")
local inBarter = false
local currentMerchant = nil
local appliedMercantile = 0
local appliedWorkingCapital = 0
local sessionGoldBeforeTemporary = nil
local lastPlayerGold = nil
local investments = {}
local updateTimer = 0
local wealthTimer = 0
local wealthRequestDelay = 0
local wealthRequestPending = false
local lastDay = nil
local lastMerchantModifiers = nil
local lastInvestmentDecision = nil
local lastBarterResult = nil
local lastWealthResult = nil
local wealth = {
    carried = 0,
    deposits = 0,
    stocks = 0,
    debt = 0,
    net = 0,
    mercantile = 0,
    luck = 0,
    reason = "not calculated",
}

local A_DEBUFF = { [1] = -5, [2] = -10, [3] = -15, [4] = -20 }
local B_GOLD_FACTOR = { [1] = 10, [2] = 25 }
local C_INVESTMENT_RATE = { [1] = 0.01, [2] = 0.025 }
local UPDATE_INTERVAL = 0.2
local WEALTH_INTERVAL = 20
local DAY_SECONDS = 86400

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local TRADE_SERVICES = {
    Barter = true, Weapon = true, Armor = true, Clothing = true,
    Books = true, Ingredients = true, Picks = true, Probes = true,
    Lights = true, Apparatus = true, RepairItems = true, Misc = true,
    Potions = true, MagicItems = true,
}

local function isMerchant(npc)
    if not npc or not npc:isValid() or not types.NPC.objectIsInstance(npc) then
        return false
    end
    local services = types.NPC.record(npc).servicesOffered
    for service in pairs(TRADE_SERVICES) do
        if services and services[service] then
            return true
        end
    end
    return false
end

local function merchantKey(npc)
    return npc and tostring(npc.id) or nil
end

local function modifyMerchantSkill(amount)
    if currentMerchant and currentMerchant:isValid() and amount ~= 0 then
        core.sendGlobalEvent("SPerks_ModifyNpcSkill", {
            npc = currentMerchant,
            skill = SKILL_ID,
            amount = amount,
        })
    end
end

local function modifyMerchantGold(amount)
    if currentMerchant and currentMerchant:isValid() and amount ~= 0 then
        core.sendGlobalEvent("SPerks_ModifyNpcBarterGold", {
            npc = currentMerchant,
            amount = amount,
        })
    end
end

-- Replaces the conversation-owned skill penalty by delta. This leaves every
-- other mod's Mercantile changes intact and makes repeated perk syncs safe.
local function refreshMerchantPenalty()
    if not currentMerchant or not currentMerchant:isValid() then
        return
    end
    local wanted = A_DEBUFF[aRank()] or 0
    if wanted ~= appliedMercantile then
        local before = appliedMercantile
        local delta = wanted - before
        modifyMerchantSkill(delta)
        appliedMercantile = wanted
        lastMerchantModifiers = lastMerchantModifiers or {}
        lastMerchantModifiers.merchant = SkillDebug.objectId(currentMerchant)
        lastMerchantModifiers.penaltyBefore = before
        lastMerchantModifiers.penaltyWanted = wanted
        lastMerchantModifiers.penaltyDelta = delta
        SkillDebug.traceEvent(SKILL_ID, "merchant penalty reconciled", {
            merchant = lastMerchantModifiers.merchant,
            rank = aRank(),
            before = before,
            wanted = wanted,
            delta = delta,
        })
    end
end

-- Working Capital uses base Mercantile plus only the D-chain wealth bonus.
-- Reading the tracked source directly prevents spells, enchantments, and
-- unrelated skill modifiers from inflating a merchant's temporary reserves.
local function refreshWorkingCapital()
    if not currentMerchant or not currentMerchant:isValid() then
        return
    end
    local factor = B_GOLD_FACTOR[bRank()] or 0
    local mercantile = types.NPC.stats.skills.mercantile(self)
    local baseMercantile = tonumber(mercantile.base) or 0
    local wealthMercantile = tonumber(wealth.mercantile) or 0
    local playerMercantile = baseMercantile + wealthMercantile
    local wanted = math.max(0, math.floor(playerMercantile * factor))
    if wanted ~= appliedWorkingCapital then
        local before = appliedWorkingCapital
        local delta = wanted - before
        modifyMerchantGold(delta)
        appliedWorkingCapital = wanted
        lastMerchantModifiers = lastMerchantModifiers or {}
        lastMerchantModifiers.merchant = SkillDebug.objectId(currentMerchant)
        lastMerchantModifiers.baseMercantile = baseMercantile
        lastMerchantModifiers.workingCapitalMercantile = playerMercantile
        lastMerchantModifiers.wealthMercantile = wealthMercantile
        lastMerchantModifiers.capitalFactor = factor
        lastMerchantModifiers.capitalBefore = before
        lastMerchantModifiers.capitalWanted = wanted
        lastMerchantModifiers.capitalDelta = delta
        SkillDebug.traceEvent(SKILL_ID, "working capital reconciled", {
            merchant = lastMerchantModifiers.merchant,
            rank = bRank(),
            baseMercantile = baseMercantile,
            workingCapitalMercantile = playerMercantile,
            wealthMercantile = wealthMercantile,
            factor = factor,
            before = before,
            wanted = wanted,
            delta = delta,
        })
    end
end

-- Investment bonuses normally persist in the actor's current barter gold.
-- OpenMW resets that value on load and normal merchant restocks can reset it
-- in play, so an exact return to a known pre-investment baseline means this
-- source's accumulated bonus must be restored. Unknown external changes are
-- deliberately left alone rather than risking a duplicate application.
local function investmentReapplyAmount(npc, currentGold)
    local entry = investments[merchantKey(npc)]
    if not entry or (entry.totalBonus or 0) <= 0 then
        lastInvestmentDecision = {
            merchant = SkillDebug.objectId(npc),
            result = "no stored investment",
            currentGold = currentGold,
            totalBonus = entry and entry.totalBonus or 0,
        }
        SkillDebug.traceEvent(SKILL_ID, "investment check", lastInvestmentDecision)
        return 0
    end
    if entry.lastKnownGold ~= nil and currentGold == entry.lastKnownGold then
        lastInvestmentDecision = {
            merchant = SkillDebug.objectId(npc),
            result = "already present",
            currentGold = currentGold,
            totalBonus = entry.totalBonus,
            lastKnownGold = entry.lastKnownGold,
            restockBaseline = entry.restockBaseline,
        }
        SkillDebug.traceEvent(SKILL_ID, "investment check", lastInvestmentDecision)
        return 0
    end
    local baseGold = types.NPC.record(npc).baseGold or 0
    if currentGold == entry.restockBaseline or currentGold == baseGold then
        entry.lastKnownGold = currentGold + entry.totalBonus
        lastInvestmentDecision = {
            merchant = SkillDebug.objectId(npc),
            result = "reapplied after reset",
            currentGold = currentGold,
            totalBonus = entry.totalBonus,
            lastKnownGold = entry.lastKnownGold,
            restockBaseline = entry.restockBaseline,
            recordBaseGold = baseGold,
        }
        SkillDebug.traceEvent(SKILL_ID, "investment reapplied", {
            merchant = SkillDebug.objectId(npc),
            amount = entry.totalBonus,
            currentGold = currentGold,
        })
        return entry.totalBonus
    end
    lastInvestmentDecision = {
        merchant = SkillDebug.objectId(npc),
        result = "external change retained",
        currentGold = currentGold,
        totalBonus = entry.totalBonus,
        lastKnownGold = entry.lastKnownGold,
        restockBaseline = entry.restockBaseline,
        recordBaseGold = baseGold,
    }
    SkillDebug.traceEvent(SKILL_ID, "investment retained conservatively", {
        merchant = SkillDebug.objectId(npc),
        currentGold = currentGold,
        lastKnown = entry.lastKnownGold,
        restockBaseline = entry.restockBaseline,
    })
    return 0
end

local function closeMerchant()
    local closing = currentMerchant and {
        merchant = SkillDebug.objectId(currentMerchant),
        penaltyRemoved = appliedMercantile,
        workingCapitalRemoved = appliedWorkingCapital,
        persistentInvestment = (investments[merchantKey(currentMerchant)] or {}).totalBonus or 0,
    } or nil
    if currentMerchant and currentMerchant:isValid() then
        local entry = investments[merchantKey(currentMerchant)]
        if entry then
            entry.lastKnownGold = types.Actor.getBarterGold(currentMerchant)
                - appliedWorkingCapital
        end
    end
    modifyMerchantSkill(-appliedMercantile)
    modifyMerchantGold(-appliedWorkingCapital)
    if closing then
        SkillDebug.traceEvent(SKILL_ID, "merchant session closed", closing)
    end
    currentMerchant = nil
    inBarter = false
    appliedMercantile = 0
    appliedWorkingCapital = 0
    sessionGoldBeforeTemporary = nil
    lastPlayerGold = nil
end

local function requestWealth(reason)
    if dRank() == 0 or wealthRequestPending then
        if dRank() == 0 then
            wealthTracker.clearAll()
        end
        return
    end
    wealthRequestPending = true
    wealth.reason = reason or "periodic"
    core.sendGlobalEvent("SPerks_RequestMercantileWealth", { player = self })
    SkillDebug.traceEvent(SKILL_ID, "wealth snapshot requested", {
        reason = wealth.reason,
    })
end

local function openMerchant(npc)
    if currentMerchant ~= npc then
        closeMerchant()
        if not isMerchant(npc) then
            return
        end
        currentMerchant = npc
        local currentGold = types.Actor.getBarterGold(npc)
        local reapply = investmentReapplyAmount(npc, currentGold)
        sessionGoldBeforeTemporary = currentGold + reapply
        if reapply > 0 then
            modifyMerchantGold(reapply)
        end
        lastPlayerGold = types.Actor.inventory(self):countOf("gold_001")
    end
    refreshMerchantPenalty()
    refreshWorkingCapital()
    requestWealth("barter opened")
end

local function onUiModeChanged(data)
    data = data or {}
    SkillDebug.traceEvent(SKILL_ID, "UI mode changed", {
        newMode = data.newMode,
        oldMode = data.oldMode,
        target = SkillDebug.objectId(data.arg),
    })
    if data.newMode == nil then
        closeMerchant()
        return
    end
    if data.arg and isMerchant(data.arg) then
        openMerchant(data.arg)
    end
    inBarter = data.newMode == "Barter"
end

-- The IE completion callback arrives after the accepted barter has moved its
-- gold. Comparing carried gold with the previous finalized balance gives the
-- exact net amount paid by the player without changing Inventory Extender.
local function onBarterFinalized()
    local playerGold = types.Actor.inventory(self):countOf("gold_001")
    local playerGoldBefore = lastPlayerGold or playerGold
    local netSpent = math.max(0, playerGoldBefore - playerGold)
    local rank = cRank()
    local invested = 0

    if rank > 0 and netSpent > 0 and currentMerchant and currentMerchant:isValid() then
        invested = math.floor(netSpent * C_INVESTMENT_RATE[rank])
        if invested > 0 then
            local key = merchantKey(currentMerchant)
            local entry = investments[key]
            if not entry then
                entry = {
                    npc = currentMerchant,
                    totalBonus = 0,
                    restockBaseline = sessionGoldBeforeTemporary
                        or types.NPC.record(currentMerchant).baseGold or 0,
                }
                investments[key] = entry
            end
            entry.npc = currentMerchant
            entry.totalBonus = (entry.totalBonus or 0) + invested
            modifyMerchantGold(invested)
            entry.lastKnownGold = types.Actor.getBarterGold(currentMerchant)
                + invested - appliedWorkingCapital
            ui.showMessage(string.format(
                "Your patronage adds %d gold to this merchant's permanent reserves.",
                invested))
        end
    end

    local entry = currentMerchant and investments[merchantKey(currentMerchant)] or nil
    lastBarterResult = {
        merchant = SkillDebug.objectId(currentMerchant),
        playerGoldBefore = playerGoldBefore,
        playerGoldAfter = playerGold,
        netSpent = netSpent,
        rank = rank,
        investmentRate = C_INVESTMENT_RATE[rank] or 0,
        invested = invested,
        cumulativeInvestment = entry and entry.totalBonus or 0,
        result = rank == 0 and "C chain inactive"
            or netSpent <= 0 and "no net player spend"
            or invested <= 0 and "investment rounded to zero"
            or "investment applied",
    }
    lastPlayerGold = playerGold
    SkillDebug.traceEvent(SKILL_ID, "barter finalized", lastBarterResult)
end

-- Converts the latest global banking/stock snapshot into stable AAM-reported
-- stat modifiers. Reapplying only when a tier changes keeps the 20-second
-- compatibility poll effectively free during ordinary play.
local function onWealthSnapshot(data)
    data = data or {}
    wealthRequestPending = false
    wealth.carried = types.Actor.inventory(self):countOf("gold_001")
    wealth.deposits = math.max(0, tonumber(data.deposits) or 0)
    wealth.stocks = math.max(0, tonumber(data.stocks) or 0)
    wealth.debt = math.max(0, tonumber(data.debt) or 0)
    wealth.net = math.max(0, wealth.carried + wealth.deposits + wealth.stocks - wealth.debt)

    local previousMercantile = wealth.mercantile or 0
    local previousLuck = wealth.luck or 0
    local rank = dRank()
    wealth.mercantile = rank > 0 and math.floor(wealth.net / 10000) or 0
    wealth.luck = rank >= 2 and math.floor(wealth.net / 25000) or 0
    wealthTracker.apply("skills", "mercantile", wealth.mercantile)
    wealthTracker.apply("attributes", "luck", wealth.luck)
    refreshWorkingCapital()
    lastWealthResult = {
        reason = wealth.reason,
        rank = rank,
        carried = wealth.carried,
        deposits = wealth.deposits,
        stocks = wealth.stocks,
        debt = wealth.debt,
        net = wealth.net,
        mercantileBefore = previousMercantile,
        mercantileAfter = wealth.mercantile,
        luckBefore = previousLuck,
        luckAfter = wealth.luck,
        nextMercantileAt = (wealth.mercantile + 1) * 10000,
        nextLuckAt = rank >= 2 and (wealth.luck + 1) * 25000 or nil,
    }
    SkillDebug.traceEvent(SKILL_ID, "wealth snapshot applied", lastWealthResult)
end

local function clearMercantile()
    closeMerchant()
    if dRank() == 0 then
        wealthTracker.clearAll()
    end
end

local function onPerkAdded()
    refreshMerchantPenalty()
    refreshWorkingCapital()
    wealthRequestDelay = 0.05
end

-- Merchant session state is sampled five times per second. Wealth is sampled
-- every 20 unpaused seconds and shortly after the day changes so Tamriel_Data
-- has time to finish its own daily stock recalculation first.
local function onUpdate(dt)
    updateTimer = updateTimer + dt
    wealthTimer = wealthTimer + dt
    if wealthRequestDelay > 0 then
        wealthRequestDelay = math.max(0, wealthRequestDelay - dt)
        if wealthRequestDelay == 0 then
            requestWealth("new day")
        end
    end

    local day = math.floor(core.getGameTime() / DAY_SECONDS)
    if lastDay == nil then
        lastDay = day
    elseif day ~= lastDay then
        lastDay = day
        wealthRequestDelay = 0.5
    end
    if wealthTimer >= WEALTH_INTERVAL then
        wealthTimer = wealthTimer % WEALTH_INTERVAL
        requestWealth("20 second poll")
    end
    if updateTimer < UPDATE_INTERVAL then
        return
    end
    updateTimer = updateTimer % UPDATE_INTERVAL
    refreshMerchantPenalty()
    refreshWorkingCapital()
end

local function onSave()
    return {
        wealthTracker = wealthTracker.snapshot(),
        currentMerchant = currentMerchant,
        appliedMercantile = appliedMercantile,
        appliedWorkingCapital = appliedWorkingCapital,
        investments = investments,
        wealth = wealth,
        lastDay = lastDay,
        lastMerchantModifiers = lastMerchantModifiers,
        lastInvestmentDecision = lastInvestmentDecision,
        lastBarterResult = lastBarterResult,
        lastWealthResult = lastWealthResult,
    }
end

local function onLoad(data)
    data = data or {}
    wealthTracker.restoreAndReverse(data.wealthTracker)
    currentMerchant = data.currentMerchant
    appliedMercantile = data.appliedMercantile or 0
    -- `appliedGold` and `appliedDisposition` belonged to the previous
    -- Mercantile design. Reverse them once so an upgraded save cannot retain
    -- House Advantage or Pleasant Robbery after those perks no longer exist.
    appliedWorkingCapital = data.appliedWorkingCapital or data.appliedGold or 0
    if currentMerchant and currentMerchant:isValid()
            and (tonumber(data.appliedDisposition) or 0) ~= 0 then
        core.sendGlobalEvent("SPerks_ModifyNpcDisposition", {
            npc = currentMerchant,
            player = self,
            amount = -(tonumber(data.appliedDisposition) or 0),
        })
    end
    investments = data.investments or {}
    wealth = data.wealth or wealth
    lastDay = data.lastDay
    lastMerchantModifiers = data.lastMerchantModifiers
    lastInvestmentDecision = data.lastInvestmentDecision
    lastBarterResult = data.lastBarterResult
    lastWealthResult = data.lastWealthResult
    closeMerchant()
    wealthRequestPending = false
    wealthRequestDelay = 0.1
end

-- Reports temporary merchant modifiers, cumulative investment, and every
-- component of the wealth calculation used by Liquid Assets/Golden Measure.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Mercantile",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luamercantile debug", "luamerc debug" },
    snapshot = function()
        local entry = currentMerchant and investments[merchantKey(currentMerchant)] or nil
        return {
            string.format(
                "Barter: active=%s merchant=%s merchantPenalty=%s workingCapital=%s",
                tostring(inBarter),
                SkillDebug.objectId(currentMerchant),
                SkillDebug.number(appliedMercantile),
                SkillDebug.number(appliedWorkingCapital)
            ),
            string.format(
                "Investment: merchants=%d currentTotal=%s currentBaseline=%s",
                SkillDebug.count(investments),
                SkillDebug.number(entry and entry.totalBonus or 0),
                SkillDebug.value(entry and entry.restockBaseline)
            ),
            string.format(
                "Wealth: carried=%s deposits=%s stocks=%s debt=%s net=%s reason=%s pending=%s",
                SkillDebug.number(wealth.carried),
                SkillDebug.number(wealth.deposits),
                SkillDebug.number(wealth.stocks),
                SkillDebug.number(wealth.debt),
                SkillDebug.number(wealth.net),
                tostring(wealth.reason),
                tostring(wealthRequestPending)
            ),
            string.format(
                "Wealth bonuses: Mercantile=%s Luck=%s",
                SkillDebug.number(wealth.mercantile),
                SkillDebug.number(wealth.luck)
            ),
            lastMerchantModifiers and string.format(
                "Last merchant modifiers: merchant=%s penalty=%s->%s delta=%s Merc(base/wealth/eligible)=%s/%s/%s factor=%s capital=%s->%s delta=%s",
                tostring(lastMerchantModifiers.merchant),
                SkillDebug.value(lastMerchantModifiers.penaltyBefore),
                SkillDebug.value(lastMerchantModifiers.penaltyWanted),
                SkillDebug.value(lastMerchantModifiers.penaltyDelta),
                SkillDebug.value(lastMerchantModifiers.baseMercantile),
                SkillDebug.value(lastMerchantModifiers.wealthMercantile),
                SkillDebug.value(lastMerchantModifiers.workingCapitalMercantile),
                SkillDebug.value(lastMerchantModifiers.capitalFactor),
                SkillDebug.value(lastMerchantModifiers.capitalBefore),
                SkillDebug.value(lastMerchantModifiers.capitalWanted),
                SkillDebug.value(lastMerchantModifiers.capitalDelta))
                or "Last merchant modifiers: none",
            lastBarterResult and string.format(
                "Last barter: merchant=%s gold=%s->%s spent=%s rate=%s invested=%s cumulative=%s result=%s",
                tostring(lastBarterResult.merchant),
                SkillDebug.number(lastBarterResult.playerGoldBefore),
                SkillDebug.number(lastBarterResult.playerGoldAfter),
                SkillDebug.number(lastBarterResult.netSpent),
                SkillDebug.number(lastBarterResult.investmentRate),
                SkillDebug.number(lastBarterResult.invested),
                SkillDebug.number(lastBarterResult.cumulativeInvestment),
                tostring(lastBarterResult.result)) or "Last barter: none",
            lastInvestmentDecision and string.format(
                "Last investment check: merchant=%s result=%s current=%s total=%s lastKnown=%s restockBase=%s recordBase=%s",
                tostring(lastInvestmentDecision.merchant),
                tostring(lastInvestmentDecision.result),
                SkillDebug.value(lastInvestmentDecision.currentGold),
                SkillDebug.value(lastInvestmentDecision.totalBonus),
                SkillDebug.value(lastInvestmentDecision.lastKnownGold),
                SkillDebug.value(lastInvestmentDecision.restockBaseline),
                SkillDebug.value(lastInvestmentDecision.recordBaseGold))
                or "Last investment check: none",
            lastWealthResult and string.format(
                "Last wealth tiers: rank=%s net=%s Merc=%s->%s next=%s Luck=%s->%s next=%s reason=%s",
                SkillDebug.number(lastWealthResult.rank),
                SkillDebug.number(lastWealthResult.net),
                SkillDebug.number(lastWealthResult.mercantileBefore),
                SkillDebug.number(lastWealthResult.mercantileAfter),
                SkillDebug.number(lastWealthResult.nextMercantileAt),
                SkillDebug.number(lastWealthResult.luckBefore),
                SkillDebug.number(lastWealthResult.luckAfter),
                SkillDebug.value(lastWealthResult.nextLuckAt),
                tostring(lastWealthResult.reason)) or "Last wealth tiers: none",
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Mercantile", ids, {
    A1 = { localizedName = "Sharp Eye", localizedFlavour = "You see the scratch under the polish, the old repair beneath the shine, and the seller's hope between them.", localizedDescription = "Merchants you speak with suffer -5 Mercantile for the conversation.", onAdd = onPerkAdded, onRemove = clearMercantile },
    A2 = { localizedName = "Weighted Coin", localizedFlavour = "Every price has a weak point. You press until it moves.", localizedDescription = "Sharp Eye's merchant penalty increases to -10 Mercantile.", onAdd = onPerkAdded, onRemove = clearMercantile },
    A3 = { localizedName = "Ledger Instinct", localizedFlavour = "Value stops being a number and becomes a smell in the air.", localizedDescription = "Sharp Eye's merchant penalty increases to -15 Mercantile.", onAdd = onPerkAdded, onRemove = clearMercantile },
    A4 = { localizedName = "Merchant's Knife", localizedFlavour = "You cut profit so cleanly the other side calls it agreement.", localizedDescription = "Sharp Eye's merchant penalty increases to -20 Mercantile.", onAdd = onPerkAdded, onRemove = clearMercantile },
    B1 = { localizedName = "Working Capital", localizedFlavour = "Your reputation reaches the counter before you do, and cautious hands open deeper drawers.", localizedDescription = "Merchants gain temporary barter gold equal to 10 times your base Mercantile plus Liquid Assets' bonus for the conversation.", onAdd = onPerkAdded, onRemove = clearMercantile },
    B2 = { localizedName = "Deep Reserves", localizedFlavour = "Merchants do not merely make room for your business. They prepare for its arrival.", localizedDescription = "Working Capital increases to 25 times your base Mercantile plus Liquid Assets' bonus.", onAdd = onPerkAdded, onRemove = clearMercantile },
    C1 = { localizedName = "Patronage", localizedFlavour = "Coin spent well does not vanish. It takes root behind another merchant's counter.", localizedDescription = "1% of the net gold you spend in a completed barter permanently increases that merchant's barter gold.", onAdd = onPerkAdded, onRemove = clearMercantile },
    C2 = { localizedName = "Commercial Roots", localizedFlavour = "Your trade leaves roads, warehouses, and fuller strongboxes wherever it passes.", localizedDescription = "Patronage invests 2.5% of the net gold you spend.", onAdd = onPerkAdded, onRemove = clearMercantile },
    D1 = { localizedName = "Liquid Assets", localizedFlavour = "Wealth is not what sits in your purse. It is the confidence with which every door expects you to enter.", localizedDescription = "Gain +1 Mercantile for every 10,000 gold of net wealth.", onAdd = onPerkAdded, onRemove = clearMercantile },
    D2 = { localizedName = "Golden Measure", localizedFlavour = "At a certain scale, fortune stops following luck. It begins manufacturing it.", localizedDescription = "Liquid Assets also grants +1 Luck for every 25,000 gold of net wealth. Tamriel_Data bank deposits and stocks count; outstanding loans reduce the total.", onAdd = onPerkAdded, onRemove = clearMercantile },
})

return {
    eventHandlers = {
        IE_BarterFinalized = onBarterFinalized,
        SPerks_MercantileWealthSnapshot = onWealthSnapshot,
        SPerks_UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
