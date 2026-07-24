# SkillPerks Core 2 - Stealth

Requires SkillPerks Core 0, Core 1, the overhaul ErnPerkFramework, and Inventory
Extender. Load those dependencies before this Core.

## Constellation Display

When ErnPerkFramework's optional **Constellation Perk Menu** is enabled, each
Stealth skill is displayed as a separate constellation on the pannable
SkillPerks galaxy page, grouped with the others inside its Stealth nebula. Core
2 supplies authored constellation textures and normalized node positions based
on each Stealth skill symbol; the framework does not contain Stealth-specific
asset or category knowledge.

Hover a node for its name, flavour text, effects, cost, and current state. Hold
left mouse to acquire an available node, or hold right mouse on an owned node
to refund it and any dependent perks.

Each acquired node receives a restrained highlight in its chain colour. Core 2
does not add progressive connection overlays: the C and D routes already visibly
begin at A4 in the authored texture and keep their separate aggression and
control colours. Internal generated dependency lines are hidden, while
cross-constellation dependencies remain available to the framework.

Completing every compatible node swaps the subdued skill symbol for a paired
blue-white glowing texture. The completion asset preserves the same node
alignment and branch colours, but dims the routes so the completed symbol reads
first. The mutually exclusive blocked branch is not required for completion.

The classic perk menu remains the default and is unaffected when constellation
display is disabled.

## Runtime Integration

Core 2 routes outgoing player hits through the Core 0 NPC/creature bridge.
This keeps Acrobatics, Sneak, Light Armor, Marksman, Short Blade, and
Hand-to-Hand effects reliable even though OpenMW normally delivers the useful
hit payload in the struck actor's local script. Extra health and fatigue damage
then uses ErnPerkFramework's shared direct-resource calculations.

Security combines Inventory Extender's selected tool with Core 0's global
activation handler. This identifies the exact lock or trap, distinguishes
success from failure, keeps Pattern Recognition scoped to one lock, and gives
Master Locksmith a real empty-hand activation with limited uses per rest.

Mercantile modifies the merchant rather than substituting generic player skill
bonuses. Sharp Eye and Silver Tongue alter the current merchant, Market
Knowledge adjusts Inventory Extender's live buy/sell offer, and Read the Room
detects a bribe from its simultaneous gold and disposition change.

Speechcraft tracks disposition changes during the active conversation. These
changes drive next-attempt bonuses, failure protection, consecutive-success
rewards, timed Lingering Words disposition, and Commanding Presence's daily
forced outcomes.

## Engine Boundaries

OpenMW does not expose a pre-write lockpick/probe durability callback. Tool
preservation is applied immediately after condition changes; a tool already
destroyed by spending its final use cannot be recovered.

OpenMW also does not expose the persuasion action type or its roll before the
dialogue UI applies the result. Speechcraft therefore identifies attempts from
non-zero disposition changes. Scripted disposition changes made during an open
conversation can be indistinguishable from persuasion and should be checked
when testing dialogue-heavy mods.
