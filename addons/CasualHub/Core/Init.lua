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
