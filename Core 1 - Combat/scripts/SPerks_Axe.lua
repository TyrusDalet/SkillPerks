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
    SPerks_Axe.lua

    Axe - "Brutal commitment. Destroys equipment, terrorises enemies, and
    exploits damaged armour." Cross-actor item and spell writes are routed
    through Core 0 global handlers, while damage math goes through the
    framework calculation pipeline.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local core       = require("openmw.core")
local nearby     = require("openmw.nearby")
local ui         = require("openmw.ui")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local CombatMath         = require("scripts.SkillPerks.shared.combat_math")
local SkillDebug         = require("scripts.SkillPerks.shared.debug")
local SharedHit          = require("scripts.SkillPerks.shared.hit")

local SKILL_ID = "axe"
local CALCULATION = interfaces.ErnPerkFramework.CALCULATION
local OPERATION = interfaces.ErnPerkFramework.CALCULATION_OPERATION

local ids = {
    A1 = ns .. "_axe_a1",
    A2 = ns .. "_axe_a2",
    A3 = ns .. "_axe_a3",
    A4 = ns .. "_axe_a4",
    B1 = ns .. "_axe_b1",
    B2 = ns .. "_axe_b2",
    C1 = ns .. "_axe_c1",
    C2 = ns .. "_axe_c2",
    D1 = ns .. "_axe_d1",
    D2 = ns .. "_axe_d2",
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

local AXE_TYPES = {
    [types.Weapon.TYPE.AxeOneHand] = true,
    [types.Weapon.TYPE.AxeTwoHand] = true,
}

local ARMOR_SLOTS = {
    types.Actor.EQUIPMENT_SLOT.Cuirass,
    types.Actor.EQUIPMENT_SLOT.CarriedLeft,
    types.Actor.EQUIPMENT_SLOT.Helmet,
    types.Actor.EQUIPMENT_SLOT.Greaves,
    types.Actor.EQUIPMENT_SLOT.Boots,
    types.Actor.EQUIPMENT_SLOT.RightPauldron,
    types.Actor.EQUIPMENT_SLOT.LeftPauldron,
    types.Actor.EQUIPMENT_SLOT.RightGauntlet,
    types.Actor.EQUIPMENT_SLOT.LeftGauntlet,
}

local CHARGED_THRESHOLD = 0.95
local DEMORALIZE_RADIUS = 1000 -- 10m in vanilla-scale world units.
local BERSERK_HEALTH_RATIO = 0.25
local BERSERK_DURATION = 10
local DAY_SECONDS = 86400

local berserkDayUsed = nil
local lastDemoralizeDebug = nil
local lastKillCheckDebug = nil

local function getAttackTarget(attack)
    return attack.target or attack.victim or attack.defender
end

local function isPlayerAxeAttack(attack)
    if not SharedHit.isPlayerAttack(attack, self)
            or not attack.weapon
            or not types.Weapon.objectIsInstance(attack.weapon) then
        return false
    end
    return AXE_TYPES[types.Weapon.record(attack.weapon).type] == true
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

local function getWeaponDamage(attack)
    local record = types.Weapon.record(attack.weapon)
    local attackType = attack.type
    if attackType == 0 or attackType == "chop" or attackType == "Chop" then
        return (record.chopMinDamage + record.chopMaxDamage) / 2
    elseif attackType == 1 or attackType == "slash" or attackType == "Slash" then
        return (record.slashMinDamage + record.slashMaxDamage) / 2
    elseif attackType == 2 or attackType == "thrust" or attackType == "Thrust" then
        return (record.thrustMinDamage + record.thrustMaxDamage) / 2
    end
    return math.max(
        (record.chopMinDamage + record.chopMaxDamage) / 2,
        (record.slashMinDamage + record.slashMaxDamage) / 2,
        (record.thrustMinDamage + record.thrustMaxDamage) / 2
    )
end

local function getCritModifier(attack)
    if attack.critical == true or attack.isCritical == true then
        return CombatMath.CRIT_MODIFIER.MELEE
    end
    return CombatMath.CRIT_MODIFIER.NONE
end

local function getHealthRatio(actor)
    local health = types.Actor.stats.dynamic.health(actor)
    local maxHealth = math.max((health.base or 0) + (health.modifier or 0), 1)
    return math.max(0, math.min(1, health.current / maxHealth))
end

-- ============================================================
--  A CHAIN - SUNDERING EDGE
-- ============================================================

local A_CONDITION_MULTIPLIER = { [1] = 0.50, [2] = 0.75, [3] = 1.00, [4] = 1.50 }

local function getEquippedArmorPieces(target)
    local pieces = {}
    for _, slot in ipairs(ARMOR_SLOTS) do
        local item = types.Actor.getEquipment(target, slot)
        if item and types.Armor.objectIsInstance(item) then
            table.insert(pieces, item)
        end
    end
    return pieces
end

-- Damages the struck armor when OpenMW reports it; otherwise spreads the
-- punishment across all equipped armor so the perk still does something
-- against hits that do not expose a precise armor object.
local function handleSunderingEdge(attack, target)
    local rank = getARank()
    SkillDebug.traceEvent(SKILL_ID, "Sundering Edge check", {
        charged = isChargedAttack(attack),
        rank = rank,
        successful = attack.successful,
        target = SkillDebug.objectId(target),
    })
    if rank == 0 or attack.successful ~= true or not isChargedAttack(attack) then
        return
    end

    local amount = getWeaponDamage(attack) * getChargeRatio(attack) * A_CONDITION_MULTIPLIER[rank]
    if amount <= 0 then
        return
    end

    if attack.armor and attack.armor:isValid() then
        core.sendGlobalEvent("SPerks_DamageItemCondition", { item = attack.armor, amount = amount })
        return
    end

    local pieces = getEquippedArmorPieces(target)
    if #pieces == 0 then
        return
    end
    local split = amount / #pieces
    for _, item in ipairs(pieces) do
        core.sendGlobalEvent("SPerks_DamageItemCondition", { item = item, amount = split })
    end
    SkillDebug.traceEvent(SKILL_ID, "Sundering Edge applied", {
        amount = amount,
        pieces = #pieces,
    })
end

-- ============================================================
--  B CHAIN - TERROR OF THE FALLEN
-- ============================================================

--- Selects the fear effect appropriate to the nearby actor. Undead use their
--- dedicated engine effect; ordinary creatures and NPCs use their respective
--- Demoralize variants.
--- @param target GameObject Actor receiving Terror of the Fallen.
--- @return string effectId Engine magic-effect identifier.
local function getFearEffectId(target)
    if not types.Creature.objectIsInstance(target) then
        return "demoralizehumanoid"
    end
    if types.Creature.record(target).type == types.Creature.TYPE.Undead then
        return "turnundead"
    end
    return "demoralizecreature"
end

--- Applies the already-classified fear effect through Core 0's actor-safe
--- spell bridge and returns its ID for diagnostics.
--- @param target GameObject Actor receiving the effect.
--- @param magnitude number Fear magnitude.
--- @return string effectId Applied engine magic-effect identifier.
local function applyDemoralize(target, magnitude)
    local effectId = getFearEffectId(target)
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = self,
        spellName = "Terror of the Fallen",
        effects = {
            {
                id = effectId,
                range = core.magic.RANGE.Target,
                magnitudeMin = magnitude,
                duration = 10,
            },
        },
        activeSpellOptions = {
            ignoreResistances = false,
            quiet = true,
        },
    })
    return effectId
