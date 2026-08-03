--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Alteration rewards practical spell pairings and stores force in player-cast
shield effects. Persistent bonuses are recalculated from a clean baseline.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local self = require("openmw.self")

local Common = require("scripts.SkillPerks.magic.common")
local CombatMath = require("scripts.SkillPerks.shared.combat_math")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local ids = Common.ids("alteration")
local effects = StatTracker.newActiveEffectTracker(self)
local legacyPairedStats = StatTracker.newStatModTracker(self, "Alteration Paired Effects")
local pools = { shield=0, fireshield=0, frostshield=0, lightningshield=0 }
local expiry = {}
local updateTimer = 0
local pendingRefund = nil
local effortlessSwimmingActive = false
local lightStepActive = false
local previousFatigue = types.Actor.stats.dynamic.fatigue(self).current
local wasJumpPressed = false
local jumpRefundPending = nil
local lastFatigueReduction = nil
local pairingDiagnostics = {}
local lastCounterweight = "No Burden rider has been attempted."

local REFUND_DELAY = 0.1
local MOVEMENT_FATIGUE_REDUCTION = 0.50
local JUMP_SAMPLE_DELAY = 0.15
local PAIRING_POLL_INTERVAL = 0.5

local function rank(chain) return Common.rank(ids, chain) end

--- Returns the Burden effect carried by a spell record or active spell.
--- @param spell table|nil
--- @return table|nil effect
local function burdenEffect(spell)
    for _,effect in pairs(spell and spell.effects or {}) do
        if effect.id=="burden" then return effect end
    end
    return nil
end

-- A-chain pairings remain active only for the lifetime of the corresponding
-- player-cast Alteration effect, so consumables cannot enable them.
local function refreshPairedEffects()
    local a = rank("A")
    local snapshot={}
    local diagnostics={qualifyingSpells=0,scannedSpells=0}
    if a>0 then
        snapshot,diagnostics=Common.playerSpellEffectSnapshot(self,{
            "swiftswim","waterbreathing","jump","feather","levitate",
        })
    end
    local swift = a >= 1 and snapshot.swiftswim.magnitude or 0
    local breathing = a >= 1 and snapshot.waterbreathing.present or false
    local jump = a >= 2 and snapshot.jump.magnitude or 0
    local feather = a >= 3 and snapshot.feather.magnitude or 0
    local burden = math.max(0, Common.getEffectMagnitude(self, "burden"))
    local levitate = a >= 4 and snapshot.levitate.magnitude or 0
    local nightEyeBonus = breathing and 25 or 0
    local featherBonus = feather > 0 and math.min(feather, burden) or 0
    local paralysisResist = levitate > 0 and 100 or 0

    effortlessSwimmingActive = swift > 0
    lightStepActive = jump > 0
    effects.apply("nighteye", nil, nightEyeBonus)
    effects.apply("feather", nil, featherBonus)
    effects.apply("resistparalysis", nil, paralysisResist)
    pairingDiagnostics={
        breathing=breathing,feather=feather,featherBonus=featherBonus,
        jump=jump,levitate=levitate,nightEyeBonus=nightEyeBonus,
        paralysisResist=paralysisResist,swift=swift,
        qualifyingSpells=diagnostics.qualifyingSpells,
        scannedSpells=diagnostics.scannedSpells,
    }
    SkillDebug.traceState("alteration","Alteration pairings","paired-effects",{
        aRank=a, waterBreathing=breathing,
        effortlessSwimming=effortlessSwimmingActive,
        feather=feather, featherBonus=featherBonus, jump=jump,
        lightStep=lightStepActive,
        levitate=levitate, nightEyeBonus=nightEyeBonus,
        paralysisResist=paralysisResist, swiftSwim=swift,
        qualifyingSpells=diagnostics.qualifyingSpells,
        scannedSpells=diagnostics.scannedSpells,
    })
end

