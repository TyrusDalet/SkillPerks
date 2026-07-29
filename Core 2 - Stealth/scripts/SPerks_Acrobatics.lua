--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

--[[ Acrobatics turns height changes into short combat and movement windows. ]]

local types      = require("openmw.types")
local core       = require("openmw.core")
local interfaces = require("openmw.interfaces")
local self       = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local SKILL_ID = "acrobatics"
local ids = Common.ids("acrobatics")
local effectTracker = StatTracker.newActiveEffectTracker(self)
local landingStats = StatTracker.newStatModTracker(self, "Acrobatics Light Landing")
local landingEffects = StatTracker.newActiveEffectTracker(self)
local momentumStats = StatTracker.newStatModTracker(self, "Acrobatics Momentum")
local momentumEffects = StatTracker.newActiveEffectTracker(self)

local wasGrounded = true
local wasJumping = false
local highestZ = self.position.z
local landingBurst = 0
local aerialStrikeWindow = 0
local chameleonTimer = 0
local jumpStacks = 0
local jumpTimer = 0
local previousHealth = types.Actor.stats.dynamic.health(self).current
local recentIncomingDamage = 0
local recentIncomingDamageTime = -9999

local A_REDUCTION = { [1] = 0.20, [2] = 0.40, [3] = 0.60, [4] = 0.80 }
local B_AIR_MULT = { [1] = 1.10, [2] = 1.20 }
local C_CHAMELEON = { [1] = 20, [2] = 35 }
local D_CAP = { [1] = 3, [2] = 5 }

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

-- Updates jump/chameleon bonuses from the D chain's jump momentum stacks.
local function updateMomentumEffects()
    local rank = dRank()
    local cap = D_CAP[rank] or 0
    local jumpBonus = rank > 0 and jumpStacks * 10 or 0
    local speedBonus = rank >= 2 and jumpStacks >= cap and 15 or 0
    effectTracker.apply("jump", nil, jumpBonus)
    momentumStats.apply("attributes", "speed", speedBonus)
    momentumEffects.apply("fortifyattribute", "speed", speedBonus)
end

local function startJumpEffects()
    SkillDebug.traceEvent(SKILL_ID, "jump started", {
        cRank = cRank(),
        dRank = dRank(),
    })
    local rankC = cRank()
    if rankC > 0 then
        chameleonTimer = rankC >= 2 and Common.controlActive(self, "sneak") and 2 or 1
        effectTracker.apply("chameleon", nil, C_CHAMELEON[rankC])
    end

    local rankD = dRank()
    if rankD > 0 then
        jumpStacks = math.min(D_CAP[rankD], jumpStacks + 1)
        jumpTimer = 3
        updateMomentumEffects()
    end
end

--- Applies Acrobatic Strike through the target bridge, using the resolved base
--- hit damage so the bonus retains the engine's armour result.
local function handleOutgoingHit(attack)
    SkillDebug.traceEvent(SKILL_ID, "outgoing hit received", {
        aerialWindow = aerialStrikeWindow,
        onGround = types.Actor.isOnGround(self),
        successful = attack and attack.successful,
    })
    local rank = bRank()
    if rank == 0 or attack.successful ~= true then
        return
    end
    if types.Actor.isOnGround(self) and aerialStrikeWindow <= 0 then
        return
    end
    local multiplier = B_AIR_MULT[rank]
    if rank >= 2 and landingBurst > 0 then
        landingBurst = 0
        multiplier = 1.25
    end
    Common.applyBonusHealthDamage(
        attack,
        Common.healthDamage(attack) * (multiplier - 1),
        self,
        ids["B" .. tostring(rank)],
        "acrobatics.acrobaticStrike")
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, handleOutgoingHit)

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ids.B1 .. "_acrobatics_hit",
    priority = 390,
    handler = function(attack)
        if Common.isIncomingAttack(attack, self) then
            recentIncomingDamage = recentIncomingDamage + Common.healthDamage(attack)
            recentIncomingDamageTime = core.getSimulationTime()
            return
        end
        routeOutgoingHit(attack, attack.skillPerksHitSource or "framework")
    end,
})

