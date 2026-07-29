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
    SPerks_Blunt.lua

    Blunt Weapon - "Attrition fighter. Drains fatigue, punishes low
    stamina, crushes through defences." See SkillPerks_Combat.md's Blunt
    Weapon section for the full design spec.

    Blunt is an offensive player-hit file. Core 0 validates target-local hits
    and marks forwarded player attacks, while defensive files such as Block
    subscribe only to incoming hits. Cross-actor writes that cannot safely
    happen from the player context are routed through Core 0's shared handlers.

    CHARGE DETECTION NOTE: the shared design prefers animation text-key
    charge detection, but current hit tables also expose attack.strength in
    practice. This file keeps charge interpretation isolated in
    getChargeRatio() so it can be replaced by text-key tracking later if
    in-game testing shows a different scale or timing.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local core       = require("openmw.core")
local ui         = require("openmw.ui")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local CombatMath         = require("scripts.SkillPerks.shared.combat_math")
local SkillDebug         = require("scripts.SkillPerks.shared.debug")
local SharedHit          = require("scripts.SkillPerks.shared.hit")

local SKILL_ID = "bluntweapon"
local CALCULATION = interfaces.ErnPerkFramework.CALCULATION
local OPERATION = interfaces.ErnPerkFramework.CALCULATION_OPERATION

local ids = {
    A1 = ns .. "_blunt_a1",
    A2 = ns .. "_blunt_a2",
    A3 = ns .. "_blunt_a3",
    A4 = ns .. "_blunt_a4",
    B1 = ns .. "_blunt_b1",
    B2 = ns .. "_blunt_b2",
    C1 = ns .. "_blunt_c1",
    C2 = ns .. "_blunt_c2",
    D1 = ns .. "_blunt_d1",
    D2 = ns .. "_blunt_d2",
}

-- Reads the framework's cached player perk set for quick rank checks.
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

-- Reactive perks do their work from hit/update handlers, not on add/remove.
local function noPersistentEffect() end

-- ============================================================
--  SHARED HIT HELPERS
-- ============================================================

local BLUNT_TYPES = {
    [types.Weapon.TYPE.BluntOneHand] = true,
    [types.Weapon.TYPE.BluntTwoClose] = true,
    [types.Weapon.TYPE.BluntTwoWide] = true,
}

local CHARGED_THRESHOLD = 0.95
local lastHitDebug = nil
local lastCalculationDebug = nil

-- Returns the actor being struck by the player's outgoing hit.
local function getAttackTarget(attack)
    return attack.target or attack.victim or attack.defender
end

-- True when the hit is a player attack made with a blunt weapon.
local function isPlayerBluntAttack(attack)
    if not SharedHit.isPlayerAttack(attack, self) then
        return false
    end
    if not attack.weapon or not types.Weapon.objectIsInstance(attack.weapon) then
        return false
    end
    local record = types.Weapon.record(attack.weapon)
    return BLUNT_TYPES[record.type] == true
end

-- Normalizes attack.strength into a 0-1 charge ratio.
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

local function getBluntSkill()
    return types.NPC.stats.skills.bluntweapon(self).modified
end

local function getTargetFatigueRatio(target)
    local fatigue = types.Actor.stats.dynamic.fatigue(target)
    local maxFatigue = math.max((fatigue.base or 0) + (fatigue.modifier or 0), 1)
    return fatigue.current / maxFatigue
end

-- Returns average weapon damage for the attack direction OpenMW reports.
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

    local chop = (record.chopMinDamage + record.chopMaxDamage) / 2
    local slash = (record.slashMinDamage + record.slashMaxDamage) / 2
    local thrust = (record.thrustMinDamage + record.thrustMaxDamage) / 2
    return math.max(chop, slash, thrust)
end

local function getCritModifier(attack)
    if attack.critical == true or attack.isCritical == true then
        return CombatMath.CRIT_MODIFIER.MELEE
    end
    return CombatMath.CRIT_MODIFIER.NONE
end

