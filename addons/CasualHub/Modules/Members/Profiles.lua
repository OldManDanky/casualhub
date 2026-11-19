-- Member profiles (design doc §4.2): opt-out sharing (on by default, every field optional and empty at first).
--
-- The authoritative copy of your own profile lives in per-character storage ("myProfile"). The synced
-- "profile" record mirrors it while sharing is on; turning sharing off publishes a tombstone so guildmates
-- drop it, and turning it back on republishes the private copy.
local _, CH = ...
local L = CH.L

local Profiles = {}
CH.Profiles = Profiles
local MODULE = "Profiles"
local TYPE = "profile"

Profiles.ROLES = { "tank", "healer", "dps" }
Profiles.INTERESTS = { "quests", "dungeons", "attunements", "worldbosses", "raids", "crafting", "gearing", "pvp", "social" }
Profiles.DAYS = { "mon", "tue", "wed", "thu", "fri", "sat", "sun" }
Profiles.TIMES = { "morning", "afternoon", "evening", "night" }
Profiles.NOTE_MAX = 140

Profiles.LABELS = {
    tank = L["Tank"], healer = L["Healer"], dps = L["DPS"],
    quests = L["Quests"], dungeons = L["Dungeons"], attunements = L["Attunements"], worldbosses = L["World bosses"],
    raids = L["Raids"], crafting = L["Crafting"], gearing = L["Gearing"], pvp = L["PvP"], social = L["Socializing"],
    mon = L["Mon"], tue = L["Tue"], wed = L["Wed"], thu = L["Thu"], fri = L["Fri"], sat = L["Sat"], sun = L["Sun"],
    morning = L["Mornings"], afternoon = L["Afternoons"], evening = L["Evenings"], night = L["Late night"],
}

local LIST_FIELDS = { roles = Profiles.ROLES, interests = Profiles.INTERESTS, days = Profiles.DAYS, times = Profiles.TIMES }

