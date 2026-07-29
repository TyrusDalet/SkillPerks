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
    SPerks_LongBlade.lua

    Long Blade - "Tempo fighter. Builds pressure through sustained
    engagement, rewards composure under fire." Momentum and Poise live as
    local player state; actual health-damage changes are resolved through
    ErnPerkFramework's calculation pipeline so other mods can share the
    final hit-damage value.

    CHARGE DETECTION NOTE: this follows Blunt's current attack.strength
    adapter. If later in-game testing proves animation text keys are more
    reliable for every weapon group, only getChargeRatio() needs changing.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local core       = require("openmw.core")
local ambient    = require("openmw.ambient")
local animation  = require("openmw.animation")
local async      = require("openmw.async")
local ui         = require("openmw.ui")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local CombatMath         = require("scripts.SkillPerks.shared.combat_math")
local StatTracker        = require("scripts.SkillPerks.shared.stat_tracker")
local LongBladeHud       = require("scripts.SkillPerks.hud.longblade")
local settings           = require("scripts.SkillPerks.Settings.settings")
local SkillDebug         = require("scripts.SkillPerks.shared.debug")
local SharedHit          = require("scripts.SkillPerks.shared.hit")

settings.registerLongBladeHudSettings()

local SKILL_ID = "longblade"

local ids = {
    A1 = ns .. "_longblade_a1",
    A2 = ns .. "_longblade_a2",
    A3 = ns .. "_longblade_a3",
    A4 = ns .. "_longblade_a4",
    B1 = ns .. "_longblade_b1",
    B2 = ns .. "_longblade_b2",
    C1 = ns .. "_longblade_c1",
    C2 = ns .. "_longblade_c2",
    D1 = ns .. "_longblade_d1",
    D2 = ns .. "_longblade_d2",
}

local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local function getARank()
    if hasPerk(ids.A4) then return 4
    elseif hasPerk(ids.A3) then return 3
    elseif hasPerk(ids.A2) then return 2
    elseif hasPerk(ids.A1) then return 1
    else return 0 end
end

local function getBRank()
    if hasPerk(ids.B2) then return 2
    elseif hasPerk(ids.B1) then return 1
    else return 0 end
end

local function getCRank()
    if hasPerk(ids.C2) then return 2
    elseif hasPerk(ids.C1) then return 1
    else return 0 end
end

local function getDRank()
    if hasPerk(ids.D2) then return 2
    elseif hasPerk(ids.D1) then return 1
    else return 0 end
end

local function noPersistentEffect() end

-- ============================================================
--  SHARED HIT HELPERS
-- ============================================================

local LONG_BLADE_TYPES = {
    [types.Weapon.TYPE.LongBladeOneHand] = true,
    [types.Weapon.TYPE.LongBladeTwoHand] = true,
}

local LONG_BLADE_ANIMATION_GROUPS = {
    [types.Weapon.TYPE.LongBladeOneHand] = "weapononehand",
    [types.Weapon.TYPE.LongBladeTwoHand] = "weapontwohand",
}

local COUNTER_ATTACK_KEYS = {
    { start = "chop start",   stop = "chop hit"   },
    { start = "slash start",  stop = "slash hit"  },
    { start = "thrust start", stop = "thrust hit" },
}

local CHARGED_THRESHOLD = 0.95
local MOMENTUM_TIMER = 8
local POISE_DELAY = 4
local OVERDRIVE_TIMER = 15
local RIPOSTE_COOLDOWN = 3
local RIPOSTE_HIT_SOUND_DELAY = 0.2

local A_MOMENTUM_CAP = { [1] = 3, [2] = 3, [3] = 8, [4] = 8 }
local C_MOMENTUM_CAP = { [1] = 1, [2] = 4 }

