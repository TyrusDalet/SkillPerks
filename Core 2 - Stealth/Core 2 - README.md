# SkillPerks Core 2 - Stealth

Core 2 adds complete perk trees for the nine Stealth skills. Each tree contains
ten perks using the shared A1-A4, B1-B2, C1-C2, and D1-D2 structure.

## Requirements and Load Order

Core 2 requires:

- SkillPerks Core 0.
- SkillPerks Core 1.
- ErnPerkFramework - Tyrus Revision/Overhaul.
- Inventory Extender.

Load those dependencies before `Core 2 SkillPerks.omwscripts`.

## Progression

- A chain: skill 25, 50, 75, and 100.
- B chain: skill 50 and 100.
- C and D: mutually exclusive mastery branches reached through A4.
- C2 and D2 require their preceding branch perk and skill 100.

## Perk Catalogue

### Acrobatics

- **A1 - Light Landing:** Reduces fall damage by 20%.
- **A2 - Soft Impact:** Fall-damage reduction rises to 40%.
- **A3 - Ground Friend:** Fall-damage reduction rises to 60%.
- **A4 - Rebounding Step:** Fall-damage reduction rises to 80%; a significant
  landing grants +20 Speed for two seconds.
- **B1 - Acrobatic Strike:** Attacks made while jumping or falling deal 10%
  bonus damage.
- **B2 - Falling Star:** Aerial damage rises to 20%; the first attack shortly
  after landing deals 25% bonus damage instead.
- **C1 - Evasive Roll:** Jumping grants Chameleon 20% for one second.
- **C2 - Vanishing Vault:** Chameleon rises to 35%; jumping while already
  sneaking extends it to two seconds.
- **D1 - Cloud Jump:** Jumps made within three seconds of landing grant
  stacking +10 Jump, up to three stacks.
- **D2 - Sky-Hungry:** Stack cap rises to five and maximum stacks grant
  +15 Speed.

### Hand-to-Hand

- **A1 - Iron Fists:** Unarmed hits deal bonus Fatigue damage equal to
  Hand-to-Hand / 10.
- **A2 - Body Breaker:** Damage improves to Hand-to-Hand / 7.
- **A3 - Breath Thief:** Damage improves to Hand-to-Hand / 5.
- **A4 - Empty-Hand Judgment:** Fatigue damage remains Hand-to-Hand / 5;
  targets below 25% Fatigue also take Health damage equal to Hand-to-Hand / 10,
  rounded down.
- **B1 - Iron Skin:** While unarmed, gain Resist Normal Weapons equal to
  Hand-to-Hand / 5, capped at 20%.
- **B2 - Bare-Knuckle Ward:** Resistance cap rises to 30%; also gain Sanctuary
  equal to Hand-to-Hand / 10, capped at 10.
- **C1 - Disarming Blow:** Unarmed hits against armed opponents have a 10%
  chance to damage weapon condition by Hand-to-Hand / 3.
- **C2 - Breaker Grip:** Chance rises to 20% and doubles against weapons below
  25% condition.
- **D1 - Knockout Blow:** Unarmed hits against non-paralysed targets below 15%
  Fatigue have a 10% chance to attempt a one-second paralysis. The target's
  Willpower and Resist Paralysis then resolve normally.
- **D2 - Lights Out:** Chance rises to 25% and duration to three seconds.

### Light Armor

- **A1 - Evasive:** Mostly Light Armor grants +5 Sanctuary.
- **A2 - Slip the Line:** Sanctuary rises to +10.
- **A3 - Untouchable Habit:** Sanctuary rises to +15.
- **A4 - Wind-Worn Guard:** Sanctuary rises to +20.
- **B1 - Reactive Step:** Taking a hit while mostly in Light Armor grants
  +20 Speed for three seconds.
- **B2 - Answering Rush:** Speed rises to +35; the next attack gains +5% damage
  per owned Light Armor perk, capped at +40%.
- **C1 - Dodge Mastery:** Incoming misses build up to five stacks; the next hit
  is reduced by 5% per stack, followed by a ten-second lockout.
- **C2 - Blurred Recovery:** Cap rises to eight and lockout falls to seven
  seconds.
- **D1 - Flow State:** Incoming misses grant +4 Agility per held dodge stack;
  stacks are consumed when hit, with a five-second lockout.
