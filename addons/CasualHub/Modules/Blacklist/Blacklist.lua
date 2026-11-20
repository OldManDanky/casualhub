-- Guild blacklist: players guildmates have flagged, each with a reason, shared between Casual Hub users.
-- Warnings appear when a listed player is in your group, invites you, whispers or trades with you, and in
-- their tooltip.
--
-- Records, both single-writer:
--   blacklist  owned by whoever added it: id = "<adder>|<target>", one per adder and target, with a reason
--   blclear    owned by an officer: id = "<officer>|<target>"; hides every entry for that target added
--              before the clearance. A later entry shows again, so a clearance isn't a permanent pardon.
--
-- Addon messages can be forged and reasons travel to every member running the addon (design doc §9), so
-- reasons are short, shown with who added them and when, and officers can clear entries for everyone.
local _, CH = ...
local L = CH.L

local Blacklist = { warned = {}, groupWarned = {} }
CH.Blacklist = Blacklist
local MODULE = "Blacklist"
local B_TYPE, C_TYPE = "blacklist", "blclear"

Blacklist.REASON_MAX = 120
Blacklist.NAME_MAX = 40
local CHAT_WARN_INTERVAL = 600  -- seconds between whisper/trade warnings for the same player

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

-- "First Last" for a typed or received name; nil when it doesn't look like a character name.
function Blacklist.NormalizeTarget(name)
    local key = CH.Identity:Normalize(name)
    if not key then return nil end
    key = key:gsub("%s+", " ")
    -- Letters (including accented UTF-8), spaces and apostrophes only.
    if #key > Blacklist.NAME_MAX or key:find("%d") or key:find("[^%w%s'\128-\255]") then return nil end
    local words = 0
    for _ in key:gmatch("%S+") do words = words + 1 end
    if words < 1 or words > 3 then return nil end
    -- Same capitalisation as the game uses, so typed names match: "ghazneth strongbow" -> "Ghazneth Strongbow".
    key = key:gsub("(%S)(%S*)", function(first, rest) return first:upper() .. rest:lower() end)
    return key
end

-- Full name of a unit ("party1", "target", ...), or nil for non-players and hidden values.
function Blacklist.UnitKey(unit)
    if not unit or not (UnitExists and UnitExists(unit)) then return nil end
    if UnitIsPlayer and not UnitIsPlayer(unit) then return nil end
    local name
    if GetUnitName then
        local ok, n = pcall(GetUnitName, unit, true)
        if ok then name = n end
    end
    if (type(name) ~= "string" or CH.Compat.IsSecret(name)) and UnitName then
        local ok, first, second = pcall(UnitName, unit)
        if ok and type(first) == "string" and not CH.Compat.IsSecret(first) then
            name = (type(second) == "string" and second ~= "" and not CH.Compat.IsSecret(second))
                and (first .. " " .. second) or first
        end
    end
    return Blacklist.NormalizeTarget(name)
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

function Blacklist.ValidateEntry(r)
    local target = Blacklist.NormalizeTarget(r.target)
    if not target or target ~= r.target or r.id ~= r.owner .. "|" .. target then return nil, "bad target" end
    if target == r.owner then return nil, "can't list yourself" end
    local reason = CH.CleanText(r.reason, Blacklist.REASON_MAX)
    if not reason or reason == "" then return nil, "missing reason" end
    return { target = target, reason = reason }
end

function Blacklist.ValidateClear(r)
    local target = Blacklist.NormalizeTarget(r.target)
    if not target or target ~= r.target or r.id ~= r.owner .. "|" .. target then return nil, "bad target" end
    if CH.Roster.loaded and not CH.Permissions:CanMember(r.owner, "clearBlacklist") then
        return nil, "only officers can clear entries"
    end
    return { target = target }
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- Latest officer clearance for a target: updatedAt, officer.
function Blacklist:Clearance(target)
    local at, by
    for _, c in ipairs(CH.Sync:Children(C_TYPE, "target", target)) do
        if not at or c.updatedAt > at then at, by = c.updatedAt, c.owner end
    end
    return at, by
end

-- Entries for a target that are in force (not cleared), newest first.
function Blacklist:Entries(target)
    local clearedAt = self:Clearance(target)
    local out = {}
    for _, e in ipairs(CH.Sync:Children(B_TYPE, "target", target)) do
        if not clearedAt or e.updatedAt > clearedAt then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.updatedAt > b.updatedAt end)
    return out
end

function Blacklist:IsListed(target)
    return target ~= nil and #self:Entries(target) > 0
end

