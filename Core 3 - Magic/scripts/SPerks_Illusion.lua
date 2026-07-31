--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Illusion rewards confirmed spell outcomes rather than cast attempts. Target
effects arrive through Core 0's shared landed-spell bridge.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local nearby = require("openmw.nearby")
local types = require("openmw.types")
local self = require("openmw.self")

local Common = require("scripts.SkillPerks.magic.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local ids = Common.ids("illusion")
local effects = StatTracker.newActiveEffectTracker(self)
local theftStats = StatTracker.newStatModTracker(self, "Illusion Mind Games")
local pendingChecks, thefts = {}, {}
local pollTimer = 0

local function rank(chain) return Common.rank(ids, chain) end
local function hasEffect(data, id)
    for _, effect in ipairs(data.effects or {}) do
        if effect.id == id then return effect end
    end
end

local function rebuildTheftBonus()
    local totals = { strength=0, endurance=0, agility=0, speed=0 }
    for _, drains in pairs(thefts) do
        for attribute, amount in pairs(drains) do totals[attribute] = totals[attribute] + amount end
    end
    for attribute, amount in pairs(totals) do
        theftStats.apply("attributes", attribute, amount)
    end
    SkillDebug.traceState("illusion","Mind Theft","theft-bonuses",{
        activeTargets=SkillDebug.count(thefts),totals=totals,
    })
end

local function onMindTheftDelta(data)
    local trace=SkillDebug.beginTrace("illusion","Mind Theft","target delta received",{
        key = data and data.key,
        remove = data and data.remove,
    })
    if not data or not data.key then return trace:reject("delta has no target key") end
    if data.remove then thefts[data.key] = nil else thefts[data.key] = data.drains or {} end
    trace:step(data.remove and "target theft removed" or "target theft stored",{
        drains=data.drains,key=data.key,
    })
    rebuildTheftBonus()
    trace:finish("player attribute bonuses reconciled")
end

local function onSpellLanded(data)
    local trace=SkillDebug.beginTrace("illusion","Illusion landed effects","landed magic-effect event",{
        spell = data and data.spellId,
        target = data and SkillDebug.objectId(data.target),
    })
    if not data or not data.target or not data.target:isValid() then
        return trace:reject("target is missing or unavailable")
    end
    if not Common.isPlayerCastLandedSpell(data) then
        return trace:reject("source is not an allowed player-cast spell")
    end
    local a=rank("A")
    local paralyze=hasEffect(data,"paralyze")
    if a >= 3 and paralyze then
        data.target:sendEvent("SPerks_IllusionMindTheft", {
            caster = self, activeSpellId = data.activeSpellId,
        })
        trace:step("Mind Theft delivered",{aRank=a,activeSpellId=data.activeSpellId})
    else
        trace:step("Mind Theft skipped",{aRank=a,hasParalyze=paralyze~=nil})
    end
    local calm=hasEffect(data,"calmhumanoid") or hasEffect(data,"calmcreature")
    if a >= 4 and calm then
        data.target:sendEvent("SPerks_IllusionClearAlarm", { caster=self })
        trace:step("Clear Alarm delivered",{aRank=a,calmEffect=calm.id})
    else
        trace:step("Clear Alarm skipped",{aRank=a,hasCalm=calm~=nil})
    end
    local charm = hasEffect(data, "charm")
    local d = rank("D")
    if d > 0 and charm and types.NPC.objectIsInstance(data.target) then
        local disposition = types.NPC.getDisposition(data.target, self)
        local magnitude = tonumber(charm.magnitude) or Common.averageMagnitude(charm)
        local projected=disposition+magnitude
        trace:step("Total Devotion threshold calculated",{
            charmMagnitude=magnitude,dRank=d,disposition=disposition,projected=projected,
        })
        if projected > 100 then
            Common.applyDynamicSpell(data.target, self, "Total Devotion", {{
                id = "commandhumanoid", magnitudeMin = d == 2 and 25 or 10,
                duration = charm.duration or 1,
            }})
            trace:step("Total Devotion queued",{commandMagnitude=d==2 and 25 or 10})
        else
            trace:step("Total Devotion skipped",{reason="projected disposition does not exceed 100"})
        end
    else
        trace:step("Total Devotion skipped",{
            dRank=d,hasCharm=charm~=nil,isNpc=types.NPC.objectIsInstance(data.target),
        })
    end
    trace:finish("landed Illusion effects processed")
end

interfaces.ErnPerkFramework.registerOnHitHandler({
    id = "SkillPerks_illusion_mind_games_hit", priority = 650,
    direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
    handler = function(attack)
        local trace=SkillDebug.beginTrace("illusion","Mind Games","incoming hit resolved",{
            successful = attack and attack.successful,
        })
        local a=rank("A")
        if attack.successful ~= false then return trace:reject("attack did not miss") end
        if a < 2 then return trace:reject("A2 is not owned",{aRank=a}) end
        local sanctuary=Common.playerSpellEffectMagnitude(self,"sanctuary")
        if sanctuary<=0 then return trace:reject("no qualifying player-cast Sanctuary",{magnitude=sanctuary}) end
        local resolved=Common.restoreResource(self, "fatigue", 5, ids.A2)
        trace:finish("Fatigue restored",{requested=5,resolved=resolved,sanctuary=sanctuary})
    end,
})

local function reduction()
    local c = rank("C")
    local trace=SkillDebug.beginTrace("illusion","Unshaken Mind","incoming damage calculation",{
        canMove=types.Actor.canMove(self),cRank=c,
    })
    if c == 0 then trace:reject("C chain inactive") return nil end
    if types.Actor.canMove(self) then trace:reject("player is not paralysed") return nil end
    local divider=c == 2 and 2 or 1.25
    trace:finish("damage divider returned",{divider=divider})
    return divider
end
for _, calculation in ipairs({
    interfaces.ErnPerkFramework.CALCULATION.HIT_DAMAGE_HEALTH,
    interfaces.ErnPerkFramework.CALCULATION.HIT_DAMAGE_FATIGUE,
}) do
    interfaces.ErnPerkFramework.registerCalculationHandler({
        id = "SkillPerks_illusion_unshaken_" .. calculation,
        calculation = calculation,
        operation = interfaces.ErnPerkFramework.CALCULATION_OPERATION.Divider,
        priority = 650,
        direction = interfaces.ErnPerkFramework.HIT_DIRECTION.Incoming,
        handler = reduction,
    })
end

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id = "SkillPerks_illusion_measured_deception",
    skill = "illusion", playerCastOnly = true,
    handler = function(event)
        local trace=SkillDebug.beginTrace("illusion","Measured Deception","Illusion skill-use event",{
            cost = event and event.cost,
            spell = event and event.spell and event.spell.id,
        })
        local b=rank("B")
        if b == 0 then return trace:reject("B chain inactive") end
        if not event.spell then return trace:reject("skill-use event has no spell") end
        local nonSelf = false
        for _, effect in ipairs(event.spell.effects or {}) do
            if effect.range ~= core.magic.RANGE.Self then nonSelf = true break end
        end
        if nonSelf then
            table.insert(pendingChecks, {
                spellId = event.spell.id, cost = event.cost or 0,
                elapsed = 0, nextPoll = 0.15,
            })
            trace:finish("landed-effect check queued",{cost=event.cost or 0,pending=#pendingChecks})
        else
            trace:reject("spell contains only self-range effects")
        end
    end,
})

local function landed(check)
    for _, actor in ipairs(nearby.actors) do
        for _, spell in pairs(types.Actor.activeSpells(actor)) do
            if spell.id == check.spellId and spell.caster == self then return true end
        end
    end
    return false
end

local function refreshPassives()
    local nightEye = rank("A") >= 1 and Common.playerSpellEffectMagnitude(self, "nighteye") or 0
    local blind = 0
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        for _, effect in pairs(spell.effects or {}) do
            if effect.id == "blind" then
                blind = blind + math.max(0, tonumber(effect.magnitudeThisFrame) or 0)
            end
        end
    end
    effects.apply("blind", nil, -math.min(math.max(0, blind), math.max(0, nightEye)))
    local c = rank("C")
    effects.apply("resistmagicka", nil, c == 2 and 20 or c == 1 and 10 or 0)
    effects.apply("resistparalysis", nil, c == 2 and 50 or c == 1 and 20 or 0)
    SkillDebug.traceState("illusion","Illusion passives","passives",{
        blindIncoming=blind,blindOffset=-math.min(math.max(0,blind),math.max(0,nightEye)),
        cRank=c,nightEye=nightEye,
        resistMagicka=c == 2 and 20 or c == 1 and 10 or 0,
        resistParalysis=c == 2 and 50 or c == 1 and 20 or 0,
    })
end

local function onUpdate(dt)
    pollTimer = pollTimer - dt
    if pollTimer <= 0 then pollTimer = 0.2 refreshPassives() end
    for index = #pendingChecks, 1, -1 do
        local check = pendingChecks[index]
        check.elapsed = check.elapsed + dt
        check.nextPoll = check.nextPoll - dt
        if check.nextPoll <= 0 then
            check.nextPoll = 0.2
            if landed(check) then
                local trace=SkillDebug.beginTrace("illusion","Measured Deception","landed-effect poll",{
                    elapsed=check.elapsed,spell=check.spellId,
                })
                trace:finish("spell affected at least one target; no refund")
                table.remove(pendingChecks, index)
            elseif check.elapsed >= 10 then
                local percent = rank("B") == 2 and 0.75 or 0.30
                local requested=math.floor(check.cost*percent)
                local trace=SkillDebug.beginTrace("illusion","Measured Deception","effect check expired",{
                    cost=check.cost,elapsed=check.elapsed,spell=check.spellId,
                })
                local resolved=Common.restoreResource(self,"magicka",requested,ids.B1)
                trace:finish("Magicka refund delivered",{
                    percent=percent,requested=requested,resolved=resolved,
                })
                table.remove(pendingChecks, index)
            end
        end
    end
end

local function clear()
    effects.clearAll()
    theftStats.clearAll()
    thefts, pendingChecks = {}, {}
end

-- Reports pending spell-result checks and active Mind Theft bookkeeping.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Illusion",
    skillId = "illusion",
    actor = self,
    ids = ids,
    commands = { "luaillusion debug", "luaillu debug" },
    snapshot = function()
        return {
            string.format(
                "Tracking: pendingChecks=%d mindThefts=%d pollTimer=%s",
                #pendingChecks,
                SkillDebug.count(thefts),
                SkillDebug.number(pollTimer)
            ),
            "Magicka: " .. SkillDebug.resourceSummary(self, "magicka"),
        }
    end,
})