--- Describes every active Water Breathing spell, including rejected sources,
--- so `luaalt debug` can distinguish detection failures from rider failures.
local function waterBreathingSourceSummary()
    local summaries={}
    for _,spell in pairs(types.Actor.activeSpells(self)) do
        for _,effect in pairs(spell.effects or {}) do
            if effect.id=="waterbreathing" then
                local source=Common.describeActiveSpellSource(self,spell)
                summaries[#summaries+1]=string.format(
                    "spell=%s caster=%s casterMatches=%s item=%s known=%s spellforge=%s authorized=%s qualifies=%s",
                    tostring(source.id),SkillDebug.objectId(source.caster),
                    tostring(source.casterIsActor),SkillDebug.objectId(source.item),
                    tostring(source.known),tostring(source.spellforge),
                    tostring(source.spellforgeAuthorized),tostring(source.qualifies)
                )
            end
        end
    end
    return #summaries>0 and table.concat(summaries,"; ")
        or "no active Water Breathing spell found"
end

--- Returns whether the player is actively swimming rather than merely
--- standing in shallow water.
local function isMovingWhileSwimming()
    if not types.Actor.isSwimming(self) then return false end
    local controls = self.controls
    return math.abs(tonumber(controls.movement) or 0) > 0.01
        or math.abs(tonumber(controls.sideMovement) or 0) > 0.01
end

--- Restores the perk-owned share of an observed movement Fatigue cost through
--- the framework resource pipeline, allowing other mods to modify the result.
local function refundMovementFatigue(kind, spent, sourceEffect)
    spent = math.max(0, tonumber(spent) or 0)
    if spent <= 0 then return 0 end

    local requested = spent * MOVEMENT_FATIGUE_REDUCTION
    local before = types.Actor.stats.dynamic.fatigue(self).current
    local resolved = Common.restoreResource(self, "fatigue", requested, sourceEffect)
    local after = types.Actor.stats.dynamic.fatigue(self).current
    lastFatigueReduction = {
        kind = kind,
        spent = spent,
        requested = requested,
        resolved = resolved,
        observed = math.max(0, after - before),
    }
    SkillDebug.traceEvent("alteration", kind .. " Fatigue reduction", lastFatigueReduction)
    return resolved
end

--- Samples vanilla swimming and jumping costs. OpenMW does not expose either
--- cost as a cancellable event, so the perk refunds half of the observed loss
--- immediately after the engine applies it.
local function updateMovementFatigueReduction(dt)
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local current = tonumber(fatigue.current) or 0

    if effortlessSwimmingActive and isMovingWhileSwimming() then
        local spent = math.max(0, (tonumber(previousFatigue) or current) - current)
        if spent > 0 then
            refundMovementFatigue("Effortless Swimming", spent, ids.A1)
            current = tonumber(fatigue.current) or current
        end
    end

    local jumpPressed = self.controls.jump == true
    if lightStepActive and jumpPressed and not wasJumpPressed then
        jumpRefundPending = {
            before = current,
            delay = JUMP_SAMPLE_DELAY,
        }
        SkillDebug.traceEvent("alteration", "Light Step jump armed", {
            fatigueBefore = current,
            sampleDelay = JUMP_SAMPLE_DELAY,
        })
    end
    wasJumpPressed = jumpPressed

    if jumpRefundPending then
        jumpRefundPending.delay = jumpRefundPending.delay - dt
        if jumpRefundPending.delay <= 0 then
            local pending = jumpRefundPending
            jumpRefundPending = nil
            current = tonumber(fatigue.current) or current
            refundMovementFatigue(
                "Light Step",
                math.max(0, pending.before - current),
                ids.A2
            )
            current = tonumber(fatigue.current) or current
        end
    end

    previousFatigue = current
end

-- Steady Footing measures real equipment AR and contributes only the missing
-- Shield needed to reach its floor. Its own tracked Shield is excluded.
local function refreshSteadyFooting()
    local c = rank("C")
    effects.apply("sound", nil, c == 2 and -10 or c == 1 and -5 or 0)
    if c == 0 then
        effects.apply("shield", nil, 0)
        SkillDebug.traceState("alteration","Steady Footing","steady-footing",{
            cRank=0, shieldBonus=0, sound=0,
        })
        return
    end
    local floor = c == 2 and 60 or 35
    local natural = CombatMath.getArmorRating(self)
    local shieldBonus=math.max(0, floor - natural)
    effects.apply("shield", nil, shieldBonus)
    SkillDebug.traceState("alteration","Steady Footing","steady-footing",{
        armorRating=natural,cRank=c,floor=floor,shieldBonus=shieldBonus,
        sound=c == 2 and -10 or -5,
    })
