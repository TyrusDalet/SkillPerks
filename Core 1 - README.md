# SkillPerks Core 1 - Combat

Core 1 adds complete perk trees for the nine Combat skills. Each tree contains
ten perks using the shared A1-A4, B1-B2, C1-C2, and D1-D2 structure.

## Requirements and Load Order

Core 1 requires:

- SkillPerks Core 0.
- ErnPerkFramework - Tyrus Revision/Overhaul.
- Inventory Extender.

Load those dependencies before `Core 1 SkillPerks.omwscripts`.

## Progression

- A chain: skill 25, 50, 75, and 100.
- B chain: skill 50 and 100.
- C and D: mutually exclusive mastery branches reached through A4.
- C2 and D2 require their preceding branch perk and skill 100.

## Perk Catalogue

### Armorer

- **A1 - Practiced Hand:** Once per new day, if no perk-granted repair tool
  remains in your inventory, prepare free Repair Tongs.
- **A2 - Salvage Sense:** The daily tool becomes a Journeyman Repair Hammer;
  failed repairs still restore a small amount to the attempted item.
- **A3 - Careful Craftsman:** The daily tool becomes a Master's Repair Hammer;
  failed repairs no longer consume tool durability.
- **A4 - Master Tinkerer:** The daily tool becomes the Secret Master's Repair
  Hammer; successful repairs can restore spent tool durability after resolution,
  with chance based on tool quality.
- **B1 - Durable Craft:** Carried and equipped gear loses 25% less condition.
- **B2 - Reinforced Craft:** Condition-loss reduction increases to 50%.
- **C1 - Field Maintenance:** Resting indoors distributes a partial repair
  across damaged inventory items.
- **C2 - Traveling Workshop:** Doubles the repair pool and prioritizes equipped
  gear before distributing the remainder.
- **D1 - Over-Repair:** Repaired items can reach 125% condition.
- **D2 - Beyond Perfection:** Repaired items can reach 150% condition.

### Athletics

- **A1 - First Wind:** +5 maximum Fatigue and 1 Fatigue restored every two
  seconds while moving.
- **A2 - Second Breath:** +10 maximum Fatigue and 1 Fatigue per second while
  moving.
- **A3 - Iron Lungs:** +15 maximum Fatigue; moving regeneration scales from
  1 to 3 per second as Fatigue falls.
- **A4 - Boundless Stamina:** +25 maximum Fatigue; moving regeneration scales
  up to 5 per second at critically low Fatigue.
- **B1 - Road-Hardened:** Feather offsets 25% of carried weight above half
  capacity.
- **B2 - Seasoned Traveller:** The threshold falls to one-quarter capacity and
  Feather offsets 33% of excess weight.
- **C1 - Swift Traveller:** Free carry capacity grants scaling Speed.
- **C2 - Fleet of Foot:** Also grants scaling swim speed, capped at 50.
- **D1 - Momentum:** Three seconds of continuous movement begins building up
  to three +10 Speed stacks; stopping for three seconds clears them.
- **D2 - Second Wind:** Raises the stack cap to five, grants +25 Agility at
  maximum stacks, and fully restores critically low Fatigue once per rest.

### Axe

- **A1 - Sundering Edge:** Charged Axe hits damage struck armor condition by
  50% of weapon damage, scaled by charge.
- **A2 - Riving Edge:** Armor condition damage rises to 75%.
- **A3 - Cleaving Edge:** Armor condition damage rises to 100%.
- **A4 - Ruinous Edge:** Armor condition damage rises to 150%.
- **B1 - Terror of the Fallen:** Axe kills can Demoralize actors within ten
  meters; chance scales with the victim's pre-hit Health percentage.
- **B2 - Panic Harvest:** Demoralize magnitude rises from 20 to 50.
- **C1 - Berserk Breakpoint:** Once per day, falling below 25% Health triggers
  ten seconds of Orc Berserk.
- **C2 - Controlled Frenzy:** Orc Berserk no longer drains Agility.
- **D1 - Broken Plate:** Damaged armor provides proportionally less protection
  against Axe damage.
