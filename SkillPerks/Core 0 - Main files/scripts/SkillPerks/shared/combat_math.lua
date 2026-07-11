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
    combat_math.lua

    The vanilla formulas and detection techniques documented in
    SkillPerks_Combat.md's "Shared Infrastructure" section, implemented
    once here instead of copy-pasted into Blunt/Spear/Axe/Long Blade/
    Block/etc individually.

    NOTE ON interfaces.Combat vs this module: OpenMW itself already
    exposes interfaces.Combat.getEffectiveArmorRating(item, actor) and
    interfaces.Combat.getArmorSkill(item) as built-in calls (confirmed via
    direct source review of Inventory Extender's autoEquip.lua and
    helpers.lua, which both call them - these are not IE inventions).
    Prefer those built-ins wherever a perk just needs to READ an AR value
    without altering an input. The hand-rolled getArmorRating() below
    exists only for the cases the design doc specifically needs it for -
    Axe D1's condition-scaled AR and Axe D2's zeroed-unarmored-location AR -
    where the built-in call gives no hook to override those inputs.

    FATIGUE TERM: sourced from the real fFatigueBase/fFatigueMult GMSTs
    (confirmed present in Inventory Extender's helpers.lua as
    Helpers.getFatigueTerm), rather than the hardcoded 0.75 + 0.5x forms
    written inline in the design doc. Algebraically identical at vanilla
    GMST defaults (1.25 - 0.5*(1-ratio) === 0.75 + 0.5*ratio), but reading
    the real GMSTs means this keeps working correctly under mods that
    rebalance fatigue scaling.
]]

local core = require("openmw.core")
local types = require("openmw.types")
local animation = require("openmw.animation")
local interfaces = require("openmw.interfaces")

local CombatMath = {}

-- ============================================================
--  N'GARDE INTEROP DETECTION
--  N'Garde is not a required dependency anywhere in SkillPerks. Detected
--  once at load time, same as FactionPerks/ErnPerkFramework's own
--  optional-dependency checks (e.g. NCGDMW detection in ErnPerkFramework
--  settings.lua). All N'Garde-enhanced paths must have vanilla fallbacks.
-- ============================================================

local hasNGardeCached = nil

--- @return boolean True if N'Garde's player-facing interface is present.
function CombatMath.hasNGarde()
    if hasNGardeCached == nil then
        hasNGardeCached = interfaces.NGardePlayer ~= nil
    end
    return hasNGardeCached
end

--- @param target table An actor to check for N'Garde's own per-target
---   fencer tracking. When present, SkillPerks' own stagger-suppression
---   loop (see shared/stagger.lua) must defer to N'Garde's tracking for
---   THAT target rather than fight it over self.controls.use writes -
---   see SkillPerks_Magic's Shared Infrastructure note on this exact point.
--- @return boolean
function CombatMath.targetHasNGardeFencer(target)
    return interfaces.NGardeFencer ~= nil
end

-- ============================================================
--  FATIGUE TERM
--  See module doc comment above for why this reads GMSTs directly rather
--  than using the hardcoded 0.75/0.5 forms written inline in the design doc.
-- ============================================================

local FATIGUE_BASE = core.getGMST("fFatigueBase")
local FATIGUE_MULT = core.getGMST("fFatigueMult")

--- @param actor table
--- @return number Multiplier in the vanilla ~0.75 (exhausted) to ~1.25 (full) range.
function CombatMath.getFatigueTerm(actor)
    local fatigueStat = types.Actor.stats.dynamic.fatigue(actor)
    local normalizedFatigue
    if fatigueStat.base == 0 then
        normalizedFatigue = 1
    else
        normalizedFatigue = math.max(0, fatigueStat.current / fatigueStat.base)
    end
    return FATIGUE_BASE - FATIGUE_MULT * (1 - normalizedFatigue)
end

-- ============================================================
--  CHARGE DETECTION
--  Reference implementation: threat.lua from N'Garde by Arrean.
--  Credit: Arrean. Implemented independently - N'Garde is not a required
--  dependency for this to work.
--
--  FLAGGED FOR IN-GAME VALIDATION: the exact weapon-animation-group text
--  key naming convention ("%s: %s max attack" / "%s: %s min attack") is
--  taken verbatim from the design doc, but the `weaponAnimation` string
--  itself (the first %s) needs to be the actual vanilla animation group
--  name for the equipped weapon type - this hasn't been cross-checked
--  against real .kf/.nif text key data in-game yet. Treat this the same
--  as every other "needs in-game validation" item already flagged in the
--  design docs, not as a design-phase blocker.
-- ============================================================

--- Determines attack type from movement state at windup start, per the
--- design doc's fully-specified rule.
--- @param actor table Usually `self` - controls are only readable for self.
--- @return string One of "Chop", "Thrust", "Slash".
function CombatMath.getAttackType(actor)
    local movement = actor.controls.movement
    local sideMovement = actor.controls.sideMovement
    if movement == 0 and sideMovement == 0 then
        return "Chop"
    elseif movement ~= 0 and sideMovement == 0 then
        return "Thrust"
    else
        return "Slash"
    end
