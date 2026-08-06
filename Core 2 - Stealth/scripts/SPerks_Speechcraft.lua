--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

local core  = require("openmw.core")
local types = require("openmw.types")
local ui    = require("openmw.ui")
local self  = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")

local SKILL_ID = "speechcraft"
local ids = Common.ids(SKILL_ID)

local speechTracker = StatTracker.newStatModTracker(self, "Compelling Voice")
local currentNpc = nil
local lastDisposition = nil
local conversationStacks = 0
local combatTargets = {}
local auraTargets = {}
local auraTimer = 0
local lastCrimeLevel = nil
local lastBountyReduction = nil
local trainingActive = false
local trainingSkills = {}
local lastTrainingBonus = nil
local lastPersuasionResult = nil
local lastAuraResult = nil
local lastCombatTargetEvent = nil
local lastSoundDelivery = nil

local A_STACK_CAP = { [1] = 2, [2] = 4, [3] = 6, [4] = 10 }
local B_SOUND = {
    [1] = { magnitude = 15, radius = 500 },
    [2] = { magnitude = 30, radius = 1500 },
}
local C_BOUNTY_RATE = { [1] = 0.20, [2] = 0.40 }
local D_TRAINING_PROGRESS = { [1] = 0.25, [2] = 0.50 }
local AURA_INTERVAL = 0.2
local AURA_DURATION = 0.5
local SOUND_KEY = "SkillPerks_SpeechcraftCombatVoice"

local SKILL_IDS = {
    "block", "armorer", "mediumarmor", "heavyarmor", "bluntweapon",
    "longblade", "axe", "spear", "athletics", "enchant", "destruction",
    "alteration", "illusion", "conjuration", "mysticism", "restoration",
    "alchemy", "unarmored", "security", "sneak", "acrobatics",
    "lightarmor", "shortblade", "marksman", "mercantile", "speechcraft",
    "handtohand",
}

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function sameObject(left, right)
    return left ~= nil and right ~= nil
        and tostring(left.id) == tostring(right.id)
end

local function setConversationStacks(value)
    local cap = A_STACK_CAP[aRank()] or 0
    conversationStacks = math.max(0, math.min(cap, math.floor(value or 0)))
    speechTracker.apply("skills", SKILL_ID, conversationStacks * 5)
end

local function closeConversation()
    currentNpc = nil
    lastDisposition = nil
    setConversationStacks(0)
end

local function openConversation(npc)
    if not npc or not npc:isValid() or not types.NPC.objectIsInstance(npc) then
        return
    end
    if not sameObject(currentNpc, npc) then
        closeConversation()
        currentNpc = npc
        lastDisposition = types.NPC.getDisposition(npc, self)
    end
end

local function snapshotTrainingSkills()
    trainingSkills = {}
    for _, skillId in ipairs(SKILL_IDS) do
        local getter = types.NPC.stats.skills[skillId]
        local stat = getter and getter(self)
        trainingSkills[skillId] = stat and (stat.base or 0) or 0
    end
end

local function onUiModeChanged(data)
    data = data or {}
    SkillDebug.traceEvent(SKILL_ID, "UI mode changed", {
        newMode = data.newMode,
        oldMode = data.oldMode,
        target = SkillDebug.objectId(data.arg),
    })

    if data.newMode == "Dialogue" and data.arg then
        openConversation(data.arg)
    elseif data.newMode == nil then
        closeConversation()
    end

    if data.newMode == "Training" then
        trainingActive = true
        snapshotTrainingSkills()
    elseif data.oldMode == "Training" and data.newMode ~= "Training" then
        trainingActive = false
        trainingSkills = {}
    end
end

-- Persuasion has no dedicated Lua result event. A positive disposition
-- change while the dialogue is open is the observable successful attempt;
-- every success adds one +5 Speechcraft stack for the same conversation.
local function pollPersuasion()
    if not currentNpc or not currentNpc:isValid() then
        return
    end
    local disposition = types.NPC.getDisposition(currentNpc, self)
    if lastDisposition == nil then
        lastDisposition = disposition
        return
    end
    local delta = disposition - lastDisposition
    lastDisposition = disposition
    if math.abs(delta) < 0.5 then
        return
    end

    local before = conversationStacks
    local rank = aRank()
    local cap = A_STACK_CAP[rank] or 0
    if delta > 0 and rank > 0 then
        setConversationStacks(conversationStacks + 1)
        lastPersuasionResult = {
            npc = SkillDebug.objectId(currentNpc),
            dispositionDelta = delta,
            rank = rank,
            cap = cap,
            stacksBefore = before,
            stacksAfter = conversationStacks,
            bonus = conversationStacks * 5,
            result = before >= cap and "success observed; already at cap"
                or "success added one stack",
        }
        SkillDebug.traceEvent(SKILL_ID, "persuasion success", lastPersuasionResult)
    else
        lastPersuasionResult = {
            npc = SkillDebug.objectId(currentNpc),
            dispositionDelta = delta,
            rank = rank,
            cap = cap,
            stacksBefore = before,
            stacksAfter = conversationStacks,
            bonus = conversationStacks * 5,
            result = delta <= 0 and "attempt did not increase disposition"
                or "A chain inactive",
        }
        SkillDebug.traceEvent(SKILL_ID, "persuasion result", lastPersuasionResult)
    end
