--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
]]

--[[ Hand-to-Hand wins by taking away stamina, weapons, and finally options. ]]

local core       = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")

local Common      = require("scripts.SkillPerks.stealth.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")

local SKILL_ID = "handtohand"
local ids = Common.ids("handtohand")

local defenseTracker = StatTracker.newActiveEffectTracker(self)

local A_DIVISOR = { [1] = 10, [2] = 7, [3] = 5, [4] = 4 }
local B_RESIST_CAP = { [1] = 20, [2] = 30 }
local C_CHANCE = { [1] = 0.10, [2] = 0.20 }
local D_CHANCE = { [1] = 0.25, [2] = 0.50 }
local D_DURATION = { [1] = 3, [2] = 5 }

local function aRank() return Common.rank(ids, "A") end
local function bRank() return Common.rank(ids, "B") end
local function cRank() return Common.rank(ids, "C") end
local function dRank() return Common.rank(ids, "D") end

local function isUnarmedPlayerHit(attack)
    return Common.isPlayerAttack(attack, self)
        and attack.successful == true
        and Common.isUnarmed(self)
end

-- Iron Skin is intentionally self-only: it updates every frame and clears on unequip.
local function updateIronSkin()
    local rank = bRank()
    local active = rank > 0 and Common.isUnarmed(self)
    local skill = Common.skill(self, SKILL_ID)
    defenseTracker.apply("resistnormalweapons", nil, active and math.min(B_RESIST_CAP[rank], skill / 5) or 0)
    defenseTracker.apply("sanctuary", nil, active and rank >= 2 and math.min(10, skill / 10) or 0)
end

local function applyIronFists(target)
    local rank = aRank()
    if rank == 0 or not target or not target:isValid() then
        return
    end
    local amount = Common.skill(self, SKILL_ID) / A_DIVISOR[rank]
    target:sendEvent("SPerks_TakeFatigue", {
        amount = amount,
        source = self,
        sourceEffect = ids["A" .. tostring(rank)],
        context = "handtohand.ironFists",
    })
    if rank >= 4 and Common.dynamicRatio(target, "fatigue") <= 0.25 then
        target:sendEvent("SPerks_TakeDamage", {
            amount = amount,
            source = self,
            sourceEffect = ids.A4,
            context = "handtohand.lowFatigueHealth",
        })
    end
end

local function damageTargetWeapon(target)
    local rank = cRank()
    if rank == 0 or not target or not target:isValid() then
        return
    end
    local weapon = types.Actor.getEquipment(target, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not weapon or not weapon:isValid() or not types.Weapon.objectIsInstance(weapon) then
        return
    end
    local itemData = types.Item.itemData(weapon)
    local chance = C_CHANCE[rank]
    if rank >= 2 and itemData and itemData.condition and types.Weapon.record(weapon).health then
        if itemData.condition / math.max(types.Weapon.record(weapon).health, 1) < 0.25 then
            chance = chance * 2
        end
    end
    if math.random() < chance then
        core.sendGlobalEvent("SPerks_ModifyItemCondition", {
            item = weapon,
            amount = -(Common.skill(self, SKILL_ID) / 3),
        })
    end
end

local function tryKnockout(target)
    local rank = dRank()
    if rank == 0 or not target or not target:isValid() or Common.dynamicRatio(target, "fatigue") > 0.15 then
        return
    end
    if math.random() >= D_CHANCE[rank] then
        return
    end
    core.sendGlobalEvent("SPerks_CreateAndApplySpell", {
        target = target,
        caster = self,
        spellName = "SkillPerks Knockout",
        effects = { { id = "paralyze", magnitudeMin = 1, duration = D_DURATION[rank] } },
        activeSpellOptions = { ignoreResistances = false, quiet = true },
    })
end

local routeOutgoingHit = Common.newOutgoingHitRouter(self, function(attack)
    if not isUnarmedPlayerHit(attack) then
        return
    end
    local target = Common.attackTarget(attack)
    applyIronFists(target)
    damageTargetWeapon(target)
    tryKnockout(target)
end)

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ids.A1 .. "_handtohand_hit",
    priority = 440,
    handler = function(attack)
        routeOutgoingHit(attack, "direct")
    end,
})