- **D2 - No Shelter:** Axe hits on unarmored locations ignore that location's
  Unarmored protection.

### Block

- **A1 - Iron Guard:** Successful blocks reduce condition damage to the
  blocking item by 5%.
- **A2 - Steady Grip:** Reduction increases to 10%.
- **A3 - Unyielding Guard:** Reduction increases to 25%.
- **A4 - Immaculate Defense:** Reduction increases to 50%.
- **B1 - Punishing Guard:** Blocks damage the attacker's weapon by Block / 5;
  unarmed attackers and creatures take the amount as direct Health damage.
- **B2 - Crushing Riposte:** Doubles the attacker's Fatigue cost for a blocked
  attack.
- **C1 - Loaded Guard:** Stores the first harmful self-cast spell, then fires
  it at the next blocked attacker for its full Magicka cost; 30-second cooldown.
- **C2 - Primed Retaliation:** Stored-spell cost falls by 25% and cooldown falls
  to 20 seconds.
- **D1 - Spell Guard:** Rolls block chance against harmful spells and negates
  them on success; N'Garde perfect parries automatically succeed.
- **D2 - Returned Malice:** Successful spell blocks also reflect the spell,
  with a ten-second reflection cooldown.

### Blunt Weapon

- **A1 - Heavy Impact:** Charged attacks deal 5 bonus Fatigue damage.
- **A2 - Staggering Impact:** Bonus rises to 10.
- **A3 - Bone-Shaking Impact:** Bonus rises to 15.
- **A4 - Earthbreaker:** Bonus rises to 20.
- **B1 - Exploitation:** Targets below 33% Fatigue take bonus Health damage
  equal to Blunt Weapon / 10.
- **B2 - Merciless Exploitation:** Threshold rises to 50% and damage improves
  to Blunt Weapon / 5.
- **C1 - Crushing Force:** Charged attacks add 25% armor-penetrating damage;
  fully blocked charged attacks still pass 10% of impact.
- **C2 - Shattering Force:** Armor penetration rises to 50% and block
  penetration to 25%.
- **D1 - Relentless Assault:** Hits add timed Blind, Sound, and Burden stacks,
  up to five.
- **D2 - Final Collapse:** Cap rises to ten; reaching ten consumes the stacks
  and paralyses the target for ten seconds without a resistance roll.

### Heavy Armor

- **A1 - Broad Shoulders:** Feather equals 10% of equipped Heavy Armor weight.
- **A2 - Load-Bearing Frame:** Feather rises to 20%.
- **A3 - Battle-Forged Back:** Feather rises to 30%.
- **A4 - Immovable:** Feather rises to 40%.
- **B1 - Iron Constitution:** Wearing at least three Heavy Armor pieces grants
  Fatigue scaling with the number worn.
- **B2 - Battle Rhythm:** Weapon swings and jumps refund part of their Fatigue
  cost.
- **C1 - Tempered Flesh:** +10% Resist Normal Weapons.
- **C2 - Ironclad:** Each Heavy Armor piece adds about 2% more resistance, up
  to an additional 20%.
- **D1 - Elemental Fortress:** A full racial-compatible Heavy Armor set grants
  Fire, Frost, and Shock resistance scaling with armor rating, capped at 30%.
- **D2 - Elemental Bulwark:** Replaces the resistance with matching elemental
  Shield effects capped at 45.

Beast races are not required to wear boots for full-set checks.

### Long Blade

- **A1 - Measured Advance:** Charged Long Blade hits build up to three Momentum
  stacks; each grants +5% weapon damage and expires after eight seconds without
  a landed attack.
- **A2 - Poised Guard:** Momentum grants +10 Agility after four seconds without
  being damaged; taking damage clears Poise and Momentum.
- **A3 - Driving Tempo:** Momentum cap rises to eight.
- **A4 - Unbroken Line:** Poise grants +20 Agility; damage removes three stacks
  and only removes Poise if no stacks remain.
- **B1 - Opening Cut:** At maximum Momentum, attacks have a 10% critical chance.
- **B2 - Killing Measure:** A qualifying hit at maximum Momentum spends half
  the stacks and opens a 15-second window with 20% critical chance.
