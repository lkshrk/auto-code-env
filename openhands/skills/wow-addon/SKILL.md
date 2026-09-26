---
name: wow-addon
description: Develop, test and ship World of Warcraft addons from a Coder workspace. Use for any work on a WoW addon, a .toc file, SavedVariables, or when code has to reach the game on the Windows desktop for testing.
triggers:
- wow
- addon
- world of warcraft
- .toc
- wow-sync
- wowsync
- wow-check
- wow-errors
- savedvariables
- lua error
- bigwigs
- ellesmere
---

# WoW addon development

The game (retail) runs on the Windows desktop (towerr). You work in the Coder workspace `dev/wow-addons` (template `dev`, preset `wow`). It cannot see the game; its only way into the game's AddOns folder is `wow-sync`. Run every command below inside that workspace through `litellm-tools_coder-coder_workspace_bash`; anything that may take longer than 20 seconds runs with the background-job pattern.

## Workflow for every change

1. Before the first edit, run `wow-errors` to see what the game already reports for this addon.
2. Edit in the checkout under `~/<repo>`. Look up every game API you call or change with `wow-api` first.
3. `wow-check ~/<repo>/<AddonDir>` and fix every finding in code you touched. Do not sync while it reports new problems in your changes.
4. `wow-sync --dry-run --addon <Name> ~/<repo>`, read the plan and warnings.
5. `wow-sync --addon <Name> ~/<repo>`, from the same checkout you edited (first time for an installed addon: see below).
6. Verify: `rclone lsl wow:/<Name>/` must list every changed file with the local size (`wc -c`) and modification time. Only then say "synced". Tell the user which addons went out and ask them to `/reload` and try the change.
7. After they did, run `wow-errors` again and read the addon's state with `wow-sv`. Fix and repeat from step 3.
8. Only call it fixed when `wow-errors` is clean for the addon and the user confirms the behaviour in game.

## Tooling in the workspace

| Command | What it does |
|---|---|
| `wow-check [paths]` | `.toc` and XML lint (missing files, old `## Interface`), luacheck against every real WoW global, lua-language-server with the WoW annotations (deprecated or wrong API use, wrong argument counts, unknown fields). `--fast` skips the language server, `--pedantic` adds unused-variable noise. Exit code 1 means errors; warnings print but exit 0, so read the output. A `deprecated` finding names the call; look up its replacement with `wow-api`. |
| `wow-errors` | Lua errors the game caught (BugGrabber) in the current game session, with message, stack and count. `--all` for older sessions, `--match <addon>` to filter, `--locals` for the local variables, `--json`. |
| `wow-sv list` / `wow-sv show <Addon> [--key a.b.c]` | Reads SavedVariables from the game as JSON, e.g. `wow-sv show MyAddon --key MyAddonDB.profiles`. Read-only. The game writes them at `/reload`, logout or exit, not live. |
| `wow-api <name>` | Signature, return values and restrictions of a function or event from Blizzard's generated API docs. Partial names match; `--kind event`. No hit means the function does not exist in this game version. |
| `wow-sync` | Pushes addons to the game (see below). `wow-sync --help` lists every option. |
| `wow-luarc [dir]` | Writes `.luarc.json` for editor use of lua-language-server. |

- `~/.local/share/wow/wow-ui-source` is Blizzard's real FrameXML (branch `live`). Grep it for how Blizzard does something instead of guessing.
- `wow-errors` needs the BugGrabber addon (or BugSack, which ships it) enabled in the game. If it reports no BugGrabber data, ask the user to install it.
- Existing findings in code you did not touch are not your task; mention them only if they explain the bug you work on.

## Game version 12.x (Midnight)

The game is retail 12.1. Training data and most online examples are older; many of them no longer work.

