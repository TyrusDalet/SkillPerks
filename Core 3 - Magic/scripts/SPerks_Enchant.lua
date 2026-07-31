--[[
SkillPerks for OpenMW.
Copyright (C) 2026 Robbie Barker

Enchant catalogues effect/trigger pairs, preserves scrolls, and reports
Enchanter's Circuit through the framework's shared magnitude calculations.
]]

local core=require("openmw.core")
local interfaces=require("openmw.interfaces")
local types=require("openmw.types")
local self=require("openmw.self")

local Common=require("scripts.SkillPerks.magic.common")
local MagicDetection=require("scripts.SkillPerks.shared.magic_detection")
local StatTracker=require("scripts.SkillPerks.shared.stat_tracker")
local SkillDebug=require("scripts.SkillPerks.shared.debug")

local ids=Common.ids("enchant")
local effects=StatTracker.newActiveEffectTracker(self)
local catalogue={CastOnUse={},CastOnStrike={},ConstantEffect={}}
local stacks={}
local reserve=0
local reserveTimer=0
local rechargeBefore=nil
local serviceGold=nil
local selfEnchanting=false
local timer=0

local function rank(chain) return Common.rank(ids,chain) end
local function itemKey(item) return item and tostring(item) or nil end
local function totalCatalogue()
    local count=0
    for _,bucket in pairs(catalogue) do for _ in pairs(bucket) do count=count+1 end end
    return count
end
local function catalogueItem(trigger,item)
    local trace=SkillDebug.beginTrace("enchant","Enchanter's Codex","enchanted item observed",{
        item=SkillDebug.objectId(item),trigger=trigger,
    })
    if rank("A")==0 then return trace:reject("A chain inactive") end
    if not item or not item:isValid() then return trace:reject("item unavailable") end
    local enchantment=MagicDetection.getEnchantmentRecord(item)
    if not enchantment then return trace:reject("item has no enchantment record") end
    local before=totalCatalogue()
    for _,effect in ipairs(enchantment.effects or {}) do
        local existed=catalogue[trigger][effect.id] == true
        catalogue[trigger][effect.id]=true
        trace:step("effect catalogued",{effect=effect.id,existing=existed,trigger=trigger})
    end
    trace:finish("catalogue reconciled",{added=totalCatalogue()-before,total=totalCatalogue()})
end

local function chargedItems()
    local result={}
    for _,item in ipairs(types.Actor.inventory(self):getAll()) do
        local maximum=MagicDetection.getMaxChargeOf(item)
        local data=maximum and types.Item.itemData(item)
        if data and data.enchantmentCharge~=nil then
            table.insert(result,{item=item,key=itemKey(item),current=data.enchantmentCharge,maximum=maximum})
        end
    end
    return result
end
local function chargeSnapshot()
    local result={}
    for _,entry in ipairs(chargedItems()) do result[entry.key]=entry.current end
    return result
end

local function grantCircuit(item)
    local d=rank("D")
    local trace=SkillDebug.beginTrace("enchant","Enchanter's Circuit","enchanted item activated",{
        dRank=d,item=SkillDebug.objectId(item),
    })
    if d==0 then return trace:reject("D chain inactive") end
    if not item or not item:isValid() then return trace:reject("item unavailable") end
    local key=itemKey(item)
    local now=core.getSimulationTime()
    if stacks[key] then
        stacks[key]=now+15
        return trace:finish("existing stack refreshed",{expiresAt=stacks[key],key=key})
    end
    local count=0
    for _,expiry in pairs(stacks) do if expiry>now then count=count+1 end end
    local cap=d==2 and 5 or 3
    if count < cap then
        stacks[key]=now+15
        return trace:finish("new stack granted",{activeBefore=count,cap=cap,expiresAt=stacks[key]})
    end
    trace:reject("stack cap reached",{active=count,cap=cap})
end
local function activeCircuitStacks()
    local now,count=core.getSimulationTime(),0
    for key,expiry in pairs(stacks) do
        if expiry>now then count=count+1 else stacks[key]=nil end
    end
    return count
end

