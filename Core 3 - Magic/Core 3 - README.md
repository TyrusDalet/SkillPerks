# SkillPerks Core 3 - Magic

Core 3 adds complete perk trees for the eight Magic skills and Unarmored. Each
tree contains ten perks using the shared A1-A4, B1-B2, C1-C2, and D1-D2
structure.

## Requirements and Load Order

Core 3 requires:

- SkillPerks Core 0.
- ErnPerkFramework - Tyrus Revision/Overhaul.
- Inventory Extender.

Load those dependencies before `Core 3 SkillPerks.omwscripts`.

Spell Framework Plus is supported but remains optional. It provides improved
Spellforge lifecycle information when installed.

## Progression

- A chain: skill 25, 50, 75, and 100.
- B chain: skill 50 and 100.
- C and D: mutually exclusive mastery branches reached through A4.
- C2 and D2 require their preceding branch perk and skill 100.

## Perk Catalogue

### Alchemy

- **A1 - Alchemical Reaction:** Drinking a potion causes each eligible potion
  effect to create a related secondary effect. Restore and Fortify reactions
  use 20% of the source effect, resistance reactions use 15% with a minimum
  magnitude of 5, and secondary effects last at least 10 seconds. Cure effects
  grant 25 points of the corresponding resistance for 15 minutes.
- **A2 - Catalytic Insight:** Restore and Fortify reactions rise to 30%.
  Resistance reactions rise to 25% with a minimum magnitude of 10, minimum
  secondary duration rises to 15 seconds, and Cure resistances last 30 minutes.
- **A3 - Living Retort:** Restore and Fortify reactions rise to 40%.
  Resistance reactions rise to 35% with a minimum magnitude of 15, minimum
  secondary duration rises to 20 seconds, and Cure resistances last 45 minutes.
- **A4 - Perfect Transmutation:** Restore and Fortify reactions rise to 50%.
  Resistance reactions rise to 50% with a minimum magnitude of 20, minimum
  secondary duration rises to 30 seconds, and Cure resistances last 60 minutes.
- **B1 - Raw Ingestion:** Successful raw-ingredient use also applies every
  beneficial effect listed on that ingredient, using the successful first
  effect's magnitude and duration as their basis. Harmful effects are removed;
  an entirely harmful ingredient causes no harm.
- **B2 - Universal Antidote:** Harmful ingredient effects are inverted into
  beneficial counterparts instead of merely being discarded.
- **C1 - Preserved Dose:** Drinking a potion has a 25% chance to replace it.
- **C2 - Lasting Vintage:** Replacement chance rises to 50%.
- **D1 - Efficient Preparation:** Brewing produces 50% bonus potions; every
  consumed ingredient has an independent 20% preservation chance.
- **D2 - Master's Batch:** Brewing output doubles; every consumed ingredient
  has an independent 35% preservation chance.

Whole bonus potions and successful ingredient refunds are returned after the
Alchemy window closes. A message reports the number of extra potions and lists
the names and quantities of all refunded ingredients.

#### Alchemical Reaction Details

Alchemical Reaction only responds to potion effects. Each reaction keeps the
source potion's duration when it is longer than the perk's minimum duration.
The same resulting effect cannot stack, refresh, or replace itself while its
current reaction is still active.

- Restore Health, Magicka, or Fatigue creates Fortify Health, Magicka, or
  Fatigue. Its magnitude is the source magnitude multiplied by its natural
  duration and the current A-chain percentage, rounded up.
- Restore Attribute creates Fortify Attribute using the same calculation.
- Fortify Health, Magicka, or Fatigue creates a matching Restore effect. Its
  per-second magnitude is the higher of source magnitude and duration divided
  by the lower value, multiplied by the current A-chain percentage, and rounded
  up. The Restore lasts for the potion effect's natural duration.
- Fortify Attribute creates a one-time Restore Attribute effect using the
  source magnitude multiplied by the current A-chain percentage, rounded up.
