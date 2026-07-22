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
    SPerks_Block.lua

    Block - "Enemy aggression becomes exhaustion and ruined weapons. The
    shield is a weapon in its own right." See SkillPerks_Combat.md's Block
    section, including its own dedicated Shared Infrastructure Note on
    N'Garde detection.

    N'GARDE DETECTION: centralised once at load time into hasNGarde, per
    the design doc's own explicit instruction ("Centralise this check in a
    single Block script variable"). All N'Garde-enhanced paths have
    vanilla fallbacks.

    BLOCK DETECTION (used by A/B/C chains, all inside the same framework
    hit-pipeline callback):
      With N'Garde:    attack.ngarde_parry or attack.ngarde_perfectParry
      Without N'Garde: attack.successful == true and attack.damage.health == 0
    C chain additionally narrows this WITH N'Garde specifically to
    attack.ngarde_perfectParry only (not attack.ngarde_parry) - see the C
    chain comment below, this is a different, stricter gate than A/B use.

    D chain's spell-landing detection is a COMPLETELY SEPARATE trigger
    (activeSpells polling, not addOnHitHandler at all - a harmful spell
    landing isn't a "hit" in the addOnHitHandler sense). Its N'Garde
    perfect-parry auto-success therefore can't read attack.ngarde_perfectParry
    (there's no attack table for a spell landing) and instead listens for
    the separate confirmed ngarde_parrySelf PLAYER EVENT - see the D chain
    comment below for the full reasoning on why these need different hooks.

    CROSS-ACTOR WRITES (weapon condition damage, fatigue drain, applying a
    spell to the attacker/caster) are routed through Core 0's shared
    global.lua handlers. Player scripts cannot safely write arbitrary
    actor/item state directly.

    "INTERCEPTING CONDITION WRITES" (A chain): same snapshot-then-refund
    approximation already used for Medium Armor C and Armorer B - there's
    no confirmed way to intercept the write itself, so this reads
    condition just after the triggering block, then corrects it back a
    short delay later once the engine's own loss has landed.

    Same no-persistent-effect pattern as the other reactive Combat files:
    the perk registrations declare ownership, while runtime hooks do the
    work when block events actually happen.
]]

local ns         = require("scripts.SkillPerks.namespace")
local interfaces = require("openmw.interfaces")
local types      = require("openmw.types")
local self       = require("openmw.self")
local core       = require("openmw.core")

local ChainRequirements = require("scripts.SkillPerks.shared.chain_requirements")
local CombatMath         = require("scripts.SkillPerks.shared.combat_math")

-- Reads the framework's cached player perk set for quick rank checks.
local function hasPerk(id)
    return interfaces.ErnPerkFramework.playerHasPerk(id)
end

local SKILL_ID = "block"

local ids = {
    A1 = ns .. "_block_a1",
    A2 = ns .. "_block_a2",
    A3 = ns .. "_block_a3",
    A4 = ns .. "_block_a4",
    B1 = ns .. "_block_b1",
    B2 = ns .. "_block_b2",
    C1 = ns .. "_block_c1",
    C2 = ns .. "_block_c2",
    D1 = ns .. "_block_d1",
    D2 = ns .. "_block_d2",
}

-- Centralised once, per the design doc's own Shared Infrastructure Note.
local hasNGarde = CombatMath.hasNGarde()

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
--  A CHAIN - IRON GUARD
-- ============================================================

local A_REDUCTION = { [1] = 0.05, [2] = 0.10, [3] = 0.25, [4] = 0.50 }
local BLOCK_REFUND_DELAY = 0.1

local pendingBlockRefunds = {}

--- Returns the item expected to absorb block/parry condition loss.
--- N'Garde parries with a left-hand shield when present; otherwise it
--- uses the right-hand weapon, including two-handed weapons.
local function getBlockingItem()
    if hasNGarde then
        local left = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedLeft)
        if left and types.Armor.objectIsInstance(left) and types.Armor.record(left).type == types.Armor.TYPE.Shield then
            return left
        end
        return types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    end
    return types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedLeft)
end

local function handleIronGuard()
    local rank = getARank()
    if rank == 0 then
        return
    end
    local item = getBlockingItem()
    if not item or not item:isValid() then
        return
    end
    local itemData = types.Item.itemData(item)
    if not itemData or itemData.condition == nil then
        return
    end
    table.insert(pendingBlockRefunds, {
        item = item,
        before = itemData.condition,
        delay = BLOCK_REFUND_DELAY,
        reduction = A_REDUCTION[rank],
    })