interfaces.ErnPerkFramework.registerSkillUseHandler({
    id="SkillPerks_enchant_uses",skill="enchant",
    handler=function(event)
        local use=Common.skillUseType(event)
        local useItem=Common.useType("Enchant_UseMagicItem")
        local strike=Common.useType("Enchant_CastOnStrike")
        local recharge=Common.useType("Enchant_Recharge")
        local item=event.enchantedItem or event.params and event.params.item
            or types.Actor.getSelectedEnchantedItem(self)
        local trace=SkillDebug.beginTrace("enchant","Enchanted item use","Enchant skill-use event",{
            item=SkillDebug.objectId(item),useType=use,
        })
        if use==useItem then
            catalogueItem("CastOnUse",item)
            grantCircuit(item)
            trace:finish("Cast on Use processed")
        elseif use==strike then
            catalogueItem("CastOnStrike",item)
            if rank("D")>=2 then grantCircuit(item) end
            trace:finish("Cast on Strike processed",{closedCircuit=rank("D")>=2})
        elseif use==recharge and rank("B")>0 then
            -- Exact soul fields differ across OpenMW/Inventory Extender
            -- versions. The UI charge diff below remains authoritative.
            rechargeBefore=rechargeBefore or chargeSnapshot()
            trace:finish("recharge snapshot captured",{items=SkillDebug.count(rechargeBefore)})
        else
            trace:reject("skill-use type has no active perk route",{
                bRank=rank("B"),dRank=rank("D"),
            })
        end
    end,
})

MagicDetection.newScrollCastTracker(self,function(recordId)
    local c=rank("C")
    local chance=c==2 and 0.50 or 0.25
    local roll=math.random()
    local trace=SkillDebug.beginTrace("enchant","Preserved Scroll","scroll cast completed",{
        cRank=c,chance=chance,recordId=recordId,roll=roll,
    })
    if c<=0 then return trace:reject("C chain inactive") end
    if roll<chance then
        core.sendGlobalEvent("SPerks_DuplicateItem",{
            target=self,recordId=recordId,count=1,reselectAsActive=true,
        })
        trace:finish("replacement scroll queued")
    else
        trace:reject("preservation roll failed")
    end
end)

local function goldCount() return types.Actor.inventory(self):countOf("gold_001") end
local function onUiModeChanged(data)
    local trace=SkillDebug.beginTrace("enchant","Enchant UI","UI mode changed",{
        newMode = data and data.newMode,
        oldMode = data and data.oldMode,
    })
    if data.newMode=="Enchanting" then
        selfEnchanting=data.arg==nil
        if data.arg~=nil then serviceGold=goldCount() end
        trace:finish("enchanting session opened",{
            selfEnchanting=selfEnchanting,serviceGold=serviceGold,
        })
    elseif data.oldMode=="Enchanting" then
        if serviceGold and rank("A")>0 then
            local spent=math.max(0,serviceGold-goldCount())
            local percent=math.floor(totalCatalogue()/5)*(rank("A")>=4 and 0.02 or 0.01)
            if spent>0 and percent>0 then
                local refund=math.floor(spent*percent)
                core.sendGlobalEvent("SPerks_DuplicateItem",{
                    target=self,recordId="gold_001",count=refund,
                })
                trace:step("service refund queued",{percent=percent,refund=refund,spent=spent})
            else
                trace:step("service refund skipped",{percent=percent,spent=spent})
            end
        end
        serviceGold=nil
        selfEnchanting=false
        effects.apply("fortifyskill","enchant",0)
        trace:finish("enchanting session closed")
    elseif data.newMode=="Recharge" then
        rechargeBefore=chargeSnapshot()
        trace:finish("recharge snapshot captured",{items=SkillDebug.count(rechargeBefore)})
    elseif data.oldMode=="Recharge" and rechargeBefore and rank("B")>0 then
        local now=chargeSnapshot()
        local added=0
        for key,current in pairs(now) do added=added+math.max(0,current-(rechargeBefore[key] or current)) end
        local gained=math.floor(added*(rank("B")==2 and 1 or 0.5))
        reserve=reserve+gained
        rechargeBefore=nil
        trace:finish("recharge reserve calculated",{chargeAdded=added,reserveGained=gained,reserveTotal=reserve})
    else
        trace:reject("mode change has no Enchant route")
    end
end

local function catalogueConstantEffects()
    local ce=core.magic.ENCHANTMENT_TYPE.ConstantEffect
    for _,item in pairs(types.Actor.getEquipment(self)) do
        local enchantment=MagicDetection.getEnchantmentRecord(item)
        if enchantment and enchantment.type==ce then catalogueItem("ConstantEffect",item) end
    end
end