end

local function setSound(target, magnitude)
    if not target or not target:isValid() then
        return
    end
    target:sendEvent("SPerks_SetTimedEffectBundle", {
        key = SOUND_KEY,
        sourceEffect = ids["B" .. tostring(math.max(1, bRank()))],
        caster = self,
        resultEvent = "SPerks_SpeechcraftSoundApplied",
        effects = {
            {
                key = SOUND_KEY,
                id = "sound",
                magnitudeMin = magnitude,
                duration = AURA_DURATION,
            },
        },
    })
end

-- Records the target-local acknowledgement so diagnostics distinguish an
-- aura refresh request from a Sound modifier actually present on the actor.
local function onSoundApplied(data)
    data = data or {}
    local effect = data.effects and data.effects[1] or {}
    lastSoundDelivery = {
        target = SkillDebug.objectId(data.target),
        applied = tonumber(data.applied) or 0,
        rejected = tonumber(data.rejected) or 0,
        requested = tonumber(effect.requested) or 0,
        observed = tonumber(effect.magnitude) or 0,
        accepted = effect.accepted == true,
        result = effect.result or data.reasons or "unknown",
    }
    SkillDebug.traceEvent(SKILL_ID, "combat Sound delivery", lastSoundDelivery)
end

local function clearAura()
    for _, target in pairs(auraTargets) do
        setSound(target, 0)
    end
    auraTargets = {}
end

-- Combat music target notifications tell us exactly which actors currently
-- regard the player as a combat target. The aura then performs only a cheap
-- distance check and refreshes one named, non-stacking Sound modifier.
local function onCombatTargetsChanged(data)
    if not data or not data.actor then
        return
    end
    local key = Common.targetKey(data.actor)
    if not key then
        return
    end
    local targets = data.targets or {}
    local targetsPlayer = false
    for targetKey, targetValue in pairs(targets) do
        -- OpenMW versions may expose combat targets as an array, a sparse
        -- table, or an object-keyed set. Normalize all three representations.
        local candidate = type(targetValue) == "userdata" and targetValue or targetKey
        if type(candidate) == "userdata" and sameObject(candidate, self) then
            targetsPlayer = true
            break
        end
    end
    -- This event is produced by the player's combat-music target tracker. A
    -- non-empty target set therefore still identifies an active hostile actor
    -- when wrapper differences prevent an explicit player comparison.
    local active = targetsPlayer or next(targets) ~= nil
    lastCombatTargetEvent = {
        actor = SkillDebug.objectId(data.actor),
        active = active,
        targets = SkillDebug.count(targets),
        targetsPlayer = targetsPlayer,
    }
    SkillDebug.traceEvent(SKILL_ID, "combat targets changed", lastCombatTargetEvent)
    if active then
        combatTargets[key] = data.actor
    else
        combatTargets[key] = nil
        if auraTargets[key] then
            setSound(auraTargets[key], 0)
            auraTargets[key] = nil
        end
    end
end