end

local OVERREPAIR_CLAMP_MIN_LOSS = 1

local function sendBlockConditionCorrection(item, before, current, maxCond, reduction)
    if before > maxCond and current <= maxCond then
        local visibleLoss = math.max(0, maxCond - current)
        local estimatedLoss = math.max(OVERREPAIR_CLAMP_MIN_LOSS, visibleLoss)
        core.sendGlobalEvent("SPerks_ModifyItemCondition", {
            item = item,
            value = before - (estimatedLoss * (1 - reduction)),
            maxCondition = before,
        })
        return
    end

    core.sendGlobalEvent("SPerks_ModifyItemCondition", {
        item = item,
        amount = (before - current) * reduction,
        maxCondition = before,
    })
end

local function tickBlockRefunds(dt)
    for i = #pendingBlockRefunds, 1, -1 do
        local entry = pendingBlockRefunds[i]
        entry.delay = entry.delay - dt
        if entry.delay <= 0 then
            if entry.item:isValid() then
                local itemData = types.Item.itemData(entry.item)
                local record = entry.item.type.record(entry.item)
                local maxCond = record.health or record.maxCondition
                local current = itemData.condition or entry.before
                local lost = entry.before - current
                if lost > 0 and maxCond then
                    sendBlockConditionCorrection(entry.item, entry.before, current, maxCond, entry.reduction)
                end
            end
            table.remove(pendingBlockRefunds, i)
        end
    end
end

-- ============================================================
--  B CHAIN - PUNISHING GUARD
-- ============================================================

local FATIGUE_SNAPSHOT_DELAY = 0.1
local pendingFatigueSnapshots = {}

local function handlePunishingGuard(attack)
    local rank = getBRank()
    if rank == 0 then
        return
    end
    local attacker = attack.attacker
    local blockSkill = types.NPC.stats.skills.block(self).modified
    local punishValue = blockSkill / 5

    if attack.weapon == nil then
        -- Unarmed or a weaponless creature: direct health damage instead,
        -- routed through the shared SPerks_TakeDamage handler (Core 0's
        -- npc.lua/creature.lua) since a local script can't write to
        -- another actor's stats directly.
        attacker:sendEvent("SPerks_TakeDamage", { amount = punishValue })
    else
        core.sendGlobalEvent("SPerks_DamageItemCondition", {
            item = attack.weapon,
            amount = punishValue,
        })
    end

    if rank >= 2 then
        -- B2: double the attacker's fatigue cost for the blocked swing.
        -- No confirmed attack-table field for "fatigue this swing cost,"
        -- so measured via a delayed before/after snapshot instead - same
        -- technique as Heavy Armor B2's own swing-fatigue restore,
        -- applied here to the ATTACKER rather than self. Assumes the
        -- attacker's own fatigue deduction for this swing lands within
        -- the snapshot delay window.
        table.insert(pendingFatigueSnapshots, {
            attacker = attacker,
            before = types.Actor.stats.dynamic.fatigue(attacker).current,
            delay = FATIGUE_SNAPSHOT_DELAY,
        })
    end
end

local function tickFatigueSnapshots(dt)
    for i = #pendingFatigueSnapshots, 1, -1 do
        local entry = pendingFatigueSnapshots[i]
        entry.delay = entry.delay - dt
        if entry.delay <= 0 then
            if entry.attacker:isValid() then
                local spent = entry.before - types.Actor.stats.dynamic.fatigue(entry.attacker).current
                if spent > 0 then
                    core.sendGlobalEvent("SPerks_ModifyActorActiveEffect", {
                        target = entry.attacker,
                        effectId = "drainfatigue",
                        amount = spent,
                    })
                end
            end
            table.remove(pendingFatigueSnapshots, i)
        end
    end
end

-- ============================================================
--  C CHAIN - LOADED GUARD
-- ============================================================

local C_COOLDOWN = { [1] = 30, [2] = 20 }
local C_MAGICKA_MULT = { [1] = 1.0, [2] = 0.75 }

local spellCaptured = false
local storedSpellId = nil
local cLastFireTime = -math.huge