- **D2 - Living Current:** Agility rises to +6 per stack and cap rises to eight.

### Marksman

- **A1 - Steady Aim:** While aiming a bow or crossbow, or holding back a thrown
  weapon, without moving, gain +5 Marksman after one second and another +5
  every second, up to two stacks (+10).
- **A2 - Held Line:** Maximum rises to four stacks (+20 Marksman).
- **A3 - Dead Calm:** Maximum rises to six stacks (+30 Marksman). The first
  stack and every subsequent stack take 0.5 seconds.
- **A4 - Certain Shot:** Maximum rises to eight stacks (+40 Marksman); aiming
  for three seconds while stationary guarantees the next shot will hit.
- **B1 - Efficient Quiver:** Ranged kills have a 25% chance to recover reported
  fired ammunition.
- **B2 - Hunter's Return:** Recovery chance rises to 50%.
- **C1 - Crank Discipline:** Crossbows ready 25% faster. When preparing to fire
  a loaded crossbow, gain +10 Agility and +25 Speed.
- **C2 - Snaplock:** Crossbows ready 50% faster. When preparing to fire a loaded
  crossbow, gain +20 Agility and +50 Speed.
- **D1 - Sniper:** Unaware ranged hits deal 150% damage.
- **D2 - Last Thing Seen:** Unaware ranged hits deal 200% damage.

### Mercantile

- **A1 - Sharp Eye:** Merchants suffer -5 Mercantile during conversation.
- **A2 - Weighted Coin:** Penalty rises to -10.
- **A3 - Ledger Instinct:** Penalty rises to -15.
- **A4 - Merchant's Knife:** Penalty rises to -20.
- **B1 - Working Capital:** Merchants gain temporary barter gold equal to 10
  times your base Mercantile plus Liquid Assets' bonus for the conversation.
- **B2 - Deep Reserves:** Working Capital increases to 25 times your base
  Mercantile plus Liquid Assets' bonus.
- **C1 - Patronage:** 1% of the net gold you spend in a completed barter
  permanently increases that merchant's barter gold.
- **C2 - Commercial Roots:** Patronage invests 2.5% of your net spend.
- **D1 - Liquid Assets:** Gain +1 Mercantile for every 10,000 gold of net
  wealth.
- **D2 - Golden Measure:** Also gain +1 Luck for every 25,000 gold of net
  wealth. With Tamriel_Data installed, bank deposits and current stock value
  count as wealth while outstanding bank loans reduce it.

### Security

- **A1 - Deft Hands:** Lockpick uses have a 20% chance not to consume
  durability.
- **A2 - Soft Pressure:** Preservation chance rises to 40%.
- **A3 - Patient Tension:** Preservation chance rises to 60%.
- **A4 - Lock Whisperer:** Preservation chance rises to 80%.
- **B1 - Pattern Recognition:** Failures on the same lock grant +5 Security
  for later attempts, stacking three times until success or changing locks.
- **B2 - Known Mechanism:** Stack cap rises to six.
- **C1 - Trap Mastery:** Failed probe attempts have a 25% chance not to consume
  durability; successful attempts have a 50% chance.
- **C2 - Wire-Seer:** Preservation chance rises to 50% on failure and 100% on
  success.
- **D1 - Master Locksmith:** Once per rest, activating a locked object attempts
  a normal Security roll at tool quality 1, regardless of held equipment.
- **D2 - Hands Like Keys:** Allows two attempts per rest; a failed attempt
  permanently reduces the lock's level by 25%.

### Short Blade

- **A1 - Blade Tempo:** Hits grant up to three +3 Speed stacks, which expire
  after four seconds without another hit.
- **A2 - Quickened Edge:** Each stack grants +5 Speed.
- **A3 - Knife Rhythm:** Stack cap rises to five.
- **A4 - Eightfold Motion:** Cap rises to eight and maximum stacks grant
  +10 Agility.
- **B1 - Opening Strike:** The first Short Blade hit on each target deals
  bonus damage equal to Short Blade / 5.
- **B2 - First Blood Lesson:** Bonus improves to Short Blade / 3 and doubles
  against an unaware target.
- **C1 - Vital Strike:** Repeated hits on one target within five seconds gain
  +4% damage per stack, up to five.
