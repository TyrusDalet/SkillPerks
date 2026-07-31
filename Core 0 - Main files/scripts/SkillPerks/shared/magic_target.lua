--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Target-local Magic bridge. It reports newly-landed player spells once and
owns effects that must mutate the struck actor in its own script context.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local pself = require("openmw.self")

local Stagger = require("scripts.SkillPerks.shared.stagger")
local MagicDetection = require("scripts.SkillPerks.shared.magic_detection")

local MagicTarget = {}
local seen = {}
local initialized = false
local pollTimer = 0
local mindThefts = {}
local tether = nil
local echoed = false
local poisonConsequence = nil
local destructionDrain = nil
local spellforgeAuthorizations = {}

--- Sends target-local diagnostic evidence back to the player script, where
--- the selected school's trace toggle and verbosity level are enforced.
local function reportTargetTrace(caster, skillId, effectName, stage, fields)
    if caster and caster:isValid() and types.Player.objectIsInstance(caster) then
        caster:sendEvent("SPerks_MagicTargetTrace", {
            skillId=skillId,effectName=effectName,stage=stage,fields=fields,
        })
    end
end

--- Reports the final target-local write made for a school resource rider.
--- @param data table Original resource request.
--- @param resource string
--- @param resolved number|nil Framework-resolved amount.
--- @param before number|nil Resource current value before the write.
function MagicTarget.reportResourceDelta(data, resource, resolved, before)
    data=data or {}
    local sourceEffect=tostring(data.sourceEffect or "")
    local skillId=sourceEffect:lower():match("^skillperks_([^_]+)_")
    if not skillId then return end
    local stat=types.Actor.stats.dynamic[resource](pself)
    reportTargetTrace(data.source,skillId,"Resource rider","target-local write complete",{
        after=stat and stat.current,before=before,damageType=data.damageType,
        requested=data.amount,resolved=resolved,resource=resource,
        sourceEffect=data.sourceEffect,target=tostring(pself),
    })
end

local function copyEffects(spell)
    local result = {}
    for _, effect in pairs(spell.effects or {}) do
        table.insert(result, {
            id = effect.id,
            index = effect.index,
            affectedAttribute = effect.affectedAttribute,
            affectedSkill = effect.affectedSkill,
            magnitude = effect.magnitudeThisFrame,
            minMagnitude = effect.minMagnitude,
            maxMagnitude = effect.maxMagnitude,
            duration = effect.duration,
            durationLeft = effect.durationLeft,
        })
    end
    return result
end

local function activeSpellIds()
    local current = {}
    for _, spell in pairs(types.Actor.activeSpells(pself)) do
        current[spell.activeSpellId or spell.id] = spell
    end
    return current
end

--- Returns the remaining duration of a generated Soul Tether instance.
local function tetherDurationLeft(spell)
    local remaining=math.huge
    for _,effect in pairs(spell.effects or {}) do
        if effect.id=="absorbmagicka" then
            remaining=math.min(
                remaining,
                math.max(0,tonumber(effect.durationLeft) or tonumber(effect.duration) or 0)
            )
        end
    end
    return remaining==math.huge and 0 or remaining
end

