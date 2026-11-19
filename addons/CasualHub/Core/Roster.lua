-- Guild roster service (design doc §4.2). Members are keyed by full "First Last" name.
--
-- The client has the full roster (online and offline) cached from login; GUILD_ROSTER_UPDATE is unreliable
-- right after login (throttled requests), so we scan on demand, on the event, and on a slow ticker.
-- A compact copy is saved per guild so the Members page has data before the first scan.
local _, CH = ...

local Roster = { members = {}, loaded = false, onlineCount = 0, total = 0 }
CH.Roster = Roster

local REQUEST_INTERVAL = 90

function Roster:Init()
    CH.Store:RegisterNamespace("roster", "guild")
    CH.Events:RegisterGameEvent("GUILD_ROSTER_UPDATE", "Roster", function() Roster:Scan() end)
    CH.Events:Subscribe("GUILD_CHANGED", "Roster", function()
        Roster.members, Roster.loaded = {}, false
        Roster:LoadCache()
        Roster:Request()
        Roster:Scan()
    end)
    self:LoadCache()
    self:Request()
    self:Scan()
    if C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(REQUEST_INTERVAL, function() Roster:Request() end)
    end
end

function Roster:Request()
    if IsInGuild and IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    end
end

function Roster:LoadCache()
    local cached = CH.Store:Get("roster", "members")
    if type(cached) ~= "table" then return end
    for name, m in pairs(cached) do
        if type(name) == "string" and type(m) == "table" and not self.members[name] then
            self.members[name] = { name = name, class = m.class, level = m.level, rank = m.rank,
                rankIndex = m.rankIndex, lastSeen = m.lastSeen, online = false, cached = true }
        end
    end
end

local function lastOnlineSeconds(index)
    if not GetGuildRosterLastOnline then return nil end
    local years, months, days, hours = GetGuildRosterLastOnline(index)
    if type(years) ~= "number" then return nil end
    return ((((years * 365) + (months or 0) * 30 + (days or 0)) * 24) + (hours or 0)) * 3600
end

function Roster:Scan()
    if not (IsInGuild and IsInGuild()) then
        if next(self.members) then
            self.members, self.loaded, self.onlineCount, self.total = {}, false, 0, 0
            CH.Events:Publish("ROSTER_UPDATED")
        end
        return
    end
    local total = GetNumGuildMembers and GetNumGuildMembers() or 0
    if type(total) ~= "number" or total == 0 then return end

    local t, seen, online = time(), {}, 0
    for i = 1, total do
        local name, rankName, rankIndex, level, className, zone, _, _, isOnline, _, classFile, _, _, isMobile,
            _, _, guid = GetGuildRosterInfo(i)
        local key = CH.Identity:Normalize(name)
        if key then
            local m = self.members[key] or { name = key }
            m.cached = nil
            m.rank, m.rankIndex, m.level = rankName, rankIndex, level
            m.class, m.className, m.guid = classFile, className, guid
            m.online = isOnline and not isMobile and true or false
            m.zone = m.online and zone or nil
            if m.online then
                m.lastSeen = t
                online = online + 1
            else
                local ago = lastOnlineSeconds(i)
                if ago then m.lastSeen = t - ago end
            end
            self.members[key] = m
            seen[key] = true
        end
    end
    for key in pairs(self.members) do
        if not seen[key] then self.members[key] = nil end  -- left or was removed from the guild
    end
    self.loaded, self.onlineCount, self.total = true, online, total
    self:SaveCache()
    CH.Events:Publish("ROSTER_UPDATED")
end

function Roster:SaveCache()
    local compact = {}
    for name, m in pairs(self.members) do
        compact[name] = { class = m.class, level = m.level, rank = m.rank, rankIndex = m.rankIndex, lastSeen = m.lastSeen }
    end
    CH.Store:Put("roster", "members", compact)
end

function Roster:Get(name)
    local key = CH.Identity:Normalize(name)
    return key and self.members[key]
end

-- True only when a fresh scan lists the character; cached entries never count as members for sync.
function Roster:IsMember(name)
    local m = self:Get(name)
    return m ~= nil and not m.cached
end

function Roster:IsOnline(name)
    local m = self:Get(name)
    return m ~= nil and m.online == true
end

-- Array of member tables (unsorted copy of references).
function Roster:List()
    local list = {}
    for _, m in pairs(self.members) do list[#list + 1] = m end
    return list
end