- **C2 - Cruel Precision:** Vital Strike improves to +5% damage per stack, its
  cap rises to eight, and its timer extends to eight seconds. Attacks at full
  stacks attempt a half-damage shadow-hit after 0.1 seconds, carrying all on-hit
  effects.
- **D1 - Bleed:** Hits apply up to three stacks for five seconds. Each stack
  deals 1% of the target's maximum Health per second, with a minimum of 1.
- **D2 - Red Silence:** Cap rises to five. Attacks from five stacks onward
  have a 10% chance to attempt one second of resistible Paralysis.

### Sneak

- **A1 - Shadow Step:** Gain +5 Sneak while sneaking.
- **A2 - Soft Footfall:** Bonus rises to +10.
- **A3 - Held Breath:** Bonus rises to +15.
- **A4 - Absent Shape:** Bonus rises to +20.
- **B1 - Silenced Movement:** Offsets half of the normal sneak movement-speed
  penalty, including while sprinting.
- **B2 - Noiseless Haste:** Fully offsets normal sneak movement loss,
  including while sprinting.
- **C1 - Opportunist:** The first unaware hit against a target deals 150%
  damage.
- **C2 - Knife in the Quiet:** Damage rises to 200%.
- **D1 - Phantom:** Entering sneak during combat grants Chameleon 40% for
  three seconds.
- **D2 - Vanishing Point:** Chameleon rises to 60%; breaking combat during the
  initial window extends it by five seconds.

### Speechcraft

- **A1 - Compelling Voice:** Each successful persuasion attempt grants a
  cumulative +5 Speechcraft for the current conversation, up to two stacks.
- **A2 - Measured Praise:** Stack cap rises to four.
- **A3 - Threaded Intent:** Stack cap rises to six.
- **A4 - Conversation's Crown:** Stack cap rises to ten.
- **B1 - Cutting Cadence:** Enemies fighting you within 5 metres suffer 15
  points of Sound.
- **B2 - Voice Above Steel:** Sound rises to 30 and reaches 15 metres.
- **C1 - Plausible Account:** Newly incurred bounty is reduced by 20%.
- **C2 - Unimpeachable Story:** Newly incurred bounty is reduced by 40%.
- **D1 - Attentive Student:** Purchased training grants 25% progress toward
  that skill's next level.
- **D2 - Lessons Remembered:** Purchased training grants 50% progress instead.

## Detailed Perk Rules

### Light Armor Scoring

“Mostly Light Armor” uses weighted slots and requires 7 Light Armor points.
A Light cuirass is worth 3 points, greaves and shield are worth 2 each, and
the helmet, each pauldron, each gauntlet, and boots are worth 1 each.

### Acrobatics Details

- Fall protection is resolved from the Health actually lost on a drop greater
  than 250 world units. Damage received from another hit at the same moment is
  excluded from the estimated fall damage.
- Rebounding Step's Speed burst uses the same significant-fall condition and
  lasts two seconds.
- Acrobatic Strike works while airborne, then its 1.5-second grace period
  begins upon landing. Falling Star uses a one-second landing window; its first
  attack uses the 25% landing bonus instead of the ordinary 20% aerial bonus.
- Evasive Roll starts when the jump begins. Vanishing Vault lasts two seconds
  only when Sneak was already held at that moment.
- Cloud Jump gains one stack per jump and refreshes a shared three-second
  expiry. The timer remains paused in the air and begins upon landing. Every
  stack grants +10 Jump; all stacks clear when the timer expires.

### Hand-to-Hand Details

- “Unarmed” means no weapon is equipped in the right hand. Shields and other
  left-hand equipment do not disable these perks.
- Empty-Hand Judgment checks the target's Fatigue before applying direct
  Health damage equal to one-tenth of Hand-to-Hand, rounded down.
- Disarming Blow and Breaker Grip damage the opponent's currently equipped
  weapon. Breaker Grip's low-condition chance can reach 40%.
- Knockout Blow and Lights Out first pass their own proc chance, then allow the
  target's normal Willpower and Resist Paralysis defenses to prevent the
  effect. As martial procs they bypass spell absorption and reflection. They
  cannot trigger on an already paralysed target and never stack or refresh an
  existing paralysis.

### Light Armor Details

- Reactive Step requires Mostly Light Armor when the hit lands. Answering Rush
  must be used during its three-second Speed burst and is consumed by the next
  successful attack.