-- Calculates the pre-armor portion of the vanilla weapon damage formula.
local function getPreArmorDamage(attack, critModifier)
    return getWeaponDamage(attack)
        * CombatMath.getStrengthModifier(self)
        * CombatMath.getConditionModifier(attack.weapon)
        * (critModifier or getCritModifier(attack))
end

-- ============================================================
--  A CHAIN - HEAVY IMPACT
-- ============================================================

local A_FATIGUE_DAMAGE = { [1] = 5, [2] = 10, [3] = 15, [4] = 20 }

-- Charged blunt hits contribute fatigue damage to the shared hit resolution.
local function handleHeavyImpact(attack)
    local rank = getARank()
    SkillDebug.traceEvent(SKILL_ID, "Heavy Impact check", {
        charged = isChargedAttack(attack),
        rank = rank,
        successful = attack.successful,
    })
    if rank == 0 or attack.successful ~= true or not isChargedAttack(attack) then
        return 0
    end
    local amount = A_FATIGUE_DAMAGE[rank]
    interfaces.ErnPerkFramework.addHitDamage(attack, "fatigue", amount, {
        source = self,
        sourceEffect = ids["A" .. tostring(rank)],
        context = "blunt.heavyImpact",
    })
    SkillDebug.traceEvent(SKILL_ID, "Heavy Impact applied", { fatigueDamage = amount })
    return amount
end

-- ============================================================
--  B CHAIN - EXPLOITATION
-- ============================================================

local B_THRESHOLD = { [1] = 0.33, [2] = 0.50 }
local B_DIVISOR = { [1] = 10, [2] = 5 }

-- Returns Blunt's low-fatigue bonus damage contribution.
local function getExploitationBonus(attack, target)
    local rank = getBRank()
    if rank == 0 or attack.successful ~= true or not attack.damage then
        return 0
    end
    if getTargetFatigueRatio(target) > B_THRESHOLD[rank] then
        return 0
    end

    return getBluntSkill() / B_DIVISOR[rank]
end

-- ============================================================
--  C CHAIN - CRUSHING FORCE
-- ============================================================

local C_ARMOR_PEN = { [1] = 0.25, [2] = 0.50 }
local C_BLOCK_PEN = { [1] = 0.10, [2] = 0.25 }

-- Returns Blunt's charged armor/block penetration damage contribution.
local function getCrushingForceBonus(attack, target)
    local rank = getCRank()
    if rank == 0 or not attack.damage or not isChargedAttack(attack) then
        return 0
    end

    local wasBlocked = attack.successful == true and (attack.damage.health or 0) <= 0
    if wasBlocked then
        local preArmor = getPreArmorDamage(attack, CombatMath.CRIT_MODIFIER.NONE)
        local fullDamage = CombatMath.applyDamageFormula(
            getWeaponDamage(attack),
            CombatMath.getStrengthModifier(self),
            CombatMath.getConditionModifier(attack.weapon),
            CombatMath.CRIT_MODIFIER.NONE,
            CombatMath.getArmorRating(target)
        )
        local totalImpact = fullDamage + (preArmor * C_ARMOR_PEN[rank])
        return totalImpact * C_BLOCK_PEN[rank]
    end

    if attack.successful == true then
        return getPreArmorDamage(attack) * C_ARMOR_PEN[rank]
    end
    return 0
end