- Resist Fire, Frost, and Shock create Fire, Frost, and Lightning Shield.
- Resist Poison and Resist Magicka create Shield.
- Cure Common Disease, Cure Blight Disease, and Cure Poison create 25 points
  of resistance to the corresponding affliction.
- Fortify Skill and every effect not listed above create no secondary effect.

#### Universal Antidote Details

Universal Antidote uses the following harmful-to-beneficial conversions:

- Drain Attribute, Health, Magicka, Fatigue, or Skill becomes the matching
  Fortify effect.
- Damage Attribute, Health, Magicka, Fatigue, or Skill becomes the matching
  Restore effect.
- Fire, Frost, and Shock Damage become Fire, Frost, and Lightning Shield.
- Weakness to Fire, Frost, Shock, Magicka, Common Disease, Blight Disease,
  Corprus Disease, Poison, or Normal Weapons becomes the matching resistance.
- Burden becomes Feather, Poison becomes Restore Health, and Blind becomes
  Fortify Attack.
- Paralyze becomes 100% Resist Paralysis for the original duration.
- Silence becomes -100 Sound for the original duration.
- Harmful effects without a supported beneficial counterpart are safely
  discarded.

### Alteration

- **A1 - Effortless Casting:** While player-cast Swift Swim is active,
  swimming costs 50% less Fatigue. Player-cast Water Breathing also grants
  25 Night-Eye.
- **A2 - Light Step:** While player-cast Jump is active, jumping costs 50%
  less Fatigue.
- **A3 - Counterweight:** Player-cast Feather negates equal Burden. Burden
  cast on another actor also applies non-stacking Drain Strength equal to
  half its magnitude for the same duration.
- **A4 - Unbound Motion:** Player-cast Levitate grants Paralysis immunity.
- **B1 - Reduced Casting Cost:** Refunds up to 15% of Alteration spell cost
  after other refunds; adjusted costs below 10 become free.
- **B2 - Second Nature:** Refund rises to 30%; adjusted costs below 25 become
  free. Combined refunds cannot exceed the spell's cost.
- **C1 - Steady Footing:** -5 Sound and enough Shield to maintain at least
  35 armor rating.
- **C2 - Immovable Principle:** -10 Sound and enough Shield to maintain at
  least 60 armor rating.
- **D1 - Kinetic Shell:** Player-cast Shield stores force from incoming damage
  and discharges it at double strength on the next weapon hit.
- **D2 - Law of Impact:** Discharge rises to triple strength and preserves
  force beyond the amount needed for a lethal blow.

#### Alteration Mechanics

- Effortless Casting refunds 50% of the Fatigue actually spent swimming while
  a player-cast Swift Swim effect is active. It also grants 10 Night-Eye while
  a player-cast Water Breathing effect is active.
- Light Step refunds 50% of the Fatigue actually spent on each jump while a
  player-cast Jump effect is active.
- Counterweight adds enough Feather to cancel existing Burden, up to the
  magnitude of the active player-cast Feather. Burden cast on another actor
  also applies a visible, non-stacking Drain Strength effect equal to half
  the Burden magnitude for the Burden's remaining duration.
- Unbound Motion grants 100% Resist Paralysis while player-cast Levitate is
  active.
- Reduced Casting Cost waits briefly for other Magicka-refund mechanics, then
  refunds only the spell cost that remains unrestored. It refunds whole points
  of Magicka and cannot raise Magicka above its pre-cast value. If the adjusted
  cost would be below its free-cast threshold, the remaining original cost is
  refunded.
- Steady Footing and Immovable Principle measure armor supplied by equipped
  armor and add only the Shield needed to reach their stated floor.
- Each active player-cast Shield, Fire Shield, Frost Shield, or Lightning
  Shield keeps a separate Kinetic Shell reserve. Incoming Health damage fills
  that reserve according to the Shield's magnitude, up to that magnitude.
  Stored force expires after 60 seconds and requires at least 10 combined
  points before it can discharge.