local function refreshCombatVoice(dt)
    auraTimer = auraTimer + dt
    if auraTimer < AURA_INTERVAL then
        return
    end
    auraTimer = auraTimer % AURA_INTERVAL
    local effect = B_SOUND[bRank()]
    if not effect then
        lastAuraResult = {
            rank = bRank(),
            tracked = SkillDebug.count(combatTargets),
            affected = 0,
            result = "B chain inactive",
        }
        clearAura()
        SkillDebug.traceState(
            SKILL_ID,
            "Combat voice",
            "combat-voice-refresh",
            lastAuraResult)
        return
    end

    local refreshed = {}
    local invalid = 0
    local outOfRange = 0
    for key, target in pairs(combatTargets) do
        if target and target:isValid() then
            local distance = (target.position - self.position):length()
            if distance <= effect.radius then
                setSound(target, effect.magnitude)
                refreshed[key] = target
            else
                outOfRange = outOfRange + 1
            end
        else
            invalid = invalid + 1
            combatTargets[key] = nil
        end
    end
    for key, target in pairs(auraTargets) do
        if not refreshed[key] then
            setSound(target, 0)
        end
    end
    auraTargets = refreshed
    lastAuraResult = {
        rank = bRank(),
        magnitude = effect.magnitude,
        radiusUnits = effect.radius,
        radiusMetres = effect.radius / 100,
        tracked = SkillDebug.count(combatTargets),
        affected = SkillDebug.count(auraTargets),
        outOfRange = outOfRange,
        invalid = invalid,
        result = "non-stacking Sound refreshed",
    }
    SkillDebug.traceState(
        SKILL_ID,
        "Combat voice",
        "combat-voice-refresh",
        lastAuraResult)
end

-- Only the newly incurred portion of a bounty is eligible. Setting the
-- baseline to the observed pre-reduction value prevents the asynchronous
-- global write from being interpreted as another new crime on the next tick.
local function pollCrimeLevel()
    local current = types.Player.getCrimeLevel(self)
    if lastCrimeLevel == nil then
        lastCrimeLevel = current
        return
    end
    if current > lastCrimeLevel then
        local incurred = current - lastCrimeLevel
        local rank = cRank()
        local rate = C_BOUNTY_RATE[rank] or 0
        local reduction = math.floor(incurred * rate)
        lastCrimeLevel = current
        lastBountyReduction = {
            rank = rank,
            bountyBefore = current,
            incurred = incurred,
            reduction = reduction,
            expectedAfter = current - reduction,
            rate = rate,
            result = rank == 0 and "C chain inactive"
                or reduction <= 0 and "reduction rounded to zero"
                or "reduction queued",
        }
        if reduction > 0 then
            core.sendGlobalEvent("SPerks_ReducePlayerCrimeLevel", {
                player = self,
                amount = reduction,
            })
            ui.showMessage(string.format(
                "Your account of events reduces the new bounty by %d gold.",
                reduction))
        end
        SkillDebug.traceEvent(SKILL_ID, "new bounty observed", lastBountyReduction)
    elseif current < lastCrimeLevel then
        lastCrimeLevel = current
    end
end

-- A purchased training session raises exactly one base skill while the
-- Training UI remains open. The perk adds progress to that same skill and
-- caps below a full level so it never grants extra levels or bypasses the
-- game's training allowance.
local function pollTraining()
    if not trainingActive then
        return
    end
    local rate = D_TRAINING_PROGRESS[dRank()] or 0
    for _, skillId in ipairs(SKILL_IDS) do
        local stat = types.NPC.stats.skills[skillId](self)
        local previous = trainingSkills[skillId]
        local current = stat.base or 0
        if previous ~= nil and current > previous then
            local trainedLevels = current - previous
            local before = tonumber(stat.progress) or 0
            local requested = rate * trainedLevels
            local after = math.min(0.999, before + requested)
            lastTrainingBonus = {
                skill = skillId,
                rank = dRank(),
                trainedLevels = trainedLevels,
                requested = requested,
                progressBefore = before,
                progressAfter = after,
                applied = after - before,
                capped = before + requested > 0.999,
                result = rate > 0 and "progress applied" or "D chain inactive",
            }
            if rate > 0 then
                stat.progress = after
                ui.showMessage(string.format(
                    "The lesson grants %d%% progress toward your next %s rank.",
                    math.floor((after - before) * 100 + 0.5), skillId))
            end
            SkillDebug.traceEvent(SKILL_ID, "purchased training observed", lastTrainingBonus)
        end
        trainingSkills[skillId] = current
    end
end

local function clearSpeechcraft()
    closeConversation()
    clearAura()
    combatTargets = {}
    trainingActive = false
    trainingSkills = {}
    lastCrimeLevel = types.Player.getCrimeLevel(self)
end

local function onPerkAdded()
    setConversationStacks(conversationStacks)
    lastCrimeLevel = types.Player.getCrimeLevel(self)
    if trainingActive then
        snapshotTrainingSkills()
    end
end

local function onUpdate(dt)
    pollPersuasion()
    refreshCombatVoice(dt)
    pollCrimeLevel()
    pollTraining()
end

