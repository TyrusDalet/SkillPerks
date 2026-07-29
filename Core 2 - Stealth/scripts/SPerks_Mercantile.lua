--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

local core       = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local Common = require("scripts.SkillPerks.stealth.common")
local SkillDebug = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "mercantile"
local ids = Common.ids("mercantile")

local inBarter = false
local currentMerchant = nil
local appliedMercantile = 0
local appliedDisposition = 0
local appliedGold = 0
local successfulHaggle = false
local bribePending = false
local lastGold = nil
local lastDisposition = nil
local lastAdjustedOffer = nil
local updateTimer = 0

local A_DEBUFF = { [1] = -5, [2] = -10, [3] = -15, [4] = -20 }
local B_DEBUFF = { [1] = -5, [2] = -10 }
local C_RATE = { [1] = 0.05, [2] = 0.10 }
local UPDATE_INTERVAL = 0.2

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

local function modifyMerchantSkill(amount)
    if currentMerchant and currentMerchant:isValid() and amount ~= 0 then
        core.sendGlobalEvent("SPerks_ModifyNpcSkill", {
            npc = currentMerchant,
            skill = SKILL_ID,
            amount = amount,
        })
    end
end

local function modifyDisposition(amount)
    if currentMerchant and currentMerchant:isValid() and amount ~= 0 then
        core.sendGlobalEvent("SPerks_ModifyNpcDisposition", {
            npc = currentMerchant,
            player = self,
            amount = amount,
        })
    end
end

local function modifyGold(amount)
    if currentMerchant and currentMerchant:isValid() and amount ~= 0 then
        core.sendGlobalEvent("SPerks_ModifyNpcBarterGold", {
            npc = currentMerchant,
            amount = amount,
        })
    end
end

-- Replaces temporary merchant-side modifiers by delta so rank changes and
-- successful-haggle upgrades never stack duplicate penalties.
local function refreshMerchantModifiers()
    if not currentMerchant or not currentMerchant:isValid() then
        return
    end
    local wanted = A_DEBUFF[aRank()] or 0
    if successfulHaggle then
        wanted = wanted + (B_DEBUFF[bRank()] or 0)
    end
    if wanted ~= appliedMercantile then
        modifyMerchantSkill(wanted - appliedMercantile)
        appliedMercantile = wanted
    end
end

local function closeMerchant()
    modifyMerchantSkill(-appliedMercantile)
    modifyDisposition(-appliedDisposition)
    modifyGold(-appliedGold)
    currentMerchant = nil
    inBarter = false
    appliedMercantile = 0
    appliedDisposition = 0
    appliedGold = 0
    successfulHaggle = false
    bribePending = false
    lastGold = nil
    lastDisposition = nil
    lastAdjustedOffer = nil
end

local function openMerchant(npc)
    if currentMerchant ~= npc then
        closeMerchant()
        if not isMerchant(npc) then
            return
        end
        currentMerchant = npc
        successfulHaggle = false
        local disposition = types.NPC.getDisposition(npc, self)
        bribePending = dRank() > 0 and disposition < 50
        lastDisposition = disposition
        lastGold = types.Actor.inventory(self):countOf("gold_001")

        if dRank() >= 2 then
            local playerMerc = types.Actor.stats.skills.mercantile(self).modified
            local npcMerc = types.NPC.stats.skills.mercantile(npc).modified
            appliedGold = math.max(0, math.floor((playerMerc - npcMerc) * 5))
            modifyGold(appliedGold)
        end
    end
    refreshMerchantModifiers()
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
    if not inBarter then
        lastAdjustedOffer = nil
    end
end

-- Inventory Extender exposes its live barter state through its public
-- context. Adjusting both offer and balance by the same delta preserves its
-- accounting while giving Market Knowledge exact symmetric buy/sell rates.
local function updateMarketKnowledge()
    local rank = cRank()
    if not inBarter or rank == 0 or not interfaces.InventoryExtender then
        return
    end
    local ctx = interfaces.InventoryExtender.getContext()
    local state = ctx and ctx.barterState
    if not state then
        return
    end
    local raw = state.currentMerchantOffer or 0
    if raw == lastAdjustedOffer then
        return
    end
    local rate = C_RATE[rank]
    local adjusted = raw >= 0 and math.floor(raw * (1 + rate) + 0.5)
        or math.ceil(raw * (1 - rate) - 0.5)
    local delta = adjusted - raw
    state.currentMerchantOffer = adjusted
    state.currentBalance = (state.currentBalance or 0) + delta
    lastAdjustedOffer = adjusted
end

-- Gold loss plus a simultaneous disposition increase is the observable
-- signature of a successful bribe. D1/D2 amplify that one increase without
-- affecting Admire, Taunt, or scripted dialogue disposition changes.
local function updateBribeLeverage()
    if not currentMerchant or not currentMerchant:isValid() then
        return
    end
    local gold = types.Actor.inventory(self):countOf("gold_001")
    local disposition = types.NPC.getDisposition(currentMerchant, self)
    if bribePending and lastGold and lastDisposition and gold < lastGold and disposition > lastDisposition then
        local multiplier = dRank() >= 2 and 3 or 2
        local bonus = (disposition - lastDisposition) * (multiplier - 1)
        modifyDisposition(bonus)
        disposition = disposition + bonus
        bribePending = false
    end
    lastGold = gold
    lastDisposition = disposition