-- Routes Blunt's health-damage additions through the framework calculation
-- pipeline so other mods can resolve against one final hit-damage value.
interfaces.ErnPerkFramework.registerCalculationHandler({
    id = ns .. "_blunt_hit_damage_health",
    calculation = CALCULATION.HIT_DAMAGE_HEALTH,
    operation = OPERATION.Addition,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
}, function(data)
    local attack = data.context
    lastCalculationDebug = {
        direction = data.direction,
        playerOwned = attack and attack.skillPerksPlayerOwned == true or false,
        result = "received",
    }
    if not attack then
        lastCalculationDebug.result = "rejected: no attack context"
        return false
    end
    if not isPlayerBluntAttack(attack) then
        lastCalculationDebug.result = "rejected by player Blunt Weapon check"
        return false
    end

    local target = getAttackTarget(attack)
    if not target or not target:isValid() then
        lastCalculationDebug.result = "rejected: no valid target"
        return false
    end

    local exploitation = getExploitationBonus(attack, target)
    local crushing = getCrushingForceBonus(attack, target)
    local bonus = exploitation + crushing
    lastCalculationDebug = {
        targetId = target.id,
        fatigueRatio = getTargetFatigueRatio(target),
        exploitation = exploitation,
        crushing = crushing,
        total = bonus,
        charged = isChargedAttack(attack),
        direction = data.direction,
        playerOwned = attack.skillPerksPlayerOwned == true,
        result = bonus > 0 and "contributed" or "no B/C contribution",
    }
    SkillDebug.traceEvent(SKILL_ID, "damage calculation", lastCalculationDebug)
    if bonus <= 0 then
        return false
    end
    return bonus
end)

-- ============================================================
--  D CHAIN - RELENTLESS ASSAULT
-- ============================================================

local D_STACK_TIMER = 8
local D_STACK_MAGNITUDE = 5
local D_MAX_STACKS = { [1] = 5, [2] = 10 }
local D_PARALYZE_DURATION = 10

local dStacksByTarget = {}

-- Applies or reverses one stack of Blind, Sound, and Burden on the target.
local function modifyDStackEffects(target, stacks)
    local amount = D_STACK_MAGNITUDE * stacks
    for _, effectId in ipairs({ "blind", "sound", "burden" }) do
        core.sendGlobalEvent("SPerks_ModifyActorActiveEffect", {
            target = target,
            effectId = effectId,
            amount = amount,
        })
    end
end

local function removeDStacksForKey(key)
    local entry = dStacksByTarget[key]
    if not entry then
        return
    end
    if entry.target and entry.target:isValid() and entry.stacks > 0 then
        modifyDStackEffects(entry.target, -entry.stacks)
    end
    dStacksByTarget[key] = nil
end

local function applyDParalysis(target)
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = self,
        spellName = "Relentless Assault",
        effects = {
            {
                id = "paralyze",
                range = core.magic.RANGE.Target,
                magnitudeMin = 1,
                duration = D_PARALYZE_DURATION,
            },
        },
        activeSpellOptions = {
            ignoreResistances = true,
            ignoreSpellAbsorption = true,
            quiet = true,
        },
    })
end

-- Adds pressure stacks to the current target and consumes them for D2's
-- paralysis when the rank-2 cap is reached.
local function handleRelentlessAssault(target)
    local rank = getDRank()
    if rank == 0 then
        return 0, false
    end

    local key = target.id
    local entry = dStacksByTarget[key]
    if not entry then
        entry = { target = target, stacks = 0, timer = D_STACK_TIMER }
        dStacksByTarget[key] = entry
    end

    local maxStacks = D_MAX_STACKS[rank]
    if entry.stacks < maxStacks then
        entry.stacks = entry.stacks + 1
        modifyDStackEffects(target, 1)
    end
    entry.timer = D_STACK_TIMER

    if rank >= 2 and entry.stacks >= D_MAX_STACKS[2] then
        removeDStacksForKey(key)
        applyDParalysis(target)
        return D_MAX_STACKS[2], true
    end
    return entry.stacks, false
end

local function tickDStacks(dt)
    for key, entry in pairs(dStacksByTarget) do
        entry.timer = entry.timer - dt
        if entry.timer <= 0 or not entry.target or not entry.target:isValid() then
            removeDStacksForKey(key)
        end
    end
end

local function clearDStacks()
    for key in pairs(dStacksByTarget) do
        removeDStacksForKey(key)
    end
end

local function serializeDStacks()
    local out = {}
    for key, entry in pairs(dStacksByTarget) do
        if entry.target and entry.target:isValid() and entry.stacks > 0 then
            out[key] = {
                target = entry.target,
                stacks = entry.stacks,
                timer = entry.timer,
            }
        end
    end
    return out
end