local function clearAcrobatics()
    effectTracker.clearAll()
    landingStats.clearAll()
    landingEffects.clearAll()
    momentumStats.clearAll()
    momentumEffects.clearAll()
    landingBurst = 0
    aerialStrikeWindow = 0
    chameleonTimer = 0
    jumpStacks = 0
    jumpTimer = 0
    recentIncomingDamage = 0
end

local function onUpdate(dt)
    local grounded = types.Actor.isOnGround(self)
    local jumping = Common.controlActive(self, "jump")
    highestZ = grounded and self.position.z or math.max(highestZ, self.position.z)

    if jumping and not wasJumping then
        startJumpEffects()
        aerialStrikeWindow = 1.5
    end

    if grounded and not wasGrounded then
        local drop = math.max(0, highestZ - self.position.z)
        local rankA = aRank()
        if rankA > 0 and drop > 250 then
            local currentHealth = types.Actor.stats.dynamic.health(self).current
            local totalLoss = math.max(0, previousHealth - currentHealth)
            local simultaneousHit = core.getSimulationTime() - recentIncomingDamageTime < 0.15
                and recentIncomingDamage or 0
            local estimatedFallDamage = math.max(0, totalLoss - simultaneousHit)
            if estimatedFallDamage > 0 then
                interfaces.ErnPerkFramework.applyActorResourceDelta({
                    actor = self,
                    resource = "health",
                    operation = interfaces.ErnPerkFramework.RESOURCE_OPERATION.Restore,
                    amount = estimatedFallDamage * A_REDUCTION[rankA],
                    source = self,
                    sourceEffect = ids["A" .. tostring(rankA)],
                    context = { reason = "acrobatics.fallReduction", drop = drop },
                })
            end
            if rankA >= 4 then
                landingBurst = 2
                landingStats.apply("attributes", "speed", 20)
                landingEffects.apply("fortifyattribute", "speed", 20)
            end
        end
        if bRank() >= 2 then
            aerialStrikeWindow = 1
        end
        highestZ = self.position.z
    end

    if landingBurst > 0 then
        landingBurst = math.max(0, landingBurst - dt)
        if landingBurst == 0 then
            landingStats.apply("attributes", "speed", 0)
            landingEffects.apply("fortifyattribute", "speed", 0)
        end
    end
    if aerialStrikeWindow > 0 then
        aerialStrikeWindow = math.max(0, aerialStrikeWindow - dt)
    end
    if chameleonTimer > 0 then
        chameleonTimer = math.max(0, chameleonTimer - dt)
        if chameleonTimer == 0 then
            effectTracker.apply("chameleon", nil, 0)
        end
    end
    if jumpTimer > 0 then
        jumpTimer = math.max(0, jumpTimer - dt)
        if jumpTimer == 0 then
            jumpStacks = 0
            updateMomentumEffects()
        end
    end

    wasGrounded = grounded
    wasJumping = jumping
    previousHealth = types.Actor.stats.dynamic.health(self).current
    if core.getSimulationTime() - recentIncomingDamageTime >= 0.15 then
        recentIncomingDamage = 0
    end
end

local function onSave()
    return {
        effects = effectTracker.snapshot(),
        landingStats = landingStats.snapshot(),
        landingEffects = landingEffects.snapshot(),
        momentumStats = momentumStats.snapshot(),
        momentumEffects = momentumEffects.snapshot(),
        landingBurst = landingBurst,
        aerialStrikeWindow = aerialStrikeWindow,
        chameleonTimer = chameleonTimer,
        jumpStacks = jumpStacks,
        jumpTimer = jumpTimer,
    }
end