- Deprecated global functions from 11.x are removed. Use the namespaced ones, for example `C_Spell.GetSpellInfo` (returns a table), `C_Spell.GetSpellCooldown`, `C_Spell.GetSpellTexture`, `C_SpellBook.GetNumSpellBookSkillLines`, `C_SpellBook.GetSpellBookSkillLineInfo`, `C_SpellBook.GetSpellBookItemName`, `C_SpellBook.IsSpellKnown`, `C_ActionBar.HasAction`, `C_AddOns.IsAddOnLoaded`, `C_AddOns.GetAddOnMetadata`, `GetMouseFoci` (returns a table).
- `COMBAT_LOG_EVENT_UNFILTERED` and `COMBAT_LOG_EVENT` are gone; registering them raises an error. There is no combat log parsing any more.
- Combat data (`UnitHealth`, `UnitName`, auras, casts, cooldowns and similar) is often a **secret value** in addon code. Addon code may store secrets, pass them to Lua functions and to the few C APIs that accept them (for example `StatusBar:SetValue`, `FontString:SetText`), and concatenate or `string.format` them. Comparing, boolean tests on secret booleans, arithmetic, `#`, using them as table keys and indexing them raise an immediate Lua error. A widget that received a secret returns secrets from its getters afterwards (`GetText`). Check with `issecretvalue(v)` and `canaccessvalue(v)`; `C_Secrets.*` and `C_RestrictedActions.IsAddOnRestrictionActive` tell when restrictions apply, the event `ADDON_RESTRICTION_STATE_CHANGED` when they change.
- `wow-api` shows `SecretArguments`/`SecretReturns` notes per function; read them before using a value in logic.
- Never assume an API from memory. If `wow-api` does not know it and `grep -rn` in `~/.local/share/wow/wow-ui-source` finds nothing, it does not exist.

### Patterns that work with secret values

Show combat data through widgets and curve or duration objects instead of computing with it:

| Need | Use |
|---|---|
| Health bar or percent | `UnitHealthPercent(unit, usePredicted, curve)` into `StatusBar:SetValue`; heal prediction via `CreateUnitHealPredictionCalculator()` |
| Cooldown swipe | `C_Spell.GetSpellCooldownDuration(spellID)` into `Cooldown:SetCooldownFromDurationObject(duration)`; no `start + duration - GetTime()` |
| Colour or alpha from a value | `C_CurveUtil.CreateColorCurve()` / `C_CurveUtil.CreateCurve()`; `Region:SetAlphaFromBoolean(value, ifTrue, ifFalse)`, `SetVertexColorFromBoolean` |
| Table that may hold secrets | `issecrettable(t)`, `hasanysecretvalues(t)`, `scrubsecretvalues(t)` (secrets become nil) |
| Is a restriction active | `C_Secrets.HasSecretRestrictions()`, `C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.X)`, `C_CombatLog.IsCombatLogRestricted()`; per spell `C_Secrets.ShouldSpellCooldownBeSecret`, `C_Secrets.GetSpellAuraSecrecy` |
| Addon messages | `C_ChatInfo.SendAddonMessage` fails in instance lockdown; check `C_ChatInfo.InChatMessagingLockdown()` and its `SendAddonMessageResult`, queue and send after `ENCOUNTER_END` |

### Replacing combat log parsing