- Answering Rush counts all ten owned Light Armor perks at 5% each, but caps
  its post-armor damage bonus at 40%.
- Dodge Mastery and Flow State keep separate stack pools and lockouts. Each
  incoming miss can build both when both branches are active.
- Dodge Mastery reduces the next incoming Health damage by 5% per held stack,
  capped at 40%, then clears its stacks. Flow State's Agility also clears on
  that hit. Their lockouts are seven or ten seconds for Dodge Mastery and five
  seconds for Flow State.
- All Light Armor chains suspend their active bonuses when the Mostly Light
  Armor threshold is no longer met.

### Marksman Details

- Steady Aim supports bows, crossbows, and thrown weapons. It requires no
  meaningful movement and the attack control to remain held. Ranks A1-A2 gain
  their first +5 Marksman after one
  second and another stack every second. Dead Calm and Certain Shot reduce
  both timings to 0.5 seconds. Moving or changing away from a ranged weapon
  clears the active bonus. Releasing captures the earned stacks for that shot,
  then clears them when the shot resolves or expires.
- Certain Shot becomes ready after three stationary seconds. It is consumed by
  the next ranged attack and turns a failed hit into a conservative
  post-armor hit rather than bypassing armor. A thunder sound plays when the
  prepared shot is released.
- Efficient Quiver can return ammunition only when the attack reports which
  arrow or bolt was fired and the target is dead when the delayed kill check
  resolves.
- Crank Discipline and Snaplock permanently accelerate crossbow preparation
  while their rank is owned. Their Agility and Speed bonuses apply only while
  the player holds the attack control to prepare a loaded crossbow to fire.
- Sniper and Last Thing Seen check awareness when the projectile lands. An
  actor already fighting the player is not unaware.

### Mercantile Details

- Sharp Eye applies only to NPCs who offer merchant services. Its penalty is
  temporary and only the exact SkillPerks contribution is removed when the
  conversation closes.
- Working Capital uses base Mercantile plus only the bonus from Liquid Assets.
  Spells, enchantments, and other Mercantile modifiers do not increase it. At
  100 base Mercantile before Liquid Assets, it adds 1,000 barter gold at B1 or
  2,500 at B2, then removes that temporary gold at conversation end without
  overwriting bonuses from other mods.
- Patronage counts the net gold paid in each accepted barter. Selling items
  back in the same transaction reduces the qualifying spend. Investments
  below one whole gold round down and do not apply.
- Each merchant keeps a separate cumulative investment. SkillPerks restores
  its own recorded bonus after a normal barter-gold restock or save load and
  never replaces the merchant's whole gold value.
- Liquid Assets counts carried gold. Golden Measure also recognizes the
  documented Tamriel_Data Banking Framework deposits and Stock Exchange
  portfolio values, then subtracts outstanding bank loans.
- Wealth is recalculated when the perk is applied, after opening barter, every
  new in-game day, and every 20 seconds of unpaused play. Stat modifiers are
  changed only when a wealth tier changes and are reported through AAM.

### Security Details

- Pattern Recognition grants +5 Security after each failed attempt on the same
  lock. Success or selecting a different lock clears every stack.
- Deft Hands rolls after every observed lockpick use. Trap Mastery rolls after
  every probe use; successful disarms receive its higher preservation chance.
- A probe or lockpick that is destroyed by spending its final use may cease to
  exist before a preservation effect can return that use.
- Master Locksmith triggers when activating a locked object, regardless of
  held equipment. Its chance is the normal `Security + Agility / 5 + Luck / 10`,
  modified by current Fatigue and reduced by the lock level. Attempting consumes
  one of the perk's uses even on failure; resting restores the allowance.
- Hands Like Keys leaves a failed lock closed but permanently reduces its
  current lock level by 25%. Successful checks simply open the lock.

### Short Blade Details

- Blade Tempo adds one stack per successful Short Blade hit. After four
  seconds without a hit, it loses one stack every four seconds rather than
  dropping the entire stack at once.
- Opening Strike becomes available again after that target leaves combat with
  the player. First Blood Lesson doubles only its flat Short Blade-based bonus,
  not the whole weapon hit. The flat bonus resolves after ordinary damage
  calculations, is included in Opportunist or Knife in the Quiet, receives
  First Blood Lesson's unaware doubling, and then receives the melee critical
  multiplier.