end

--- @param actor table
--- @param weaponAnimation string The weapon's animation group name.
--- @param attackType string One of "Chop", "Thrust", "Slash" (see getAttackType).
--- @param timeDrawn number Seconds the attack has been charging so far.
--- @return number ratio 0.0-1.0 charge ratio, or nil if the text keys weren't found.
function CombatMath.getChargeRatio(actor, weaponAnimation, attackType, timeDrawn)
    local maxKey = string.format("%s: %s max attack", weaponAnimation, attackType)
    local minKey = string.format("%s: %s min attack", weaponAnimation, attackType)
    local maxTime = animation.getTextKeyTime(actor, maxKey)
    local minTime = animation.getTextKeyTime(actor, minKey)
    if not maxTime or not minTime then
        return nil
    end
    local drawTime = maxTime - minTime
    if drawTime <= 0 then
        return nil
    end
    return math.min(timeDrawn / drawTime, 1.0)
end

-- ============================================================
--  VANILLA DAMAGE FORMULA
--  (Weapon Damage * Strength Modifier * Condition Modifier * Critical Hit
--  Modifier) / Armor Reduction
-- ============================================================

CombatMath.CRIT_MODIFIER = {
    NONE = 1,
    MELEE = 4,
    RANGED = 1.5,
}

--- @param actor table The attacker.
--- @return number Strength Modifier = (Strength.modified + 50) / 100
function CombatMath.getStrengthModifier(actor)
    local strength = types.Actor.stats.attributes.strength(actor).modified
    return (strength + 50) / 100
end

--- @param weapon table
--- @return number Condition Modifier = current condition / max condition. 1.0 if unreadable.
function CombatMath.getConditionModifier(weapon)
    local itemData = types.Item.itemData(weapon)
    local record = types.Weapon.record(weapon)
    local maxCondition = record.health
    if not itemData or not maxCondition or maxCondition <= 0 then
        return 1.0
    end
    local current = itemData.condition
    if current == nil then
        -- nil condition on a valid weapon means "full" per the itemData
        -- semantics already confirmed in SkillPerks_Magic's shared
        -- infrastructure notes (enchantmentCharge follows the same rule).
        return 1.0
    end
    return current / maxCondition
end

--- @param weaponDamage number Pre-computed weapon damage for the swing
---   (e.g. from the weapon record's chop/slash/thrust min/max range).
--- @param strengthModifier number
--- @param conditionModifier number
--- @param critModifier number One of CombatMath.CRIT_MODIFIER.*
--- @param targetArmorRating number
--- @return number Final damage after armor reduction.
function CombatMath.applyDamageFormula(weaponDamage, strengthModifier, conditionModifier, critModifier, targetArmorRating)
    local rawDamage = weaponDamage * strengthModifier * conditionModifier * critModifier
    if rawDamage <= 0 then
        return 0
    end
    local armorReduction = math.min(1 + (targetArmorRating / rawDamage), 4)
    return rawDamage / armorReduction
end

-- ============================================================
--  ARMOR RATING (hand-rolled)
--  Chest*0.3 + (Shield+Head+Legs+Feet+RightShoulder+LeftShoulder)*0.1
--            + (RightHand+LeftHand)*0.05
--  Each piece: BaseAR * (ArmorSkill.modified / 30)
--  Unarmored locations: UnarmoredSkill^2 * 0.0065
--
--  Only use this over interfaces.Combat.getEffectiveArmorRating when a
--  perk needs to override condition scaling or zero out an unarmored
--  location's contribution - see the module doc comment above.
-- ============================================================

-- location -> { slot, weight }. RightHand/LeftHand are the Gauntlet slots
-- (0.05 weight each); everything else at 0.1 weight; Cuirass alone at 0.3.
local AR_LOCATIONS = {
    { slot = types.Actor.EQUIPMENT_SLOT.Cuirass,       weight = 0.3  },
    { slot = types.Actor.EQUIPMENT_SLOT.CarriedLeft,   weight = 0.1  }, -- Shield
    { slot = types.Actor.EQUIPMENT_SLOT.Helmet,        weight = 0.1  },
    { slot = types.Actor.EQUIPMENT_SLOT.Greaves,       weight = 0.1  }, -- Legs
    { slot = types.Actor.EQUIPMENT_SLOT.Boots,         weight = 0.1  }, -- Feet
    { slot = types.Actor.EQUIPMENT_SLOT.RightPauldron, weight = 0.1  },
    { slot = types.Actor.EQUIPMENT_SLOT.LeftPauldron,  weight = 0.1  },
    { slot = types.Actor.EQUIPMENT_SLOT.RightGauntlet, weight = 0.05 },
    { slot = types.Actor.EQUIPMENT_SLOT.LeftGauntlet,  weight = 0.05 },
}

--- @param actor table
--- @param options table|nil Optional overrides:
---   conditionScale(item) -> number [0,1] multiplier applied on top of the
---     piece's own condition ratio (Axe D1's "factor condition into damage
---     reduction" - pass a function returning currentCondition/maxCondition
---     again if you want it applied twice deliberately, or 1 to skip).
---   zeroUnarmored(location) -> boolean, if true that location's Unarmored
---     contribution is set to 0 instead of the normal formula (Axe D2).
--- @return number Total weighted armor rating.
function CombatMath.getArmorRating(actor, options)
    options = options or {}
    local total = 0
    local unarmoredSkill = types.NPC.stats.skills.unarmored(actor).modified

    for _, location in ipairs(AR_LOCATIONS) do
        local item = types.Actor.getEquipment(actor, location.slot)
        local pieceAR = 0

        if item and types.Armor.objectIsInstance(item) then
            local record = types.Armor.record(item)
            local armorSkillId = interfaces.Combat.getArmorSkill(item)
            local skillValue = armorSkillId and types.NPC.stats.skills[armorSkillId](actor).modified or 0
            pieceAR = record.baseArmor * (skillValue / 30)

            local conditionRatio = CombatMath.getConditionModifier(item)
            if options.conditionScale then
                conditionRatio = conditionRatio * options.conditionScale(item)
            end
            pieceAR = pieceAR * conditionRatio
        else
            -- Unarmored location.
            if options.zeroUnarmored and options.zeroUnarmored(location.slot) then
                pieceAR = 0
            else
                pieceAR = unarmoredSkill * unarmoredSkill * 0.0065
            end
        end

        total = total + pieceAR * location.weight
    end

    return total
