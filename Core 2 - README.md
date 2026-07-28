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
- **D1 - Momentum:** Jumps made within three seconds grant stacking +10 Jump,
  up to three stacks.
- **D2 - Sky-Hungry:** Stack cap rises to five and maximum stacks grant
  +15 Speed.

### Hand-to-Hand

- **A1 - Iron Fists:** Unarmed hits deal bonus Fatigue damage equal to
  Hand-to-Hand / 10.
- **A2 - Body Breaker:** Damage improves to Hand-to-Hand / 7.
- **A3 - Breath Thief:** Damage improves to Hand-to-Hand / 5.
- **A4 - Empty-Hand Judgment:** Damage improves to Hand-to-Hand / 4; targets
  below 25% Fatigue take matching Health damage.
- **B1 - Iron Skin:** While unarmed, gain Resist Normal Weapons equal to
  Hand-to-Hand / 5, capped at 20%.
- **B2 - Bare-Knuckle Ward:** Resistance cap rises to 30%; also gain Sanctuary
  equal to Hand-to-Hand / 10, capped at 10.
- **C1 - Disarming Blow:** Unarmed hits against armed opponents have a 10%
  chance to damage weapon condition by Hand-to-Hand / 3.
- **C2 - Breaker Grip:** Chance rises to 20% and doubles against weapons below
  25% condition.
- **D1 - Knockout Blow:** Targets below 15% Fatigue have a 25% chance to be
  paralysed for three seconds by an unarmed hit.
- **D2 - Lights Out:** Chance rises to 50% and duration to five seconds.

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

- **A1 - Steady Aim:** Standing still with a ranged weapon builds +5 Marksman
  per second after one second, up to +10.
- **A2 - Held Line:** Maximum bonus rises to +20.
- **A3 - Dead Calm:** Maximum rises to +30 and buildup begins after 0.5 seconds.
- **A4 - Certain Shot:** Maximum rises to +40; drawing for three seconds while
  stationary guarantees the next shot will hit.
- **B1 - Efficient Quiver:** Ranged kills have a 25% chance to recover reported
  fired ammunition.
- **B2 - Hunter's Return:** Recovery chance rises to 50%.
- **C1 - Ranged Mastery:** Equipping a bow or crossbow grants +10 Marksman.
- **C2 - Unbroken Sight:** Bonus rises to +20 Marksman and +5 Agility.
- **D1 - Sniper:** Unaware ranged hits deal 150% damage.
- **D2 - Last Thing Seen:** Unaware ranged hits deal 200% damage.

### Mercantile

- **A1 - Sharp Eye:** Merchants suffer -5 Mercantile during conversation.
- **A2 - Weighted Coin:** Penalty rises to -10.
- **A3 - Ledger Instinct:** Penalty rises to -15.
- **A4 - Merchant's Knife:** Penalty rises to -20.
- **B1 - Silver Tongue:** An accepted haggle applies a further -5 Mercantile
  for that conversation.
- **B2 - Pleasant Robbery:** Additional penalty rises to -10 and accepted
  haggles grant +3 temporary disposition.
- **C1 - Market Knowledge:** Inventory Extender barter prices improve by 5%
  when buying or selling.
- **C2 - Price Memory:** Barter-price improvement rises to 10%.
- **D1 - Read the Room:** If starting disposition is below 50, the next
  successful bribe has double effect.
- **D2 - House Advantage:** The bribe has triple effect; merchants gain
  temporary barter gold equal to five times your Mercantile advantage.

### Security

- **A1 - Deft Hands:** Failed lockpick condition loss is reduced by 20%.
- **A2 - Soft Pressure:** Reduction rises to 40%.
- **A3 - Patient Tension:** Reduction rises to 60%.
- **A4 - Lock Whisperer:** Reduction rises to 80%.
- **B1 - Pattern Recognition:** Failures on the same lock grant +5 Security
  for later attempts, stacking three times until success or changing locks.
- **B2 - Known Mechanism:** Stack cap rises to six.
- **C1 - Trap Mastery:** Failed probe wear is halved; successful disarms have
  a 25% chance to preserve the use.
