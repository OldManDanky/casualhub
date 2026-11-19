-- Role derivation from guild rank. These roles drive UI affordances only: addon messages can be forged by a
-- modified client, so nothing here is a security boundary (design doc §9).
local _, GH = ...

local Permissions = {}
GH.Permissions = Permissions

Permissions.ROLE_LEVEL = { none = 0, member = 1, officer = 2, guildmaster = 3 }

-- Minimum role per action. Phase 6 adds a guild-master UI for rank mappings; policy decisions are open (§14).
Permissions.ACTIONS = {
    postAnnouncement = "officer",
    createOfficialEvent = "officer",
    configureGuild = "guildmaster",
    createActivity = "member",
    editOwnProfile = "member",
}

-- rankIndex is 0-based (0 = Guild Master), as returned by GetGuildInfo / GetGuildRosterInfo.
function Permissions:RoleForRank(rankIndex)
    if type(rankIndex) ~= "number" then return "member" end
    local mapped = GH.Settings:Get("permissions.rankRoles." .. tostring(rankIndex))
    if Permissions.ROLE_LEVEL[mapped] then return mapped end
    if rankIndex == 0 then return "guildmaster" end
    if rankIndex == 1 then return "officer" end
    return "member"
end

function Permissions:PlayerRole()
    if not (IsInGuild and IsInGuild()) then return "none" end
    local _, _, rankIndex = GetGuildInfo("player")
    local role = self:RoleForRank(rankIndex)
    -- The client's own officer flag promotes a member whose rank is not mapped as officer.
    if role == "member" and C_GuildInfo and C_GuildInfo.IsGuildOfficer then
        local ok, isOfficer = pcall(C_GuildInfo.IsGuildOfficer)
        if ok and isOfficer then role = "officer" end
    end
    return role
end

function Permissions:Can(action)
    local needed = self.ACTIONS[action]
    if not needed then return false end
    return self.ROLE_LEVEL[self:PlayerRole()] >= self.ROLE_LEVEL[needed]
end

local ROLE_LABELS = { none = "Not in a guild", member = "Member", officer = "Officer", guildmaster = "Guild Master" }
function Permissions:RoleLabel(role)
    return GH.L[ROLE_LABELS[role] or role]
end
