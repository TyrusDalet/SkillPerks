--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Alchemy observes active item effects and inventory diffs. This keeps potion
preservation and batch bonuses compatible with quick keys and Inventory
Extender instead of relying on one particular item-use handler.
]]

local core = require("openmw.core")
local interfaces = require("openmw.interfaces")
local types = require("openmw.types")
local ui = require("openmw.ui")
local self = require("openmw.self")

local Common = require("scripts.SkillPerks.magic.common")
local SkillDebug = require("scripts.SkillPerks.shared.debug")
local TimedEffects = require("scripts.SkillPerks.shared.timed_effects")

local ids=Common.ids("alchemy")
local mimickedEffects=TimedEffects.new(self,"Alchemy Reactions")
local seenSpells={}
local potionSnapshot={}
local alchemySession=nil
local inAlchemy=false
local timer=0
local reactionExpiry={}
local reactionSpellIds={}
local reactionRequests={}
local pendingReactionKeys={}
local reactionResourceSnapshots={}
local duplicationSerial=0
local pendingAlchemyClose=nil
local ALCHEMY_SETTLE_DELAY=0.15
local diagnostics={
    lastScan="No active-spell scan completed.",
    lastObservedSpell="No new active spell observed.",
    lastConsumable="No consumable active spell observed.",
    lastReaction="No Alchemical Reaction attempted.",
    lastIngredient="No Raw Ingestion attempt observed.",
    lastPreservation="No potion consumption diff observed.",
    lastSession="No Alchemy UI session observed.",
    lastSkillUse="No Alchemy skill-use event observed.",
    lastDelivery="No Alchemy dynamic-spell acknowledgement received.",
    lastDuplication="No Alchemy item-duplication acknowledgement received.",
    lastExpiryCorrection="No dynamic-stat Fortify reaction has expired.",
}

local function rank(chain) return Common.rank(ids,chain) end
local function countsOf(typeObject)
    local result={}
    for _,item in ipairs(types.Actor.inventory(self):getAll(typeObject)) do
        result[item.recordId]=(result[item.recordId] or 0)+(item.count or 1)
    end
    return result
end
local function duplicate(recordId,count,reason)
    if not recordId or count <= 0 then return false end
    duplicationSerial=duplicationSerial+1
    local requestId="SkillPerks_AlchemyItem_"..tostring(duplicationSerial)
    core.sendGlobalEvent("SPerks_DuplicateItem",{
        target=self,recordId=recordId,count=count,
        requestId=requestId,resultTarget=self,
        resultEvent="SPerks_AlchemyItemDuplicationResult",
    })
    diagnostics.lastDuplication=string.format(
        "Queued: request=%s reason=%s record=%s count=%d.",
        requestId,tostring(reason),tostring(recordId),count
    )
    return true
end

--- Resolves a consumable record without depending on ActiveSpell.item.
--- OpenMW always exposes the source record as ActiveSpell.id, while item is
--- optional and primarily identifies enchanted-item instances.
--- @param typeObject table types.Potion or types.Ingredient.
--- @param source any Record id or live object.
--- @return userdata|nil record
local function consumableRecord(typeObject,source)
    if source==nil then return nil end
    local ok,record=pcall(typeObject.record,source)
    if ok and record and record.id then return record end
    return nil
end

--- Classifies a newly-active consumable spell and records which API field
--- supplied its identity. Record-id classification handles ordinary consumed
--- potions and ingredients; the object fallback retains compatibility with
--- scripted item applications that do provide ActiveSpell.item.
--- @param spell table ActiveSpell.
--- @return string|nil kind "potion" or "ingredient".
--- @return userdata|nil record Consumable record.
--- @return string sourceField Classification source for diagnostics.
local function classifyConsumable(spell)
    local spellId=spell and spell.id
    local potion=consumableRecord(types.Potion,spellId)
    if potion then return "potion",potion,"activeSpell.id" end
    local ingredient=consumableRecord(types.Ingredient,spellId)
    if ingredient then return "ingredient",ingredient,"activeSpell.id" end

    local item=spell and spell.item
    potion=consumableRecord(types.Potion,item)
    if potion then return "potion",potion,"activeSpell.item" end
    ingredient=consumableRecord(types.Ingredient,item)
    if ingredient then return "ingredient",ingredient,"activeSpell.item" end
    return nil,nil,"unresolved"
end

--- Finds the consumable record entry that produced one active effect.
--- ActiveSpellEffect.index is 0-based, matching activeSpells:add semantics.
--- @param record userdata|nil Potion or ingredient record.
--- @param effect table|nil ActiveSpellEffect.
--- @return table|nil sourceEffect
local function recordEffect(record,effect)
    if effect==nil then return nil end
    local effects=record and record.effects
    local index=tonumber(effect and effect.index)
    if effects and index~=nil and effects[index+1] then return effects[index+1] end
    for _,candidate in ipairs(effects or {}) do
        if candidate.id==effect.id
                and candidate.affectedAttribute==effect.affectedAttribute
                and candidate.affectedSkill==effect.affectedSkill then
            return candidate
        end
    end
    return nil
end

--- Reads a useful magnitude after applied-once Restore effects have already
--- fallen to zero. The active instance range is preferred, followed by the
--- source consumable record's configured range.
--- @param effect table ActiveSpellEffect.
--- @param sourceEffect table|nil MagicEffectWithParams.
--- @return number magnitude
--- @return string source Diagnostic magnitude source.
local function resolvedMagnitude(effect,sourceEffect)
    local current=tonumber(effect and effect.magnitudeThisFrame)
    if current~=nil and current~=0 then return current,"magnitudeThisFrame" end
    local activeAverage=Common.averageMagnitude(effect)
    if activeAverage~=0 then return activeAverage,"active effect range" end
    local recordAverage=Common.averageMagnitude(sourceEffect)
    if recordAverage~=0 then return recordAverage,"consumable record range" end
    return current or 0,"zero"
