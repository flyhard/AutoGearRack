# AutoGearRack v1 spec

Status: built as v1.0.0 (2026-11-17). Decisions come from Per's grilling in the project thread "Find Pawn-based auto-gear addon".

## Goal

A small glue addon for WoW Forever (Interface 16001, `_forever_`) that makes three addons work together:

- **AutoGear** picks and equips upgrades.
- **Pawn** (with Pawn Forever) supplies the stat weights AutoGear scores gear with, one scale per spec.
- **ItemRack** (Universal, or the ItemRack (Forever) port) keeps your saved sets current when AutoGear swaps in an upgrade.

The addon never equips anything itself. It configures AutoGear and edits ItemRack's saved sets.

## Dependencies

- Required at runtime: AutoGear, plus one of `ItemRack` (Universal, folder `ItemRack`) or `ItemRack_Forever`. Pawn is optional, and without it the Pawn features are inert.
- The TOC lists all four as `## OptionalDeps` so the addon loads after them. On `PLAYER_LOGIN` it checks what's present and prints a single line naming anything missing, then disables the missing parts.
- SavedVariablesPerCharacter: `AutoGearRackDB`.

## Glossary

- **Spec slot**: the talent group index 1 or 2 (`C_SpecializationInfo.GetActiveSpecGroup` / `GetActiveTalentGroup`). Not a named spec: AutoGear's `AutoGearDetectSpec()` returns `"None"` on Forever.
- **Set's spec**: ItemRack Universal stores it as `set.AssociatedSpec` (1|2|nil). ItemRack (Forever) stores it as `set.spec` (number, 0 or nil = none). Read both.
- **Main set**: a user ItemRack set (name doesn't start with `~`) that saves 10 or more of slots 1-19.
- **Situational set**: any other user set (mount, swim, fishing, zone).
- **AutoGear swap**: an equipment change caused by AutoGear's action queue.

## Behaviour

### 1. Pawn scale per spec (Q5, Q9, Q11)

- `AutoGearRackDB.scales[slot] = "<Pawn scale name>"`, set with `/agr scale <1|2> <scale name>`, validated with `PawnDoesScaleExist` (also accept the localized name via AutoGear's own `AutoGearGetPawnScaleName`).
- On login, and whenever the spec slot changes, AutoGearRack applies the slot's scale:
  - If Pawn is ready and the slot has a scale, set `AutoGearDB.UsePawn = true`, `AutoGearDB.OverridePawnScale = true` and `AutoGearDB.PawnScale = <name>`.
  - If Pawn is ready and the slot has no scale, set `AutoGearDB.OverridePawnScale = false` so AutoGear uses its class profile, and warn once per slot per session: "No Pawn scale for spec N: AutoGear is using its class profile. Use /agr scale N <name>."
- First run only (`AutoGearRackDB.pawnEnabledOnce`): if Pawn is ready and `UsePawn` is off, turn it on and say so. After that, if Per turns `UsePawn` off with `/ag pawn off`, AutoGearRack leaves it off and doesn't override scales (respect the choice; `/agr status` shows it).
- Pawn readiness: retry at 1-second intervals for up to 10 seconds after login (`PawnIsReady()`).

### 2. Detecting AutoGear swaps

- `hooksecurefunc("EquipCursorItem", fn)` and `hooksecurefunc("PickupInventoryItem", fn)`. In the hook, `debugstack(2)` containing `AddOns[/\\]AutoGear[/\\]` means AutoGear made the call. Record `touched[slot] = GetTime()` for slots 1-19.
  - AutoGear localises `PickupContainerItem` at load, but `EquipCursorItem` and `PickupInventoryItem` are globals at the call site (`AutoGear.lua`, equip action handler), so these two hooks are enough.
- Keep `snapshot[slot]` = `ItemRack.GetID(slot)` for slots 1-19, refreshed on `PLAYER_EQUIPMENT_CHANGED`.
- On `PLAYER_EQUIPMENT_CHANGED(slot)`, a change is an AutoGear swap when `touched[slot]` is less than 5 seconds old, or when the slot is 17 (off hand) and `touched[16]` is. Queue `{slot, old = snapshot[slot], new = ItemRack.GetID(slot)}`, then update the snapshot.
- Ignore any change while `ItemRack.SetSwapping` is set: that's ItemRack's own swap.

### 3. Updating sets (Q4, Q7, Q10)

Process the queue 1 second after the last change, out of combat, with `ItemRack.SetSwapping` clear and no fishing pole in the main hand (re-schedule otherwise; flush on `PLAYER_REGEN_ENABLED`).

Target sets:
- If `AutoGearRackDB.sets` (explicit list, from `/agr add <set>` and `/agr remove <set>`) isn't empty, use only those.
- Otherwise use every main set.
- In both cases, skip sets whose spec is set and doesn't match the active spec slot.

For each queued change and target set: if `set.equip[slot]` equals `old` exactly, or `ItemRack.SameID(set.equip[slot], old)` holds (same base item ID: saved IDs carry the player level, so an exact match fails after a level-up), set `set.equip[slot] = new`. Never touch `set.old`, `oldset`, icons or anything else. Slots the set doesn't save stay unsaved.

Afterwards, for each changed set: call `ItemRack.UpdateCurrentSet()` if it exists and fire `ItemRack:FireItemRackEvent("ITEMRACK_SET_SAVED", name)` when `FireItemRackEvent` exists (it lets Baganator and similar addons refresh). Print one line per set: `AutoGearRack: updated <set>: <old link> -> <new link>`.

### 4. Pausing AutoGear (Q6, Q12)

AutoGear is paused by setting `AutoGearDB.Enabled = false`, and resumed by restoring the value it had before the pause. Track `AutoGearRackDB.pausedByUs` so a pause never overrides Per's own `/ag disable`, and a `/reload` mid-pause still resumes.

Pause while either is true:
- A **situational set** is equipped: `ItemRackUser.CurrentSet` is a non-internal set that isn't a main set and `ItemRack.IsSetEquipped(name)` holds. Check on `PLAYER_EQUIPMENT_CHANGED`, after ItemRack swaps end and through the ItemRack event list, at most once per 0.5 seconds.
- A **spec switch is in progress**: from the spec-change event (`ACTIVE_TALENT_GROUP_CHANGED` / `PLAYER_SPECIALIZATION_CHANGED` / `PLAYER_TALENT_UPDATE`, whichever fires) until `ItemRack.SetSwapping` is clear, the new scale has been applied, and 2 seconds have passed.

On resume, call `AutoGearQueueScan()` if it exists so AutoGear re-evaluates with the right scale.

### 5. Slash commands (`/agr`, `/autogearrack`)

- `/agr` or `/agr status`: detected addons, active spec slot, the scale per slot, whether Pawn is on, the sets that will update (and why the others won't), and the pause state.
- `/agr scale <1|2> <name>` and `/agr scale <1|2> clear`
- `/agr add <set>`, `/agr remove <set>`, `/agr auto` (clears the explicit list)
- `/agr on` / `/agr off` turns the whole addon on or off (hooks stay, actions stop).
- `/agr debug` toggles verbose prints.

## Out of scope for v1

- CurseForge publishing and a release workflow (later, like LoreForeverHush).
- An options panel (slash commands only).
- Equipping anything itself, or editing AutoGear's scoring.
- Blizzard's Equipment Manager sets (Angleur's "Angleur" fishing set lives there and is left alone).

## Open checks (in game, don't change the design)

1. **Spec slots on Forever**: run `/dump C_SpecializationInfo.GetNumSpecGroups()` and `/dump GetActiveTalentGroup and GetActiveTalentGroup()`. If Forever has only one slot, the per-spec features degrade to a single scale (slot 1) and spec filtering is a no-op.
2. **Pawn Forever scale names**: `/agr status` should list them. AutoGear's own "[class]: [spec]" detection won't find them on Forever, which is why `/agr scale` exists.
3. **debugstack format**: confirm `debugstack(2)` names `Interface/AddOns/AutoGear/AutoGear.lua` (forward or back slashes) on this client. If it doesn't, fall back to a 1-second window after AutoGear prints "Equipping" via a hook on `AutoGearPrint`.

## Repo

`flyhard/AutoGearRack` (Per creates it empty). Layout like LoreForeverHush: `AutoGearRack.toc`, `AutoGearRack.lua`, `README.md`, `LICENSE` (MIT), `CHANGELOG.md`, `docs/spec.md`.

## Sources read (2026-11-17)

- AutoGear: github.com/BujuArena/AutoGear (UsePawn / OverridePawnScale / PawnScale options, Forever spec = "None", equip action handler).
- ItemRack Universal 4.58: github.com/Bl4ut0/ItemRack-Universal (`ItemRack.GetID`, `SameID`, `SetSwapping`, `RegisterExternalEventListener`, `AssociatedSpec`).
- ItemRack (Forever) 1.0.4: github.com/EfkaBz/ItemRack-Forever (`set.spec`, `ItemRack.GetActiveSpec`).
