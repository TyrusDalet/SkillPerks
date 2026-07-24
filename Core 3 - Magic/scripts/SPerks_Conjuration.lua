--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Conjuration tracks the spellcast window so bonus summons and servant
empowerment can be matched to actors created by that specific cast.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local nearby = require("openmw.nearby")
local types = require("openmw.types")
local self = require("openmw.self")
local ui = require("openmw.ui")

local Common = require("scripts.SkillPerks.magic.common")
local StatTracker = require("scripts.SkillPerks.shared.stat_tracker")

local ids = Common.ids("conjuration")
local effects = StatTracker.newActiveEffectTracker(self)
local stats = StatTracker.newStatModTracker(self, "Conjuration Perks")
local castActors = nil
local summonCast = nil
local castExpiresAt = 0
local previousActorSnapshot = nil
local latestActorSnapshot = nil
local trackingSource = "none"
local debugState = {
    casts = 0,
    discovered = 0,
    applications = 0,
    lastEmpowerment = nil,
}
local updateTimer = 0

local MAX_SPELL_EFFECTS = 8

local CREATURE_SKILL_GROUPS = {
    combatSkill = {
        "block", "armorer", "mediumarmor", "heavyarmor", "bluntweapon",
        "longblade", "axe", "spear", "athletics",
    },
    magicSkill = {
        "enchant", "destruction", "alteration", "illusion", "conjuration",
        "mysticism", "restoration", "alchemy", "unarmored",
    },
    stealthSkill = {
        "security", "sneak", "acrobatics", "lightarmor", "shortblade",
        "marksman", "mercantile", "speechcraft", "handtohand",
    },
}

local function rank(chain) return Common.rank(ids, chain) end
local function summonEffects(spell)
    local result = {}
    for index, effect in ipairs(spell and spell.effects or {}) do
        if tostring(effect.id):find("summon",1,true) then
            table.insert(result,{index=index-1,effect=effect})
        end
    end
    return result
end

local function actorSnapshot()
    local result = {}
    for _, actor in ipairs(nearby.actors) do result[tostring(actor)] = true end
    return result
end

local function copySnapshot(snapshot)
    local result = {}
    for key, value in pairs(snapshot or {}) do result[key] = value end
    return result
end

local function summonDuration(spell)
    local duration = 1
    for _, entry in ipairs(summonEffects(spell)) do
        duration = math.max(duration, tonumber(entry.effect.duration) or 1)
    end
    return duration
end

latestActorSnapshot = actorSnapshot()
previousActorSnapshot = copySnapshot(latestActorSnapshot)

interfaces.AnimationController.addTextKeyHandler("", function(group, key)
    if group ~= "spellcast" then return end
    if key == "self start" or key == "touch start" or key == "target start" then
        local spell = types.Player.getSelectedSpell(self)
        if spell and #summonEffects(spell) > 0 then
            castActors, summonCast = actorSnapshot(), spell
            castExpiresAt = core.getSimulationTime() + 3
            trackingSource = "animation"
        end
    elseif key == "self stop" or key == "touch stop" or key == "target stop" then
        castActors = castActors or {}
    end
end)

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id="SkillPerks_conjuration_summoning",
    skill="conjuration", playerCastOnly=true,
    handler=function(event)
        local list = summonEffects(event.spell)
        if #list == 0 then return end

        -- The framework's skill event is authoritative even on animation sets
        -- that omit the usual spellcast text keys. The previous rolling
        -- snapshot is deliberately used as the fallback because the summoned
        -- actor may already exist by the time skill progression is reported.
        if not castActors then
            castActors = copySnapshot(previousActorSnapshot
                or latestActorSnapshot or actorSnapshot())
            trackingSource = "skill-fallback"
        end
        summonCast = event.spell
        castExpiresAt = math.max(
            castExpiresAt,
            core.getSimulationTime() + 3
        )
        debugState.casts = debugState.casts + 1

        local a = rank("A")
        if a > 0 then
            local firstChance=({0.10,0.20,0.30,0.50})[a]
            local extra = math.random() < firstChance and 1 or 0
            if a == 4 and extra == 1 and math.random() < 0.25 then extra = 2 end
            for _=1,extra do
                types.Actor.activeSpells(self):add({
                    id=event.spell.id,
                    effects=Common.effectIndexList(event.spell,function(e)
                        return tostring(e.id):find("summon",1,true) ~= nil
                    end),
                    caster=self, stackable=true, quiet=true,
                })
            end
        end
    end,
})

