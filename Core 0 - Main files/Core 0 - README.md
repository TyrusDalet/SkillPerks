# SkillPerks Core 0 - Main Files

Core 0 contains the shared scripts, settings, actor bridges, assets, and plugin
records used by every SkillPerks perk pack. It does not add any purchasable
perks by itself.

## Requirements and Load Order

Core 0 requires:

- OpenMW 0.51 or later.
- ErnPerkFramework - Tyrus Revision/Overhaul.
- Inventory Extender.

Load the required Framework and Inventory Extender script packages before
`Core 0 SkillPerks.omwscripts`. Load every installed SkillPerks gameplay Core
after Core 0.

When updating SkillPerks, replace the complete Core 0 package together with
the gameplay Cores. Do not update only individual perk scripts: Combat,
Stealth, and Magic import shared Core 0 modules such as `debug.lua`, `hit.lua`,
`stat_tracker.lua`, and `magic_detection.lua`, and mismatched Core versions
will prevent the perk scripts from starting.

`SPerks.ESP` contains shared records used by the gameplay Cores, including
repair tools and supporting spell effects. Keep it active whenever SkillPerks
is installed.

## What Core 0 Provides

- The SkillPerks settings page.
- Shared perk progression and visibility options.
- Support for the classic and constellation perk menus.
- Compatibility shared by the Combat, Stealth, and Magic Cores.
- Reliable perk synchronization and respec support.
- Optional integration with compatible gameplay mods.
- One player-hit bridge shared by every gameplay Core. NPC and creature
  targets forward the authoritative hit once; PerkFramework then runs all
  subscribed perks and applies their combined health, fatigue, or magicka
  contribution as one resolved resource change.

## Standard Perk Structure

Every SkillPerks skill contains ten slots:

```text
A1 (25) -> A2 (50) -> A3 (75) -> A4 (100)
B1 (50) -> B2 (100)
A4 -> C1 (75) -> C2 (100)
  \-> D1 (75) -> D2 (100)
```

The number in parentheses is the required base skill value. C and D are
mutually exclusive mastery branches. Although C1 and D1 use the 75 skill tier,
they also require A4 and therefore cannot be acquired before reaching 100 in
the relevant skill.

Temporary skill bonuses do not satisfy acquisition requirements.

## Perk Visibility

The **Perk Visibility** setting controls how aggressively unavailable
SkillPerks are hidden in the classic perk menu:

1. Show every perk.
2. Show a skill's perks after that skill reaches 25.
3. Show perks up to the current skill tier. This is the default.
4. Show only perks whose chain path is currently reachable.
5. Show only perks whose complete requirements are currently satisfied.

The optional constellation menu displays the complete authored tree instead,
using node state to distinguish owned, available, unaffordable, and locked
perks.

## Debug Verbosity

SkillPerks debug output is controlled from its settings page:

- `0 - Off`: no diagnostic logging.
- `1 - Important`: major state changes and failures.
- `2 - Detailed`: perk decisions and useful testing state.
- `3 - Trace`: the most detailed diagnostic output for bug reports.

Normal player-facing perk notifications are independent of debug verbosity.

Every skill debug command also accepts a trailing `trace`. For example,
`luah2h debug trace` toggles live Hand-to-Hand activation and rejection
logging. These per-skill traces only print while verbosity is set to `3`, and
the same command turns that skill's trace off again.

## Shared Console Commands

Enter these commands directly into the normal OpenMW console:

- `luaperks menu` - opens the perk menu even when no perk points are available.
- `luaperks respec` - refunds and removes all Framework-managed player perks.
- `luaperks dump` - prints the persistent owned-perk list, acquisition order,
  requirements, costs, and resource information for diagnosis.

The commands are provided by ErnPerkFramework but are documented here because
they are the main entry points used with SkillPerks. A trailing `\` supplied
by some OpenMW console configurations is ignored.

## Optional Compatibility

Spell Framework Plus and N'Garde are supported but are not required. Install
them only if you want their own features.

## Credits

Copyright (C) 2026 Robbie Barker.

SkillPerks depends on ErnPerkFramework, Copyright (C) 2025 Erin Pentecost and
2026 Robbie Barker.

Inventory Extender supplies required inventory and UI integration.

N'Garde by Arrean provided reference and inspiration for charged attacks,
stagger, and knockdown support.
