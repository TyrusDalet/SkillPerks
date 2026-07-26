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

local ids = Common.ids("alteration")
local effects = StatTracker.newActiveEffectTracker(self)
local pools = { shield=0, fireshield=0, frostshield=0, lightningshield=0 }
local expiry = {}
local updateTimer = 0

local function rank(chain) return Common.rank(ids, chain) end

-- A-chain pairings remain active only for the lifetime of the corresponding
-- player-cast Alteration effect, so consumables cannot enable them.
local function refreshPairedEffects()
    local a = rank("A")
    local swift = a >= 1 and Common.playerSpellEffectMagnitude(self, "swiftswim") or 0
    local breathing = a >= 1 and Common.playerSpellEffectMagnitude(self, "waterbreathing") or 0
    local jump = a >= 2 and Common.playerSpellEffectMagnitude(self, "jump") or 0
    local feather = a >= 3 and Common.playerSpellEffectMagnitude(self, "feather") or 0
    local burden = math.max(0, Common.getEffectMagnitude(self, "burden"))
    local levitate = a >= 4 and Common.playerSpellEffectMagnitude(self, "levitate") or 0

    effects.apply("fortifyfatigue", nil, (swift > 0 or jump > 0) and 10 or 0)
    effects.apply("nighteye", nil, breathing > 0 and 10 or 0)
    effects.apply("feather", nil, feather > 0 and math.min(feather, burden) or 0)
    effects.apply("resistparalysis", nil, levitate > 0 and 100 or 0)

    -- Jumping has no isolated fatigue-cost hook. A small sustained Fortify
    -- Fatigue provides the intended Light Step benefit without changing the
    -- jump trajectory or duplicating Slowfall.
end

-- Steady Footing measures real equipment AR and contributes only the missing
-- Shield needed to reach its floor. Its own tracked Shield is excluded.
local function refreshSteadyFooting()
    local c = rank("C")
    effects.apply("sound", nil, c == 2 and -10 or c == 1 and -5 or 0)
    if c == 0 then
        effects.apply("shield", nil, 0)
        return
    end
    local floor = c == 2 and 60 or 35
    local natural = CombatMath.getArmorRating(self)
    effects.apply("shield", nil, math.max(0, floor - natural))
end

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id = "SkillPerks_alteration_cast",
    skill = "alteration",
    playerCastOnly = true,
    handler = function(event)
        local b = rank("B")
        if b == 0 then return end
        local cost = math.max(0, tonumber(event.cost) or 0)
        local percent = b == 2 and 0.30 or 0.15
        local refund = math.floor(cost * percent)
        local threshold = b == 2 and 25 or 10
        if cost - refund < threshold then refund = cost end
        Common.restoreResource(self, "magicka", refund, ids["B" .. b])
    end,
})

local function onSpellLanded(data)
    if rank("A") < 3 or not data or not data.target or not data.target:isValid() then return end
    if not Common.isPlayerCastLandedSpell(data) then return end
    for _, effect in ipairs(data.effects or {}) do
        if effect.id == "burden" then
            local duration = math.max(1, tonumber(effect.duration) or 1)
            Common.applyDynamicSpell(data.target, self, "Crushing Burden", {{
                id="drainattribute", affectedAttribute="strength",
                magnitudeMin=math.max(1, math.floor((tonumber(effect.magnitude) or 1) * 0.25)),
                duration=math.min(10, duration),
            }})
            return
        end
    end
end

local SHIELDS = {
    shield = "damagehealth",
    fireshield = "firedamage",
    frostshield = "frostdamage",
    lightningshield = "shockdamage",
}

local function qualifyingShieldMagnitude(effectId)
    return math.max(0, Common.playerSpellEffectMagnitude(self, effectId))
end

local function accrueForce(attack)
    if rank("D") == 0 or attack.attacker == self or not attack.damage then return end
    if attack.target and attack.target ~= self then return end
    local lost = math.max(0, tonumber(attack.damage.health) or 0)
    if lost <= 0 then return end
    for effectId in pairs(SHIELDS) do
        local magnitude = qualifyingShieldMagnitude(effectId)
        if magnitude > 0 then
            local gain = math.floor(lost * magnitude / 100) * 2
            pools[effectId] = math.min(magnitude, pools[effectId] + gain)
            if gain > 0 then expiry[effectId] = core.getSimulationTime() + 60 end
        end
    end
