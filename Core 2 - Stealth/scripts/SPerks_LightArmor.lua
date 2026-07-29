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
    SPerks_LightArmor.lua

    Light Armor turns missed blows into momentum. Passive evasion is
    equipment-gated through ArmorPoints, while hit/miss reactions are routed
    through ErnPerkFramework's shared on-hit and calculation hooks.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local ArmorPoints = require("scripts.SkillPerks.shared.armor_points")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "lightarmor"
local ids = Common.ids("lightarmor")
local CALCULATION = interfaces.ErnPerkFramework.CALCULATION
local OPERATION = interfaces.ErnPerkFramework.CALCULATION_OPERATION

local effectTracker = StatTracker.newActiveEffectTracker(self)
local statTracker = StatTracker.newStatModTracker(self, "Light Armor Reactive Flow")
local burstTimer = 0
local cDodgeStacks = 0
local dDodgeStacks = 0
local cLockout = 0
local dLockout = 0
local pendingReductionStacks = 0
local pendingReductionRank = 0

local A_SANCTUARY = { [1] = 5, [2] = 10, [3] = 15, [4] = 20 }
local B_SPEED = { [1] = 20, [2] = 35 }
local C_CAP = { [1] = 5, [2] = 8 }
local C_LOCKOUT = { [1] = 10, [2] = 7 }
local D_CAP = { [1] = 5, [2] = 8 }
local D_AGILITY = { [1] = 4, [2] = 6 }

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function mostlyLight()
    return ArmorPoints.isMostly(self, "lightarmor")
end

-- Rebuilds the always-on Sanctuary bonus from current equipment.
local function updateAStats()
    local rank = mostlyLight() and aRank() or 0
    effectTracker.apply("sanctuary", nil, A_SANCTUARY[rank] or 0)
end

local function updateBurst()
    local rank = bRank()
    local value = (burstTimer > 0 and mostlyLight()) and (B_SPEED[rank] or 0) or 0
    statTracker.apply("attributes", "speed", value)
    effectTracker.apply("fortifyattribute", "speed", value)
end

local function updateFlow()
    local rank = dRank()
    local value = (rank > 0 and mostlyLight()) and (dDodgeStacks * D_AGILITY[rank]) or 0
    statTracker.apply("attributes", "agility", value)
    effectTracker.apply("fortifyattribute", "agility", value)
end

local function ownedLightArmorPerks()
    local count = 0
    for _, id in pairs(ids) do
        if Common.hasPerk(id) then
            count = count + 1
        end
    end
    return count
end

-- C-chain damage reduction is resolved in the arithmetic pipeline after the
-- on-hit handler records how many dodge stacks are being spent.
interfaces.ErnPerkFramework.registerCalculationHandler({
    id = ns .. "_lightarmor_dodge_reduction",
    calculation = CALCULATION.HIT_DAMAGE_HEALTH,
    operation = OPERATION.Modifier,
    priority = 360,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
    handler = function(data)
        if pendingReductionStacks <= 0 or pendingReductionRank <= 0 then
            return nil
        end
        local reduction = math.min(0.80, pendingReductionStacks * 0.05)
        pendingReductionStacks = 0
        pendingReductionRank = 0
        return data.value * (1 - reduction)
    end,
})

local function onHit(attack)
    SkillDebug.traceEvent(SKILL_ID, "hit received", {
        healthDamage = attack and attack.damage and attack.damage.health,
        successful = attack and attack.successful,
    })
    if not mostlyLight() then
        return
    end

    if Common.isIncomingAttack(attack, self) then
        if attack.successful == false then
            local rankC = cRank()
            if rankC > 0 and cLockout <= 0 then
                cDodgeStacks = math.min(C_CAP[rankC], cDodgeStacks + 1)
            end
            local rankD = dRank()
            if rankD > 0 and dLockout <= 0 then
                dDodgeStacks = math.min(D_CAP[rankD], dDodgeStacks + 1)
                updateFlow()
            end
            return
        end

        local rankB = bRank()
        if rankB > 0 then
            burstTimer = 3
            updateBurst()
        end

        local rankC = cRank()
        if rankC > 0 and cDodgeStacks > 0 and cLockout <= 0 then
            pendingReductionStacks = cDodgeStacks
            pendingReductionRank = rankC
            cLockout = C_LOCKOUT[rankC]
        end
        if dRank() > 0 and dDodgeStacks > 0 and dLockout <= 0 then
            dLockout = 5
        end
        cDodgeStacks = 0
        dDodgeStacks = 0
        updateFlow()
    end
end

-- Core 0 delivers outgoing hits through the Framework. Apply B2's post-armour
-- bonus through the direct-health pipeline, then consume the burst once.
local routeOutgoingHit = Common.newOutgoingHitRouter(self, function(attack)
    if bRank() < 2 or burstTimer <= 0 or attack.successful ~= true then
        return
    end
    local percent = math.min(0.40, ownedLightArmorPerks() * 0.05)
    Common.applyBonusHealthDamage(
        attack,
        Common.healthDamage(attack) * percent,
        self,
        ids.B2,
        "lightarmor.answeringRush"
    )
    burstTimer = 0
    updateBurst()
end)

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_lightarmor_on_hit",
    priority = 420,
    handler = function(attack)
        onHit(attack)
        routeOutgoingHit(attack, attack.skillPerksHitSource or "framework")
    end,
})

