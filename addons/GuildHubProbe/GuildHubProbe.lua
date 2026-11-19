-- GuildHub Probe
-- Records what the WoW Forever client supports so GuildHub's design can be locked against facts
-- (design doc §10 Compatibility Test Plan, §15 Immediate Next Steps).
--
-- Results live in SavedVariables (GuildHubProbeDB), which the client writes on /reload or logout.
-- Commands: /ghprobe (show report), /ghprobe run (re-run), /ghprobe reset (clear saved data).

local ADDON_NAME = ...
local PROBE_VERSION = "0.1.0"
local PREFIX = "GHProbe1"
local COMM_WAIT = 6       -- seconds to wait for addon-message echoes
local ROSTER_WAIT = 10    -- seconds to wait for GUILD_ROSTER_UPDATE
local START_DELAY = 3     -- seconds after entering the world before probing

local report            -- the report for the current run (also referenced from SavedVariables)
local commState         -- in-flight comms test state
local pendingAsync = 0
local eventFrame = CreateFrame("Frame")
local handlers = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function chat(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd4af37GuildHub Probe:|r " .. tostring(msg))
end

local function isSecret(v)
    if type(issecretvalue) == "function" then
        local ok, res = pcall(issecretvalue, v)
        return ok and res or false
    end
    return false
end

local function resolve(path)
    local v = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return v
end

local function pack(...)
    return { n = select("#", ...), ... }
end

-- Calls a dotted-path function if it exists. Returns ok, packedResults|errorString.
local function try(path, ...)
    local fn = resolve(path)
    if type(fn) ~= "function" then return false, "missing" end
    local res = pack(pcall(fn, ...))
    if not res[1] then return false, tostring(res[2]) end
    local out = { n = res.n - 1 }
    for i = 2, res.n do out[i - 1] = res[i] end
    return true, out
end

-- Compact, SavedVariables-safe description of any value.
local function describe(v)
    if isSecret(v) then return "<secret>" end
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "boolean" or t == "number" then return v end
    if t == "string" then
        if #v > 80 then return v:sub(1, 80) .. "...(" .. #v .. ")" end
        return v
    end
    return "<" .. t .. ">"
end

local function describeAll(packed)
    local out = {}
    for i = 1, packed.n do
        local v = describe(packed[i])
        out[i] = v == nil and "nil" or v
    end
    return out
end

local function typesOf(packed)
    local out = {}
    for i = 1, packed.n do
        out[i] = isSecret(packed[i]) and "secret" or type(packed[i])
    end
    return out
end

local function section(name, fn)
    local ok, err = xpcall(fn, function(e)
        return tostring(e) .. "\n" .. (debugstack and debugstack(2, 6, 0) or "")
    end)
    if not ok then
        report.errors[#report.errors + 1] = { section = name, error = err }
        chat("|cffff5555error in " .. name .. "|r (see report)")
    end
end

local function after(seconds, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(seconds, fn)
    else
        local f, elapsed = CreateFrame("Frame"), 0
        f:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= seconds then self:SetScript("OnUpdate", nil); fn() end
        end)
    end
end

local function selfName()
    return UnitName("player")
end

local function isSelf(sender)
    if not sender or isSecret(sender) then return false end
    local short = Ambiguate and Ambiguate(sender, "none") or sender:match("^[^-]+")
    return short == selfName()
end

---------------------------------------------------------------------------
-- Probe lists
---------------------------------------------------------------------------

local FUNCTIONS = {
    -- Addon messaging
    "C_ChatInfo.RegisterAddonMessagePrefix", "C_ChatInfo.IsAddonMessagePrefixRegistered",
    "C_ChatInfo.GetRegisteredAddonMessagePrefixes", "C_ChatInfo.SendAddonMessage",
    "C_ChatInfo.SendAddonMessageLogged", "C_ChatInfo.InChatMessagingLockdown",
    "RegisterAddonMessagePrefix", "SendAddonMessage", "ChatThrottleLib",
    -- Guild roster and ranks
    "IsInGuild", "GetGuildInfo", "C_GuildInfo.GuildRoster", "GuildRoster", "GetNumGuildMembers",
    "GetGuildRosterInfo", "GetGuildRosterLastOnline", "GetGuildRosterMOTD", "GetGuildInfoText",
    "GuildControlGetNumRanks", "GuildControlGetRankName", "C_GuildInfo.GuildControlGetRankFlags",
    "C_GuildInfo.GetGuildRankOrder", "C_GuildInfo.CanEditOfficerNote", "C_GuildInfo.CanViewOfficerNote",
    "CanEditOfficerNote", "CanViewOfficerNote", "CanEditPublicNote", "CanEditMOTD", "IsGuildLeader",
    "C_GuildInfo.IsGuildOfficer", "C_GuildInfo.MemberExistsByName", "C_Club.GetGuildClubId",
    "C_Club.GetClubMembers", "SetGuildRosterShowOffline", "GetGuildRosterShowOffline",
    -- Professions
    "GetNumSkillLines", "GetSkillLineInfo", "GetProfessions", "GetProfessionInfo",
    "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillLine", "GetTradeSkillItemLink",
    "GetTradeSkillRecipeLink", "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo",
    "GetNumCrafts", "GetCraftInfo", "GetCraftDisplaySkillLine",
    "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetRecipeInfo",
    "C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.GetChildProfessionInfo",
    "C_TradeSkillUI.GetTradeSkillLine", "C_TradeSkillUI.IsTradeSkillLinked",
    -- Time, timers, calendar
    "C_Timer.After", "C_Timer.NewTicker", "C_Timer.NewTimer", "GetServerTime", "time", "date",
    "C_DateAndTime.GetCurrentCalendarTime", "C_DateAndTime.GetServerTimeLocal",
    "C_Calendar.OpenCalendar", "C_Calendar.GetNumDayEvents",
    -- Serialization helpers
    "C_EncodingUtil.SerializeCBOR", "C_EncodingUtil.DeserializeCBOR", "C_EncodingUtil.CompressString",
    "C_EncodingUtil.DecompressString", "C_EncodingUtil.EncodeBase64", "C_EncodingUtil.SerializeJSON",
    -- UI framework
    "C_AddOns.GetAddOnMetadata", "GetAddOnMetadata", "C_AddOns.IsAddOnLoaded",
    "Settings.RegisterCanvasLayoutCategory", "Settings.RegisterAddOnCategory",
    "InterfaceOptions_AddCategory", "AddonCompartmentFrame", "BackdropTemplateMixin",
    "CreateFromMixins", "Mixin", "CreateDataProvider", "CreateScrollBoxListLinearView",
    "ScrollUtil.InitScrollBoxListWithScrollBar", "MenuUtil.CreateContextMenu",
    "UIDropDownMenu_Initialize", "StaticPopup_Show", "LibStub",
    -- Restrictions / secrets (Retail 12.x-era engine)
    "issecretvalue", "issecrettable", "canaccessvalue", "canaccesssecrets", "canaccesstable",
    "C_RestrictedActions.IsAddOnRestrictionActive", "InCombatLockdown",
    -- Misc
    "IsInInstance", "UnitGUID", "GetNormalizedRealmName", "Ambiguate", "C_PartyInfo.InviteUnit",
    "InviteUnit", "C_Map.GetBestMapForUnit", "C_Seasons.HasActiveSeason", "GetExpansionLevel",
    "GetMaxPlayerLevel", "GetPhysicalScreenSize",
}

local EVENTS = {
    "CHAT_MSG_ADDON", "CHAT_MSG_ADDON_LOGGED", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    "GUILD_RANKS_UPDATE", "GUILD_MOTD", "GUILD_NEWS_UPDATE", "CLUB_MEMBER_UPDATED",
    "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "CRAFT_SHOW", "CRAFT_UPDATE", "SKILL_LINES_CHANGED",
    "CALENDAR_UPDATE_EVENT_LIST", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_START", "ADDON_RESTRICTION_STATE_CHANGED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
    "GROUP_ROSTER_UPDATE", "PLAYER_LOGOUT",
}

local TEMPLATES = {
    { "Frame", "BackdropTemplate" }, { "Button", "UIPanelButtonTemplate" },
    { "Button", "UIPanelCloseButton" }, { "EditBox", "InputBoxTemplate" },
    { "CheckButton", "UICheckButtonTemplate" }, { "ScrollFrame", "UIPanelScrollFrameTemplate" },
    { "Frame", "BasicFrameTemplateWithInset" }, { "Frame", "PortraitFrameTemplate" },
    { "Frame", "ButtonFrameTemplate" }, { "Frame", "InsetFrameTemplate" },
    { "Frame", "WowScrollBoxList" }, { "EventFrame", "MinimalScrollBar" },
    { "Frame", "ScrollingEditBoxTemplate" }, { "DropdownButton", "WowStyle1DropdownTemplate" },
    { "Slider", "OptionsSliderTemplate" }, { "Slider", "MinimalSliderWithSteppersTemplate" },
    { "Frame", "TooltipBackdropTemplate" },
}

---------------------------------------------------------------------------
-- Synchronous sections
---------------------------------------------------------------------------

local function probeMeta()
    local b = pack(GetBuildInfo())
    local m = {
        probeVersion = PROBE_VERSION,
        luaVersion = _VERSION,
        buildVersion = b[1], buildNumber = b[2], buildDate = b[3], interface = b[4],
        buildInfoReturnCount = b.n,
        buildInfoAll = describeAll(b),
        projectId = WOW_PROJECT_ID,
        projectConstants = {},
        locale = GetLocale(),
        realm = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName(),
        playerClass = select(2, UnitClass("player")),
        playerLevel = UnitLevel("player"),
        faction = UnitFactionGroup("player"),
        uiScale = UIParent:GetEffectiveScale(),
        screenWidth = GetScreenWidth(), screenHeight = GetScreenHeight(),
        inCombat = InCombatLockdown(),
        hasJit = type(jit) == "table",
        hasBit = type(bit) == "table",
        hasUtf8 = type(utf8) == "table",
    }
    if GetPhysicalScreenSize then m.physicalScreen = describeAll(pack(GetPhysicalScreenSize())) end
    if GetCurrentRegion then m.region = GetCurrentRegion() end
    if GetExpansionLevel then m.expansionLevel = GetExpansionLevel() end
    if GetMaxPlayerLevel then m.maxPlayerLevel = GetMaxPlayerLevel() end
    if IsInInstance then m.instance = describeAll(pack(IsInInstance())) end
    for k, v in pairs(_G) do
        if type(k) == "string" and k:find("^WOW_PROJECT_") then m.projectConstants[k] = describe(v) end
    end
    report.meta = m
end

local function probeFunctions()
    local present, missing, out = 0, 0, {}
    for _, path in ipairs(FUNCTIONS) do
        local t = type(resolve(path))
        out[path] = t
        if t == "nil" then missing = missing + 1 else present = present + 1 end
    end
    report.functions = out
    report.summary.functionsPresent = present
    report.summary.functionsMissing = missing
end

local function probeEvents()
    local f = CreateFrame("Frame")
    local out = {}
    for _, ev in ipairs(EVENTS) do
        local ok, res = pcall(f.RegisterEvent, f, ev)
        if ok then
            out[ev] = (res == false) and "rejected" or "ok"
        else
            out[ev] = "error: " .. tostring(res)
        end
    end
    f:UnregisterAllEvents()
    report.events = out
end

local function probeTemplates()
    local out = {}
    for _, spec in ipairs(TEMPLATES) do
        local frameType, template = spec[1], spec[2]
        local ok, frame = pcall(CreateFrame, frameType, nil, UIParent, template)
        if ok and frame then
            frame:Hide()
            out[frameType .. ":" .. template] = "ok"
        else
            out[frameType .. ":" .. template] = "error: " .. tostring(frame)
        end
    end
    report.templates = out
end

local function probeProfessions()
    local p = report.professions
    if GetNumSkillLines and GetSkillLineInfo then
        p.skillLines = {}
        for i = 1, GetNumSkillLines() do
            local r = pack(GetSkillLineInfo(i))
            if i == 1 then p.skillLineReturnTypes = typesOf(r) end
            -- name, isHeader, isExpanded, rank, tempPoints, modifier, maxRank
            p.skillLines[i] = { describe(r[1]), r[2] and "header" or "", describe(r[4]), describe(r[7]) }
        end
    end
    if GetProfessions then
        local ok, idx = try("GetProfessions")
        if ok then
            p.getProfessions = describeAll(idx)
            p.professionInfo = {}
            for i = 1, idx.n do
                if type(idx[i]) == "number" then
                    local ok2, info = try("GetProfessionInfo", idx[i])
                    p.professionInfo[i] = ok2 and describeAll(info) or info
                end
            end
        else
            p.getProfessions = idx
        end
    end
end

-- Captured whenever the player opens a profession window (TRADE_SKILL_SHOW / CRAFT_SHOW).
local function captureTradeWindow(kind)
    if not report then return end
    local w = { kind = kind, capturedAt = time() }
    local ok, line = try("GetTradeSkillLine")
    if ok then w.tradeSkillLine = describeAll(line) end
    ok, line = try("C_TradeSkillUI.GetBaseProfessionInfo")
    if ok then w.baseProfessionInfo = describe(line[1]) end
    local num = (kind == "craft" and GetNumCrafts and GetNumCrafts()) or (GetNumTradeSkills and GetNumTradeSkills())
    w.numEntries = num
    local infoFn = kind == "craft" and "GetCraftInfo" or "GetTradeSkillInfo"
    w.sampleEntries = {}
    for i = 1, math.min(num or 0, 6) do
        local ok2, r = try(infoFn, i)
        if ok2 then
            if i == 1 then w.entryReturnTypes = typesOf(r) end
            w.sampleEntries[i] = describeAll(r)
        end
    end
    ok, line = try("C_TradeSkillUI.GetAllRecipeIDs")
    if ok and type(line[1]) == "table" then w.modernRecipeCount = #line[1] end
    local key = (w.tradeSkillLine and w.tradeSkillLine[1]) or kind
    report.professions.windows = report.professions.windows or {}
    report.professions.windows[tostring(key)] = w
    chat("captured profession window: " .. tostring(key))
end

---------------------------------------------------------------------------
-- Async sections (guild roster, addon messaging)
---------------------------------------------------------------------------

local finishRun

local function asyncDone()
    pendingAsync = pendingAsync - 1
    if pendingAsync <= 0 then finishRun() end
end

local function captureRoster(g)
    g.rosterEventAfter = g.requestedAt and (GetTime() - g.requestedAt) or nil
    local total, online, onlineMobile = GetNumGuildMembers()
    g.counts = { total = describe(total), online = describe(online), onlineAndMobile = describe(onlineMobile) }
    local me = selfName()
    for i = 1, total or 0 do
        local r = pack(GetGuildRosterInfo(i))
        if i == 1 then
            g.rosterReturnCount = r.n
            g.rosterReturnTypes = typesOf(r)
            g.sampleNameFormat = (type(r[1]) == "string" and not isSecret(r[1]) and r[1]:find("-")) and "Name-Realm" or "Name"
        end
        local name = r[1]
        if type(name) == "string" and not isSecret(name) and (name == me or isSelf(name)) then
            local row = describeAll(r)
            -- Keep notes out of the report; record only whether they are readable.
            if type(r[7]) == "string" then row[7] = "<public note, " .. #r[7] .. " chars>" end
            if type(r[8]) == "string" then row[8] = "<officer note, " .. #r[8] .. " chars>" end
            g.selfRow = row
            g.selfIndex = i
        end
    end
    if GetGuildRosterLastOnline and (total or 0) > 0 then
        local ok, r = try("GetGuildRosterLastOnline", 1)
        g.lastOnlineReturnTypes = ok and typesOf(r) or r
    end
end

local function probeGuild()
    local g = { inGuild = IsInGuild and IsInGuild() or false }
    report.guild = g
    if not g.inGuild then
        g.note = "character is not in a guild; roster probe skipped"
        return
    end
    local info = pack(GetGuildInfo("player"))
    g.guildInfoReturnTypes = typesOf(info)
    g.guildName, g.rankName, g.rankIndex = describe(info[1]), describe(info[2]), describe(info[3])
    if GuildControlGetNumRanks then
        g.ranks = {}
        for i = 1, GuildControlGetNumRanks() do g.ranks[i] = describe(GuildControlGetRankName(i)) end
    end
    g.permissions = {}
    for _, fn in ipairs({ "CanEditOfficerNote", "CanViewOfficerNote", "C_GuildInfo.CanEditOfficerNote",
        "C_GuildInfo.CanViewOfficerNote", "CanEditPublicNote", "CanEditMOTD", "IsGuildLeader",
        "C_GuildInfo.IsGuildOfficer" }) do
        local ok, r = try(fn)
        g.permissions[fn] = ok and describe(r[1]) or r
    end

    pendingAsync = pendingAsync + 1
    local finished = false
    local function finish(reason)
        if finished then return end
        finished = true
        handlers.GUILD_ROSTER_UPDATE = nil
        g.rosterResult = reason
        section("guild-roster", function() captureRoster(g) end)
        asyncDone()
    end
    handlers.GUILD_ROSTER_UPDATE = function() finish("event") end
    g.requestedAt = GetTime()
    local ok, err = try("C_GuildInfo.GuildRoster")
    if ok then g.rosterRequest = "C_GuildInfo.GuildRoster" else
        ok, err = try("GuildRoster")
        g.rosterRequest = ok and "GuildRoster" or ("failed: " .. tostring(err))
    end
    after(ROSTER_WAIT, function() finish("timeout") end)
end

local function enumName(enumTable, value)
    if type(enumTable) ~= "table" then return nil end
    for k, v in pairs(enumTable) do if v == value then return k end end
end

local function sendAddon(channel, target, text)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return try("C_ChatInfo.SendAddonMessage", PREFIX, text, channel, target)
    end
    return try("SendAddonMessage", PREFIX, text, channel, target)
end

local function buildPayload(nonce, label, length)
    local base = "PING:" .. nonce .. ":" .. label .. ":"
    if length and length > #base then base = base .. string.rep("x", length - #base) end
    return base
end

local function probeComms()
    local c = { prefix = PREFIX, tests = {}, peers = {} }
    report.comms = c

    local ok, r = try("C_ChatInfo.RegisterAddonMessagePrefix", PREFIX)
    if ok then
        c.register = { api = "C_ChatInfo", result = describe(r[1]),
            resultName = enumName(Enum and Enum.RegisterAddonMessagePrefixResult, r[1]) }
    else
        local ok2, r2 = try("RegisterAddonMessagePrefix", PREFIX)
        c.register = { api = "legacy", result = ok2 and describe(r2[1]) or r2 }
    end
    ok, r = try("C_ChatInfo.IsAddonMessagePrefixRegistered", PREFIX)
    c.isRegistered = ok and describe(r[1]) or r
    ok, r = try("C_ChatInfo.InChatMessagingLockdown")
    c.messagingLockdown = ok and describeAll(r) or r
    c.inCombat = InCombatLockdown()
    if IsInInstance then c.instance = describeAll(pack(IsInInstance())) end

    local nonce = tostring(math.random(100000, 999999))
    commState = { nonce = nonce, sentAt = {}, c = c }
    local me = selfName()
    local tests = {
        { label = "whisper-self-small", channel = "WHISPER", target = me },
        { label = "whisper-self-255", channel = "WHISPER", target = me, length = 255 },
        { label = "whisper-self-256", channel = "WHISPER", target = me, length = 256 },
        { label = "whisper-self-4000", channel = "WHISPER", target = me, length = 4000 },
    }
    if IsInGuild and IsInGuild() then
        tests[#tests + 1] = { label = "guild-small", channel = "GUILD" }
    end
    for _, t in ipairs(tests) do
        local text = buildPayload(nonce, t.label, t.length)
        local sendOk, res = sendAddon(t.channel, t.target, text)
        local entry = { channel = t.channel, length = #text, received = false }
        if sendOk then
            entry.sendReturns = describeAll(res)
            entry.sendResultName = enumName(Enum and Enum.SendAddonMessageResult, res[1])
        else
            entry.sendError = res
        end
        commState.sentAt[t.label] = GetTime()
        c.tests[t.label] = entry
    end

    pendingAsync = pendingAsync + 1
    after(COMM_WAIT, function()
        local received = 0
        for _, entry in pairs(c.tests) do if entry.received then received = received + 1 end end
        report.summary.commsReceived = received .. "/" .. #tests
        asyncDone()
    end)
end

-- Handles our prefix. Our own PINGs come back as receipts; other clients' guild PINGs get a PONG whisper,
-- which gives a two-client propagation test when another guildmate runs the probe.
local answered = {}
local function onAddonMessage(event, prefix, text, channel, sender, target)
    if prefix ~= PREFIX then return end
    if not report or not report.comms then return end
    local c = report.comms
    if isSecret(text) or isSecret(sender) then
        c.secretPayloadSeen = (c.secretPayloadSeen or 0) + 1
        return
    end
    c.senderFormatSample = c.senderFormatSample or (sender and (sender:find("-") and "Name-Realm" or "Name"))
    local kind, nonce, label = text:match("^(%u+):(%d+):([%w%-%.]+)")
    if kind == "PING" and commState and nonce == commState.nonce and isSelf(sender) then
        local entry = c.tests[label]
        if entry then
            entry.received = true
            entry.receivedVia = event
            entry.receivedChannel = channel
            entry.receivedLength = #text
            entry.truncated = #text < entry.length
            entry.latency = commState.sentAt[label] and (GetTime() - commState.sentAt[label]) or nil
        end
    elseif kind == "PING" and not isSelf(sender) then
        c.peers[sender] = c.peers[sender] or { firstSeen = time() }
        c.peers[sender].pingVia = channel
        if not answered[sender] then
            answered[sender] = true
            sendAddon("WHISPER", sender, "PONG:" .. nonce .. ":" .. PROBE_VERSION)
        end
    elseif kind == "PONG" and commState and nonce == commState.nonce then
        c.peers[sender] = c.peers[sender] or { firstSeen = time() }
        c.peers[sender].pong = label
        chat("peer " .. sender .. " answered (probe " .. tostring(label) .. ")")
    end
end
handlers.CHAT_MSG_ADDON = onAddonMessage
handlers.CHAT_MSG_ADDON_LOGGED = onAddonMessage

---------------------------------------------------------------------------
-- Run orchestration
---------------------------------------------------------------------------

local running = false

finishRun = function()
    if not running then return end
    running = false
    report.finishedAt = time()
    local s = report.summary
    chat(("done. functions %d present / %d missing; comms %s; errors %d."):format(
        s.functionsPresent or 0, s.functionsMissing or 0, tostring(s.commsReceived or "n/a"), #report.errors))
    chat("type |cffffff00/ghprobe|r to view the report, |cffffff00/reload|r to save it to disk.")
end

local function runProbe()
    if running then chat("already running"); return end
    running = true
    pendingAsync = 0
    local charKey = selfName() .. "-" .. (GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName())
    report = { startedAt = time(), character = charKey, summary = {}, errors = {}, professions = {},
        persistence = GuildHubProbeCharDB and GuildHubProbeCharDB.persistence }
    GuildHubProbeDB.reports[charKey] = report
    GuildHubProbeDB.latest = charKey
    chat("probing client (" .. PROBE_VERSION .. ")...")

    section("meta", probeMeta)
    section("functions", probeFunctions)
    section("events", probeEvents)
    section("templates", probeTemplates)
    section("professions", probeProfessions)
    section("guild", probeGuild)
    section("comms", probeComms)

    if pendingAsync == 0 then finishRun() end
end

---------------------------------------------------------------------------
-- Report window
---------------------------------------------------------------------------

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta == "number" end
        return a < b
    end)
    return keys
end

local function dump(v, indent, out)
    for _, k in ipairs(sortedKeys(v)) do
        local val = v[k]
        if type(val) == "table" then
            out[#out + 1] = indent .. tostring(k) .. ":"
            dump(val, indent .. "  ", out)
        else
            out[#out + 1] = indent .. tostring(k) .. " = " .. tostring(val)
        end
    end
end

local window
local function showWindow()
    if not report then chat("no report yet; type /ghprobe run"); return end
    if not window then
        local ok, frame = pcall(CreateFrame, "Frame", "GuildHubProbeFrame", UIParent,
            BackdropTemplateMixin and "BackdropTemplate" or nil)
        if not ok then chat("could not create window: " .. tostring(frame)); return end
        window = frame
        frame:SetSize(720, 520)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:SetFrameStrata("DIALOG")
        if frame.SetBackdrop then
            frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
            frame:SetBackdropBorderColor(0.83, 0.69, 0.22, 1)
        end
        tinsert(UISpecialFrames, "GuildHubProbeFrame")

        local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 14, -12)
        title:SetText("GuildHub Probe - Ctrl+A, Ctrl+C to copy")

        local okClose, close = pcall(CreateFrame, "Button", nil, frame, "UIPanelCloseButton")
        if okClose then close:SetPoint("TOPRIGHT", -4, -4) end

        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -40)
        scroll:SetPoint("BOTTOMRIGHT", -34, 14)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(660)
        edit:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll:SetScrollChild(edit)
        frame.edit = edit
    end
    local lines = {}
    dump(report, "", lines)
    window.edit:SetText(table.concat(lines, "\n"))
    window:Show()
end

---------------------------------------------------------------------------
-- Lifecycle, persistence test, slash commands
---------------------------------------------------------------------------

local started = false

function handlers.ADDON_LOADED(_, name)
    if name ~= ADDON_NAME then return end
    GuildHubProbeDB = type(GuildHubProbeDB) == "table" and GuildHubProbeDB or {}
    GuildHubProbeDB.reports = GuildHubProbeDB.reports or {}
    GuildHubProbeCharDB = type(GuildHubProbeCharDB) == "table" and GuildHubProbeCharDB or {}
    local p = GuildHubProbeCharDB.persistence or { loads = 0 }
    p.loads = (p.loads or 0) + 1
    -- If the previous session saved a logout marker for the previous load, persistence across that exit worked.
    p.previousExitSaved = p.lastLogoutLoad ~= nil and p.lastLogoutLoad == p.loads - 1
    p.lastLoadAt = time()
    GuildHubProbeCharDB.persistence = p
end

function handlers.PLAYER_ENTERING_WORLD(_, isInitialLogin, isReloadingUi)
    local p = GuildHubProbeCharDB.persistence
    p.lastEnter = { initialLogin = describe(isInitialLogin), reload = describe(isReloadingUi), at = time() }
    if started then return end
    started = true
    after(START_DELAY, runProbe)
end

function handlers.PLAYER_LOGOUT()
    local p = GuildHubProbeCharDB.persistence
    p.lastLogoutLoad = p.loads
    p.lastLogoutAt = time()
end

function handlers.TRADE_SKILL_SHOW() after(0.5, function() captureTradeWindow("tradeskill") end) end
function handlers.CRAFT_SHOW() after(0.5, function() captureTradeWindow("craft") end) end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then h(event, ...) end
end)
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "CHAT_MSG_ADDON",
    "CHAT_MSG_ADDON_LOGGED", "GUILD_ROSTER_UPDATE", "TRADE_SKILL_SHOW", "CRAFT_SHOW" }) do
    pcall(eventFrame.RegisterEvent, eventFrame, ev)
end

SLASH_GUILDHUBPROBE1 = "/ghprobe"
SlashCmdList.GUILDHUBPROBE = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "run" then
        runProbe()
    elseif msg == "reset" then
        GuildHubProbeDB = { reports = {} }
        report = nil
        chat("saved reports cleared")
    else
        showWindow()
    end
end
