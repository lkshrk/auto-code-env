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
4. Check references (section below) and pick what to sync.
5. `wow-sync --dry-run <paths>`, read the plan and warnings.
6. `wow-sync <paths>`.
7. Tell the user exactly what went out (`<Name>-Dev` or real name) and ask them to `/reload` and try the change.
8. After they did, run `wow-errors` again and read the addon's state with `wow-sv`. Fix and repeat from step 3.
9. Only call it fixed when `wow-errors` is clean for the addon and the user confirms the behaviour in game.

## Tooling in the workspace

| Command | What it does |
|---|---|
| `wow-check [paths]` | `.toc` and XML lint (missing files, old `## Interface`), luacheck against every real WoW global, lua-language-server with the WoW annotations (deprecated or wrong API use, wrong argument counts, unknown fields). `--fast` skips the language server, `--pedantic` adds unused-variable noise. Exit code 1 means errors; warnings print but exit 0, so read the output. A `deprecated` finding names the call; look up its replacement with `wow-api`. |
| `wow-errors` | Lua errors the game caught (BugGrabber) in the current game session, with message, stack and count. `--all` for older sessions, `--match <addon>` to filter, `--locals` for the local variables, `--json`. |
| `wow-sv list` / `wow-sv show <Addon> [--key a.b.c]` | Reads SavedVariables from the game as JSON, e.g. `wow-sv show MyAddon-Dev --key MyAddonDBDev.profiles`. Read-only. The game writes them at `/reload`, logout or exit, not live. |
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

- **Addon does nothing:** is it loaded and not "out of date" (`## Interface` 120100)? Are all `.toc` files present with exact case (`wow-check`)? Does the `ADDON_LOADED` handler compare against the name from `local addonName = ...` rather than a literal, which breaks under `-Dev`? Did it rely on `COMBAT_LOG_EVENT_UNFILTERED`?
- **Nil data:** spell or item not cached yet (`C_Spell.RequestLoadSpellData` + `SPELL_DATA_LOAD_RESULT`, `C_Item.RequestLoadItemDataByID` + `ITEM_DATA_LOAD_RESULT`); SavedVariables read before `ADDON_LOADED`; unit does not exist. Zero or blank only in instances usually means secret values.
- **Blocked action or taint ("AddOn tried to call the protected function"):** no `SetScript` on Blizzard frames, use `HookScript` or `hooksecurefunc`; no `SetAttribute`, `SetPoint`, `Show`/`Hide` on secure frames while `InCombatLockdown()`, queue until `PLAYER_REGEN_ENABLED`; check `frame:IsForbidden()` before touching nameplates. For a trace, ask the user to run `/console taintLog 1`, reproduce, `/reload` and paste `Logs\taint.log`.
- **Frame not visible:** shown and parent visible (`IsVisible`), non-zero size, anchored (`ClearAllPoints` before re-anchoring), alpha, strata. The user can inspect with `/fstack`.
- **Settings not saved:** variable listed in `## SavedVariables`, global not local, defaults merged into the existing table instead of replacing it, only plain data stored. Verify with `wow-sv show` after the user's `/reload`.
- **Load order:** files run in `.toc` order; SavedVariables exist from `ADDON_LOADED`, player data from `PLAYER_LOGIN`.

## Getting code into the game

Every addon is installed as `<Name>-Dev` beside the released copy by default: the `.toc` is renamed, the title gets `[DEV]`, and every SavedVariables name gets the suffix, so the dev copy never touches the user's real settings.

| Goal | Command |
|---|---|
| One addon or one module | `wow-sync ~/<repo>/<AddonDir>` |
| Everything in a repository | `wow-sync ~/<repo>` |
| Only what changed in git | `wow-sync --changed ~/<repo>` |
| Keep syncing on every save | `wow-sync --watch --changed ~/<repo>` (background job) |
| Only one named addon | `wow-sync --addon <Name> ~/<repo>` |
| Preview without writing | add `--dry-run` |
| Switch the game back to the released addons | `wow-sync --off` |

Rules:

