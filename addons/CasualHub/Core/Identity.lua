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

-- The guild's name, or nil when not in a guild or the client has not loaded guild info yet.
-- Realm names are not stable on Forever: the same guild was reported under both "CAMWOWUS1Realm7PvE"
-- (GetGuildInfo) and "CAMWOWUS2Realm7PvE" (the player's realm) in back-to-back sessions, so the key is the
-- guild name alone. Schema migration 2 merges data saved under the old "Name@Realm" keys.
function Identity:GuildKey()
    if self.guildKey ~= nil then return self.guildKey end
    if not (IsInGuild and IsInGuild()) then return nil end
    local guildName = GetGuildInfo("player")
    if type(guildName) ~= "string" or guildName == "" or CH.Compat.IsSecret(guildName) then return nil end
    self.guildKey = guildName
    return self.guildKey
end

function Identity:GuildName()
    if not (IsInGuild and IsInGuild()) then return nil end
    return (GetGuildInfo("player"))
end

function Identity:InvalidateGuild()
    self.guildKey = nil
end