- **C2 - Wire-Seer:** Successful-disarm preservation rises to 50%.
- **D1 - Master Locksmith:** Once per rest, activating a lock with an empty
  right hand attempts a normal Security roll at tool quality 1.
- **D2 - Hands Like Keys:** Allows two attempts per rest; success permanently
  weakens the lock by half your Security skill.

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
  +3% damage per stack, up to five.
- **C2 - Cruel Precision:** Cap rises to eight and timer to eight seconds.
- **D1 - Bleed:** Hits apply up to three stacks dealing 1 Health per second
  each for five seconds.
- **D2 - Red Silence:** Cap rises to five; after reaching maximum stacks, the
  next hit attempts a brief paralysis.

### Sneak

- **A1 - Shadow Step:** Gain +5 Sneak while sneaking.
- **A2 - Soft Footfall:** Bonus rises to +10.
- **A3 - Held Breath:** Bonus rises to +15.
- **A4 - Absent Shape:** Bonus rises to +20.
- **B1 - Silenced Movement:** Offsets half of the normal sneak movement-speed
  penalty; sprint remains penalized.
- **B2 - Noiseless Haste:** Fully offsets normal sneak movement loss; sprint
  remains penalized.
- **C1 - Opportunist:** The first unaware hit against a target deals 150%
  damage.
- **C2 - Knife in the Quiet:** Damage rises to 200%.
- **D1 - Phantom:** Entering sneak during combat grants Chameleon 40% for
  three seconds.
- **D2 - Vanishing Point:** Chameleon rises to 60%; breaking combat during the
  initial window extends it by five seconds.

### Speechcraft

- **A1 - Compelling Voice:** A successful persuasion attempt grants +5
  Speechcraft to the next attempt with that NPC during the conversation.
- **A2 - Measured Praise:** Bonus rises to +10.
- **A3 - Threaded Intent:** Bonus rises to +15 and carries across persuasion
  types.
- **A4 - Conversation's Crown:** Bonus rises to +20; three consecutive
  successes grant a persistent +5 disposition once per conversation.
- **B1 - Read the Crowd:** Failed persuasion does not reduce disposition.
- **B2 - Recovery Line:** Failure against an NPC below 30 disposition grants
  +10 Speechcraft to the next attempt.
- **C1 - Lingering Words:** A conversation containing successful persuasion
  leaves +5 disposition for 24 in-game hours.
- **C2 - Remembered Grace:** Effect rises to +10 for 72 in-game hours.
- **D1 - Commanding Presence:** Once per day, converts the next persuasion
  attempt against a non-hostile NPC into a success.
- **D2 - Voice of Office:** Available twice per day and doubles the successful
  disposition gain.

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
- Acrobatic Strike works while airborne and for 1.5 seconds after beginning a
  jump. Falling Star leaves a one-second landing window; its first attack uses
  the 25% landing bonus instead of the ordinary 20% aerial bonus.
- Evasive Roll starts when the jump begins. Vanishing Vault lasts two seconds
  only when Sneak was already held at that moment.
- Acrobatics Momentum gains one stack per jump and refreshes a shared
  three-second expiry. Every stack grants +10 Jump; all stacks clear when the
  timer expires.

### Hand-to-Hand Details

- “Unarmed” means no weapon is equipped in the right hand. Shields and other
  left-hand equipment do not disable these perks.
- Empty-Hand Judgment checks the target's Fatigue before its matching direct
  Health damage is applied.
- Disarming Blow and Breaker Grip damage the opponent's currently equipped
  weapon. Breaker Grip's low-condition chance can reach 40%.
- Knockout Blow and Lights Out apply ordinary Paralysis, so Resist Paralysis
  and other normal defenses still apply.

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

- Steady Aim requires a ranged weapon, no meaningful movement, and the attack
  control to remain held. After its initial delay it gains +5 Marksman for
  each full second. Moving, changing away from a ranged weapon, or releasing
  the draw beyond a brief release window clears the bonus.
- Certain Shot becomes ready after three stationary seconds. It is consumed by
  the next ranged attack and turns a failed hit into a conservative
  post-armor hit rather than bypassing armor.