local momentumStacks = 0
local momentumTimer = 0
local momentumKind = "longblade"
local equippedMomentumKind = nil
local observedMomentumWeapon = false
local observedCRank = -1
local lastHitTime = -9999
local overdriveTimer = 0
local riposteCooldown = 0
local lastHitDebug = nil
local reportedPoiseBonus = nil

local poiseTracker = StatTracker.newStatModTracker(self)

local function getAttackTarget(attack)
    return attack.target or attack.victim or attack.defender
end

local function attackDealtHealthDamage(attack)
    return attack
        and attack.successful == true
        and attack.damage
        and type(attack.damage.health) == "number"
        and attack.damage.health > 0
end

local function getWeaponFromAttack(attack)
    if attack and attack.weapon and types.Weapon.objectIsInstance(attack.weapon) then
        return attack.weapon
    end
    return types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
end

local function getWeaponRecord(attack)
    local weapon = getWeaponFromAttack(attack)
    if not weapon or not types.Weapon.objectIsInstance(weapon) then
        return nil
    end
    return types.Weapon.record(weapon)
end

local function isLongBladeWeapon(weapon)
    if not weapon or not types.Weapon.objectIsInstance(weapon) then
        return false
    end
    return LONG_BLADE_TYPES[types.Weapon.record(weapon).type] == true
end