local function getMagicEffectRecord(effectParams)
    if type(effectParams) ~= "table" then
        return nil
    end
    if effectParams.effect then
        return effectParams.effect
    end
    if effectParams.id then
        return core.magic.effects.records[effectParams.id]
    end
    return nil
end

local function effectParamsAreHarmful(effectParams)
    local effect = getMagicEffectRecord(effectParams)
    return effect and effect.harmful == true
end

local function pollForSpellCapture()
    if spellCaptured or getCRank() == 0 then
        return
    end
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        local allHarmfulSelf = true
        local hasEffects = false
        for _, effectParams in ipairs(spell.effects or {}) do
            hasEffects = true
            if not effectParamsAreHarmful(effectParams) or effectParams.range ~= core.magic.RANGE.Self then
                allHarmfulSelf = false
                break
            end
        end
        if hasEffects and allHarmfulSelf then
            types.Actor.activeSpells(self):remove(spell.activeSpellId)
            storedSpellId = spell.id
            spellCaptured = true
            break
        end
    end
end

local function fireStoredSpell(attacker)
    local rank = getCRank()
    if rank == 0 or not spellCaptured or not storedSpellId then
        return
    end
    if not attacker or not attacker:isValid() then
        return
    end

    local now = core.getSimulationTime()
    if (now - cLastFireTime) < C_COOLDOWN[rank] then
        return
    end

    local spellRecord = core.magic.spells.records[storedSpellId]
    if not spellRecord then
        return
    end

    local cost = math.floor(spellRecord.cost * C_MAGICKA_MULT[rank])
    local magicka = types.Actor.stats.dynamic.magicka(self)
    magicka.current = math.max(0, magicka.current - cost)

    core.sendGlobalEvent("SPerks_ApplyExistingSpell", {
        target = attacker,
        spellId = storedSpellId,
        caster = self,
        ignoreResistances = false,
    })

    cLastFireTime = now
end

local function clearCState()
    spellCaptured = false
    storedSpellId = nil
end

-- Block perks only react when the player is the defender. This rejects
-- outgoing player attacks that another actor blocks.
local function isIncomingAttackAgainstPlayer(attack)
    if not attack.attacker or not attack.attacker:isValid() then
        return false
    end
    if attack.attacker == self then
        return false
    end
    if attack.target and attack.target ~= self then
        return false
    end
    return true
end

-- ============================================================
--  SHARED HIT HANDLER (A + B + C)
-- ============================================================

-- Registers Block's reactive effects with the framework hit pipeline.
interfaces.ErnPerkFramework.registerOnHitHandler({
    id = ns .. "_block_on_hit",
    handler = function(attack)
        if not isIncomingAttackAgainstPlayer(attack) then
            return
        end

        local blockSuccess
        if hasNGarde then
            blockSuccess = attack.ngarde_parry == true or attack.ngarde_perfectParry == true
        else
            blockSuccess = attack.successful == true and attack.damage ~= nil and attack.damage.health == 0
        end
        if not blockSuccess then
            return
        end

        handleIronGuard()
        handlePunishingGuard(attack)

        -- C chain's trigger is STRICTER with N'Garde than A/B's blockSuccess
        -- gate above - only a genuine perfect parry qualifies, not any parry.
        local cTrigger = hasNGarde and (attack.ngarde_perfectParry == true) or blockSuccess
        if cTrigger then
            fireStoredSpell(attack.attacker)
        end
    end,
})

-- ============================================================
--  D CHAIN - SPELL GUARD
--  Completely separate trigger from A/B/C - a harmful spell LANDING on
--  the player is not an addOnHitHandler event. Detected via activeSpells
--  polling instead, tracking previously-seen activeSpellIds to find NEW
--  arrivals each tick.
-- ============================================================

local D2_REFLECT_COOLDOWN = 10
local dReflectLastTime = -math.huge
local knownActiveSpellIds = {}

