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

local ids=Common.ids("alchemy")
local seenSpells={}
local potionSnapshot={}
local alchemySession=nil
local inAlchemy=false
local timer=0
local reactionExpiry={}

local function rank(chain) return Common.rank(ids,chain) end
local function countsOf(typeObject)
    local result={}
    for _,item in ipairs(types.Actor.inventory(self):getAll(typeObject)) do
        result[item.recordId]=(result[item.recordId] or 0)+(item.count or 1)
    end
    return result
end
local function duplicate(recordId,count)
    if not recordId or count <= 0 then return end
    core.sendGlobalEvent("SPerks_DuplicateItem",{target=self,recordId=recordId,count=count})
end

local SHIELD_MAP={
    resistfire="fireshield",resistfrost="frostshield",
    resistshock="lightningshield",resistpoison="shield",resistmagicka="shield",
}
local CURE_MAP={
    curedisease="resistcommondisease",curecommondisease="resistcommondisease",
    cureblightdisease="resistblightdisease",curepoison="resistpoison",
}

local function applyReaction(effect,a)
    local id=effect.id
    local magnitude=math.max(0,tonumber(effect.magnitudeThisFrame) or 0)
    local natural=math.max(1,tonumber(effect.duration) or tonumber(effect.durationLeft) or 1)
    local duration=math.max(natural,({10,15,20,30})[a])
    local percent=({0.20,0.30,0.40,0.50})[a]
    local extra=effect.affectedAttribute or effect.affectedSkill
    local targetId,targetMagnitude
    if id=="restorehealth" or id=="restoremagicka" or id=="restorefatigue" then
        targetId="fortify"..id:sub(8)
        targetMagnitude=math.floor(magnitude*natural*percent)
    elseif id=="restoreattribute" then
        targetId,targetMagnitude="fortifyattribute",math.floor(magnitude*natural*percent)
    elseif id=="fortifyhealth" or id=="fortifymagicka" or id=="fortifyfatigue" then
        targetId="restore"..id:sub(8)
        targetMagnitude=math.floor(magnitude*percent/duration)
    elseif id=="fortifyattribute" then
        targetId,targetMagnitude="restoreattribute",math.floor(magnitude*percent/duration)
    elseif SHIELD_MAP[id] then
        local floor=({5,10,15,20})[a]
        local pct=({0.15,0.25,0.35,0.50})[a]
        targetId,targetMagnitude=SHIELD_MAP[id],math.max(floor,math.floor(magnitude*pct))
    elseif CURE_MAP[id] then
        targetId,targetMagnitude=CURE_MAP[id],25
        duration=({900,1800,2700,3600})[a]
    end
    if not targetId or targetMagnitude <= 0 then return end
    local reactionKey=targetId.."|"..tostring(extra or "")
    if (reactionExpiry[reactionKey] or 0)>core.getSimulationTime() then return end
    Common.applyDynamicSpell(self,self,"Alchemical Reaction",{{
        id=targetId,magnitudeMin=targetMagnitude,duration=duration,
        affectedAttribute=effect.affectedAttribute,affectedSkill=effect.affectedSkill,
    }},{ignoreReflect=true,ignoreResistances=true,ignoreSpellAbsorption=true})
    reactionExpiry[reactionKey]=core.getSimulationTime()+duration
end

local INVERT={
    drainattribute="fortifyattribute",drainhealth="fortifyhealth",
    drainmagicka="fortifymagicka",drainfatigue="fortifyfatigue",
    drainskill="fortifyskill",damageattribute="restoreattribute",
    damagehealth="restorehealth",damagemagicka="restoremagicka",
    damagefatigue="restorefatigue",damageskill="restoreskill",
    weaknesstofire="resistfire",weaknesstofrost="resistfrost",
    weaknesstoshock="resistshock",weaknesstomagicka="resistmagicka",
    weaknesstocommondisease="resistcommondisease",
    weaknesstoblightdisease="resistblightdisease",
    weaknesstocorprusdisease="resistcorprusdisease",
    weaknesstopoison="resistpoison",weaknesstonormalweapons="resistnormalweapons",
    burden="feather",poison="restorehealth",blind="fortifyattack",
}

local function ingredientEffects(spell,b)
    local item=spell.item
    if not item or not types.Ingredient.objectIsInstance(item) then return end
    local record=types.Ingredient.record(item)
    local basis=spell.effects and spell.effects[1]
    if not basis then return end
    local magnitude=math.max(1,tonumber(basis.magnitudeThisFrame) or 1)
    local duration=math.max(1,tonumber(basis.duration) or 1)
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
                Common.applyDynamicSpell(self,self,"Raw Ingestion",{{
                    id=id,magnitudeMin=value,duration=duration,
                    affectedAttribute=effect.affectedAttribute,
                    affectedSkill=effect.affectedSkill,
                }},{ignoreReflect=true,ignoreResistances=true,ignoreSpellAbsorption=true,stackable=true})
                applied=applied+1
            end
        end
    end
    local firstRecord=core.magic.effects.records[basis.id]
    if firstRecord and firstRecord.harmful then
        types.Actor.activeSpells(self):remove(spell.activeSpellId)
        if b>=2 then
            local id=INVERT[basis.id]
            local value=magnitude
            if basis.id=="paralyze" then id,value="resistparalysis",100 end
            if basis.id=="silence" then id,value="sound",-100 end
            if id then
                Common.applyDynamicSpell(self,self,"Raw Ingestion",{{
                    id=id,magnitudeMin=value,duration=duration,
                    affectedAttribute=basis.affectedAttribute,affectedSkill=basis.affectedSkill,
                }},{ignoreReflect=true,ignoreResistances=true,ignoreSpellAbsorption=true})
                applied=applied+1
            end
        end
    end
    if applied==0 and firstRecord and firstRecord.harmful then
        ui.showMessage("The ingredient's toxicity breaks harmlessly against your practiced constitution.")
    end