local function playCounterAttackAnimation(weapon)
    local controller = interfaces.AnimationController
    if not controller or not controller.playBlendedAnimation then
        return
    end
    if not isLongBladeWeapon(weapon) then
        return
    end

    local group = LONG_BLADE_ANIMATION_GROUPS[types.Weapon.record(weapon).type]
    if not group then
        return
    end

    local keys = COUNTER_ATTACK_KEYS[math.random(#COUNTER_ATTACK_KEYS)]
    local ok, err = pcall(controller.playBlendedAnimation, group, {
        startKey = keys.start,
        stopKey = keys.stop,
        priority = animation.PRIORITY.Weapon,
        blendMask = animation.BLEND_MASK.UpperBody,
        autoDisable = true,
        speed = 1.35,
    })
    if not ok then
        print("Long Blade counter animation failed: " .. tostring(err))
    end
end

local function isPlayerAttack(attack)
    return SharedHit.isPlayerAttack(attack, self)
end

local function isIncomingAttackAgainstPlayer(attack)
    if not attack.attacker or not attack.attacker:isValid() then
        return false
    end
    if attack.attacker == self then
        return false
    end
    local target = getAttackTarget(attack)
    if target and target ~= self then
        return false
    end
    return true
end

local function getChargeRatio(attack)
    local strength = attack.strength
    if type(strength) ~= "number" then
        return 0
    end
    if strength > 1 then
        strength = strength / 100
    end
    return math.max(0, math.min(strength, 1))
end

local function isChargedAttack(attack)
    return getChargeRatio(attack) >= CHARGED_THRESHOLD
end

local getMomentumCap

local function describeAttackForDebug(attack, kind)
    local weaponRecord = getWeaponRecord(attack)
    local target = getAttackTarget(attack)
    return {
        attackerIsPlayer = attack.attacker == nil or isPlayerAttack(attack),
        successful = attack.successful,
        sourceType = attack.sourceType,
        weaponId = weaponRecord and weaponRecord.id or nil,
        weaponType = weaponRecord and weaponRecord.type or nil,
        momentumKind = kind,
        strengthRaw = attack.strength,
        chargeRatio = getChargeRatio(attack),
        charged = isChargedAttack(attack),
        targetId = target and target.id or nil,
        arank = getARank(),
        crank = getCRank(),
        cap = getMomentumCap(kind or momentumKind),
        stacks = momentumStacks,
    }
end

--- Explains why a seen player hit did not grant Momentum.
--- @param attack table OpenMW combat hit payload.
--- @param kind string|nil Momentum weapon kind.
--- @param criticalLanded boolean Whether B-chain crit logic fired.
--- @return string|nil reason Nil means Momentum should be granted.
local function momentumBlockReason(attack, kind, criticalLanded)
    if not kind then
        return "weapon not eligible"
    end
    if getMomentumCap(kind) <= 0 then
        return "momentum cap is 0"
    end
    if attack.successful ~= true then
        return "hit was not successful"
    end
    if not isChargedAttack(attack) and not criticalLanded then
        return "hit was not charged and did not crit"
    end
    return nil
end

local function isAllowedMomentumWeapon(attack)
    local record = getWeaponRecord(attack)
    if not record then
        return nil
    end
    if LONG_BLADE_TYPES[record.type] then
        return "longblade"
    end
    if getCRank() > 0 then
        return "other"
    end
    return nil
end

local function getWeaponDamage(weapon)
    local record = types.Weapon.record(weapon)
    return math.max(
        (record.chopMinDamage + record.chopMaxDamage) / 2,
        (record.slashMinDamage + record.slashMaxDamage) / 2,
        (record.thrustMinDamage + record.thrustMaxDamage) / 2
    )
end

local function getTargetArmorRating(target)
    if types.NPC.objectIsInstance(target) then
        return CombatMath.getArmorRating(target)
    end
    return 0
end

-- ============================================================
--  MOMENTUM / POISE STATE
-- ============================================================

local hasPoise

getMomentumCap = function(kind)
    if kind == "other" then
        return C_MOMENTUM_CAP[getCRank()] or 0
    end
    return A_MOMENTUM_CAP[getARank()] or 0
end

local function getHudState()
    local displayKind = equippedMomentumKind or momentumKind
    return {
        enabled = getARank() > 0 and equippedMomentumKind ~= nil,
        current = momentumStacks,
        max = getMomentumCap(displayKind),
        poise = hasPoise(),
        overdrive = overdriveTimer,
    }
end

local function isAtMomentumCap()
    return momentumStacks > 0 and momentumStacks >= getMomentumCap(momentumKind)
end

local function addMomentum(amount, kind)
    local cap = getMomentumCap(kind)
    if cap <= 0 then
        return
    end
    if momentumKind ~= kind then
        momentumStacks = 0
        momentumKind = kind
    end
    equippedMomentumKind = kind
    momentumStacks = math.min(cap, momentumStacks + amount)
    momentumTimer = MOMENTUM_TIMER
end

local function setMomentum(value)
    momentumStacks = math.max(0, math.min(value, getMomentumCap(momentumKind)))
    momentumTimer = momentumStacks > 0 and MOMENTUM_TIMER or 0
end

--- Classifies the readied weapon into the Momentum profile that can currently
--- use it. C-chain perks admit all other weapon records, while unarmed and
--- non-weapon equipment cannot carry Long Blade Momentum.
local function getEquippedMomentumKind(weapon, cRank)
    if isLongBladeWeapon(weapon) then
        return "longblade"
    end
    if weapon and types.Weapon.objectIsInstance(weapon) and cRank > 0 then
        return "other"
    end
    return nil
end

--- Reconciles Momentum as soon as equipment or the C-chain rank changes.
--- Switching between the Long Blade and transferred-form profiles follows the
--- same reset rule already used when a hit changes `momentumKind`; changing to
--- another weapon within the same profile preserves the current stacks.
local function syncMomentumKindWithEquipment(force)
    local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    local cRank = getCRank()
    if not force and weapon == observedMomentumWeapon and cRank == observedCRank then
        return false
    end
    observedMomentumWeapon = weapon
    observedCRank = cRank

    local nextKind = getEquippedMomentumKind(weapon, cRank)
    equippedMomentumKind = nextKind
    if nextKind == nil then
        setMomentum(0)
    elseif nextKind ~= momentumKind then
        momentumKind = nextKind
        setMomentum(0)
    else
        -- A respec can lower the current profile's cap without changing its
        -- name, so clamp existing stacks against the newly reported rank.
        setMomentum(momentumStacks)
    end
    return true
end

hasPoise = function()
    return momentumStacks > 0 and core.getSimulationTime() - lastHitTime >= POISE_DELAY
end

local function getPoiseBonus()
    if not hasPoise() then
        return 0
    end
    if momentumKind == "other" then
        return getCRank() >= 2 and 10 or 5
    end
    return getARank() >= 4 and 20 or 10
end

-- Applies the current Poise agility bonus through StatTracker, so reloads
-- and respecs can reverse exactly the value this file owns. The same value
-- is reported through ErnPerkFramework's external modifier registry so AAM
-- can show Poise as an explained modifier instead of a silent stat change.
local function updatePoiseBonus()
    local bonus = getPoiseBonus()
    poiseTracker.apply("attributes", "agility", bonus)
    if reportedPoiseBonus == bonus then
        return
    end
    reportedPoiseBonus = bonus
    if bonus > 0 then
        interfaces.ErnPerkFramework.reportExternalModifiers("Long Blade Poise", {
            attributes = { agility = bonus },
        })
    else
        interfaces.ErnPerkFramework.reportExternalModifiers("Long Blade Poise", nil)
    end
end

local function clearLongBladeState()
    momentumStacks = 0
    momentumTimer = 0
    overdriveTimer = 0
    riposteCooldown = 0
    poiseTracker.clearAll()
    reportedPoiseBonus = nil
    interfaces.ErnPerkFramework.reportExternalModifiers("Long Blade Poise", nil)
    LongBladeHud.forceUpdate(getHudState())
end

-- ============================================================
--  B CHAIN - CRITICAL TEMPO
-- ============================================================

local function maybeStartOverdrive()
    if getBRank() < 2 or overdriveTimer > 0 or not isAtMomentumCap() then
        return
    end
    local spent = math.ceil(momentumStacks / 2)
    setMomentum(momentumStacks - spent)
    overdriveTimer = OVERDRIVE_TIMER
end

local function getCriticalMultiplier(momentumForCrit, options)
    options = options or {}
    local rank = getBRank()
    if rank == 0 then
        return 1, 0, false
    end

    local chance = 0
    if overdriveTimer > 0 then
        chance = 0.20
    else
        local cap = getMomentumCap(momentumKind)
        local stacks = momentumForCrit or momentumStacks
        if cap > 0 and stacks >= cap then
            chance = 0.10
        end
    end

    if chance > 0 and math.random() < chance then
        if options.playSound ~= false then
            ambient.playSound("critical damage")
        end
        return CombatMath.CRIT_MODIFIER.MELEE, chance, true
    end
    return 1, chance, false
end

-- Allows other player-side mods to route direct counterattack damage through
-- Long Blade's own B-chain crit rules without copying its perk/momentum logic.
local function resolveCounterCritical(data)
    data = data or {}
    local amount = data.amount or 0
    if amount <= 0 or not isLongBladeWeapon(data.weapon) then
        return {
            amount = amount,
            criticalChance = 0,
            criticalLanded = false,
        }
    end

    local criticalMultiplier, criticalChance, criticalLanded = getCriticalMultiplier(data.momentumForCrit, {
        playSound = data.playSound ~= false,
    })
    return {
        amount = amount * criticalMultiplier,
        criticalChance = criticalChance,
        criticalLanded = criticalLanded,
    }
end

-- Exposes Riposte priority to other counterattack perks. If this returns true,
-- Long Blade is ready to spend the response window, so other counter systems
-- should yield even if Riposte's own hit roll later misses.
local function willAttemptRiposte(data)
    data = data or {}
    local attacker = data.attacker
    if getDRank() == 0 or riposteCooldown > 0 then
        return false
    end
    if data.attack and not attackDealtHealthDamage(data.attack) then
        return false
    end
    if not attacker or not attacker:isValid() then
        return false
    end
    if not hasPoise() then
        return false
    end
    local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    return isLongBladeWeapon(weapon)
end

-- Applies Momentum and B-chain critical damage from the player-owned hit
-- event. OpenMW delivers outgoing hit callbacks to the target actor, so the
-- target-side Core 0 bridge forwards the resolved hit damage back here.
local function applyMomentumDamageBonus(attack, kind)
    if attack.successful ~= true or not kind then
        return false
    end
    local target = getAttackTarget(attack)
    if not target or not target:isValid() then
        return false
    end
    local baseDamage = attack.damage and attack.damage.health
    if type(baseDamage) ~= "number" or baseDamage <= 0 then
        return false
    end

    local momentumMultiplier = 1 + (momentumStacks * 0.05)
    local criticalMultiplier, criticalChance, criticalLanded = getCriticalMultiplier()
    local finalMultiplier = momentumMultiplier * criticalMultiplier
    local extraDamage = baseDamage * (finalMultiplier - 1)
    if lastHitDebug then
        lastHitDebug.damageBase = baseDamage
        lastHitDebug.momentumMultiplier = momentumMultiplier
        lastHitDebug.criticalChance = criticalChance
        lastHitDebug.criticalLanded = criticalLanded
        lastHitDebug.extraDamage = extraDamage
    end
    if extraDamage <= 0 then
        return criticalLanded
    end

    interfaces.ErnPerkFramework.addHitDamage(attack, "health", extraDamage, {
        source = self,
        sourceEffect = ids.B1,
        context = "longblade.momentum",
    })
    return criticalLanded
end

-- ============================================================
--  D CHAIN - RIPOSTE
-- ============================================================

local function getArmorHitSound(actor)
    local cuirass = types.Actor.getEquipment(actor, types.Actor.EQUIPMENT_SLOT.Cuirass)
    if cuirass and types.Armor.objectIsInstance(cuirass) then
        local weight = types.Armor.record(cuirass).weight
        if weight < 10 then
            return "light armor hit"
        elseif weight < 25 then
            return "medium armor hit"
        else
            return "heavy armor hit"
        end
    end
    return "health damage"
end

local function playRiposteHitSoundDelayed(actor, criticalLanded)
    local armorSound = getArmorHitSound(actor)
    async:newUnsavableSimulationTimer(RIPOSTE_HIT_SOUND_DELAY, function()
        if criticalLanded then
            ambient.playSound("critical damage")
        end
        ambient.playSound(armorSound)
        ambient.playSound("health damage")
    end)
end

local function getRiposteDamage(target, momentumForCrit)
    local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not isLongBladeWeapon(weapon) then
        return 0, 0, false, weapon
    end

    local criticalMultiplier, criticalChance, criticalLanded = getCriticalMultiplier(momentumForCrit, { playSound = false })
    return CombatMath.applyDamageFormula(
        getWeaponDamage(weapon),
        CombatMath.getStrengthModifier(self),
        CombatMath.getConditionModifier(weapon),
        criticalMultiplier,
        getTargetArmorRating(target)
    ), criticalChance, criticalLanded, weapon
end

-- Performs the automatic counter-strike as direct target damage. The hit
-- roll is kept explicit here because Riposte is not a real engine attack.
local function tryRiposte(attacker, momentumForCrit)
    SkillDebug.traceEvent(SKILL_ID, "Riposte check", {
        cooldown = riposteCooldown,
        dRank = getDRank(),
        momentum = momentumForCrit,
        target = SkillDebug.objectId(attacker),
    })
    if getDRank() == 0 or riposteCooldown > 0 or not attacker or not attacker:isValid() then
        return
    end

    local hitChance = math.max(0, math.min(100, CombatMath.getHitChance(self, attacker, SKILL_ID)))
    if math.random(100) > hitChance then
        riposteCooldown = RIPOSTE_COOLDOWN
        SkillDebug.traceEvent(SKILL_ID, "Riposte missed", { hitChance = hitChance })
        return
    end

    local damage, criticalChance, criticalLanded, weapon = getRiposteDamage(attacker, momentumForCrit)
    if damage <= 0 then
        return
    end

    playCounterAttackAnimation(weapon)
    local health = types.Actor.stats.dynamic.health(attacker)
    local predictedKill = health.current <= damage
    attacker:sendEvent("SPerks_TakeDamage", {
        amount = damage,
        source = self,
        sourceEffect = ids.D1,
        context = "longblade.riposte",
    })
    playRiposteHitSoundDelayed(attacker, criticalLanded)

    addMomentum(getDRank() >= 2 and predictedKill and 3 or 1, "longblade")
    riposteCooldown = RIPOSTE_COOLDOWN
    lastHitDebug = {
        kind = "riposte",
        damageBase = damage,
        criticalChance = criticalChance,
        criticalLanded = criticalLanded,
        stacksBefore = momentumForCrit or momentumStacks,
        stacksAfter = momentumStacks,
    }
    SkillDebug.traceEvent(SKILL_ID, "Riposte landed", lastHitDebug)
    LongBladeHud.forceUpdate(getHudState())
end

-- ============================================================
--  SHARED HIT HANDLER
-- ============================================================

local function handleOutgoingPlayerHit(attack, source)
    local kind = isAllowedMomentumWeapon(attack)
    lastHitDebug = describeAttackForDebug(attack, kind)
    lastHitDebug.source = source or "direct"
    local criticalLanded = applyMomentumDamageBonus(attack, kind)
    local blockReason = momentumBlockReason(attack, kind, criticalLanded)
    lastHitDebug.blockReason = blockReason
    if not blockReason then
        addMomentum(1, kind)
        lastHitDebug.stacksAfter = momentumStacks
        maybeStartOverdrive()
        updatePoiseBonus()
        LongBladeHud.forceUpdate(getHudState())
        SkillDebug.trace(SKILL_ID, function()
            return "Long Blade Momentum gained via " .. tostring(lastHitDebug.source)
                .. ": stacks=" .. tostring(momentumStacks)
                .. " kind=" .. tostring(kind)
        end)
    else
        SkillDebug.trace(SKILL_ID, function()
            return "Long Blade Momentum blocked via " .. tostring(lastHitDebug.source)
                .. ": " .. tostring(blockReason)
                .. " success=" .. tostring(attack.successful)
                .. " strength=" .. tostring(attack.strength)
                .. " ratio=" .. tostring(getChargeRatio(attack))
                .. " kind=" .. tostring(kind)
        end)
    end
end

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_longblade_on_hit",
    handler = function(attack)
        if isPlayerAttack(attack) then
            handleOutgoingPlayerHit(attack, attack.skillPerksHitSource or "framework")
            return
        end

        if not isIncomingAttackAgainstPlayer(attack) then
            return
        end
        if not attackDealtHealthDamage(attack) then
            SkillDebug.trace(SKILL_ID, "SkillPerks longblade [incoming hit]: no health damage, Momentum retained")
            return
        end

        local hadPoise = hasPoise()
        local momentumBeforeHit = momentumStacks
        lastHitTime = core.getSimulationTime()
        if getARank() >= 4 then
            setMomentum(momentumStacks - 3)
        else
            setMomentum(0)
        end
        SkillDebug.traceEvent(SKILL_ID, "incoming damage consumed Momentum", {
            after = momentumStacks,
            before = momentumBeforeHit,
            hadPoise = hadPoise,
        })
        if hadPoise then
            tryRiposte(attack.attacker, momentumBeforeHit)
        end
        updatePoiseBonus()
        LongBladeHud.forceUpdate(getHudState())
    end,
})

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local function onUpdate(dt)
    syncMomentumKindWithEquipment(false)
    if momentumStacks > 0 then
        momentumTimer = momentumTimer - dt
        if momentumTimer <= 0 then
            setMomentum(0)
        end
    end
    if overdriveTimer > 0 then
        overdriveTimer = math.max(0, overdriveTimer - dt)
    end
    if riposteCooldown > 0 then
        riposteCooldown = math.max(0, riposteCooldown - dt)
    end
    updatePoiseBonus()
    LongBladeHud.update(getHudState())