-- Keeps only known values, in canonical order, without duplicates. Returns nil for non-lists.
local function cleanList(value, allowed)
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    local present = {}
    for _, v in pairs(value) do
        if type(v) == "string" then present[v] = true end
    end
    local out = {}
    for _, v in ipairs(allowed) do
        if present[v] then out[#out + 1] = v end
    end
    return out
end

-- Validator for synced records: returns a cleaned copy with only known fields (unknown fields from newer
-- versions are dropped), or nil plus a reason.
function Profiles.Validate(record)
    if record.id ~= record.owner then return nil, "profile id must equal owner" end
    local out = {}
    for field, allowed in pairs(LIST_FIELDS) do
        local list = cleanList(record[field], allowed)
        if not list then return nil, "bad " .. field end
        out[field] = list
    end
    if record.main ~= nil then
        local main = CH.Identity:Normalize(record.main)
        if not main or #main > 48 or main == record.owner then return nil, "bad main" end
        out.main = main
    end
    if record.note ~= nil then
        if type(record.note) ~= "string" then return nil, "bad note" end
        local note = CH.CleanText(record.note, Profiles.NOTE_MAX)
        if note ~= "" then out.note = note end
    end
    return out
end

function Profiles.SameFields(a, b)
    local ca, cb = Profiles.Validate({ id = "x", owner = "x", roles = a.roles, interests = a.interests,
        days = a.days, times = a.times, main = a.main, note = a.note }), Profiles.Validate({ id = "x", owner = "x",
        roles = b.roles, interests = b.interests, days = b.days, times = b.times, main = b.main, note = b.note })
    if not ca or not cb then return false end
    return CH.Serializer.Encode(ca) == CH.Serializer.Encode(cb)
end

---------------------------------------------------------------------------
-- Own profile
---------------------------------------------------------------------------

function Profiles:Mine()
    local mine = CH.Store:Get("myProfile", "profile")
    if type(mine) ~= "table" then
        mine = { roles = {}, interests = {}, days = {}, times = {} }
    end
    return mine
end

function Profiles:IsSharing()
    return CH.Settings:Get("profile.share") ~= false
end

-- Publishes (or retracts) the shared copy to match the private copy and the sharing setting.
function Profiles:Publish()
    local me = CH.Identity:PlayerKey()
    if not me or not CH.Identity:GuildKey() or not CH.Roster.loaded then return false end
    local shared = CH.Sync:Get(TYPE, me)
    if self:IsSharing() then
        local record = CH.Store.DeepCopy(self:Mine())
        record.id, record.owner = me, me
        if shared and not shared.deleted and Profiles.SameFields(shared, record) then
            return true  -- already published; don't bump the revision on every login
        end
        record.rev = shared and shared.rev or 0
        return CH.Sync:PublishLocal(TYPE, record)
    elseif shared and not shared.deleted then
        return CH.Sync:PublishLocal(TYPE, { id = me, owner = me, rev = shared.rev, deleted = true })
    end
    return true
end

-- fields: { roles, interests, days, times, main, note }. Returns true or false plus a user-facing reason.
function Profiles:SaveMine(fields)
    local me = CH.Identity:PlayerKey()
    local candidate = { id = me, owner = me }
    for k, v in pairs(fields) do candidate[k] = v end
    if candidate.main == "" then candidate.main = nil end
    if candidate.main then
        local main = CH.Identity:Normalize(candidate.main)
        if main == me then return false, L["Your main can't be this character."] end
        if not CH.Roster:IsMember(main) then
            return false, (L["%s is not in the guild roster. Use the full name, for example \"First Last\"."]):format(tostring(main))
        end
        candidate.main = main
    end
    local clean, reason = Profiles.Validate(candidate)
    if not clean then return false, reason end
    clean.id, clean.owner = nil, nil
    CH.Store:Put("myProfile", "profile", clean)
    self:Publish()
    CH.Events:Publish("PROFILE_SAVED")
    return true
end

function Profiles:ResetMine()
    CH.Store:Delete("myProfile", "profile")
    self:Publish()
    CH.Events:Publish("PROFILE_SAVED")
end

---------------------------------------------------------------------------
-- Reading profiles
---------------------------------------------------------------------------

function Profiles:Get(name)
    local key = CH.Identity:Normalize(name)
    if not key then return nil end
    if key == CH.Identity:PlayerKey() then
        local mine = CH.Store.DeepCopy(self:Mine())
        mine.id, mine.owner, mine._local = key, key, true
        local shared = CH.Sync:Get(TYPE, key)
        mine.updatedAt = shared and shared.updatedAt
        mine.private = not self:IsSharing()
        return mine
    end
    local record = CH.Sync:Get(TYPE, key)
    if record and not record.deleted then return record end
    return nil
end

-- Alts that point at `name` as their main.
function Profiles:AltsOf(name)
    local key = CH.Identity:Normalize(name)
    local alts = {}
    for id, record in CH.Sync:Iterate(TYPE) do
        if not record.deleted and record.main == key and id ~= key then alts[#alts + 1] = id end
    end
    table.sort(alts)
    return alts
end

function Profiles:Label(value)
    return self.LABELS[value] or value
end

function Profiles:FormatList(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local out = {}
    for i, v in ipairs(list) do out[i] = self:Label(v) end
    return table.concat(out, ", ")
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.2.0",
    description = L["Member profiles shared with the guild"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        CH.Store:RegisterNamespace("myProfile", "char")
        CH.Sync:RegisterType(TYPE, { namespace = "profiles", validate = Profiles.Validate, maxRecords = 1000 })
        -- Publish once the guild and roster are known (not available at PLAYER_LOGIN on every client).
        local function ensurePublished()
            if Profiles.published then return end
            if Profiles:Publish() then
                Profiles.published = true
                CH.Events:Unsubscribe("ROSTER_UPDATED", MODULE)
            end
        end
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, ensurePublished)
        CH.Events:Subscribe("SETTING_CHANGED", MODULE .. "-share", function(path)
            if path == "profile.share" then Profiles:Publish() end
        end)
        ensurePublished()
    end,
})