end

--- Rolls Terror of the Fallen once for a qualifying Axe kill, then applies
--- the appropriate fear effect to every nearby actor other than the victim.
--- The completed roll and delivery counts are retained for `luaaxe debug`.
--- @param sourceTarget GameObject Actor killed by the Axe hit.
--- @param chance number Proc chance in the inclusive 0-1 range.
local function triggerDemoralize(sourceTarget, chance)
    local rank = getBRank()
    if rank == 0 then
        return
    end

    local roll = math.random()
    local magnitude = rank >= 2 and 50 or 20
    lastDemoralizeDebug = {
        chance = chance,
        roll = roll,
        triggered = roll < chance,
        magnitude = magnitude,
        humanoids = 0,
        creatures = 0,
        undead = 0,
    }
    SkillDebug.traceEvent(SKILL_ID, "Terror roll", {
        chance = chance,
        rank = rank,
        roll = roll,
        triggered = lastDemoralizeDebug.triggered,
    })
    if not lastDemoralizeDebug.triggered then
        return
    end

    for _, actor in ipairs(nearby.actors) do
        if actor:isValid()
                and actor ~= self
                and actor ~= sourceTarget
                and (actor.position - self.position):length() <= DEMORALIZE_RADIUS then
            local effectId = applyDemoralize(actor, magnitude)
            if effectId == "turnundead" then
                lastDemoralizeDebug.undead = lastDemoralizeDebug.undead + 1
            elseif effectId == "demoralizecreature" then
                lastDemoralizeDebug.creatures = lastDemoralizeDebug.creatures + 1
            else
                lastDemoralizeDebug.humanoids = lastDemoralizeDebug.humanoids + 1
            end
        end
    end
    SkillDebug.traceEvent(SKILL_ID, "Terror delivered", {
        creatures = lastDemoralizeDebug.creatures,
        humanoids = lastDemoralizeDebug.humanoids,
        undead = lastDemoralizeDebug.undead,
    })
