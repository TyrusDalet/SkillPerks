--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Unarmored turns empty equipment slots into a casting focus. All persistent
bonuses use delta trackers so reloads and respecs cannot duplicate them.
]]

local animation = require("openmw.animation")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local self = require("openmw.self")

local Common = require("scripts.SkillPerks.magic.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local ids = Common.ids("unarmored")
local effectTracker = StatTracker.newActiveEffectTracker(self)
local CALCULATION = interfaces.ErnPerkFramework.CALCULATION
local OPERATION = interfaces.ErnPerkFramework.CALCULATION_OPERATION

local ARMOR_SLOTS = {
    types.Actor.EQUIPMENT_SLOT.Helmet, types.Actor.EQUIPMENT_SLOT.Cuirass,
    types.Actor.EQUIPMENT_SLOT.Greaves, types.Actor.EQUIPMENT_SLOT.LeftPauldron,
    types.Actor.EQUIPMENT_SLOT.RightPauldron, types.Actor.EQUIPMENT_SLOT.LeftGauntlet,
    types.Actor.EQUIPMENT_SLOT.RightGauntlet, types.Actor.EQUIPMENT_SLOT.Boots,
    types.Actor.EQUIPMENT_SLOT.CarriedLeft,
}
local A_SOUND = { -2, -3, -5, -5 }
local A_SHIELD = { 1, 2, 3, 5 }
local C_RESIST = { 4, 4 }
local C_ABSORB = { 0, 2.5 }
local updateTimer = 0

local function rank(chain) return Common.rank(ids, chain) end

local function emptySlots()
    local count = 0
    for _, slot in ipairs(ARMOR_SLOTS) do
        local item = types.Actor.getEquipment(self, slot)
        if not item or not types.Armor.objectIsInstance(item) then count = count + 1 end
    end
    return count
end

local function mostlyUnarmored()
    return emptySlots() >= 7
end

local function fullyUnarmored()
    return emptySlots() == #ARMOR_SLOTS
end

local function refreshPassives()
    local empty = emptySlots()
    local a = rank("A")
    effectTracker.apply("sound", nil, a > 0 and A_SOUND[a] * empty or 0)
    effectTracker.apply("shield", nil, a > 0 and A_SHIELD[a] * empty or 0)

    local c = rank("C")
    effectTracker.apply("resistmagicka", nil, c > 0 and C_RESIST[c] * empty or 0)
    effectTracker.apply("spellabsorption", nil, c > 0 and C_ABSORB[c] * empty or 0)

    local d = rank("D")
    local sanctuary = 0
    if d >= 2 and fullyUnarmored() then
        local agility = types.Actor.stats.attributes.agility(self).modified
        local luck = types.Actor.stats.attributes.luck(self).modified
        local fatigueRatio = Common.dynamicRatio(self, "fatigue")
        local fatigueMultiplier = 0.75 + 0.5 * fatigueRatio
        sanctuary = math.max(0, (agility / 5 + luck / 10) * (1.25 - fatigueMultiplier))
    end
    effectTracker.apply("sanctuary", nil, sanctuary)
    SkillDebug.traceState("unarmored","Unarmored passives","passives",{
        aRank=a,cRank=c,dRank=d,emptySlots=empty,
        fullyUnarmored=fullyUnarmored(),sanctuary=sanctuary,
        shield=a > 0 and A_SHIELD[a] * empty or 0,
        sound=a > 0 and A_SOUND[a] * empty or 0,
        spellAbsorption=c > 0 and C_ABSORB[c] * empty or 0,
        resistMagicka=c > 0 and C_RESIST[c] * empty or 0,
    })
end

interfaces.ErnPerkFramework.registerCalculationHandler({
    id = "SkillPerks_unarmored_body_as_focus_health",
    calculation = CALCULATION.HIT_DAMAGE_HEALTH,
    operation = OPERATION.Modifier,
    priority = 700,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
    handler = function(data)
        local trace=SkillDebug.beginTrace("unarmored","Body as Focus","incoming Health calculation",{
            damage = data and data.value,
            fatigueRatio = Common.dynamicRatio(self, "fatigue"),
            fullyUnarmored = fullyUnarmored(),
        })
        local d=rank("D")
        if d == 0 then
            trace:reject("D chain inactive")
            return nil
        end
        if not fullyUnarmored() then
            trace:reject("armor gate failed",{emptySlots=emptySlots(),required=#ARMOR_SLOTS})
            return nil
        end
        local fatigueRatio=Common.dynamicRatio(self, "fatigue")
        if fatigueRatio < 0.25 then
            trace:reject("Fatigue below 25% threshold",{fatigueRatio=fatigueRatio})
            return nil
        end
        local converted = math.max(0, data.value * 0.75)
        local resolved=interfaces.ErnPerkFramework.applyActorResourceDelta({
            actor = self, resource = "fatigue",
            operation = interfaces.ErnPerkFramework.RESOURCE_OPERATION.Damage,
            amount = converted, source = data.source, sourceEffect = ids.D1,
            context = { convertedFromHealth = true },
        })
        local remaining=data.value-converted
        trace:finish("Health damage converted",{
            fatigueRequested=converted,fatigueResolved=resolved,
            healthIncoming=data.value,healthRemaining=remaining,
        })
        return remaining
    end,
})

local function updateCastingSpeed()
    local speed = 1
    local b = rank("B")
    if b > 0 and mostlyUnarmored() then speed = b == 2 and 2.00 or 1.50 end
    pcall(animation.setSpeed, self, "spellcast", speed)
    SkillDebug.traceState("unarmored","Unburdened Casting","casting-speed",{
        bRank=b,emptySlots=emptySlots(),mostlyUnarmored=mostlyUnarmored(),speed=speed,
    })
end

local function clear()
    effectTracker.clearAll()
    pcall(animation.setSpeed, self, "spellcast", 1)
end

local function onUpdate(dt)
    updateTimer = updateTimer - dt
    if updateTimer > 0 then return end
    updateTimer = 0.2
    refreshPassives()
    updateCastingSpeed()
end

-- Confirms empty-slot gates and the resources used by Body as Focus.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Unarmored",
    skillId = "unarmored",
    actor = self,
    ids = ids,
    commands = { "luaunarmored debug", "luaunarm debug" },
    snapshot = function()
        return {
            string.format(
                "Armor gate: emptySlots=%d/%d mostlyUnarmored=%s",
                emptySlots(),
                #ARMOR_SLOTS,
                tostring(mostlyUnarmored())
            ),
            "Health: " .. SkillDebug.resourceSummary(self, "health"),
            "Fatigue: " .. SkillDebug.resourceSummary(self, "fatigue"),
        }
    end,
})

Common.registerMagicPerks("unarmored", "Unarmored", ids, {
    A1={localizedName="Empty Hand Discipline",localizedFlavour="Steel is a crutch. Your body has learned to carry the ward itself.",localizedDescription="Each empty armor slot grants -2 Sound and +1 Shield.",onAdd=refreshPassives,onRemove=clear},
    A2={localizedName="Unencumbered Form",localizedFlavour="Every discarded plate leaves another channel open to your will.",localizedDescription="Each empty armor slot now grants -3 Sound and +2 Shield.",onAdd=refreshPassives,onRemove=clear},
    A3={localizedName="Ninefold Guard",localizedFlavour="There is no gap in armor that was never worn.",localizedDescription="Each empty armor slot now grants -5 Sound and +3 Shield.",onAdd=refreshPassives,onRemove=clear},
    A4={localizedName="Living Aegis",localizedFlavour="Flesh, breath, and spell become the only armor worth trusting.",localizedDescription="Each empty armor slot now grants -5 Sound and +5 Shield.",onAdd=refreshPassives,onRemove=clear},
    B1={localizedName="Unburdened Casting",localizedFlavour="Without iron dragging at the gesture, magic answers before thought is finished.",localizedDescription="While mostly unarmored, spellcasting animations are 50% faster.",onRemove=clear},
    B2={localizedName="Thought Before Motion",localizedFlavour="The spell is already formed when lesser mages begin to raise their hands.",localizedDescription="While mostly unarmored, spellcasting animations are 100% faster.",onRemove=clear},
    C1={localizedName="Focused Flesh",localizedFlavour="Bare skin teaches hostile magic that you are not undefended, merely unafraid.",localizedDescription="Each empty armor slot grants 4% Resist Magicka.",onAdd=refreshPassives,onRemove=clear},
    C2={localizedName="Soul-Sheathed",localizedFlavour="Your body does not merely resist sorcery. It drinks from the blow.",localizedDescription="Each empty armor slot additionally grants 2.5% Spell Absorption.",onAdd=refreshPassives,onRemove=clear},
    D1={localizedName="Body as Focus",localizedFlavour="Pain strikes the body and is carried away through motion, breath, and exhaustion.",localizedDescription="While completely unarmored and above 25% Fatigue, convert 75% of incoming Health damage into Fatigue damage.",onRemove=clear},
    D2={localizedName="Untouchable Centre",localizedFlavour="The weapon finds only the place where disciplined flesh has ceased to be.",localizedDescription="While completely unarmored, gain scaling Sanctuary from Agility, Luck, and current Fatigue.",onAdd=refreshPassives,onRemove=clear},
})

return {
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = function() return { effects = effectTracker.snapshot() } end,
        onLoad = function(data)
            effectTracker.restoreAndReverse(data and data.effects)
            updateTimer = 0
        end,
    },
}