end

--- Resolves the source effect's natural duration before applying rank floors.
--- @param effect table ActiveSpellEffect.
--- @param sourceEffect table|nil MagicEffectWithParams.
--- @return number duration At least one second for formula stability.
--- @return string source Diagnostic duration source.
local function resolvedDuration(effect,sourceEffect)
    local activeDuration=tonumber(effect and effect.duration)
    if activeDuration and activeDuration>0 then return activeDuration,"active effect" end
    local recordDuration=tonumber(sourceEffect and sourceEffect.duration)
    if recordDuration and recordDuration>0 then return recordDuration,"consumable record" end
    local remaining=tonumber(effect and effect.durationLeft)
    if remaining and remaining>0 then return remaining,"durationLeft" end
    return 1,"instant fallback"
end

--- Captures currently-active spell instance ids without treating them as new
--- consumptions after a Lua reload, load, respec, or perk removal.
--- @return table ids Active-spell id lookup.
local function activeSpellSnapshot()
    local result={}
    for _,spell in pairs(types.Actor.activeSpells(self)) do
        local key=spell.activeSpellId or spell.id
        if key~=nil then result[key]=true end
    end
    return result
end

--- Checks only for the exact dynamic spell record previously granted by
--- Alchemical Reaction. Unrelated constant-effect equipment may share the same
--- magic effect id, but cannot share this generated spell id.
--- @param spellId string|nil Generated spell record id.
--- @return boolean active
local function reactionSpellIsActive(spellId)
    if spellId==nil then return false end
    for _,spell in pairs(types.Actor.activeSpells(self)) do
        if spell.id==spellId then return true end
    end
    return false
end

local FORTIFY_RESOURCE={
    fortifyhealth="health",
    fortifymagicka="magicka",
    fortifyfatigue="fatigue",
}

--- Returns the effect portion of a reaction key such as
--- `fortifyhealth|`. Keeping this derivation in one place lets save data from
--- earlier versions participate in expiry protection without migration.
--- @param reactionKey string
--- @return string effectId
local function reactionEffectId(reactionKey)
    local divider=tostring(reactionKey):find("|",1,true)
    if divider then return tostring(reactionKey):sub(1,divider-1) end
    return tostring(reactionKey)
end

--- Remembers the live resource level while one of Alchemical Reaction's
--- exact generated Fortify Health/Magicka/Fatigue spells is active. OpenMW
--- can subtract a large Fortify magnitude from `current` when that spell
--- expires, even when the temporary effect did not supply that much usable
--- resource. The final correction below is bookkeeping, not healing: it
--- restores only the pre-expiry value, capped at the normal post-effect max.
--- @param reactionKey string
--- @param resource string
local function ensureResourceSnapshot(reactionKey,resource)
    if not resource then return end
    local getter=types.Actor.stats.dynamic[resource]
    if not getter then return end
    local state=reactionResourceSnapshots[reactionKey]
    if not state then
        state={resource=resource,current=tonumber(getter(self).current) or 0}
        reactionResourceSnapshots[reactionKey]=state
    else
        state.resource=resource
    end
end

--- Reconciles generated dynamic-stat Fortify effects at the exact moment
--- their tracked spell disappears. A value already below the normal maximum
--- remains damaged/spent; a temporary value above it settles at that normal
--- maximum and cannot be driven through zero by an oversized expiry loss.
local function reconcileExpiredResourceReactions()
    -- Rebuild missing snapshot entries from saved exact spell ids. This keeps
    -- active reactions protected when loading saves made before this state was
    -- persisted, although only post-load resource changes can be observed.
    for reactionKey in pairs(reactionSpellIds) do
        ensureResourceSnapshot(
            reactionKey,
            FORTIFY_RESOURCE[reactionEffectId(reactionKey)]
        )
    end

    for reactionKey,state in pairs(reactionResourceSnapshots) do
        local resource=state.resource
        local getter=resource and types.Actor.stats.dynamic[resource]
        local spellId=reactionSpellIds[reactionKey]
        local pending=pendingReactionKeys[reactionKey]
        if getter and spellId and reactionSpellIsActive(spellId) then
            local stat=getter(self)
            state.current=tonumber(stat.current) or state.current or 0
            state.observedActive=true
            state.spellId=spellId
        elseif getter and spellId and state.observedActive then
            local stat=getter(self)
            local before=tonumber(stat.current) or 0
            local preExpiry=tonumber(state.current) or before
            local normalMaximum=math.max(0,(tonumber(stat.base) or 0)+(tonumber(stat.modifier) or 0))
            local desired=math.min(preExpiry,normalMaximum)
            local corrected=0
            if before<desired then
                corrected=desired-before
                -- This direct write repairs engine expiry bookkeeping. Routing
                -- it as Restore Health/Magicka/Fatigue would incorrectly fire
                -- gameplay hooks such as Ward of Delay.
                stat.current=desired
            end
            diagnostics.lastExpiryCorrection=string.format(
                "%s spell=%s preExpiry=%s postExpiry=%s normalMax=%s final=%s corrected=%s.",
                resource,tostring(spellId),SkillDebug.number(preExpiry),
                SkillDebug.number(before),SkillDebug.number(normalMaximum),
                SkillDebug.number(math.max(before,desired)),SkillDebug.number(corrected)
            )
            SkillDebug.traceEvent("alchemy","Fortify reaction expiry reconciled",{
                corrected=corrected,final=math.max(before,desired),
                normalMaximum=normalMaximum,postExpiry=before,
                preExpiry=preExpiry,reactionKey=reactionKey,
                resource=resource,spellId=spellId,
            })
            reactionResourceSnapshots[reactionKey]=nil
            reactionSpellIds[reactionKey]=nil
            reactionExpiry[reactionKey]=nil
            pendingReactionKeys[reactionKey]=nil
        elseif not spellId and not pending then
            reactionResourceSnapshots[reactionKey]=nil
        end
    end
