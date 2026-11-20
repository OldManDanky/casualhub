-- Namespace, client capability checks, logging and protected calls.
-- See docs/forever-compat.md for the client facts these checks are based on.
local ADDON_NAME, CH = ...

_G.CasualHub = CH  -- for /run debugging; modules use the private namespace, not this global
CH.name = ADDON_NAME
CH.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "dev"

CH.GOLD = { r = 0.83, g = 0.69, b = 0.22, hex = "ffd4af37" }

-- CasualBot artwork (docs/CasualBot_Discord_Icon_1024.png, converted by tools/png2tga.py). Round, transparent corners.
CH.ICON = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\icon64.tga"
CH.ICON_LARGE = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\icon256.tga"

function CH:Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|c" .. CH.GOLD.hex .. "Casual Hub|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------

-- Cleans user or network text for display and storage: strips UI escape sequences ("|"), control characters
-- and surrounding/duplicate whitespace, then truncates to maxBytes without splitting a UTF-8 character.
function CH.CleanText(text, maxBytes)
    if type(text) ~= "string" then return nil end
    text = text:gsub("|", ""):gsub("[%c]", " "):gsub("%s+", " ")
    text = text:gsub("^ ", ""):gsub(" $", "")
    if maxBytes and #text > maxBytes then
        text = text:sub(1, maxBytes)
        -- Drop a trailing partial UTF-8 sequence.
        local i = #text
        while i > 0 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i - 1 end
        if i > 0 and text:byte(i) >= 0xC0 then
            local lead = text:byte(i)
            local need = lead >= 0xF0 and 4 or (lead >= 0xE0 and 3 or 2)
            if #text - i + 1 < need then text = text:sub(1, i - 1) end
        end
    end
    return text
end

-- "just now", "5m ago", "3h ago", "2d ago" for a past timestamp (seconds).
function CH.FormatAgo(timestamp, now)
    if type(timestamp) ~= "number" then return CH.L["unknown"] end
    local delta = math.max(0, (now or time()) - timestamp)
    if delta < 60 then return CH.L["just now"] end
    if delta < 3600 then return (CH.L["%dm ago"]):format(math.floor(delta / 60)) end
    if delta < 86400 then return (CH.L["%dh ago"]):format(math.floor(delta / 3600)) end
    return (CH.L["%dd ago"]):format(math.floor(delta / 86400))
end

-- Hex color ("ffrrggbb") for a class file name such as "HUNTER"; white when unknown.
-- Forever does not define RAID_CLASS_COLORS for every class, so both sources are optional.
function CH.ClassColorHex(classFile)
    local c
    if type(classFile) == "string" then
        if C_ClassColor and C_ClassColor.GetClassColor then
            local ok, color = pcall(C_ClassColor.GetClassColor, classFile)
            if ok then c = color end
        end
        if not c and RAID_CLASS_COLORS then c = RAID_CLASS_COLORS[classFile] end
    end
    if not c or type(c.r) ~= "number" then return "ffffffff" end
    return ("ff%02x%02x%02x"):format(math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
end

function CH.ServerTime()
    return (GetServerTime and GetServerTime()) or time()
end

---------------------------------------------------------------------------
-- Compatibility
---------------------------------------------------------------------------

local Compat = {}
CH.Compat = Compat

do
    local buildVersion, buildNumber, _, interface = GetBuildInfo()
    Compat.buildVersion = buildVersion
    Compat.buildNumber = buildNumber
    Compat.interface = interface
    Compat.projectId = WOW_PROJECT_ID
    -- Forever reports its own project (18, WOW_PROJECT_CAMELOT) and runs a modern-namespace API on a 1.x ruleset.
    Compat.isForever = WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)
end