end

local function dischargeForce(attack)
    local d = rank("D")
    if d == 0 or attack.attacker ~= self or attack.successful == false then return end
    local target = attack.target or attack.victim or attack.defender
    if not target or not target:isValid() then return end
    local total = 0
    for _, value in pairs(pools) do total = total + value end
    if total < 10 then return end

    local multiplier = d == 2 and 3 or 2
    local spendScale = 1
    if d == 2 then
        local health = types.Actor.stats.dynamic.health(target)
        spendScale = math.min(1, math.max(0.05, (health.current or 1) / math.max(total * multiplier, 1)))
    end

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
    pools, expiry = {shield=0,fireshield=0,frostshield=0,lightningshield=0}, {}
end

local function onUpdate(dt)
    updateTimer = updateTimer - dt
    if updateTimer > 0 then return end
    updateTimer = 0.2
    refresh()
    local now = core.getSimulationTime()
    for id, endsAt in pairs(expiry) do
        if now >= endsAt then pools[id], expiry[id] = 0, nil end
    end
end

Common.registerMagicPerks("alteration", "Alteration", ids, {
    A1={localizedName="Effortless Casting",localizedFlavour="Water yields to the mage who has stopped struggling against it.",localizedDescription="Player-cast Swift Swim eases exertion; Water Breathing also grants brief Night-Eye.",onAdd=refresh,onRemove=clear},
    A2={localizedName="Light Step",localizedFlavour="The earth receives you gently because you have learned how little of yourself to give it.",localizedDescription="Player-cast Jump also eases the Fatigue spent moving and leaping.",onAdd=refresh,onRemove=clear},
    A3={localizedName="Counterweight",localizedFlavour="Weight is only an argument between forces, and you have learned to answer.",localizedDescription="Player-cast Feather negates equal Burden; Burden cast on others also briefly drains Strength.",onAdd=refresh,onRemove=clear},
    A4={localizedName="Unbound Motion",localizedFlavour="Once the ground has released you, no lesser force may command your limbs.",localizedDescription="Player-cast Levitate grants complete Paralysis immunity.",onAdd=refresh,onRemove=clear},
    B1={localizedName="Reduced Casting Cost",localizedFlavour="The practiced hand wastes no magicka proving what it already knows.",localizedDescription="Refund 15% of Alteration spell cost; casts costing under 10 after reduction become free.",onRemove=clear},
    B2={localizedName="Second Nature",localizedFlavour="Utility becomes instinct, and instinct asks no payment for ordinary miracles.",localizedDescription="Refund rises to 30%; casts costing under 25 after reduction become free.",onRemove=clear},
    C1={localizedName="Steady Footing",localizedFlavour="A quiet field braces every stance and stills every uncertain syllable.",localizedDescription="-5 Sound and enough Shield to maintain at least 35 Armor Rating.",onAdd=refresh,onRemove=clear},
    C2={localizedName="Immovable Principle",localizedFlavour="Armor may crack and footing may fail, but the law holding you upright does not.",localizedDescription="-10 Sound and enough Shield to maintain at least 60 Armor Rating.",onAdd=refresh,onRemove=clear},
    D1={localizedName="Kinetic Shell",localizedFlavour="Every ward remembers the violence it denied.",localizedDescription="Player-cast Shield effects store force from incoming damage and discharge it at double strength on your next successful weapon hit.",onRemove=clear},
    D2={localizedName="Law of Impact",localizedFlavour="You return no more force than death requires. Anything beyond that remains yours.",localizedDescription="Kinetic Shell discharges at triple strength and preserves force beyond what should be needed for a lethal blow.",onRemove=clear},
})

return {
    eventHandlers={ SPerks_MagicEffectLanded=onSpellLanded },
    engineHandlers={
        onUpdate=onUpdate,
        onSave=function() return {effects=effects.snapshot(),pools=pools,expiry=expiry} end,
        onLoad=function(data)
            effects.restoreAndReverse(data and data.effects)
            pools=(data and data.pools) or {shield=0,fireshield=0,frostshield=0,lightningshield=0}
            expiry=(data and data.expiry) or {}
        end,
    },
}