- **C1 - Transferable Form:** Other weapons can build one Momentum stack and
  +5 Agility Poise.
- **C2 - Master's Geometry:** Other-weapon cap rises to four and Poise to
  +10 Agility.
- **D1 - Riposte:** While Poised, being hit can trigger an automatic fully
  charged Long Blade counterattack and grant one Momentum; three-second cooldown.
- **D2 - Answer in Blood:** A lethal Riposte grants three Momentum.

### Medium Armor

- **A1 - Tempered Guard:** Mostly Medium Armor grants its pieces +5% armor
  rating until disabled for eight seconds by a received hit.
- **A2 - Honed Reflexes:** Bonus rises to 10%.
- **A3 - Practiced Deflection:** Bonus rises to 15%.
- **A4 - Master's Guard:** Bonus rises to 20% and cooldown falls to six seconds.
- **B1 - Reactive Guard:** Gain +20 Sanctuary while the armor bonus is cooling
  down.
- **B2 - Read the Opening:** Sanctuary rises to +35; incoming misses shorten
  the cooldown.
- **C1 - Efficient Absorption:** Extends half of the armor bonus to all worn
  armor and reduces durability damage from the triggering hit by 50%.
- **C2 - Total Coverage:** Extension rises to 75% and durability reduction to
  75%.
- **D1 - Second Skin:** The first cooldown hit restores 10% maximum Health and
  Fatigue.
- **D2 - Living Armor:** Restoration can trigger twice and cooldown extensions
  from further hits are reduced.

### Spear

- **A1 - Pinning Point:** Charged Spear hits apply Drain Agility 3 for five
  seconds.
- **A2 - Narrowing Point:** Magnitude rises to 5.
- **A3 - Hobbling Point:** Magnitude rises to 8 and stacks three times.
- **A4 - Impaling Point:** Magnitude rises to 10 and stacks five times.
- **B1 - Exploit Weakness:** Charged Spear hits gain charge-scaled damage for
  each negative attribute effect on the target.
- **B2 - Pinned Nerve:** Three negative attribute effects allow charged hits
  to attempt a one-second Paralyze.
- **C1 - Driving Thrust:** Thrusts with any weapon gain the weakness-based
  bonus; Spear thrusts can receive both bonuses.
- **C2 - Opening Wound:** All weapon thrusts apply Damage Agility 1 for two
  seconds.
- **D1 - Hamstringing Point:** Charged Spear hits apply independently stacking
  Drain Speed 25 for five seconds, up to three stacks.
- **D2 - Severing Point:** Each new Drain Speed stack also applies Damage Speed
  5 for two seconds.

## Detailed Perk Rules

### Armor Set Scoring

“Mostly” armor checks use weighted equipment slots rather than a raw item
count. Cuirasses are worth 3 points; greaves are worth 2 points for Light
Armor or 3 for Medium and Heavy Armor; shields are worth 2; helmets are worth
1 for Light Armor or 2 for Medium and Heavy Armor; each pauldron, gauntlet,
and boot is worth 1. Mostly Medium or Heavy Armor requires 8 matching points.

Heavy Armor's full-set perks require a Heavy cuirass, greaves, both pauldrons,
and both gauntlets, plus Heavy boots for races able to wear them. Helmets and
shields are not required.

### Armorer Details

- The four perk tools form one shared supply. A new tool is prepared only when
  a new in-game day begins and none of the perk-granted tools remains in the
  inventory. Loading, reloading Lua, changing cells, and merely acquiring a
  perk do not prepare one. The highest owned A perk determines the next tool.
- Perk-granted tools cost nothing and cannot intentionally be sold, dropped,
  or stored.
- Salvage Sense restores 5 condition to the actual item targeted by a failed
  repair.
- Careful Craftsman returns the durability consumed by a failed repair.
- Master Tinkerer returns durability consumed by a successful repair on a
  quality-based roll. The chance is 10% at tool quality 0.5, follows a smooth
  curve between 0.5 and 2.0, and reaches 75% at quality 2.0 or higher.