end

local SHIELD_MAP={
    resistfire="fireshield",resistfrost="frostshield",
    resistshock="lightningshield",resistpoison="shield",resistmagicka="shield",
}
local CURE_MAP={
    curedisease="resistcommondisease",curecommondisease="resistcommondisease",
    cureblightdisease="resistblightdisease",curepoison="resistpoison",
}

--- Converts a Fortify dynamic-stat effect into a periodic Restore rate. The
--- stronger of magnitude and duration is divided by the weaker, scaled by the
--- perk rank, and rounded up; the Restore keeps the potion's natural duration.
--- @param magnitude number Source Fortify magnitude.
--- @param percent number Rank conversion percentage.
--- @param requestedDuration number Potion effect duration.
--- @return number restoreMagnitude
--- @return number restoreDuration
--- @return string shape Diagnostic calculation path.
local function restorativeRate(magnitude,percent,requestedDuration)
    local duration=math.max(1,requestedDuration)
    local lower=math.min(math.max(0,magnitude),duration)
    local higher=math.max(math.max(0,magnitude),duration)
    if lower<=0 then return 0,duration,"zero ratio operand" end
    return math.ceil((higher/lower)*percent),duration,"higher/lower ratio"
end

local function applyReaction(effect,a,sourceRecord)
    local sourceRecordId=sourceRecord and sourceRecord.id
    local configuredEffect=recordEffect(sourceRecord,effect)
    local trace = SkillDebug.beginTrace("alchemy", "Alchemical Reaction", "potion effect observed", {
        effect = effect and effect.id,
        magnitude = effect and effect.magnitudeThisFrame,
        magnitudeMin = effect and effect.minMagnitude,
        magnitudeMax = effect and effect.maxMagnitude,
        rank = a,
        source = sourceRecordId,
    })
    if not trace:gate("perk rank is active", a > 0, { rank=a }) then
        diagnostics.lastReaction="Rejected: A chain inactive."
        return trace:reject("A chain inactive")
    end
    local id=tostring(effect and effect.id or ""):lower()
    local magnitude,magnitudeSource=resolvedMagnitude(effect,configuredEffect)
    magnitude=math.max(0,magnitude)
    local natural,durationSource=resolvedDuration(effect,configuredEffect)
    local duration=math.max(natural,({10,15,20,30})[a])
    local percent=({0.20,0.30,0.40,0.50})[a]
    local extra=effect.affectedAttribute or effect.affectedSkill
    local targetId,targetMagnitude,reactionShape
    if id=="restorehealth" or id=="restoremagicka" or id=="restorefatigue" then
        targetId="fortify"..id:sub(8)
        targetMagnitude=math.ceil(magnitude*natural*percent)
        reactionShape="source total"
    elseif id=="restoreattribute" then
        targetId,targetMagnitude="fortifyattribute",math.ceil(magnitude*natural*percent)
        reactionShape="source total"
    elseif id=="fortifyhealth" or id=="fortifymagicka" or id=="fortifyfatigue" then
        targetId="restore"..id:sub(8)
        targetMagnitude,duration,reactionShape=restorativeRate(magnitude,percent,natural)
    elseif id=="fortifyattribute" then
        -- Restore Attribute is applied once, so its full converted budget
        -- belongs in the magnitude rather than being divided by duration.
        targetId,targetMagnitude="restoreattribute",math.ceil(magnitude*percent)
        duration=1
        reactionShape="applied once"
    elseif SHIELD_MAP[id] then
        local floor=({5,10,15,20})[a]
        local pct=({0.15,0.25,0.35,0.50})[a]
        targetId,targetMagnitude=SHIELD_MAP[id],math.max(floor,math.ceil(magnitude*pct))
        reactionShape="resistance scaling"
    elseif CURE_MAP[id] then
        targetId,targetMagnitude=CURE_MAP[id],25
        duration=({900,1800,2700,3600})[a]
    end
    trace:step("secondary effect calculated", {
        duration=duration,durationSource=durationSource,
        magnitudeSource=magnitudeSource,naturalDuration=natural,
        reactionShape=reactionShape,
        sourceEffect=id,sourceMagnitude=magnitude,
        targetEffect=targetId, targetMagnitude=targetMagnitude,
    })
    if not targetId or targetMagnitude <= 0 then
        diagnostics.lastReaction=string.format(
            "Rejected: source=%s effect=%s magnitude=%s(%s) duration=%s(%s) shape=%s has no qualifying conversion.",
            tostring(sourceRecordId),id,SkillDebug.number(magnitude),magnitudeSource,
            SkillDebug.number(natural),durationSource,tostring(reactionShape)
        )
        return trace:reject("source effect has no qualifying reaction")
    end
    local reactionKey=targetId.."|"..tostring(extra or "")
    local now=core.getSimulationTime()
    local expiresAt=reactionExpiry[reactionKey] or 0
    local trackedSpellId=reactionSpellIds[reactionKey]
    local trackedActive=reactionSpellIsActive(trackedSpellId)
        or mimickedEffects.isActive(reactionKey)
    local pendingRequest=pendingReactionKeys[reactionKey]
    if expiresAt>now and (trackedActive or pendingRequest~=nil) then
        diagnostics.lastReaction=string.format(
            "Rejected: %s is already tracked as spell=%s pending=%s until %s.",
            reactionKey,tostring(trackedSpellId),tostring(pendingRequest),
            SkillDebug.number(expiresAt)
        )
        return trace:reject("matching reaction is still active", {
            expiresAt=expiresAt,now=now,pendingRequest=pendingRequest,
            reactionKey=reactionKey,spellId=trackedSpellId,trackedActive=trackedActive,
        })
    end
    if expiresAt>0 then
        reactionExpiry[reactionKey]=nil
        reactionSpellIds[reactionKey]=nil
        pendingReactionKeys[reactionKey]=nil
        reactionResourceSnapshots[reactionKey]=nil
        trace:step("stale reaction lock cleared",{
            expiresAt=expiresAt,now=now,reactionKey=reactionKey,
            spellId=trackedSpellId,trackedActive=trackedActive,
        })
    end
    local queued,requestId=mimickedEffects.apply({
        id=targetId,magnitudeMin=targetMagnitude,duration=duration,
        affectedAttribute=effect.affectedAttribute,affectedSkill=effect.affectedSkill,
    },{key=reactionKey,sourceEffect=ids["A"..a],stackable=false})
    local mimicked=queued
    if not queued then
        queued,requestId=Common.applyDynamicSpell(self,self,"Alchemical Reaction",{{
            id=targetId,magnitudeMin=targetMagnitude,duration=duration,
            affectedAttribute=effect.affectedAttribute,affectedSkill=effect.affectedSkill,
        }},{ignoreReflect=true,ignoreResistances=true,ignoreSpellAbsorption=true})
    end
    if not queued then
        diagnostics.lastReaction=string.format(
            "Failed to queue %s magnitude %s for %ss.",
            reactionKey,SkillDebug.number(targetMagnitude),SkillDebug.number(duration)
        )
        return trace:reject("mimicked effect was not applied",{reason=requestId})
    end
    reactionExpiry[reactionKey]=now+duration
    if not mimicked then
        reactionRequests[requestId]=reactionKey
        pendingReactionKeys[reactionKey]=requestId
        ensureResourceSnapshot(reactionKey,FORTIFY_RESOURCE[targetId])
    end
    diagnostics.lastReaction=string.format(
        "Queued: source=%s %s(%s via %s, %ss via %s) -> %s magnitude=%s duration=%ss shape=%s request=%s.",
        tostring(sourceRecordId),id,SkillDebug.number(magnitude),magnitudeSource,
        SkillDebug.number(natural),durationSource,reactionKey,
        SkillDebug.number(targetMagnitude),SkillDebug.number(duration),
        tostring(reactionShape or "standard"),tostring(requestId)
    )
    trace:finish(mimicked and "mimicked effect applied" or "native fallback queued", {
        duration=duration, effect=targetId, expiresAt=reactionExpiry[reactionKey],
        magnitude=targetMagnitude,queued=queued,reactionKey=reactionKey,requestId=requestId,
    })