end

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id = "SkillPerks_alteration_cast",
    skill = "alteration",
    playerCastOnly = true,
    handler = function(event)
        local spell=event and event.spell
        if rank("A")>=3 and spell and burdenEffect(spell) then
            lastCounterweight=string.format(
                "Burden cast observed: spell=%s; awaiting target-local landing.",
                tostring(spell.id)
            )
            SkillDebug.traceEvent("alteration","Counterweight cast observed",{
                detection="Core 0 target-local active-spell bridge",
                spell=spell.id,
            })
        end

        local b = rank("B")
        local trace=SkillDebug.beginTrace("alteration","Reduced Casting Cost","Alteration skill-use event",{
            bRank=b,cost=event and event.cost,spell=event and event.spell and event.spell.id,
        })
        if b == 0 then return trace:reject("B chain inactive") end
        local cost = math.max(0, tonumber(event.cost) or 0)
        local percent = b == 2 and 0.30 or 0.15
        local refund = math.floor(cost * percent)
        local threshold = b == 2 and 25 or 10
        if cost - refund < threshold then refund = cost end
        trace:step("refund calculated",{
            cost=cost,percent=percent,refund=refund,threshold=threshold,
        })

        local magicka=types.Actor.stats.dynamic.magicka(self)
        local observedAfterCast=tonumber(magicka.current) or 0
        local beforeCast=tonumber(event.magickaBeforeCast)
            or (observedAfterCast+cost)
        if pendingRefund then
            pendingRefund.cost=pendingRefund.cost+cost
            pendingRefund.refund=pendingRefund.refund+refund
            pendingRefund.delay=REFUND_DELAY
            pendingRefund.casts=pendingRefund.casts+1
            pendingRefund.sourceEffect=ids["B"..b]
        else
            pendingRefund={
                beforeCast=beforeCast,
                casts=1,
                cost=cost,
                delay=REFUND_DELAY,
                refund=refund,
                sourceEffect=ids["B"..b],
            }
        end
        trace:finish("refund queued for delayed reconciliation",{
            batchBeforeCast=pendingRefund.beforeCast,
            batchCasts=pendingRefund.casts,
            batchCost=pendingRefund.cost,
            batchRefund=pendingRefund.refund,
            delay=pendingRefund.delay,
            observedAfterCast=observedAfterCast,
        })
    end,
})

--- Resolves Alteration refunds after other cast-refund mechanics have had a
--- few frames to run. The batch can restore only Magicka still missing from
--- the player's pre-cast total, so combined refunds cannot generate Magicka.
local function updatePendingRefund(dt)
    if not pendingRefund then return end
    pendingRefund.delay=pendingRefund.delay-dt
    if pendingRefund.delay>0 then return end

    local batch=pendingRefund
    pendingRefund=nil
    local trace=SkillDebug.beginTrace(
        "alteration",
        "Reduced Casting Cost",
        "delayed refund reconciliation",
        {
            beforeCast=batch.beforeCast,
            casts=batch.casts,
            totalCost=batch.cost,
            requestedRefund=batch.refund,
        }
    )
    local magicka=types.Actor.stats.dynamic.magicka(self)
    local current=tonumber(magicka.current) or 0
    local maximum=math.max(
        0,
        (tonumber(magicka.base) or 0)+(tonumber(magicka.modifier) or 0)
    )
    local ceiling=math.min(maximum,math.max(0,batch.beforeCast))
    local expectedAfterCosts=math.max(0,batch.beforeCast-batch.cost)
    local otherRefunds=math.max(0,current-expectedAfterCosts)
    local unrestoredCost=math.max(0,batch.cost-otherRefunds)
    local preCastHeadroom=math.max(0,ceiling-current)
    local allowed=math.min(batch.refund,unrestoredCost,preCastHeadroom)
    trace:step("other refunds reconciled",{
        allowedRefund=allowed,
        current=current,
        expectedAfterCosts=expectedAfterCosts,
        maximum=maximum,
        otherRefunds=otherRefunds,
        preCastCeiling=ceiling,
        preCastHeadroom=preCastHeadroom,
        unrestoredCost=unrestoredCost,
    })
    local resolved=Common.restoreResource(
        self,
        "magicka",
        allowed,
        batch.sourceEffect
    )
    local observed=types.Actor.stats.dynamic.magicka(self).current
    trace:finish("delayed Magicka refund delivered",{
        observedAfter=observed,
        observedGain=(tonumber(observed) or current)-current,
        requested=allowed,
        resolved=resolved,
        suppressed=math.max(0,batch.refund-allowed),
    })