end

-- ============================================================
--  C CHAIN - BERSERK BREAKPOINT
-- ============================================================

local function getCurrentGameDay()
    return math.floor(core.getGameTime() / DAY_SECONDS)
end

local function refreshBerserkIfNeeded()
    if getCRank() == 0 or berserkDayUsed == nil then
        return
    end
    if getCurrentGameDay() > berserkDayUsed then
        berserkDayUsed = nil
        ui.showMessage("Your berserker fury is ready again.")
    end
end

local function triggerBerserkIfNeeded()
    local rank = getCRank()
    if rank == 0 or getHealthRatio(self) >= BERSERK_HEALTH_RATIO then
        return
    end

    local day = getCurrentGameDay()
    if berserkDayUsed == day then
        return
    end
    berserkDayUsed = day
    SkillDebug.traceEvent(SKILL_ID, "Berserk triggered", {
        day = day,
        healthRatio = getHealthRatio(self),
        rank = rank,
    })
    ui.showMessage("Berserk fury takes hold!")

    local effects = {
        { id = "fortifyhealth", range = core.magic.RANGE.Target, magnitudeMin = 20, duration = BERSERK_DURATION },
        { id = "fortifyfatigue", range = core.magic.RANGE.Target, magnitudeMin = 200, duration = BERSERK_DURATION },
        { id = "fortifyattack", range = core.magic.RANGE.Target, magnitudeMin = 100, duration = BERSERK_DURATION },
    }
    if rank == 1 then
        table.insert(effects, {
            id = "drainattribute",
            range = core.magic.RANGE.Target,
            magnitudeMin = 100,
            duration = BERSERK_DURATION,
            affectedAttribute = "agility",
        })
    end

    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = self,
        caster = self,
        spellName = "Orc Berserk",
        effects = effects,
        activeSpellOptions = {
            ignoreReflect = true,
            ignoreResistances = true,
            ignoreSpellAbsorption = true,
            quiet = true,
        },
    })
end

-- ============================================================
--  D CHAIN - BROKEN PLATE
-- ============================================================

local function getPreArmorDamage(attack)
    return getWeaponDamage(attack)
        * CombatMath.getStrengthModifier(self)
        * CombatMath.getConditionModifier(attack.weapon)
        * getCritModifier(attack)
end

local function getArmorConditionRatio(item)
    local itemData = types.Item.itemData(item)
    local record = item.type.record(item)
    local maxCondition = record.health or record.maxCondition
    if not itemData or not maxCondition or maxCondition <= 0 or itemData.condition == nil then
        return 1
    end
    return math.max(0, math.min(1, itemData.condition / maxCondition))
end