- Always pass explicit paths. Without paths `wow-sync` syncs every repository in `CODER_REPO_DIRS`, including ones built for other game versions (for example the WotLK/Ascension `AutoGossip-WOTLK-Ascension`), which must never reach the retail folder.
- `wow-sync` is the only way into the AddOns folder. No direct `rclone` copies, no other transfer.
- Keep the default suffix `Dev`. Never set `WOW_DEV_SUFFIX` to anything else and never pass `--any-suffix`: a second dev copy of the same addon (`-Dev` and `-1234`) is a second addon hooking the same frames. `wow-sync` refuses other suffixes.
- Never sync with an empty suffix (under the real name, overwriting the user's released addon) unless the user asks for it or the reference check below requires it, and then only after the user says yes.
- Prefer a one-shot sync after each change over `--watch`; if the user wants `--watch`, run it as a background job and stop it when done.

## Addons that reference each other

A `-Dev` copy lives under a different folder name, and WoW finds addons only by folder name. Any reference by name breaks when one side is renamed and the other is not. Which side references which differs per addon, so check it for the addon you changed, in both directions, before syncing.

1. **What the changed addon references:** its `.toc` lines `## Dependencies`, `## RequiredDeps`, `## OptionalDeps`, `## LoadWith`, `## LoadManagers`, and in its Lua and XML: `C_AddOns.IsAddOnLoaded(...)`, `C_AddOns.LoadAddOn(...)`, `C_AddOns.EnableAddOn(...)`, `C_AddOns.GetAddOnMetadata(...)`, `Interface\AddOns\<Name>\` paths, and string comparisons against folder names.
2. **What references the changed addon:** the same patterns in every other addon of the repository that name it:
   ```sh
   grep -rnE --include='*.toc' --include='*.lua' --include='*.xml' '<ChangedName>([^A-Za-z0-9_]|$)' ~/<repo> | grep -v '/Libs/'
   ```
   Ask the user whether an addon outside the repository (installed separately in the game) depends on it; you cannot see those.
3. **Decide the set for one `wow-sync` run:**
   - Every addon that references a changed addon by name, or is referenced by name from one, and is itself changed or must see the dev behaviour: sync it in the same run. `wow-sync` rewrites dependency lines, `AddOns\<Name>\` paths and string literals that are exactly the name of another addon of the same run to the `-Dev` names.
   - A referenced addon that is unchanged and whose released version is fine stays out of the run. The `-Dev` copies keep pointing at its real name.
   - If an addon that cannot be synced (released, outside the repository) must find the changed one by name, a `-Dev` copy is invisible to it. Then install the changed addon under its real name, overwriting the released one: `WOW_DEV_SUFFIX= wow-sync --addon <Name> ~/<repo>`. That replaces the user's installed version; say so and get a yes first.
4. **Names built at runtime** (`"Core" .. module`, `name:match("^Core(.+)$")`, lookups by prefix) are not rewritten. If the code builds names, the `-Dev` rename cannot work for those addons; use the real name, with the user's consent.
5. Before the real run, run `wow-sync --dry-run` with the same arguments and read its warnings. Afterwards tell the user which addons went out as `-Dev` and which references stayed on released copies.

## In the game

Dev copies are `LoadOnDemand`, so the game never starts one on its own. The helper addon `WowSync` loads them. At the first login after a sync it switches only the addons of that sync: disables their releases for all characters, enables the dev copies, and reloads once if a release was active. After that it never changes enable states: a dev copy the user turned off in the AddOn list stays off, and a dev copy whose release is also enabled is not loaded (reported, nothing switched). A dev copy and its release never run in the same session, because two copies hooking the same frames freeze the game at login. To bring a dev copy back after the user turned it off, sync it again or ask the user to run `/wowsync dev`. In chat: `/wowsync status`, `/wowsync dev`, `/wowsync release`. What the helper did at the last login (loaded, blocked by an enabled release, failed with reason) is in `wow-sv show WowSync --key WowSyncDB.last`; read it when the user says a dev copy did not show up.

Because the helper loads dev copies during its own startup, an addon that expects to load before others or checks `IsAddOnLoaded` of a released sibling at file load may behave differently as a dev copy; say so when that is a possible cause.

- After every sync the user has to `/reload` (or relog) for the new files to load.
- An addon whose `## Interface` is older than the game build is hidden unless "Load out of date AddOns" is ticked; keep `## Interface` current (retail 12.1 = `120100`).
- Lua errors reach you through `wow-errors` once the user reloaded or logged out, because the game writes BugGrabber's data only then. Ask the user to `/reload` after reproducing, not to paste errors.

## Releases

Releases are built by the BigWigs packager in the addon repository's GitHub workflow, not from the workspace. Commit and push through `gh`/`git` in the workspace; the account is chosen by repository owner automatically.
