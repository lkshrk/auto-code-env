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
local function session()
  clock = clock + 120
  reloads, log = 0, {}
  for _, a in ipairs(addons) do a.loaded = a.enabled and not a.lod end
  dofile(modePath)
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

world({
  dev("SuiteBags-Dev", "SuiteBags", { "Suite-Dev" }),
  dev("Suite-Dev", "Suite"),
  { name = "Suite", enabled = true },
  { name = "SuiteBags", enabled = true },
  { name = "Other", enabled = true },
})
WowSyncDB = nil

check(session() == 1, "first login with the release active reloads")
check(not byName["Suite-Dev"].loaded and not byName["SuiteBags-Dev"].loaded, "dev copies never load beside the release")
check(not byName.Suite.enabled and not byName.SuiteBags.enabled, "releases are disabled")
check(byName.Other.enabled, "unrelated addons stay enabled")

check(session() == 0, "second login needs no reload")
check(byName["Suite-Dev"].loaded and byName["SuiteBags-Dev"].loaded, "dev copies load, dependents after their dependency")
check(not byName.Suite.loaded, "release stays unloaded in dev mode")
check(next(WowSyncDB.last.failed) == nil, "no load failures are reported")

SlashCmdList.WOWSYNC("release")
check(reloads == 1, "/wowsync release reloads")
check(byName.Suite.enabled and not byName["Suite-Dev"].enabled, "/wowsync release swaps enable states")
check(session() == 0 and byName.Suite.loaded and not byName["Suite-Dev"].loaded, "release mode loads only the release")

world({
  { name = "Old-Dev", enabled = true },
  { name = "Old", enabled = true },
  dev("Foo-Dev", "Foo"),
  dev("Foo-2154", "Foo"),
  { name = "Foo", enabled = false },
})
WowSyncDB = nil
check(session() == 1, "a legacy dev copy with an active release reloads")
check(not byName.Old.enabled and byName["Old-Dev"].enabled, "legacy copies still switch by suffix")
check(byName["Foo-Dev"].loaded and not byName["Foo-2154"].loaded and not byName["Foo-2154"].enabled, "only the first dev copy of a release loads")
check(WowSyncDB.last.failed["Foo-2154"] ~= nil, "the second copy is reported")

if failures > 0 then os.exit(1) end
print = io.write
print("PASS: WowSync never runs a dev copy beside its release\n")