local function getBrokenPlateBonus(attack, target)
    local rank = getDRank()
    if rank == 0 or attack.successful ~= true or not types.NPC.objectIsInstance(target) then
        return 0
    end

    local rawDamage = getPreArmorDamage(attack)
    local normalAR = CombatMath.getArmorRating(target)
    local scaledAR = CombatMath.getArmorRating(target, {
        conditionScale = getArmorConditionRatio,
        -- OpenMW's hit table tells us the strike hit no armor, but not
        -- which unarmored slot was struck. Until that slot is available,
        -- D2 zeroes the unarmored contribution during this recomputation
        -- as the closest framework-level approximation.
        zeroUnarmored = function()
            return rank >= 2 and attack.armor == nil
        end,
    })
    local normalDamage = rawDamage / math.min(1 + (normalAR / math.max(rawDamage, 1)), 4)
    local scaledDamage = rawDamage / math.min(1 + (scaledAR / math.max(rawDamage, 1)), 4)
    return math.max(0, scaledDamage - normalDamage)
end

interfaces.ErnPerkFramework.registerCalculationHandler({
    id = ns .. "_axe_broken_plate",
    calculation = CALCULATION.HIT_DAMAGE_HEALTH,
    operation = OPERATION.Addition,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
}, function(data)
    local attack = data.context
    if not attack or not isPlayerAxeAttack(attack) then
        return false
    end
    local target = getAttackTarget(attack)
    if not target or not target:isValid() then
        return false
    end
    local bonus = getBrokenPlateBonus(attack, target)
    return bonus > 0 and bonus or false
end)

-- This handler observes final resolved damage after all earlier arithmetic
-- buckets. It returns the same value unchanged, using Modifier only because
-- the framework exposes the final running value at that point.
interfaces.ErnPerkFramework.registerCalculationHandler({
    id = ns .. "_axe_demoralize_on_kill",
    calculation = CALCULATION.HIT_DAMAGE_HEALTH,
    operation = OPERATION.Modifier,
    priority = 5000,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
}, function(data)
    local attack = data.context
    if not attack or not isPlayerAxeAttack(attack) or getBRank() == 0 then
        return data.value
    end
    local target = getAttackTarget(attack)
    if not target or not target:isValid() then
        return data.value
    end

    local resources = attack.perkFrameworkPreHitResources
    local beforeHealth = resources and resources.health or nil
    local beforeCurrent = beforeHealth and tonumber(beforeHealth.current) or nil
    local beforeRatio = beforeHealth and tonumber(beforeHealth.ratio) or nil
    local lethal = beforeCurrent ~= nil and data.value >= beforeCurrent
    lastKillCheckDebug = {
        target = target.id,
        damage = data.value,
        beforeCurrent = beforeCurrent,
        beforeRatio = beforeRatio,
        lethal = lethal,
        snapshot = beforeHealth ~= nil,
    }
    SkillDebug.traceEvent(SKILL_ID, "Terror kill check", lastKillCheckDebug)
    if lethal then
        triggerDemoralize(target, math.max(0, math.min(1, 0.20 + beforeRatio)))
    end
    return data.value
end)

-- ============================================================
--  SHARED HIT HANDLER
-- ============================================================

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_axe_on_hit",
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack)
        SkillDebug.traceEvent(SKILL_ID, "outgoing hit received", {
            successful = attack and attack.successful,
            weapon = attack and SkillDebug.objectId(attack.weapon),
        })
        if not isPlayerAxeAttack(attack) then
            SkillDebug.trace(SKILL_ID, "SkillPerks axe [outgoing hit rejected]: not a player Axe attack")
            return
        end
        local target = getAttackTarget(attack)
        if not target or not target:isValid() then
            return
        end

        handleSunderingEdge(attack, target)
    end,
})

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local function onUpdate()
    refreshBerserkIfNeeded()
    triggerBerserkIfNeeded()
end

local function onSave()
    return { berserkDayUsed = berserkDayUsed }
end

local function onLoad(data)
    berserkDayUsed = data and data.berserkDayUsed or nil
end