- Ordinary Shield reserve becomes direct weapon-hit damage. Fire, Frost, and
  Lightning Shield reserves become their matching elemental damage. Kinetic
  Shell spends the reserve at double strength; Law of Impact uses triple
  strength and retains force estimated to exceed the target's remaining
  Health.

### Conjuration

- **A1 - Easier Summoning:** -5 Sound while selecting a summon spell;
  successful summons have a 10% chance to call a second servant. Recasting
  that spell dismisses its previous bonus servants.
- **A2 - Widened Gate:** Sound becomes -10 and chance rises to 20%.
- **A3 - Crowded Threshold:** Sound becomes -15 and chance rises to 30%.
- **A4 - Legion Beyond:** Sound becomes -25; 50% chance for a second summon,
  then 25% chance for a third.
- **B1 - Empowered Servants:** Newly summoned creatures gain 25% attributes,
  skills, and maximum Health.
- **B2 - Deathless Retinue:** Bonuses rise to 35% and servants restore
  2 Health per second.
- **C1 - Pact Dividend:** Maximum Magicka increases by 10% of Intelligence.
- **C2 - Deep Covenant:** Increase rises to 25% of Intelligence.
- **D1 - Bound Mastery:** Every active Bound item grants +5 to its governing
  attribute.
- **D2 - Armory of the Will:** Each Bound piece gains +1 attribute per other
  Bound piece; a mostly Bound set grants +50 Conjuration.

#### Conjuration Mechanics

- A-chain bonus summons repeat only the summoning effects from the successful
  spell. Legion Beyond first rolls its 50% second-summon chance; the 25% third
  summon is rolled only if the second summon succeeds.
- Successfully casting the same summon spell again dismisses the bonus
  instances created by its previous cast before rolling new ones, matching
  vanilla's per-spell replacement behavior. Different summon spells remain
  independent.
- Empowered Servants and Deathless Retinue increase every base attribute,
  every applicable base skill, and base maximum Health by 25% or 35% for the
  original summon duration. Deathless Retinue also restores 2 Health per
  second for that duration.
- Pact Dividend and Deep Covenant use modified Intelligence and round their
  10% or 25% Magicka bonus down to a whole point.
- Bound Daggers, Boots, and the left gauntlet govern Speed. Bound Longswords,
  Maces, Battle Axes, War Axes, and Warhammers govern Strength. Bound Spears,
  Cuirasses, Helms, Greaves, and Pauldrons govern Endurance. Bound Longbows,
  Shields, and the right gauntlet govern Agility.
- Bound Mastery grants +5 to the governing attribute for every active Bound
  piece. Armory of the Will instead grants `5 + the number of other active
  Bound pieces` per piece.
- Armory of the Will counts larger Bound pieces more heavily when checking its
  set bonus. A total Bound weight of 7 is considered a mostly Bound set and
  grants +50 Conjuration.

### Destruction

- **A1 - Elemental Pressure:** Elemental damage gains up to 10% against targets
  missing its paired resource; Drain also deals one-tenth real damage.
- **A2 - Deepening Pressure:** Elemental cap rises to 25% and Drain rider to
  one-eighth.
- **A3 - Ruinous Sympathy:** Elemental cap rises to 50% and Drain rider to
  one-fifth.
- **A4 - Terminal Pressure:** Elemental cap rises to 100% and Drain rider to
  one-half.
- **B1 - Elemental Consequence:** Fire disintegrates armor, Frost drains
  Fatigue, Shock drains Magicka, Poison builds debuffs, and Drain kills refund
  up to 50% of remaining spell cost.
- **B2 - Lingering Catastrophe:** Elemental riders double; Poison becomes
  stronger with a higher cap; Drain-kill refund rises to 100%.
- **C1 - Raw Power:** +25% direct Damage/Drain/Absorb Health and Poison damage;
  A/B riders also accept enchantments and scrolls.
- **C2 - Unanswerable Force:** Direct bonus rises to +50%.
- **D1 - Elemental Mastery:** Player-cast elemental magic gains weather-linked
  protection against reflection.
