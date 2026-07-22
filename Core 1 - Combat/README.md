# SkillPerks Core 1 - Combat

Requires SkillPerks Core 0, the overhaul ErnPerkFramework, and Inventory
Extender. Load Core 0 before this Core.

## Constellation Display

When ErnPerkFramework's optional **Constellation Perk Menu** is enabled, each
Combat skill is displayed as a separate constellation on the pannable
SkillPerks galaxy page. Core 1 registers its own normalized node positions and
transparent DDS artwork for the Combat skill symbols; the framework does not
contain Combat-specific asset or category knowledge. Gold, blue, red, and
green paths identify the A, B, C, and D perk chains respectively, while each
clickable node is keyed directly to its perk ID.

Owned stars and the authored paths between consecutive owned perks brighten in
their chain colour. Combat suppresses the framework's generated dependency lines
inside each skill because those routes are already present in the DDS artwork;
dependencies added between separate constellations remain visible.

Hover a node for its name, flavour text, effects, cost, and current state. Hold
left mouse to acquire an available node, or hold right mouse on an owned node
to refund it and any dependent perks.

A skill symbol remains subdued until its tree is complete, then swaps to a
blue-white glowing version while preserving its branch colours. The completed
texture has the same dimensions and node alignment as the subdued texture. The
C and D paths are mutually exclusive, so owning either complete branch exempts
the blocked alternative and its descendant from the completion check.

The classic perk menu remains the default and is unaffected when constellation
display is disabled.
