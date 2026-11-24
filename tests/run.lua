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
    local expected = { SettingsPanel = true, TooltipDataProcessor = true, IsInGroup = true, IsInRaid = true, GetNumGroupMembers = true, UnitExists = true, UnitIsPlayer = true, StaticPopupDialogs = true, StaticPopup_Show = true, OKAY = true, C_Item = true, GetItemInfo = true, GameTooltip = true, GuildControlGetNumRanks = true, GuildControlGetRankName = true, ChatFontNormal = true, hooksecurefunc = true, ChatEdit_InsertLink = true, ChatFrameUtil = true, Auctionator = true, C_Spell = true, GetSpellInfo = true, GetProfessions = true, GetProfessionInfo = true, C_TradeSkillUI = true, PlaySound = true, SOUNDKIT = true, UnitLevel = true, C_ClassColor = true, CasualHubDB = true, CasualHubCharDB = true, CasualHubMinimapButton = true }
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
    check(CasualHubDB and CasualHubDB.schemaVersion == 2, "database created at the current schema")
    check(CH.Modules:IsRunning("Dashboard") and CH.Modules:IsRunning("Settings"), "Dashboard and Settings running")
    check(CH.Identity:PlayerKey() == "Ghazneth Strongbow", "player key is full First Last name")
    check(CH.Identity:Normalize("Ghazneth-Strongbow") == "Ghazneth Strongbow", "First-Last normalizes to First Last")
    check(CH.Identity:IsPlayer("Ghazneth Strongbow") and not CH.Identity:IsPlayer("Ghazneth"), "first name alone is not the player")
    check(CH.Identity:GuildKey() == "Da Filthy Casuals", "guild key is the guild name (realm names vary on Forever)")
    check(CH.Permissions:PlayerRole() == "guildmaster", "rank 0 is guildmaster")
    check(CH.Permissions:Can("postAnnouncement"), "guildmaster can post announcements")
    check(Stub.settingsCategory ~= nil, "registered Blizzard Settings category")
    check(CasualHubMinimapButton ~= nil and CasualHubMinimapButton:IsShown(), "minimap button shown")

    SlashCmdList.CASUALHUB("")
    check(CasualHubMainFrame:IsShown(), "/chub opens the window")
    check(CH.UI.currentPage == "dashboard", "dashboard is the first page")
    local dash = CH.UI.pageFrames.dashboard
    check(contains(dash.guildCard.body:GetText(), "Ghazneth Strongbow"), "dashboard shows the player")
    check(contains(dash.guildCard.body:GetText(), "Online: |cffffffff3|r of 4"), "dashboard shows online count")
    check(dash.motdCard.body:GetText() == "Raid Friday!", "dashboard shows MOTD")
    check((Stub.rosterRequests or 0) >= 1, "dashboard requested a roster refresh")

    for _, entry in ipairs(CH.NAVIGATION) do
        CH.UI:SelectPage(entry.id)
        check(CH.UI.currentPage == entry.id and CH.UI.pageFrames[entry.id]:IsShown(), "page " .. entry.id .. " opens")
    end
    check(not CH.UI.pageFrames.dashboard.scroll:IsShown(), "previous page hidden")
    local anySoon = false
    for _, b in pairs(CH.UI.navButtons) do if b.badge:IsShown() and b.badge:GetText() == "soon" then anySoon = true end end
    check(not anySoon, "every section is built: no 'soon' badges")

    local page = CH.UI.pageFrames.settings
    -- Pages scroll when the window is shorter than their layout, and fill the window otherwise.
    local workspace = CH.UI.content
    check(page.scroll and (page.minHeight or 0) > 527, "settings page needs more than the default window height")
    workspace:SetSize(680, 500)
    check(page:GetHeight() == page.minHeight and page:GetWidth() == 680 - 26, "short window: the page keeps its height and scrolls")
    workspace:SetSize(680, 900)
    check(page:GetHeight() == 896 and page:GetWidth() == 680, "tall window: the page fills it, no scroll bar")
    local dash = CH.UI.pageFrames.dashboard
    workspace:SetSize(680, 500)
    check(dash:GetHeight() == 496, "pages without a minimum height just fill the window")
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
    check(printedContains(CH.version), "/chub version prints the version")
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
    check(CasualHubDB.schemaVersion == 2 and type(CasualHubCharDB) == "table", "both databases repaired")
    local warned = false
    for _, e in ipairs(CH.Log.entries) do if e.level == "warn" and contains(e.msg, "reset invalid settings") then warned = true end end
    check(warned, "repairs logged")
    noErrors(CH)
end