- **D2 - Executioner's Element:** Below 25% of the paired resource, Fire, Frost,
  and Shock gain finishing effects; Shock can chain to another vulnerable enemy.

#### Destruction Mechanics

- Fire is paired with Health, Frost with Fatigue, and Shock with Magicka.
  Elemental Pressure adds `base magnitude x missing paired-resource percentage
  x the current A-chain cap` as direct Health damage.
- Drain Health, Fatigue, and Magicka deal real damage to the drained resource.
  Drain Attribute and Drain Skill deal lasting Damage Attribute or Damage Skill.
  The fractions are 10%, 12.5%, 20%, and 50% at A1-A4.
- Elemental Consequence converts half of an elemental effect's total
  magnitude over its duration into its rider. Lingering Catastrophe converts
  the full total.
- Fire's rider is Disintegrate Armor. Frost directly damages Fatigue. Shock
  directly damages Magicka.
- Poison adds one stack per second for its duration. At B1, each stack adds
  5% Weakness to Magicka and removes 5 Speed, up to 10 stacks. At B2, each
  stack adds 15% Weakness and removes 10 Speed, up to 20 stacks. The penalties
  clear five seconds after the poison ends.
- Killing a target while the marked Drain remains active refunds a percentage
  of the spell's unspent duration and original cost: up to 50% at B1 or 100%
  at B2.
- Raw Power and Unanswerable Force add 25% or 50% direct Health damage for
  Damage Health, Drain Health, Absorb Health, and Poison. They also allow the
  A- and B-chain riders to respond to enchantments and scrolls.
- Elemental Mastery prevents reflected Fire during ash weather or clear
  daytime, reflected Shock during rain or fog, and reflected Frost at night
  or during snow.
- Executioner's Element applies below 25% of the paired resource. Fire doubles
  its Disintegrate Armor rider, Frost adds one second of Paralysis, and Shock
  strikes one nearby actor below 25% Magicka. It also adds one extra base
  magnitude of direct damage to the vulnerable original target.

### Enchant

- **A1 - Enchanter's Codex:** Catalogues unique effect/trigger pairs; every five
  stacks refunds 1% of NPC enchanting cost.
- **A2 - Living Catalogue:** Each catalogue stack grants +1 Enchant while
  self-enchanting.
- **A3 - Echoed Activation:** Every 25 catalogue stacks grants 1% chance for
  Cast on Use effects to echo.
- **A4 - Grand Codex:** Doubles refund, self-enchanting skill, and echo rates.
- **B1 - Charge Reserve:** Half of detected recharge excess enters a reserve
  that restores one charge to deficient items every 11 seconds.
- **B2 - Perfect Reclamation:** All excess enters the reserve and distributes
  every 5.5 seconds.
- **C1 - Preserved Scroll:** Used scrolls have a 25% chance to be replaced and
  re-selected.
- **C2 - Indelible Formula:** Replacement chance rises to 50%.
- **D1 - Enchanter's Circuit:** Cast on Use creates a 15-second stack, up to
  three; each adds 10% to equipped Constant Effect magnitude.
- **D2 - Closed Circuit:** Cast on Strike also grants stacks and cap rises to
  five.

#### Enchant Mechanics

- The Codex records each effect once for each trigger category: Cast on Use,
  Cast on Strike, and Constant Effect. The same effect can therefore provide
  up to three catalogue entries when encountered under all three triggers.
- Enchanter's Codex refunds 1% of an enchanter's gold fee for every five
  entries. Living Catalogue grants +1 Enchant per entry only while creating
  an enchantment yourself.
- Echoed Activation gains 1% echo chance for every 25 entries. The free echo
  repeats the resolved Cast on Use effects on the original target. Grand Codex
  doubles the fee refund, self-enchanting bonus, and echo chance.
- Charge Reserve records charge added while the Recharge window is open. Half
  of that amount becomes reserve at B1 and all of it at B2. Reserve restores
  one charge at a time, prioritising the right-hand item, selected enchanted
  item, equipped items, and then other carried items; the most depleted item
  wins within a priority group.
