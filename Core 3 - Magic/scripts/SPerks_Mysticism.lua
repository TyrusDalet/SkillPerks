--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Mysticism gives Soultrap an immediate payoff and makes Telekinesis a genuine
force effect. Target-local stagger and tether state live in Core 0.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local self = require("openmw.self")

local Common = require("scripts.SkillPerks.magic.common")
local MagicDetection = require("scripts.SkillPerks.shared.magic_detection")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local ids = Common.ids("mysticism")
local effects = StatTracker.newActiveEffectTracker(self)
local updateTimer = 0
local echoedTargets = {}

local function rank(chain) return Common.rank(ids, chain) end

local function soulValue(target)
    if types.Creature.objectIsInstance(target) then
        return tonumber(types.Creature.record(target).soulValue) or 0
    end
    return 0
end

local function deficientEquipped()
    local result, seen = {}, {}
    local right = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    local selected = types.Actor.getSelectedEnchantedItem(self)
    local function add(item, tier)
        if not item or seen[item] then return end
        local maximum = MagicDetection.getMaxChargeOf(item)
        local itemData = types.Item.itemData(item)
        local current = itemData and tonumber(itemData.enchantmentCharge)
        if maximum and current and current < maximum then
            seen[item] = true
            table.insert(result, { item=item, maximum=maximum, current=current, tier=tier })
        end
    end
    add(right, 1) add(selected, 2)
    for _, item in pairs(types.Actor.getEquipment(self)) do add(item, 3) end
    table.sort(result, function(a,b)
        return a.tier == b.tier and a.current < b.current or a.tier < b.tier
    end)
    return result
end

local function distributeCharge(amount)
    local trace=SkillDebug.beginTrace("mysticism","Echo of the Soul","charge distribution",{
        requested=amount,
    })
    local granted = 0
    for _, entry in ipairs(deficientEquipped()) do
        if amount <= 0 then break end
        local add = math.min(amount, entry.maximum - entry.current)
        local itemData = types.Item.itemData(entry.item)
        itemData.enchantmentCharge = entry.current + add
        amount, granted = amount - add, granted + add
        trace:step("item charged",{
            amount=add,item=SkillDebug.objectId(entry.item),
            newCharge=entry.current+add,remaining=amount,
        })
    end
    if granted<=0 then trace:reject("no deficient equipped enchanted item")
    else trace:finish("charge distributed",{granted=granted,unused=amount}) end
    return granted
end

local function onSpellLanded(data)
    local trace=SkillDebug.beginTrace("mysticism","Soultrap perks","landed magic-effect event",{
        spell = data and data.spellId,
        target = data and SkillDebug.objectId(data.target),
    })
    if not data or not data.target or not data.target:isValid() then
        return trace:reject("target is missing or unavailable")
    end
    if not Common.isPlayerCastLandedSpell(data) then
        return trace:reject("source is not an allowed player-cast spell")
    end
    local soultrap
    for _, effect in ipairs(data.effects or {}) do
        if effect.id == "soultrap" then soultrap = effect break end
    end
    if not soultrap then return trace:reject("landed spell contains no Soultrap effect") end

    local value = soulValue(data.target)
    local a = rank("A")
    local key = tostring(data.target)
    if a > 0 and not echoedTargets[key] then
        local rate = ({ 0.05, 0.10, 0.15, 0.25 })[a]
        local requested=math.floor(value * rate)
        trace:step("Echo of the Soul calculated",{
            aRank=a,rate=rate,requestedCharge=requested,soulValue=value,
        })
        local granted=distributeCharge(requested)
        if granted > 0 then
            echoedTargets[key] = true
            data.target:sendEvent("SPerks_MysticismConfirmEcho", { caster=self })
            trace:step("Echo of the Soul confirmed",{granted=granted,targetKey=key})
        else
            trace:step("Echo of the Soul produced no charge",{requested=requested})
        end
    elseif a == 0 then
        trace:step("Echo of the Soul skipped",{reason="A chain inactive"})
    else
        trace:step("Echo of the Soul skipped",{reason="target already echoed",targetKey=key})
    end

    local b = rank("B")
    if b > 0 then
        local duration = math.max(1, tonumber(soultrap.durationLeft or soultrap.duration) or 1)
        -- The target owns the authoritative non-stacking gate. It sends an
        -- acceptance event back only when no live tether exists; applying the
        -- Absorb spell before that acknowledgement allowed repeated Soultraps
        -- to queue multiple global spell requests.
        data.target:sendEvent("SPerks_MysticismSetTether", {
            caster=self, soulValue=value, burst=b >= 2,
            duration=duration, magnitude=b,
            expiresAt=core.getSimulationTime() + duration,
        })
        trace:step("Soul Tether acceptance requested",{
            bRank=b,burst=b>=2,duration=duration,magnitude=b,soulValue=value,
        })
    else
        trace:step("Soul Tether skipped",{reason="B chain inactive"})
    end
    trace:finish("Soultrap perk processing complete",{aRank=a,bRank=b})