-- ============================================================
--  SHARED HIT HANDLER
-- ============================================================

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_blunt_on_hit",
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Outgoing,
    handler = function(attack)
        local weapon = attack.weapon
        local weaponRecord = weapon and types.Weapon.objectIsInstance(weapon)
            and types.Weapon.record(weapon) or nil
        lastHitDebug = {
            source = attack.skillPerksHitSource or "framework",
            successful = attack.successful,
            charge = getChargeRatio(attack),
            charged = isChargedAttack(attack),
            weaponId = weaponRecord and weaponRecord.id or nil,
            weaponType = weaponRecord and weaponRecord.type or nil,
            playerBlunt = isPlayerBluntAttack(attack),
            targetId = getAttackTarget(attack) and getAttackTarget(attack).id or nil,
            aFatigueDamage = 0,
            dStacks = 0,
            dParalyzed = false,
        }
        if not isPlayerBluntAttack(attack) then
            lastHitDebug.result = "rejected by player Blunt Weapon check"
            SkillDebug.traceEvent(SKILL_ID, "outgoing hit", lastHitDebug)
            return
        end

        local target = getAttackTarget(attack)
        if not target or not target:isValid() then
            lastHitDebug.result = "rejected: no valid target"
            SkillDebug.traceEvent(SKILL_ID, "outgoing hit", lastHitDebug)
            return
        end

        lastHitDebug.aFatigueDamage = handleHeavyImpact(attack)

        if attack.successful == true then
            lastHitDebug.dStacks, lastHitDebug.dParalyzed = handleRelentlessAssault(target)
        end
        lastHitDebug.result = "processed"
        SkillDebug.traceEvent(SKILL_ID, "outgoing hit", lastHitDebug)
    end,
})

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local function onUpdate(dt)
    tickDStacks(dt)
end

local function onSave()
    return {
        dStacksByTarget = serializeDStacks(),
    }
end

local function onLoad(data)
    dStacksByTarget = {}
    if not data or not data.dStacksByTarget then
        return
    end
    for key, entry in pairs(data.dStacksByTarget) do
        if entry.target and entry.target:isValid() and entry.stacks and entry.stacks > 0 then
            dStacksByTarget[key] = {
                target = entry.target,
                stacks = entry.stacks,
                timer = entry.timer or D_STACK_TIMER,
            }
        end
    end
end

