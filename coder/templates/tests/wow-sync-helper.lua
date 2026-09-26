-- Plays login sessions through the generated WowSync helper against a mocked C_AddOns.
local helperPath, modePath = arg[1], arg[2]

local clock = 1000
local addons, byName, reloads, log

local function world(list)
  addons, byName = list, {}
  for _, a in ipairs(list) do
    a.meta, a.deps = a.meta or {}, a.deps or {}
    byName[a.name] = a
  end
end

local function find(x)
  return type(x) == "number" and addons[x] or byName[x]
end

C_AddOns = {
  GetNumAddOns = function() return #addons end,
  GetAddOnInfo = function(x) local a = find(x) return a.name, a.name, "", a.enabled, a.enabled and "" or "DISABLED" end,
  GetAddOnMetadata = function(x, key) local a = find(x) return a.meta[key] end,
  DoesAddOnExist = function(x) return find(x) ~= nil end,
  IsAddOnLoaded = function(x) local a = find(x) return a.loaded, a.loaded end,
  GetAddOnEnableState = function(x) return find(x).enabled and 2 or 0 end,
  EnableAddOn = function(x) find(x).enabled = true end,
  DisableAddOn = function(x) find(x).enabled = false end,
  LoadAddOn = function(x)
    local a = find(x)
    if not a.enabled then return false, "DISABLED" end
    for _, dep in ipairs(a.deps) do
      if not find(dep).loaded then return false, "DEP_MISSING" end
    end
    a.loaded = true
    return true
  end,
}
Enum = { AddOnEnableState = { None = 0 } }
UnitName = function() return "Tester" end
time = function() return clock end
C_Timer = { After = function(_, fn) fn() end }
ReloadUI = function() reloads = reloads + 1 end
print = function(msg) log[#log + 1] = msg end
SlashCmdList = {}

local frame
CreateFrame = function()
  frame = { events = {} }
  function frame:RegisterEvent(e) self.events[e] = true end
  function frame:UnregisterEvent(e) self.events[e] = nil end
  function frame:SetScript(_, fn) self.handler = fn end
  return frame
end

-- A new session: the client loads every enabled, not load-on-demand addon before WowSync runs.
local stamp = 0
local function session(sync)
  clock = clock + 120
  reloads, log = 0, {}
  for _, a in ipairs(addons) do a.loaded = a.enabled and not a.lod end
  if sync then
    stamp = stamp + 1
    WowSyncMode, WowSyncStamp, WowSyncAddons = sync.mode or "dev", tostring(stamp), sync.addons
  end
  loadfile(helperPath)("WowSync")
  frame.handler(frame, "ADDON_LOADED", "WowSync")
  frame.handler(frame, "PLAYER_LOGIN")
  return reloads
end

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  end
end

local function dev(name, release, deps)
  return { name = name, lod = true, enabled = false, deps = deps, meta = { ["X-WowSync-Release"] = release, ["X-WowSync-Load"] = "1" } }
end

-- The generated Mode.lua names the dev copies of its sync.
WowSyncAddons = nil
dofile(modePath)
check(type(WowSyncAddons) == "table" and #WowSyncAddons > 0, "Mode.lua lists the synced dev copies")

world({
  dev("SuiteBags-Dev", "SuiteBags", { "Suite-Dev" }),
  dev("Suite-Dev", "Suite"),
  dev("Mine-Dev", "Mine"),
  { name = "Suite", enabled = true },
  { name = "SuiteBags", enabled = true },
  { name = "Mine", enabled = true },
  { name = "Other", enabled = true },
})
WowSyncDB = nil
local synced = { addons = { "SuiteBags-Dev", "Suite-Dev" } }
local function session_same() return session(nil) end

check(session(synced) == 1, "first login after a sync with the release active reloads")
check(not byName["Suite-Dev"].loaded and not byName["SuiteBags-Dev"].loaded, "dev copies never load beside the release")
check(not byName.Suite.enabled and not byName.SuiteBags.enabled, "releases of the synced addons are disabled")
check(byName.Mine.enabled and not byName["Mine-Dev"].enabled, "addons outside the sync keep their state")

check(session_same() == 0, "second login needs no reload")
check(byName["Suite-Dev"].loaded and byName["SuiteBags-Dev"].loaded, "dev copies load, dependents after their dependency")

-- The user turns a dev copy off and the release back on in the AddOn list.
byName["SuiteBags-Dev"].enabled, byName.SuiteBags.enabled = false, true
for _ = 1, 3 do check(session_same() == 0, "a later login does not reload") end
check(not byName["SuiteBags-Dev"].enabled and not byName["SuiteBags-Dev"].loaded, "a dev copy disabled by hand stays disabled")
check(byName.SuiteBags.enabled and byName.SuiteBags.loaded, "a release enabled by hand stays enabled")
check(byName["Suite-Dev"].loaded, "the other dev copy keeps loading")

-- Both enabled by hand: nothing is switched, the dev copy just does not load.
byName["Mine-Dev"].enabled = true
check(session_same() == 0, "a conflict does not reload")
check(byName.Mine.loaded and not byName["Mine-Dev"].loaded and byName["Mine-Dev"].enabled, "dev copy is blocked, states untouched")
check(WowSyncDB.last.blocked["Mine-Dev"] ~= nil, "the blocked copy is reported")

-- A new sync of one addon switches only that addon.
byName["Mine-Dev"].enabled = false
check(session({ addons = { "Mine-Dev" } }) == 1, "a new sync of an active release reloads")
check(byName["Mine-Dev"].enabled and not byName.Mine.enabled, "the synced addon is switched")
check(not byName["SuiteBags-Dev"].enabled and byName.SuiteBags.enabled, "earlier manual choices survive a new sync")

SlashCmdList.WOWSYNC("release")
check(not byName["Suite-Dev"].enabled and not byName["Mine-Dev"].enabled, "/wowsync release disables every dev copy")
check(byName.Suite.enabled and byName.Mine.enabled, "/wowsync release enables every release")
check(session_same() == 0 and byName.Suite.loaded and not byName["Suite-Dev"].loaded, "release mode loads only releases")

world({
  { name = "Old-Dev", enabled = false },
  { name = "Old", enabled = true },
  dev("Foo-Dev", "Foo"),
  dev("Foo-2154", "Foo"),
  { name = "Foo", enabled = false },
})
WowSyncDB = nil
session({ addons = { "Foo-2154" } })
check(byName["Foo-2154"].enabled and not byName["Foo-Dev"].enabled, "switching a copy disables other copies of the same release")
SlashCmdList.WOWSYNC("dev")
check(not byName.Old.enabled and byName["Old-Dev"].enabled, "/wowsync dev also switches suffix-only copies")
byName["Foo-Dev"].enabled = true
session_same()
check((byName["Foo-Dev"].loaded and 1 or 0) + (byName["Foo-2154"].loaded and 1 or 0) == 1, "only one dev copy of a release loads")

if failures > 0 then os.exit(1) end
print = io.write
print("PASS: WowSync respects manual enable states and never runs a dev copy beside its release\n")