-- Resolves a dotted global path such as "C_GuildInfo.GuildRoster"; nil when any part is absent.
function Compat.Resolve(path)
    local v = _G
    for part in path:gmatch("[^%.]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return v
end

function Compat.Has(path)
    return Compat.Resolve(path) ~= nil
end

function Compat.IsSecret(value)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        return ok and secret or false
    end
    return false
end

-- Capabilities the core relies on. Missing ones are reported in diagnostics; features degrade rather than fail.
Compat.CORE_CAPABILITIES = {
    { path = "C_Timer.After", feature = "timers" },
    { path = "C_GuildInfo.GuildRoster", feature = "guild roster refresh" },
    { path = "GetGuildRosterInfo", feature = "guild roster" },
    { path = "C_ChatInfo.SendAddonMessage", feature = "addon messaging (Phase 2)" },
    { path = "C_EncodingUtil.SerializeCBOR", feature = "record serialization (Phase 2)" },
    { path = "BackdropTemplateMixin", feature = "panel backdrops" },
    { path = "Settings.RegisterCanvasLayoutCategory", feature = "Blizzard settings entry" },
}

function Compat.MissingCapabilities()
    local missing = {}
    for _, cap in ipairs(Compat.CORE_CAPABILITIES) do
        if not Compat.Has(cap.path) then missing[#missing + 1] = cap end
    end
    return missing
end

---------------------------------------------------------------------------
-- Logging (diagnostics ring buffer; errors are also persisted once the database is ready)
---------------------------------------------------------------------------

local Log = { entries = {}, max = 300, pendingErrors = {}, persisted = nil, maxPersisted = 50 }
CH.Log = Log

local function formatMessage(msg, ...)
    if select("#", ...) == 0 then return tostring(msg) end
    local ok, text = pcall(string.format, tostring(msg), ...)
    return ok and text or (tostring(msg) .. " [format error]")
end

function Log:Add(level, msg, ...)
    local entry = { t = time(), level = level, msg = formatMessage(msg, ...) }
    local entries = self.entries
    entries[#entries + 1] = entry
    if #entries > self.max then table.remove(entries, 1) end
    if level == "error" then self:Persist(entry) end
    if level == "debug" and CH.Settings and CH.Settings:Get("debug") then
        CH:Print("|cff999999[debug]|r %s", entry.msg)
    end
    return entry
end

function Log:Persist(entry)
    local record = { t = entry.t, msg = entry.msg, version = CH.version }
    if not self.persisted then
        self.pendingErrors[#self.pendingErrors + 1] = record
        return
    end
    local list = self.persisted
    list[#list + 1] = record
    while #list > self.maxPersisted do table.remove(list, 1) end
end

-- Called by the database once SavedVariables are loaded.
function Log:AttachStorage(list)
    self.persisted = list
    for _, record in ipairs(self.pendingErrors) do
        list[#list + 1] = record
    end
    self.pendingErrors = {}
    while #list > self.maxPersisted do table.remove(list, 1) end
end

function Log:Debug(msg, ...) return self:Add("debug", msg, ...) end
function Log:Info(msg, ...) return self:Add("info", msg, ...) end
function Log:Warn(msg, ...) return self:Add("warn", msg, ...) end
function Log:Error(msg, ...) return self:Add("error", msg, ...) end

---------------------------------------------------------------------------
-- Protected calls: failures are logged with a stack and never propagate to the caller.
---------------------------------------------------------------------------

local function errorHandler(err)
    local stack = debugstack and debugstack(2, 8, 0) or ""
    return tostring(err) .. "\n" .. stack
end

local unpack = unpack or table.unpack

-- Returns true plus results, or false plus the error. A nil fn counts as success.
function CH.SafeCall(label, fn, ...)
    if fn == nil then return true end
    local args = { n = select("#", ...), ... }
    local results = { xpcall(function() return fn(unpack(args, 1, args.n)) end, errorHandler) }
    if not results[1] then
        Log:Error("%s: %s", tostring(label), tostring(results[2]))
        if not CH.errorNotified then
            CH.errorNotified = true
            CH:Print("an error occurred (%s). Type /chub diag for details.", tostring(label))
        end
    end
    return unpack(results, 1, table.maxn(results))
end

-- "20:30", "8:30", "20", "8pm", "8:30pm" -> hour, minute
function CH.ParseClock(text)
    text = (text or ""):lower():gsub("%s", "")
    local h, m, ampm = text:match("^(%d%d?):(%d%d)([ap]?m?)$")
    if not h then
        h, ampm = text:match("^(%d%d?)([ap]?m?)$")
        m = "0"
    end
    h, m = tonumber(h), tonumber(m)
    if not h or m > 59 then return nil end
    if ampm == "pm" or ampm == "p" then
        if h < 1 or h > 12 then return nil end
        if h < 12 then h = h + 12 end
    elseif ampm == "am" or ampm == "a" then
        if h < 1 or h > 12 then return nil end
        if h == 12 then h = 0 end
    elseif ampm ~= "" then
        return nil
    end
    if h > 23 then return nil end
    return h, m
end

-- Runs fn once, `delay` seconds after the first call for `key`; further calls in the meantime are dropped.
-- Used to redraw a page once per burst of synced records instead of once per record.
local debounced = {}
function CH.Debounce(key, delay, fn)
    if debounced[key] then return end
    if not (C_Timer and C_Timer.After) then
        CH.SafeCall(key, fn)
        return
    end
    debounced[key] = true
    C_Timer.After(delay, function()
        debounced[key] = nil
        CH.SafeCall(key, fn)
    end)
end