local function onSave()
    return {
        speechTracker = speechTracker.snapshot(),
        currentNpc = currentNpc,
        lastDisposition = lastDisposition,
        conversationStacks = conversationStacks,
        lastCrimeLevel = lastCrimeLevel,
        lastBountyReduction = lastBountyReduction,
        lastTrainingBonus = lastTrainingBonus,
        lastPersuasionResult = lastPersuasionResult,
        lastAuraResult = lastAuraResult,
    }
end

local function onLoad(data)
    data = data or {}
    -- The former design applied its one-attempt bonus through both a stat
    -- tracker and an active-effect tracker. Reverse either legacy snapshot
    -- once before starting the cumulative conversation system.
    speechTracker.restoreAndReverse(data.speechTracker or data.tracker)
    if data.effects then
        local legacyEffects = StatTracker.newActiveEffectTracker(self)
        legacyEffects.restoreAndReverse(data.effects)
    end
    for _, entry in pairs(data.lingering or {}) do
        if entry.npc and entry.npc:isValid() and (tonumber(entry.amount) or 0) ~= 0 then
            core.sendGlobalEvent("SPerks_ModifyNpcDisposition", {
                npc = entry.npc,
                player = self,
                amount = -(tonumber(entry.amount) or 0),
            })
        end
    end
    currentNpc = nil
    lastDisposition = nil
    conversationStacks = 0
    combatTargets = {}
    auraTargets = {}
    trainingActive = false
    trainingSkills = {}
    lastCrimeLevel = nil
    lastBountyReduction = data.lastBountyReduction
    lastTrainingBonus = data.lastTrainingBonus
    lastPersuasionResult = data.lastPersuasionResult
    lastAuraResult = data.lastAuraResult
end