end

local INVERT={
    drainattribute="fortifyattribute",drainhealth="fortifyhealth",
    drainmagicka="fortifymagicka",drainfatigue="fortifyfatigue",
    drainskill="fortifyskill",damageattribute="restoreattribute",
    damagehealth="restorehealth",damagemagicka="restoremagicka",
    damagefatigue="restorefatigue",damageskill="restoreskill",
    firedamage="fireshield",frostdamage="frostshield",
    shockdamage="lightningshield",
    weaknesstofire="resistfire",weaknesstofrost="resistfrost",
    weaknesstoshock="resistshock",weaknesstomagicka="resistmagicka",
    weaknesstocommondisease="resistcommondisease",
    weaknesstoblightdisease="resistblightdisease",
    weaknesstocorprusdisease="resistcorprusdisease",
    weaknesstopoison="resistpoison",weaknesstonormalweapons="resistnormalweapons",
    burden="feather",poison="restorehealth",blind="fortifyattack",
}

local function ingredientEffects(spell,b,record)
    local trace = SkillDebug.beginTrace("alchemy", "Raw Ingestion", "ingredient effect observed", {
        activeSpell=spell and spell.activeSpellId,
        item=spell and SkillDebug.objectId(spell.item),
        record=record and record.id,
        rank=b,
    })
    if b<=0 then
        diagnostics.lastIngredient="Rejected: B chain inactive."
        return trace:reject("B chain inactive")
    end
    if not record then
        diagnostics.lastIngredient="Rejected: ingredient record could not be resolved."
        return trace:reject("source record is not an ingredient")
    end
    local basis=spell.effects and spell.effects[1]
    if not basis then
        diagnostics.lastIngredient="Rejected: ingredient active spell has no successful basis effect."
        return trace:reject("active ingredient has no basis effect")
    end
    local configuredBasis=recordEffect(record,basis)
    local magnitude,magnitudeSource=resolvedMagnitude(basis,configuredBasis)
    magnitude=math.max(1,magnitude)
    local duration,durationSource=resolvedDuration(basis,configuredBasis)
    local applied=0
    for index,effect in ipairs(record.effects or {}) do
        local effectRecord=core.magic.effects.records[effect.id]
        local harmful=effectRecord and effectRecord.harmful
        if index>1 and (not harmful or b>=2) then
            local id=harmful and INVERT[effect.id] or effect.id
            local value=magnitude
            if effect.id=="paralyze" then id,value="resistparalysis",100 end
            if effect.id=="silence" then id,value="sound",-100 end
            if id then
                trace:step("additional ingredient effect accepted", {
                    harmful=harmful, index=index, sourceEffect=effect.id,
                    targetEffect=id, value=value,
                })
                local effectData={
                    id=id,magnitudeMin=value,duration=duration,
                    affectedAttribute=effect.affectedAttribute,
                    affectedSkill=effect.affectedSkill,
                }
                local queued=select(1,mimickedEffects.apply(effectData,{
                    key="RawIngestion:"..tostring(record.id)..":"..tostring(index),
                    sourceEffect=ids["B"..b],stackable=true,
                }))
                if not queued then
                    queued=Common.applyDynamicSpell(self,self,"Raw Ingestion",{effectData},{
                        ignoreReflect=true,ignoreResistances=true,
                        ignoreSpellAbsorption=true,stackable=true,
                    })
                end
                if queued then applied=applied+1 end
                trace:step("additional ingredient effect queued",{
                    index=index,queued=queued,targetEffect=id,
                })
            end
        elseif index > 1 then
            trace:step("additional ingredient effect rejected", {
                harmful=harmful, index=index, rank=b, sourceEffect=effect.id,
            })
        end
    end
    local firstRecord=core.magic.effects.records[basis.id]
    if firstRecord and firstRecord.harmful then
        local removed,removeError=pcall(function()
            types.Actor.activeSpells(self):remove(spell.activeSpellId)
        end)
        trace:step("harmful basis removal resolved",{
            activeSpell=spell.activeSpellId,error=removed and nil or removeError,
            removed=removed,
        })
        if b>=2 then
            local id=INVERT[basis.id]
            local value=magnitude
            if basis.id=="paralyze" then id,value="resistparalysis",100 end
            if basis.id=="silence" then id,value="sound",-100 end
            if id then
                local effectData={
                    id=id,magnitudeMin=value,duration=duration,
                    affectedAttribute=basis.affectedAttribute,affectedSkill=basis.affectedSkill,
                }
                local queued=select(1,mimickedEffects.apply(effectData,{
                    key="RawIngestion:"..tostring(record.id)..":basis",
                    sourceEffect=ids["B"..b],stackable=false,
                }))
                if not queued then
                    queued=Common.applyDynamicSpell(self,self,"Raw Ingestion",{effectData},{
                        ignoreReflect=true,ignoreResistances=true,
                        ignoreSpellAbsorption=true,stackable=false,
                    })
                end
                if queued then applied=applied+1 end
                trace:step("harmful basis inversion queued",{
                    queued=queued,sourceEffect=basis.id,targetEffect=id,value=value,
                })
            end
        end
    end
    if applied==0 and firstRecord and firstRecord.harmful then
        ui.showMessage("The ingredient's toxicity breaks harmlessly against your practiced constitution.")
    end
    diagnostics.lastIngredient=string.format(
        "Processed: record=%s basis=%s magnitude=%s(%s) duration=%ss(%s) harmful=%s queued=%d.",
        tostring(record.id),tostring(basis.id),SkillDebug.number(magnitude),magnitudeSource,
        SkillDebug.number(duration),durationSource,
        tostring(firstRecord and firstRecord.harmful),applied
    )
    trace:finish("ingredient processing complete", {
        applied=applied,basis=basis.id,duration=duration,durationSource=durationSource,
        magnitude=magnitude,magnitudeSource=magnitudeSource,record=record.id,
        basisHarmful=firstRecord and firstRecord.harmful,
    })