-- Every listed player: { target, entries, latest }, most recently flagged first.
function Blacklist:List(includeCleared)
    local seen, out = {}, {}
    for _, e in CH.Sync:Iterate(B_TYPE) do
        if not e.deleted and not seen[e.target] then
            seen[e.target] = true
            local entries = self:Entries(e.target)
            if #entries > 0 then
                out[#out + 1] = { target = e.target, entries = entries, latest = entries[1].updatedAt }
            elseif includeCleared then
                out[#out + 1] = { target = e.target, entries = {}, latest = e.updatedAt, cleared = true }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.latest ~= b.latest then return a.latest > b.latest end
        return a.target < b.target
    end)
    return out
end

function Blacklist:MyEntry(target)
    local me = CH.Identity:PlayerKey()
    local e = me and CH.Sync:Get(B_TYPE, me .. "|" .. target)
    if e and not e.deleted then return e end
end

function Blacklist:Count()
    return #self:List()
end

-- One-line summary for warnings: "Reason (Adder, 3d ago) +1 more".
function Blacklist:Summary(target)
    local entries = self:Entries(target)
    local e = entries[1]
    if not e then return nil end
    local text = ("%s (%s, %s)"):format(e.reason, e.owner, CH.FormatAgo(e.updatedAt, CH.ServerTime()))
    if #entries > 1 then text = text .. "  " .. (L["+%d more"]):format(#entries - 1) end
    return text, #entries
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

-- Adds or updates your own entry for a player.
function Blacklist:Add(name, reason)
    local me = CH.Identity:PlayerKey()
    if not me or not CH.Identity:GuildKey() then return false, L["You need to be in a guild."] end
    local target = Blacklist.NormalizeTarget(name)
    if not target then return false, L["Enter the player's full name, for example \"First Last\"."] end
    if target == me then return false, L["You can't add yourself."] end
    local clean = CH.CleanText(reason or "", self.REASON_MAX)
    if clean == "" then return false, L["Give a short reason."] end
    local existing = CH.Sync:Get(B_TYPE, me .. "|" .. target)
    local ok = CH.Sync:PublishLocal(B_TYPE, { id = me .. "|" .. target, owner = me,
        rev = existing and existing.rev or 0, target = target, reason = clean })
    if not ok then return false, L["Could not save."] end
    return true, target
end

function Blacklist:Remove(target)
    local e = self:MyEntry(target)
    if not e then return false end
    return CH.Sync:PublishLocal(B_TYPE, { id = e.id, owner = e.owner, rev = e.rev, deleted = true })
end

function Blacklist:CanClear()
    return CH.Permissions:Can("clearBlacklist")
end

-- Officers: hide every current entry for a player, for everyone.
function Blacklist:Clear(target)
    if not self:CanClear() then return false, L["Only officers can clear entries."] end
    local me = CH.Identity:PlayerKey()
    local existing = CH.Sync:Get(C_TYPE, me .. "|" .. target)
    return CH.Sync:PublishLocal(C_TYPE, { id = me .. "|" .. target, owner = me,
        rev = existing and existing.rev or 0, target = target })
end

-- Officers: withdraw your own clearance.
function Blacklist:Unclear(target)
    local me = CH.Identity:PlayerKey()
    local c = me and CH.Sync:Get(C_TYPE, me .. "|" .. target)
    if not c or c.deleted then return false end
    return CH.Sync:PublishLocal(C_TYPE, { id = c.id, owner = me, rev = c.rev, deleted = true })
end

---------------------------------------------------------------------------
-- Warnings
---------------------------------------------------------------------------

local function enabled(kind)
    return CH.Settings:Get("blacklist.warn." .. kind) ~= false
end

local function alertSound()
    if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then pcall(PlaySound, SOUNDKIT.RAID_WARNING) end
end

local function popup(text)
    if StaticPopupDialogs and StaticPopup_Show then
        if not StaticPopupDialogs.CASUALHUB_BLACKLIST then
            StaticPopupDialogs.CASUALHUB_BLACKLIST = {
                text = "%s", button1 = OKAY or "OK", timeout = 0, whileDead = true, hideOnEscape = true,
                showAlert = true, preferredIndex = 3,
            }
        end
        StaticPopup_Show("CASUALHUB_BLACKLIST", text)
    end
    CH:Print(text)
    alertSound()
end

-- Units in the current group, excluding the player.
local function groupUnits()
    local units = {}
    if IsInRaid and IsInRaid() then
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        for i = 1, n do units[#units + 1] = "raid" .. i end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    return units
end

-- Called on GROUP_ROSTER_UPDATE: one popup per listed player per group (reset when you leave the group).
function Blacklist:CheckGroup()
    if not (IsInGroup and IsInGroup()) then
        self.groupWarned = {}
        return
    end
    if not enabled("group") then return end
    local me = CH.Identity:PlayerKey()
    local found = {}
    for _, unit in ipairs(groupUnits()) do
        local key = Blacklist.UnitKey(unit)
        if key and key ~= me and not self.groupWarned[key] and self:IsListed(key) then
            self.groupWarned[key] = true
            found[#found + 1] = key
        end
    end
    if #found == 0 then return end
    local lines = {}
    for _, key in ipairs(found) do lines[#lines + 1] = ("%s: %s"):format(key, (self:Summary(key))) end
    popup((L["Casual Hub blacklist: in your group\n\n%s"]):format(table.concat(lines, "\n")))
end

-- PARTY_INVITE_REQUEST(name, ...)
function Blacklist:CheckInvite(name)
    if not enabled("invite") then return end
    local key = Blacklist.NormalizeTarget(name)
    if key and self:IsListed(key) then
        popup((L["Casual Hub blacklist: %s is inviting you.\n\n%s"]):format(key, (self:Summary(key))))
    end
end

local function chatWarn(self, key, what)
    local now = CH.ServerTime()
    local last = self.warned[key .. what]
    if last and now - last < CHAT_WARN_INTERVAL then return end
    self.warned[key .. what] = now
    CH:Print((L["|cffff4040Blacklist:|r %s %s. %s"]):format(key, what, (self:Summary(key))))
    alertSound()
end

-- CHAT_MSG_WHISPER(text, sender, ...)
function Blacklist:CheckWhisper(_, sender)
    if not enabled("chat") then return end
    local key = Blacklist.NormalizeTarget(sender)
    if key and self:IsListed(key) then chatWarn(self, key, L["is whispering you"]) end
end

-- TRADE_SHOW: the trade partner is the "NPC" unit.
function Blacklist:CheckTrade()
    if not enabled("chat") then return end
    local key = Blacklist.UnitKey("NPC")
    if key and self:IsListed(key) then chatWarn(self, key, L["opened a trade with you"]) end
end

-- Adds a red line to player tooltips.
function Blacklist:OnTooltipUnit(tooltip)
    if not enabled("tooltip") or not tooltip or not tooltip.GetUnit then return end
    local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
    if not ok or not unit then return end
    local key = Blacklist.UnitKey(unit)
    if not key or not self:IsListed(key) then return end
    local summary, count = self:Summary(key)
    tooltip:AddLine((L["Casual Hub blacklist (%d): %s"]):format(count, summary), 1, 0.25, 0.25, true)
    if tooltip.Show then tooltip:Show() end
end

local function hookTooltips()
    local handler = function(tooltip) CH.SafeCall("blacklist tooltip", Blacklist.OnTooltipUnit, Blacklist, tooltip) end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, handler)
        return "TooltipDataProcessor"
    elseif GameTooltip and GameTooltip.HookScript then
        local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", handler)
        return ok and "OnTooltipSetUnit" or nil
    end
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.7.0",
    description = L["Blacklist: shared list of players to avoid, with warnings"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        CH.Sync:RegisterType(B_TYPE, { namespace = "blacklist", validate = Blacklist.ValidateEntry, maxRecords = 1500 })
        CH.Sync:RegisterType(C_TYPE, { namespace = "blacklistClears", validate = Blacklist.ValidateClear, maxRecords = 500 })
        CH.Events:RegisterGameEvent("GROUP_ROSTER_UPDATE", MODULE, function()
            CH.Debounce("Blacklist-group", 1, function() Blacklist:CheckGroup() end)
        end)
        CH.Events:RegisterGameEvent("PARTY_INVITE_REQUEST", MODULE, function(name)
            CH.SafeCall("blacklist invite", Blacklist.CheckInvite, Blacklist, name)
        end)
        CH.Events:RegisterGameEvent("CHAT_MSG_WHISPER", MODULE, function(...)
            CH.SafeCall("blacklist whisper", Blacklist.CheckWhisper, Blacklist, ...)
        end)
        CH.Events:RegisterGameEvent("TRADE_SHOW", MODULE, function()
            CH.SafeCall("blacklist trade", Blacklist.CheckTrade, Blacklist)
        end)
        Blacklist.tooltipHook = hookTooltips()
        -- Joining the game already in a group.
        if C_Timer and C_Timer.After then C_Timer.After(15, function() Blacklist:CheckGroup() end) end
    end,
    shutdown = function()
        for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "PARTY_INVITE_REQUEST", "CHAT_MSG_WHISPER", "TRADE_SHOW" }) do
            CH.Events:UnregisterGameEvent(event, MODULE)
        end
    end,
})