end

--- Sends one observed Burden landing to the target-authoritative acceptance
--- gate shared with the generic landed-spell route.
--- @param target GameObject
--- @param effect table Burden active effect.
--- @param source string Diagnostic detection route.
local function requestCounterweight(target,effect,source)
    local duration=math.max(
        1,
        tonumber(effect.durationLeft) or tonumber(effect.duration) or 1
    )
    local burdenMagnitude=tonumber(effect.magnitudeThisFrame)
        or tonumber(effect.magnitude)
        or tonumber(effect.maxMagnitude)
        or tonumber(effect.minMagnitude)
        or 1
    local magnitude=math.max(1,math.floor(burdenMagnitude*0.5))
    target:sendEvent("SPerks_AlterationSetCounterweight",{
        amount=magnitude,caster=self,duration=duration,
        expiresAt=core.getSimulationTime()+duration,
    })
    lastCounterweight=string.format(
        "Acceptance requested via %s: target=%s burden=%s drain=%s duration=%ss.",
        tostring(source),SkillDebug.objectId(target),
        SkillDebug.number(burdenMagnitude),SkillDebug.number(magnitude),
        SkillDebug.number(duration)
    )
    SkillDebug.traceEvent("alteration","Counterweight landing observed",{
        burdenMagnitude=burdenMagnitude,detection=source,duration=duration,
        expectedDrain=magnitude,target=SkillDebug.objectId(target),
    })
end

local function onSpellLanded(data)
    lastCounterweight=string.format(
        "Target-local Burden landing received: spell=%s target=%s.",
        tostring(data and data.spellId),
        data and SkillDebug.objectId(data.target) or "nil"
    )
    local trace=SkillDebug.beginTrace("alteration","Crushing Burden","landed magic-effect event",{
        spell = data and data.spellId,
        target = data and SkillDebug.objectId(data.target),
    })
    local a=rank("A")
    if a < 3 then return trace:reject("A3 is not owned",{aRank=a}) end
    if not data or not data.target or not data.target:isValid() then
        return trace:reject("target is missing or unavailable")
    end
    if not Common.isPlayerCastLandedSpell(data) then
        return trace:reject("source is not an allowed player-cast spell")
    end
    for _, effect in ipairs(data.effects or {}) do
        if effect.id == "burden" then
            requestCounterweight(data.target,effect,"generic landed-spell bridge")
            return trace:finish("Counterweight acceptance requested",{
                target=SkillDebug.objectId(data.target),
            })
        end
    end
    trace:reject("landed spell contains no Burden effect")
end

local SHIELDS = {
    shield = "damagehealth",
    fireshield = "firedamage",
    frostshield = "frostdamage",
    lightningshield = "shockdamage",
}

