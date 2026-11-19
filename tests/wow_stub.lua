-- Minimal WoW Forever API stand-in for offline smoke tests (Lua 5.1).
-- Frames are permissive mocks: unknown CamelCase methods are no-ops, lowercase fields behave like a table.
-- Facts mirrored from docs/forever-compat.md: project 18, interface 16001, "First Last" names, etc.
local Stub = { missingGlobals = {}, frames = {}, eventFrames = {}, printed = {}, timers = {} }

local KNOWN_EVENTS = {}
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON",
    "CHAT_MSG_ADDON_LOGGED", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE", "GUILD_MOTD",
    "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_CLOSE", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE", "UI_SCALE_CHANGED", "SKILL_LINES_CHANGED" }) do
    KNOWN_EVENTS[e] = true
end

local KNOWN_TEMPLATES = {}
for _, t in ipairs({ "BackdropTemplate", "UIPanelButtonTemplate", "UIPanelCloseButton", "InputBoxTemplate",
    "UICheckButtonTemplate", "UIPanelScrollFrameTemplate", "BasicFrameTemplateWithInset", "PortraitFrameTemplate",
    "ButtonFrameTemplate", "InsetFrameTemplate", "WowScrollBoxList", "MinimalScrollBar", "ScrollingEditBoxTemplate",
    "WowStyle1DropdownTemplate", "OptionsSliderTemplate", "MinimalSliderWithSteppersTemplate",
    "TooltipBackdropTemplate" }) do
    KNOWN_TEMPLATES[t] = true
end

local KNOWN_TYPES = { Frame = true, Button = true, CheckButton = true, EditBox = true, ScrollFrame = true,
    Slider = true, EventFrame = true, DropdownButton = true, StatusBar = true }

local noop = function() end
local methods = {}
local ObjectMT = {
    __index = function(_, key)
        local m = methods[key]
        if m then return m end
        if type(key) == "string" and key:match("^%u") then return noop end
        return nil
    end,
}

