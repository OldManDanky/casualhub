-- Role derivation from guild rank. These roles drive UI affordances only: addon messages can be forged by a
-- modified client, so nothing here is a security boundary (design doc §9).
local _, CH = ...

local Permissions = {}
CH.Permissions = Permissions

Permissions.ROLE_LEVEL = { none = 0, member = 1, officer = 2, guildmaster = 3 }

-- Minimum role per action. The guild master's shared policy (Bulletin module) can change rank mappings and
-- who may post notices; see SetPolicyProvider.
Permissions.ACTIONS = {
    postAnnouncement = "officer",
    createOfficialEvent = "officer",
    viewReports = "officer",
    addBlacklist = "member",
    clearBlacklist = "officer",
    configureGuild = "guildmaster",
    createActivity = "member",
    editOwnProfile = "member",
}

-- provider() -> policy table { rankRoles = { ["1"] = "officer", ... }, noticeRole = "officer"|"member" } or nil.
function Permissions:SetPolicyProvider(provider)
    self.policyProvider = provider
end

function Permissions:Policy()
    if not self.policyProvider then return nil end
    local ok, policy = pcall(self.policyProvider)
    if ok and type(policy) == "table" then return policy end
end

-- Minimum role for an action, after the guild policy.
function Permissions:Needed(action)
    local policy = self:Policy()
    if action == "postAnnouncement" and policy and self.ROLE_LEVEL[policy.noticeRole] then return policy.noticeRole end
    return self.ACTIONS[action]
end

-- rankIndex is 0-based (0 = Guild Master), as returned by GetGuildInfo / GetGuildRosterInfo.
-- Precedence: the guild master's published policy, then this client's own setting, then the defaults.
function Permissions:RoleForRank(rankIndex)
    if type(rankIndex) ~= "number" then return "member" end
    if rankIndex == 0 then return "guildmaster" end
    local policy = self:Policy()
    local fromPolicy = policy and policy.rankRoles and policy.rankRoles[tostring(rankIndex)]
    if fromPolicy == "member" or fromPolicy == "officer" then return fromPolicy end
    local mapped = CH.Settings:Get("permissions.rankRoles." .. tostring(rankIndex))
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

-- Role of another guild member, from the roster rank and the same mappings.
function Permissions:RoleOf(name)
    if name == CH.Identity:PlayerKey() then return self:PlayerRole() end
    local m = CH.Roster:Get(name)
    if not m then return "none" end
    return self:RoleForRank(m.rankIndex)
end

function Permissions:CanMember(name, action)
    local needed = self:Needed(action)
    if not needed then return false end
    return self.ROLE_LEVEL[self:RoleOf(name)] >= self.ROLE_LEVEL[needed]
end

function Permissions:Can(action)
    local needed = self:Needed(action)
    if not needed then return false end
    return self.ROLE_LEVEL[self:PlayerRole()] >= self.ROLE_LEVEL[needed]
end

local ROLE_LABELS = { none = "Not in a guild", member = "Member", officer = "Officer", guildmaster = "Guild Master" }
function Permissions:RoleLabel(role)
    return CH.L[ROLE_LABELS[role] or role]
end
