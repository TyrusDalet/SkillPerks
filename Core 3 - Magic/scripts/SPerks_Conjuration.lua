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
local SkillDebug  = require("scripts.SkillPerks.shared.debug")

local ids = Common.ids("conjuration")
local effects = StatTracker.newActiveEffectTracker(self)
local stats = StatTracker.newStatModTracker(self, "Conjuration Perks")
local castActors = nil
local summonCast = nil
local castExpiresAt = 0
local previousActorSnapshot = nil
local latestActorSnapshot = nil
local trackingSource = "none"
local bonusSummonsBySpell = {}
local pendingBonusCapture = nil
local debugState = {
    casts = 0,
    discovered = 0,
    applications = 0,
    lastEmpowerment = nil,
    lastDelivery = "No direct empowerment acknowledgement received.",
}
local updateTimer = 0

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

--- Captures the player's current active-spell instances for one record.
--- The A chain uses the difference after `activeSpells:add` to identify only
--- the bonus instances it created; the vanilla cast is already in this
--- baseline and is therefore never removed by SkillPerks.
local function activeSpellInstanceSnapshot(spellId)
    local result={}
    for _,activeSpell in pairs(types.Actor.activeSpells(self)) do
        if activeSpell.id==spellId and activeSpell.caster==self
                and activeSpell.activeSpellId~=nil then
            result[activeSpell.activeSpellId]=true
        end
    end
    return result
end

--- Finds bonus instances created after the saved baseline. OpenMW normally
--- exposes additions immediately, but the short pending window also supports
--- builds where the ActiveSpell list updates on the following frame.
local function captureAddedBonusSummons()
    local pending=pendingBonusCapture
    if not pending then return end
    local tracked=bonusSummonsBySpell[pending.spellId] or {}
    local captured=0
    for activeId in pairs(activeSpellInstanceSnapshot(pending.spellId)) do
        if not pending.before[activeId] then
            tracked[activeId]=true
        end
    end
    for _ in pairs(tracked) do captured=captured+1 end
    bonusSummonsBySpell[pending.spellId]=tracked
    SkillDebug.traceState("conjuration","Bonus summon tracking",
        "bonus-capture-"..tostring(pending.spellId),{
            captured=captured,expected=pending.expected,spell=pending.spellId,
        })
    if captured>=pending.expected or core.getSimulationTime()>=pending.expiresAt then
        SkillDebug.traceEvent("conjuration","bonus summon capture complete",{
            captured=captured,expected=pending.expected,spell=pending.spellId,
        })
        pendingBonusCapture=nil
    end
end

--- Removes only the A-chain instances previously captured for this spell.
--- Recasting another summon spell leaves these instances alone, matching
--- vanilla's per-spell replacement behavior.
local function dismissBonusSummons(spellId)
    captureAddedBonusSummons()
    local tracked=bonusSummonsBySpell[spellId]
    if not tracked then return 0,0 end
    local active=activeSpellInstanceSnapshot(spellId)
    local removed,missing=0,0
    for activeId in pairs(tracked) do
        if active[activeId] then
            local ok=pcall(function()
                types.Actor.activeSpells(self):remove(activeId)
            end)
            if ok then removed=removed+1 else missing=missing+1 end
        else
            missing=missing+1
        end
    end
    bonusSummonsBySpell[spellId]=nil
    return removed,missing
end