end

local function inspectNewItemEffects()
    local current={}
    local activeCount,newCount,classifiedCount=0,0,0
    local a,b=rank("A"),rank("B")
    for _,spell in pairs(types.Actor.activeSpells(self)) do
        activeCount=activeCount+1
        local key=spell.activeSpellId or spell.id
        current[key]=true
        if not seenSpells[key] then
            newCount=newCount+1
            local kind,record,sourceField=classifyConsumable(spell)
            local effectCount=SkillDebug.count(spell.effects)
            if kind then classifiedCount=classifiedCount+1 end
            diagnostics.lastObservedSpell=string.format(
                "Active spell=%s id=%s item=%s classification=%s via=%s record=%s effects=%d.",
                tostring(key),tostring(spell.id),SkillDebug.objectId(spell.item),
                tostring(kind or "not consumable"),sourceField,
                tostring(record and record.id),effectCount
            )
            if kind then diagnostics.lastConsumable=diagnostics.lastObservedSpell end
            local trace=SkillDebug.beginTrace(
                "alchemy","Consumable detector","new active spell observed",{
                    aRank=a,activeSpell=key,bRank=b,effects=effectCount,
                    item=SkillDebug.objectId(spell.item),kind=kind,
                    record=record and record.id,sourceField=sourceField,
                    spellId=spell.id,
                }
            )
            if kind=="potion" then
                if a>0 then
                    trace:step("potion routed to Alchemical Reaction",{
                        effects=effectCount,record=record.id,
                    })
                    for _,effect in pairs(spell.effects or {}) do
                        applyReaction(effect,a,record)
                    end
                    trace:finish("potion processing complete")
                else
                    trace:reject("potion observed but A chain is inactive")
                end
            elseif kind=="ingredient" then
                if b>0 then
                    trace:step("ingredient routed to Raw Ingestion",{
                        effects=effectCount,record=record.id,
                    })
                    ingredientEffects(spell,b,record)
                    trace:finish("ingredient processing complete")
                else
                    trace:reject("ingredient observed but B chain is inactive")
                end
            else
                trace:reject("active spell is not backed by a potion or ingredient record")
            end
        end
    end
    seenSpells=current
    diagnostics.lastScan=string.format(
        "active=%d new=%d consumables=%d seenAfter=%d A=%d B=%d.",
        activeCount,newCount,classifiedCount,SkillDebug.count(seenSpells),a,b
    )
    SkillDebug.traceState("alchemy","Consumable detector","active-spell-scan",{
        active=activeCount,classified=classifiedCount,new=newCount,seen=SkillDebug.count(seenSpells),
    })
end