Common.registerMagicPerks("illusion", "Illusion", ids, {
    A1={localizedName="Eyes Against the Dark",localizedFlavour="Once you have commanded darkness, it can no longer close over you without resistance.",localizedDescription="Player-cast Night-Eye reduces incoming Blind magnitude by up to its own magnitude.",onAdd=refreshPassives,onRemove=clear},
    A2={localizedName="Untouchable Doubt",localizedFlavour="Every failed strike feeds the certainty that you were never where they believed.",localizedDescription="While player-cast Sanctuary is active, attacks that miss you restore 5 Fatigue.",onRemove=clear},
    A3={localizedName="Mind Theft",localizedFlavour="Paralysis stills the body; you make use of everything the victim can no longer move.",localizedDescription="A player-cast Paralyze siphons half the target's Strength, Endurance, Agility, and Speed until it ends.",onRemove=clear},
    A4={localizedName="Perfect Reassurance",localizedFlavour="Fear, suspicion, and outrage are only stories. You teach the mind a quieter one.",localizedDescription="Landing a player-cast Calm resets the target's Alarm to 0.",onRemove=clear},
    B1={localizedName="Measured Deception",localizedFlavour="A lie that reaches no mind has spent nothing but breath.",localizedDescription="Refund 30% of the Magicka cost when an enemy-targeting Illusion spell affects nobody.",onRemove=clear},
    B2={localizedName="No Wasted Words",localizedFlavour="Even failed persuasion returns with lessons enough to fuel the next attempt.",localizedDescription="Measured Deception refunds 75%.",onRemove=clear},
    C1={localizedName="Unshaken Mind",localizedFlavour="You have studied every route by which one will enters another. Yours are guarded.",localizedDescription="+10% Resist Magicka, +20% Resist Paralysis, and 20% less weapon damage while paralysed.",onAdd=refreshPassives,onRemove=clear},
    C2={localizedName="Sovereign Will",localizedFlavour="No foreign thought sits easily upon the throne of your mind.",localizedDescription="+20% Resist Magicka, +50% Resist Paralysis, and 50% less weapon damage while paralysed.",onAdd=refreshPassives,onRemove=clear},
    D1={localizedName="Total Devotion",localizedFlavour="Affection pushed beyond mortal measure becomes obedience without question.",localizedDescription="Charm that would push disposition above 100 also applies Command Humanoid 10 for the Charm's duration.",onRemove=clear},
    D2={localizedName="Beloved Master",localizedFlavour="They do not merely trust you. For one perfect moment, your purpose is theirs.",localizedDescription="Total Devotion's Command magnitude increases to 25.",onRemove=clear},
})

return {
    eventHandlers = {
        SPerks_MagicEffectLanded = onSpellLanded,
        SPerks_IllusionMindTheftDelta = onMindTheftDelta,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = function() return { effects=effects.snapshot(), stats=theftStats.snapshot(), thefts=thefts } end,
        onLoad = function(data)
            effects.restoreAndReverse(data and data.effects)
            theftStats.restoreAndReverse(data and data.stats)
            thefts, pendingChecks = {}, {}
        end,
    },
}
