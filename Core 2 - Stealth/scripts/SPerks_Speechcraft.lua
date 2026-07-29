--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

local core = require("openmw.core")
local types = require("openmw.types")
local self = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "speechcraft"
local ids = Common.ids("speechcraft")

local tracker = StatTracker.newStatModTracker(self, "Speechcraft Next Attempt")
local effects = StatTracker.newActiveEffectTracker(self)
local currentNpc = nil
local lastDisposition = nil
local nextAttemptBonus = 0
local consecutiveSuccesses = 0
local conversationHadSuccess = false
local conversationRewarded = false
local commandDay = nil
local commandUses = 0
local lingering = {}

local A_BONUS = { [1] = 5, [2] = 10, [3] = 15, [4] = 20 }
local DAY_SECONDS = 86400

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function currentDay()
    return math.floor(core.getGameTime() / DAY_SECONDS)
end

local function setNextAttemptBonus(value)
    nextAttemptBonus = math.max(0, value or 0)
    tracker.apply("skills", SKILL_ID, nextAttemptBonus)
    effects.apply("fortifyskill", SKILL_ID, nextAttemptBonus)
end

local function modifyDisposition(npc, amount)
    if not npc or not npc:isValid() or amount == 0 then
        return
    end
    core.sendGlobalEvent("SPerks_ModifyNpcDisposition", {
        npc = npc,
        player = self,
        amount = amount,
    })
    if npc == currentNpc and lastDisposition then
        lastDisposition = lastDisposition + amount
    end
end

local function expireLingeringBonuses()
    local now = core.getGameTime()
    for key, entry in pairs(lingering) do
        if entry.npc and entry.npc:isValid() and now >= entry.expires then
            modifyDisposition(entry.npc, -entry.amount)
            lingering[key] = nil
        end
    end
end

local function applyLingeringBonus(npc)
    local rank = cRank()
    if rank == 0 or not npc or not npc:isValid() then
        return
    end
    local key = tostring(npc.id)
    local previous = lingering[key]
    if previous and previous.npc and previous.npc:isValid() then
        modifyDisposition(previous.npc, -previous.amount)
    end
    local amount = rank >= 2 and 10 or 5
    local duration = rank >= 2 and 72 * 3600 or 24 * 3600
    modifyDisposition(npc, amount)
    lingering[key] = {
        npc = npc,
        amount = amount,
        expires = core.getGameTime() + duration,
    }
end

local function closeConversation()
    if currentNpc and conversationHadSuccess then
        applyLingeringBonus(currentNpc)
    end
    currentNpc = nil
    lastDisposition = nil
    consecutiveSuccesses = 0
    conversationHadSuccess = false
    conversationRewarded = false
    setNextAttemptBonus(0)
end

local function openConversation(npc)
    if not npc or not npc:isValid() or not types.NPC.objectIsInstance(npc) then
        return
    end
    if currentNpc ~= npc then
        closeConversation()
        currentNpc = npc
        lastDisposition = types.NPC.getDisposition(npc, self)
    end
end

local function onUiModeChanged(data)
    data = data or {}
    SkillDebug.traceEvent(SKILL_ID, "UI mode changed", {
        newMode = data.newMode,
        oldMode = data.oldMode,
        target = SkillDebug.objectId(data.arg),
    })
    if data.newMode == nil then
        closeConversation()
    elseif data.newMode == "Dialogue" and data.arg then
        openConversation(data.arg)
    end
end

local function resetDailyCommandUses()
    local day = currentDay()
    if commandDay ~= day then
        commandDay = day
        commandUses = 0
    end
end

local function canCommand(npc)
    local rank = dRank()
    if rank == 0 or not npc or not npc:isValid() then
        return false
    end
    resetDailyCommandUses()
    local cap = rank >= 2 and 2 or 1
    local fight = types.Actor.stats.ai.fight(npc)
    return commandUses < cap and (not fight or fight.modified < 70)
end

-- Persuasion itself has no Lua callback. Its disposition write is observable,
-- however, so each non-zero change is treated as one completed attempt. This
-- lets all post-roll outcomes work without replacing the game's dialogue UI.
local function processDispositionAttempt(delta)
    SkillDebug.traceEvent(SKILL_ID, "disposition change observed", {
        delta = delta,
        npc = SkillDebug.objectId(currentNpc),
    })
    local npc = currentNpc
    if not npc or delta == 0 then
        return
    end

    -- The previous one-use bonus has already participated in this roll.
    setNextAttemptBonus(0)

    local succeeded = delta > 0
    if canCommand(npc) then
        commandUses = commandUses + 1
        if delta < 0 then
            modifyDisposition(npc, -delta)
            local forcedGain = math.max(1, math.abs(delta))
            modifyDisposition(npc, forcedGain)
            delta = forcedGain
        elseif dRank() >= 2 then
            modifyDisposition(npc, delta)
            delta = delta * 2
        end
        succeeded = true
    elseif not succeeded and bRank() > 0 then
        -- Read the Crowd cancels the vanilla failure penalty.
        modifyDisposition(npc, -delta)
    end

    if succeeded then
        conversationHadSuccess = true
        consecutiveSuccesses = consecutiveSuccesses + 1
        setNextAttemptBonus(A_BONUS[aRank()] or 0)
        if aRank() >= 4 and consecutiveSuccesses >= 3 and not conversationRewarded then
            modifyDisposition(npc, 5)
            conversationRewarded = true
        end
    else
        consecutiveSuccesses = 0
        if bRank() >= 2 and types.NPC.getDisposition(npc, self) < 30 then
            setNextAttemptBonus(10)
        end
    end