local function preserveConsumedPotions()
    local current=countsOf(types.Potion)
    local c=rank("C")
    local consumedTotal,replacedTotal=0,0
    if not inAlchemy then
        local chance=c==2 and 0.50 or 0.25
        for id,old in pairs(potionSnapshot) do
            for _=1,math.max(0,old-(current[id] or 0)) do
                consumedTotal=consumedTotal+1
                local roll=c>0 and math.random() or nil
                local trace=SkillDebug.beginTrace("alchemy","Preserved Dose","potion consumption detected",{
                    before=old,cRank=c,chance=chance,current=current[id] or 0,
                    potion=id,roll=roll,
                })
                if c<=0 then
                    trace:reject("potion consumed but C chain is inactive")
                else
                    local replaced=roll<chance and duplicate(id,1,"Preserved Dose")
                    if replaced then replacedTotal=replacedTotal+1 end
                    trace:finish(replaced and "replacement queued" or "preservation roll failed",{
                        replaced=replaced,
                    })
                end
            end
        end
    end
    if consumedTotal>0 then
        diagnostics.lastPreservation=string.format(
            "Detected %d consumed potion(s); C=%d queued %d replacement(s).",
            consumedTotal,c,replacedTotal
        )
    elseif inAlchemy then
        diagnostics.lastPreservation="Potion diff paused while the Alchemy window is active."
    end
    potionSnapshot=current
end

--- Returns an ingredient's display name without allowing a missing modded
--- record to interrupt batch settlement or its player-facing summary.
--- @param recordId string Ingredient record id.
--- @return string name
local function ingredientName(recordId)
    local ok,record=pcall(types.Ingredient.record,recordId)
    if ok and record and record.name and record.name~="" then return record.name end
    return tostring(recordId)
end