| Old combat log use | Now |
|---|---|
| Damage and healing meters | `C_DamageMeter` (`IsDamageMeterAvailable`, `GetAvailableCombatSessions`, `GetCombatSessionFromID`) |
| Health changes, deaths | `UNIT_HEALTH` + `UnitHealthPercent`; `UnitIsDeadOrGhost(unit)` on that event |
| Auras applied or removed, dispels | `UNIT_AURA(unit, updateInfo)` + `C_UnitAuras.GetAuraDataByAuraInstanceID` or `AuraUtil.ForEachAura` |
| Casts, interrupts | `frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)`, `UNIT_SPELLCAST_SUCCEEDED`, `UNIT_SPELLCAST_INTERRUPTED` (payload has `interruptedBy`) |
| Boss abilities | `C_EncounterTimeline` (Blizzard's boss timeline) plus `ENCOUNTER_START`/`ENCOUNTER_END` |

Some combat log features have no replacement on purpose. Say so to the user instead of inventing a workaround.

## Debugging checklist

Start with `wow-errors`. When it is clean but something is wrong, walk the matching list:

- **Addon does nothing:** is it loaded and not "out of date" (`## Interface` 120100)? Are all `.toc` files present with exact case (`wow-check`)? Does the `ADDON_LOADED` handler compare against the name from `local addonName = ...` rather than a literal, which breaks under `--dev`? Did it rely on `COMBAT_LOG_EVENT_UNFILTERED`?
- **Nil data:** spell or item not cached yet (`C_Spell.RequestLoadSpellData` + `SPELL_DATA_LOAD_RESULT`, `C_Item.RequestLoadItemDataByID` + `ITEM_DATA_LOAD_RESULT`); SavedVariables read before `ADDON_LOADED`; unit does not exist. Zero or blank only in instances usually means secret values.
- **Blocked action or taint ("AddOn tried to call the protected function"):** no `SetScript` on Blizzard frames, use `HookScript` or `hooksecurefunc`; no `SetAttribute`, `SetPoint`, `Show`/`Hide` on secure frames while `InCombatLockdown()`, queue until `PLAYER_REGEN_ENABLED`; check `frame:IsForbidden()` before touching nameplates. For a trace, ask the user to run `/console taintLog 1`, reproduce, `/reload` and paste `Logs\taint.log`.
- **Frame not visible:** shown and parent visible (`IsVisible`), non-zero size, anchored (`ClearAllPoints` before re-anchoring), alpha, strata. The user can inspect with `/fstack`.
- **Settings not saved:** variable listed in `## SavedVariables`, global not local, defaults merged into the existing table instead of replacing it, only plain data stored. Verify with `wow-sv show` after the user's `/reload`.
- **Load order:** files run in `.toc` order; SavedVariables exist from `ADDON_LOADED`, player data from `PLAYER_LOGIN`.

## Getting code into the game

`wow-sync` installs each addon under its real name, replacing the copy in the game. That is the default; use it.

| Goal | Command |
|---|---|
| One addon or one module | `wow-sync --addon <Name> ~/<repo>` |
| Only what changed in git | `wow-sync --changed ~/<repo>` |
| Preview without writing | add `--dry-run` |
| Put the user's original release back | `wow-sync --restore <Name>` |

**The first sync of an addon the user has installed from elsewhere (WowUp, CurseForge) stops** with `refusing to sync <Name>: the game has a release copy`. Then ask the user once: "Replace your installed <Name> with the workspace version? The original is saved and `wow-sync --restore <Name>` brings it back." On yes, rerun the same command with `--replace-release`. `wow-sync` saves the release and its SavedVariables to `~/.local/share/wow/backup/<Name>/` first, marks its own copy, and never asks again for that addon until a WowUp update replaces it. Never pass `--replace-release` without that yes in this conversation. An addon with no copy in the game needs no flag.

Rules:

- "Sync" means a `wow-sync` run that wrote to `wow:`. Nothing else: not a `cp` into another directory (`~/EUI-wotlk`, `~/wt/*` and any second checkout are source trees, never the game), not a `--dry-run`, not a direct `rclone`. The game is always reachable through `wow-sync`; never tell the user you cannot reach it.
- Always pass explicit paths, and `--addon` unless you use `--changed`. Without paths `wow-sync` syncs every repository in `CODER_REPO_DIRS`, including ones for other game versions (the WotLK/Ascension `AutoGossip-WOTLK-Ascension`, `~/EUI-wotlk`), which must never reach the retail folder.
- Sync from the checkout you edited.
- After the sync, check `rclone lsl wow:/<Name>/` lists every changed file with its local size (`wc -c`). Only then tell the user it is synced, naming the addon.
- A WowUp update of the addon overwrites the synced copy. If the user reports the fix gone, sync again.
- Do not use `--dev`, `--off` or `--any-suffix` unless the user asks for a dev copy beside the release. `--dev` installs `<Name>-Dev` with renamed SavedVariables and needs the helper addon WowSync; it is for bigger rewrites only.

## In the game

- After every sync the user has to `/reload` (or relog) for the new files to load.
- If the AddOn list shows a synced addon disabled, an earlier `--dev` sync turned its release off; ask the user to enable it.
- An addon whose `## Interface` is older than the game build is hidden unless "Load out of date AddOns" is ticked; keep `## Interface` current (retail 12.1 = `120100`).
- Lua errors reach you through `wow-errors` once the user reloaded or logged out, because the game writes BugGrabber's data only then. Ask the user to `/reload` after reproducing, not to paste errors.

## Releases

Releases are built by the BigWigs packager in the addon repository's GitHub workflow, not from the workspace. Commit and push through `gh`/`git` in the workspace; the account is chosen by repository owner automatically.