end

local function onBarterFinalized()
    local rank = bRank()
    SkillDebug.traceEvent(SKILL_ID, "barter finalized", {
        merchant = SkillDebug.objectId(currentMerchant),
        rank = rank,
    })
    if rank == 0 or not currentMerchant or not currentMerchant:isValid() then
        return
    end
    successfulHaggle = true
    refreshMerchantModifiers()
    if rank >= 2 then
        modifyDisposition(3)
        appliedDisposition = appliedDisposition + 3
    end
end

local function clearMercantile()
    closeMerchant()
end

-- Polls the active merchant session often enough to follow UI changes without
-- querying inventory, disposition, and Inventory Extender every rendered frame.
local function onUpdate(dt)
    updateTimer = updateTimer + dt
    if updateTimer < UPDATE_INTERVAL then
        return
    end
    updateTimer = updateTimer % UPDATE_INTERVAL

    refreshMerchantModifiers()
    updateMarketKnowledge()
    updateBribeLeverage()
end

local function onSave()
    return {
        currentMerchant = currentMerchant,
        appliedMercantile = appliedMercantile,
        appliedDisposition = appliedDisposition,
        appliedGold = appliedGold,
    }
end

local function onLoad(data)
    data = data or {}
    currentMerchant = data.currentMerchant
    appliedMercantile = data.appliedMercantile or 0
    appliedDisposition = data.appliedDisposition or 0
    appliedGold = data.appliedGold or 0
    closeMerchant()
end

-- Reports the active merchant session and every temporary adjustment it owns.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Mercantile",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luamercantile debug", "luamerc debug" },
    snapshot = function()
        return {
            string.format(
                "Barter: active=%s merchant=%s haggleSucceeded=%s bribePending=%s",
                tostring(inBarter),
                SkillDebug.objectId(currentMerchant),
                tostring(successfulHaggle),
                tostring(bribePending)
            ),
            string.format(
                "Applied: mercantile=%s disposition=%s gold=%s lastOffer=%s",
                SkillDebug.number(appliedMercantile),
                SkillDebug.number(appliedDisposition),
                SkillDebug.number(appliedGold),
                SkillDebug.value(lastAdjustedOffer)
            ),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Mercantile", ids, {
    A1 = { localizedName = "Sharp Eye", localizedFlavour = "You see the scratch under the polish, the old repair beneath the shine, and the seller's hope between them.", localizedDescription = "Merchants you speak with suffer -5 Mercantile for the conversation.", onRemove = clearMercantile },
    A2 = { localizedName = "Weighted Coin", localizedFlavour = "Every price has a weak point. You press until it moves.", localizedDescription = "Sharp Eye's merchant penalty increases to -10 Mercantile.", onRemove = clearMercantile },
    A3 = { localizedName = "Ledger Instinct", localizedFlavour = "Value stops being a number and becomes a smell in the air.", localizedDescription = "Sharp Eye's merchant penalty increases to -15 Mercantile.", onRemove = clearMercantile },
    A4 = { localizedName = "Merchant's Knife", localizedFlavour = "You cut profit so cleanly the other side calls it agreement.", localizedDescription = "Sharp Eye's merchant penalty increases to -20 Mercantile.", onRemove = clearMercantile },
    B1 = { localizedName = "Silver Tongue", localizedFlavour = "A successful bargain leaves the merchant nodding before they notice what they gave away.", localizedDescription = "After an accepted haggle, the merchant suffers a further -5 Mercantile for the rest of the conversation.", onRemove = clearMercantile },
    B2 = { localizedName = "Pleasant Robbery", localizedFlavour = "They like you more after losing money. That is the real craft.", localizedDescription = "Silver Tongue's penalty increases to -10 Mercantile. Each accepted haggle also grants +3 disposition until the conversation ends.", onRemove = clearMercantile },
    C1 = { localizedName = "Market Knowledge", localizedFlavour = "You know what sells, what sits, and what desperation sounds like over a counter.", localizedDescription = "Inventory Extender barter prices improve by 5% when buying or selling.", onRemove = clearMercantile },
    C2 = { localizedName = "Price Memory", localizedFlavour = "Every shop in Vvardenfell becomes one long conversation you have already won.", localizedDescription = "Market Knowledge improves barter prices by 10%.", onRemove = clearMercantile },
    D1 = { localizedName = "Read the Room", localizedFlavour = "Before the first offer, you already know whether pride or need is holding the purse.", localizedDescription = "If a merchant's disposition is below 50 when conversation begins, the next successful bribe has double effect.", onRemove = clearMercantile },
    D2 = { localizedName = "House Advantage", localizedFlavour = "You do not enter a market. You arrange one around yourself.", localizedDescription = "Read the Room triples the next bribe instead. Merchants also gain barter gold equal to five times your Mercantile advantage for the conversation.", onRemove = clearMercantile },
})

return {
    eventHandlers = {
        IE_BarterFinalized = onBarterFinalized,
        SPerks_UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