local function clearHandToHand()
    defenseTracker.clearAll()
end

local function onUpdate()
    updateIronSkin()
end

local function onSave()
    return { defense = defenseTracker.snapshot() }
end

local function onLoad(data)
    defenseTracker.restoreAndReverse(data and data.defense)
end

Common.registerStealthPerks(SKILL_ID, "Hand-to-Hand", ids, {
    A1 = { localizedName = "Iron Fists", localizedFlavour = "Your hands stop being empty. Every strike lands with the weight of breath stolen and balance ruined.", localizedDescription = "Unarmed hits deal bonus fatigue damage equal to Hand-to-Hand / 10.", onRemove = clearHandToHand },
    A2 = { localizedName = "Body Breaker", localizedFlavour = "You strike the places armor forgets to guard.", localizedDescription = "Iron Fists improves to Hand-to-Hand / 7 fatigue damage.", onRemove = clearHandToHand },
    A3 = { localizedName = "Breath Thief", localizedFlavour = "Every blow taxes the lungs until standing becomes the enemy's hardest decision.", localizedDescription = "Iron Fists improves to Hand-to-Hand / 5 fatigue damage.", onRemove = clearHandToHand },
    A4 = { localizedName = "Empty-Hand Judgment", localizedFlavour = "When their strength is gone, your hands find the line between mercy and silence.", localizedDescription = "Iron Fists improves to Hand-to-Hand / 4. Targets below 25% fatigue also take matching health damage.", onRemove = clearHandToHand },
    B1 = { localizedName = "Iron Skin", localizedFlavour = "Unarmed does not mean unguarded. You meet steel with bone, timing, and refusal.", localizedDescription = "While unarmed, gain Resist Normal Weapons equal to Hand-to-Hand / 5, capped at 20%.", onRemove = clearHandToHand },
    B2 = { localizedName = "Bare-Knuckle Ward", localizedFlavour = "You move inside the weapon's reach and make its advantage smaller.", localizedDescription = "Iron Skin's cap rises to 30%. While unarmed, also gain Sanctuary equal to Hand-to-Hand / 10, capped at 10%.", onRemove = clearHandToHand },
    C1 = { localizedName = "Disarming Blow", localizedFlavour = "A wrist, a knuckle, a bad angle. Weapons fail long before their owners understand why.", localizedDescription = "Unarmed hits against armed opponents have a 10% chance to damage their weapon condition by Hand-to-Hand / 3.", onRemove = clearHandToHand },
    C2 = { localizedName = "Breaker Grip", localizedFlavour = "Once a weapon starts to fail, every strike knows exactly where to continue.", localizedDescription = "Disarming Blow chance rises to 20%, doubled against weapons below 25% condition.", onRemove = clearHandToHand },
    D1 = { localizedName = "Knockout Blow", localizedFlavour = "You wait for fatigue to hollow them out, then place one clean answer where their body cannot argue.", localizedDescription = "Unarmed hits against targets below 15% fatigue have a 25% chance to paralyze for 3 seconds.", onRemove = clearHandToHand },
    D2 = { localizedName = "Lights Out", localizedFlavour = "The fight ends in a blink, and the floor explains the rest.", localizedDescription = "Knockout Blow chance rises to 50% and duration to 5 seconds.", onRemove = clearHandToHand },
})

return {
    eventHandlers = {
        SPerks_PlayerHitActor = function(attack)
            routeOutgoingHit(attack, "bridge")
        end,
    },
    engineHandlers = { onUpdate = onUpdate, onSave = onSave, onLoad = onLoad },
}