local BOUND = {
    bounddagger={attribute="speed",weight=1},
    boundlongsword={attribute="strength",weight=1},
    boundmace={attribute="strength",weight=1},
    boundspear={attribute="endurance",weight=2},
    boundbattleaxe={attribute="strength",weight=2},
    boundlongbow={attribute="agility",weight=2},
    boundcuirass={attribute="endurance",weight=3},
    boundhelm={attribute="endurance",weight=1},
    boundleftgauntlet={attribute="speed",weight=1},
    boundrightgauntlet={attribute="agility",weight=1},
    boundshield={attribute="agility",weight=2},
    boundboots={attribute="speed",weight=1},
    boundgreaves={attribute="endurance",weight=2},
    boundpauldrons={attribute="endurance",weight=1},
    boundwaraxe={attribute="strength",weight=1},
    boundwarhammer={attribute="strength",weight=2},
}

local function activeBoundPieces()
    local pieces = {}
    local totalWeight = 0
    for id, entry in pairs(BOUND) do
        if Common.getEffectMagnitude(self,id) > 0 then
            table.insert(pieces,entry)
            totalWeight = totalWeight + entry.weight
        end
    end
    return pieces,totalWeight
end

local function refreshPassives()
    local a = rank("A")
    local selected = types.Player.getSelectedSpell(self)
    effects.apply("sound",nil,a > 0 and #summonEffects(selected) > 0
        and ({-5,-10,-15,-25})[a] or 0)

    local c = rank("C")
    local intelligence = types.Actor.stats.attributes.intelligence(self).modified
    stats.apply("dynamic","magicka",c == 2 and math.floor(intelligence*0.25)
        or c == 1 and math.floor(intelligence*0.10) or 0)

    local d = rank("D")
    local totals={strength=0,endurance=0,agility=0,speed=0}
    local pieces,weight=activeBoundPieces()
    local each=d == 2 and 5+math.max(0,#pieces-1) or d == 1 and 5 or 0
    for _,entry in ipairs(pieces) do totals[entry.attribute]=totals[entry.attribute]+each end
    for attribute,amount in pairs(totals) do stats.apply("attributes",attribute,amount) end
    stats.apply("skills","conjuration",d == 2 and weight >= 7 and 50 or 0)
end

-- Builds the complete B-chain bonus using vanilla magic effects. Applying it
-- through Core 0's global dynamic-spell service works for temporary summoned
-- actors that do not accept ordinary target-local events.
local function applySummonEmpowerment(actor, b)
    local percent = b == 2 and 0.35 or 0.25
    local duration = summonDuration(summonCast)
    local spellEffects = {}

    local function addEffect(effect)
        effect.duration = duration
        table.insert(spellEffects, effect)
    end

    for _, attribute in ipairs({
        "strength", "intelligence", "willpower", "agility",
        "speed", "endurance", "personality", "luck",
    }) do
        local stat = types.Actor.stats.attributes[attribute](actor)
        local amount = math.floor((tonumber(stat.base) or 0) * percent)
        if amount > 0 then
            addEffect({
                id = "fortifyattribute",
                affectedAttribute = attribute,
                magnitudeMin = amount,
            })
        end
    end

    if types.NPC.objectIsInstance(actor) then
        for _, skill in ipairs({
            "block","armorer","mediumarmor","heavyarmor","bluntweapon","longblade",
            "axe","spear","athletics","enchant","destruction","alteration","illusion",
            "conjuration","mysticism","restoration","alchemy","unarmored","security",
            "sneak","acrobatics","lightarmor","shortblade","marksman","mercantile",
            "speechcraft","handtohand",
        }) do
            local stat = types.NPC.stats.skills[skill](actor)
            local amount = math.floor((tonumber(stat.base) or 0) * percent)
            if amount > 0 then
                addEffect({
                    id = "fortifyskill",
                    affectedSkill = skill,
                    magnitudeMin = amount,
                })
            end
        end
    elseif types.Creature.objectIsInstance(actor) then
        local record = types.Creature.record(actor)
        for recordField, skills in pairs(CREATURE_SKILL_GROUPS) do
            local amount = math.floor((tonumber(record[recordField]) or 0) * percent)
            if amount > 0 then
                for _, skill in ipairs(skills) do
                    addEffect({
                        id = "fortifyskill",
                        affectedSkill = skill,
                        magnitudeMin = amount,
                    })
                end
            end
        end
    end

    local health = types.Actor.stats.dynamic.health(actor)
    local healthBonus = math.floor((tonumber(health.base) or 0) * percent)
    if healthBonus > 0 then
        addEffect({ id = "fortifyhealth", magnitudeMin = healthBonus })
    end
    if b == 2 then
        addEffect({ id = "restorehealth", magnitudeMin = 2 })
    end

    -- Morrowind spell records support at most eight effects. Split the
    -- empowerment into quiet batches while presenting one logical perk.
    for first = 1, #spellEffects, MAX_SPELL_EFFECTS do
        local batch = {}
        for index = first, math.min(first + MAX_SPELL_EFFECTS - 1, #spellEffects) do
            table.insert(batch, spellEffects[index])
        end
        Common.applyDynamicSpell(actor, self, "Empowered Servant", batch, {
            ignoreReflect = true,
            ignoreResistances = true,
            ignoreSpellAbsorption = true,
            quiet = true,
        })
    end

    debugState.applications = debugState.applications + 1
    debugState.lastEmpowerment = {
        recordId = types.Creature.objectIsInstance(actor)
            and types.Creature.record(actor).id or tostring(actor),
        healthBase = health.base,
        healthBonus = healthBonus,
        expectedMaximum = (tonumber(health.base) or 0) + healthBonus,
        duration = duration,
    }
end

local function empowerNewSummons()
    local b=rank("B")
    local now = core.getSimulationTime()

    -- Discover every creature created during this cast. A-chain bonus
    -- summons may appear on different frames, so finding the first actor
    -- must not close the tracking window.
    if castActors and now < castExpiresAt and b > 0 then
        for _,actor in ipairs(nearby.actors) do
            local key = tostring(actor)
            if types.Creature.objectIsInstance(actor)
                    and not castActors[key] and actor:isValid() then
                castActors[key] = true
                debugState.discovered = debugState.discovered + 1
                applySummonEmpowerment(actor, b)
            end
        end
    elseif castActors and now >= castExpiresAt then
        castActors,summonCast=nil,nil
    end

end

local function clear()
    effects.clearAll()
    stats.clearAll()
    castActors,summonCast=nil,nil
    castExpiresAt=0
    trackingSource="none"
end

local function onUpdate(dt)
    updateTimer=updateTimer-dt
    if updateTimer > 0 then return end
    updateTimer=0.2
    refreshPassives()
    empowerNewSummons()
    previousActorSnapshot = latestActorSnapshot
    latestActorSnapshot = actorSnapshot()
end

local function consolePrint(message)
    ui.printToConsole(tostring(message), ui.CONSOLE_COLOR.Default)
end

-- Reports each stage of the summon bridge without requiring verbose Lua logs.
local function onConsoleCommand(mode, command)
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "luaconj debug" then return end

    consolePrint("Conjuration summon bridge:"
        .. " B=" .. tostring(rank("B"))
        .. " casts=" .. tostring(debugState.casts)
        .. " source=" .. tostring(trackingSource)
        .. " tracking=" .. tostring(castActors ~= nil)
        .. " discovered=" .. tostring(debugState.discovered)
        .. " applications=" .. tostring(debugState.applications))

    local last = debugState.lastEmpowerment
    if not last then
        consolePrint("Conjuration last empowerment: none applied.")
        return
    end
    consolePrint("Conjuration last empowerment:"
        .. " actor=" .. tostring(last.recordId)
        .. " healthBase=" .. tostring(last.healthBase)
        .. " healthBonus=" .. tostring(last.healthBonus)
        .. " expectedMaximum=" .. tostring(last.expectedMaximum)
        .. " duration=" .. tostring(last.duration))
end

Common.registerMagicPerks("conjuration","Conjuration",ids,{
    A1={localizedName="Easier Summoning",localizedFlavour="The first footstep across the threshold is always the hardest. You have made it easier.",localizedDescription="-5 Sound while selecting a summon spell; successful summons have a 10% chance to call a second servant.",onAdd=refreshPassives,onRemove=clear},
    A2={localizedName="Widened Gate",localizedFlavour="The passage opens wider, and eager claws find room beside one another.",localizedDescription="Sound becomes -10; bonus-summon chance rises to 20%.",onAdd=refreshPassives,onRemove=clear},
    A3={localizedName="Crowded Threshold",localizedFlavour="Your call is no longer an invitation. It is a road.",localizedDescription="Sound becomes -15; bonus-summon chance rises to 30%.",onAdd=refreshPassives,onRemove=clear},
    A4={localizedName="Legion Beyond",localizedFlavour="One name spoken in your voice may return with an army behind it.",localizedDescription="Sound becomes -25; 50% chance for a second summon, then 25% chance for a third.",onAdd=refreshPassives,onRemove=clear},
    B1={localizedName="Empowered Servants",localizedFlavour="What crosses your circle arrives carrying a share of your authority.",localizedDescription="Creatures summoned by you gain 25% to attributes, skills, and maximum Health.",onRemove=clear},
    B2={localizedName="Deathless Retinue",localizedFlavour="Your servants are reinforced by a pact that closes their wounds as quickly as battle opens them.",localizedDescription="Summon bonuses rise to 35%, and servants restore 2 Health per second.",onRemove=clear},
    C1={localizedName="Pact Dividend",localizedFlavour="Every binding leaves a little of the outer realm caught in your own reserves.",localizedDescription="Maximum Magicka increases by 10% of Intelligence.",onAdd=refreshPassives,onRemove=clear},
    C2={localizedName="Deep Covenant",localizedFlavour="The pact no longer borrows space in your soul. It expands it.",localizedDescription="Maximum Magicka increase rises to 25% of Intelligence.",onAdd=refreshPassives,onRemove=clear},
    D1={localizedName="Bound Mastery",localizedFlavour="Each conjured edge and plate carries an attribute of the warrior you intend to become.",localizedDescription="Every active Bound item grants +5 to its governing attribute.",onAdd=refreshPassives,onRemove=clear},
    D2={localizedName="Armory of the Will",localizedFlavour="The more of yourself you replace with conjured purpose, the stronger every piece becomes.",localizedDescription="Each Bound piece gains +1 attribute per other piece; a mostly Bound set grants +50 Conjuration.",onAdd=refreshPassives,onRemove=clear},
})

return {
    engineHandlers={
        onUpdate=onUpdate,
        onSave=function() return {effects=effects.snapshot(),stats=stats.snapshot()} end,
        onLoad=function(data)
            effects.restoreAndReverse(data and data.effects)
            stats.restoreAndReverse(data and data.stats)
            castActors,summonCast=nil,nil
            castExpiresAt=0
            latestActorSnapshot=actorSnapshot()
            previousActorSnapshot=copySnapshot(latestActorSnapshot)
            trackingSource="none"
            debugState={
                casts=0,discovered=0,applications=0,
                lastEmpowerment=nil,
            }
        end,
        onConsoleCommand=onConsoleCommand,
    },
}
