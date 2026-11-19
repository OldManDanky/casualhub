-- Offline smoke tests for Casual Hub. Usage (from the repo root):  lua5.1 tests/run.lua [scenario] [savedFile]
-- With no arguments it runs every scenario, each in a fresh Lua process (see tests/run.sh).
package.path = "tests/?.lua;" .. package.path
local Stub = require("wow_stub")

local ADDON_DIR = "addons/CasualHub"
local scenario, savedFile = arg[1], arg[2]

local failures = 0
local function check(cond, label)
    if cond then
        print("  ok   " .. label)
    else
        failures = failures + 1
        print("  FAIL " .. label)
    end
end

local function contains(haystack, needle)
    return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

local function printedContains(needle)
    for _, msg in ipairs(Stub.printed) do
        if contains(msg, needle) then return true end
    end
    return false
end

local function boot(env, saved)
    Stub.install(env)
    if saved then
        CasualHubDB = saved.CasualHubDB
        CasualHubCharDB = saved.CasualHubCharDB
    end
    local ns = Stub.loadToc(ADDON_DIR, "CasualHub")
    if env and env.beforeLoad then env.beforeLoad(ns) end
    Stub.fire("ADDON_LOADED", "SomeOtherAddon")
    Stub.fire("ADDON_LOADED", "CasualHub")
    Stub.fire("PLAYER_LOGIN")
    Stub.fire("PLAYER_ENTERING_WORLD", true, false)
    Stub.runTimers()
    return ns
end

local function saveTo(path)
    Stub.fire("PLAYER_LOGOUT")
    local f = assert(io.open(path, "w"))
    f:write("CasualHubDB = ", Stub.serialize(CasualHubDB), "\nCasualHubCharDB = ", Stub.serialize(CasualHubCharDB), "\n")
    f:close()
end

local function loadSaved(path)
    local env = {}
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    chunk()
    return env
end