-- N'Garde's perfect-parry auto-success (D1) can't read an attack table
-- here (there isn't one for a spell landing), so it listens for the
-- separate confirmed ngarde_parrySelf PLAYER EVENT instead, and holds a
-- short-lived flag for the next spell-poll tick to consume. FLAGGED: the
-- exact timing relationship between a melee ngarde_parrySelf firing and a
-- harmful spell showing up in activeSpells is not something this mod
-- controls or has confirmed - the design doc calls for this cross-system
-- interaction explicitly, but its real-world timing needs testing.
local PERFECT_PARRY_WINDOW = 0.5
local pendingPerfectParry = false
local pendingPerfectParryTimer = 0

local function onNGardeParrySelf(data)
    if data and data.isPerfect then
        pendingPerfectParry = true
        pendingPerfectParryTimer = PERFECT_PARRY_WINDOW
    end
end

--- Vanilla block formula with attacker hit chance forced to 0 (spell
--- sources have no weapon-hit-chance side), per the design doc. The doc
--- flags the exact comparison as "TBD pending balance testing" - this
--- treats CombatMath.getBlockRate's return value directly as a 0-100
--- percent chance (algebraically consistent with the same formula's use
--- elsewhere for physical hit%), clamped defensively. Open to being
--- replaced with a genuine flat threshold once that's decided.
local function rollSpellBlockChance()
    local blockRate = CombatMath.getBlockRate(self, {})
    local chance = math.max(0, math.min(100, blockRate))
    return (math.random() * 100) <= chance
end

local function handleIncomingHarmfulSpell(spell)
    local rank = getDRank()
    if rank == 0 then
        return
    end

    local success = rollSpellBlockChance()
    if hasNGarde and pendingPerfectParry then
        success = true
    end
    pendingPerfectParry = false

    if not success then
        return
    end

    -- Negation always works, even during D2's reflection-only cooldown.
    types.Actor.activeSpells(self):remove(spell.activeSpellId)

    if rank >= 2 and spell.caster and spell.caster:isValid() then
        local now = core.getSimulationTime()
        if (now - dReflectLastTime) >= D2_REFLECT_COOLDOWN then
            -- "No caster attribution" per the doc - passing nil first;
            -- if in-game testing shows the API requires one, the doc's
            -- own fallback is to use self instead.
            core.sendGlobalEvent("SPerks_ApplyExistingSpell", {
                target = spell.caster,
                spellId = spell.id,
                caster = nil,
                ignoreResistances = false,
            })
            dReflectLastTime = now
        end
    end
end

local function pollForHarmfulSpells()
    if getDRank() == 0 then
        return
    end
    local currentIds = {}
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        local activeSpellId = spell.activeSpellId
        if activeSpellId then
            currentIds[activeSpellId] = true
        end
        if activeSpellId and not knownActiveSpellIds[activeSpellId] then
            local isHarmful = false
            for _, effectParams in ipairs(spell.effects or {}) do
                if effectParamsAreHarmful(effectParams) then
                    isHarmful = true
                    break
                end
            end
            if isHarmful then
                handleIncomingHarmfulSpell(spell)
            end
        end
    end
    knownActiveSpellIds = currentIds
end

-- ============================================================
--  ENGINE CALLBACKS
-- ============================================================

local function onUpdate(dt)
    tickBlockRefunds(dt)
    tickFatigueSnapshots(dt)
    pollForSpellCapture()
    pollForHarmfulSpells()

    if pendingPerfectParry then
        pendingPerfectParryTimer = pendingPerfectParryTimer - dt
        if pendingPerfectParryTimer <= 0 then
            pendingPerfectParry = false
        end
    end
end

local function onSave()
    return {
        spellCaptured = spellCaptured,
        storedSpellId = storedSpellId,
        -- Per the design doc: D2's reflection cooldown timestamp IS meant
        -- to persist (unlike C's own cooldown, which the doc does not
        -- list as persisted - resets to "ready" on load, consistent with
        -- every other moment-to-moment timer in this mod).
        dReflectLastTime = dReflectLastTime,
    }
end

local function onLoad(data)
    data = data or {}
    spellCaptured = data.spellCaptured or false
    storedSpellId = data.storedSpellId
    dReflectLastTime = data.dReflectLastTime or -math.huge

    cLastFireTime = -math.huge
    pendingBlockRefunds = {}
    pendingFatigueSnapshots = {}
    knownActiveSpellIds = {}
    pendingPerfectParry = false
    pendingPerfectParryTimer = 0
end

-- ============================================================
--  PERK REGISTRATIONS
-- ============================================================

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A1,
    localizedName = "Iron Guard",
    category = ChainRequirements.category("Combat", "Block", 1),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You meet the blow where it is weakest, turning violence into a dull shudder through wood, steel, and bone.",
    localizedDescription = "Successful blocks reduce condition damage dealt to the blocking "
        .. "item by 5%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A2,
    localizedName = "Steady Grip",
    category = ChainRequirements.category("Combat", "Block", 2),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your grip no longer flinches at impact. The strike slides away, robbed of the force it came to spend.",
    localizedDescription = "The condition damage reduction increases to 10%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A3,
    localizedName = "Unyielding Guard",
    category = ChainRequirements.category("Combat", "Block", 3),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Where others brace and pray, you set your guard and endure. The weapon breaks its promise before your defence breaks form.",
    localizedDescription = "The condition damage reduction increases to 25%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A3"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.A4,
    localizedName = "Immaculate Defense",
    category = ChainRequirements.category("Combat", "Block", 4),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your defence has become a craft of denial. Blades find no purchase, hammers find no weakness, and time finds little to wear away.",
    localizedDescription = "The condition damage reduction increases to 50%.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "A4"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B1,
    localizedName = "Punishing Guard",
    category = ChainRequirements.category("Combat", "Block", 5),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Your guard does not merely survive the strike. It answers through the attacker's own weapon, shaking haft, edge, and hand alike.",
    localizedDescription = "Successful blocks deal condition damage to the attacker's weapon "
        .. "equal to your Block skill divided by 5. Unarmed attackers, or creatures with no "
        .. "weapon, take that same value as direct health damage instead.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.B2,
    localizedName = "Crushing Riposte",
    category = ChainRequirements.category("Combat", "Block", 6),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Each blocked swing is made to feel heavier in hindsight. Your enemy spends strength twice: once to strike, once to recover.",
    localizedDescription = "The fatigue cost of a blocked attack is doubled for the attacker.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "B2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C1,
    localizedName = "Loaded Guard",
    category = ChainRequirements.category("Combat", "Block", 7),
    art = "textures\\levelup\\knight",
    localizedFlavour = "A hostile spell can be held like a drawn blade behind your guard, waiting for the next fool who mistakes patience for mercy.",
    localizedDescription = "The first harmful spell you cast on yourself after taking this "
        .. "perk is negated and stored permanently instead of being cast. On your next "
        .. "successful block (or perfect parry, with N'Garde), the stored spell fires at your "
        .. "attacker - you pay its full Magicka cost. 30 second cooldown between firings. The "
        .. "stored spell is never consumed, and is only cleared if you lose this perk or respec.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C1"),
    onAdd = noPersistentEffect,
    onRemove = clearCState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.C2,
    localizedName = "Primed Retaliation",
    category = ChainRequirements.category("Combat", "Block", 9),
    art = "textures\\levelup\\knight",
    localizedFlavour = "The magic behind your shield no longer strains against your will. It waits sharper, lighter, and far more eager to be loosed.",
    localizedDescription = "The stored spell's Magicka cost is reduced by 25%, and the cooldown "
        .. "between firings drops to 20 seconds.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "C2"),
    onAdd = noPersistentEffect,
    onRemove = clearCState,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D1,
    localizedName = "Spell Guard",
    category = ChainRequirements.category("Combat", "Block", 8),
    art = "textures\\levelup\\knight",
    localizedFlavour = "You have learned to raise your guard against more than iron. A curse has weight, a spell has direction, and both can be turned aside.",
    localizedDescription = "When a harmful spell affects you, roll your block chance against "
        .. "it as if it were a weapon. On success, the spell is negated entirely. With N'Garde, "
        .. "a perfect parry auto-succeeds this roll regardless of your block chance.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D1"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

interfaces.ErnPerkFramework.registerPerk({
    id = ids.D2,
    localizedName = "Returned Malice",
    category = ChainRequirements.category("Combat", "Block", 10),
    art = "textures\\levelup\\knight",
    localizedFlavour = "Malice denied does not vanish. Under your guard it remembers its maker, turns, and hurries home.",
    localizedDescription = "On a successful spell block, the spell is also reflected back at "
        .. "its caster with no attribution to you. 10 second cooldown on the reflection only - "
        .. "negation keeps working even while it's on cooldown.",
    requirements = ChainRequirements.forSlot(SKILL_ID, ids, "D2"),
    onAdd = noPersistentEffect,
    onRemove = noPersistentEffect,
})

return {
    eventHandlers = {
        ngarde_parrySelf = onNGardeParrySelf,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
}