local function accrueForce(attack)
    local trace=SkillDebug.beginTrace("alteration","Kinetic Shell storage","incoming hit",{
        attacker=attack and SkillDebug.objectId(attack.attacker),
        damage = attack and attack.damage and attack.damage.health,
    })
    local d=rank("D")
    if d == 0 then return trace:reject("D chain inactive") end
    if attack.attacker == self then return trace:reject("hit is self-authored") end
    if not attack.damage then return trace:reject("hit has no damage payload") end
    if attack.target and attack.target ~= self then return trace:reject("player is not the target") end
    local lost = math.max(0, tonumber(attack.damage.health) or 0)
    if lost <= 0 then return trace:reject("hit dealt no Health damage") end
    local totalGain=0
    local shieldEffects,shieldDiagnostics=Common.playerSpellEffectSnapshot(self,{
        "shield","fireshield","frostshield","lightningshield",
    })
    for effectId in pairs(SHIELDS) do
        local magnitude=math.max(
            0,
            shieldEffects[effectId] and shieldEffects[effectId].magnitude or 0
        )
        if magnitude > 0 then
            local gain = math.floor(lost * magnitude / 100) * 2
            pools[effectId] = math.min(magnitude, pools[effectId] + gain)
            if gain > 0 then expiry[effectId] = core.getSimulationTime() + 60 end
            totalGain=totalGain+gain
            trace:step("shield pool resolved",{
                effect=effectId,gain=gain,magnitude=magnitude,pool=pools[effectId],
            })
        end
    end
    if totalGain<=0 then
        return trace:reject("no qualifying player-cast Shield effect",shieldDiagnostics)
    end
    trace:finish("force stored",{
        totalGain=totalGain,
        qualifyingSpells=shieldDiagnostics.qualifyingSpells,
        scannedSpells=shieldDiagnostics.scannedSpells,
    })
end

local function dischargeForce(attack)
    local trace=SkillDebug.beginTrace("alteration","Kinetic Shell discharge","outgoing hit",{
        successful = attack and attack.successful,
    })
    local d = rank("D")
    if d == 0 then return trace:reject("D chain inactive") end
    if attack.attacker ~= self then return trace:reject("player is not attacker") end
    if attack.successful == false then return trace:reject("attack was unsuccessful") end
    local target = attack.target or attack.victim or attack.defender
    if not target or not target:isValid() then return trace:reject("target unavailable") end
    local total = 0
    for _, value in pairs(pools) do total = total + value end
    if total < 10 then return trace:reject("stored force is below discharge threshold",{total=total}) end

    local multiplier = d == 2 and 3 or 2
    local spendScale = 1
    if d == 2 then
        local health = types.Actor.stats.dynamic.health(target)
        spendScale = math.min(1, math.max(0.05, (health.current or 1) / math.max(total * multiplier, 1)))
    end
    trace:step("discharge scale calculated",{
        dRank=d,multiplier=multiplier,spendScale=spendScale,totalStored=total,
    })

    local physical = pools.shield * spendScale
    if attack.damage then
        attack.damage.health = (attack.damage.health or 0) + physical * multiplier
    end
    local spellEffects = {}
    for effectId, damageId in pairs(SHIELDS) do
        if effectId ~= "shield" and pools[effectId] > 0 then
            table.insert(spellEffects, {
                id=damageId, magnitudeMin=pools[effectId] * spendScale * multiplier,
                duration=1,
            })
        end
        pools[effectId] = pools[effectId] * (1 - spendScale)
        if pools[effectId] < 0.01 then pools[effectId] = 0 end
    end
    pools.shield = pools.shield * (1 - spendScale)
    if pools.shield < 0.01 then pools.shield = 0 end
    Common.applyDynamicSpell(target, self, "Kinetic Shell", spellEffects)
    trace:finish("damage added and elemental spell queued",{
        elementalEffects=#spellEffects,physicalAdded=physical*multiplier,
        remainingPools=pools,
    })
end

interfaces.ErnPerkFramework.registerOnHitHandler({
    id="SkillPerks_alteration_kinetic_shell", priority=625,
    handler=function(attack)
        accrueForce(attack)
        dischargeForce(attack)
    end,
})

local function refresh()
    refreshPairedEffects()
    refreshSteadyFooting()
end

local function clear()
    effects.clearAll()
    legacyPairedStats.clearAll()
    effortlessSwimmingActive = false
    lightStepActive = false
    previousFatigue = types.Actor.stats.dynamic.fatigue(self).current
    wasJumpPressed = false
    jumpRefundPending = nil
    lastFatigueReduction = nil
    pairingDiagnostics = {}
    pools, expiry = {shield=0,fireshield=0,frostshield=0,lightningshield=0}, {}
    pendingRefund = nil