local function onLoad(data)
    data = data or {}
    effectTracker.restoreAndReverse(data.effects)
    landingStats.restoreAndReverse(data.landingStats)
    landingEffects.restoreAndReverse(data.landingEffects)
    momentumStats.restoreAndReverse(data.momentumStats)
    momentumEffects.restoreAndReverse(data.momentumEffects)
    landingBurst = data.landingBurst or 0
    aerialStrikeWindow = data.aerialStrikeWindow or 0
    chameleonTimer = data.chameleonTimer or 0
    jumpStacks = data.jumpStacks or 0
    jumpTimer = data.jumpTimer or 0
end

-- Shows the movement transitions that gate landing, aerial, and jump effects.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Acrobatics",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luaacrobatics debug", "luaacro debug" },
    snapshot = function()
        return {
            string.format(
                "Movement: grounded=%s jumping=%s highestZ=%s landingBurst=%s aerialWindow=%s",
                tostring(wasGrounded),
                tostring(wasJumping),
                SkillDebug.number(highestZ),
                SkillDebug.number(landingBurst),
                SkillDebug.number(aerialStrikeWindow)
            ),
            string.format(
                "Effects: chameleon=%s jumpStacks=%d jumpTimer=%s recentDamage=%s",
                SkillDebug.number(chameleonTimer),
                jumpStacks,
                SkillDebug.number(jumpTimer),
                SkillDebug.number(recentIncomingDamage)
            ),
        }
    end,
})

Common.registerStealthPerks(SKILL_ID, "Acrobatics", ids, {
    A1 = { localizedName = "Light Landing", localizedFlavour = "You learn to argue with the ground and lose less each time.", localizedDescription = "Reduces fall damage by 20%.", onRemove = clearAcrobatics },
    A2 = { localizedName = "Soft Impact", localizedFlavour = "Stone still wins, but it stops winning cleanly.", localizedDescription = "Light Landing improves to 40% reduced fall damage.", onRemove = clearAcrobatics },
    A3 = { localizedName = "Ground Friend", localizedFlavour = "The landing becomes part of the leap instead of its punishment.", localizedDescription = "Light Landing improves to 60% reduced fall damage.", onRemove = clearAcrobatics },
    A4 = { localizedName = "Rebounding Step", localizedFlavour = "A hard landing becomes a launch, and pain becomes momentum.", localizedDescription = "Light Landing improves to 80% reduced fall damage. Landing from a significant height also grants +20 Speed for 2 seconds.", onRemove = clearAcrobatics },
    B1 = { localizedName = "Acrobatic Strike", localizedFlavour = "A blow from above carries more than steel. It carries the insult of height.", localizedDescription = "Attacks made while jumping or falling deal 10% bonus damage.", onRemove = clearAcrobatics },
    B2 = { localizedName = "Falling Star", localizedFlavour = "You turn descent into impact and impact into decision.", localizedDescription = "Aerial damage rises to 20%. The first attack shortly after landing deals 25% bonus damage instead.", onRemove = clearAcrobatics },
    C1 = { localizedName = "Evasive Roll", localizedFlavour = "You cross the enemy's sightline at the angle where certainty fails.", localizedDescription = "Jumping grants Chameleon 20% for 1 second.", onRemove = clearAcrobatics },
    C2 = { localizedName = "Vanishing Vault", localizedFlavour = "A leap, a shadow, and then the space where you were.", localizedDescription = "Evasive Roll increases to Chameleon 35%. If already sneaking when jumping, it lasts 2 seconds.", onRemove = clearAcrobatics },
    D1 = { localizedName = "Momentum", localizedFlavour = "Each leap remembers the last and dares the next to go higher.", localizedDescription = "Each jump within 3 seconds grants +10 Jump per stack, up to 3 stacks.", onRemove = clearAcrobatics },
    D2 = { localizedName = "Sky-Hungry", localizedFlavour = "The ground becomes a suggestion. You keep refusing it.", localizedDescription = "Momentum stack cap rises to 5. At maximum stacks, gain +15 Speed.", onRemove = clearAcrobatics },
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