-- Reports all four independent chains so live traces can be enabled only for
-- Speechcraft while testing persuasion, combat, crime, or training behavior.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Speechcraft",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luaspeechcraft debug", "luaspeech debug" },
    snapshot = function()
        return {
            string.format(
                "Conversation: npc=%s disposition=%s stacks=%d/%d SpeechcraftBonus=%d",
                SkillDebug.objectId(currentNpc),
                SkillDebug.value(lastDisposition),
                conversationStacks,
                A_STACK_CAP[aRank()] or 0,
                conversationStacks * 5
            ),
            string.format(
                "Combat voice: targets=%d affected=%d magnitude=%s radius=%sm",
                SkillDebug.count(combatTargets),
                SkillDebug.count(auraTargets),
                SkillDebug.value(B_SOUND[bRank()] and B_SOUND[bRank()].magnitude),
                SkillDebug.value(B_SOUND[bRank()] and B_SOUND[bRank()].radius / 100)
            ),
            lastCombatTargetEvent and string.format(
                "Last combat target event: actor=%s targets=%s targetsPlayer=%s active=%s",
                tostring(lastCombatTargetEvent.actor),
                SkillDebug.number(lastCombatTargetEvent.targets),
                tostring(lastCombatTargetEvent.targetsPlayer),
                tostring(lastCombatTargetEvent.active))
                or "Last combat target event: none received",
            string.format(
                "Bounty: current=%s baseline=%s last=%s",
                SkillDebug.number(types.Player.getCrimeLevel(self)),
                SkillDebug.value(lastCrimeLevel),
                lastBountyReduction and string.format(
                    "rank=%s before=%s incurred=%s reduced=%s expectedAfter=%s rate=%s result=%s",
                    SkillDebug.number(lastBountyReduction.rank),
                    SkillDebug.number(lastBountyReduction.bountyBefore),
                    SkillDebug.number(lastBountyReduction.incurred),
                    SkillDebug.number(lastBountyReduction.reduction),
                    SkillDebug.number(lastBountyReduction.expectedAfter),
                    SkillDebug.number(lastBountyReduction.rate),
                    tostring(lastBountyReduction.result)) or "none"
            ),
            string.format(
                "Training: active=%s last=%s",
                tostring(trainingActive),
                lastTrainingBonus and string.format(
                    "%s progress %.3f->%.3f requested=%.3f applied=%.3f capped=%s result=%s",
                    tostring(lastTrainingBonus.skill),
                    lastTrainingBonus.progressBefore,
                    lastTrainingBonus.progressAfter,
                    lastTrainingBonus.requested or 0,
                    lastTrainingBonus.applied or 0,
                    tostring(lastTrainingBonus.capped),
                    tostring(lastTrainingBonus.result)) or "none"
            ),
            lastPersuasionResult and string.format(
                "Last persuasion: npc=%s delta=%s rank=%s stacks=%s->%s cap=%s bonus=%s result=%s",
                tostring(lastPersuasionResult.npc),
                SkillDebug.number(lastPersuasionResult.dispositionDelta),
                SkillDebug.number(lastPersuasionResult.rank),
                SkillDebug.number(lastPersuasionResult.stacksBefore),
                SkillDebug.number(lastPersuasionResult.stacksAfter),
                SkillDebug.number(lastPersuasionResult.cap),
                SkillDebug.number(lastPersuasionResult.bonus),
                tostring(lastPersuasionResult.result)) or "Last persuasion: none",
            lastAuraResult and string.format(
                "Last combat voice: rank=%s tracked=%s affected=%s outOfRange=%s invalid=%s Sound=%s radius=%sm result=%s",
                SkillDebug.number(lastAuraResult.rank),
                SkillDebug.number(lastAuraResult.tracked),
                SkillDebug.number(lastAuraResult.affected),
                SkillDebug.number(lastAuraResult.outOfRange or 0),
                SkillDebug.number(lastAuraResult.invalid or 0),
                SkillDebug.value(lastAuraResult.magnitude),
                SkillDebug.value(lastAuraResult.radiusMetres),
                tostring(lastAuraResult.result)) or "Last combat voice: none",
            lastSoundDelivery and string.format(
                "Sound delivery: target=%s requested=%s observedTotal=%s accepted=%s applied=%s rejected=%s result=%s",
                tostring(lastSoundDelivery.target),
                SkillDebug.number(lastSoundDelivery.requested),
                SkillDebug.number(lastSoundDelivery.observed),
                tostring(lastSoundDelivery.accepted),
                SkillDebug.number(lastSoundDelivery.applied),
                SkillDebug.number(lastSoundDelivery.rejected),
                tostring(lastSoundDelivery.result)) or "Sound delivery: none acknowledged",
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Speechcraft", ids, {
    A1 = { localizedName = "Compelling Voice", localizedFlavour = "One success lends weight to the next word, and soon the whole conversation moves at your pace.", localizedDescription = "Each successful persuasion attempt grants a cumulative +5 Speechcraft for the current conversation, up to 2 stacks.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    A2 = { localizedName = "Measured Praise", localizedFlavour = "Admiration becomes a rhythm, each well-placed phrase preparing the listener for another.", localizedDescription = "Compelling Voice's stack cap increases to 4.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    A3 = { localizedName = "Threaded Intent", localizedFlavour = "Every answer ties back to a thought you planted three sentences ago.", localizedDescription = "Compelling Voice's stack cap increases to 6.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    A4 = { localizedName = "Conversation's Crown", localizedFlavour = "You do not win arguments. You make agreement feel like the listener's own discovery.", localizedDescription = "Compelling Voice's stack cap increases to 10.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    B1 = { localizedName = "Cutting Cadence", localizedFlavour = "Your voice finds the cracks in an enemy's concentration and worries at them like a blade.", localizedDescription = "Enemies fighting you within 5 metres suffer 15 points of Sound.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    B2 = { localizedName = "Voice Above Steel", localizedFlavour = "Even through the roar of battle, your words arrive sharp, certain, and impossible to ignore.", localizedDescription = "Cutting Cadence increases to 30 Sound within 15 metres.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    C1 = { localizedName = "Plausible Account", localizedFlavour = "By the time the guards understand what happened, they are no longer certain it happened quite that way.", localizedDescription = "Newly incurred bounty is reduced by 20%.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    C2 = { localizedName = "Unimpeachable Story", localizedFlavour = "Your version of events arrives polished, witnessed, and wearing better clothes than the truth.", localizedDescription = "Plausible Account reduces newly incurred bounty by 40%.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    D1 = { localizedName = "Attentive Student", localizedFlavour = "A master needs fewer words with you. You hear the lesson behind the lesson.", localizedDescription = "Purchased training grants 25% progress toward that skill's next level.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
    D2 = { localizedName = "Lessons Remembered", localizedFlavour = "Instruction does not end when the teacher falls silent. It keeps unfolding in your hands.", localizedDescription = "Attentive Student grants 50% progress instead.", onAdd = onPerkAdded, onRemove = clearSpeechcraft },
})

return {
    eventHandlers = {
        OMWMusicCombatTargetsChanged = onCombatTargetsChanged,
        SPerks_SpeechcraftSoundApplied = onSoundApplied,
        SPerks_UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
