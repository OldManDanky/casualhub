-- Guild Activity Board (design doc §4.3): requests for quests, dungeons, attunements, world bosses,
-- gearing and general help. Members volunteer or withdraw; the organizer accepts volunteers, edits,
-- closes and completes the request.
--
-- Two single-writer record types keep ownership simple:
--   activity  owned by the organizer: id = "<organizer>#<nonce>", details, status, accepted volunteers
--   signup    owned by the volunteer: id = "<activityId>|<volunteer>", role, state (volunteered/withdrawn)
local _, CH = ...
local L = CH.L

local Activities = { notified = {} }
CH.Activities = Activities
local MODULE = "Activities"
local A_TYPE, S_TYPE = "activity", "signup"

Activities.CATEGORIES = { "quests", "dungeons", "attunements", "worldbosses", "gearing", "help" }
Activities.ROLES = { "tank", "healer", "dps" }
Activities.SIGNUP_ROLES = { "tank", "healer", "dps", "any" }
Activities.STATUSES = { "open", "closed", "completed", "cancelled" }
Activities.EXPIRY_HOURS = { 2, 6, 24, 72 }
Activities.TITLE_MAX, Activities.DETAILS_MAX, Activities.NOTE_MAX = 60, 300, 80
Activities.MAX_GROUP = 40

local MAX_LIFETIME = 15 * 86400   -- an activity may stay open at most this long
local KEEP_AFTER_END = 7 * 86400  -- finished or expired activities are kept this long, then pruned
local ORPHAN_SIGNUP_TTL = 3 * 86400

Activities.LABELS = {
    quests = L["Quests"], dungeons = L["Dungeons"], attunements = L["Attunements"], worldbosses = L["World bosses"],
    gearing = L["Gearing"], help = L["General help"],
    tank = L["Tank"], healer = L["Healer"], dps = L["DPS"], any = L["Any role"],
    open = L["Open"], closed = L["Closed"], completed = L["Completed"], cancelled = L["Cancelled"],
    expired = L["Expired"], full = L["Full"],
    volunteered = L["Volunteered"], withdrawn = L["Withdrawn"], accepted = L["Accepted"],
}
Activities.CATEGORY_COLORS = {
    quests = "ffe8c547", dungeons = "ff6fa8dc", attunements = "ffb48ee0", worldbosses = "ffe06666",
    gearing = "ff93c47d", help = "ffcccccc",
}

local function toSet(list)
    local set = {}
    for _, v in ipairs(list) do set[v] = true end
    return set
end
local CATEGORY_SET, STATUS_SET = toSet(Activities.CATEGORIES), toSet(Activities.STATUSES)
local ROLE_SET, SIGNUP_ROLE_SET = toSet(Activities.ROLES), toSet(Activities.SIGNUP_ROLES)

local function isInt(n, lo, hi)
    return type(n) == "number" and n % 1 == 0 and n >= lo and n <= hi
end

function Activities:Label(value)
    return self.LABELS[value] or tostring(value)
end

---------------------------------------------------------------------------
-- Validation (also applied to everything received from peers)
---------------------------------------------------------------------------