scenarios.migrate_guild_keys = function()
    -- Schema 1 saved the same guild under two realm spellings (seen in-game on 2026-11-19).
    local saved = { GuildHubDB = nil, CasualHubDB = { schemaVersion = 1, settings = {}, data = { account = {}, guilds = {
        ["Da Filthy Casuals@CAMWOWUS2Realm7PvE"] = { profiles = {
            ["Thrall Stormrage"] = { id = "Thrall Stormrage", owner = "Thrall Stormrage", rev = 4, updatedAt = 1, roles = { "tank" } },
            ["Jaina Proudmoore"] = { id = "Jaina Proudmoore", owner = "Jaina Proudmoore", rev = 1, updatedAt = 1 } },
            roster = { members = { ["Thrall Stormrage"] = { level = 60 } } } },
        ["Da Filthy Casuals@CAMWOWUS1Realm7PvE"] = { profiles = {
            ["Thrall Stormrage"] = { id = "Thrall Stormrage", owner = "Thrall Stormrage", rev = 2, updatedAt = 1, roles = { "healer" } },
            ["Ghazneth Ironhide"] = { id = "Ghazneth Ironhide", owner = "Ghazneth Ironhide", rev = 1, updatedAt = 1 } } },
    } } }, CasualHubCharDB = { schemaVersion = 1 } }
    local CH = boot(nil, { CasualHubDB = saved.CasualHubDB, CasualHubCharDB = saved.CasualHubCharDB })
    local guilds = CasualHubDB.data.guilds
    local keys = {}
    for k in pairs(guilds) do keys[#keys + 1] = k end
    check(#keys == 1 and keys[1] == "Da Filthy Casuals", "realm-suffixed guild keys merged into one")
    local profiles = guilds["Da Filthy Casuals"].profiles
    check(profiles["Thrall Stormrage"].rev == 4 and profiles["Thrall Stormrage"].roles[1] == "tank", "merge keeps the higher revision")
    check(profiles["Jaina Proudmoore"] and profiles["Ghazneth Ironhide"], "records from both keys kept")
    check(CasualHubDB.schemaVersion == 2 and not CH.Store.readOnly, "migrated to schema 2")
    check(CH.Profiles:Get("Thrall Stormrage") and CH.Profiles:Get("Thrall Stormrage").roles[1] == "tank", "merged data visible")
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
        and CasualHubDB.data.guilds["Da Filthy Casuals"].guildy.k.v == 3, "guild record scoped to guild key")
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
    for _, entry in ipairs(CH.NAVIGATION) do CH.UI:SelectPage(entry.id) end
    check(CH.UI.currentPage == "settings", "every page opens without a guild")
    check(select(2, CH.Activities:Create({ category = "quests", title = "x", expiresAt = Stub.serverTime + 3600 }))
        == "You need to be in a guild.", "activities explain they need a guild")
    check(not CH.GuildEvents:Create({ category = "raid", title = "x", startAt = Stub.serverTime + 3600, duration = 60, capacity = 5 }),
        "events need a guild")
    check(select(2, CH.Blacklist:Add("Grief Lord", "x")) == "You need to be in a guild.", "blacklist needs a guild")
    check(not CH.Bulletin:CanPost() and not CH.Professions:CreateRequest({ kind = "craft", title = "x",
        expiresAt = Stub.serverTime + 3600 }), "notices and requests need a guild")
    check(#Stub.sent == 0, "nothing is sent without a guild")
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

---------------------------------------------------------------------------
-- Phase 2: transport, sync, profiles
---------------------------------------------------------------------------

-- Delivers a message as if a guildmate's client sent it.
local function peerSend(CH, msgType, body, channel, sender, reverse)
    local chunks = assert(CH.Comm:EncodeWire(msgType, body))
    local first, last, step = 1, #chunks, 1
    if reverse then first, last, step = #chunks, 1, -1 end
    for i = first, last, step do
        Stub.fire("CHAT_MSG_ADDON", "CasualHub", chunks[i], channel or "WHISPER", sender or "Thrall Stormrage",
            "Ghazneth Strongbow")
    end
    return chunks
end

-- Reassembles and decodes everything this client sent.
local function sentMessages(CH, msgType)
    local bufs, out = {}, {}
    for _, s in ipairs(Stub.sent) do
        local _, id, i, n, data = s.text:match("^(%d+):(%w+):(%d+):(%d+):(.*)$")
        local b = bufs[id] or { parts = {}, n = tonumber(n), got = 0, channel = s.channel, target = s.target }
        bufs[id] = b
        b.parts[tonumber(i)] = data
        b.got = b.got + 1
        if b.got == b.n then
            local env = CH.Serializer.Decode(table.concat(b.parts))
            if not msgType or env.t == msgType then
                out[#out + 1] = { t = env.t, b = env.b, channel = b.channel, target = b.target, chunks = b.n }
            end
        end
    end
    return out
end

-- Lets queued sends drain (the transport rate-limits), then clears the capture.
local function drain()
    Stub.advance(30)
    Stub.sent = {}
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
    return out
end

scenarios.serializer = function()
    local CH = boot()
    local S = CH.Serializer
    local value = { a = "x:y;z", n = 42, f = 1.5, neg = -7, big = 1795100000, t = true, f2 = false,
        list = { "one", "two" }, nested = { deep = { s = "\n\0|" } }, [3] = "three" }
    local decoded = S.Decode(S.Encode(value))
    check(decoded and decoded.a == "x:y;z" and decoded.n == 42 and decoded.f == 1.5 and decoded.big == 1795100000,
        "round-trips strings and numbers")
    check(decoded and decoded.list[2] == "two" and decoded.nested.deep.s == "\n\0|" and decoded[3] == "three" and
        decoded.f2 == false, "round-trips nested tables, binary strings, booleans")
    check(S.Encode({ b = 1, a = 2 }) == S.Encode({ a = 2, b = 1 }), "encoding is deterministic")
    for _, bad in ipairs({ "", "x", "s5:ab", "t", "ts1:a", "i12", "s1:ab", "tTTe", "s99999999:a" }) do
        local v = S.Decode(bad)
        check(v == nil, "rejects malformed input " .. string.format("%q", bad))
    end
    local deep = {}
    local cur = deep
    for _ = 1, 20 do cur.x = {}; cur = cur.x end
    check(S.Encode(deep) == nil, "refuses to encode over-deep tables")
    check(S.Decode(string.rep("t", 50) .. string.rep("e", 50)) == nil, "refuses to decode over-deep tables")
    check(CH.CleanText("a|cffff0000b|r\n\tc  d", 140) == "acffff0000br c d", "CleanText strips escapes and controls")
    check(CH.CleanText(("é"):rep(10), 5) == "éé", "CleanText never splits a UTF-8 character")
end

scenarios.sync = function()
    local CH = boot()
    local recs = sentMessages(CH, "REC")
    check(#recs == 1 and recs[1].channel == "GUILD" and recs[1].b.r.owner == "Ghazneth Strongbow" and recs[1].b.r.rev == 1,
        "own (empty) profile published to the guild on login")
    Stub.advance(20)
    local hellos = sentMessages(CH, "HELLO")
    check(#hellos == 1 and hellos[1].channel == "GUILD" and hellos[1].b.d.profile.n == 1, "HELLO with digest broadcast after login")
    for _, s in ipairs(Stub.sent) do
        if #s.text > 255 then check(false, "wire message over 255 bytes") end
    end

    Stub.sent = {}
    peerSend(CH, "HELLO", { d = { profile = { h = 1, n = 5 } } }, "GUILD")
    Stub.advance(5)
    local sums = sentMessages(CH, "SUM")
    check(#sums == 1 and sums[1].channel == "WHISPER" and sums[1].target == "Thrall Stormrage"
        and sums[1].b.s["Ghazneth Strongbow"] == 1, "answers a differing HELLO with a whispered summary")
    Stub.sent = {}
    peerSend(CH, "HELLO", { d = { profile = { h = 1, n = 5 } } }, "GUILD")
    Stub.advance(5)
    check(#sentMessages(CH, "SUM") == 0, "one summary per peer per minute")
    peerSend(CH, "HELLO", { d = { profile = CH.Sync:Digest("profile") } }, "GUILD", "Ghazneth Ironhide")
    Stub.advance(5)
    check(#sentMessages(CH, "SUM") == 0, "no summary when digests match")
    local his = sentMessages(CH, "HI")
    check(#his == 1 and his[1].target == "Ghazneth Ironhide" and his[1].channel == "WHISPER",
        "presence reply to each new peer, even when nothing needs syncing")
    Stub.sent = {}
    peerSend(CH, "HELLO", { d = { profile = CH.Sync:Digest("profile") } }, "GUILD", "Ghazneth Ironhide")
    Stub.advance(5)
    check(#sentMessages(CH, "HI") == 0, "only one presence reply per peer per session")
    peerSend(CH, "HI", {}, "WHISPER", "Jaina Proudmoore")
    check(CH.Comm:Peer("Jaina Proudmoore") ~= nil and CH.Comm.stats.unknownType == 0, "HI marks the sender as a peer")

    Stub.sent = {}
    peerSend(CH, "SUM", { y = "profile", s = { ["Thrall Stormrage"] = 2 } })
    Stub.advance(1)
    local reqs = sentMessages(CH, "REQ")
    check(#reqs == 1 and reqs[1].b.ids[1] == "Thrall Stormrage", "requests records the peer has newer")
    local pushes = sentMessages(CH, "REC")
    check(#pushes == 1 and pushes[1].target == "Thrall Stormrage" and pushes[1].b.r.owner == "Ghazneth Strongbow",
        "pushes records the peer lacks")

    local thrall = { id = "Thrall Stormrage", owner = "Thrall Stormrage", rev = 2, updatedAt = Stub.serverTime - 3600,
        roles = { "dps", "tank", "bogus", "tank" }, interests = { "raids" }, note = "Warchief |cffff0000hi|r\nthere",
        extra = "drop me" }
    peerSend(CH, "REC", { y = "profile", r = thrall })
    local p = CH.Profiles:Get("Thrall Stormrage")
    check(p and p.rev == 2 and #p.roles == 2 and p.roles[1] == "tank" and p.roles[2] == "dps",
        "accepts a peer profile, de-duplicates and orders roles")
    check(p and p.note == "Warchief cffff0000hir there" and p.extra == nil, "strips escapes, control chars, unknown fields")
    local older = copy(thrall)
    older.rev, older.roles = 1, { "healer" }
    peerSend(CH, "REC", { y = "profile", r = older })
    check(CH.Profiles:Get("Thrall Stormrage").roles[1] == "tank", "older revision ignored")
    local relayed = copy(thrall)
    relayed.rev, relayed.interests = 3, { "pvp" }
    peerSend(CH, "REC", { y = "profile", r = relayed }, "WHISPER", "Ghazneth Ironhide")
    p = CH.Profiles:Get("Thrall Stormrage")
    check(p.rev == 3 and p.interests[1] == "pvp" and p._via == "Ghazneth Ironhide", "accepts newer copy relayed by another member")

    peerSend(CH, "REC", { y = "profile", r = { id = "Arthas Menethil", owner = "Arthas Menethil", rev = 1, updatedAt = 1 } })
    check(CH.Sync:Get("profile", "Arthas Menethil") == nil, "rejects records for non-members")
    peerSend(CH, "REC", { y = "profile", r = { id = "Ghazneth", owner = "Ghazneth", rev = 1, updatedAt = 1 } })
    check(CH.Sync:Get("profile", "Ghazneth") == nil, "first name alone is not a member")
    peerSend(CH, "REC", { y = "profile", r = { id = "Jaina Proudmoore", owner = "Thrall Stormrage", rev = 1, updatedAt = 1 } })
    check(CH.Sync:Get("profile", "Jaina Proudmoore") == nil, "rejects a profile whose id isn't its owner")

    local malformedBefore = CH.Comm.stats.malformed
    for _, text in ipairs({ "garbage", "1:abc:1:1:not-serialized", "1:abc:1:99:x", "1:abc:3:2:x", "2:abc:1:1:x" }) do
        Stub.fire("CHAT_MSG_ADDON", "CasualHub", text, "WHISPER", "Thrall Stormrage")
    end
    check(CH.Comm.stats.malformed - malformedBefore == 4 and CH.Comm.stats.otherProtocol == 1,
        "malformed and other-protocol messages counted and ignored")
    Stub.fire("CHAT_MSG_ADDON", "OtherAddon", "1:abc:1:1:x", "WHISPER", "Thrall Stormrage")
    check(CH.Comm.stats.malformed - malformedBefore == 4, "other prefixes ignored")

    local big = {}
    for i = 1, 40 do big["Filler Name" .. i] = 1 end
    big["Jaina Proudmoore"] = 4
    Stub.sent = {}
    local chunks = peerSend(CH, "SUM", { y = "profile", s = big }, "WHISPER", "Thrall Stormrage", true)
    Stub.advance(1)
    local jaina = false
    for _, r in ipairs(sentMessages(CH, "REQ")) do
        for _, id in ipairs(r.b.ids) do if id == "Jaina Proudmoore" then jaina = true end end
    end
    check(#chunks > 1 and jaina, "multi-chunk summary reassembled from out-of-order chunks (" .. #chunks .. " chunks)")

    check(not CH.Comm:Send("REQ", { y = "profile", ids = {} }, "WHISPER", "Jaina Proudmoore"), "never whispers offline members")
    check(not CH.Comm:Send("REQ", { y = "profile", ids = {} }, "WHISPER", "Ghazneth"), "never whispers a first name alone")
    CH.Comm:Send("REQ", { y = "profile", ids = {} }, "WHISPER", "Thrall Stormrage")
    local filter = Stub.chatFilters[1] and Stub.chatFilters[1][2]
    check(filter and filter(nil, "CHAT_MSG_SYSTEM", "No player named 'Thrall Stormrage' is currently playing."),
        "hides the failed-whisper error for our own whisper")
    check(filter and not filter(nil, "CHAT_MSG_SYSTEM", "No player named 'Jaina Proudmoore' is currently playing."),
        "leaves other system errors alone")

    drain()
    peerSend(CH, "REC", { y = "profile", r = { id = "Ghazneth Strongbow", owner = "Ghazneth Strongbow", rev = 50,
        updatedAt = 1, roles = { "healer" } } })
    Stub.advance(30)
    local heal = sentMessages(CH, "REC")
    check(#heal == 1 and heal[1].b.r.rev == 51 and #heal[1].b.r.roles == 0, "a forged newer copy of our profile is overridden")

    drain()
    local ok = CH.Profiles:SaveMine({ roles = { "healer" }, interests = { "dungeons" }, main = "", note = "Hi" })
    Stub.advance(30)
    recs = sentMessages(CH, "REC")
    check(ok and #recs == 1 and recs[1].b.r.rev == 52 and recs[1].b.r.roles[1] == "healer", "saving own profile broadcasts a new revision")
    check(not CH.Profiles:SaveMine({ main = "Arthas Menethil" }), "main must be a guild member")
    check(not CH.Profiles:SaveMine({ main = "Ghazneth Strongbow" }), "main can't be yourself")
    check(CH.Profiles:SaveMine({ main = "Ghazneth-Ironhide", roles = { "dps" } }) and CH.Profiles:Mine().main == "Ghazneth Ironhide",
        "main accepts the First-Last spelling")
    check(CH.Profiles:AltsOf("Ghazneth Ironhide")[1] == "Ghazneth Strongbow", "alts listed under their main")

    drain()
    CH.Settings:Set("profile.share", false)
    Stub.advance(30)
    recs = sentMessages(CH, "REC")
    check(#recs == 1 and recs[1].b.r.deleted == true and recs[1].b.r.main == nil, "turning sharing off sends a tombstone only")
    check(CH.Profiles:Mine().main == "Ghazneth Ironhide", "private copy kept while not sharing")
    drain()
    peerSend(CH, "REQ", { y = "profile", ids = { "Ghazneth Strongbow" } })
    Stub.advance(30)
    recs = sentMessages(CH, "REC")
    check(#recs == 1 and recs[1].b.r.deleted == true and recs[1].b.r.roles == nil, "requests get the tombstone, not the profile")
    drain()
    CH.Settings:Set("profile.share", true)
    Stub.advance(30)
    recs = sentMessages(CH, "REC")
    check(#recs == 1 and not recs[1].b.r.deleted and recs[1].b.r.main == "Ghazneth Ironhide", "turning sharing on republishes")

    drain()
    Stub.sendResults = { 3 }
    CH.Comm.tokens, CH.Comm.lastRefill = 8, Stub.now
    CH.Comm:Send("HELLO", { d = {} }, "GUILD")
    check(#Stub.sent == 0 and #CH.Comm.queue == 1, "throttled message stays queued")
    Stub.advance(2)
    check(#Stub.sent == 1 and CH.Comm.stats.throttled == 1, "sent once the throttle clears")
    Stub.sent = {}
    CH.Comm.tokens, CH.Comm.lastRefill = 8, Stub.now
    for _ = 1, 20 do CH.Comm:Send("HELLO", { d = {} }, "GUILD") end
    check(#Stub.sent == 8, "bursts limited to 8 messages")
    Stub.advance(13)
    check(#Stub.sent == 20, "the rest drain at about one per second")
    Stub.sent, Stub.lockdown = {}, true
    CH.Comm:Send("HELLO", { d = {} }, "GUILD")
    Stub.advance(1)
    check(#Stub.sent == 0, "held during messaging lockdown")
    Stub.lockdown = false
    Stub.advance(6)
    check(#Stub.sent == 1, "sent after lockdown ends")

    local peer = CH.Comm:Peer("Thrall Stormrage")
    check(peer and peer.version == CH.version, "peer addon version recorded")
    Stub.fire("PLAYER_LOGOUT")
    local last = CasualHubDB.diagnostics.lastSession
    check(last and last.peers["Thrall Stormrage"] == CH.version and last.comm.sentChunks > 0 and last.sync.accepted > 0,
        "session counters and peers saved at logout")
    noErrors(CH)
    reportGlobals()
    saveTo(savedFile)
end

scenarios.sync_relog = function()
    local CH = boot(nil, loadSaved(savedFile))
    check(#sentMessages(CH, "REC") == 0, "unchanged profile not republished on login")
    check(CH.Profiles:Get("Thrall Stormrage") and CH.Profiles:Get("Thrall Stormrage").rev == 3, "peer profiles persist")
    check(CH.Profiles:Mine().main == "Ghazneth Ironhide", "own profile persists per character")
    Stub.roster[2] = nil  -- Thrall leaves the guild
    CH.Roster:Scan()
    Stub.advance(30)
    check(CH.Sync:Get("profile", "Thrall Stormrage") == nil, "profiles of members who left are pruned")
    noErrors(CH)
end

scenarios.members_ui = function()
    local CH = boot()
    peerSend(CH, "REC", { y = "profile", r = { id = "Thrall Stormrage", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime - 60, roles = { "tank" }, interests = { "raids" }, note = "For the Horde" } })
    SlashCmdList.CASUALHUB("members")
    local page = CH.UI.pageFrames.members
    check(page and page:IsShown(), "/chub members opens the Members page")
    check(#page.list.items == 4, "lists every roster member")
    check(page.list.items[1].member.online and not page.list.items[4].member.online, "online members first")
    check(contains(page.subtitle:GetText(), "4 members, 3 online, 2 using Casual Hub"), "summary counts Casual Hub users")
    page.search:SetText("thr")
    page.search:RunScript("OnTextChanged", true)
    check(#page.list.items == 1 and page.list.items[1].member.name == "Thrall Stormrage", "search filters by name")
    page.search:SetText("horde")
    page.search:RunScript("OnTextChanged", true)
    check(#page.list.items == 1, "search matches profile notes")
    page.search:SetText("")
    page.search:RunScript("OnTextChanged", true)
    page.onlineOnly:SetChecked(true)
    page.onlineOnly:RunScript("OnClick")
    check(#page.list.items == 3, "online filter")
    page.addonOnly:SetChecked(true)
    page.addonOnly:RunScript("OnClick")
    check(#page.list.items == 2, "Casual Hub users filter")
    CH.MembersPage:Select("Thrall Stormrage")
    check(contains(page.detailBody:GetText(), "Tank") and contains(page.detailBody:GetText(), "For the Horde"),
        "detail shows the selected profile")

    CH.MembersPage:OpenEditor()
    local ed = page.editor
    check(ed:IsShown() and not page.list:IsShown(), "editor replaces the list")
    ed.roles.healer:SetChecked(true)
    ed.days.sat:SetChecked(true)
    ed.note:SetText("LF attunement buddies")
    ed.main:SetText("Arthas Menethil")
    CH.MembersPage:SaveEditor()
    check(ed:IsShown() and contains(ed.error:GetText(), "not in the guild roster"), "invalid main shows an error and keeps the editor open")
    ed.main:SetText("")
    CH.MembersPage:SaveEditor()
    local mine = CH.Profiles:Mine()
    check(not ed:IsShown() and mine.roles[1] == "healer" and mine.days[1] == "sat" and mine.note == "LF attunement buddies",
        "editor saves the profile")
    check(CH.MembersPage.selected == "Ghazneth Strongbow" and contains(page.detailBody:GetText(), "Healer"),
        "own profile shown after saving")
    for _, entry in ipairs(CH.NAVIGATION) do CH.UI:SelectPage(entry.id) end
    check(not CH.UI.navButtons.members.badge:IsShown(), "Members no longer marked 'soon'")
    noErrors(CH)
    reportGlobals()
end

---------------------------------------------------------------------------
-- Phase 3: Activity Board
---------------------------------------------------------------------------

scenarios.activities = function()
    local CH = boot()
    local A = CH.Activities
    drain()
    local now = Stub.serverTime
    local id, reason = A:Create({ category = "dungeons", title = "RFC run", details = "Need a tank",
        expiresAt = now + 6 * 3600, roles = { tank = 1, dps = 2 }, capacity = 5 })
    Stub.advance(30)
    local recs = sentMessages(CH, "REC")
    check(id and id:find("^Ghazneth Strongbow#") and #recs == 1 and recs[1].b.y == "activity"
        and recs[1].channel == "GUILD" and recs[1].b.r.title == "RFC run", "creating a request broadcasts it" .. tostring(reason or ""))
    check(not A:Create({ category = "raids", title = "x", expiresAt = now + 3600 }), "rejects unknown category")
    check(not A:Create({ category = "quests", title = "  ", expiresAt = now + 3600 }), "rejects empty title")
    check(not A:Create({ category = "quests", title = "x", expiresAt = now + 3600, capacity = 1 }), "rejects group size 1")
    check(not A:Create({ category = "quests", title = "x", expiresAt = now + 20 * 86400 }), "rejects expiry over 15 days")

    drain()
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Thrall Stormrage", owner = "Thrall Stormrage", rev = 1,
        updatedAt = now, activityId = id, role = "tank", state = "volunteered", note = "on my way" } })
    local a = A:Get(id)
    local vols = A:Volunteers(a)
    check(#vols == 1 and vols[1].name == "Thrall Stormrage" and vols[1].role == "tank" and vols[1].note == "on my way",
        "peer volunteers")
    check(printedContains("Thrall Stormrage volunteered (Tank)"), "organizer told about a new volunteer")
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Jaina Proudmoore", owner = "Thrall Stormrage", rev = 1,
        updatedAt = now, activityId = id, role = "dps", state = "volunteered" } })
    check(#A:Volunteers(A:Get(id)) == 1, "signup id must match its owner")
    local function manualCount(t) local n = 0 for _ in CH.Sync:Iterate(t) do n = n + 1 end return n end
    check(CH.Sync:Count("signup") == manualCount("signup") and #CH.Sync:Children("signup", "activityId", id) == 1,
        "cached record count and child index match the store")
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Ghazneth Ironhide", owner = "Ghazneth Ironhide", rev = 1,
        updatedAt = now, activityId = id, role = "dps", state = "volunteered" } }, nil, "Ghazneth Ironhide")
    check(CH.Sync:Count("signup") == manualCount("signup") and #CH.Sync:Children("signup", "activityId", id) == 2,
        "both stay correct after a new record")
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Ghazneth Ironhide", owner = "Ghazneth Ironhide", rev = 2,
        updatedAt = now, deleted = true } }, nil, "Ghazneth Ironhide")
    check(CH.Sync:Count("signup") == manualCount("signup") and #CH.Sync:Children("signup", "activityId", id) == 1,
        "deleted records leave the child index")

    check(A:SetAccepted(id, "Thrall Stormrage", "tank"), "organizer accepts a volunteer")
    a = A:Get(id)
    check(a.accepted["Thrall Stormrage"] == "tank" and A:RoleFill(a).tank == 1 and A:Volunteers(a)[1].accepted,
        "accepted volunteer counted toward roles")
    A:Update(id, { category = "dungeons", title = "RFC run", expiresAt = a.expiresAt, roles = a.roles, capacity = 2 })
    check(A:EffectiveStatus(A:Get(id)) == "full", "full when the group reaches its size")
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Thrall Stormrage", owner = "Thrall Stormrage", rev = 2,
        updatedAt = now, activityId = id, role = "tank", state = "withdrawn" } })
    a = A:Get(id)
    local v1 = A:Volunteers(a)[1]
    check(A:AcceptedCount(a) == 0 and (A:RoleFill(a).tank or 0) == 0 and A:ActiveVolunteerCount(a) == 0
        and v1.withdrewAfterAccept and not v1.accepted, "accepted volunteer who withdraws frees the slot")
    check(A:EffectiveStatus(a) == "open", "group no longer full after the withdrawal")
    check(printedContains("Thrall Stormrage withdrew from"), "organizer told about the withdrawal")
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Thrall Stormrage", owner = "Thrall Stormrage", rev = 3,
        updatedAt = now, activityId = id, role = "tank", state = "volunteered" } })
    a = A:Get(id)
    check(A:AcceptedCount(a) == 1 and A:Volunteers(a)[1].accepted and A:EffectiveStatus(a) == "full",
        "re-volunteering restores the accepted slot")

    -- A guildmate's request
    local tid = "Thrall Stormrage#abc"
    peerSend(CH, "REC", { y = "activity", r = { id = tid, owner = "Thrall Stormrage", rev = 1, updatedAt = now,
        category = "attunements", title = "Onyxia attune", status = "open", expiresAt = now + 86400, roles = { healer = 1 } } })
    check(A:Get(tid) and A:Get(tid).title == "Onyxia attune", "receives a guildmate's request")
    check(not A:SetStatus(tid, "closed"), "can't change someone else's request")
    peerSend(CH, "REC", { y = "activity", r = { id = "Thrall Stormrage#fake", owner = "Ghazneth Ironhide", rev = 1,
        updatedAt = now, category = "quests", title = "spoof", status = "open", expiresAt = now + 3600 } })
    check(A:Get("Thrall Stormrage#fake") == nil, "rejects a request whose id names another organizer")
    drain()
    check(A:Volunteer(tid, "healer", "can heal"), "volunteer for a guildmate's request")
    Stub.advance(30)
    recs = sentMessages(CH, "REC")
    check(#recs == 1 and recs[1].b.y == "signup" and recs[1].b.r.state == "volunteered" and recs[1].b.r.role == "healer",
        "signup broadcast")
    check(not A:Volunteer(id, "dps"), "can't volunteer for your own request")
    peerSend(CH, "REC", { y = "activity", r = { id = tid, owner = "Thrall Stormrage", rev = 2, updatedAt = now,
        category = "attunements", title = "Onyxia attune", status = "open", expiresAt = now + 86400, roles = { healer = 1 },
        accepted = { ["Ghazneth Strongbow"] = "healer" } } })
    check(printedContains("Thrall Stormrage accepted you"), "told when accepted")
    drain()
    A:Withdraw(tid)
    Stub.advance(30)
    recs = sentMessages(CH, "REC")
    check(#recs == 1 and recs[1].b.r.state == "withdrawn", "withdraw broadcasts")

    check(A:SetStatus(id, "closed") and A:EffectiveStatus(A:Get(id)) == "closed", "organizer closes")
    check(A:SetStatus(id, "open") and A:IsActive(A:Get(id)), "and reopens")
    Stub.advance(25 * 3600)
    check(A:EffectiveStatus(A:Get(tid)) == "expired", "requests expire")
    Stub.advance(8 * 86400)
    CH.Sync:Prune()
    check(A:Get(tid) == nil and CH.Sync:Get("signup", tid .. "|Ghazneth Strongbow") == nil,
        "expired requests and their signups pruned after a week")
    peerSend(CH, "REC", { y = "activity", r = { id = "Thrall Stormrage#old", owner = "Thrall Stormrage", rev = 1,
        updatedAt = now, category = "quests", title = "stale", status = "open", expiresAt = now + 3600 } })
    check(A:Get("Thrall Stormrage#old") == nil, "already-expired requests from peers refused")
    local doomed = A:Create({ category = "help", title = "Delete me", expiresAt = Stub.serverTime + 3600 })
    check(doomed and A:Delete(doomed) and A:Get(doomed) == nil and CH.Sync:Get("activity", doomed).deleted,
        "organizer deletes (tombstone kept so it can't come back)")
    noErrors(CH)
    reportGlobals()
end

scenarios.activities_ui = function()
    local CH = boot()
    local P = CH.ActivitiesPage
    check(select(1, P.ParseClock("20:30")) == 20 and select(2, P.ParseClock("20:30")) == 30, "parses 20:30")
    check(P.ParseClock("8pm") == 20 and P.ParseClock("12am") == 0 and P.ParseClock("12pm") == 12 and
        P.ParseClock("8:15 am") == 8, "parses am/pm")
    check(P.ParseClock("25:00") == nil and P.ParseClock("8:75") == nil and P.ParseClock("13pm") == nil and
        P.ParseClock("soon") == nil, "rejects bad times")

    SlashCmdList.CASUALHUB("activities")
    local page = CH.UI.pageFrames.activities
    check(page and page:IsShown() and page.empty:IsShown(), "/chub activities opens an empty board")
    P:OpenEditor(nil)
    local ed = page.editor
    check(ed:IsShown() and not page.list:IsShown(), "New request opens the editor")
    ed.category.buttons.quests:RunScript("OnClick")
    ed.title:SetText("Help with Hogger")
    ed.day.buttons.tomorrow:RunScript("OnClick")
    ed.clock:SetText("25:99")
    P:SaveEditor()
    check(ed:IsShown() and contains(ed.error:GetText(), "start time"), "bad start time rejected")
    ed.clock:SetText("8:30pm")
    ed.roleBoxes.dps:SetText("2")
    P:SaveEditor()
    local list = CH.Activities:List()
    check(not ed:IsShown() and #list == 1 and list[1].category == "quests" and list[1].roles.dps == 2 and
        list[1].startAt and list[1].startAt > Stub.serverTime, "request posted for tomorrow evening")
    check(#page.list.items == 1 and P.selected == list[1].id, "new request listed and selected")
    check(page.actionButtons[1]:IsShown() and page.actionButtons[1]:GetText() == "Edit", "organizer sees Edit")
    check(contains(CH.UI.pageFrames.activities.detailBody:GetText(), "Quests"), "detail shows the category")

    local id = list[1].id
    peerSend(CH, "REC", { y = "signup", r = { id = id .. "|Thrall Stormrage", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, activityId = id, role = "dps", state = "volunteered" } })
    Stub.advance(1)  -- pages redraw once per burst of records, 0.2s later
    local row = page.volunteerRows[1]
    check(row:IsShown() and row.accept:IsShown() and contains(row.text:GetText(), "Thrall Stormrage"), "volunteer listed with Accept")
    row.accept:RunScript("OnClick")
    check(CH.Activities:Get(id).accepted["Thrall Stormrage"] == "dps" and page.volunteerRows[1].invite:IsShown(),
        "Accept works; Invite offered for online accepted volunteers")

    page.categoryFilter.buttons.dungeons:RunScript("OnClick")
    check(#page.list.items == 0, "category filter")
    page.categoryFilter.buttons.all:RunScript("OnClick")
    check(#page.list.items == 1, "All shows everything")
    CH.Activities:SetStatus(id, "completed")
    P:Refresh()
    check(#page.list.items == 0, "finished requests hidden by default")
    page.showClosed:SetChecked(true)
    page.showClosed:RunScript("OnClick")
    check(#page.list.items == 1, "Show finished includes them")

    peerSend(CH, "REC", { y = "activity", r = { id = "Thrall Stormrage#x1", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, category = "worldbosses", title = "Azuregos", status = "open",
        expiresAt = Stub.serverTime + 3600, roles = { tank = 2 } } })
    P:Select("Thrall Stormrage#x1")
    check(page.actionButtons[1]:GetText() == "Volunteer: Tank" and page.actionButtons[2]:GetText() == "Volunteer: any",
        "volunteer buttons per needed role")
    page.actionButtons[1]:RunScript("OnClick")
    local s = CH.Activities:MySignup("Thrall Stormrage#x1")
    check(s and s.role == "tank" and page.actionButtons[1]:GetText() == "Withdraw", "volunteering switches to Withdraw")

    SlashCmdList.CASUALHUB("dashboard")
    check(contains(CH.UI.pageFrames.dashboard.activitiesCard.body:GetText(), "Azuregos"), "dashboard lists open requests")
    noErrors(CH)
    reportGlobals()
end

---------------------------------------------------------------------------
-- Phase 4: Events and group builder
---------------------------------------------------------------------------

local function rsvp(CH, eventId, who, role, state, joinedAt, rev)
    peerSend(CH, "REC", { y = "rsvp", r = { id = eventId .. "|" .. who, owner = who, rev = rev or 1,
        updatedAt = Stub.serverTime, eventId = eventId, role = role, state = state, joinedAt = joinedAt } }, nil, who)
end

scenarios.events = function()
    local CH = boot()
    local E = CH.GuildEvents
    drain()
    local now = Stub.serverTime
    local base = { category = "dungeon", title = "Deadmines", startAt = now + 2 * 86400, duration = 120,
        capacity = 3, roles = { tank = 1, healer = 1 }, organizerRole = "dps" }
    local id, reason = E:Create(base)
    Stub.advance(30)
    local recs = sentMessages(CH, "REC")
    check(id and id:find("^Ghazneth Strongbow#") and #recs == 1 and recs[1].b.y == "event" and recs[1].b.r.title == "Deadmines",
        "scheduling an event broadcasts it " .. tostring(reason or ""))
    local function bad(over)
        local f = copy(base)
        for k, v in pairs(over) do f[k] = v end
        return E:Create(f) == nil
    end
    check(bad({ category = "raids" }), "rejects unknown category")
    check(bad({ title = " " }), "rejects empty title")
    check(bad({ capacity = 41 }), "rejects groups over 40")
    check(bad({ startAt = now + 90 * 86400 }), "rejects events more than 60 days out")
    check(bad({ duration = 5 }), "rejects too-short duration")

    local e = E:Get(id)
    local lu = E:Lineup(e)
    check(lu.size == 1 and lu.slots.dps[1].organizer, "organizer takes their own slot")
    check(E:EffectiveStatus(e) == "upcoming", "upcoming before the start")

    -- Signups fill role slots in signup order; the rest wait.
    rsvp(CH, id, "Thrall Stormrage", "tank", "going", now - 300)
    rsvp(CH, id, "Ghazneth Ironhide", "tank", "going", now - 200)
    rsvp(CH, id, "Jaina Proudmoore", "healer", "tentative", now - 100)
    e = E:Get(id)
    lu = E:Lineup(e)
    check(#lu.slots.tank == 1 and lu.slots.tank[1].name == "Thrall Stormrage", "first tank gets the slot")
    check(#lu.waitlist == 1 and lu.waitlist[1].name == "Ghazneth Ironhide", "second tank waits (slot full)")
    check(#lu.tentative == 1 and lu.size == 2, "tentative signups don't take a slot")
    check(E:PlacementOf(e, "Ghazneth Ironhide", lu) == "waitlist", "placement reports the waitlist")

    -- The organizer confirms a waiting player past the slot count, and benches another.
    check(E:SetLineup(id, "Ghazneth Ironhide", "tank"), "organizer confirms from the waitlist")
    lu = E:Lineup(E:Get(id))
    check(#lu.slots.tank == 1 and lu.slots.tank[1].name == "Ghazneth Ironhide" and lu.slots.tank[1].confirmed
        and lu.waitlist[1].name == "Thrall Stormrage", "confirmed players come first; the size cap then pushes others out")
    E:SetLineup(id, "Ghazneth Ironhide", "bench")
    lu = E:Lineup(E:Get(id))
    check(lu.slots.tank[1].name == "Thrall Stormrage" and lu.waitlist[1].benched, "benched player waits")
    E:SetLineup(id, "Ghazneth Ironhide", nil)

    -- Peers can't touch the organizer's record or sign up someone else.
    local foreign = copy(E:Get(id))
    foreign.owner, foreign.rev, foreign.title = "Thrall Stormrage", 99, "hijacked"
    peerSend(CH, "REC", { y = "event", r = foreign })
    check(E:Get(id).title == "Deadmines", "event record can't be rewritten by another owner")
    peerSend(CH, "REC", { y = "rsvp", r = { id = id .. "|Jaina Proudmoore", owner = "Thrall Stormrage", rev = 5,
        updatedAt = now, eventId = id, role = "dps", state = "going", joinedAt = now } })
    check(#E:Lineup(E:Get(id)).tentative == 1, "rsvp id must match its owner")
    peerSend(CH, "REC", { y = "rsvp", r = { id = id .. "|Thrall Stormrage", owner = "Thrall Stormrage", rev = 7,
        updatedAt = now, eventId = id, role = "tank", state = "going", joinedAt = now + 999 } })
    check(E:Lineup(E:Get(id)).slots.tank[1].name == "Thrall Stormrage", "rejects a signup time in the future")

    -- Official flag: only from officers.
    peerSend(CH, "REC", { y = "event", r = { id = "Ghazneth Ironhide#aa1", owner = "Ghazneth Ironhide", rev = 1,
        updatedAt = now, category = "raid", title = "Not official", status = "scheduled", startAt = now + 86400,
        duration = 180, capacity = 10, official = true } }, nil, "Ghazneth Ironhide")
    peerSend(CH, "REC", { y = "event", r = { id = "Thrall Stormrage#aa2", owner = "Thrall Stormrage", rev = 1,
        updatedAt = now, category = "raid", title = "Onyxia", status = "scheduled", startAt = now + 3 * 86400,
        duration = 180, capacity = 10, official = true } })
    check(E:Get("Ghazneth Ironhide#aa1") and not E:Get("Ghazneth Ironhide#aa1").official, "member's official flag dropped")
    check(E:Get("Thrall Stormrage#aa2").official, "officer's official flag kept")

    -- Attending someone else's event; changing role keeps your place.
    local tid = "Thrall Stormrage#aa2"
    drain()
    check(E:Respond(tid, "going", "healer"), "sign up for a guildmate's event")
    local mine = E:MyRsvp(tid)
    local joined = mine.joinedAt
    Stub.advance(60)
    E:Respond(tid, "going", "dps")
    mine = E:MyRsvp(tid)
    check(mine.role == "dps" and mine.joinedAt == joined, "changing role keeps the signup time")
    E:Respond(tid, "declined")
    E:Respond(tid, "going", "dps")
    check(E:MyRsvp(tid).joinedAt > joined, "dropping out and back in goes to the end")
    check(not E:Respond(id, "going", "dps"), "organizer can't sign up for their own event")
    recs = sentMessages(CH, "REC")
    check(#recs >= 1 and recs[#recs].b.y == "rsvp", "signups broadcast")

    -- Reminders: once before the start, once at the start, only for events you're in.
    E:SetStatus("Ghazneth Strongbow#none", "cancelled")  -- no-op on a missing event
    Stub.printed = {}
    Stub.advance(3 * 86400 - 14 * 60 - 120)
    E:CheckReminders()
    check(printedContains("Reminder: \"Onyxia\" starts in"), "reminder before an event you're in")
    local count = #Stub.printed
    E:CheckReminders()
    check(#Stub.printed == count, "reminder shown once")
    check(not printedContains("Not official"), "no reminder for events you're not in")
    Stub.advance(16 * 60)
    E:CheckReminders()
    check(printedContains("\"Onyxia\" is starting now"), "reminder at the start")
    check(E:EffectiveStatus(E:Get(tid)) == "inprogress", "in progress after the start")

    -- Cancellation notice for attendees.
    local cancelled = copy(E:Get(tid))
    cancelled.status, cancelled.rev, cancelled.updatedAt = "cancelled", cancelled.rev + 1, Stub.serverTime
    peerSend(CH, "REC", { y = "event", r = cancelled })
    check(printedContains("Thrall Stormrage cancelled \"Onyxia\""), "attendees told about a cancellation")

    -- Pruning a week after the end.
    Stub.advance(9 * 86400)
    CH.Sync:Prune()
    check(E:Get(tid) == nil and CH.Sync:Get("rsvp", tid .. "|Ghazneth Strongbow") == nil,
        "old events and their signups pruned")
    local doomed = E:Create({ category = "social", title = "Delete me", startAt = Stub.serverTime + 3600,
        duration = 60, capacity = 5 })
    check(doomed and E:Delete(doomed) and E:Get(doomed) == nil and CH.Sync:Get("event", doomed).deleted,
        "organizer deletes (tombstone kept)")
    noErrors(CH)
    reportGlobals()
end

scenarios.events_ui = function()
    local CH = boot()
    local E, P = CH.GuildEvents, CH.EventsPage
    local now = Stub.serverTime
    check(P.DayOffset(now + 86400, now) == 1 and P.DayOffset(now, now) == 0, "day offsets")
    local start = P.ComputeStart(2, "20:30", now)
    check(date("%H:%M", start) == "20:30" and P.DayOffset(start, now) == 2, "start from day offset and clock")
    check(P.ComputeStart(0, "nope", now) == nil, "bad clock rejected")

    SlashCmdList.CASUALHUB("events")
    local page = CH.UI.pageFrames.events
    check(page and page:IsShown() and page.empty:IsShown() and not CH.UI.navButtons.events.badge:IsShown(),
        "/chub events opens an empty page, no longer marked 'soon'")
    P:OpenEditor(nil)
    local ed = page.editor
    check(ed:IsShown() and ed.official:IsShown(), "editor opens; officers (GM here) see the Official box")
    ed.title:SetText("Scarlet Monastery")
    ed.clock:SetText("21:00")
    ed.capacity:SetText("5")
    ed.roleBoxes.tank:SetText("1")
    ed.organizerRole.buttons.healer:RunScript("OnClick")
    ed.official:SetChecked(true)
    P:SaveEditor()
    local list = E:List()
    local e = list[1]
    check(not ed:IsShown() and e and e.title == "Scarlet Monastery" and e.organizerRole == "healer" and e.official
        and e.roles.tank == 1 and P.DayOffset(e.startAt, now) == 1 and date("%H:%M", e.startAt) == "21:00",
        "editor schedules the event (tomorrow 21:00 by default)")
    check(#page.list.items == 1 and contains(page.detailBody:GetText(), "Official"), "listed and shown")
    check(page.actionButtons[1]:GetText() == "Edit" and page.actionButtons[2]:GetText() == "Repeat +7d",
        "organizer actions")

    -- Repeat: a new event a week later.
    page.actionButtons[2]:RunScript("OnClick")
    check(ed:IsShown() and ed.title:GetText() == "Scarlet Monastery" and ed.dayOffset == 8, "repeat prefills a week later")
    P:SaveEditor()
    check(#E:List() == 2, "repeat creates a second event")

    -- Suggestions from shared profiles.
    peerSend(CH, "REC", { y = "profile", r = { id = "Ghazneth Ironhide", owner = "Ghazneth Ironhide", rev = 1,
        updatedAt = now, roles = { "tank" }, days = { ({ "sun", "mon", "tue", "wed", "thu", "fri", "sat" })[date("*t", e.startAt).wday] },
        times = { "evening" } } }, nil, "Ghazneth Ironhide")
    peerSend(CH, "REC", { y = "profile", r = { id = "Jaina Proudmoore", owner = "Jaina Proudmoore", rev = 1,
        updatedAt = now, roles = { "dps" } } }, nil, "Jaina Proudmoore")
    local sugg = E:Suggestions(E:Get(e.id))
    check(#sugg == 2 and sugg[1].name == "Ghazneth Ironhide" and sugg[1].dayMatch and sugg[1].timeMatch,
        "suggestions ranked by availability fit")
    P:Select(e.id)
    page.actionButtons[3]:RunScript("OnClick")
    check(P.view == "suggestions" and page.lineup.items[2].suggestion, "Suggestions view in the detail panel")
    rsvp(CH, e.id, "Ghazneth Ironhide", "tank", "going", now)
    check(#E:Suggestions(E:Get(e.id)) == 1, "signed-up members drop out of suggestions")
    page.actionButtons[3]:RunScript("OnClick")
    local found
    for _, item in ipairs(page.lineup.items) do if item.entry and item.entry.name == "Ghazneth Ironhide" then found = item end end
    check(P.view == "lineup" and found and found.section == "lineup", "lineup shows the new tank")

    -- Attendee view of a guildmate's event.
    peerSend(CH, "REC", { y = "event", r = { id = "Thrall Stormrage#zz1", owner = "Thrall Stormrage", rev = 1,
        updatedAt = now, category = "raid", title = "Molten Core", status = "scheduled", startAt = now + 4 * 86400,
        duration = 240, capacity = 40, roles = { tank = 4, healer = 8 } } })
    P:Select("Thrall Stormrage#zz1")
    check(page.actionButtons[1]:GetText() == "Go: Tank" and page.actionButtons[5]:GetText() == "Can't go",
        "signup buttons per role")
    page.actionButtons[2]:RunScript("OnClick")
    local r = E:MyRsvp("Thrall Stormrage#zz1")
    check(r and r.role == "healer" and r.state == "going" and contains(page.detailBody:GetText(), "In (Healer)"),
        "signing up shows your placement")

    SlashCmdList.CASUALHUB("dashboard")
    local dash = CH.UI.pageFrames.dashboard.eventsCard.body:GetText()
    check(contains(dash, "Scarlet Monastery") and contains(dash, "Molten Core"), "dashboard lists upcoming events")
    SlashCmdList.CASUALHUB("settings")
    local settings = CH.UI.pageFrames.settings
    check(settings.notifyEvents:GetChecked() and settings.eventLead.value == 15, "reminder settings shown")
    settings.eventLead.buttons[30]:RunScript("OnClick")
    check(CH.Settings:Get("notifications.eventLead") == 30, "reminder lead saved")
    noErrors(CH)
    reportGlobals()
end

---------------------------------------------------------------------------
-- Phase 5: Professions
---------------------------------------------------------------------------

local function fakeTradeSkill(professionID, name, recipes)
    -- recipes: { {id, name, learned} }
    _G.C_TradeSkillUI = {
        GetBaseProfessionInfo = function() return { professionID = professionID, professionName = name,
            skillLevel = 150, maxSkillLevel = 225 } end,
        GetAllRecipeIDs = function()
            local ids = {}
            for i, r in ipairs(recipes) do ids[i] = r[1] end
            return ids
        end,
        GetRecipeInfo = function(id)
            for _, r in ipairs(recipes) do if r[1] == id then return { recipeID = id, name = r[2], learned = r[3] } end end
        end,
        IsTradeSkillLinked = function() return false end,
        IsTradeSkillGuild = function() return false end,
    }
end

scenarios.professions = function()
    local CH = boot()
    local P = CH.Professions
    -- Encoding
    local text, n = P.EncodeRecipes({ 2153, 2149, 2152, 2149, 9060 })
    local back = P.DecodeRecipes(text)
    check(n == 4 and #back == 4 and back[1] == 2149 and back[4] == 9060, "recipe IDs round-trip (sorted, deduped)")
    check(#text < 20, "encoding is compact: " .. text)
    check(P.DecodeRecipes("12.0.3") == nil and P.DecodeRecipes("ab|c") == nil, "malformed recipe strings rejected")

    -- Skill levels from the profession list, recipes from the window.
    _G.GetProfessions = function() return 1, 2, nil, nil, 3 end
    local info = { { "Leatherworking", 165, 150, 225 }, { "Skinning", 393, 160, 225 }, { "Cooking", 185, 60, 75 } }
    _G.GetProfessionInfo = function(i)
        local p = info[i]
        return p[1], "icon", p[3], p[4], 0, 0, p[2]
    end
    CH.Professions:RefreshSkills()
    check(#P:MyEntries() == 3 and P:MyEntry(165).skill == 150 and P:MyEntry(165).source == "scan", "professions detected")
    fakeTradeSkill(165, "Leatherworking", { { 2149, "Handstitched Leather Boots", true },
        { 2152, "Light Armor Kit", true }, { 9060, "Heavy Leather Ball", false } })
    drain()
    Stub.fire("TRADE_SKILL_SHOW")
    local lw = P:MyEntry(165)
    check(lw.count == 2 and P.DecodeRecipes(lw.recipes)[2] == 2152 and lw.scannedAt, "only learned recipes captured")
    check(P:RecipeName(9060) == "Heavy Leather Ball", "names of every recipe in the window cached")
    Stub.advance(25)
    local recs = sentMessages(CH, "REC")
    local published = {}
    for _, m in ipairs(recs) do if m.b.y == "craft" then published[m.b.r.id] = m.b.r end end
    check(published["Ghazneth Strongbow|165"] and published["Ghazneth Strongbow|165"].recipes == lw.recipes,
        "recipes published after a short delay")
    check(CH.Sync:Get("craft", "Ghazneth Strongbow|393") and not CH.Sync:Get("craft", "Ghazneth Strongbow|393").deleted,
        "professions without a window scan are shared too (skill only)")
    local count = #Stub.sent
    Stub.fire("TRADE_SKILL_SHOW")
    Stub.advance(25)
    check(#Stub.sent == count, "reopening the window with nothing new sends nothing")

    -- Linked (someone else's) windows are ignored.
    C_TradeSkillUI.IsTradeSkillLinked = function() return true end
    fakeTradeSkill(171, "Alchemy", { { 2330, "Minor Healing Potion", true } })
    C_TradeSkillUI.IsTradeSkillLinked = function() return true end
    Stub.fire("TRADE_SKILL_SHOW")
    check(P:MyEntry(171) == nil, "linked profession windows aren't captured as yours")

    -- Guildmates' professions and search.
    local enc = P.EncodeRecipes({ 2330, 2332, 3170 })
    peerSend(CH, "REC", { y = "craft", r = { id = "Thrall Stormrage|171", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, skillLine = 171, name = "Alchemy", skill = 200, maxSkill = 225, source = "scan",
        scannedAt = Stub.serverTime - 86400, specialty = "Potions", recipes = enc } })
    peerSend(CH, "REC", { y = "craft", r = { id = "Jaina Proudmoore|197", owner = "Jaina Proudmoore", rev = 1,
        updatedAt = Stub.serverTime, skillLine = 197, source = "manual", note = "Mageweave bags" } }, nil, "Jaina Proudmoore")
    peerSend(CH, "REC", { y = "craft", r = { id = "Thrall Stormrage|999", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, skillLine = 171, source = "scan" } })
    check(CH.Sync:Get("craft", "Thrall Stormrage|999") == nil, "record id must match its profession")
    local names = { [2330] = "Minor Healing Potion", [2332] = "Minor Rejuvenation Potion", [3170] = "Weak Troll's Blood Elixir" }
    _G.C_Spell = { GetSpellName = function(id) return names[id] end }
    local rows = P:Search("potion")
    check(#rows == 3 and not rows[1].recipeName and rows[2].recipeName == "Minor Healing Potion"
        and rows[3].recipeName == "Minor Rejuvenation Potion" and rows[2].record.owner == "Thrall Stormrage",
        "search matches the crafter (specialty \"Potions\") and resolves recipe names through the spell API")
    rows = P:Search("bags")
    check(#rows == 1 and rows[1].record.owner == "Jaina Proudmoore" and not rows[1].recipeName, "notes are searchable")
    check(#P:Search("", 171) == 1 and #P:Search("", nil, true) == 4, "profession and online filters")
    check(P:RecipeLabel(424242) == "Recipe #424242", "unknown recipes get a placeholder")

    -- Names the client hasn't loaded yet: requested on arrival, filled in when the spell data loads.
    local loaded, requested = {}, {}
    _G.C_Spell = { GetSpellName = function(id) return loaded[id] or names[id] end,
        RequestLoadSpellData = function(sid) requested[sid] = true end }
    local refreshed = 0
    CH.Events:Subscribe("RECIPE_NAMES_LOADED", "test", function() refreshed = refreshed + 1 end)
    peerSend(CH, "REC", { y = "craft", r = { id = "Thrall Stormrage|202", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, skillLine = 202, source = "scan", recipes = P.EncodeRecipes({ 3918, 3919 }) } })
    check(requested[3918] and requested[3919], "names requested as soon as a guildmate's recipes arrive")
    check(P:RecipeLabel(3918) == "Recipe #3918", "placeholder until the name loads")
    loaded[3918] = "Rough Blasting Powder"
    Stub.fire("SPELL_DATA_LOAD_RESULT", 3918, true)
    Stub.fire("SPELL_DATA_LOAD_RESULT", 3919, false)
    Stub.advance(1)
    check(P:RecipeName(3918) == "Rough Blasting Powder" and refreshed == 1, "loaded name cached and the page told once")
    check(#P:Search("blasting") == 1, "loaded names are searchable")
    CH.Events:Unsubscribe("RECIPE_NAMES_LOADED", "test")

    -- Sharing off retracts everything.
    drain()
    CH.Settings:Set("professions.share", false)
    recs = sentMessages(CH, "REC")
    local tombs = 0
    for _, m in ipairs(recs) do if m.b.y == "craft" and m.b.r.deleted then tombs = tombs + 1 end end
    check(tombs == 3, "turning sharing off retracts all three professions")
    CH.Settings:Set("professions.share", true)

    -- Manual entries.
    check(P:SaveMine(197, { skill = "120", specialty = "Bags" }) and P:MyEntry(197).source == "manual"
        and P:MyEntry(197).skill == 120, "manual profession added")
    check(P:RemoveMine(197) and P:MyEntry(197) == nil, "manual profession removed")
    check(not P:RemoveMine(165), "scanned professions can't be removed by hand")

    -- Requests and offers.
    drain()
    local itemID, title = P.ParseItemText("|cff1eff00|Hitem:4240::::::::29:::::|h[Blue Linen Bag]|h|r")
    check(itemID == 4240 and title == "Blue Linen Bag", "item links parsed")
    local id = P:CreateRequest({ kind = "craft", title = "Minor Healing Potion", skillLine = 171, quantity = 5,
        expiresAt = Stub.serverTime + 3 * 86400 })
    check(id and P:GetRequest(id).quantity == 5, "craft request posted")
    local who = P:CraftersFor(P:GetRequest(id))
    check(#who == 1 and who[1].name == "Thrall Stormrage", "known crafters suggested for a request")
    check(not P:CreateRequest({ kind = "craft", title = "x", expiresAt = Stub.serverTime + 20 * 86400 }), "rejects long expiry")
    peerSend(CH, "REC", { y = "craftoffer", r = { id = id .. "|Thrall Stormrage", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, requestId = id, state = "offered", note = "have mats" } })
    check(P:ActiveOfferCount(P:GetRequest(id)) == 1 and printedContains("Thrall Stormrage can help with"),
        "offer received and requester told")
    check(not P:Offer(id), "can't offer on your own request")
    check(P:SetRequestStatus(id, "done") and P:EffectiveStatus(P:GetRequest(id)) == "done", "request marked done")
    peerSend(CH, "REC", { y = "craftreq", r = { id = "Thrall Stormrage#q1", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, kind = "materials", title = "Silverleaf", quantity = 20, status = "open",
        expiresAt = Stub.serverTime + 86400, itemID = 765 } })
    check(P:Offer("Thrall Stormrage#q1", "I have 12") and P:MyOffer("Thrall Stormrage#q1").state == "offered", "offer to help")
    check(P:WithdrawOffer("Thrall Stormrage#q1") and P:MyOffer("Thrall Stormrage#q1").state == "withdrawn", "withdraw offer")

    -- Auctionator prices, when installed.
    check(P:Price(765) == nil, "no prices without Auctionator")
    _G.Auctionator = { API = { v1 = {
        GetAuctionPriceByItemID = function(caller, item) assert(caller == "Casual Hub") return item == 765 and 1234 or nil end,
        GetAuctionAgeByItemID = function() return 2 end } } }
    local price, age = P:Price(765)
    check(price == 1234 and age == 2, "Auctionator price and age")
    check(CH.FormatMoney(123456):find("12g") and CH.FormatMoney(123456):find("34s"), "money formatting")
    _G.Auctionator.API.v1.GetAuctionPriceByItemID = function() error("boom") end
    check(P:Price(765) == nil, "Auctionator errors are contained")
    _G.Auctionator = nil

    Stub.advance(5 * 86400)
    CH.Sync:Prune()
    check(P:GetRequest(id) == nil and P:GetRequest("Thrall Stormrage#q1") == nil, "finished and expired requests pruned")
    _G.C_TradeSkillUI, _G.C_Spell, _G.GetProfessions, _G.GetProfessionInfo = nil, nil, nil, nil
    noErrors(CH)
    reportGlobals()
end

scenarios.professions_ui = function()
    local CH = boot()
    local P, Page = CH.Professions, CH.ProfessionsPage
    _G.C_Spell = { GetSpellName = function(id) return ({ [2330] = "Minor Healing Potion" })[id] end }
    peerSend(CH, "REC", { y = "craft", r = { id = "Thrall Stormrage|171", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, skillLine = 171, skill = 200, maxSkill = 225, source = "scan",
        scannedAt = Stub.serverTime - 3600, recipes = P.EncodeRecipes({ 2330 }) } })
    SlashCmdList.CASUALHUB("professions")
    local page = CH.UI.pageFrames.professions
    check(page and page:IsShown() and not CH.UI.navButtons.professions.badge:IsShown() and #page.list.items == 1,
        "/chub professions lists crafters; no longer marked 'soon'")
    page.search:SetText("healing")
    page.search:GetScript("OnTextChanged")(page.search, true)
    check(#page.list.items == 1 and page.list.items[1].recipeName == "Minor Healing Potion", "search finds the recipe")
    Page:Select(page.list.items[1])
    check(contains(page.detailTitle:GetText(), "Thrall Stormrage") and contains(page.detailBody:GetText(), "profession window")
        and page.lines.items[2] and contains(page.lines.items[2].text, "Minor Healing Potion"), "crafter detail with source and recipes")
    local requestButton
    for _, b in ipairs(page.actionButtons) do if b:IsShown() and b:GetText() == "Request a craft" then requestButton = b end end
    check(requestButton, "Request a craft offered")
    requestButton:RunScript("OnClick")
    local ed = page.editor
    check(ed:IsShown() and ed.item:GetText() == "Minor Healing Potion" and ed.profession:Get() == 171,
        "request editor prefilled from the recipe")
    ed.quantity:SetText("3")
    Page:SaveEditor()
    local q = P:Requests()[1]
    check(not ed:IsShown() and q and q.title == "Minor Healing Potion" and q.quantity == 3 and Page.view == "requests",
        "request posted from the crafter view")
    check(contains(page.detailBody:GetText(), "Known crafters") and contains(page.detailBody:GetText(), "Thrall Stormrage"),
        "request shows who can craft it")

    -- Materials, cost and Auctionator: recipe 2330 needs 1 Peacebloom + 1 Silverleaf, makes 1 Minor Healing Potion.
    local itemNames = { [2447] = "Peacebloom", [765] = "Silverleaf", [118] = "Minor Healing Potion" }
    _G.C_TradeSkillUI = {
        GetRecipeOutputItemData = function(id) if id == 2330 then return { itemID = 118 } end end,
        GetRecipeSchematic = function(id) if id == 2330 then return { quantityMin = 1, reagentSlotSchematics = {
            { reagents = { { itemID = 2447 } }, quantityRequired = 1 },
            { reagents = { { itemID = 765 } }, quantityRequired = 1 },
            { reagents = { { itemID = 9999 } }, quantityRequired = 1, required = false } } } end end,
    }
    _G.C_Item = { GetItemNameByID = function(id) return itemNames[id] end }
    local lists = {}
    _G.Auctionator = { API = { v1 = {
        GetAuctionPriceByItemID = function(_, id) return ({ [2447] = 300, [765] = 500, [118] = 2500 })[id] end,
        GetAuctionAgeByItemID = function() return 1 end,
        ConvertToSearchString = function(_, term) return '"' .. term.searchString .. '";;;;;;;;;;;;;;;' .. term.quantity end,
        CreateShoppingList = function(caller, name, terms) lists[name] = { caller = caller, terms = terms } end,
    } } }
    local cost = P:CraftCost(2330, 3)
    check(cost and #cost.mats == 2 and cost.total == 2400 and cost.mats[1].qty == 3 and cost.item == 118,
        "material cost for three (optional reagents left out)")
    Page:SetView("requests")
    Page:Select(q)
    local body = page.detailBody:GetText()
    check(contains(body, "3x Peacebloom") and contains(body, "Material cost") and contains(body, "Sells for")
        and contains(body, "not live"), "request shows materials, cost and sale price with the scan age")
    local shop
    for _, b in ipairs(page.actionButtons) do if b:IsShown() and b:GetText() == "Shopping list" then shop = b end end
    check(shop, "Shopping list button with Auctionator")
    shop:RunScript("OnClick")
    local list = lists["Casual Hub: Minor Healing Potion x3"]
    check(list and list.caller == "Casual Hub" and #list.terms == 2 and contains(list.terms[1], "Peacebloom"),
        "Auctionator shopping list created with the materials")

    Page:SetView("crafters")
    Page:Select({ record = P:Crafters()[1] })
    page.lines.rows[2]:RunScript("OnClick")
    check(Page.selectedRecipe == 2330 and contains(page.detailBody:GetText(), "Material cost"), "clicking a recipe shows its cost")
    page.lines.rows[2]:RunScript("OnEnter")
    page.lines.rows[2]:RunScript("OnLeave")
    _G.Auctionator, _G.C_TradeSkillUI, _G.C_Item = nil, nil, nil

    Page:SetView("mine")
    check(page.mineTools:IsShown() and not page.crafterTools:IsShown() and page.empty:IsShown(), "My professions view")
    page.addManual:RunScript("OnClick")
    check(P:MyEntry(171) and P:MyEntry(171).source == "manual" and page.mineEditor:IsShown(), "add a profession by hand")
    page.mineEditor.specialty:SetText("Elixirs")
    page.mineEditor.skill:SetText("90")
    Page:SaveMine()
    check(P:MyEntry(171).specialty == "Elixirs" and P:MyEntry(171).skill == 90, "specialty and skill saved")
    _G.C_Spell = nil
    noErrors(CH)
    reportGlobals()
end

---------------------------------------------------------------------------
-- Phase 6: Bulletin, guild policy, reports
---------------------------------------------------------------------------

local function guildRanks()
    local names = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }
    _G.GuildControlGetNumRanks = function() return #names end
    _G.GuildControlGetRankName = function(i) return names[i] end
end

local function notice(id, owner, fields, rev)
    local r = { id = id, owner = owner, rev = rev or 1, updatedAt = Stub.serverTime }
    for k, v in pairs(fields) do r[k] = v end
    return r
end

scenarios.bulletin = function()
    guildRanks()
    local CH = boot()
    local B = CH.Bulletin
    drain()
    local now = Stub.serverTime
    local id = B:Post({ kind = "announcement", title = "Raid night moved", body = "Thursday 20:00\nBring flasks",
        expiresAt = now + 7 * 86400, pinned = true })
    Stub.advance(30)
    local recs = sentMessages(CH, "REC")
    check(id and #recs == 1 and recs[1].b.y == "notice" and recs[1].b.r.body == "Thursday 20:00\nBring flasks",
        "guild master posts a notice (line breaks kept)")
    check(not B:Post({ kind = "announcement", title = "x", expiresAt = now + 90 * 86400 }), "rejects expiry over 60 days")
    check(B:IsRead(B:Get(id)) and B:UnreadCount() == 0, "your own notices count as read")

    -- Authority comes from rank: officers may post, members may not (default policy).
    peerSend(CH, "REC", { y = "notice", r = notice("Ghazneth Ironhide#n1", "Ghazneth Ironhide",
        { kind = "announcement", title = "Free gold", expiresAt = now + 86400 }) }, nil, "Ghazneth Ironhide")
    check(B:Get("Ghazneth Ironhide#n1") == nil, "members can't post notices by default")
    peerSend(CH, "REC", { y = "notice", r = notice("Thrall Stormrage#n1", "Thrall Stormrage",
        { kind = "rule", title = "Be kind", body = "No drama in guild chat." }) })
    check(B:Get("Thrall Stormrage#n1") and #B:Rules() == 1, "officer posts a guild rule")
    Stub.advance(1)
    check(B:UnreadCount() == 1 and CH.UI.navCounts and CH.UI.navCounts.bulletin == 1, "unread count on the sidebar")
    B:MarkRead(B:Get("Thrall Stormrage#n1"))
    check(B:UnreadCount() == 0, "marked read")
    peerSend(CH, "REC", { y = "notice", r = notice("Thrall Stormrage#n1", "Thrall Stormrage",
        { kind = "rule", title = "Be kind", body = "No drama in guild chat or Discord." }, 2) })
    check(B:UnreadCount() == 1, "an edit makes it unread again")

    -- Login summary, then live pinned notices.
    Stub.printed = {}
    B.announced = false
    B:AnnounceUnread()
    check(printedContains("1 new guild notice"), "unread summary after login")
    peerSend(CH, "REC", { y = "notice", r = notice("Thrall Stormrage#n2", "Thrall Stormrage",
        { kind = "announcement", title = "Onyxia tonight", pinned = true, expiresAt = now + 86400 }) })
    check(printedContains("New pinned notice from Thrall Stormrage"), "pinned notice announced while online")

    -- Guild policy from the guild master.
    check(B:SavePolicy({ rankRoles = { ["3"] = "officer" }, noticeRole = "member",
        checklist = { "Join the Discord", "  ", "Fill in your profile" } }), "guild master saves the policy")
    local p = B:Policy()
    check(p and #p.checklist == 2 and p.noticeRole == "member", "policy stored (blank checklist items dropped)")
    check(CH.Permissions:RoleOf("Ghazneth Ironhide") == "officer"
        and CH.GuildEvents:IsOfficer("Ghazneth Ironhide"), "policy rank mapping applies (rank 3 now officer)")
    peerSend(CH, "REC", { y = "notice", r = notice("Jaina Proudmoore#n1", "Jaina Proudmoore",
        { kind = "announcement", title = "Selling bags", expiresAt = now + 86400 }) }, nil, "Jaina Proudmoore")
    check(B:Get("Jaina Proudmoore#n1"), "with noticeRole=member anyone may post")
    peerSend(CH, "REC", { y = "policy", r = { id = "policy|Thrall Stormrage", owner = "Thrall Stormrage", rev = 1,
        updatedAt = now, rankRoles = { ["1"] = "member" }, noticeRole = "officer" } })
    check(CH.Sync:Get("policy", "policy|Thrall Stormrage") == nil and B:Policy().owner == "Ghazneth Strongbow",
        "a policy from anyone but the guild master is refused")
    peerSend(CH, "REC", { y = "policy", r = { id = "policy|Ghazneth Strongbow", owner = "Ghazneth Strongbow", rev = 99,
        updatedAt = now, noticeRole = "officer" } })
    check(B:Policy().noticeRole == "member", "our own policy can't be overwritten by a forged higher revision")

    -- Checklist progress is local.
    check(select(2, B:ChecklistProgress()) == 2 and select(1, B:ChecklistProgress()) == 0, "checklist starts empty")
    B:SetChecked("Join the Discord", true)
    check(B:ChecklistProgress() == 1, "ticking an item")
    B:SetChecked("An item that was removed", true)
    CH.Store:Bucket("noticeRead", true)["Thrall Stormrage#gone"] = 3
    B:PruneLocal()
    check(B:IsChecked("Join the Discord") and not B:IsChecked("An item that was removed")
        and CH.Store:Bucket("noticeRead", true)["Thrall Stormrage#gone"] == nil
        and CH.Store:Bucket("noticeRead", true)["Thrall Stormrage#n1"], "stale read marks and checklist ticks cleaned up")

    -- Expiry and pruning.
    Stub.advance(2 * 86400)
    check(#B:List() < #B:List(true), "expired announcements hidden by default")
    Stub.advance(12 * 86400)
    CH.Sync:Prune()
    check(B:Get("Thrall Stormrage#n2") == nil and B:Get("Thrall Stormrage#n1"), "expired announcements pruned; rules stay")
    local fresh = B:Post({ kind = "announcement", title = "Delete me", expiresAt = Stub.serverTime + 86400 })
    check(fresh and B:Delete(fresh) and B:Get(fresh) == nil and CH.Sync:Get("notice", fresh).deleted, "author deletes")
    _G.GuildControlGetNumRanks, _G.GuildControlGetRankName = nil, nil
    noErrors(CH)
    reportGlobals()
end

scenarios.analytics = function()
    local CH = boot()
    local An, E, A = CH.Analytics, CH.GuildEvents, CH.Activities
    check(An.WeekOf(os.time({ year = 2026, month = 11, day = 19, hour = 15 })) == "2026-11-16"
        and An.WeekOf(os.time({ year = 2026, month = 11, day = 16, hour = 1 })) == "2026-11-16"
        and An.WeekOf(os.time({ year = 2026, month = 11, day = 22, hour = 23 })) == "2026-11-16", "weeks start on Monday")
    drain()
    local now = Stub.serverTime
    local eid = E:Create({ category = "dungeon", title = "RFK", startAt = now + 3600, duration = 60, capacity = 5,
        organizerRole = "dps" })
    rsvp(CH, eid, "Thrall Stormrage", "tank", "going", now - 10)
    rsvp(CH, eid, "Ghazneth Ironhide", "healer", "going", now - 5)
    local aid = A:Create({ category = "quests", title = "Help", expiresAt = now + 6 * 3600 })
    An:Collect()
    local r = An:Report()[1]
    check(r and r.events == 0 and r.activitiesPosted == 1 and r.users >= 1, "posted requests counted right away")
    Stub.advance(3 * 3600)
    A:SetStatus(aid, "completed")
    An:Collect()
    An:Collect()
    r = An:Report()[1]
    check(r.events == 1 and r.attendees == 3 and math.abs(r.avgLineup - 3) < 0.01 and r.byCategory.dungeon == 1,
        "finished event counted once with its lineup")
    check(r.activitiesCompleted == 1 and r.activitiesPosted == 1, "completed activity counted once")
    local csv = An:CSV()
    check(csv:find("^week,events") and csv:find("\n" .. r.week .. ",1,0,3.0,0,3,1,1,0,0,0,", 1, true), "CSV export")
    check(not csv:find("Thrall"), "no names in the export")
    -- Retention: only the last 12 weeks are kept.
    for i = 1, 14 do
        Stub.advance(7 * 86400)
        An:Collect()
    end
    check(#An:Report(99) == 12, "older weeks dropped after 12")
    noErrors(CH)
    reportGlobals()
end

scenarios.bulletin_ui = function()
    guildRanks()
    local CH = boot()
    local B, Page = CH.Bulletin, CH.BulletinPage
    SlashCmdList.CASUALHUB("bulletin")
    local page = CH.UI.pageFrames.bulletin
    check(page and page:IsShown() and page.newNotice:IsShown() and page.viewRow.buttons.reports:IsShown(),
        "/chub bulletin opens; the guild master can post and see reports")
    page.newNotice:RunScript("OnClick")
    local ed = page.editor
    check(ed:IsShown() and ed.expiry.buttons[14]:IsShown(), "notice editor (announcements expire)")
    ed.kind.buttons.rule:RunScript("OnClick")
    check(not ed.expiry.buttons[14]:IsShown(), "rules have no expiry")
    ed.title:SetText("Loot rules")
    ed.body:SetText("Need before greed.\nAsk before rolling on BoEs.")
    Page:SaveEditor()
    local n = B:List()[1]
    check(not ed:IsShown() and n and n.kind == "rule" and n.body:find("\n"), "rule posted from the editor")
    check(#page.list.items == 1 and contains(page.detailBody:GetText(), "Ask before rolling"), "notice shown")

    B:SavePolicy({ checklist = { "Join the Discord", "Read the loot rules" } })
    Page:SetView("welcome")
    check(#page.list.items == 2 and contains(page.detailBody:GetText(), "Loot rules") and contains(page.detailBody:GetText(), "0/2"),
        "welcome checklist and guild rules")
    page.list.rows[1]:RunScript("OnClick")
    check(B:IsChecked("Join the Discord") and contains(page.detailBody:GetText(), "1/2"), "ticking a checklist item")

    Page:SetView("reports")
    check(Page.view == "reports" and contains(page.detailTitle:GetText(), "Week of"), "reports view")

    Page:SetView("policy")
    check(#page.list.items == 5 and page.policyEditor:IsShown(), "guild policy lists the ranks with the checklist editor")
    page.list.rows[3]:RunScript("OnClick")  -- rank index 2 (Veteran): member -> officer
    check(Page:DraftRole(2) == "officer" and Page.dirty, "clicking a rank toggles it in the draft")
    page.policyEditor.items[3]:SetText("Say hi in guild chat")
    page.policyEditor.items[3]:GetScript("OnTextChanged")(page.policyEditor.items[3], true)
    Page:SavePolicy()
    local p = B:Policy()
    check(p.rankRoles["2"] == "officer" and #p.checklist == 3 and CH.Permissions:RoleOf("Jaina Proudmoore") == "officer",
        "policy saved and shared")
    SlashCmdList.CASUALHUB("dashboard")
    B:Post({ kind = "announcement", title = "Pinned news", pinned = true, expiresAt = Stub.serverTime + 86400 })
    SlashCmdList.CASUALHUB("dashboard")
    check(contains(CH.UI.pageFrames.dashboard.motdCard.body:GetText(), "Pinned news"), "dashboard shows pinned notices")
    _G.GuildControlGetNumRanks, _G.GuildControlGetRankName = nil, nil
    noErrors(CH)
    reportGlobals()
end

---------------------------------------------------------------------------
-- Load test (not part of run.sh): a large guild's worth of synced data, timing the hot paths.
---------------------------------------------------------------------------

scenarios.perf = function()
    local roster = { { "Ghazneth Strongbow", "Guild Master", 0, 29, "Hunter", "Zone", true, "HUNTER" } }
    for i = 1, 119 do
        roster[#roster + 1] = { ("Member%03d Test"):format(i), "Member", i % 5 == 0 and 1 or 3, 20 + i % 40, "Warrior",
            "Zone", i % 3 == 0, "WARRIOR" }
    end
    local CH = boot({ roster = roster })
    local S, now = CH.Sync, Stub.serverTime
    local clock = os.clock
    local function timed(label, fn, reps)
        reps = reps or 1
        collectgarbage("collect")
        local kb0, t0 = collectgarbage("count"), clock()
        for _ = 1, reps do fn() end
        local ms = (clock() - t0) * 1000 / reps
        print(("  %-44s %8.2f ms   %+8.0f KB garbage/run"):format(label, ms, (collectgarbage("count") - kb0) / reps))
        return ms
    end
    local function rec(typeName, r, sender)
        r.rev, r.updatedAt = r.rev or 1, r.updatedAt or now
        return S:Accept(typeName, r, sender or r.owner)
    end
    local names = {}
    for i = 2, #roster do names[#names + 1] = roster[i][1] end
    collectgarbage("collect")
    local baseKB = collectgarbage("count")
    print(("  baseline after login: %.0f KB"):format(baseKB))

    timed("accept 119 profiles", function()
        for _, n in ipairs(names) do rec("profile", { id = n, owner = n, roles = { "dps" }, days = { "fri" }, times = { "evening" } }) end
    end)
    timed("accept 300 activities + 1500 signups", function()
        for i = 1, 300 do
            local o = names[i % #names + 1]
            local id = o .. "#a" .. i
            rec("activity", { id = id, owner = o, category = "dungeons", title = "Run " .. i, status = "open",
                expiresAt = now + 86400, roles = { tank = 1, dps = 3 }, capacity = 5 })
            for j = 1, 5 do
                local v = names[(i + j * 7) % #names + 1]
                if v ~= o then rec("signup", { id = id .. "|" .. v, owner = v, activityId = id, role = "dps", state = "volunteered" }) end
            end
        end
    end)
    timed("accept 100 events + 2000 rsvps", function()
        for i = 1, 100 do
            local o = names[i % #names + 1]
            local id = o .. "#e" .. i
            rec("event", { id = id, owner = o, category = "raid", title = "Raid " .. i, status = "scheduled",
                startAt = now + i * 3600, duration = 180, capacity = 40, roles = { tank = 4, healer = 8 } })
            for j = 1, 20 do
                local v = names[(i + j * 5) % #names + 1]
                if v ~= o then rec("rsvp", { id = id .. "|" .. v, owner = v, eventId = id, role = j % 3 == 0 and "tank" or "dps",
                    state = "going", joinedAt = now - j }) end
            end
        end
    end)
    local P = CH.Professions
    timed("accept 400 professions (150 recipes each)", function()
        for i = 1, 400 do
            local o = names[i % #names + 1]
            local ids = {}
            for k = 1, 150 do ids[k] = 2000 + i * 7 + k * 13 end
            local skill = ({ 171, 164, 333, 202, 165, 197, 185, 129 })[math.floor(i / #names) % 8 + 1]
            rec("craft", { id = o .. "|" .. skill, owner = o, skillLine = skill, skill = 200, maxSkill = 300, source = "scan",
                scannedAt = now - 60, recipes = P.EncodeRecipes(ids) })
        end
    end)
    timed("accept 100 notices", function()
        for i = 1, 100 do
            rec("notice", { id = "Member005 Test#n" .. i, owner = "Member005 Test", kind = "announcement", title = "News " .. i,
                body = string.rep("text ", 60), expiresAt = now + 86400 })
        end
    end)
    collectgarbage("collect")
    local loadedKB = collectgarbage("count")
    local counts = {}
    for t in pairs(S.types) do local n = 0 for _ in S:Iterate(t) do n = n + 1 end counts[#counts + 1] = t .. "=" .. n end
    table.sort(counts)
    print(("  memory with data loaded: %.0f KB (+%.0f KB)   %s"):format(loadedKB, loadedKB - baseKB, table.concat(counts, " ")))

    local names2 = {}
    _G.C_Spell = { GetSpellName = function(id) names2[id] = names2[id] or ("Recipe Name " .. id) return names2[id] end }
    timed("digest of every type", function() for t in pairs(S.types) do S:Digest(t) end end)
    timed("Activities:List()", function() CH.Activities:List() end)
    timed("Events:List() + Lineup of all 100", function()
        for _, e in ipairs(CH.GuildEvents:List()) do CH.GuildEvents:Lineup(e) end
    end)
    timed("Events:CheckReminders()", function() CH.GuildEvents:CheckReminders() end)
    timed("Professions:Search('') ", function() P:Search("") end)
    timed("Professions:Search('name 3')", function() P:Search("name 3") end)
    timed("Professions:Search('name 3') again (cached)", function() P:Search("name 3") end)
    timed("Bulletin:UnreadCount()", function() CH.Bulletin:UnreadCount() end)
    timed("Analytics:Collect()", function() CH.Analytics:Collect() end)
    for _, page in ipairs({ "dashboard", "members", "activities", "events", "professions", "bulletin" }) do
        SlashCmdList.CASUALHUB(page)
        timed("open + refresh page " .. page, function() CH.UI:SelectPage(page) end)
    end
    timed("Sync:Prune()", function() S:Prune() end)
    collectgarbage("collect")
    print(("  memory after all of the above: %.0f KB"):format(collectgarbage("count")))
    Stub.fire("PLAYER_LOGOUT")
    local saved = Stub.serialize(CasualHubDB)
    print(("  SavedVariables size: %.0f KB account, %.0f KB character"):format(#saved / 1024,
        #Stub.serialize(CasualHubCharDB) / 1024))
    local parts = {}
    for ns, bucket in pairs(CasualHubDB.data.guilds["Da Filthy Casuals"] or {}) do
        parts[#parts + 1] = { ns, #Stub.serialize(bucket) / 1024 }
    end
    table.sort(parts, function(x, y) return x[2] > y[2] end)
    local out = {}
    for i = 1, math.min(6, #parts) do out[i] = ("%s %.0f KB"):format(parts[i][1], parts[i][2]) end
    print("  largest: " .. table.concat(out, ", "))
    local one = CasualHubDB.data.guilds["Da Filthy Casuals"].rsvps
    local _, sample = next(one)
    print("  one rsvp as saved: " .. Stub.serialize(sample):gsub("%s+", " "))
    _G.C_Spell = nil
end

---------------------------------------------------------------------------
-- Blacklist
---------------------------------------------------------------------------

-- A fake group and units: units = { party1 = "First Last", ... }.
local function fakeUnits(units, inRaid)
    _G.UnitExists = function(u) return units[u] ~= nil end
    _G.UnitIsPlayer = function(u) return units[u] ~= nil end
    local realGetUnitName = GetUnitName
    _G.GetUnitName = function(u, full)
        if units[u] then return units[u] end
        return realGetUnitName(u, full)
    end
    _G.IsInGroup = function() return next(units) ~= nil end
    _G.IsInRaid = function() return inRaid or false end
    _G.GetNumGroupMembers = function() local n = 0 for _ in pairs(units) do n = n + 1 end return n end
end

scenarios.blacklist = function()
    local tooltipHandler
    local CH = boot({ beforeLoad = function()
        _G.Enum = _G.Enum or {}
        _G.Enum.TooltipDataType = { Unit = 2 }
        _G.TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) if kind == 2 then tooltipHandler = fn end end }
    end })
    local BL = CH.Blacklist
    local popups = {}
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function(which, text) popups[#popups + 1] = { which = which, text = text } end
    check(BL.NormalizeTarget("grief  lord") == "Grief Lord" and BL.NormalizeTarget("Grief-Lord") == "Grief Lord",
        "names normalized (spaces, hyphen, capitals)")
    check(BL.NormalizeTarget("x1x") == nil and BL.NormalizeTarget("a b c d") == nil and BL.NormalizeTarget("<script>") == nil,
        "junk names rejected")
    drain()
    check(not BL:Add("Grief Lord", "  "), "a reason is required")
    check(not BL:Add("Ghazneth Strongbow", "me"), "can't list yourself")
    local ok, target = BL:Add("grief lord", "Ninja-looted the Onyxia bag and left")
    Stub.advance(30)
    local recs = sentMessages(CH, "REC")
    check(ok and target == "Grief Lord" and #recs == 1 and recs[1].b.y == "blacklist"
        and recs[1].b.r.id == "Ghazneth Strongbow|Grief Lord", "entry added and shared")
    check(BL:IsListed("Grief Lord") and BL:Count() == 1, "listed")

    -- A guildmate's entry for the same player, and a forged one.
    peerSend(CH, "REC", { y = "blacklist", r = { id = "Thrall Stormrage|Grief Lord", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, target = "Grief Lord", reason = "Scammed me in trade" } })
    peerSend(CH, "REC", { y = "blacklist", r = { id = "Jaina Proudmoore|Grief Lord", owner = "Thrall Stormrage", rev = 1,
        updatedAt = Stub.serverTime, target = "Grief Lord", reason = "forged" } })
    check(#BL:Entries("Grief Lord") == 2, "a second reason from a guildmate; forged ids refused")
    local summary, n = BL:Summary("Grief Lord")
    check(n == 2 and contains(summary, "+1 more"), "summary mentions the other reports")

    -- Warnings.
    fakeUnits({ party1 = "Grief Lord", party2 = "Thrall Stormrage" })
    Stub.fire("GROUP_ROSTER_UPDATE")
    Stub.advance(2)
    check(#popups == 1 and popups[1].which == "CASUALHUB_BLACKLIST" and contains(popups[1].text, "Grief Lord")
        and contains(popups[1].text, "in your group"), "popup when a listed player is in your group")
    Stub.fire("GROUP_ROSTER_UPDATE")
    Stub.advance(2)
    check(#popups == 1, "only once per group")
    fakeUnits({})
    Stub.fire("GROUP_ROSTER_UPDATE")
    Stub.advance(2)
    fakeUnits({ party1 = "Grief Lord" })
    Stub.fire("GROUP_ROSTER_UPDATE")
    Stub.advance(2)
    check(#popups == 2, "warned again in a new group")
    Stub.fire("PARTY_INVITE_REQUEST", "Grief-Lord")
    check(#popups == 3 and contains(popups[3].text, "inviting you"), "popup on a group invite")
    Stub.printed = {}
    Stub.fire("CHAT_MSG_WHISPER", "hey wanna buy gold", "Grief-Lord")
    Stub.fire("CHAT_MSG_WHISPER", "hello?", "Grief-Lord")
    local whispers = 0
    for _, m in ipairs(Stub.printed) do if contains(m, "is whispering you") then whispers = whispers + 1 end end
    check(whispers == 1, "one chat warning per whisperer (not every message)")
    fakeUnits({ NPC = "Grief Lord" })
    Stub.fire("TRADE_SHOW")
    check(printedContains("opened a trade with you"), "chat warning on a trade")

    local lines = {}
    local tip = { GetUnit = function() return "Grief", "mouseover" end, AddLine = function(_, text) lines[#lines + 1] = text end }
    fakeUnits({ mouseover = "Grief Lord" })
    check(tooltipHandler ~= nil, "tooltip hook installed")
    tooltipHandler(tip)
    check(#lines == 1 and contains(lines[1], "blacklist (2)"), "tooltip marker")
    -- In combat/instances the tooltip can hand out a secret unit token that UnitExists rejects.
    local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
    local realIsSecret, realExists, errsBefore = _G.issecretvalue, _G.UnitExists, #CH.Log.persisted
    _G.issecretvalue = function(v) return v == SECRET end
    _G.UnitExists = function(u)
        if u == SECRET then error("Secret values are only allowed during untainted execution for this argument.") end
        return realExists(u)
    end
    local secretTip = { GetUnit = function() return "Grief", SECRET end, AddLine = function(_, text) lines[#lines + 1] = text end }
    tooltipHandler(secretTip)
    check(#lines == 1 and #CH.Log.persisted == errsBefore, "secret unit tokens on tooltips are skipped without an error")
    _G.issecretvalue, _G.UnitExists = realIsSecret, realExists
    CH.Settings:Set("blacklist.warn.tooltip", false)
    tooltipHandler(tip)
    check(#lines == 1, "tooltip marker can be turned off")

    -- Officer clearance: hides current entries for everyone; later entries show again.
    check(BL:CanClear() and BL:Clear("Grief Lord"), "officer (GM) clears the player")
    check(not BL:IsListed("Grief Lord") and #BL:List(true) == 1 and BL:List(true)[1].cleared, "cleared entries hidden")
    peerSend(CH, "REC", { y = "blclear", r = { id = "Ghazneth Ironhide|Some One", owner = "Ghazneth Ironhide", rev = 1,
        updatedAt = Stub.serverTime, target = "Some One" } }, nil, "Ghazneth Ironhide")
    check(CH.Sync:Get("blclear", "Ghazneth Ironhide|Some One") == nil, "members can't clear entries")
    Stub.advance(60)
    peerSend(CH, "REC", { y = "blacklist", r = { id = "Thrall Stormrage|Grief Lord", owner = "Thrall Stormrage", rev = 2,
        updatedAt = Stub.serverTime, target = "Grief Lord", reason = "Did it again" } })
    check(BL:IsListed("Grief Lord") and #BL:Entries("Grief Lord") == 1, "a new entry after the clearance shows")
    check(BL:Unclear("Grief Lord") and #BL:Entries("Grief Lord") == 2, "undoing the clearance restores the older entry")
    check(BL:Remove("Grief Lord") and #BL:Entries("Grief Lord") == 1, "removing your own entry")
    _G.StaticPopupDialogs, _G.StaticPopup_Show = nil, nil
    noErrors(CH)
    reportGlobals()
end

scenarios.blacklist_ui = function()
    local CH = boot()
    local BL, Page = CH.Blacklist, CH.BlacklistPage
    SlashCmdList.CASUALHUB("blacklist")
    local page = CH.UI.pageFrames.blacklist
    check(page and page:IsShown() and page.empty:IsShown() and page.warn.group:GetChecked(), "/chub blacklist opens")
    fakeUnits({ target = "Grief Lord" })
    page.add:RunScript("OnClick")
    local ed = page.editor
    check(ed:IsShown() and ed.name:GetText() == "Grief Lord", "Add player prefills your target")
    ed.reason:SetText("Ninja looter")
    Page:SaveEditor()
    check(not ed:IsShown() and BL:IsListed("Grief Lord") and #page.list.items == 1 and Page.selected == "Grief Lord",
        "saved from the editor")
    check(contains(page.detailBody:GetText(), "Ninja looter") and page.actionButtons[1]:GetText() == "Edit my reason"
        and page.actionButtons[3]:GetText() == "Clear for everyone", "detail with your entry and officer actions")
    page.search:SetText("nobody")
    page.search:GetScript("OnTextChanged")(page.search, true)
    check(#page.list.items == 0, "search filters")
    page.warn.chat:SetChecked(false)
    page.warn.chat:RunScript("OnClick")
    check(CH.Settings:Get("blacklist.warn.chat") == false, "warning toggles saved")
    fakeUnits({})
    noErrors(CH)
    reportGlobals()
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
