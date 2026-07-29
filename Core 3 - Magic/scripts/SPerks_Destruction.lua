--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Destruction resolves secondary damage only after a spell has landed. Direct
resource riders use the framework pipeline; elemental spell riders retain
normal target resistances through Core 0's dynamic-spell bridge.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local nearby = require("openmw.nearby")
local types = require("openmw.types")
local self = require("openmw.self")

local Common = require("scripts.SkillPerks.magic.common")
local MagicDetection = require("scripts.SkillPerks.shared.magic_detection")
local SkillDebug = require("scripts.SkillPerks.shared.debug")

local ids=Common.ids("destruction")
local castCosts={}
local reflectedSeen={}
local reflectionTimer=0

local function rank(chain) return Common.rank(ids,chain) end
local function targetRatio(target,resource)
    local stat=types.Actor.stats.dynamic[resource](target)
    local maximum=math.max((stat.base or 0)+(stat.modifier or 0),1)
    return math.max(0,math.min(1,(stat.current or maximum)/maximum))
end
local function damage(target,resource,amount,effectId,damageType)
    if amount <= 0 then return end
    local event=resource=="health" and "SPerks_TakeDamage"
        or resource=="fatigue" and "SPerks_TakeFatigue" or "SPerks_TakeMagicka"
    target:sendEvent(event,{amount=amount,source=self,sourceEffect=effectId,damageType=damageType})
end

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id="SkillPerks_destruction_cast_cost",skill="destruction",playerCastOnly=true,
    handler=function(event)
        if event.spell then castCosts[event.spell.id]=event.cost or 0 end
    end,
})

local ELEMENT = {
    firedamage={resource="health",damageType="fire"},
    frostdamage={resource="fatigue",damageType="frost"},
    shockdamage={resource="magicka",damageType="shock"},
}
local DRAIN_RESOURCE={drainhealth="health",drainfatigue="fatigue",drainmagicka="magicka"}

-- Shows the cast-cost ledger and reflection suppression cache used by riders.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Destruction",
    skillId = "destruction",
    actor = self,
    ids = ids,
    commands = { "luadestruction debug", "luadest debug" },
    snapshot = function()
        return {
            string.format(
                "Tracking: castCosts=%d reflectedEffects=%d reflectionPoll=%s",
                SkillDebug.count(castCosts),
                SkillDebug.count(reflectedSeen),
                SkillDebug.number(reflectionTimer)
            ),
            "Magicka: " .. SkillDebug.resourceSummary(self, "magicka"),
        }
    end,
})

local function chainShock(origin,amount)
    for _,actor in ipairs(nearby.actors) do
        if actor ~= origin and actor:isValid() and targetRatio(actor,"magicka") < 0.25 then
            Common.applyDynamicSpell(actor,self,"Elemental Mastery",{{id="shockdamage",magnitudeMin=amount,duration=1}})
            return
        end
    end
end

local function onSpellLanded(data)
    local target=data and data.target
    SkillDebug.traceEvent("destruction", "spell landed", {
        spell = data and data.spellId,
        target = SkillDebug.objectId(target),
    })
    if not target or not target:isValid() then return end
    local c=rank("C")
    local playerCast=Common.isPlayerCastLandedSpell(data)
    if not playerCast and c == 0 then return end
    local a,b,d=rank("A"),rank("B"),rank("D")
    local sourceCost=castCosts[data.spellId] or 0
    if data.item then
        local enchantment=MagicDetection.getEnchantmentRecord(data.item)
        if enchantment then
            sourceCost=enchantment.type==core.magic.ENCHANTMENT_TYPE.CastOnce
                and 50 or math.max(1,enchantment.cost or 1)
        end
    end

    for _,effect in ipairs(data.effects or {}) do
        local id=effect.id
        local magnitude=math.max(0,tonumber(effect.magnitude) or Common.averageMagnitude(effect))
        local duration=math.max(1,tonumber(effect.duration) or 1)
        local element=ELEMENT[id]

        if element and a > 0 then
            local cap=({0.10,0.25,0.50,1.00})[a]
            local bonus=magnitude*(1-targetRatio(target,element.resource))*cap
            if d >= 2 and playerCast and targetRatio(target,element.resource)<0.25 then bonus=bonus+magnitude end
            damage(target,"health",bonus,ids["A"..a],element.damageType)
        end

        if id:find("^drain") and a > 0 then
            local ratio=({0.10,0.125,0.20,0.50})[a]
            local resource=DRAIN_RESOURCE[id]
            if resource then
                damage(target,resource,magnitude*ratio,ids["A"..a],"drain")
            elseif id=="drainattribute" then
                Common.applyDynamicSpell(target,self,"Drain Mastery",{{id="damageattribute",affectedAttribute=effect.affectedAttribute,magnitudeMin=magnitude*ratio,duration=1}})
            elseif id=="drainskill" then
                Common.applyDynamicSpell(target,self,"Drain Mastery",{{id="damageskill",affectedSkill=effect.affectedSkill,magnitudeMin=magnitude*ratio,duration=1}})
            end
            if b>0 and (playerCast or c>=2) then
                target:sendEvent("SPerks_DestructionSetDrainKill",{
                    caster=self,cost=sourceCost,duration=duration,
                    refundRatio=b==2 and 1 or 0.5,
                })
            end
        end

        if c > 0 and (id=="damagehealth" or id=="drainhealth" or id=="absorbhealth" or id=="poison") then
            damage(target,"health",magnitude*(c==2 and 0.50 or 0.25),ids["C"..c],"rawpower")
        end

        if b > 0 then
            local scale=b==2 and 1 or 0.5
            if id=="firedamage" then
                local finisher=d>=2 and playerCast and targetRatio(target,"health")<0.25 and 2 or 1
                Common.applyDynamicSpell(target,self,"Elemental Consequence",{{id="disintegratearmor",magnitudeMin=magnitude*duration*scale*finisher,duration=1}})
            elseif id=="frostdamage" then
                damage(target,"fatigue",magnitude*duration*scale,ids["B"..b],"frost")
                if d>=2 and playerCast and targetRatio(target,"fatigue")<0.25 then
                    Common.applyDynamicSpell(target,self,"Frozen Finish",{{id="paralyze",magnitudeMin=1,duration=1}})
                end
            elseif id=="shockdamage" then
                damage(target,"magicka",magnitude*duration*scale,ids["B"..b],"shock")
                if d>=2 and playerCast and targetRatio(target,"magicka")<0.25 then chainShock(target,magnitude) end
            elseif id=="poison" then
                target:sendEvent("SPerks_DestructionPoisonConsequence",{
                    duration=duration,cap=b==2 and 20 or 10,
                    weakness=b==2 and 15 or 5,speed=b==2 and 10 or 5,
                })
            end
        end
    end
