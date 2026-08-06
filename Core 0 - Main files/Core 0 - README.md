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

SkillPerks records its installed version in each save. After an update, Core 0
automatically asks PerkFramework to refund and repurchase every owned perk in
its original acquisition order. This reapplies updated perk effects without
requiring the player to enter `luaperks reload` manually.

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
A3 -> C1 (75) --+-> C2 (100)
  \-> D1 (75) --+-> D2 (100)
             A4 -+
```

The number in parentheses is the required base skill value. C and D are
mutually exclusive specialisation branches. C1 or D1 becomes available after
A3 at skill 75. Its final upgrade still requires both the first branch perk and
A4, so C2 and D2 remain mastery perks.

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
- `3 - Trace`: full, ordered perk execution traces for explicitly selected
  skills.

Normal player-facing perk notifications are independent of debug verbosity.

Every skill debug command also accepts `trace`, `trace on`, `trace off`, or
`trace status`. For example, `luah2h debug trace on` enables live
Hand-to-Hand diagnostics. These per-skill traces only print while verbosity is
set to `3`.

A level-3 trace follows one activation through ordered stages. It records the
trigger, every eligibility gate and rejection reason, input values, arithmetic,
random rolls, queued output, target-local processing, and global dynamic-spell
application acknowledgement where those stages apply. Passive and polled perks
report only when their calculated state changes, preventing identical
frame-by-frame noise.

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

Spell Framework Plus, Spellforge, and N'Garde are supported but are not
required. Spellforge spells cast by the player use the same Magic-perk source
rules as ordinary and custom spells; abilities, enchanted items, scrolls, and
scripted secondary effects remain excluded unless a perk explicitly permits
them. Install these optional mods only if you want their own features.

Tamriel_Data's Banking and Stock Exchange frameworks are also optional.
Mercantile's Golden Measure recognizes documented bank deposits, outstanding
loans, share counts, and current share prices when those systems are present;
without them, the perk simply uses carried gold.

## Credits

Copyright (C) 2026 Robbie Barker.

SkillPerks depends on ErnPerkFramework, Copyright (C) 2025 Erin Pentecost and
2026 Robbie Barker.

Inventory Extender supplies required inventory and UI integration.

N'Garde by Arrean provided reference and inspiration for charged attacks,
stagger, and knockdown support.