end

local function onActorActivated(data)
    local d = rank("D")
    local target = data and data.target
    local trace=SkillDebug.beginTrace("mysticism","Telekinetic Force","actor activated",{
        dRank = d,
        target = SkillDebug.objectId(target),
    })
    if d == 0 then return trace:reject("D chain inactive") end
    if not target or not target:isValid() then return trace:reject("target unavailable") end
    local telekinesis=Common.playerSpellEffectMagnitude(self, "telekinesis")
    if telekinesis <= 0 then
        return trace:reject("no qualifying player-cast Telekinesis",{magnitude=telekinesis})
    end
    local hostile = true
    if types.NPC.objectIsInstance(target) then
        local fight = types.Actor.stats.ai.fight(target)
        hostile = fight and fight.modified >= 50
    end
    if not hostile then return trace:reject("target is not hostile") end
    local cost = d == 2 and 15 or 25
    local magicka = types.Actor.stats.dynamic.magicka(self)
    if magicka.current < cost then
        return trace:reject("insufficient Magicka",{cost=cost,current=magicka.current})
    end
    local resolved=interfaces.ErnPerkFramework.applyActorResourceDelta({
        actor=self,resource="magicka",
        operation=interfaces.ErnPerkFramework.RESOURCE_OPERATION.Damage,
        amount=cost,source=self,sourceEffect=ids["D"..d],
        context={telekineticForce=true},
    })
    local mysticism = types.NPC.stats.skills.mysticism(self).modified
    local willpower = types.Actor.stats.attributes.willpower(self).modified
    local drain=math.ceil(mysticism / 2 + willpower / 10)
    trace:step("force calculated",{
        costRequested=cost,costResolved=resolved,drainAmount=drain,
        mysticism=mysticism,willpower=willpower,
    })
    target:sendEvent("SPerks_MysticismStaggerAttempt", {
        caster=self,drainAmount=drain, isD2=d >= 2,
    })
    trace:finish("stagger attempt delivered",{knockdownCheck=d>=2})
end

local function refreshHungrySoul()
    local c = rank("C")
    local cap = c == 2 and 50 or c == 1 and 25 or 0
    local ratio = Common.dynamicRatio(self, "magicka")
    local amount = ratio < 0.5 and cap * (1 - ratio / 0.5) or 0
    effects.apply("spellabsorption", nil, amount)
    SkillDebug.traceState("mysticism","Hungry Soul","passive",{
        absorption=amount,cRank=c,magickaRatio=ratio,maximum=cap,
    })
end

local function clear()
    effects.clearAll()
    echoedTargets = {}
end

local function onUpdate(dt)
    updateTimer = updateTimer - dt
    if updateTimer <= 0 then updateTimer = 0.2 refreshHungrySoul() end
end

-- Shows soul-echo target memory and the resources used by Mysticism riders.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Mysticism",
    skillId = "mysticism",
    actor = self,
    ids = ids,
    commands = { "luamysticism debug", "luamyst debug" },
    snapshot = function()
        return {
            string.format("Echoed targets=%d updateTimer=%s", SkillDebug.count(echoedTargets), SkillDebug.number(updateTimer)),
            "Magicka: " .. SkillDebug.resourceSummary(self, "magicka"),
            "Fatigue: " .. SkillDebug.resourceSummary(self, "fatigue"),
        }
    end,
})