end

local function inspectNewItemEffects()
    local current={}
    for _,spell in pairs(types.Actor.activeSpells(self)) do
        local key=spell.activeSpellId or spell.id
        current[key]=true
        if not seenSpells[key] and spell.item then
            if types.Potion.objectIsInstance(spell.item) and rank("A")>0 then
                for _,effect in pairs(spell.effects or {}) do applyReaction(effect,rank("A")) end
            elseif types.Ingredient.objectIsInstance(spell.item) and rank("B")>0 then
                ingredientEffects(spell,rank("B"))
            end
        end
    end
    seenSpells=current
end

local function preserveConsumedPotions()
    local current=countsOf(types.Potion)
    if not inAlchemy and rank("C")>0 then
        local chance=rank("C")==2 and 0.50 or 0.25
        for id,old in pairs(potionSnapshot) do
            for _=1,math.max(0,old-(current[id] or 0)) do
                if math.random()<chance then duplicate(id,1) end
            end
        end
    end
    potionSnapshot=current
end

local function onUiModeChanged(data)
    if data.newMode=="Alchemy" then
        inAlchemy=true
        alchemySession={ingredients=countsOf(types.Ingredient),potions=countsOf(types.Potion)}
    elseif data.oldMode=="Alchemy" then
        inAlchemy=false
        local d=rank("D")
        if d>0 and alchemySession then
            local ingredients=countsOf(types.Ingredient)
            local potions=countsOf(types.Potion)
            for id,now in pairs(potions) do
                local produced=math.max(0,now-(alchemySession.potions[id] or 0))
                local bonus=math.floor(produced*(d==2 and 1 or 0.5))
                duplicate(id,bonus)
            end
            local chance=d==2 and 0.35 or 0.20
            for id,before in pairs(alchemySession.ingredients) do
                for _=1,math.max(0,before-(ingredients[id] or 0)) do
                    if math.random()<chance then duplicate(id,1) end
                end
            end
        end
        alchemySession=nil
        potionSnapshot=countsOf(types.Potion)
    end
end

local function clear()
    seenSpells={}
    alchemySession=nil
    reactionExpiry={}
end

local function onUpdate(dt)
    inspectNewItemEffects()
    timer=timer-dt
    if timer<=0 then timer=0.5 preserveConsumedPotions() end
end

Common.registerMagicPerks("alchemy","Alchemy",ids,{
    A1={localizedName="Alchemical Reaction",localizedFlavour="A draught is not one effect but a conversation, and you have learned to hear the answer.",localizedDescription="Potion effects create related secondary effects at 20% strength.",onRemove=clear},
    A2={localizedName="Catalytic Insight",localizedFlavour="Every tincture carries another possibility waiting for the practiced body to reveal it.",localizedDescription="Alchemical Reaction rises to 30% with stronger minimum effects.",onRemove=clear},
    A3={localizedName="Living Retort",localizedFlavour="Your body completes reactions no glass vessel could survive.",localizedDescription="Alchemical Reaction rises to 40%.",onRemove=clear},
    A4={localizedName="Perfect Transmutation",localizedFlavour="Nothing entering your blood remains only what the brewer intended.",localizedDescription="Alchemical Reaction rises to 50% with the strongest duration floors.",onRemove=clear},
    B1={localizedName="Raw Ingestion",localizedFlavour="Where others taste bitterness, you taste an unfinished formula.",localizedDescription="A successful raw-ingredient use also applies every beneficial effect on that ingredient; harmful results are discarded.",onRemove=clear},
    B2={localizedName="Universal Antidote",localizedFlavour="Even poison is merely medicine facing the wrong direction.",localizedDescription="Raw Ingestion inverts harmful ingredient effects into beneficial counterparts.",onRemove=clear},
    C1={localizedName="Preserved Dose",localizedFlavour="The bottle empties, yet the practiced hand finds one measured draught still waiting.",localizedDescription="Drinking a potion has a 25% chance to replace the consumed dose.",onRemove=clear},
    C2={localizedName="Lasting Vintage",localizedFlavour="A master alchemist can make one perfect measure survive every thirst.",localizedDescription="Preserved Dose chance rises to 50%.",onRemove=clear},
    D1={localizedName="Efficient Preparation",localizedFlavour="Nothing clings to mortar or alembic unless you have decided it may be wasted.",localizedDescription="Brewing produces 50% bonus potions; each consumed ingredient has a 20% preservation chance.",onRemove=clear},
    D2={localizedName="Master's Batch",localizedFlavour="Your laboratory does not multiply ingredients. It multiplies certainty.",localizedDescription="Brewing output doubles; ingredient preservation chance rises to 35%.",onRemove=clear},
})

return {
    eventHandlers={SPerks_UiModeChanged=onUiModeChanged},
    engineHandlers={
        onUpdate=onUpdate,
        onSave=function() return {potionSnapshot=potionSnapshot,reactionExpiry=reactionExpiry} end,
        onLoad=function(data)
            potionSnapshot=(data and data.potionSnapshot) or countsOf(types.Potion)
            reactionExpiry=(data and data.reactionExpiry) or {}
            seenSpells={}
        end,
    },
}
