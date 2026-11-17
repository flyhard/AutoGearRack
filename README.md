# AutoGearRack

A small glue addon for **WoW Forever** that makes three addons work together:

- **AutoGear** keeps picking and equipping upgrades, but scores them with **your Pawn scale for the spec you're in**.
- When AutoGear equips an upgrade, the **ItemRack** sets that held the old item get the new one, so swapping back to a set never puts old gear on.
- AutoGear is **paused** while a situational ItemRack set is on (mount, swim, zone sets) and while you switch spec, so it doesn't undo ItemRack's swaps.

AutoGearRack never equips anything itself.

## Needs

- [AutoGear](https://www.curseforge.com/wow/addons/autogear)
- [ItemRack Universal](https://www.curseforge.com/wow/addons/itemrack-universal) or ItemRack (Forever). Install only one of them.
- [Pawn](https://www.curseforge.com/wow/addons/pawn) 2.14.2 or newer, ideally with [Pawn Forever](https://www.curseforge.com/wow/addons/pawn-forever) for Forever stat weights.

## Setup

Open **Options > AddOns > AutoGearRack** (or type `/agr options`). The panel shows what's detected, a Pawn scale dropdown for each spec, and your ItemRack sets with whether each one follows AutoGear.

The same settings work from chat:

1. `/agr status` lists your Pawn scales, your ItemRack sets and what AutoGearRack will do with each.
2. Pick a scale per spec: `/agr scale 1 <scale name>` and, if you use dual spec, `/agr scale 2 <scale name>`.
3. In ItemRack, tick "Primary Spec" or "Secondary Spec" on sets that belong to one spec.

On first login AutoGearRack turns on AutoGear's "Use Pawn to evaluate upgrades". If you turn it off later with `/ag pawn off`, it stays off.

## Which sets get updated

By default, every **main set** (a set that saves 10 or more slots) that is tied to your active spec or to no spec. Sets with fewer slots count as situational and are left alone, and so are sets tied to your other spec.

To choose the sets yourself, tick "Pick the sets myself" in the panel, or use `/agr add <set>` and `/agr remove <set>`. Picking starts from the sets automatic mode would update, so nothing changes until you tick or untick a set. `/agr auto` goes back to automatic.

A set only changes in a slot it already saves, and only if that slot held the item AutoGear just replaced.

## Commands

| Command | Does |
|---|---|
| `/agr` | Status plus the command list |
| `/agr status` | Show what's detected, the scales, the sets that follow AutoGear and any pause |
| `/agr help` | List the commands |
| `/agr options` | Open the settings panel |
| `/agr scale <1\|2> <name>` | Use this Pawn scale in spec 1 or 2 (`clear` removes it) |
| `/agr add <set>` / `/agr remove <set>` | Pick the sets to update yourself |
| `/agr auto` | Update every main set of the active spec again |
| `/agr on` / `/agr off` | Turn AutoGearRack on or off |
| `/agr debug` | Verbose messages |

## Tests

`lua5.1 tests/run.lua` runs the logic against stubbed game, AutoGear, Pawn and ItemRack APIs.

## License

MIT