local function newObject(kind, name, parent)
    local o = setmetatable({
        __kind = kind, __name = name, __parent = parent, __scripts = {}, __shown = true,
        __w = 100, __h = 100, __text = "", __points = {}, __value = 0, __checked = false, __scale = 1,
    }, ObjectMT)
    Stub.frames[#Stub.frames + 1] = o
    return o
end
Stub.newObject = newObject

function methods:GetName() return self.__name end
function methods:GetParent() return self.__parent end
function methods:SetScript(kind, fn) self.__scripts[kind] = fn end
function methods:GetScript(kind) return self.__scripts[kind] end
function methods:HookScript(kind, fn)
    local prev = self.__scripts[kind]
    self.__scripts[kind] = prev and function(...) prev(...); fn(...) end or fn
end
function methods:RunScript(kind, ...)
    local fn = self.__scripts[kind]
    if fn then return fn(self, ...) end
end
function methods:IsShown() return self.__shown end
function methods:IsVisible()
    if not self.__shown then return false end
    if self.__parent and self.__parent.IsVisible then return self.__parent:IsVisible() end
    return true
end
function methods:Show()
    if self.__shown then return end
    self.__shown = true
    self:RunScript("OnShow")
end
function methods:Hide()
    if not self.__shown then return end
    self.__shown = false
    self:RunScript("OnHide")
end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:SetText(t) self.__text = t == nil and "" or tostring(t) end
function methods:GetText() return self.__text end
function methods:GetStringWidth() return #self.__text * 6 end
function methods:SetSize(w, h) self.__w, self.__h = w, h; self:RunScript("OnSizeChanged", w, h) end
function methods:SetWidth(w) self.__w = w end
function methods:SetHeight(h) self.__h = h end
function methods:GetWidth() return self.__w end
function methods:GetHeight() return self.__h end
function methods:GetSize() return self.__w, self.__h end
function methods:SetPoint(...) self.__points[#self.__points + 1] = { ... } end
function methods:ClearAllPoints() self.__points = {} end
function methods:GetPoint(i)
    local p = self.__points[i or 1]
    if not p then return nil end
    if type(p[2]) == "string" or p[2] == nil and #p == 1 then return p[1], nil, p[1], 0, 0 end
    if type(p[2]) == "number" then return p[1], nil, p[1], p[2], p[3] end
    return p[1], p[2], p[3] or p[1], p[4] or 0, p[5] or 0
end
function methods:GetCenter() return 50, 50 end
function methods:GetEffectiveScale() return 1 end
function methods:SetScale(s) self.__scale = s end
function methods:GetScale() return self.__scale end
function methods:SetChecked(v) self.__checked = v and true or false end
function methods:GetChecked() return self.__checked end
function methods:SetMinMaxValues(a, b) self.__min, self.__max = a, b end
function methods:SetValue(v)
    self.__value = v
    self:RunScript("OnValueChanged", v, false)
end
function methods:GetValue() return self.__value end
function methods:IsDraggingThumb() return false end
function methods:CreateFontString(name) return newObject("FontString", name, self) end
function methods:CreateTexture(name) return newObject("Texture", name, self) end
function methods:RegisterEvent(event)
    if not KNOWN_EVENTS[event] then
        error("Frame:RegisterEvent(): Attempt to register unknown event \"" .. tostring(event) .. "\"", 2)
    end
    Stub.eventFrames[event] = Stub.eventFrames[event] or {}
    Stub.eventFrames[event][self] = true
end
function methods:UnregisterEvent(event)
    if Stub.eventFrames[event] then Stub.eventFrames[event][self] = nil end
end
function methods:UnregisterAllEvents()
    for _, set in pairs(Stub.eventFrames) do set[self] = nil end
end

function Stub.fire(event, ...)
    local set = Stub.eventFrames[event]
    if not set then return end
    local list = {}
    for f in pairs(set) do list[#list + 1] = f end
    for _, f in ipairs(list) do f:RunScript("OnEvent", event, ...) end
end

function Stub.runTimers()
    local pending = Stub.timers
    Stub.timers = {}
    for _, fn in ipairs(pending) do fn() end
end

-- Install globals. `env` overrides per scenario (e.g. not in a guild).
function Stub.install(env)
    env = env or {}
    local G = _G

    G.CreateFrame = function(kind, name, parent, template)
        if not KNOWN_TYPES[kind] then error("CreateFrame: unknown frame type " .. tostring(kind), 2) end
        if template then
            for t in tostring(template):gmatch("[^,%s]+") do
                if not KNOWN_TEMPLATES[t] then error("CreateFrame: unknown template " .. t, 2) end
            end
        end
        local o = newObject(kind, name, parent)
        if name then G[name] = o end
        return o
    end
    G.UIParent = newObject("Frame", "UIParent")
    G.Minimap = newObject("Frame", "Minimap")
    G.GameTooltip = newObject("GameTooltip", "GameTooltip")
    G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) Stub.printed[#Stub.printed + 1] = msg end }
    G.UISpecialFrames = {}
    G.SlashCmdList = {}
    G.ChatFontNormal = {}
    G.UNKNOWNOBJECT = "Unknown"
    G.BackdropTemplateMixin = {}
    G.tinsert = table.insert
    G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    G.debugstack = function() return "(stack)" end
    G.issecretvalue = function() return false end
    G.ReloadUI = function() Stub.reloaded = true end
    G.HideUIPanel = noop
    G.GetCursorPosition = function() return 80, 90 end
    G.InCombatLockdown = function() return false end

    G.WOW_PROJECT_ID = env.projectId or 18
    G.WOW_PROJECT_CAMELOT = 18
    G.WOW_PROJECT_MAINLINE = 1
    G.WOW_PROJECT_CLASSIC = 2
    G.GetBuildInfo = function() return "1.60.1", "70959", "Nov 13 2026", 16001 end
    G.GetLocale = function() return "enUS" end
    G.GetTime = function() return 1000 end
    G.time = os.time
    G.date = os.date
    G.C_AddOns = { GetAddOnMetadata = function(_, field) return field == "Version" and "0.1.0-alpha" or nil end }
    G.C_Timer = {
        After = function(_, fn) Stub.timers[#Stub.timers + 1] = fn end,
        NewTicker = function() return { Cancel = noop } end,
    }
    G.C_EncodingUtil = { SerializeCBOR = noop, DeserializeCBOR = noop }
    G.C_ChatInfo = { SendAddonMessage = function() return 0 end, RegisterAddonMessagePrefix = function() return 0 end }
    G.Settings = {
        RegisterCanvasLayoutCategory = function(_, name) return { name = name, GetID = function() return 1 end } end,
        RegisterAddOnCategory = function(cat) Stub.settingsCategory = cat end,
    }

    -- Player and guild ("First Last" naming, surname in UnitName's second return)
    G.UnitName = function(unit) if unit == "player" then return "Ghazneth", "Strongbow" end end
    G.GetUnitName = function(unit) if unit == "player" then return "Ghazneth Strongbow" end end
    G.UnitGUID = function() return "Player-6933-000B227D" end
    G.GetRealmName = function() return "Strongbow" end
    G.GetNormalizedRealmName = function() return "CAMWOWUS2Realm7PvE" end
    local inGuild = env.inGuild ~= false
    G.IsInGuild = function() return inGuild end
    G.GetGuildInfo = function(unit)
        if not inGuild or unit ~= "player" then return nil end
        return "Da Filthy Casuals", "Guild Master", 0, "CAMWOWUS2Realm7PvE"
    end
    G.GetNumGuildMembers = function() if inGuild then return 55, 5, 5 end return 0, 0, 0 end
    G.GetGuildRosterInfo = function() end
    G.GetGuildRosterMOTD = function() return inGuild and "Raid Friday!" or "" end
    G.C_GuildInfo = {
        GuildRoster = function() Stub.rosterRequests = (Stub.rosterRequests or 0) + 1 end,
        IsGuildOfficer = function() return inGuild end,
    }

    setmetatable(G, {
        __index = function(_, key)
            Stub.missingGlobals[key] = (Stub.missingGlobals[key] or 0) + 1
            return nil
        end,
    })
end

-- Loads every file listed in a .toc, as the client would, with a shared private namespace.
function Stub.loadToc(addonDir, addonName)
    local ns = {}
    local toc = assert(io.open(addonDir .. "/" .. addonName .. ".toc"))
    for raw in toc:lines() do
        local line = raw:gsub("\r", ""):match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local path = addonDir .. "/" .. line:gsub("\\", "/")
            local chunk = assert(loadfile(path))
            chunk(addonName, ns)
        end
    end
    toc:close()
    return ns
end

-- Serializer for handing SavedVariables between simulated sessions.
function Stub.serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "string" then return string.format("%q", value) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(value) end
    if t ~= "table" then return "nil" end
    local parts = { "{" }
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local key = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
        parts[#parts + 1] = indent .. "  " .. key .. " = " .. Stub.serialize(value[k], indent .. "  ") .. ","
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end

return Stub