-- Exposes whether kill tracking and the once-per-day Berserk gate are armed.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Axe",
    skillId = SKILL_ID,
    actor = self,
    ids = ids,
    commands = { "luaaxe debug" },
    snapshot = function()
        local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
        local weaponRecord = weapon and types.Weapon.objectIsInstance(weapon)
            and types.Weapon.record(weapon) or nil
        local fear = lastDemoralizeDebug
        local kill = lastKillCheckDebug
        return {
            string.format(
                "Weapon: id=%s axe=%s",
                SkillDebug.objectId(weapon),
                tostring(weaponRecord and AXE_TYPES[weaponRecord.type] == true)
            ),
            string.format(
                "Berserk: usedDay=%s currentDay=%s health(%s)",
                SkillDebug.value(berserkDayUsed),
                SkillDebug.value(getCurrentGameDay()),
                SkillDebug.resourceSummary(self, "health")
            ),
            kill and string.format(
                "Last Axe hit: target=%s preHealth=%s preRatio=%s damage=%s lethal=%s snapshot=%s",
                SkillDebug.value(kill.target),
                SkillDebug.value(kill.beforeCurrent),
                SkillDebug.value(kill.beforeRatio),
                SkillDebug.number(kill.damage),
                tostring(kill.lethal),
                tostring(kill.snapshot)
            ) or "Last Axe hit: none observed by kill resolver.",
            fear and string.format(
                "Terror: triggered=%s roll=%s chance=%s magnitude=%d targets(humanoid/creature/undead)=%d/%d/%d",
                tostring(fear.triggered),
                SkillDebug.number(fear.roll),
                SkillDebug.number(fear.chance),
                fear.magnitude,
                fear.humanoids,
                fear.creatures,
                fear.undead
            ) or "Terror: no qualifying Axe kill observed.",
        }
    end,
})

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Sundering Edge",
    category = ChainRequirements.category("Combat", "Axe", 1),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "You stop treating armour as protection and start treating it as kindling with hinges.",
    localizedDescription = "Charged Axe hits deal bonus condition damage to struck armor equal to 50% weapon damage times charge strength.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Riving Edge",
    category = ChainRequirements.category("Combat", "Axe", 2),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "Leather parts. Mail buckles. Plate learns that a perfect edge can still be bullied open.",
    localizedDescription = "Charged Axe armor condition damage rises to 75% weapon damage times charge strength.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Cleaving Edge",
    category = ChainRequirements.category("Combat", "Axe", 3),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "Your axe does not glance. It bites into the work of smiths and asks how much of it was pride.",
    localizedDescription = "Charged Axe armor condition damage rises to 100% weapon damage times charge strength.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Ruinous Edge",
    category = ChainRequirements.category("Combat", "Axe", 4),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "A single committed blow can make a cuirass feel like a confession. Everything breaks somewhere.",
    localizedDescription = "Charged Axe armor condition damage rises to 150% weapon damage times charge strength.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Terror of the Fallen",
    category = ChainRequirements.category("Combat", "Axe", 5),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "When one enemy falls beneath your axe, everyone close enough to hear it wonders if they are next.",
    localizedDescription = "Axe kills can Demoralize nearby actors within 10 meters. Chance is 20% plus the killed target's health percent before the blow. Magnitude 20.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Panic Harvest",
    category = ChainRequirements.category("Combat", "Axe", 6),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "The battlefield reads your work at a glance: one body ruined, and courage draining from the rest.",
    localizedDescription = "Terror of the Fallen's Demoralize magnitude rises to 50.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Berserk Breakpoint",
    category = ChainRequirements.category("Combat", "Axe", 7),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "At the edge of death, fear burns away. What remains is hunger, fury, and the strength to make the last exchange yours.",
    localizedDescription = "Once per day, falling below 25% health triggers 10 seconds of Orc Berserk: Fortify Health 20, Fortify Fatigue 200, Fortify Attack 100, and Drain Agility 100.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Controlled Frenzy",
    category = ChainRequirements.category("Combat", "Axe", 9),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "Your rage no longer throws you from your feet. It sharpens, narrows, and obeys.",
    localizedDescription = "Orc Berserk no longer drains Agility.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Broken Plate",
    category = ChainRequirements.category("Combat", "Axe", 8),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "Damaged armour does not save its wearer. It merely gives your axe a better place to enter.",
    localizedDescription = "Axe damage treats damaged armor condition as reducing that armor's effective protection.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "No Shelter",
    category = ChainRequirements.category("Combat", "Axe", 10),
    art = "textures\\levelup\\barbarian",
    localizedFlavour = "Where armour is missing, mercy is missing with it.",
    localizedDescription = "When an Axe hit strikes an unarmored location, that location gains no Unarmored protection for the damage calculation.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