- Durable Craft and Reinforced Craft cover weapons, armor, repair tools,
  lockpicks, and probes in the player's inventory. They refund 25% or 50% of
  observed condition loss.
- Field Maintenance's total repair is based on modified Armorer. Each damaged
  item receives `Armorer / number of damaged items`; Traveling Workshop doubles
  that amount and redirects unused equipped-item repair to unequipped gear.
- Over-Repair affects weapons and armor only. Its extra condition improves
  their normal condition-based performance and is subsequently worn away by
  ordinary use and damage.

### Athletics Details

- Iron Lungs and Boundless Stamina regenerate 1 Fatigue per second at full
  Fatigue and scale upward as Fatigue falls. They reach their 3 or 5
  points-per-second maximum at 20% Fatigue and remain at that rate below 20%.
- Road-Hardened grants Feather equal to 25% of carried weight above 50% of
  capacity. Seasoned Traveller grants 33% of carried weight above 25% of
  capacity.
- Swift Traveller grants `base Speed x unused carry-capacity percentage`,
  rounded down. Fleet of Foot grants the same amount as Swift Swim, capped at
  50.
- Athletics Momentum adds one stack for every three continuous seconds of
  movement. All stacks clear after three seconds without movement.
- Second Wind triggers below 20% Fatigue, restores Fatigue to maximum, and
  becomes available again after completing a rest.

### Axe Details

- A charged Axe hit uses a 95% charge threshold. Its extra armor damage is
  `fully calculated weapon damage x charge ratio x the current A-chain
  percentage`. An unarmored hit location spreads that condition damage across
  currently equipped armor.