end

local function onUpdate()
    expireLingeringBonuses()
    resetDailyCommandUses()
    if not currentNpc or not currentNpc:isValid() then
        return
    end
    local disposition = types.NPC.getDisposition(currentNpc, self)
    if lastDisposition == nil then
        lastDisposition = disposition
        return
    end
    local delta = disposition - lastDisposition
    if math.abs(delta) >= 0.5 then
        lastDisposition = disposition
        processDispositionAttempt(delta)
    else
        lastDisposition = disposition
    end
end

local function clearSpeechcraft()
    closeConversation()
    tracker.clearAll()
    effects.clearAll()
    for key, entry in pairs(lingering) do
        if entry.npc and entry.npc:isValid() then
            modifyDisposition(entry.npc, -entry.amount)
        end
        lingering[key] = nil
    end
end

local function onSave()
    return {
        tracker = tracker.snapshot(),
        effects = effects.snapshot(),
        currentNpc = currentNpc,
        lastDisposition = lastDisposition,
        nextAttemptBonus = nextAttemptBonus,
        consecutiveSuccesses = consecutiveSuccesses,
        conversationHadSuccess = conversationHadSuccess,
        conversationRewarded = conversationRewarded,
        commandDay = commandDay,
        commandUses = commandUses,
        lingering = lingering,
    }
end

local function onLoad(data)
    data = data or {}
    tracker.restoreAndReverse(data.tracker)
    effects.restoreAndReverse(data.effects)
    currentNpc = data.currentNpc
    lastDisposition = data.lastDisposition
    nextAttemptBonus = data.nextAttemptBonus or 0
    consecutiveSuccesses = data.consecutiveSuccesses or 0
    conversationHadSuccess = data.conversationHadSuccess or false
    conversationRewarded = data.conversationRewarded or false
    commandDay = data.commandDay
    commandUses = data.commandUses or 0
    lingering = data.lingering or {}
    setNextAttemptBonus(nextAttemptBonus)
end

-- Reports the current persuasion chain, daily command uses, and lingering NPCs.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Speechcraft",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luaspeechcraft debug", "luaspeech debug" },
    snapshot = function()
        return {
            string.format(
                "Conversation: npc=%s disposition=%s nextBonus=%s successes=%d rewarded=%s",
                SkillDebug.objectId(currentNpc),
                SkillDebug.value(lastDisposition),
                SkillDebug.number(nextAttemptBonus),
                consecutiveSuccesses,
                tostring(conversationRewarded)
            ),
            string.format(
                "Command: day=%s uses=%d lingeringNPCs=%d",
                SkillDebug.value(commandDay),
                commandUses,
                SkillDebug.count(lingering)
            ),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Speechcraft", ids, {
    A1 = { localizedName = "Compelling Voice", localizedFlavour = "You learn where a sentence should lean, and people begin leaning with it.", localizedDescription = "A successful persuasion attempt grants +5 Speechcraft to your next attempt with that NPC during the conversation.", onRemove = clearSpeechcraft },
    A2 = { localizedName = "Measured Praise", localizedFlavour = "Admiration becomes a tool, sharpened carefully enough to pass for kindness.", localizedDescription = "Compelling Voice's next-attempt bonus increases to +10 Speechcraft.", onRemove = clearSpeechcraft },
    A3 = { localizedName = "Threaded Intent", localizedFlavour = "Every remark ties to the next until the listener is standing exactly where you wanted.", localizedDescription = "Compelling Voice's bonus increases to +15 and carries across persuasion types.", onRemove = clearSpeechcraft },
    A4 = { localizedName = "Conversation's Crown", localizedFlavour = "You do not win arguments. You make agreement feel inevitable.", localizedDescription = "Compelling Voice's bonus increases to +20. Three consecutive successes also grant a persistent +5 disposition once per conversation.", onRemove = clearSpeechcraft },
    B1 = { localizedName = "Read the Crowd", localizedFlavour = "Failure has a shape. Once you see it coming, it stops leaving bruises.", localizedDescription = "Failed persuasion attempts do not reduce disposition.", onRemove = clearSpeechcraft },
    B2 = { localizedName = "Recovery Line", localizedFlavour = "When the room turns cold, you find the one sentence still warm enough to use.", localizedDescription = "Read the Crowd also grants +10 Speechcraft to the next attempt after failing against an NPC below 30 disposition.", onRemove = clearSpeechcraft },
    C1 = { localizedName = "Lingering Words", localizedFlavour = "Some compliments leave after the conversation. Yours wait by the door.", localizedDescription = "After a conversation containing a successful persuasion, that NPC retains +5 disposition for 24 in-game hours.", onRemove = clearSpeechcraft },
    C2 = { localizedName = "Remembered Grace", localizedFlavour = "People recall your words with more warmth than they heard them.", localizedDescription = "Lingering Words improves to +10 disposition for 72 in-game hours.", onRemove = clearSpeechcraft },
    D1 = { localizedName = "Commanding Presence", localizedFlavour = "For one moment, persuasion stops asking and starts happening.", localizedDescription = "Once per day, your next persuasion attempt against a non-hostile NPC is converted into a success.", onRemove = clearSpeechcraft },
    D2 = { localizedName = "Voice of Office", localizedFlavour = "You speak with enough certainty that refusal feels like bad manners.", localizedDescription = "Commanding Presence is available twice per day, and its successful disposition gain is doubled.", onRemove = clearSpeechcraft },
})

return {
    eventHandlers = {
        SPerks_UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