local function clearLightArmorState()
    effectTracker.clearAll()
    statTracker.clearAll()
    burstTimer = 0
    cDodgeStacks = 0
    dDodgeStacks = 0
    cLockout = 0
    dLockout = 0
    pendingReductionStacks = 0
    pendingReductionRank = 0
end

local function onUpdate(dt)
    if burstTimer > 0 then
        burstTimer = math.max(0, burstTimer - dt)
    end
    if cLockout > 0 then
        cLockout = math.max(0, cLockout - dt)
    end
    if dLockout > 0 then
        dLockout = math.max(0, dLockout - dt)
    end
    updateAStats()
    updateBurst()
    updateFlow()
end

local function onSave()
    return {
        effects = effectTracker.snapshot(),
        stats = statTracker.snapshot(),
        burstTimer = burstTimer,
        cDodgeStacks = cDodgeStacks,
        dDodgeStacks = dDodgeStacks,
        cLockout = cLockout,
        dLockout = dLockout,
    }
end

local function onLoad(data)
    data = data or {}
    effectTracker.restoreAndReverse(data.effects)
    statTracker.restoreAndReverse(data.stats)
    burstTimer = data.burstTimer or 0
    -- Older saves used one shared stack counter. Migrating it into both
    -- chains preserves progress while allowing their lockouts to diverge.
    cDodgeStacks = data.cDodgeStacks or data.dodgeStacks or 0
    dDodgeStacks = data.dDodgeStacks or data.dodgeStacks or 0
    cLockout = data.cLockout or 0
    dLockout = data.dLockout or 0
end

-- Reports the reactive burst, both dodge-stack tracks, and pending hit reduction.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Light Armor",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "lualightarmor debug", "luala debug" },
    snapshot = function()
        local points, breakdown = ArmorPoints.getPoints(self)
        return {
            string.format(
                "Armor: points=%s equippedPieces=%d",
                SkillDebug.number(points),
                SkillDebug.count(breakdown)
            ),
            string.format(
                "Reactive Step: burst=%s pendingReduction=%d rank=%d",
                SkillDebug.number(burstTimer),
                pendingReductionStacks,
                pendingReductionRank
            ),
            string.format(
                "Dodge: C=%d lockout=%s D=%d lockout=%s",
                cDodgeStacks,
                SkillDebug.number(cLockout),
                dDodgeStacks,
                SkillDebug.number(dLockout)
            ),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Light Armor", ids, {
    A1 = { localizedName = "Evasive", localizedFlavour = "Light armor does not ask you to endure the blow. It teaches you to be where the blow is not.", localizedDescription = "While mostly wearing Light Armor, gain Sanctuary +5.", onAdd = updateAStats, onRemove = clearLightArmorState },
    A2 = { localizedName = "Slip the Line", localizedFlavour = "The attack arrives with certainty. You answer with absence.", localizedDescription = "Evasive increases to Sanctuary +10.", onAdd = updateAStats, onRemove = clearLightArmorState },
    A3 = { localizedName = "Untouchable Habit", localizedFlavour = "Avoidance stops being a reaction and becomes posture.", localizedDescription = "Evasive increases to Sanctuary +15.", onAdd = updateAStats, onRemove = clearLightArmorState },
    A4 = { localizedName = "Wind-Worn Guard", localizedFlavour = "Armor, breath, and footwork become one clean refusal.", localizedDescription = "Evasive increases to Sanctuary +20.", onAdd = updateAStats, onRemove = clearLightArmorState },
    B1 = { localizedName = "Reactive Step", localizedFlavour = "A landed blow becomes borrowed momentum. You are already leaving before they recover.", localizedDescription = "Taking a hit while mostly wearing Light Armor grants +20 Speed for 3 seconds.", onRemove = clearLightArmorState },
    B2 = { localizedName = "Answering Rush", localizedFlavour = "Your retreat snaps into offence, all speed and sudden steel.", localizedDescription = "The speed burst rises to +35. Your next attack during the burst deals +5% damage per owned Light Armor perk, capped at +40%.", onRemove = clearLightArmorState },
    C1 = { localizedName = "Dodge Mastery", localizedFlavour = "Every miss teaches your body the shape of the next danger.", localizedDescription = "Each incoming miss adds a dodge stack. Your next hit taken is reduced by 5% per stack, up to 5 stacks. 10 second lockout after use.", onRemove = clearLightArmorState },
    C2 = { localizedName = "Blurred Recovery", localizedFlavour = "The enemy keeps correcting their aim. You keep correcting faster.", localizedDescription = "Dodge stack cap rises to 8 and the lockout drops to 7 seconds.", onRemove = clearLightArmorState },
    D1 = { localizedName = "Flow State", localizedFlavour = "A missed blow feeds the rhythm in your limbs until movement itself becomes defence.", localizedDescription = "Each incoming miss grants +4 Agility per dodge stack while held. Stacks are consumed when hit. 5 second lockout.", onRemove = clearLightArmorState },
    D2 = { localizedName = "Living Current", localizedFlavour = "You stop dodging as separate motions. The whole fight becomes a current around you.", localizedDescription = "Flow State grants +6 Agility per stack and the stack cap rises to 8.", onRemove = clearLightArmorState },
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