-- Item-origin active spells retain the physical source item. Reapplying the
-- resolved effects through a fresh dynamic spell gives A3/A4 a literal free
-- echo while preventing recursion: the generated spell has no source item.
local function onMagicEffectLanded(data)
    local trace=SkillDebug.beginTrace("enchant","Echoed Activation","landed magic-effect event",{
        item = data and SkillDebug.objectId(data.item),
        spell = data and data.spellId,
        target = data and SkillDebug.objectId(data.target),
    })
    local a=rank("A")
    if a<3 then return trace:reject("A3 is not owned",{aRank=a}) end
    if not data or not data.item then return trace:reject("effect has no source item") end
    if not data.target or not data.target:isValid() then return trace:reject("target unavailable") end
    local enchantment=MagicDetection.getEnchantmentRecord(data.item)
    if not enchantment or enchantment.type~=core.magic.ENCHANTMENT_TYPE.CastOnUse then
        return trace:reject("source is not a Cast on Use enchantment")
    end
    catalogueItem("CastOnUse",data.item)
    grantCircuit(data.item)
    local chance=math.floor(totalCatalogue()/25)*(a>=4 and 0.02 or 0.01)
    local roll=math.random()
    trace:step("echo chance resolved",{catalogue=totalCatalogue(),chance=chance,roll=roll})
    if chance<=0 then return trace:reject("catalogue grants no echo chance") end
    if roll>=chance then return trace:reject("echo roll failed") end
    local echoed={}
    for _,effect in ipairs(data.effects or {}) do
        table.insert(echoed,{
            id=effect.id,magnitudeMin=tonumber(effect.magnitude) or Common.averageMagnitude(effect),
            duration=math.max(1,tonumber(effect.duration) or 1),
            affectedAttribute=effect.affectedAttribute,affectedSkill=effect.affectedSkill,
        })
    end
    Common.applyDynamicSpell(data.target,self,"Echoed Enchantment",echoed)
    trace:finish("echo spell queued",{effects=#echoed})
end

local function distributeReserve()
    local trace=SkillDebug.beginTrace("enchant","Charge Reserve","distribution tick",{reserve=reserve})
    if reserve<1 then return trace:reject("reserve below one charge") end
    local list=chargedItems()
    table.sort(list,function(a,b)
        local ar=types.Actor.getEquipment(self,types.Actor.EQUIPMENT_SLOT.CarriedRight)
        local selected=types.Actor.getSelectedEnchantedItem(self)
        local function tier(item)
            if item==ar then return 1 elseif item==selected then return 2 end
            for _,equipped in pairs(types.Actor.getEquipment(self)) do if item==equipped then return 3 end end
            return 4
        end
        local ta,tb=tier(a.item),tier(b.item)
        return ta==tb and a.current<b.current or ta<tb
    end)
    for _,entry in ipairs(list) do
        if reserve<1 then break end
        local missing=math.max(0,entry.maximum-entry.current)
        if missing>0 then
            local add=math.min(1,missing,reserve)
            types.Item.itemData(entry.item).enchantmentCharge=entry.current+add
            reserve=reserve-add
            trace:step("charge restored",{
                amount=add,item=SkillDebug.objectId(entry.item),
                newCharge=entry.current+add,reserveRemaining=reserve,
            })
        end
    end
    trace:finish("distribution complete",{reserveRemaining=reserve})
end

for _,calculation in ipairs({
    interfaces.ErnPerkFramework.CALCULATION.ENCHANT_CAST_ON_USE_SELF_EFFECT_MAGNITUDE,
    interfaces.ErnPerkFramework.CALCULATION.ENCHANT_CONSTANT_EFFECT_SELF_EFFECT_MAGNITUDE,
}) do
    interfaces.ErnPerkFramework.registerCalculationHandler({
        id="SkillPerks_enchanters_circuit_"..calculation,
        calculation=calculation,
        operation=interfaces.ErnPerkFramework.CALCULATION_OPERATION.Multiplier,
        priority=700,
        handler=function()
            local count=activeCircuitStacks()
            local multiplier=count>0 and 1+count*0.10 or nil
            local trace=SkillDebug.beginTrace("enchant","Enchanter's Circuit","magnitude calculation",{
                activeStacks=count,calculation=calculation,
            })
            if not multiplier then
                trace:reject("no active circuit stacks")
                return nil
            end
            trace:finish("multiplier returned",{multiplier=multiplier})
            return multiplier
        end,
    })
end

local function refresh()
    catalogueConstantEffects()
    local a=rank("A")
    local bonus=selfEnchanting and a>=2 and totalCatalogue()*(a>=4 and 2 or 1) or 0
    effects.apply("fortifyskill","enchant",bonus)
    SkillDebug.traceState("enchant","Living Catalogue","passive",{
        aRank=a,bonus=bonus,selfEnchanting=selfEnchanting,totalCatalogue=totalCatalogue(),
    })
end
local function clear()
    effects.clearAll()
    stacks={}
    selfEnchanting=false
end
local function onUpdate(dt)
    timer=timer-dt
    if timer<=0 then timer=0.5 refresh() end
    if reserve>0 and rank("B")>0 then
        reserveTimer=reserveTimer-dt
        if reserveTimer<=0 then
            reserveTimer=rank("B")==2 and 5.5 or 11
            distributeReserve()
        end
    end
end

-- Reports catalogue growth, circuit stacks, charge reserve, and Enchant UI state.
local onConsoleCommand = SkillDebug.makeHandler({
    name = "Enchant",
    skillId = "enchant",
    actor = self,
    ids = ids,
    commands = { "luaenchant debug" },
    snapshot = function()
        return {
            string.format(
                "Catalogue: use=%d strike=%d constant=%d",
                SkillDebug.count(catalogue.CastOnUse),
                SkillDebug.count(catalogue.CastOnStrike),
                SkillDebug.count(catalogue.ConstantEffect)
            ),
            string.format(
                "Circuit: stacks=%d reserve=%s timer=%s rechargeBefore=%s",
                SkillDebug.count(stacks),
                SkillDebug.number(reserve),
                SkillDebug.number(reserveTimer),
                SkillDebug.value(rechargeBefore)
            ),
            string.format("Enchanting: active=%s serviceGold=%s", tostring(selfEnchanting), SkillDebug.value(serviceGold)),
        }
    end,
})

Common.registerMagicPerks("enchant","Enchant",ids,{
    A1={localizedName="Enchanter's Codex",localizedFlavour="Every awakened effect writes one more line into a catalogue no mortal library could contain.",localizedDescription="Catalogue unique effect/trigger pairs. Every 5 stacks refunds 1% of NPC enchanting costs.",onAdd=refresh,onRemove=clear},
    A2={localizedName="Living Catalogue",localizedFlavour="The Codex opens inside your hands while you bind a new enchantment.",localizedDescription="While self-enchanting, each catalogue stack grants +1 Enchant.",onAdd=refresh,onRemove=clear},
    A3={localizedName="Echoed Activation",localizedFlavour="Some enchantments remember being awakened and answer twice.",localizedDescription="Every 25 catalogue stacks grants a 1% chance for Cast on Use effects to echo.",onRemove=clear},
    A4={localizedName="Grand Codex",localizedFlavour="Your catalogue is no record of enchantment. It is the grammar by which enchanted things obey.",localizedDescription="Doubles Codex refund, self-enchanting skill, and activation-echo rates.",onAdd=refresh,onRemove=clear},
    B1={localizedName="Charge Reserve",localizedFlavour="No soul is spent so neatly that a master cannot catch what spills beyond the vessel.",localizedDescription="Half of detected recharge excess enters a reserve that restores 1 charge to deficient items every 11 seconds.",onRemove=clear},
    B2={localizedName="Perfect Reclamation",localizedFlavour="Not one spark escapes your circuit without being given another task.",localizedDescription="All detected excess enters the reserve; distribution occurs every 5.5 seconds.",onRemove=clear},
    C1={localizedName="Preserved Scroll",localizedFlavour="The words burn away, but sometimes their meaning leaves a second page behind.",localizedDescription="Used scrolls have a 25% chance to be replaced and re-selected.",onRemove=clear},
    C2={localizedName="Indelible Formula",localizedFlavour="A true formula survives even the fire that consumes its parchment.",localizedDescription="Preserved Scroll chance rises to 50%.",onRemove=clear},
    D1={localizedName="Enchanter's Circuit",localizedFlavour="Each awakened item joins a circuit of power humming through everything you wear.",localizedDescription="Cast on Use items grant a 15-second stack, up to 3; each adds 10% to equipped Constant Effect magnitude.",onRemove=clear},
    D2={localizedName="Closed Circuit",localizedFlavour="Weapon, ring, and amulet answer as one instrument beneath your hand.",localizedDescription="Cast on Strike also grants stacks and the cap rises to 5.",onRemove=clear},
})

return {
    eventHandlers={
        SPerks_UiModeChanged=onUiModeChanged,
        SPerks_MagicEffectLanded=onMagicEffectLanded,
    },
    engineHandlers={
        onConsoleCommand=onConsoleCommand,
        onUpdate=onUpdate,
        onSave=function() return {catalogue=catalogue,stacks=stacks,reserve=reserve,effects=effects.snapshot()} end,
        onLoad=function(data)
            catalogue=(data and data.catalogue) or catalogue
            stacks=(data and data.stacks) or {}
            reserve=(data and data.reserve) or 0
            effects.restoreAndReverse(data and data.effects)
        end,
    },
}
