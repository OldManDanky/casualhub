-- Character and guild identity.
--
-- Forever characters have surnames. Names are "First Last" everywhere that matters (roster, addon-message
-- senders, GetUnitName), and UnitName("player") returns "First", "Last" (surname in Retail's realm slot).
-- First names are not unique, so the canonical character key is the full "First Last" name.
-- Whisper targets accept "First Last" and "First-Last" but not "First" alone.
local _, CH = ...

local Identity = {}
CH.Identity = Identity

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Canonical character key, or nil for unusable input (nil, secret, empty, "Unknown").
function Identity:Normalize(name)
    if type(name) ~= "string" or CH.Compat.IsSecret(name) then return nil end
    name = trim(name)
    if CH.Compat.isForever then
        -- "First-Last" (whisper/WTF spelling) and "First Last" refer to the same character.
        name = name:gsub("%-", " ")
    end
    if name == "" or name == UNKNOWNOBJECT then return nil end
    return name
end

function Identity:PlayerKey()
    if self.playerKey then return self.playerKey end
    local key
    if GetUnitName then key = GetUnitName("player", true) end
    if not key or key == "" then
        local first, second = UnitName("player")
        if second and second ~= "" then
            key = first .. (CH.Compat.isForever and " " or "-") .. second
        else
            key = first
        end
    end
    key = self:Normalize(key)
    if key then self.playerKey = key end  -- only cache once the client knows the name
    return key
end

function Identity:IsPlayer(name)
    local key = self:Normalize(name)
    return key ~= nil and key == self:PlayerKey()
end

function Identity:PlayerGUID()
    return UnitGUID("player")
end

-- "Guild Name@Realm", or nil when not in a guild or the client has not loaded guild info yet.
function Identity:GuildKey()
    if self.guildKey ~= nil then return self.guildKey or nil end
    if not (IsInGuild and IsInGuild()) then return nil end
    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if type(guildName) ~= "string" or guildName == "" then return nil end
    if type(guildRealm) ~= "string" or guildRealm == "" then
        guildRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    end
    self.guildKey = guildName .. "@" .. tostring(guildRealm)
    return self.guildKey
end

function Identity:GuildName()
    if not (IsInGuild and IsInGuild()) then return nil end
    return (GetGuildInfo("player"))
end

function Identity:InvalidateGuild()
    self.guildKey = nil
end