- Efficient Quiver can return ammunition only when the attack reports which
  arrow or bolt was fired and the target is dead when the delayed kill check
  resolves.
- Sniper and Last Thing Seen check awareness when the projectile lands. An
  actor already fighting the player is not unaware.

### Mercantile Details

- Sharp Eye applies only to NPCs who offer merchant services. Its penalty and
  Silver Tongue's additional penalty are temporary and are removed when the
  conversation closes.
- Pleasant Robbery's +3 disposition is granted for each accepted haggle and
  all of that temporary disposition is removed at conversation end.
- Market Knowledge changes the live offer symmetrically: goods sold improve
  by 5% or 10%, while purchases become 5% or 10% cheaper.
- Read the Room arms one bribe only when the merchant's starting disposition
  is below 50. The first successful bribe doubles or triples the disposition
  it would have granted, then consumes the benefit.
- House Advantage adds temporary barter gold equal to five times the positive
  difference between the player's and merchant's modified Mercantile skills.
  It never removes gold when the merchant has the advantage, and the added
  gold is removed when the conversation closes.

### Security Details

- Pattern Recognition grants +5 Security after each failed attempt on the same
  lock. Success or selecting a different lock clears every stack.
- Trap Mastery always refunds half of condition lost by a failed probe use.
  Its 25% or 50% successful-disarm preservation roll is separate.
- A probe or lockpick that is destroyed by spending its final use may cease to
  exist before a preservation effect can return that use.
- Master Locksmith requires an empty right hand. Its chance is the normal
  `Security + Agility / 5 + Luck / 10`, modified by current Fatigue and reduced
  by the lock level. Attempting consumes one of the perk's uses even on
  failure; resting restores the allowance.
- Hands Like Keys reduces the lock level by half the player's modified
  Security on success, in addition to opening it.

### Short Blade Details

- Blade Tempo adds one stack per successful Short Blade hit. After four
  seconds without a hit, it loses one stack every four seconds rather than
  dropping the entire stack at once.
- Opening Strike becomes available again after that target leaves combat with
  the player. First Blood Lesson doubles only its flat Short Blade-based bonus,
  not the whole weapon hit.
- Vital Strike adds 3% of the current post-armor hit per existing stack, then
  adds the new stack. Changing targets clears the previous target's sequence.
- Bleed deals direct Health damage once per second equal to its current stack
  count. New hits add a stack and refresh the shared five-second duration.
- Red Silence marks the stack when it first reaches five. The following hit,
  not the fifth-stack hit, attempts one second of resistible Paralysis.

### Sneak Details

- Silenced Movement and Noiseless Haste calculate enough Speed to offset half
  or all of the game's normal Sneak movement multiplier. Neither offsets the
  sprint penalty.
- Opportunist is available once per target per combat encounter and requires
  the target to be unaware when hit. The bonus is based on damage remaining
  after normal armor resolution.
- Phantom starts only when the player newly enters Sneak while an actor is
  actively fighting them. Vanishing Point can gain its five-second extension
  once, only if all such combat targeting ends during the original
  three-second window.

### Speechcraft Details

- Compelling Voice's bonus is consumed by the next observed persuasion
  attempt, whether that attempt succeeds or fails. A new success prepares the
  next bonus.
- Conversation's Crown requires three successes without an intervening
  failure and can award its permanent +5 disposition only once per
  conversation.
- Read the Crowd reverses the normal disposition loss from failure. Recovery
  Line then prepares +10 Speechcraft only if disposition is below 30.
- Lingering Words and Remembered Grace replace their own previous bonus on the
  NPC rather than stacking repeatedly. Their duration uses in-game time.
- Commanding Presence works only while the NPC's Fight value is below 70. It
  converts a failed attempt into an equal positive gain. Voice of Office also
  doubles an already successful attempt. Uses reset when the in-game day
  changes.

## Console Commands

Core 2 currently has no Stealth-specific console commands.

The shared commands remain available:

- `luaperks menu`
- `luaperks respec`
- `luaperks dump`

See the Core 0 README for their full descriptions.

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
