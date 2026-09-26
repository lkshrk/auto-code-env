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
- savedvariables
- bigwigs
- ellesmere
---

# WoW addon development

The game (retail) runs on the Windows desktop (towerr). You work in the Coder workspace `dev/wow-addons` (template `dev`, preset `wow`). It cannot see the game; its only way into the game's AddOns folder is `wow-sync`. Run every command below inside that workspace through `litellm-tools_coder-coder_workspace_bash`; anything that may take longer than 20 seconds runs with the background-job pattern.

## Workflow for every change

1. Edit in the checkout under `~/<repo>`.
2. `luacheck <changed files>`; fix what it reports.
3. Check references (section below) and pick what to sync.
4. `wow-sync --dry-run <paths>`, read the plan and warnings.
5. `wow-sync <paths>`.
6. Tell the user exactly what went out (`<Name>-Dev` or real name) and ask them to `/reload` and report errors.
7. Only call it fixed after the user confirms in game.

## Tooling in the workspace

- `wow-sync` pushes addons to the game over SFTP (see below). `wow-sync --help` lists every option.
- `wow-luarc [dir]` writes `.luarc.json` so lua-language-server knows the WoW API (Lua 5.1, annotations under `~/.local/share/wow/wow-api/Annotations`).
- `luacheck` uses a generated default with every WoW global as read-only unless the repository has its own `.luacheckrc`.
- `~/.local/share/wow/wow-ui-source` is Blizzard's real FrameXML (branch `live`). Grep it for how Blizzard does something instead of guessing.

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
- Keep the default suffix `Dev`. Do not invent per-task suffixes such as `WOW_DEV_SUFFIX=1234Test`: the in-game helper knows only the suffix of the last sync, so mixed suffixes break the switch.
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

The helper addon `WowSync` switches the game to the dev copies at login: it disables each released addon that has a `-Dev` copy, enables the copy, and reloads once. In chat: `/wowsync status`, `/wowsync dev`, `/wowsync release`.

- After every sync the user has to `/reload` (or relog) for the new files to load.
- An addon whose `## Interface` is older than the game build is hidden unless "Load out of date AddOns" is ticked; keep `## Interface` current (retail 12.1 = `120100`).
- Lua errors are visible to the user only. Ask them to enable `/console scriptErrors 1` (or use BugSack if installed), reproduce, and paste the full error with its stack.

## Releases

Releases are built by the BigWigs packager in the addon repository's GitHub workflow, not from the workspace. Commit and push through `gh`/`git` in the workspace; the account is chosen by repository owner automatically.