end

local function protectedElement()
    local weather=core.weather and core.weather.getCurrent(self.cell)
    local name=weather and ((weather.recordId or weather.name or ""):lower()) or ""
    local hour=(core.getGameTime()/3600)%24
    local night=hour<6 or hour>=18
    if name:find("ash",1,true) or (name:find("clear",1,true) and not night) then return "firedamage" end
    if name:find("rain",1,true) or name:find("fog",1,true) then return "shockdamage" end
    if night or name:find("snow",1,true) then return "frostdamage" end
end

-- Reflected effects return to the player with the player recorded as caster.
-- Removing the reflected active spell before its next tick provides D1's
-- weather immunity without altering the original outgoing cast.
local function suppressWeatherReflection()
    if rank("D")==0 then reflectedSeen={} return end
    local protected=protectedElement()
    if not protected then return end
    local current={}
    for _,spell in pairs(types.Actor.activeSpells(self)) do
        local key=spell.activeSpellId or spell.id
        current[key]=true
        if not reflectedSeen[key] and spell.caster==self then
            for _,effect in pairs(spell.effects or {}) do
                if effect.id==protected and (tonumber(effect.magnitudeThisFrame) or 0)>0 then
                    types.Actor.activeSpells(self):remove(spell.activeSpellId)
                    break
                end
            end
        end
    end
    reflectedSeen=current
end

Common.registerMagicPerks("destruction","Destruction",ids,{
    A1={localizedName="Elemental Pressure",localizedFlavour="Flame seeks wounded flesh, frost hunts failing breath, and lightning hears the silence in an empty mind.",localizedDescription="Elemental damage gains up to 10% against targets missing its paired resource; Drain also deals one-tenth real damage."},
    A2={localizedName="Deepening Pressure",localizedFlavour="Weakness is not merely exposed to you. It becomes a path the spell eagerly follows.",localizedDescription="Elemental cap rises to 25%; Drain rider rises to one-eighth."},
    A3={localizedName="Ruinous Sympathy",localizedFlavour="Your spell and the enemy's failing strength recognize one another instantly.",localizedDescription="Elemental cap rises to 50%; Drain rider rises to one-fifth."},
    A4={localizedName="Terminal Pressure",localizedFlavour="At the edge of collapse, every element becomes perfectly cruel.",localizedDescription="Elemental cap rises to 100%; Drain rider rises to one-half."},
    B1={localizedName="Elemental Consequence",localizedFlavour="The element leaves more behind than pain: cracked armor, spent breath, and a hollowed reserve.",localizedDescription="Fire disintegrates armor; Frost drains Fatigue; Shock drains Magicka; Poison builds debuffs. Drain kills refund up to 50% of remaining spell cost."},
    B2={localizedName="Lingering Catastrophe",localizedFlavour="The first wound is only the announcement. The true destruction follows.",localizedDescription="Elemental riders double; Poison stacks become stronger and may build twice as high; Drain-kill refund rises to 100%."},
    C1={localizedName="Raw Power",localizedFlavour="You have found the common violence beneath poison, absorption, damage, and decay.",localizedDescription="+25% direct damage for Damage Health, Drain Health, Absorb Health, and Poison; A/B riders also accept enchantments and scrolls."},
    C2={localizedName="Unanswerable Force",localizedFlavour="Source no longer matters. Spell, scroll, and steel all speak destruction in your hand.",localizedDescription="Raw Power rises to +50%, retaining expanded source access."},
    D1={localizedName="Elemental Mastery",localizedFlavour="Weather itself teaches which element the world is prepared to defend.",localizedDescription="Player-cast elemental magic gains weather-linked protection against reflection."},
    D2={localizedName="Executioner's Element",localizedFlavour="When a resource falters below its final quarter, the matching element knows how to finish the work.",localizedDescription="Below 25% of the paired resource, Fire, Frost, and Shock gain finishing effects; Shock may chain to another vulnerable enemy."},
})

return {
    eventHandlers={
        SPerks_MagicEffectLanded=onSpellLanded,
        SPerks_DestructionDrainKillRefund=function(data)
            Common.restoreResource(self,"magicka",data and data.amount or 0,ids["B"..rank("B")])
        end,
    },
    engineHandlers={
        onConsoleCommand=onConsoleCommand,
        onUpdate=function(dt)
            reflectionTimer=reflectionTimer-dt
            if reflectionTimer<=0 then
                reflectionTimer=0.1
                suppressWeatherReflection()
            end
        end,
    },
}