end

local function onSave()
    return {
        momentumStacks = momentumStacks,
        momentumTimer = momentumTimer,
        momentumKind = momentumKind,
        lastHitTime = lastHitTime,
        overdriveTimer = overdriveTimer,
        riposteCooldown = riposteCooldown,
        poiseTracker = poiseTracker.snapshot(),
    }
end

local function onLoad(data)
    poiseTracker.restoreAndReverse(data and data.poiseTracker)
    momentumStacks = data and data.momentumStacks or 0
    momentumTimer = data and data.momentumTimer or 0
    momentumKind = data and data.momentumKind or "longblade"
    lastHitTime = data and data.lastHitTime or -9999
    overdriveTimer = data and data.overdriveTimer or 0
    riposteCooldown = data and data.riposteCooldown or 0
    syncMomentumKindWithEquipment(true)
    LongBladeHud.forceUpdate(getHudState())
end

--- Prints Long Blade debug command output to the visible in-game console.
--- @param message any Text or value to display.
local function consolePrint(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

local function onConsoleCommand(mode, command)
    if SkillDebug.handleTraceCommand({
        name = "Long Blade",
        skillId = SKILL_ID,
        commands = { "lualb debug", "lualongblade debug" },
    }, command) then
        return
    end
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "lualb debug" and command ~= "lualongblade debug" then
        return
    end
    SkillDebug.describe({ name = "Long Blade", skillId = SKILL_ID, actor = self, ids = ids })

    consolePrint("Long Blade Momentum: stacks=" .. tostring(momentumStacks)
        .. " cap=" .. tostring(getMomentumCap(momentumKind))
        .. " kind=" .. tostring(momentumKind)
        .. " timer=" .. tostring(momentumTimer)
        .. " A=" .. tostring(getARank())
        .. " C=" .. tostring(getCRank()))

    if not lastHitDebug then
        consolePrint("Long Blade last hit: none seen by handler.")
        return
    end

    consolePrint("Long Blade last hit:"
        .. " source=" .. tostring(lastHitDebug.source)
        .. " player=" .. tostring(lastHitDebug.attackerIsPlayer)
        .. " success=" .. tostring(lastHitDebug.successful)
        .. " sourceType=" .. tostring(lastHitDebug.sourceType)
        .. " weaponId=" .. tostring(lastHitDebug.weaponId)
        .. " weaponType=" .. tostring(lastHitDebug.weaponType)
        .. " kind=" .. tostring(lastHitDebug.momentumKind)
        .. " strength=" .. tostring(lastHitDebug.strengthRaw)
        .. " ratio=" .. tostring(lastHitDebug.chargeRatio)
        .. " charged=" .. tostring(lastHitDebug.charged)
        .. " cap=" .. tostring(lastHitDebug.cap)
        .. " stacksBefore=" .. tostring(lastHitDebug.stacks)
        .. " stacksAfter=" .. tostring(lastHitDebug.stacksAfter)
        .. " baseDamage=" .. tostring(lastHitDebug.damageBase)
        .. " momentumMult=" .. tostring(lastHitDebug.momentumMultiplier)
        .. " critChance=" .. tostring(lastHitDebug.criticalChance)
        .. " critLanded=" .. tostring(lastHitDebug.criticalLanded)
        .. " extraDamage=" .. tostring(lastHitDebug.extraDamage)
        .. " block=" .. tostring(lastHitDebug.blockReason)
        .. " target=" .. tostring(lastHitDebug.targetId))
end

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Measured Advance",
    category = ChainRequirements.category("Combat", "Long Blade", 1),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "You learn that a duel is not won in one swing. Each charged cut sets the rhythm, and each rhythm asks the enemy to keep up.",
    localizedDescription = "Charged Long Blade hits build Momentum, up to 3 stacks. Each stack grants +5% weapon damage. All Momentum is lost if no attack lands for 8 seconds.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = noPersistentEffect,
    onRemove = clearLongBladeState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Poised Guard",
    category = ChainRequirements.category("Combat", "Long Blade", 2),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "When your blade is moving and your feet are calm, the fight begins to orbit you.",
    localizedDescription = "While you have Momentum and have not been hit for 4 seconds, you gain Poise, granting +10 Agility. Being hit drops Poise and clears Momentum.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = noPersistentEffect,
    onRemove = clearLongBladeState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Driving Tempo",
    category = ChainRequirements.category("Combat", "Long Blade", 3),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "You press the exchange until defence becomes labour. The longer they stand before you, the heavier every answer becomes.",
    localizedDescription = "Momentum cap rises to 8 stacks.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = noPersistentEffect,
    onRemove = clearLongBladeState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Unbroken Line",
    category = ChainRequirements.category("Combat", "Long Blade", 4),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "A lesser stance breaks when struck. Yours bends, answers, and returns to the line before the enemy can claim the moment.",
    localizedDescription = "Poise now grants +20 Agility. Being hit removes 3 Momentum instead of all Momentum, and Poise remains if any stacks survive.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = noPersistentEffect,
    onRemove = clearLongBladeState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Opening Cut",
    category = ChainRequirements.category("Combat", "Long Blade", 5),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "At full tempo, the smallest mistake is suddenly enormous. You see the opening before it becomes visible.",
    localizedDescription = "At maximum Momentum, attacks have a 10% chance to become a critical hit.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Killing Measure",
    category = ChainRequirements.category("Combat", "Long Blade", 6),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "You spend your gathered pressure in a sudden, terrible phrase of steel, each cut carrying the threat of an ending.",
    localizedDescription = "At maximum Momentum, your next qualifying hit consumes half your Momentum to begin a 15 second window where the critical chance doubles to 20%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Transferable Form",
    category = ChainRequirements.category("Combat", "Long Blade", 7),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "The weapon changes. The discipline does not. Even an unfamiliar grip can carry the memory of a clean line.",
    localizedDescription = "Non-Long Blade weapons can build Momentum and Poise, capped at 1 Momentum stack. Their Poise grants +5 Agility.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = noPersistentEffect,
    onRemove = clearLongBladeState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Master's Geometry",
    category = ChainRequirements.category("Combat", "Long Blade", 9),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "You no longer borrow the form. You impose it. Every weapon becomes a line, every line a decision.",
    localizedDescription = "Non-Long Blade Momentum cap rises to 4 stacks, and its Poise bonus rises to +10 Agility.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = noPersistentEffect,
    onRemove = clearLongBladeState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Riposte",
    category = ChainRequirements.category("Combat", "Long Blade", 8),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "Strike you carelessly, and the answer is already waiting. Your blade turns pain into punctuation.",
    localizedDescription = "While Poise is active, being hit attempts an automatic counter-strike using your Long Blade hit chance. If it connects, it deals a fully charged Long Blade strike and grants 1 Momentum. 3 second cooldown.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Answer in Blood",
    category = ChainRequirements.category("Combat", "Long Blade", 10),
    art = "textures\\levelup\\warrior",
    localizedFlavour = "When your riposte ends a life, the whole duel seems to snap back into your hand.",
    localizedDescription = "If Riposte kills its target, it grants 3 Momentum instead of 1.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

return {
    interfaceName = "SkillPerksLongBlade",
    interface = {
        resolveCounterCritical = resolveCounterCritical,
        willAttemptRiposte = willAttemptRiposte,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