--- Collapses duplicate generated Soul Tether spells already present on this
--- actor. The shortest-lived instance is retained so a repeated Soultrap
--- cannot refresh the original tether while the migration cleanup runs.
local function reconcileSoulTetherSpells()
    local instances={}
    for _,spell in pairs(types.Actor.activeSpells(pself)) do
        local recordId=tostring(spell.id or ""):lower()
        if recordId:find("^sperks_dynamic_")
                and tostring(spell.name or "")=="Soul Tether" then
            instances[#instances+1]=spell
        end
    end
    if #instances<=1 then return instances[1] end
    table.sort(instances,function(left,right)
        return tetherDurationLeft(left)<tetherDurationLeft(right)
    end)
    local kept=instances[1]
    local removed=0
    for index=2,#instances do
        local activeId=instances[index].activeSpellId
        if activeId~=nil and pcall(function()
            types.Actor.activeSpells(pself):remove(activeId)
        end) then
            removed=removed+1
        end
    end
    reportTargetTrace(kept.caster,"mysticism","Soul Tether",
        "duplicate active spells reconciled",{
            keptDuration=tetherDurationLeft(kept),removed=removed,
            target=tostring(pself),
        })
    return kept
end

local function reportNewPlayerSpells(current)
    local now=core.getSimulationTime()
    for key, spell in pairs(current) do
        if not seen[key] and spell.caster and spell.caster:isValid()
                and types.Player.objectIsInstance(spell.caster) then
            local authorization=spellforgeAuthorizations[
                tostring(spell.id or ""):lower()
            ]
            local spellforgeAuthorized=authorization
                and authorization.expiresAt>=now
                and authorization.casterId==tostring(spell.caster.id)
            spell.caster:sendEvent("SPerks_MagicEffectLanded", {
                target = pself,
                spellId = spell.id,
                activeSpellId = spell.activeSpellId,
                item = spell.item,
                isPlayerCast = spellforgeAuthorized
                    or MagicDetection.isPlayerCastActiveSpell(
                    spell.caster,
                    spell
                ),
                sourceType=spellforgeAuthorized and "spellforge" or "spell",
                effects = copyEffects(spell),
            })
        end
    end
    seen = {}
    for key in pairs(current) do seen[key] = true end
end

local function reverseMindTheft(id, state)
    for attribute, amount in pairs(state.drains or {}) do
        local stat = types.Actor.stats.attributes[attribute](pself)
        stat.modifier = stat.modifier + amount
    end
    if state.caster and state.caster:isValid() then
        reportTargetTrace(state.caster,"illusion","Mind Theft","reversing target drains",{
            activeSpellId=id,drains=state.drains,target=tostring(pself),
        })
        state.caster:sendEvent("SPerks_IllusionMindTheftDelta", {
            key = tostring(pself) .. ":" .. tostring(id),
            drains = state.drains,
            remove = true,
        })
    end
end

local function updateMindThefts(current)
    for id, state in pairs(mindThefts) do
        if not current[id] then
            reverseMindTheft(id, state)
            mindThefts[id] = nil
        end
    end
end

function MagicTarget.onUpdate(dt)
    -- Only actors carrying a death-triggered perk mark need a death check.
    -- Expired marks are discarded here, while a valid mark is consumed by
    -- onDeath after it reports the relevant reward to the player.
    local now = core.getSimulationTime()
    for spellId,authorization in pairs(spellforgeAuthorizations) do
        if authorization.expiresAt<now then
            spellforgeAuthorizations[spellId]=nil
        end
    end
    if tether and now > (tether.expiresAt or 0) then tether = nil end
    if destructionDrain and now > (destructionDrain.expiresAt or 0) then
        destructionDrain = nil
    end
    if (tether or destructionDrain) and types.Actor.isDead(pself) then
        MagicTarget.onDeath()
        return
    end

    pollTimer = pollTimer - dt
    if pollTimer > 0 then return end
    pollTimer = 0.1
    reconcileSoulTetherSpells()
    local current = activeSpellIds()
    if initialized then
        reportNewPlayerSpells(current)
    else
        seen = {}
        for key in pairs(current) do seen[key] = true end
        initialized = true
    end
    updateMindThefts(current)

    if poisonConsequence then
        poisonConsequence.remaining = poisonConsequence.remaining - 0.1
        poisonConsequence.tick = poisonConsequence.tick - 0.1
        if poisonConsequence.tick <= 0 and poisonConsequence.remaining > 0 then
            poisonConsequence.tick = 1
            poisonConsequence.stacks = math.min(
                poisonConsequence.cap,
                poisonConsequence.stacks + 1
            )
            local weakness = poisonConsequence.stacks * poisonConsequence.weakness
            local speed = poisonConsequence.stacks * poisonConsequence.speed
            types.Actor.activeEffects(pself):modify(
                weakness - poisonConsequence.appliedWeakness,
                "weaknesstomagicka"
            )
            types.Actor.activeEffects(pself):modify(
                -(speed - poisonConsequence.appliedSpeed),
                "fortifyattribute",
                "speed"
            )
            poisonConsequence.appliedWeakness = weakness
            poisonConsequence.appliedSpeed = speed
            reportTargetTrace(poisonConsequence.caster,"destruction","Poison consequence","stack applied",{
                speedPenalty=speed,stacks=poisonConsequence.stacks,
                target=tostring(pself),weakness=weakness,
            })
        elseif poisonConsequence.remaining <= -5 then
            types.Actor.activeEffects(pself):modify(
                -poisonConsequence.appliedWeakness,
                "weaknesstomagicka"
            )
            types.Actor.activeEffects(pself):modify(
                poisonConsequence.appliedSpeed,
                "fortifyattribute",
                "speed"
            )
            reportTargetTrace(poisonConsequence.caster,"destruction","Poison consequence","state cleared",{
                finalStacks=poisonConsequence.stacks,target=tostring(pself),
            })
            poisonConsequence = nil
        end
    end
end

--- Authorizes one SFP helper spell after Core 0's global bridge confirms its
--- Spellforge user-data cookie and player caster. The short window exists
--- only to classify the ActiveSpell that SFP adds immediately afterward.
local function authorizeSpellforgeSpell(data)
    data=data or {}
    if not data.caster or not data.caster:isValid()
            or not types.Player.objectIsInstance(data.caster) then
        return
    end
    local spellId=tostring(data.spellId or ""):lower()
    if spellId=="" then return end
    spellforgeAuthorizations[spellId]={
        casterId=tostring(data.caster.id),
        expiresAt=math.max(
            core.getSimulationTime()+0.5,
            tonumber(data.expiresAt) or 0
        ),
    }
end

local function applyMindTheft(data)
    if not data or not data.activeSpellId then
        reportTargetTrace(data and data.caster,"illusion","Mind Theft","rejected: missing active spell id",{})
        return
    end
    if mindThefts[data.activeSpellId] then
        reportTargetTrace(data.caster,"illusion","Mind Theft","rejected: already active",{
            activeSpellId=data.activeSpellId,target=tostring(pself),
        })
        return
    end
    local drains = {}
    for _, attribute in ipairs({ "strength", "endurance", "agility", "speed" }) do
        local stat = types.Actor.stats.attributes[attribute](pself)
        local amount = math.max(0, math.floor((stat.modified or 0) * 0.5))
        stat.modifier = stat.modifier - amount
        drains[attribute] = amount
    end
    mindThefts[data.activeSpellId] = { caster = data.caster, drains = drains }
    if data.caster and data.caster:isValid() then
        reportTargetTrace(data.caster,"illusion","Mind Theft","attribute drains applied",{
            activeSpellId=data.activeSpellId,drains=drains,target=tostring(pself),
        })
        data.caster:sendEvent("SPerks_IllusionMindTheftDelta", {
            key = tostring(pself) .. ":" .. tostring(data.activeSpellId),
            drains = drains,
        })
    end
end

local function clearAlarm(data)
    if types.NPC.objectIsInstance(pself) then
        local alarm = types.Actor.stats.ai.alarm(pself)
        local before=alarm and alarm.base
        if alarm then alarm.base = 0 end
        reportTargetTrace(data and data.caster,"illusion","Clear Alarm","alarm cleared",{
            alarmBefore=before,target=tostring(pself),
        })
    end
end

local function staggerAttempt(data)
    data = data or {}
    local fatigue = types.Actor.stats.dynamic.fatigue(pself)
    local framework = interfaces.ErnPerkFramework
    if framework then
        local resolved=framework.applyActorResourceDelta({
            actor=pself,resource="fatigue",
            operation=framework.RESOURCE_OPERATION.Damage,
            amount=math.max(0,data.drainAmount or 0),
            sourceEffect="SkillPerks_mysticism_d1",
            context={telekineticForce=true},
        })
        reportTargetTrace(data.caster,"mysticism","Telekinetic Force","Fatigue damage applied",{
            requested=data.drainAmount,resolved=resolved,target=tostring(pself),
        })
    else
        reportTargetTrace(data.caster,"mysticism","Telekinetic Force","rejected: Framework unavailable",{
            target=tostring(pself),
        })
    end
    if not data.isD2 then
        Stagger.forceStagger()
        reportTargetTrace(data.caster,"mysticism","Telekinetic Force","stagger forced",{
            d2=false,target=tostring(pself),
        })
        return
    end
    local willpower = types.Actor.stats.attributes.willpower(pself).modified
    local maximum = math.max(fatigue.base + fatigue.modifier, 1)
    local factor = 0.2 + 0.8 * math.max(0, math.min(1, fatigue.current / maximum))
    local resist = math.max(0, math.min(1, 0.10 * (willpower / 10) * factor))
    local roll=math.random()
    local resisted=roll<resist
    if resisted then Stagger.forceStagger() else Stagger.forceKnockdown() end
    reportTargetTrace(data.caster,"mysticism","Invisible Hammer","resistance resolved",{
        fatigueFactor=factor,knockedDown=not resisted,resistChance=resist,
        roll=roll,target=tostring(pself),willpower=willpower,
    })
end

--- Records the death-trigger portion of Soul Tether only when this actor does
--- not already carry a live tether or its Absorb Magicka spell. Checking both
--- forms of state makes the non-stacking rule survive Lua reloads and old saves.
--- @param data table|nil New tether state.
local function setTether(data)
    local now = core.getSimulationTime()
    if tether and now <= (tether.expiresAt or 0) then
        reportTargetTrace(data and data.caster,"mysticism","Soul Tether","rejected: tether already active",{
            existingExpiresAt=tether.expiresAt,now=now,target=tostring(pself),
        })
        return
    end

    local existingSpell=reconcileSoulTetherSpells()
    local existingDuration=existingSpell and tetherDurationLeft(existingSpell) or 0
    if existingDuration>0 then
        -- Target-local state is not persisted, but active spells are. Restore
        -- the death marker without refreshing the surviving spell's duration.
        tether={
            burst=data and data.burst,
            caster=data and data.caster,
            expiresAt=now+existingDuration,
            soulValue=data and data.soulValue,
        }
        reportTargetTrace(data and data.caster,"mysticism","Soul Tether",
            "rejected: Absorb Magicka already active",{
                existingDuration=existingDuration,
                restoredDeathMark=true,
                target=tostring(pself),
            })
        return
    end

    tether = data
    reportTargetTrace(data and data.caster,"mysticism","Soul Tether","death mark stored",{
        burst=data and data.burst,expiresAt=data and data.expiresAt,
        soulValue=data and data.soulValue,target=tostring(pself),
    })
    if data and data.caster and data.caster:isValid() then
        data.caster:sendEvent("SPerks_MysticismTetherAccepted",{
            duration=math.max(1,tonumber(data.duration) or 1),
            magnitude=math.max(1,tonumber(data.magnitude) or 1),
            target=pself,
        })
    end
end

function MagicTarget.onDeath()
    local resolvedTether = tether
    local resolvedDrain = destructionDrain
    tether = nil
    destructionDrain = nil

    if resolvedTether and resolvedTether.burst
            and resolvedTether.caster and resolvedTether.caster:isValid()
            and core.getSimulationTime() <= (resolvedTether.expiresAt or 0) then
        local amount=math.ceil((resolvedTether.soulValue or 0)*0.20)
        reportTargetTrace(resolvedTether.caster,"mysticism","Final Dividend","target death qualified",{
            amount=amount,soulValue=resolvedTether.soulValue,target=tostring(pself),
        })
        resolvedTether.caster:sendEvent("SPerks_MysticismSoulTetherBurst",{amount=amount})
    end
    if resolvedDrain and resolvedDrain.caster
            and resolvedDrain.caster:isValid()
            and core.getSimulationTime() <= (resolvedDrain.expiresAt or 0) then
        local duration = math.max(1, resolvedDrain.duration or 1)
        local remaining = math.max(
            0,
            resolvedDrain.expiresAt - core.getSimulationTime()
        )
        local amount=(resolvedDrain.cost or 0)*math.min(1,remaining/duration)
            *(resolvedDrain.refundRatio or 0)
        reportTargetTrace(resolvedDrain.caster,"destruction","Drain-kill refund","target death qualified",{
            amount=amount,cost=resolvedDrain.cost,duration=duration,
            remaining=remaining,target=tostring(pself),
        })
        resolvedDrain.caster:sendEvent("SPerks_DestructionDrainKillRefund",{amount=amount})
    end
end

local function confirmEcho(data)
    if echoed then
        reportTargetTrace(data and data.caster,"mysticism","Echo of the Soul","rejected: target already confirmed",{
            target=tostring(pself),
        })
        return
    end
    echoed = true
    if data and data.caster and data.caster:isValid() then
        reportTargetTrace(data.caster,"mysticism","Echo of the Soul","target confirmed",{
            target=tostring(pself),
        })
        data.caster:sendEvent("SPerks_MysticismEchoConfirmed", { target = pself })
    end
end

-- Poison exposure owns its stacking debuffs on the poisoned actor, allowing
-- the player script to send one compact instruction instead of polling every
-- target for the effect's full duration.
local function startPoisonConsequence(data)
    data = data or {}
    if poisonConsequence then
        types.Actor.activeEffects(pself):modify(
            -poisonConsequence.appliedWeakness,
            "weaknesstomagicka"
        )
        types.Actor.activeEffects(pself):modify(
            poisonConsequence.appliedSpeed,
            "fortifyattribute",
            "speed"
        )
    end
    poisonConsequence = {
        caster=data.caster,
        remaining=math.max(1,tonumber(data.duration) or 1),
        tick=0, stacks=0, cap=math.max(1,tonumber(data.cap) or 10),
        weakness=math.max(0,tonumber(data.weakness) or 5),
        speed=math.max(0,tonumber(data.speed) or 5),
        appliedWeakness=0, appliedSpeed=0,
    }
    reportTargetTrace(data.caster,"destruction","Poison consequence","state initialized",{
        cap=poisonConsequence.cap,duration=poisonConsequence.remaining,
        speedPerStack=poisonConsequence.speed,target=tostring(pself),
        weaknessPerStack=poisonConsequence.weakness,
    })
end

local function setDestructionDrain(data)
    data = data or {}
    destructionDrain = {
        caster=data.caster,
        cost=math.max(0,tonumber(data.cost) or 0),
        duration=math.max(1,tonumber(data.duration) or 1),
        expiresAt=core.getSimulationTime()+math.max(1,tonumber(data.duration) or 1),
        refundRatio=math.max(0,tonumber(data.refundRatio) or 0),
    }
    reportTargetTrace(data.caster,"destruction","Drain-kill refund","death mark stored",{
        cost=destructionDrain.cost,duration=destructionDrain.duration,
        expiresAt=destructionDrain.expiresAt,refundRatio=destructionDrain.refundRatio,
        target=tostring(pself),
    })
end

function MagicTarget.eventHandlers()
    return {
        SPerks_IllusionMindTheft = applyMindTheft,
        SPerks_IllusionClearAlarm = clearAlarm,
        SPerks_MysticismStaggerAttempt = staggerAttempt,
        SPerks_MysticismSetTether = setTether,
        SPerks_MysticismConfirmEcho = confirmEcho,
        SPerks_DestructionPoisonConsequence = startPoisonConsequence,
        SPerks_DestructionSetDrainKill = setDestructionDrain,
        SPerks_AuthorizeSpellforgeSpell = authorizeSpellforgeSpell,
    }
end

return MagicTarget