- Preserved Scroll and Indelible Formula replace the consumed scroll and make
  the replacement the selected enchanted item.
- Each different enchanted item maintains one Circuit stack; reusing that
  item refreshes its 15-second stack rather than adding another. Each active
  stack multiplies the magnitude of equipped Constant Effects and
  self-targeted Cast on Use effects by 10%.

### Illusion

- **A1 - Eyes Against the Dark:** Player-cast Night-Eye cancels incoming Blind
  magnitude up to its own magnitude.
- **A2 - Untouchable Doubt:** While player-cast Sanctuary is active, incoming
  misses restore 5 Fatigue.
- **A3 - Mind Theft:** Player-cast Paralyze siphons half the target's Strength,
  Endurance, Agility, and Speed until it ends.
- **A4 - Perfect Reassurance:** Landing player-cast Calm resets target Alarm
  to 0.
- **B1 - Measured Deception:** Refunds 30% of Magicka when an enemy-targeting
  Illusion spell affects nobody.
- **B2 - No Wasted Words:** Refund rises to 75%.
- **C1 - Unshaken Mind:** +10% Resist Magicka, +20% Resist Paralysis, and 20%
  less weapon damage while paralysed.
- **C2 - Sovereign Will:** +20% Resist Magicka, +50% Resist Paralysis, and 50%
  less weapon damage while paralysed.
- **D1 - Total Devotion:** Charm overflow above 100 disposition also applies
  Command Humanoid 10 for the Charm duration.
- **D2 - Beloved Master:** Command magnitude rises to 25.

#### Illusion Mechanics

- Eyes Against the Dark cancels Blind point for point, up to the total
  magnitude of active player-cast Night-Eye.
- Mind Theft removes half of the target's current modified Strength,
  Endurance, Agility, and Speed and grants those exact amounts to the player.
  Each theft lasts until that particular Paralyze effect ends; thefts from
  multiple targets can coexist.
- Measured Deception watches non-self Illusion spells for 10 seconds. It
  refunds the stated percentage only if no actor receives that spell.
- Unshaken Mind divides incoming weapon Health and Fatigue damage by 1.25
  while the player cannot move, producing 20% less damage. Sovereign Will
  divides it by 2, producing 50% less damage.
- Total Devotion checks the target's current disposition plus the landed Charm
  magnitude. Command Humanoid is added only when that total exceeds 100 and
  lasts for the Charm's duration.

### Mysticism

- **A1 - Echo of the Soul:** The first Soultrap on an actor converts 5% of soul
  value into charge for equipped enchanted items.
- **A2 - Resonant Capture:** Conversion rises to 10%.
- **A3 - Deep Resonance:** Conversion rises to 15%.
- **A4 - Perfect Soul Circuit:** Conversion rises to 25%.
- **B1 - Soul Tether:** Soultrap also applies a non-stacking 1 point per second
  Absorb Magicka for its duration. Recasting Soultrap does not refresh it.
- **B2 - Final Dividend:** Absorption rises to 2 per second; death during the
  tether restores 20% of soul value as Magicka.
- **C1 - Hungry Soul:** Below 50% Magicka, gain scaling Spell Absorption up
  to 25%.
- **C2 - Abyssal Appetite:** Absorption cap rises to 50%.
- **D1 - Telekinetic Force:** While Telekinesis is active, activating a hostile
  actor spends 25 Magicka, drains Fatigue, and staggers it.
- **D2 - Invisible Hammer:** Cost falls to 15 Magicka; failed Willpower/Fatigue
  resistance causes knockdown.

#### Mysticism Mechanics

- Echo of the Soul can trigger only once per target. Charge is distributed
  first to a deficient right-hand enchanted item, then the selected enchanted
  item, then other equipped items. Lower-charge items take priority within the
  same group.