function Activities.ValidateActivity(r)
    local owner = r.owner
    local prefix = owner .. "#"
    if r.id:sub(1, #prefix) ~= prefix or not r.id:sub(#prefix + 1):match("^%w+$") or #r.id - #prefix > 16 then
        return nil, "bad id"
    end
    if not CATEGORY_SET[r.category] then return nil, "bad category" end
    if not STATUS_SET[r.status] then return nil, "bad status" end
    local title = CH.CleanText(r.title, Activities.TITLE_MAX)
    if not title or title == "" then return nil, "missing title" end
    local out = { category = r.category, status = r.status, title = title }
    if r.details ~= nil then
        if type(r.details) ~= "string" then return nil, "bad details" end
        local details = CH.CleanText(r.details, Activities.DETAILS_MAX)
        if details ~= "" then out.details = details end
    end
    if r.startAt ~= nil then
        if not isInt(r.startAt, 0, 2 ^ 31) then return nil, "bad start" end
        out.startAt = r.startAt
    end
    if not isInt(r.expiresAt, 0, 2 ^ 31) or r.expiresAt > r.updatedAt + MAX_LIFETIME then return nil, "bad expiry" end
    out.expiresAt = r.expiresAt
    out.roles = {}
    if r.roles ~= nil then
        if type(r.roles) ~= "table" then return nil, "bad roles" end
        for role, n in pairs(r.roles) do
            if not ROLE_SET[role] or not isInt(n, 0, Activities.MAX_GROUP) then return nil, "bad roles" end
            if n > 0 then out.roles[role] = n end
        end
    end
    if r.capacity ~= nil then
        if not isInt(r.capacity, 2, Activities.MAX_GROUP) then return nil, "bad capacity" end
        out.capacity = r.capacity
    end
    out.accepted = {}
    if r.accepted ~= nil then
        if type(r.accepted) ~= "table" then return nil, "bad accepted" end
        local count = 0
        for name, role in pairs(r.accepted) do
            count = count + 1
            if count > Activities.MAX_GROUP then return nil, "too many accepted" end
            if CH.Identity:Normalize(name) ~= name or name == owner or not SIGNUP_ROLE_SET[role] then
                return nil, "bad accepted entry"
            end
            out.accepted[name] = role
        end
    end
    return out
end

function Activities.ValidateSignup(r)
    if type(r.activityId) ~= "string" or #r.activityId > 80 or not r.activityId:match("^.+#%w+$") then
        return nil, "bad activity id"
    end
    if r.id ~= r.activityId .. "|" .. r.owner then return nil, "bad signup id" end
    if r.activityId:sub(1, #r.owner + 1) == r.owner .. "#" then return nil, "can't volunteer for your own activity" end
    if not SIGNUP_ROLE_SET[r.role] then return nil, "bad role" end
    if r.state ~= "volunteered" and r.state ~= "withdrawn" then return nil, "bad state" end
    local out = { activityId = r.activityId, role = r.role, state = r.state }
    if r.note ~= nil then
        if type(r.note) ~= "string" then return nil, "bad note" end
        local note = CH.CleanText(r.note, Activities.NOTE_MAX)
        if note ~= "" then out.note = note end
    end
    return out
end

local function activityEnd(a)
    if a.status ~= "open" then return a.updatedAt end
    return a.expiresAt
end

function Activities.PruneActivity(a, now)
    return now > activityEnd(a) + KEEP_AFTER_END
end

function Activities.PruneSignup(s, now)
    local activity = CH.Sync:Get(A_TYPE, s.activityId)
    if activity then return activity.deleted or Activities.PruneActivity(activity, now) end
    return now - s.updatedAt > ORPHAN_SIGNUP_TTL
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- "open", "full", "expired", "closed", "completed" or "cancelled".
function Activities:EffectiveStatus(a, now)
    now = now or CH.ServerTime()
    if a.status ~= "open" then return a.status end
    if now > a.expiresAt then return "expired" end
    if a.capacity and self:AcceptedCount(a) + 1 >= a.capacity then return "full" end
    return "open"
end

function Activities:IsActive(a, now)
    local status = self:EffectiveStatus(a, now)
    return status == "open" or status == "full"
end

-- True when an accepted volunteer has since withdrawn. Acceptance lives on the
-- organizer's record and withdrawal on the volunteer's, so both are checked.
function Activities:HasWithdrawn(activity, name)
    local s = CH.Sync:Get(S_TYPE, activity.id .. "|" .. name)
    return s ~= nil and not s.deleted and s.state == "withdrawn"
end

-- Accepted volunteers who are still in (withdrawn ones don't hold a slot).
function Activities:AcceptedCount(a)
    local n = 0
    for name in pairs(a.accepted or {}) do
        if not self:HasWithdrawn(a, name) then n = n + 1 end
    end
    return n
end

function Activities:Get(id)
    local a = CH.Sync:Get(A_TYPE, id)
    if a and not a.deleted then return a end
end

-- All live activities, newest first.
function Activities:List()
    local list = {}
    for _, a in CH.Sync:Iterate(A_TYPE) do
        if not a.deleted then list[#list + 1] = a end
    end
    table.sort(list, function(x, y)
        local ax, ay = self:IsActive(x), self:IsActive(y)
        if ax ~= ay then return ax end
        local tx, ty = x.startAt or x.updatedAt, y.startAt or y.updatedAt
        if ax and tx ~= ty then return tx < ty end  -- active: soonest first
        if tx ~= ty then return tx > ty end         -- finished: most recent first
        return x.id < y.id
    end)
    return list
end

-- Live signups for an activity: { name, role, note, state, accepted }.
function Activities:Volunteers(activity)
    local out = {}
    for _, s in CH.Sync:Iterate(S_TYPE) do
        if not s.deleted and s.activityId == activity.id then
            out[#out + 1] = { name = s.owner, role = s.role, note = s.note, state = s.state,
                accepted = activity.accepted[s.owner] ~= nil and s.state ~= "withdrawn",
                withdrewAfterAccept = activity.accepted[s.owner] ~= nil and s.state == "withdrawn" }
        end
    end
    -- Accepted volunteers whose signup we haven't received still count.
    for name, role in pairs(activity.accepted or {}) do
        local found = false
        for _, v in ipairs(out) do if v.name == name then found = true end end
        if not found then out[#out + 1] = { name = name, role = role, state = "volunteered", accepted = true } end
    end
    table.sort(out, function(x, y)
        if x.accepted ~= y.accepted then return x.accepted end
        if (x.state == "withdrawn") ~= (y.state == "withdrawn") then return y.state == "withdrawn" end
        return x.name < y.name
    end)
    return out
end

function Activities:ActiveVolunteerCount(activity)
    local n = 0
    for _, v in ipairs(self:Volunteers(activity)) do
        if v.state == "volunteered" or v.accepted then n = n + 1 end  -- withdrawn never counts
    end
    return n
end

function Activities:MySignup(activityId)
    local me = CH.Identity:PlayerKey()
    local s = me and CH.Sync:Get(S_TYPE, activityId .. "|" .. me)
    if s and not s.deleted then return s end
end

function Activities:IsMine(activity)
    return activity.owner == CH.Identity:PlayerKey()
end

-- Accepted count per role, for "T 1/2" style summaries.
function Activities:RoleFill(activity)
    local fill = {}
    for name, role in pairs(activity.accepted or {}) do
        if not self:HasWithdrawn(activity, name) then fill[role] = (fill[role] or 0) + 1 end
    end
    return fill
end

function Activities:OpenCount()
    local n = 0
    for _, a in ipairs(self:List()) do
        if self:IsActive(a) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Writing (organizer)
---------------------------------------------------------------------------

local function newId(owner)
    local t = CH.ServerTime()
    local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    local s = ""
    repeat
        local d = t % 36
        s = alphabet:sub(d + 1, d + 1) .. s
        t = math.floor(t / 36)
    until t == 0
    for _ = 1, 3 do
        local d = math.random(0, 35)
        s = s .. alphabet:sub(d + 1, d + 1)
    end
    return owner .. "#" .. s
end

-- fields: { category, title, details, startAt, expiresAt, roles, capacity }. Returns id or nil, reason.
function Activities:Create(fields)
    local me = CH.Identity:PlayerKey()
    if not me or not CH.Identity:GuildKey() then return nil, L["You need to be in a guild."] end
    local record = { id = newId(me), owner = me, status = "open", accepted = {} }
    for _, k in ipairs({ "category", "title", "details", "startAt", "expiresAt", "roles", "capacity" }) do
        record[k] = fields[k]
    end
    local check = CH.Store.DeepCopy(record)
    check.updatedAt = CH.ServerTime()
    local ok, reason = Activities.ValidateActivity(check)
    if not ok then return nil, reason end
    if not CH.Sync:PublishLocal(A_TYPE, record) then return nil, L["Could not save."] end
    return record.id
end

local function editOwn(id, mutate)
    local a = Activities:Get(id)
    if not a or not Activities:IsMine(a) then return false, L["Only the organizer can change this."] end
    local record = CH.Store.DeepCopy(a)
    mutate(record)
    local check = CH.Store.DeepCopy(record)
    check.updatedAt = CH.ServerTime()
    local ok, reason = Activities.ValidateActivity(check)
    if not ok then return false, reason end
    return CH.Sync:PublishLocal(A_TYPE, record)
end

function Activities:Update(id, fields)
    return editOwn(id, function(r)
        for _, k in ipairs({ "category", "title", "details", "startAt", "expiresAt", "roles", "capacity" }) do
            r[k] = fields[k]
        end
        if r.status ~= "open" then r.status = "open" end
    end)
end

function Activities:SetStatus(id, status)
    if not STATUS_SET[status] then return false end
    return editOwn(id, function(r)
        r.status = status
        if status == "open" and r.expiresAt < CH.ServerTime() then
            r.expiresAt = CH.ServerTime() + 2 * 3600  -- reopening an expired request gives it two more hours
        end
    end)
end

function Activities:SetAccepted(id, name, role)
    return editOwn(id, function(r)
        r.accepted = r.accepted or {}
        r.accepted[name] = role
    end)
end

function Activities:Delete(id)
    local a = self:Get(id)
    if not a or not self:IsMine(a) then return false end
    return CH.Sync:PublishLocal(A_TYPE, { id = id, owner = a.owner, rev = a.rev, deleted = true })
end

---------------------------------------------------------------------------
-- Writing (volunteer)
---------------------------------------------------------------------------

function Activities:Volunteer(activityId, role, note)
    local a = self:Get(activityId)
    if not a then return false, L["That request no longer exists."] end
    if self:IsMine(a) then return false, L["You're the organizer."] end
    if not self:IsActive(a) and not a.accepted[CH.Identity:PlayerKey()] then
        return false, L["That request isn't open."]
    end
    local me = CH.Identity:PlayerKey()
    local existing = CH.Sync:Get(S_TYPE, activityId .. "|" .. me)
    return CH.Sync:PublishLocal(S_TYPE, { id = activityId .. "|" .. me, owner = me, rev = existing and existing.rev or 0,
        activityId = activityId, role = role or "any", note = note, state = "volunteered" })
end

function Activities:Withdraw(activityId)
    local s = self:MySignup(activityId)
    if not s then return false end
    local record = CH.Store.DeepCopy(s)
    record.state = "withdrawn"
    return CH.Sync:PublishLocal(S_TYPE, record)
end

---------------------------------------------------------------------------
-- Restrained notifications: someone volunteers for your request, an accepted
-- volunteer withdraws, or you're accepted.
---------------------------------------------------------------------------

function Activities:OnRecordChanged(typeName, id, record)
    if not CH.Settings:Get("notifications.activities") or not CH.ready then return end
    local me = CH.Identity:PlayerKey()
    if typeName == S_TYPE and not record.deleted and record.state == "volunteered" and record.owner ~= me then
        local a = self:Get(record.activityId)
        local key = id .. "@v"
        if a and a.owner == me and self:IsActive(a) and not self.notified[key] then
            self.notified[key] = true
            CH:Print(L["%s volunteered (%s) for \"%s\". /chub activities"], record.owner, self:Label(record.role), a.title)
        end
        self.notified[id .. "@w"] = nil
    elseif typeName == S_TYPE and not record.deleted and record.state == "withdrawn" and record.owner ~= me then
        local a = self:Get(record.activityId)
        local key = id .. "@w"
        if a and a.owner == me and a.accepted[record.owner] and self:IsActive(a) and not self.notified[key] then
            self.notified[key] = true
            CH:Print(L["%s withdrew from \"%s\". /chub activities"], record.owner, a.title)
        end
    elseif typeName == A_TYPE and not record.deleted and record.owner ~= me and record.accepted and record.accepted[me] then
        local key = id .. "@a"
        if not self.notified[key] and self:IsActive(record) then
            self.notified[key] = true
            CH:Print(L["%s accepted you for \"%s\". /chub activities"], record.owner, record.title)
        end
    end
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.3.2",
    description = L["Activity Board: post requests and volunteer"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        CH.Sync:RegisterType(A_TYPE, { namespace = "activities", validate = Activities.ValidateActivity,
            prune = Activities.PruneActivity, maxRecords = 400 })
        CH.Sync:RegisterType(S_TYPE, { namespace = "signups", validate = Activities.ValidateSignup,
            prune = Activities.PruneSignup, maxRecords = 3000 })
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(...) Activities:OnRecordChanged(...) end)
    end,
})
