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
    local expected = { SettingsPanel = true, C_ClassColor = true, CasualHubDB = true, CasualHubCharDB = true, CasualHubMinimapButton = true }
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
    check(contains(dash.guildCard.body:GetText(), "Online: |cffffffff3|r of 4"), "dashboard shows online count")
    check(dash.motdCard.body:GetText() == "Raid Friday!", "dashboard shows MOTD")
    check((Stub.rosterRequests or 0) >= 1, "dashboard requested a roster refresh")

    for _, entry in ipairs(CH.NAVIGATION) do
        CH.UI:SelectPage(entry.id)
        check(CH.UI.currentPage == entry.id and CH.UI.pageFrames[entry.id]:IsShown(), "page " .. entry.id .. " opens")
    end
    check(not CH.UI.pageFrames.dashboard:IsShown(), "previous page hidden")
    check(CH.UI.navButtons.events.badge:IsShown() and not CH.UI.navButtons.settings.badge:IsShown(),
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