- Vital Strike adds 4% of the current post-armor hit per existing stack, then
  adds the new stack. Cruel Precision raises this to 5%. Changing targets
  clears the previous target's sequence.
- At eight stacks, Cruel Precision makes a separate hit roll after each attack.
  A successful shadow-hit resolves 0.1 seconds later, begins at half the
  triggering hit's resolved damage, then passes through the shared outgoing
  on-hit pipeline. Its internal marker prevents it from generating another
  shadow-hit. It repeats the triggering impact sound at 25% volume when the
  delayed strike lands.
- Bleed deals direct Health damage once per second equal to 1% of the target's
  maximum Health per stack, with a one-damage minimum for each stack. New hits
  add a stack and refresh the shared five-second duration.
- At five stacks, Red Silence rolls its 10% paralysis chance on every further
  hit, including the hit that reaches five. Successful rolls still face the
  target's natural paralysis resistance and cannot stack with active Paralysis.

### Sneak Details

- Silenced Movement and Noiseless Haste calculate enough Speed to offset half
  or all of the game's normal Sneak movement multiplier. Their compensation
  remains active while sprinting.
- Opportunist is available once per target per combat encounter and requires
  the target to be unaware when hit. The bonus is based on damage remaining
  after normal armour and other Framework damage resolution. Opening Strike is
  added immediately before this multiplier; First Blood Lesson's unaware
  doubling follows it, with critical scaling represented last.
- Phantom starts only when the player newly enters Sneak while an actor is
  actively fighting them. Vanishing Point can gain its five-second extension
  once, only if all such combat targeting ends during the original
  three-second window.

### Speechcraft Details

- Compelling Voice gains one +5 Speechcraft stack after each observed
  successful persuasion. Failures do not remove stacks; every stack clears
  when the conversation closes. The temporary skill bonus is reported through
  AAM.
- Cutting Cadence and Voice Above Steel affect only actors currently fighting
  the player and inside the stated radius. Each target receives one named
  Sound modifier that is replaced and refreshed, never stacked repeatedly.
- Plausible Account and Unimpeachable Story affect only the newly added part of
  a bounty. Existing bounty is untouched, and reductions are rounded down to
  whole gold.
- Attentive Student and Lessons Remembered detect a base-skill increase while
  the Training interface is open, then add progress to that same skill. The
  bonus is capped just below a full level, so it cannot grant another instant
  skill rank or bypass the trainer limit.

## Console Commands

Enter these directly into the normal OpenMW console:

- `luaacrobatics debug`
- `luahandtohand debug`
- `lualightarmor debug`
- `luamarksman debug`
- `luamercantile debug`
- `luasecurity debug`
- `luashortblade debug`
- `luasneak debug`
- `luaspeechcraft debug`

Each command reports the skill's owned chain ranks and relevant live state,
including movement windows, target memory, stacks, cooldowns, equipment,
conversation state, or lock tracking where applicable.

Mercantile diagnostics include the last merchant modifiers, completed barter,
investment-restock decision, and full net-wealth tier calculation. Speechcraft
diagnostics include the last persuasion result, combat Sound refresh, bounty
reduction calculation, and purchased-training progress delivery.

Append ` trace` to any command to toggle its live activation trace, such as
`luah2h debug trace`. Trace output requires SkillPerks verbosity `3`; enter
the same command again to disable it.

Shorter aliases remain available for most skills: `luaacro debug`, `luah2h
debug`, `luala debug`, `luamark debug`, `luamerc debug`, `luasec debug`,
`luasb debug`, and `luaspeech debug`.

The shared `luaperks menu`, `luaperks respec`, and `luaperks dump` commands are
documented in Core 0.

## Constellation Display

The optional constellation menu groups these nine skills inside the Stealth
nebula. Core 2 provides authored normal/completed textures and normalized node
positions. Internal chain routes are part of the artwork; cross-constellation
requirements remain available to the Framework.

Completing every compatible node swaps the subdued symbol for its blue-white
completed version. The mutually exclusive branch not selected is not required.

## Gameplay Notes

Inventory Extender is required for Security, Mercantile, and other
inventory-facing effects.

A lockpick or probe that spends its final remaining use may break before a
preservation effect can return that use.

Silenced Movement and Noiseless Haste use movement-formula work adapted, with
permission, from Ownlyme's Shadowdancer blessing in Roguelite. Roguelite is
not required.