- Only creatures have a soul value. The converted charge is rounded down.
- Soul Tether lasts for the Soultrap duration and ignores reflection,
  resistance, and absorption. Repeated Soultrap casts neither stack its
  Absorb Magicka nor refresh its duration. Existing duplicate effects are
  collapsed to the oldest, shortest-lived tether. Final Dividend's death
  restoration is rounded up and is paid only when the target dies before the
  tether expires.
- Hungry Soul begins below 50% Magicka and scales linearly: it reaches 25%
  Spell Absorption at empty Magicka. Abyssal Appetite reaches 50%.
- Telekinetic Force requires active player-cast Telekinesis and a hostile
  target. It drains the target's Fatigue by half the player's Mysticism plus
  one-tenth of the player's Willpower, rounded up, then staggers the target.
- Invisible Hammer uses the same Fatigue damage. The target's Willpower and
  remaining Fatigue determine whether the result remains a stagger or becomes
  a knockdown; exhausted, weak-willed targets are least likely to resist.

### Restoration

- **A1 - Ward of Delay:** Restore Health overflow fills a 25%-maximum buffer;
  half of incoming damage can be reserved and dissipated over two seconds.
- **A2 - Deep Reserve:** Health buffer cap rises to 50% and dissipation to
  three seconds.
- **A3 - Second Reservoir:** Restore Fatigue overflow gains an independent
  buffer using the same rules.
- **A4 - Perfect Intercession:** Both caps rise to 100% and dissipation to
  five seconds.
- **B1 - Attribute-Linked Restoration:** Restoring a damaged linked attribute
  also restores its Health, Magicka, or Fatigue at 1:1.
- **B2 - Harmonic Recovery:** Linked restoration rises to 2:1.
- **C1 - Clear Mind:** At full Health and Fatigue, restore 1 Magicka per second.
- **C2 - Abundant Clarity:** Each Ward buffer above half capacity adds another
  1 Magicka per second.
- **D1 - Warding Reprisal:** Spell damage prevented by resistances is reflected
  at its caster as a paired damage type.
- **D2 - Cushioned Vengeance:** Damage caught by the Health buffer also
  contributes direct reflected damage.

#### Restoration Mechanics

- Only eligible player-cast Restore Health and Restore Fatigue effects can fill
  Ward of Delay. Passive regeneration, abilities, enchantments, scrolls,
  potions, and ingredients do not create reserve.
- Healing first fills the missing resource. Only genuine overflow enters its
  Ward buffer. Overflow first cancels damage currently dissipating, then fills
  available reserve.
- A Ward can reserve up to half of each incoming hit while reserve remains.
  The reserved portion is removed from the immediate hit and then dissipates
  evenly over the perk's stated two-, three-, or five-second period.
- A buffer begins to fade after ten seconds without healing or buffering,
  losing 5% of its maximum capacity per second.
- Attribute-Linked Restoration maps Strength and Endurance to Health,
  Intelligence to Magicka, and Agility, Speed, and Willpower to Fatigue. Once
  per second, it restores the linked resource by the amount of attribute damage
  repaired that second, or twice that amount with Harmonic Recovery.
- Clear Mind requires both Health and Fatigue to be full. Abundant Clarity adds
  one more Magicka per second for each Health or Fatigue Ward whose available
  plus dissipating reserve exceeds half of its capacity.
- Warding Reprisal returns resisted Fire as Frost, Frost as Fire, Shock as
  Poison, Poison as Shock, and resisted Damage, Drain, or Absorb Health as
  Damage Health. The reflected amount is calculated from the damage that the
  player's resistance prevented.
- Cushioned Vengeance adds direct Damage Health equal to the exact amount of
  that hit newly caught by the Health Ward.

### Unarmored

- **A1 - Empty Hand Discipline:** Each empty armor slot grants -2 Sound and
  +1 Shield.
- **A2 - Unencumbered Form:** Each slot grants -3 Sound and +2 Shield.
- **A3 - Ninefold Guard:** Each slot grants -5 Sound and +3 Shield.
- **A4 - Living Aegis:** Each slot grants -5 Sound and +5 Shield.
- **B1 - Unburdened Casting:** While mostly unarmored, spellcasting animations
  are 50% faster.