--- Formats successful ingredient-preservation rolls in stable name order.
--- @param refunds table<string,number> Refunded units by ingredient record.
--- @return string summary
local function refundedIngredientSummary(refunds)
    local entries={}
    for recordId,count in pairs(refunds or {}) do
        if count>0 then
            entries[#entries+1]={name=ingredientName(recordId),count=count}
        end
    end
    table.sort(entries,function(left,right)
        return left.name:lower()<right.name:lower()
    end)
    if #entries==0 then return "none" end
    local parts={}
    for _,entry in ipairs(entries) do
        parts[#parts+1]=string.format("%d %s",entry.count,entry.name)
    end
    return table.concat(parts,", ")
end

--- Resolves one completed Alchemy session after the UI has committed its
--- inventory changes. Every consumed ingredient unit receives an independent
--- preservation roll; successful rolls are delivered in per-record batches.
--- @param session table Opening inventory snapshots.
--- @param d number D-chain rank captured when the Alchemy window closed.
local function resolveAlchemySession(session,d)
    local trace=SkillDebug.beginTrace("alchemy","Alchemy session","settled inventory diff",{
        dRank=d,settleDelay=ALCHEMY_SETTLE_DELAY,
    })
    local producedTotal,bonusTotal,consumedTotal,preservedTotal=0,0,0,0
    local preservedById={}
    local ingredients=countsOf(types.Ingredient)
    local potions=countsOf(types.Potion)

    if d>0 and session then
        for id,now in pairs(potions) do
            local produced=math.max(0,now-(session.potions[id] or 0))
            local bonus=math.floor(produced*(d==2 and 1 or 0.5))
            local queued=duplicate(id,bonus,"batch yield")
            producedTotal=producedTotal+produced
            bonusTotal=bonusTotal+(queued and bonus or 0)
            trace:step("batch output resolved",{
                bonus=bonus,potion=id,produced=produced,queued=queued,
            })
        end

        local chance=d==2 and 0.35 or 0.20
        for id,before in pairs(session.ingredients) do
            local consumed=math.max(0,before-(ingredients[id] or 0))
            local preserved=0
            for rollIndex=1,consumed do
                consumedTotal=consumedTotal+1
                local roll=math.random()
                local succeeded=roll<chance
                if succeeded then preserved=preserved+1 end
                trace:step("ingredient preservation rolled",{
                    chance=chance,ingredient=id,roll=roll,
                    rollIndex=rollIndex,succeeded=succeeded,
                })
            end
            if preserved>0 then
                local queued=duplicate(id,preserved,"ingredient preservation")
                if queued then
                    preservedById[id]=preserved
                    preservedTotal=preservedTotal+preserved
                end
                trace:step("ingredient refunds queued",{
                    ingredient=id,preserved=preserved,queued=queued,
                })
            end
        end
    end

    local refundSummary=refundedIngredientSummary(preservedById)
    diagnostics.lastSession=string.format(
        "Settled: D=%d produced=%d bonusQueued=%d ingredientsUsed=%d preservedQueued=%d refunds=%s.",
        d,producedTotal,bonusTotal,consumedTotal,preservedTotal,refundSummary
    )
    potionSnapshot=countsOf(types.Potion)

    if d>0 and (producedTotal>0 or consumedTotal>0) then
        ui.showMessage(string.format(
            "%d extra potion%s brewed. Refunded ingredients: %s.",
            bonusTotal,bonusTotal==1 and "" or "s",refundSummary
        ))
    end
    trace:finish("session settlement complete",{
        bonusQueued=bonusTotal,dRank=d,ingredientsConsumed=consumedTotal,
        ingredientsPreserved=preservedTotal,potionsProduced=producedTotal,
        refunds=refundSummary,
    })
end

local function onUiModeChanged(data)
    data=data or {}
    local oldMode=tostring(data.oldMode or "")
    local newMode=tostring(data.newMode or "")
    local oldKey=oldMode:lower()
    local newKey=newMode:lower()
    local trace=SkillDebug.beginTrace("alchemy","Alchemy session","UI mode changed",{
        newMode=newMode,oldMode=oldMode,
    })
    diagnostics.lastSession=string.format(
        "UI transition old=%s new=%s.",
        oldMode~="" and oldMode or "nil",newMode~="" and newMode or "nil"
    )
    if newKey=="alchemy" then
        if pendingAlchemyClose then
            resolveAlchemySession(pendingAlchemyClose.session,pendingAlchemyClose.rank)
            pendingAlchemyClose=nil
        end
        inAlchemy=true
        alchemySession={ingredients=countsOf(types.Ingredient),potions=countsOf(types.Potion)}
        diagnostics.lastSession=string.format(
            "Opened: captured %d ingredient and %d potion record stacks.",
            SkillDebug.count(alchemySession.ingredients),SkillDebug.count(alchemySession.potions)
        )
        trace:finish("session snapshot captured",{
            ingredientRecords=SkillDebug.count(alchemySession.ingredients),
            potionRecords=SkillDebug.count(alchemySession.potions),
        })
    elseif oldKey=="alchemy" then
        inAlchemy=false
        local d=rank("D")
        pendingAlchemyClose={session=alchemySession,rank=d,timer=ALCHEMY_SETTLE_DELAY}
        diagnostics.lastSession=string.format(
            "Closed: D=%d settlement pending for %.2fs; session=%s.",
            d,ALCHEMY_SETTLE_DELAY,tostring(alchemySession~=nil)
        )
        alchemySession=nil
        trace:finish("session settlement scheduled",{
            dRank=d,settleDelay=ALCHEMY_SETTLE_DELAY,
        })
    else
        trace:reject("mode change is unrelated to Alchemy")
    end
end

local function clear()
    seenSpells=activeSpellSnapshot()
    alchemySession=nil
    pendingAlchemyClose=nil
    -- Active dynamic-stat reactions must remain tracked after a respec so
    -- their later expiry cannot corrupt the player's current resources.
    for reactionKey in pairs(reactionExpiry) do
        if not reactionResourceSnapshots[reactionKey] then
            reactionExpiry[reactionKey]=nil
            reactionSpellIds[reactionKey]=nil
            pendingReactionKeys[reactionKey]=nil
        end
    end
    for requestId,reactionKey in pairs(reactionRequests) do
        if not reactionResourceSnapshots[reactionKey] then
            reactionRequests[requestId]=nil
        end
    end
end

local function onUpdate(dt)
    mimickedEffects.update(dt)
    local now=core.getSimulationTime()
    for reactionKey,expiresAt in pairs(reactionExpiry) do
        if now>=expiresAt and not reactionSpellIds[reactionKey] then
            reactionExpiry[reactionKey]=nil
        end
    end
    reconcileExpiredResourceReactions()
    inspectNewItemEffects()
    if pendingAlchemyClose then
        pendingAlchemyClose.timer=pendingAlchemyClose.timer-dt
        if pendingAlchemyClose.timer<=0 then
            local pending=pendingAlchemyClose
            pendingAlchemyClose=nil
            resolveAlchemySession(pending.session,pending.rank)
        end
    end
    timer=timer-dt
    if timer<=0 then timer=0.5 preserveConsumedPotions() end
end

--- Formats every field supplied by OpenMW's Alchemy skill-use callback. The
--- exact parameter set varies by use type and engine version, so retaining all
--- fields is more useful than assuming undocumented batch property names.
--- @param params table|nil SkillProgression parameters.
--- @return string summary
local function skillUseSummary(params)
    local keys={}
    for key in pairs(params or {}) do keys[#keys+1]=key end
    table.sort(keys,function(left,right) return tostring(left)<tostring(right) end)
    local parts={}
    for _,key in ipairs(keys) do
        parts[#parts+1]=tostring(key).."="..SkillDebug.value(params[key])
    end
    return #parts>0 and table.concat(parts," ") or "<no parameters>"
end

--- Records the authoritative Alchemy skill-use boundary. Active-spell and UI
--- diffs still perform the effects, but this trace establishes whether the
--- engine reported raw ingestion or brewing before those later stages run.
interfaces.ErnPerkFramework.registerSkillUseHandler({
    id="SkillPerks_alchemy_uses",skill="alchemy",
    handler=function(event)
        local params=event and event.params or {}
        local useType=Common.skillUseType(event)
        diagnostics.lastSkillUse=string.format(
            "useType=%s %s",tostring(useType),skillUseSummary(params)
        )
        local trace=SkillDebug.beginTrace(
            "alchemy","Alchemy skill use","framework skill-use event",{
                params=params,useType=useType,
            }
        )
        trace:finish("skill-use boundary recorded")
    end,
})

--- Retains the global dynamic-spell result while Alchemy tracing is active.
--- Core 0 also logs this event, but the local snapshot makes the last delivery
--- visible through `luaalchemy debug` after the live log has scrolled away.
--- @param data table Dynamic spell application result.
local function onMagicSpellApplicationResult(data)
    data=data or {}
    if data.traceSkill~="alchemy" then return end
    local reactionKey=reactionRequests[data.requestId]
    if reactionKey then
        reactionRequests[data.requestId]=nil
        if pendingReactionKeys[reactionKey]==data.requestId then
            pendingReactionKeys[reactionKey]=nil
        end
        if (data.success==true or data.active==true) and data.spellId then
            reactionSpellIds[reactionKey]=data.spellId
            ensureResourceSnapshot(
                reactionKey,
                FORTIFY_RESOURCE[reactionEffectId(reactionKey)]
            )
        else
            reactionSpellIds[reactionKey]=nil
            reactionExpiry[reactionKey]=nil
            reactionResourceSnapshots[reactionKey]=nil
        end
    end
    diagnostics.lastDelivery=string.format(
        "effect=%s reaction=%s stage=%s success=%s active=%s skipped=%s spell=%s error=%s",
        tostring(data.effectId),tostring(reactionKey),tostring(data.stage),
        tostring(data.success),tostring(data.active),tostring(data.skipped),
        tostring(data.spellId),tostring(data.error)
    )
end

--- Records whether the global item bridge actually created and delivered a
--- preserved potion, bonus batch, or returned ingredient.
--- @param data table Item-duplication result.
local function onItemDuplicationResult(data)
    data=data or {}
    diagnostics.lastDuplication=string.format(
        "request=%s record=%s requested=%s delivered=%s stage=%s success=%s error=%s",
        tostring(data.requestId),tostring(data.recordId),tostring(data.requestedCount),
        tostring(data.deliveredCount),tostring(data.stage),tostring(data.success),
        tostring(data.error)
    )
    SkillDebug.traceEvent("alchemy","GLOBAL item duplication result",data)
end

local function totalUnits(counts)
    local total=0
    for _,count in pairs(counts or {}) do total=total+(tonumber(count) or 0) end
    return total
end

-- Reports potion/ingredient inventory tracking and active reaction bookkeeping.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Alchemy",
    skillId = "alchemy",
    actor = self,
    ids = ids,
    commands = { "luaalchemy debug", "luaalch debug" },
    snapshot = function()
        return {
            string.format(
                "Alchemy UI: active=%s session=%s timer=%s",
                tostring(inAlchemy),
                tostring(alchemySession ~= nil),
                SkillDebug.number(timer)
            ),
            string.format(
                "Tracking: potionRecords=%d potionUnits=%d seenSpells=%d activeReactions=%d trackedReactionSpells=%d resourceGuards=%d pendingReactions=%d trace=%s",
                SkillDebug.count(potionSnapshot),
                totalUnits(potionSnapshot),
                SkillDebug.count(seenSpells),
                SkillDebug.count(reactionExpiry),
                SkillDebug.count(reactionSpellIds),
                SkillDebug.count(reactionResourceSnapshots),
                SkillDebug.count(pendingReactionKeys),
                tostring(SkillDebug.isTraceEnabled("alchemy"))
            ),
            string.format("Mimicked active effects=%d",mimickedEffects.count()),
            "Last scan: "..diagnostics.lastScan,
            "Last new spell: "..diagnostics.lastObservedSpell,
            "Last consumable: "..diagnostics.lastConsumable,
            "Last A reaction: "..diagnostics.lastReaction,
            "Last B ingestion: "..diagnostics.lastIngredient,
            "Last C preservation: "..diagnostics.lastPreservation,
            "Last D session: "..diagnostics.lastSession,
            "Last skill use: "..diagnostics.lastSkillUse,
            "Last spell delivery: "..diagnostics.lastDelivery,
            "Last Fortify expiry: "..diagnostics.lastExpiryCorrection,
            "Last item delivery: "..diagnostics.lastDuplication,
        }
    end,
})

Common.registerMagicPerks("alchemy","Alchemy",ids,{
    A1={localizedName="Alchemical Reaction",localizedFlavour="A draught is not one effect but a conversation, and you have learned to hear the answer.",localizedDescription="Potion effects create related secondary effects at 20% strength.",onRemove=clear},
    A2={localizedName="Catalytic Insight",localizedFlavour="Every tincture carries another possibility waiting for the practiced body to reveal it.",localizedDescription="Alchemical Reaction rises to 30% with stronger minimum effects.",onRemove=clear},
    A3={localizedName="Living Retort",localizedFlavour="Your body completes reactions no glass vessel could survive.",localizedDescription="Alchemical Reaction rises to 40%.",onRemove=clear},
    A4={localizedName="Perfect Transmutation",localizedFlavour="Nothing entering your blood remains only what the brewer intended.",localizedDescription="Alchemical Reaction rises to 50% with the strongest duration floors.",onRemove=clear},
    B1={localizedName="Raw Ingestion",localizedFlavour="Where others taste bitterness, you taste an unfinished formula.",localizedDescription="A successful raw-ingredient use also applies every beneficial effect on that ingredient; harmful results are discarded.",onRemove=clear},
    B2={localizedName="Universal Antidote",localizedFlavour="Even poison is merely medicine facing the wrong direction.",localizedDescription="Raw Ingestion inverts harmful ingredient effects into beneficial counterparts, including elemental damage into the matching elemental Shield.",onRemove=clear},
    C1={localizedName="Preserved Dose",localizedFlavour="The bottle empties, yet the practiced hand finds one measured draught still waiting.",localizedDescription="Drinking a potion has a 25% chance to replace the consumed dose.",onRemove=clear},
    C2={localizedName="Lasting Vintage",localizedFlavour="A master alchemist can make one perfect measure survive every thirst.",localizedDescription="Preserved Dose chance rises to 50%.",onRemove=clear},
    D1={localizedName="Efficient Preparation",localizedFlavour="Nothing clings to mortar or alembic unless you have decided it may be wasted.",localizedDescription="Brewing produces 50% bonus potions; every consumed ingredient has an independent 20% preservation chance. Results are reported when Alchemy closes.",onRemove=clear},
    D2={localizedName="Master's Batch",localizedFlavour="Your laboratory does not multiply ingredients. It multiplies certainty.",localizedDescription="Brewing output doubles; every consumed ingredient has an independent 35% preservation chance. Results are reported when Alchemy closes.",onRemove=clear},
})

return {
    eventHandlers={
        SPerks_UiModeChanged=onUiModeChanged,
        SPerks_MagicSpellApplicationResult=onMagicSpellApplicationResult,
        SPerks_AlchemyItemDuplicationResult=onItemDuplicationResult,
    },
    engineHandlers={
        onConsoleCommand=onConsoleCommand,
        onUpdate=onUpdate,
        onSave=function()
            return {
                potionSnapshot=potionSnapshot,
                reactionExpiry=reactionExpiry,
                reactionSpellIds=reactionSpellIds,
                reactionResourceSnapshots=reactionResourceSnapshots,
                mimickedEffects=mimickedEffects.snapshot(),
            }
        end,
        onLoad=function(data)
            potionSnapshot=(data and data.potionSnapshot) or countsOf(types.Potion)
            reactionExpiry=(data and data.reactionExpiry) or {}
            reactionSpellIds=(data and data.reactionSpellIds) or {}
            reactionResourceSnapshots=(data and data.reactionResourceSnapshots) or {}
            mimickedEffects.restore(data and data.mimickedEffects)
            reactionRequests={}
            pendingReactionKeys={}
            seenSpells=activeSpellSnapshot()
        end,
    },
}