end

--- Records the target-local Counterweight result. Core 0 applies and owns the
--- timed Strength modifier directly, so no permanent dynamic spell record is
--- created for this rider.
--- @param data table|nil Accepted target, magnitude, and duration.
local function applyAcceptedCounterweight(data)
    local target=data and data.target
    if not target or not target:isValid() then
        lastCounterweight="Acceptance failed: target is unavailable."
        return
    end
    local amount=math.max(1,math.floor(tonumber(data.amount) or 1))
    local duration=math.max(1,tonumber(data.duration) or 1)
    lastCounterweight=string.format(
        "Direct modifier applied: target=%s Drain Strength=%s duration=%ss.",
        SkillDebug.objectId(target),SkillDebug.number(amount),
        SkillDebug.number(duration)
    )
end

local function onUpdate(dt)
    updatePendingRefund(dt)
    updateTimer = updateTimer - dt
    if updateTimer <= 0 then
        updateTimer = PAIRING_POLL_INTERVAL
        refresh()
        local now = core.getSimulationTime()
        for id, endsAt in pairs(expiry) do
            if now >= endsAt then pools[id], expiry[id] = 0, nil end
        end
    end
    updateMovementFatigueReduction(dt)
end

-- Exposes stored Kinetic Shell force and timed Alteration rider effects.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Alteration",
    skillId = "alteration",
    actor = self,
    ids = ids,
    commands = { "luaalteration debug", "luaalt debug" },
    snapshot = function()
        return {
            string.format(
                "Kinetic pools: shield=%s fire=%s frost=%s shock=%s",
                SkillDebug.number(pools.shield),
                SkillDebug.number(pools.fireshield),
                SkillDebug.number(pools.frostshield),
                SkillDebug.number(pools.lightningshield)
            ),
            string.format(
                "Movement pairings: swimming=%s lightStep=%s jumpPending=%s reduction=%s",
                tostring(effortlessSwimmingActive),
                tostring(lightStepActive),
                tostring(jumpRefundPending ~= nil),
                SkillDebug.number(MOVEMENT_FATIGUE_REDUCTION)
            ),
            string.format(
                "Active pairings: SwiftSwim=%s WaterBreathing=%s NightEyeBonus=%s Jump=%s Feather=%s FeatherBonus=%s Levitate=%s ParalysisResist=%s spells=%s/%s",
                SkillDebug.number(pairingDiagnostics.swift),
                tostring(pairingDiagnostics.breathing == true),
                SkillDebug.number(pairingDiagnostics.nightEyeBonus),
                SkillDebug.number(pairingDiagnostics.jump),
                SkillDebug.number(pairingDiagnostics.feather),
                SkillDebug.number(pairingDiagnostics.featherBonus),
                SkillDebug.number(pairingDiagnostics.levitate),
                SkillDebug.number(pairingDiagnostics.paralysisResist),
                SkillDebug.number(pairingDiagnostics.qualifyingSpells),
                SkillDebug.number(pairingDiagnostics.scannedSpells)
            ),
            "Water Breathing source: "..waterBreathingSourceSummary(),
            "Last Counterweight: "..lastCounterweight,
            "Counterweight detection: Core 0 observes only the actor actually carrying Burden.",
            lastFatigueReduction and string.format(
                "Last Fatigue reduction: kind=%s spent=%s requested=%s resolved=%s observed=%s",
                tostring(lastFatigueReduction.kind),
                SkillDebug.number(lastFatigueReduction.spent),
                SkillDebug.number(lastFatigueReduction.requested),
                SkillDebug.number(lastFatigueReduction.resolved),
                SkillDebug.number(lastFatigueReduction.observed)
            ) or "Last Fatigue reduction: none",
            string.format("Timed riders=%d updateTimer=%s", SkillDebug.count(expiry), SkillDebug.number(updateTimer)),
            pendingRefund and string.format(
                "Pending refund: casts=%d cost=%s requested=%s delay=%s beforeCast=%s",
                pendingRefund.casts,
                SkillDebug.number(pendingRefund.cost),
                SkillDebug.number(pendingRefund.refund),
                SkillDebug.number(pendingRefund.delay),
                SkillDebug.number(pendingRefund.beforeCast)
            ) or "Pending refund: none",
        }
    end,
})