- **B2 - Thought Before Motion:** Casting animations are 100% faster.
- **C1 - Focused Flesh:** Each empty slot grants 4% Resist Magicka.
- **C2 - Soul-Sheathed:** Each empty slot also grants 2.5% Spell Absorption.
- **D1 - Body as Focus:** While completely unarmored and above 25% Fatigue,
  convert 75% of incoming Health damage into Fatigue damage.
- **D2 - Untouchable Centre:** While completely unarmored, gain Sanctuary
  scaling from Agility, Luck, and current Fatigue.

#### Unarmored Mechanics

- The nine checked armor positions are helm, cuirass, greaves, both pauldrons,
  both gauntlets, boots, and the left hand. An empty slot or a non-armor item
  in that slot counts as unarmored.
- “Mostly unarmored” means at least seven of those nine positions are
  unarmored. “Completely unarmored” means all nine.
- The A- and C-chain bonuses are multiplied separately by every unarmored
  position. At nine empty positions, Living Aegis therefore grants -45 Sound
  and +45 Shield, while Soul-Sheathed grants 36% Resist Magicka and 22.5%
  Spell Absorption.
- Body as Focus requires at least 25% current Fatigue. It converts 75% of
  incoming weapon Health damage into an equal amount of Fatigue damage, leaving
  25% as Health damage.
- Untouchable Centre's Sanctuary is based on Agility and Luck and becomes
  stronger as current Fatigue falls, reaching zero at full Fatigue.

## Console Commands

Enter these directly into the normal OpenMW console:

- `luaalchemy debug`
- `luaalteration debug`
- `luaconjuration debug`
- `luadestruction debug`
- `luaenchant debug`
- `luaillusion debug`
- `luamysticism debug`
- `luarestoration debug`
- `luaunarmored debug`

Each command reports the skill's owned chain ranks and relevant live state,
including tracked casts, targets, effect pools, reserves, equipment gates, and
active spell-compatibility information where applicable.

Append ` trace` to any command to toggle its live activation trace, or use
`trace on`, `trace off`, and `trace status` explicitly. For example:

- `luarestoration debug trace on`
- `luarestoration debug trace status`
- `luarestoration debug trace off`

Trace output requires SkillPerks verbosity `3`. Each activation is numbered
and reports its trigger, eligibility gates, source classification, calculations,
random rolls, resource or spell delivery, target-local handling, and final
application acknowledgement. Passive calculations print when their inputs or
outputs change rather than repeating unchanged state every update.

Shorter aliases remain available: `luaalch debug`, `luaalt debug`, `luaconj
debug`, `luadest debug`, `luaillu debug`, `luamyst debug`, `luarest debug`, and
`luaunarm debug`.

The shared `luaperks menu`, `luaperks respec`, and `luaperks dump` commands are
documented in Core 0.

## Ward of Delay HUD

Owning Ward of Delay enables a compact Morrowind-style reserve display. The
Health bar shows reserve available for the next hit; the adjoining segment and
status line show damage already committed to dissipation. Second Reservoir adds
a matching Fatigue bar.

The HUD is owned by SkillPerks. Its enable, position, and update controls appear
on the SkillPerks settings page only while Core 3 is installed.

## What Counts as a Spell

Vanilla spells, player-created spells, powers, and supported Spellforge spells
count when cast by the player. Passive abilities, diseases, curses,
enchantments, scrolls, potions, ingredients, and effects without a caster do
not count unless a perk specifically says otherwise.

Spell Framework Plus is optional and improves compatibility with Spellforge.

## Constellation Display

The optional constellation menu groups all nine trees inside the Magic nebula.
Core 3 provides authored normal/completed textures and normalized node
positions. Completing every compatible node swaps the subdued symbol for its
blue-white completed version.

## Gameplay Notes

Empowered Servants applies shortly after a successful summoning cast. Charge
Reserve stores excess charge detected while using the Recharge menu.
