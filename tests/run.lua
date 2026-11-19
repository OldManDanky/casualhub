-- Offline smoke tests for GuildHub. Usage (from the repo root):  lua5.1 tests/run.lua [scenario] [savedFile]
-- With no arguments it runs every scenario, each in a fresh Lua process (see tests/run.sh).
package.path = "tests/?.lua;" .. package.path
local Stub = require("wow_stub")

local ADDON_DIR = "addons/GuildHub"
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
        GuildHubDB = saved.GuildHubDB
        GuildHubCharDB = saved.GuildHubCharDB
    end
    local ns = Stub.loadToc(ADDON_DIR, "GuildHub")
    if env and env.beforeLoad then env.beforeLoad(ns) end
    Stub.fire("ADDON_LOADED", "SomeOtherAddon")
    Stub.fire("ADDON_LOADED", "GuildHub")
    Stub.fire("PLAYER_LOGIN")
    Stub.fire("PLAYER_ENTERING_WORLD", true, false)
    Stub.runTimers()
    return ns
end

local function saveTo(path)
    Stub.fire("PLAYER_LOGOUT")
    local f = assert(io.open(path, "w"))
    f:write("GuildHubDB = ", Stub.serialize(GuildHubDB), "\nGuildHubCharDB = ", Stub.serialize(GuildHubCharDB), "\n")
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
    local expected = { SettingsPanel = true, GuildHubDB = true, GuildHubCharDB = true, GuildHubMinimapButton = true }
    local unexpected = {}
    for name in pairs(Stub.missingGlobals) do
        if not expected[name] then unexpected[#unexpected + 1] = name end
    end
    table.sort(unexpected)
    check(#unexpected == 0, "no unexpected undefined globals" ..
        (#unexpected > 0 and (": " .. table.concat(unexpected, ", ")) or ""))
end

local function noErrors(GH)
    local errs = {}
    for _, e in ipairs(GH.Log.entries) do
        if e.level == "error" then errs[#errs + 1] = e.msg end
    end
    check(#errs == 0, "no logged errors" .. (#errs > 0 and (":\n      " .. table.concat(errs, "\n      ")) or ""))
end

local scenarios = {}

scenarios.fresh = function()
    local GH = boot()
    check(GH.ready, "core ready after PLAYER_LOGIN")
    check(GH.Compat.isForever, "detects Forever (project 18)")
    check(GuildHubDB and GuildHubDB.schemaVersion == 1, "database created at schema 1")
    check(GH.Modules:IsRunning("Dashboard") and GH.Modules:IsRunning("Settings"), "Dashboard and Settings running")
    check(GH.Identity:PlayerKey() == "Ghazneth Strongbow", "player key is full First Last name")
    check(GH.Identity:Normalize("Ghazneth-Strongbow") == "Ghazneth Strongbow", "First-Last normalizes to First Last")
    check(GH.Identity:IsPlayer("Ghazneth Strongbow") and not GH.Identity:IsPlayer("Ghazneth"), "first name alone is not the player")
    check(GH.Identity:GuildKey() == "Da Filthy Casuals@CAMWOWUS2Realm7PvE", "guild key")
    check(GH.Permissions:PlayerRole() == "guildmaster", "rank 0 is guildmaster")
    check(GH.Permissions:Can("postAnnouncement"), "guildmaster can post announcements")
    check(Stub.settingsCategory ~= nil, "registered Blizzard Settings category")
    check(GuildHubMinimapButton ~= nil and GuildHubMinimapButton:IsShown(), "minimap button shown")

    SlashCmdList.GUILDHUB("")
    check(GuildHubMainFrame:IsShown(), "/gh opens the window")
    check(GH.UI.currentPage == "dashboard", "dashboard is the first page")
    local dash = GH.UI.pageFrames.dashboard
    check(contains(dash.guildCard.body:GetText(), "Ghazneth Strongbow"), "dashboard shows the player")
    check(contains(dash.guildCard.body:GetText(), "Online: |cffffffff5|r of 55"), "dashboard shows online count")
    check(dash.motdCard.body:GetText() == "Raid Friday!", "dashboard shows MOTD")
    check((Stub.rosterRequests or 0) >= 1, "dashboard requested a roster refresh")

    for _, entry in ipairs(GH.NAVIGATION) do
        GH.UI:SelectPage(entry.id)
        check(GH.UI.currentPage == entry.id and GH.UI.pageFrames[entry.id]:IsShown(), "page " .. entry.id .. " opens")
    end
    check(not GH.UI.pageFrames.dashboard:IsShown(), "previous page hidden")
    check(GH.UI.navButtons.members.badge:IsShown() and not GH.UI.navButtons.settings.badge:IsShown(),
        "'soon' badge only on unbuilt sections")

    local page = GH.UI.pageFrames.settings
    page.scale.slider:SetValue(1.2)
    check(math.abs(GH.Settings:Get("scale") - 1.2) < 1e-9 and math.abs(GuildHubMainFrame:GetScale() - 1.2) < 1e-9,
        "scale slider commits and rescales the window")
    page.minimap:SetChecked(false)
    page.minimap:RunScript("OnClick")
    check(GH.Settings:Get("minimap.show") == false and not GuildHubMinimapButton:IsShown(), "minimap checkbox hides the button")
    page.lock:SetChecked(true)
    page.lock:RunScript("OnClick")
    check(GH.Settings:Get("lockWindow") == true and not GuildHubMainFrame.grip:IsShown(), "lock hides resize grip")
    local dashCheck
    for _, cb in ipairs(page.moduleChecks) do if cb.module.name == "Dashboard" then dashCheck = cb end end
    check(dashCheck ~= nil, "Dashboard listed as a toggleable module")
    dashCheck:SetChecked(false)
    dashCheck:RunScript("OnClick")
    check(GH.Settings:IsModuleEnabled("Dashboard") == false and page.reloadButton:IsShown(), "disabling a module offers a reload")
    dashCheck:SetChecked(true)
    dashCheck:RunScript("OnClick")
    check(GH.Settings:IsModuleEnabled("Dashboard") and GuildHubDB.settings.modules.Dashboard == nil,
        "re-enabling removes the opt-out")
    dashCheck:SetChecked(false)
    dashCheck:RunScript("OnClick")  -- leave disabled for the persistence scenario

    GuildHubMainFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -80)
    GuildHubMainFrame.__points = { { "TOPLEFT", UIParent, "TOPLEFT", 120, -80 } }
    GH.Settings:Set("window.point", "TOPLEFT"); GH.Settings:Set("window.relativePoint", "TOPLEFT")
    GH.Settings:Set("window.x", 120); GH.Settings:Set("window.y", -80)

    SlashCmdList.GUILDHUB("diag")
    check(GuildHubCopyDialog and contains(GuildHubCopyDialog.edit:GetText(), "Modules:"), "/gh diag shows the report")
    check(contains(GuildHubCopyDialog.edit:GetText(), "[Forever]"), "diagnostics identify Forever")
    SlashCmdList.GUILDHUB("version")
    check(printedContains("0.1.0-alpha"), "/gh version prints the version")
    SlashCmdList.GUILDHUB("bogus")
    check(printedContains("unknown command 'bogus'"), "unknown command reported")
    SlashCmdList.GUILDHUB("help")
    check(printedContains("/gh diag"), "/gh help lists commands")
    SlashCmdList.GUILDHUB("settings")
    check(GH.UI.currentPage == "settings", "/gh settings opens a page")
    SlashCmdList.GUILDHUB("")
    check(not GuildHubMainFrame:IsShown(), "/gh again closes the window")
    GuildHub_OnAddonCompartmentClick("GuildHub", "LeftButton")
    check(GuildHubMainFrame:IsShown(), "addon compartment click opens the window")

    noErrors(GH)
    reportGlobals()
    saveTo(savedFile)
end

scenarios.persisted = function()
    local saved = loadSaved(savedFile)
    local GH = boot(nil, saved)
    check(math.abs(GH.Settings:Get("scale") - 1.2) < 1e-9, "scale persisted")
    check(GH.Settings:Get("minimap.show") == false, "minimap setting persisted")
    check(GuildHubMinimapButton == nil, "minimap button not created when hidden")
    check(GH.Settings:Get("window.x") == 120 and GH.Settings:Get("window.point") == "TOPLEFT", "window position persisted")
    check(GH.Modules:Get("Dashboard").state == "disabled", "disabled module stays disabled")
    SlashCmdList.GUILDHUB("")
    check(GH.UI.currentPage == "settings", "with Dashboard disabled the window opens on Settings")
    local p = { GuildHubMainFrame:GetPoint(1) }
    check(p[1] == "TOPLEFT" and p[4] == 120 and p[5] == -80, "window restored at saved position")
    check(math.abs(GuildHubMainFrame:GetScale() - 1.2) < 1e-9, "window restored at saved scale")
    noErrors(GH)
    reportGlobals()
end

scenarios.corrupt = function()
    local GH = boot(nil, { GuildHubDB = { schemaVersion = "x", settings = { scale = "big", minimap = 5, extra = 1 },
        diagnostics = 7 }, GuildHubCharDB = "nonsense" })
    check(GH.ready, "starts despite corrupt saved data")
    check(GH.Settings:Get("scale") == 1.0, "invalid scale reset to default")
    check(GH.Settings:Get("minimap.show") == true, "invalid minimap table rebuilt")
    check(GuildHubDB.settings.extra == 1, "unknown settings kept for forward compatibility")
    check(GuildHubDB.schemaVersion == 1 and type(GuildHubCharDB) == "table", "both databases repaired")
    local warned = false
    for _, e in ipairs(GH.Log.entries) do if e.level == "warn" and contains(e.msg, "reset invalid settings") then warned = true end end
    check(warned, "repairs logged")
    noErrors(GH)
end

scenarios.newer_schema = function()
    local GH = boot(nil, { GuildHubDB = { schemaVersion = 99, settings = {} }, GuildHubCharDB = { schemaVersion = 99 } })
    check(GH.Store.readOnly, "newer schema makes storage read-only")
    GH.Store:RegisterNamespace("test", "account")
    local ok, why = GH.Store:Put("test", "a", { x = 1 })
    check(not ok and why == "read-only", "writes refused")
    check(GuildHubDB.schemaVersion == 99, "newer data left untouched")
end

scenarios.store = function()
    local GH = boot()
    GH.Store:RegisterNamespace("acct", "account")
    GH.Store:RegisterNamespace("mine", "char")
    GH.Store:RegisterNamespace("guildy", "guild")
    local seen
    GH.Events:Subscribe("STORE_CHANGED", "test", function(ns, key) seen = ns .. ":" .. key end)
    check(GH.Store:Put("acct", "k", { v = 1 }) and GH.Store:Get("acct", "k").v == 1, "account record round-trip")
    check(seen == "acct:k", "STORE_CHANGED published")
    check(GH.Store:Put("mine", "k", { v = 2 }) and GuildHubCharDB.data.mine.k.v == 2, "char record stored per character")
    check(GH.Store:Put("guildy", "k", { v = 3 })
        and GuildHubDB.data.guilds["Da Filthy Casuals@CAMWOWUS2Realm7PvE"].guildy.k.v == 3, "guild record scoped to guild key")
    GH.Store:Delete("acct", "k")
    check(GH.Store:Get("acct", "k") == nil, "delete")
    local ok = pcall(GH.Store.Get, GH.Store, "nope", "k")
    check(not ok, "unregistered namespace is an error")
    noErrors(GH)
end

scenarios.no_guild = function()
    local GH = boot({ inGuild = false })
    check(GH.Identity:GuildKey() == nil and GH.Permissions:PlayerRole() == "none", "no guild key or role")
    GH.Store:RegisterNamespace("guildy", "guild")
    local ok, why = GH.Store:Put("guildy", "k", {})
    check(not ok and why == "scope unavailable", "guild records refused without a guild")
    SlashCmdList.GUILDHUB("")
    check(contains(GH.UI.pageFrames.dashboard.guildCard.body:GetText(), "not in a guild"), "dashboard explains no guild")
    noErrors(GH)
end

scenarios.module_failure = function()
    local GH = boot({
        beforeLoad = function(GH)
            GH:RegisterModule("Broken", { initialize = function() error("boom") end })
            GH:RegisterModule("NeedsBroken", { dependencies = { "Broken" } })
            GH:RegisterModule("Unsupported", { requires = { "C_Nope.Thing" } })
        end,
    })
    check(GH.Modules:Get("Broken").state == "failed", "erroring module marked failed")
    check(GH.Modules:Get("NeedsBroken").state == "blocked", "dependent module blocked")
    check(GH.Modules:Get("Unsupported").state == "unsupported", "missing capability marks unsupported")
    check(GH.Modules:IsRunning("Dashboard") and GH.ready, "core and other modules unaffected")
    check(printedContains("/gh diag"), "user told where to find the error")
    check(#GuildHubDB.diagnostics.errors >= 1, "error persisted to SavedVariables")
    SlashCmdList.GUILDHUB("")
    check(GuildHubMainFrame:IsShown(), "window still opens")
end

scenarios.not_forever = function()
    local GH = boot({ projectId = 2 })
    check(not GH.Compat.isForever, "non-Forever client detected")
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