- Terror of the Fallen's chance is `20% + the victim's Health percentage
  immediately before the killing blow`, capped at 100%. It affects every
  nearby actor other than the slain victim, including allies.
- Berserk Breakpoint grants Fortify Health 20, Fortify Fatigue 200, Fortify
  Attack 100, and Drain Agility 100 for ten seconds. Controlled Frenzy removes
  only the Agility penalty. The daily use resets when the in-game day changes.
- Broken Plate scales each struck armor piece's effective protection by its
  current-condition percentage. No Shelter removes the normal Unarmored armor
  contribution when the Axe strikes an unarmored location.

### Block Details

- Block item preservation applies to the item actually used to block or parry.
  N'Garde's right-hand, shield, and two-handed parry choices are respected.
- Punishing Guard deals `modified Block / 5` condition damage to the
  attacker's weapon. Creatures and unarmed attackers instead take that amount
  as direct Health damage, bypassing armor and normal weapon resistance.
- Loaded Guard captures only a spell whose effects are all harmful and
  self-targeted. The original cast is negated. The captured spell remains
  stored until the perk is lost or respecced and is not consumed when fired.
- Firing Loaded Guard requires enough Magicka. C1 pays the spell's full cost
  and has a 30-second cooldown; C2 pays 75% and has a 20-second cooldown.
- Spell Guard uses the normal Block chance against newly applied harmful
  spells. A successful roll removes the spell. Returned Malice may reflect the
  same spell once every ten seconds; spell negation continues during that
  reflection cooldown. N'Garde perfect parries automatically pass the roll.

### Blunt Weapon Details

- “Charged” means at least 95% charge. Heavy Impact's Fatigue damage and
  Crushing Force's penetration are additional to the ordinary hit.
- Exploitation checks the target's Fatigue percentage before applying its
  direct Health damage.
- Crushing Force uses the strike's estimated pre-armor damage. Its additional
  25% or 50% component is not reduced by armor. A fully blocked charged attack
  still passes 10% or 25% of its calculated impact.
- Every Relentless Assault stack applies 5 Blind, 5 Sound, and 5 Burden.
  New hits refresh the shared eight-second duration. Final Collapse consumes
  all ten stacks to apply ten seconds of irresistible Paralysis.

### Heavy Armor Details

- Iron Constitution requires at least three Heavy Armor pieces and grants
  +5 maximum Fatigue per Heavy piece.
- Battle Rhythm returns 30% of the Fatigue actually spent by each weapon swing
  and jump. It retains Iron Constitution's existing Fatigue pool.
- Ironclad retains Tempered Flesh's flat 10% Resist Normal Weapons and adds 2%
  for every worn Heavy Armor piece, up to 20% additional resistance.
- Elemental Fortress and Elemental Bulwark use the player's effective armor
  rating with vanilla hit-location weights, divided by 10. D1 applies the
  resulting value as Fire, Frost, and Shock resistance up to 30 each. D2
  replaces those resistances with matching elemental Shields up to 45 each.

### Long Blade Details

- A charged attack requires at least 95% charge. A non-charged attack may also
  build Momentum when that attack becomes a Long Blade critical hit.
- Momentum multiplies weapon damage by 5% per stack. Long Blade criticals use
  the normal four-times melee critical multiplier after Momentum's multiplier.
- Each charged or critical hit that adds Momentum refreshes its eight-second
  expiry.
- Killing Measure spends half of the current stacks, rounded up, when it opens
  its 15-second critical window. It cannot open another window while one is
  active.
- Transferable Form and Master's Geometry use a separate “other weapon”
  Momentum profile. Changing between Long Blade and another weapon clears the
  old profile's stacks; changing weapons within the same profile preserves
  them.
- Riposte uses the player's Long Blade hit chance against the attacker's
  evasion, performs a fully charged strike, and can use the same B-chain
  critical pathway as an ordinary Long Blade attack. Riposte takes priority
  over FactionPerks counterattacks when both are ready.

### Medium Armor Details

- Tempered Guard's bonus uses each piece's actual weighted armor contribution.
  A hit disables it for eight seconds, or six at A4. Further hits add two
  seconds, capped at twelve total.
- Read the Opening removes one second when an attack misses during cooldown,
  but cannot reduce the remaining cooldown below two seconds.
- Efficient Absorption and Total Coverage keep the full A-chain percentage on
  Medium pieces when the Mostly Medium threshold is met. Their 50% or 75%
  extension applies to other armor; without Mostly Medium Armor it applies to
  every worn piece instead.
- Their durability protection applies only to the hit that begins the
  cooldown. Second Skin and Living Armor restore 10% of maximum Health and
  Fatigue on the first one or two eligible hits within that same cooldown.
- Living Armor reduces additional-hit cooldown extensions from two seconds to
  one second.

### Spear Details

- Spear charged-hit effects require at least 95% charge. A-chain Drain Agility
  stacks share one five-second timer; D-chain Drain Speed stacks each keep
  their own five-second timer.
- Exploit Weakness counts separate negative attribute-effect instances. Each
  contributes `3 + 2 x charge ratio` bonus Health damage, with no count cap.
- Pinned Nerve requires at least three negative attribute effects and applies
  one second of Paralysis subject to the target's resistance.
- Driving Thrust applies the same per-effect bonus to thrusts with any weapon.
  A Spear thrust qualifies for both the B- and C-chain bonuses.
- Opening Wound deals 1 Damage Agility per second for two seconds. Each new
  Severing Point stack deals 5 Damage Speed per second for two seconds.

## Console Commands

Enter these directly into the normal OpenMW console:

- `luaathletics debug` - prints Athletics movement, Fatigue regeneration,
  Momentum, encumbrance, and active rank state.
- `luaath debug` - shorter alias for `luaathletics debug`.
- `lualb debug` - prints Long Blade Momentum, cap, weapon classification,
  timers, ranks, and the last attack recognized by the perk.

The shared `luaperks menu`, `luaperks respec`, and `luaperks dump` commands are
documented in Core 0.

## HUD and Constellations

Long Blade Momentum has an optional Morrowind-style HUD configured on the
SkillPerks settings page. Its controls appear only while Core 1 is installed.

The optional constellation menu places these nine skills in the Combat nebula.
Core 1 supplies authored normal/completed textures and node positions. Internal
routes are drawn into the artwork, while cross-constellation requirements remain
available to the Framework. Completing every compatible node swaps the subdued
symbol for its blue-white completed version.

## Optional Compatibility

N'Garde is optional. If installed, relevant Block perks recognize its parries
and perfect parries.