Common.registerMagicPerks("mysticism", "Mysticism", ids, {
    A1={localizedName="Echo of the Soul",localizedFlavour="The soul answers the trap before the gem has even learned its name.",localizedDescription="The first Soultrap on an actor converts 5% of its soul value into charge for equipped enchanted items.",onRemove=clear},
    A2={localizedName="Resonant Capture",localizedFlavour="The captive spirit rings through every prepared vessel you carry.",localizedDescription="Echo of the Soul converts 10%.",onRemove=clear},
    A3={localizedName="Deep Resonance",localizedFlavour="You hear power in the instant between possession and imprisonment.",localizedDescription="Echo of the Soul converts 15%.",onRemove=clear},
    A4={localizedName="Perfect Soul Circuit",localizedFlavour="No captured essence crosses your grasp without leaving power behind.",localizedDescription="Echo of the Soul converts 25%.",onRemove=clear},
    B1={localizedName="Soul Tether",localizedFlavour="Once hooked, the spirit pays a slow toll for every second it resists.",localizedDescription="Soultrap also applies a non-stacking 1 point per second Absorb Magicka for its duration. Recasting Soultrap does not refresh it.",onRemove=clear},
    B2={localizedName="Final Dividend",localizedFlavour="When the tether snaps in death, its last recoil floods back into you.",localizedDescription="Soul Tether rises to 2 points per second; death during it restores 20% of the target's soul value as Magicka.",onRemove=clear},
    C1={localizedName="Hungry Soul",localizedFlavour="An empty reserve is not weakness. It is an invitation hostile magic cannot refuse.",localizedDescription="Below 50% Magicka, gain scaling Spell Absorption up to 25%.",onAdd=refreshHungrySoul,onRemove=clear},
    C2={localizedName="Abyssal Appetite",localizedFlavour="The less power remains yours, the more eagerly your soul devours another's.",localizedDescription="Hungry Soul's cap increases to 50%.",onAdd=refreshHungrySoul,onRemove=clear},
    D1={localizedName="Telekinetic Force",localizedFlavour="Telekinesis was never merely the art of touching distant objects.",localizedDescription="While Telekinesis is active, activating a hostile actor spends 25 Magicka, drains Fatigue, and staggers them.",onRemove=clear},
    D2={localizedName="Invisible Hammer",localizedFlavour="Distance becomes leverage. Will becomes impact.",localizedDescription="Cost falls to 15 Magicka; targets that fail a Willpower and Fatigue resistance roll are knocked down.",onRemove=clear},
})

return {
    eventHandlers = {
        SPerks_MagicEffectLanded = onSpellLanded,
        SPerks_MagicActorActivated = onActorActivated,
        SPerks_MysticismTetherAccepted = function(data)
            local trace=SkillDebug.beginTrace(
                "mysticism",
                "Soul Tether",
                "target accepted tether",
                {
                    duration=data and data.duration,
                    magnitude=data and data.magnitude,
                    target=data and SkillDebug.objectId(data.target),
                }
            )
            if not data or not data.target or not data.target:isValid() then
                return trace:reject("accepted tether target is unavailable")
            end
            trace:finish("target-local Magicka transfer started",{
                duration=math.max(1,tonumber(data.duration) or 1),
                magnitude=math.max(1,tonumber(data.magnitude) or 1),
            })
        end,
        SPerks_MysticismTetherTick = function(data)
            Common.restoreResource(self,"magicka",data and data.amount or 0,ids.B1)
        end,
        SPerks_MysticismSoulTetherBurst = function(data)
            Common.restoreResource(self, "magicka", data and data.amount or 0, ids.B2)
        end,
    },
    engineHandlers = {
        onConsoleCommand=onConsoleCommand,
        onUpdate=onUpdate,
        onSave=function() return { effects=effects.snapshot() } end,
        onLoad=function(data) effects.restoreAndReverse(data and data.effects) echoedTargets={} end,
    },
}