Common.registerMagicPerks("alteration", "Alteration", ids, {
    A1={localizedName="Effortless Casting",localizedFlavour="Water yields to the mage who has stopped struggling against it.",localizedDescription="While player-cast Swift Swim is active, swimming costs 50% less Fatigue. Player-cast Water Breathing also grants 25 Night-Eye.",onAdd=refresh,onRemove=clear},
    A2={localizedName="Light Step",localizedFlavour="The earth receives you gently because you have learned how little of yourself to give it.",localizedDescription="While player-cast Jump is active, jumping costs 50% less Fatigue.",onAdd=refresh,onRemove=clear},
    A3={localizedName="Counterweight",localizedFlavour="Weight is only an argument between forces, and you have learned to answer.",localizedDescription="Player-cast Feather negates equal Burden. Burden cast on another actor also applies non-stacking Drain Strength equal to half its magnitude for the same duration.",onAdd=refresh,onRemove=clear},
    A4={localizedName="Unbound Motion",localizedFlavour="Once the ground has released you, no lesser force may command your limbs.",localizedDescription="Player-cast Levitate grants complete Paralysis immunity.",onAdd=refresh,onRemove=clear},
    B1={localizedName="Reduced Casting Cost",localizedFlavour="The practiced hand wastes no magicka proving what it already knows.",localizedDescription="Refund up to 15% of Alteration spell cost after other refunds; casts costing under 10 after reduction become free.",onRemove=clear},
    B2={localizedName="Second Nature",localizedFlavour="Utility becomes instinct, and instinct asks no payment for ordinary miracles.",localizedDescription="Refund rises to 30%; casts costing under 25 after reduction become free. Combined refunds cannot exceed the spell's cost.",onRemove=clear},
    C1={localizedName="Steady Footing",localizedFlavour="A quiet field braces every stance and stills every uncertain syllable.",localizedDescription="-5 Sound and enough Shield to maintain at least 35 Armor Rating.",onAdd=refresh,onRemove=clear},
    C2={localizedName="Immovable Principle",localizedFlavour="Armor may crack and footing may fail, but the law holding you upright does not.",localizedDescription="-10 Sound and enough Shield to maintain at least 60 Armor Rating.",onAdd=refresh,onRemove=clear},
    D1={localizedName="Kinetic Shell",localizedFlavour="Every ward remembers the violence it denied.",localizedDescription="Player-cast Shield effects store force from incoming damage and discharge it at double strength on your next successful weapon hit.",onRemove=clear},
    D2={localizedName="Law of Impact",localizedFlavour="You return no more force than death requires. Anything beyond that remains yours.",localizedDescription="Kinetic Shell discharges at triple strength and preserves force beyond what should be needed for a lethal blow.",onRemove=clear},
})

return {
    eventHandlers={
        SPerks_AlterationBurdenLanded=onSpellLanded,
        SPerks_AlterationCounterweightAccepted=applyAcceptedCounterweight,
    },
    engineHandlers={
        onConsoleCommand=onConsoleCommand,
        onUpdate=onUpdate,
        onSave=function()
            return {
                effects=effects.snapshot(),
                pools=pools,
                expiry=expiry,
            }
        end,
        onLoad=function(data)
            effects.restoreAndReverse(data and data.effects)
            -- Remove the maximum-Fatigue modifier saved by the previous
            -- implementation before rebuilding these as cost reductions.
            legacyPairedStats.restoreAndReverse(data and data.pairedStats)
            effortlessSwimmingActive = false
            lightStepActive = false
            previousFatigue = types.Actor.stats.dynamic.fatigue(self).current
            wasJumpPressed = false
            jumpRefundPending = nil
            lastFatigueReduction = nil
            pairingDiagnostics = {}
            pools=(data and data.pools) or {shield=0,fireshield=0,frostshield=0,lightningshield=0}
            expiry=(data and data.expiry) or {}
        end,
    },
}