end

-- ============================================================
--  VANILLA BLOCK FORMULA
--  Chance to block = (Block Rate - Attacker Hit Chance)%
--  Block Rate = (Block + Agility/5 + Luck/10) * fatigueTerm
--  Not moving forward: *1.25. Incoming charge strength: *((charge/100)+1).
-- ============================================================

--- @param actor table The blocker.
--- @param options table|nil { notMovingForward = boolean, chargeStrength = number (0-100) }
--- @return number Block Rate, ready to compare against attacker hit chance.
function CombatMath.getBlockRate(actor, options)
    options = options or {}
    local block = types.NPC.stats.skills.block(actor).modified
    local agility = types.Actor.stats.attributes.agility(actor).modified
    local luck = types.Actor.stats.attributes.luck(actor).modified

    local rate = (block + agility / 5 + luck / 10) * CombatMath.getFatigueTerm(actor)

    if options.notMovingForward then
        rate = rate * 1.25
    end
    if options.chargeStrength then
        rate = rate * ((options.chargeStrength / 100) + 1)
    end

    return rate
end

-- ============================================================
--  VANILLA HIT ROLL FORMULA
--  Hit Rate = (Weapon Skill + Agility/5 + Luck/10) * fatigueTerm
--             + Fortify Attack - Blind
--  Evasion = (Agility/5 + Luck/10) * fatigueTerm
---           + min(Sanctuary,100) + min(Chameleon/5,100)
--  Chance to hit = (Hit Rate - Evasion)%
-- ============================================================

--- @param attacker table
--- @param weaponSkillId string e.g. "longblade", "axe", "marksman"
--- @return number Hit Rate.
function CombatMath.getHitRate(attacker, weaponSkillId)
    local weaponSkill = types.NPC.stats.skills[weaponSkillId](attacker).modified
    local agility = types.Actor.stats.attributes.agility(attacker).modified
    local luck = types.Actor.stats.attributes.luck(attacker).modified

    local fortifyAttack = types.Actor.activeEffects(attacker):getEffect(core.magic.EFFECT_TYPE.FortifyAttack)
    local blind = types.Actor.activeEffects(attacker):getEffect(core.magic.EFFECT_TYPE.Blind)

    local rate = (weaponSkill + agility / 5 + luck / 10) * CombatMath.getFatigueTerm(attacker)
    rate = rate + (fortifyAttack and fortifyAttack.magnitude or 0)
    rate = rate - (blind and blind.magnitude or 0)
    return rate
end

--- @param defender table
--- @return number Evasion.
function CombatMath.getEvasion(defender)
    local agility = types.Actor.stats.attributes.agility(defender).modified
    local luck = types.Actor.stats.attributes.luck(defender).modified

    local sanctuary = types.Actor.activeEffects(defender):getEffect(core.magic.EFFECT_TYPE.Sanctuary)
    local chameleon = types.Actor.activeEffects(defender):getEffect(core.magic.EFFECT_TYPE.Chameleon)

    local evasion = (agility / 5 + luck / 10) * CombatMath.getFatigueTerm(defender)
    evasion = evasion + math.min(sanctuary and sanctuary.magnitude or 0, 100)
    evasion = evasion + math.min((chameleon and chameleon.magnitude or 0) / 5, 100)
    return evasion
end

--- @param attacker table
--- @param defender table
--- @param weaponSkillId string
--- @return number percent Chance to hit, 0-100 (can exceed range before use - caller should clamp/roll as needed).
function CombatMath.getHitChance(attacker, defender, weaponSkillId)
    return CombatMath.getHitRate(attacker, weaponSkillId) - CombatMath.getEvasion(defender)
end

return CombatMath