local function consolePrint(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

--- Prints Blunt's live ranks and the last observations from the unified
--- Framework hit route and arithmetic damage-calculation path.
local function onConsoleCommand(mode, command)
    if SkillDebug.handleTraceCommand({
        name = "Blunt Weapon",
        skillId = SKILL_ID,
        commands = { "luablunt debug", "luabl debug" },
    }, command) then
        return
    end
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "luablunt debug" and command ~= "luabl debug" then
        return
    end
    SkillDebug.describe({ name = "Blunt Weapon", skillId = SKILL_ID, actor = self, ids = ids })

    local equipped = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    local equippedRecord = equipped and types.Weapon.objectIsInstance(equipped)
        and types.Weapon.record(equipped) or nil
    consolePrint("Blunt ranks: A=" .. tostring(getARank())
        .. " B=" .. tostring(getBRank())
        .. " C=" .. tostring(getCRank())
        .. " D=" .. tostring(getDRank())
        .. " skill=" .. tostring(getBluntSkill())
        .. " equipped=" .. tostring(equippedRecord and equippedRecord.id)
        .. " type=" .. tostring(equippedRecord and equippedRecord.type)
        .. " blunt=" .. tostring(equippedRecord and BLUNT_TYPES[equippedRecord.type] == true))

    if lastHitDebug then
        consolePrint("Blunt hit: source=" .. tostring(lastHitDebug.source)
            .. " success=" .. tostring(lastHitDebug.successful)
            .. " charge=" .. tostring(lastHitDebug.charge)
            .. " charged=" .. tostring(lastHitDebug.charged)
            .. " weapon=" .. tostring(lastHitDebug.weaponId)
            .. " type=" .. tostring(lastHitDebug.weaponType)
            .. " target=" .. tostring(lastHitDebug.targetId)
            .. " result=" .. tostring(lastHitDebug.result))
        consolePrint("Blunt direct procs: A fatigue=" .. tostring(lastHitDebug.aFatigueDamage)
            .. " D stacks=" .. tostring(lastHitDebug.dStacks)
            .. " D paralysis=" .. tostring(lastHitDebug.dParalyzed))
    else
        consolePrint("Blunt hit: none seen by Framework handler.")
    end

    if lastCalculationDebug then
        consolePrint("Blunt damage calculation: result=" .. tostring(lastCalculationDebug.result)
            .. " direction=" .. tostring(lastCalculationDebug.direction)
            .. " playerOwned=" .. tostring(lastCalculationDebug.playerOwned)
            .. " target=" .. tostring(lastCalculationDebug.targetId)
            .. " fatigue=" .. tostring(lastCalculationDebug.fatigueRatio)
            .. " B bonus=" .. tostring(lastCalculationDebug.exploitation)
            .. " C bonus=" .. tostring(lastCalculationDebug.crushing)
            .. " total=" .. tostring(lastCalculationDebug.total)
            .. " charged=" .. tostring(lastCalculationDebug.charged))
    else
        consolePrint("Blunt damage calculation: none seen.")
    end
end

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Heavy Impact",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A hammer does not need finesse to leave a lesson. Your heaviest swings drive the breath from bone and sinew.",
    localizedDescription = "Charged Blunt Weapon attacks deal 5 bonus fatigue damage.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Staggering Impact",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your blows land like doors being broken from their hinges, leaving enemies stumbling before pain can even arrive.",
    localizedDescription = "Charged Blunt Weapon attacks now deal 10 bonus fatigue damage.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Bone-Shaking Impact",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 3),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The body remembers every strike. Armor may hold, but the force beneath it keeps travelling.",
    localizedDescription = "Charged Blunt Weapon attacks now deal 15 bonus fatigue damage.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Earthbreaker",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 4),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your full swing carries the certainty of falling stone. What it cannot cut, it simply makes kneel.",
    localizedDescription = "Charged Blunt Weapon attacks now deal 20 bonus fatigue damage.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Exploitation",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 5),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A tired opponent cannot brace properly. You know exactly when weakness becomes an opening.",
    localizedDescription = "Blunt Weapon attacks against targets below 33% fatigue deal bonus "
        .. "health damage equal to your Blunt Weapon skill divided by 10.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Merciless Exploitation",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 6),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Once their stance softens, you do not let it recover. Every falter is made deeper.",
    localizedDescription = "The fatigue threshold rises to 50%, and the bonus damage improves "
        .. "to your Blunt Weapon skill divided by 5.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Crushing Force",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 7),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Steel can turn an edge. It cannot bargain with mass. Your charged strikes drive force through whatever stands between.",
    localizedDescription = "Charged attacks deal 25% of their pre-armor damage as additional "
        .. "armor-penetrating damage. Fully blocked charged attacks still deal 10% of their "
        .. "calculated impact through the block.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Shattering Force",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 9),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A shield can catch the weapon. It cannot catch the shock that follows.",
    localizedDescription = "Armor penetration rises to 50%, and block penetration rises to 25%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Relentless Assault",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 8),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You do not merely hit an enemy. You keep arriving, blow after blow, until their senses and balance come apart.",
    localizedDescription = "Each successful Blunt Weapon hit adds a timed stack of Blind, "
        .. "Sound, and Burden. Stacks last 8 seconds, refresh together, and cap at 5.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = noPersistentEffect,
    onRemove = clearDStacks,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Final Collapse",
    category = ChainRequirements.category("Combat", "Blunt Weapon", 10),
    art = "textures\\levelup\\knight",
    localizedFlavour = "At the end of your assault there is no flourish, no duel, no answer. There is only the moment their body refuses the fight.",
    localizedDescription = "The stack cap rises to 10. Reaching 10 stacks consumes them and "
        .. "paralyses the target for 10 seconds, ignoring resistance.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = noPersistentEffect,
    onRemove = clearDStacks,
})

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onConsoleCommand = onConsoleCommand,
    },
}
