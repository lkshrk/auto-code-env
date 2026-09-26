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

The game runs on the Windows desktop (towerr). You work in a Coder workspace on the `dev` template with the `wow` preset; it cannot see the game, it can only push files into the game's AddOns folder with `wow-sync`. All commands below run inside that workspace through `litellm-tools_coder-coder_workspace_bash`; anything that may take longer than 20 seconds runs with the background-job pattern.

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

Keep the default suffix `Dev`. Do not invent per-task suffixes such as `WOW_DEV_SUFFIX=1234Test`: the in-game helper knows only the suffix of the last sync, so mixed suffixes break the switch. Never sync with an empty suffix (under the real name, overwriting the user's released addon) unless the user asks for it or the suite rule below requires it.

## Addon suites: parent and child addons

Many addons are several addons that depend on each other by folder name (`## Dependencies: Core` in a module's `.toc`, `C_AddOns.IsAddOnLoaded("CoreBags")`, `Interface\AddOns\Core\media\...`). A `-Dev` copy is a different folder name, so references between them must stay consistent:

- **Changed only a child module:** sync just that module. Its `-Dev` copy keeps depending on the released parent. Correct as long as the parent is unchanged.
- **Changed the parent, or parent and children together:** sync the parent and all its children in one run (`wow-sync ~/<repo>`, or several paths in one command). `wow-sync` then rewrites dependency lines, `AddOns\<Name>\` paths and string literals that name another addon of the same run to the `-Dev` names, so the whole suite runs as `-Dev` against itself.
- **Changed only the parent but the children must stay released:** a `-Dev` parent would never be loaded by the released children. Either sync the children too (previous bullet), or install the parent directly over the released one with `WOW_DEV_SUFFIX= wow-sync --addon <Parent> ~/<repo>`. The latter overwrites the user's released parent; say so and get a yes first. `wow-sync` prints a warning when a parent goes out as `-Dev` while its nested modules stay released.

Names built at runtime (`"Core" .. module`, `name:match("^Core(.+)$")`) are not rewritten. If the code does that, sync the suite under its real name instead, with the user's consent.

## In the game

The helper addon `WowSync` switches the game to the dev copies at login: it disables each released addon that has a `-Dev` copy, enables the copy, and reloads once. In chat: `/wowsync status`, `/wowsync dev`, `/wowsync release`.

- After every sync the user has to `/reload` (or relog) for the new files to load.
- An addon whose `## Interface` is older than the game build is hidden unless "Load out of date AddOns" is ticked; keep `## Interface` current (retail 12.1 = `120100`).
- Lua errors are visible to the user only (BugSack/BugGrabber if installed). After a sync, ask the user to reload and paste the error text; do not claim a fix works until they confirm.

## Releases

Releases are built by the BigWigs packager in the addon repository's GitHub workflow, not from the workspace. Commit and push through `gh`/`git` in the workspace; the account is chosen by repository owner automatically.