--- Dismisses every tracked A-chain summon, used when its perks are removed.
local function dismissAllBonusSummons()
    local spellIds={}
    for spellId in pairs(bonusSummonsBySpell) do spellIds[#spellIds+1]=spellId end
    for _,spellId in ipairs(spellIds) do dismissBonusSummons(spellId) end
    pendingBonusCapture=nil
end

--- Drops identifiers whose bonus spell expired naturally, keeping save data
--- and diagnostics limited to instances that can still be dismissed.
local function pruneExpiredBonusSummons()
    for spellId,tracked in pairs(bonusSummonsBySpell) do
        local active=activeSpellInstanceSnapshot(spellId)
        local remaining=0
        for activeId in pairs(tracked) do
            if active[activeId] then
                remaining=remaining+1
            else
                tracked[activeId]=nil
            end
        end
        if remaining==0 then bonusSummonsBySpell[spellId]=nil end
    end
end

local function trackedBonusSummonCount()
    local count=0
    for _,tracked in pairs(bonusSummonsBySpell) do
        for _ in pairs(tracked) do count=count+1 end
    end
    return count
end

latestActorSnapshot = actorSnapshot()
previousActorSnapshot = copySnapshot(latestActorSnapshot)

interfaces.AnimationController.addTextKeyHandler("", function(group, key)
    if group ~= "spellcast" then return end
    if key == "self start" or key == "touch start" or key == "target start" then
        local spell = types.Player.getSelectedSpell(self)
        local summons=#summonEffects(spell)
        local trace=SkillDebug.beginTrace("conjuration","Summon tracking","spellcast animation started",{
            key=key,spell=spell and spell.id,summonEffects=summons,
        })
        if Common.actorKnowsCastableSpell(self, spell) and summons > 0 then
            castActors, summonCast = actorSnapshot(), spell
            castExpiresAt = core.getSimulationTime() + 3
            trackingSource = "animation"
            trace:finish("tracking window opened",{
                actorsBefore=SkillDebug.count(castActors),expiresAt=castExpiresAt,
            })
        else
            trace:reject("selected spell is not a known summon spell")
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
        local trace=SkillDebug.beginTrace("conjuration","Summoning cast","Conjuration skill-use event",{
            spell = event and event.spell and event.spell.id,
            summonEffects = #list,
        })
        if #list == 0 then return trace:reject("spell contains no summon effects") end

        -- The framework's skill event is authoritative even on animation sets
        -- that omit the usual spellcast text keys. The previous rolling
        -- snapshot is deliberately used as the fallback because the summoned
        -- actor may already exist by the time skill progression is reported.
        if not castActors then
            castActors = copySnapshot(previousActorSnapshot
                or latestActorSnapshot or actorSnapshot())
            trackingSource = "skill-fallback"
            trace:step("animation snapshot unavailable; fallback snapshot selected",{
                actorsBefore=SkillDebug.count(castActors),
            })
        else
            trace:step("animation snapshot retained",{
                actorsBefore=SkillDebug.count(castActors),
            })
        end
        summonCast = event.spell
        castExpiresAt = math.max(
            castExpiresAt,
            core.getSimulationTime() + 3
        )
        debugState.casts = debugState.casts + 1

        local dismissed,stale=dismissBonusSummons(event.spell.id)
        trace:step("previous bonus instances dismissed",{
            removed=dismissed,spell=event.spell.id,stale=stale,
        })

        local a = rank("A")
        if a > 0 then
            local firstChance=({0.10,0.20,0.30,0.50})[a]
            local firstRoll=math.random()
            local extra = firstRoll < firstChance and 1 or 0
            local secondRoll=nil
            if a == 4 and extra == 1 then
                secondRoll=math.random()
                if secondRoll < 0.25 then extra = 2 end
            end
            trace:step("bonus summon rolls resolved",{
                aRank=a,extraSummons=extra,firstChance=firstChance,
                firstRoll=firstRoll,secondChance=a==4 and 0.25 or nil,
                secondRoll=secondRoll,
            })
            local before=activeSpellInstanceSnapshot(event.spell.id)
            for _=1,extra do
                types.Actor.activeSpells(self):add({
                    id=event.spell.id,
                    effects=Common.effectIndexList(event.spell,function(e)
                        return tostring(e.id):find("summon",1,true) ~= nil
                    end),
                    caster=self, stackable=true, quiet=true,
                })
            end
            if extra>0 then
                pendingBonusCapture={
                    before=before,expected=extra,
                    expiresAt=core.getSimulationTime()+0.5,
                    spellId=event.spell.id,
                }
                captureAddedBonusSummons()
            end
        else
            trace:step("bonus summon skipped",{reason="A chain inactive"})
        end
        trace:finish("summon cast tracking armed",{
            expiresAt=castExpiresAt,source=trackingSource,
        })
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
    local selectedSummon = Common.actorKnowsCastableSpell(self, selected)
        and #summonEffects(selected) > 0
    effects.apply("sound",nil,a > 0 and selectedSummon
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
    SkillDebug.traceState("conjuration","Conjuration passives","passives",{
        aRank=a,boundPieces=#pieces,boundWeight=weight,cRank=c,dRank=d,
        magickaBonus=c == 2 and math.floor(intelligence*0.25)
            or c == 1 and math.floor(intelligence*0.10) or 0,
        selectedSpell=selected and selected.id,selectedSummon=selectedSummon,
        sound=a > 0 and selectedSummon and ({-5,-10,-15,-25})[a] or 0,
        statPerPiece=each,totals=totals,
    })
end

-- Builds the complete B-chain bonus and lets the summoned actor's Core 0
-- script own its exact modifier deltas. This avoids several permanent dynamic
-- spell records for every creature summoned.
local function applySummonEmpowerment(actor, b)
    local trace=SkillDebug.beginTrace("conjuration","Empowered Servants","new summon discovered",{
        actor = SkillDebug.objectId(actor),
        rank = b,
    })
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

    actor:sendEvent("SPerks_ApplyTimedEffectBundle",{
        caster=self,
        effects=spellEffects,
        key="SkillPerks_EmpoweredServant",
        resultEvent="SPerks_ConjurationEmpowermentApplied",
        sourceEffect=ids["B"..b],
        stackable=false,
    })
    trace:step("direct empowerment bundle sent",{
        totalEffects=#spellEffects,
    })

    debugState.applications = debugState.applications + 1
    debugState.lastEmpowerment = {
        recordId = types.Creature.objectIsInstance(actor)
            and types.Creature.record(actor).id or tostring(actor),
        healthBase = health.base,
        healthBonus = healthBonus,
        expectedMaximum = (tonumber(health.base) or 0) + healthBonus,
        duration = duration,
    }
    trace:finish("summon empowerment queued",{
        duration=duration,effects=#spellEffects,expectedMaximum=debugState.lastEmpowerment.expectedMaximum,
        healthBase=health.base,healthBonus=healthBonus,percent=percent,
    })
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
        local trace=SkillDebug.beginTrace("conjuration","Summon tracking","tracking window expired",{
            bRank=b,expiresAt=castExpiresAt,now=now,
        })
        castActors,summonCast=nil,nil
        trace:finish("tracking state cleared")
    end

end

local function clear()
    dismissAllBonusSummons()
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
    captureAddedBonusSummons()
    pruneExpiredBonusSummons()
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
    if SkillDebug.handleTraceCommand({
        name = "Conjuration",
        skillId = "conjuration",
        commands = { "luaconj debug", "luaconjuration debug" },
    }, command) then
        return
    end
    command = tostring(command or ""):lower():match("^%s*(.-)%s*$")
    if command ~= "luaconj debug" and command ~= "luaconjuration debug" then return end
    SkillDebug.describe({ name = "Conjuration", skillId = "conjuration", actor = self, ids = ids })

    consolePrint("Conjuration summon bridge:"
        .. " B=" .. tostring(rank("B"))
        .. " casts=" .. tostring(debugState.casts)
        .. " source=" .. tostring(trackingSource)
        .. " tracking=" .. tostring(castActors ~= nil)
        .. " discovered=" .. tostring(debugState.discovered)
        .. " applications=" .. tostring(debugState.applications)
        .. " trackedBonusSpells=" .. tostring(SkillDebug.count(bonusSummonsBySpell))
        .. " trackedBonusInstances=" .. tostring(trackedBonusSummonCount())
        .. " pendingCapture=" .. tostring(pendingBonusCapture ~= nil))

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
    consolePrint("Conjuration last delivery: "..tostring(debugState.lastDelivery))
end

Common.registerMagicPerks("conjuration","Conjuration",ids,{
    A1={localizedName="Easier Summoning",localizedFlavour="The first footstep across the threshold is always the hardest. You have made it easier.",localizedDescription="-5 Sound while selecting a summon spell; successful summons have a 10% chance to call a second servant. Recasting that spell dismisses its previous bonus servants.",onAdd=refreshPassives,onRemove=clear},
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
    eventHandlers={
        SPerks_ConjurationEmpowermentApplied=function(data)
            data=data or {}
            debugState.lastDelivery=string.format(
                "target=%s applied=%s rejected=%s reasons=%s",
                SkillDebug.objectId(data.target),tostring(data.applied),
                tostring(data.rejected),tostring(data.reasons)
            )
        end,
    },
    engineHandlers={
        onUpdate=onUpdate,
        onSave=function()
            return {
                effects=effects.snapshot(),stats=stats.snapshot(),
                bonusSummonsBySpell=bonusSummonsBySpell,
            }
        end,
        onLoad=function(data)
            effects.restoreAndReverse(data and data.effects)
            stats.restoreAndReverse(data and data.stats)
            castActors,summonCast=nil,nil
            castExpiresAt=0
            latestActorSnapshot=actorSnapshot()
            previousActorSnapshot=copySnapshot(latestActorSnapshot)
            trackingSource="none"
            bonusSummonsBySpell=(data and data.bonusSummonsBySpell) or {}
            pendingBonusCapture=nil
            debugState={
                casts=0,discovered=0,applications=0,
                lastEmpowerment=nil,
                lastDelivery="No direct empowerment acknowledgement received.",
            }
        end,
        onConsoleCommand=onConsoleCommand,
    },
}
