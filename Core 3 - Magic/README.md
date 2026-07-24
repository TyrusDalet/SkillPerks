# SkillPerks Core 3 - Magic

Requires SkillPerks Core 0, the overhaul ErnPerkFramework, and Inventory
Extender. Load those dependencies before this Core.

Core 3 adds complete perk trees for Alchemy, Alteration, Conjuration,
Destruction, Enchant, Illusion, Mysticism, Restoration, and Unarmored. Each
tree contains ten perks using the standard A1-A4, B1-B2, C1-C2, and D1-D2
structure. C and D are mutually exclusive branches and their second ranks
also require A4.

## Framework Integration

Normal player spell casts use ErnPerkFramework's shared skill-use dispatcher.
Actor-affecting damage, restoration, and damage conversion use the ordered
calculation and resource pipelines. Enchanter's Circuit contributes only its
own multiplier to the framework's Cast on Use and Constant Effect magnitude
channels, allowing FactionPerks and other mods to contribute independently.

Core 0's NPC and creature scripts report newly landed player spells back to
the correct player script. The same target-local bridge owns writes that
OpenMW does not permit from a player script, including Illusion attribute
theft, Conjuration servant bonuses, Destruction poison stacks, Mysticism
stagger state, and Soul Tether's death payout.

Alchemy and Enchant use inventory snapshots where OpenMW's skill-use payload
does not provide stable item details. This keeps potion preservation, brewing
batches, recharge reserve, and scroll preservation compatible with quick keys
and Inventory Extender.

## Constellation Display

The optional constellation menu places all nine skills in the Magic nebula of
the SkillPerks galaxy. Core 3 supplies authored normal and completed DDS
textures plus normalized node positions for every tree. Internal dependency
lines are suppressed because the routes already exist in the artwork;
cross-constellation dependencies remain available to the framework.

Completing every compatible node swaps the subdued constellation for its
blue-white completed version. The mutually exclusive blocked branch is not
required for completion.

## Engine-Sensitive Testing

OpenMW does not identify a summoned actor directly in the completed cast
event. Empowered Servants therefore snapshots nearby actors at summon start
and applies its bonus only to newly appearing creatures during the following
three seconds. Test this with multi-summon mods and scripted creature spawns.

Recharge events do not expose consistent soul and target-item fields across
supported UI paths. Charge Reserve measures actual charge gained during the
Recharge window and converts the detected excess into its shared pool.

Restoration overflow is measured from active player-cast Restore effects
against the actor's current missing resource. Test rapid multi-effect healing,
very short effects, and scripted stat changes alongside Ward of Delay.

Destruction's reflected-spell protection identifies an elemental effect
returning to the player with the player recorded as caster. Weather, night,
multi-effect spells, and reflection from third-party spell systems should be
tested explicitly.