local function reportGlobals()
    -- Optional APIs the code probes on purpose; anything else read-but-undefined is suspicious.
    local expected = { SettingsPanel = true, CasualHubDB = true, CasualHubCharDB = true, CasualHubMinimapButton = true }
    local unexpected = {}
    for name in pairs(Stub.missingGlobals) do
        if not expected[name] then unexpected[#unexpected + 1] = name end
    end
    table.sort(unexpected)
    check(#unexpected == 0, "no unexpected undefined globals" ..
        (#unexpected > 0 and (": " .. table.concat(unexpected, ", ")) or ""))
end

local function noErrors(CH)
    local errs = {}
    for _, e in ipairs(CH.Log.entries) do
        if e.level == "error" then errs[#errs + 1] = e.msg end
    end
    check(#errs == 0, "no logged errors" .. (#errs > 0 and (":\n      " .. table.concat(errs, "\n      ")) or ""))
end

local scenarios = {}

scenarios.fresh = function()
    local CH = boot()
    check(CH.ready, "core ready after PLAYER_LOGIN")
    check(CH.Compat.isForever, "detects Forever (project 18)")
    check(CasualHubDB and CasualHubDB.schemaVersion == 1, "database created at schema 1")
    check(CH.Modules:IsRunning("Dashboard") and CH.Modules:IsRunning("Settings"), "Dashboard and Settings running")
    check(CH.Identity:PlayerKey() == "Ghazneth Strongbow", "player key is full First Last name")
    check(CH.Identity:Normalize("Ghazneth-Strongbow") == "Ghazneth Strongbow", "First-Last normalizes to First Last")
    check(CH.Identity:IsPlayer("Ghazneth Strongbow") and not CH.Identity:IsPlayer("Ghazneth"), "first name alone is not the player")
    check(CH.Identity:GuildKey() == "Da Filthy Casuals@CAMWOWUS2Realm7PvE", "guild key")
    check(CH.Permissions:PlayerRole() == "guildmaster", "rank 0 is guildmaster")
    check(CH.Permissions:Can("postAnnouncement"), "guildmaster can post announcements")
    check(Stub.settingsCategory ~= nil, "registered Blizzard Settings category")
    check(CasualHubMinimapButton ~= nil and CasualHubMinimapButton:IsShown(), "minimap button shown")

    SlashCmdList.CASUALHUB("")
    check(CasualHubMainFrame:IsShown(), "/chub opens the window")
    check(CH.UI.currentPage == "dashboard", "dashboard is the first page")
    local dash = CH.UI.pageFrames.dashboard
    check(contains(dash.guildCard.body:GetText(), "Ghazneth Strongbow"), "dashboard shows the player")
    check(contains(dash.guildCard.body:GetText(), "Online: |cffffffff5|r of 55"), "dashboard shows online count")
    check(dash.motdCard.body:GetText() == "Raid Friday!", "dashboard shows MOTD")
    check((Stub.rosterRequests or 0) >= 1, "dashboard requested a roster refresh")

    for _, entry in ipairs(CH.NAVIGATION) do
        CH.UI:SelectPage(entry.id)
        check(CH.UI.currentPage == entry.id and CH.UI.pageFrames[entry.id]:IsShown(), "page " .. entry.id .. " opens")
    end
    check(not CH.UI.pageFrames.dashboard:IsShown(), "previous page hidden")
    check(CH.UI.navButtons.members.badge:IsShown() and not CH.UI.navButtons.settings.badge:IsShown(),
        "'soon' badge only on unbuilt sections")

    local page = CH.UI.pageFrames.settings
    page.scale.slider:SetValue(1.2)
    check(math.abs(CH.Settings:Get("scale") - 1.2) < 1e-9 and math.abs(CasualHubMainFrame:GetScale() - 1.2) < 1e-9,
        "scale slider commits and rescales the window")
    page.minimap:SetChecked(false)
    page.minimap:RunScript("OnClick")
    check(CH.Settings:Get("minimap.show") == false and not CasualHubMinimapButton:IsShown(), "minimap checkbox hides the button")
    page.lock:SetChecked(true)
    page.lock:RunScript("OnClick")
    check(CH.Settings:Get("lockWindow") == true and not CasualHubMainFrame.grip:IsShown(), "lock hides resize grip")
    local dashCheck
    for _, cb in ipairs(page.moduleChecks) do if cb.module.name == "Dashboard" then dashCheck = cb end end
    check(dashCheck ~= nil, "Dashboard listed as a toggleable module")
    dashCheck:SetChecked(false)
    dashCheck:RunScript("OnClick")
    check(CH.Settings:IsModuleEnabled("Dashboard") == false and page.reloadButton:IsShown(), "disabling a module offers a reload")
    dashCheck:SetChecked(true)
    dashCheck:RunScript("OnClick")
    check(CH.Settings:IsModuleEnabled("Dashboard") and CasualHubDB.settings.modules.Dashboard == nil,
        "re-enabling removes the opt-out")
    dashCheck:SetChecked(false)
    dashCheck:RunScript("OnClick")  -- leave disabled for the persistence scenario

    CasualHubMainFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -80)
    CasualHubMainFrame.__points = { { "TOPLEFT", UIParent, "TOPLEFT", 120, -80 } }
    CH.Settings:Set("window.point", "TOPLEFT"); CH.Settings:Set("window.relativePoint", "TOPLEFT")
    CH.Settings:Set("window.x", 120); CH.Settings:Set("window.y", -80)

    SlashCmdList.CASUALHUB("diag")
    check(CasualHubCopyDialog and contains(CasualHubCopyDialog.edit:GetText(), "Modules:"), "/chub diag shows the report")
    check(contains(CasualHubCopyDialog.edit:GetText(), "[Forever]"), "diagnostics identify Forever")
    SlashCmdList.CASUALHUB("version")
    check(printedContains("0.1.0-alpha"), "/chub version prints the version")
    SlashCmdList.CASUALHUB("bogus")
    check(printedContains("unknown command 'bogus'"), "unknown command reported")
    SlashCmdList.CASUALHUB("help")
    check(printedContains("/chub diag"), "/chub help lists commands")
    SlashCmdList.CASUALHUB("settings")
    check(CH.UI.currentPage == "settings", "/chub settings opens a page")
    SlashCmdList.CASUALHUB("")
    check(not CasualHubMainFrame:IsShown(), "/chub again closes the window")
    CasualHub_OnAddonCompartmentClick("CasualHub", "LeftButton")
    check(CasualHubMainFrame:IsShown(), "addon compartment click opens the window")

    noErrors(CH)
    reportGlobals()
    saveTo(savedFile)
end

scenarios.persisted = function()
    local saved = loadSaved(savedFile)
    local CH = boot(nil, saved)
    check(math.abs(CH.Settings:Get("scale") - 1.2) < 1e-9, "scale persisted")
    check(CH.Settings:Get("minimap.show") == false, "minimap setting persisted")
    check(CasualHubMinimapButton == nil, "minimap button not created when hidden")
    check(CH.Settings:Get("window.x") == 120 and CH.Settings:Get("window.point") == "TOPLEFT", "window position persisted")
    check(CH.Modules:Get("Dashboard").state == "disabled", "disabled module stays disabled")
    SlashCmdList.CASUALHUB("")
    check(CH.UI.currentPage == "settings", "with Dashboard disabled the window opens on Settings")
    local p = { CasualHubMainFrame:GetPoint(1) }
    check(p[1] == "TOPLEFT" and p[4] == 120 and p[5] == -80, "window restored at saved position")
    check(math.abs(CasualHubMainFrame:GetScale() - 1.2) < 1e-9, "window restored at saved scale")
    noErrors(CH)
    reportGlobals()
end

scenarios.corrupt = function()
    local CH = boot(nil, { CasualHubDB = { schemaVersion = "x", settings = { scale = "big", minimap = 5, extra = 1 },
        diagnostics = 7 }, CasualHubCharDB = "nonsense" })
    check(CH.ready, "starts despite corrupt saved data")
    check(CH.Settings:Get("scale") == 1.0, "invalid scale reset to default")
    check(CH.Settings:Get("minimap.show") == true, "invalid minimap table rebuilt")
    check(CasualHubDB.settings.extra == 1, "unknown settings kept for forward compatibility")
    check(CasualHubDB.schemaVersion == 1 and type(CasualHubCharDB) == "table", "both databases repaired")
    local warned = false
    for _, e in ipairs(CH.Log.entries) do if e.level == "warn" and contains(e.msg, "reset invalid settings") then warned = true end end
    check(warned, "repairs logged")
    noErrors(CH)
end

scenarios.newer_schema = function()
    local CH = boot(nil, { CasualHubDB = { schemaVersion = 99, settings = {} }, CasualHubCharDB = { schemaVersion = 99 } })
    check(CH.Store.readOnly, "newer schema makes storage read-only")
    CH.Store:RegisterNamespace("test", "account")
    local ok, why = CH.Store:Put("test", "a", { x = 1 })
    check(not ok and why == "read-only", "writes refused")
    check(CasualHubDB.schemaVersion == 99, "newer data left untouched")
end

scenarios.store = function()
    local CH = boot()
    CH.Store:RegisterNamespace("acct", "account")
    CH.Store:RegisterNamespace("mine", "char")
    CH.Store:RegisterNamespace("guildy", "guild")
    local seen
    CH.Events:Subscribe("STORE_CHANGED", "test", function(ns, key) seen = ns .. ":" .. key end)
    check(CH.Store:Put("acct", "k", { v = 1 }) and CH.Store:Get("acct", "k").v == 1, "account record round-trip")
    check(seen == "acct:k", "STORE_CHANGED published")
    check(CH.Store:Put("mine", "k", { v = 2 }) and CasualHubCharDB.data.mine.k.v == 2, "char record stored per character")
    check(CH.Store:Put("guildy", "k", { v = 3 })
        and CasualHubDB.data.guilds["Da Filthy Casuals@CAMWOWUS2Realm7PvE"].guildy.k.v == 3, "guild record scoped to guild key")
    CH.Store:Delete("acct", "k")
    check(CH.Store:Get("acct", "k") == nil, "delete")
    local ok = pcall(CH.Store.Get, CH.Store, "nope", "k")
    check(not ok, "unregistered namespace is an error")
    noErrors(CH)
end

scenarios.no_guild = function()
    local CH = boot({ inGuild = false })
    check(CH.Identity:GuildKey() == nil and CH.Permissions:PlayerRole() == "none", "no guild key or role")
    CH.Store:RegisterNamespace("guildy", "guild")
    local ok, why = CH.Store:Put("guildy", "k", {})
    check(not ok and why == "scope unavailable", "guild records refused without a guild")
    SlashCmdList.CASUALHUB("")
    check(contains(CH.UI.pageFrames.dashboard.guildCard.body:GetText(), "not in a guild"), "dashboard explains no guild")
    noErrors(CH)
end

scenarios.module_failure = function()
    local CH = boot({
        beforeLoad = function(CH)
            CH:RegisterModule("Broken", { initialize = function() error("boom") end })
            CH:RegisterModule("NeedsBroken", { dependencies = { "Broken" } })
            CH:RegisterModule("Unsupported", { requires = { "C_Nope.Thing" } })
        end,
    })
    check(CH.Modules:Get("Broken").state == "failed", "erroring module marked failed")
    check(CH.Modules:Get("NeedsBroken").state == "blocked", "dependent module blocked")
    check(CH.Modules:Get("Unsupported").state == "unsupported", "missing capability marks unsupported")
    check(CH.Modules:IsRunning("Dashboard") and CH.ready, "core and other modules unaffected")
    check(printedContains("/chub diag"), "user told where to find the error")
    check(#CasualHubDB.diagnostics.errors >= 1, "error persisted to SavedVariables")
    SlashCmdList.CASUALHUB("")
    check(CasualHubMainFrame:IsShown(), "window still opens")
end

scenarios.not_forever = function()
    local CH = boot({ projectId = 2 })
    check(not CH.Compat.isForever, "non-Forever client detected")
    check(printedContains("not WoW Forever"), "warns on other clients")
end

if scenario then
    print("[" .. scenario .. "]")
    assert(scenarios[scenario], "unknown scenario " .. scenario)()
    os.exit(failures == 0 and 0 or 1)
else
    local names = {}
    for name in pairs(scenarios) do names[#names + 1] = name end
    table.sort(names)
    print(table.concat(names, " "))
end
