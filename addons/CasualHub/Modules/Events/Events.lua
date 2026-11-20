-- Events and Group Builder (design doc §4.4): scheduled events with role-based signups, waitlists and
-- organizer notes; participant suggestions from voluntarily shared profiles; reminders while the
-- addon is running (no automated invitations, no offline alerts).
--
-- Two single-writer record types, like the Activity Board:
--   event  owned by the organizer: id = "<organizer>#<nonce>", schedule, role slots, lineup overrides
--   rsvp   owned by the attendee:  id = "<eventId>|<attendee>", role, state (going/tentative/declined)
--
-- The lineup is computed, not stored: organizer-confirmed attendees first, then everyone else who is
-- going in signup order, while their role still has a slot and the event has room. The rest wait.
local _, CH = ...
local L = CH.L

local Events = { reminded = {} }
CH.GuildEvents = Events
local MODULE = "Events"
local E_TYPE, R_TYPE = "event", "rsvp"

Events.CATEGORIES = { "raid", "dungeon", "worldboss", "pvp", "social", "other" }
Events.ROLES = { "tank", "healer", "dps" }
Events.STATES = { "going", "tentative", "declined" }
Events.STATUSES = { "scheduled", "cancelled", "completed" }
Events.DURATIONS = { 60, 120, 180, 240 }       -- minutes, offered by the editor
Events.LEAD_MINUTES = { 5, 15, 30, 60 }        -- reminder lead times offered in Settings
Events.TITLE_MAX, Events.DETAILS_MAX, Events.NOTES_MAX, Events.NOTE_MAX = 60, 300, 200, 80
Events.MAX_SIZE = 40
Events.MAX_AHEAD = 60 * 86400                  -- events can be scheduled up to 60 days out
Events.SUGGESTIONS = 8

local KEEP_AFTER_END = 7 * 86400
local ORPHAN_RSVP_TTL = 3 * 86400
local REMINDER_TTL = 2 * 86400

Events.LABELS = {
    raid = L["Raid"], dungeon = L["Dungeon"], worldboss = L["World boss"], pvp = L["PvP"], social = L["Social"],
    other = L["Other"],
    tank = L["Tank"], healer = L["Healer"], dps = L["DPS"],
    going = L["Going"], tentative = L["Tentative"], declined = L["Declined"],
    scheduled = L["Scheduled"], cancelled = L["Cancelled"], completed = L["Completed"],
    upcoming = L["Upcoming"], inprogress = L["In progress"], finished = L["Finished"],
}
Events.CATEGORY_COLORS = {
    raid = "ffe06666", dungeon = "ff6fa8dc", worldboss = "ffe8a040", pvp = "ffcc4444", social = "ff93c47d",
    other = "ffcccccc",
}

local function toSet(list)
    local set = {}
    for _, v in ipairs(list) do set[v] = true end
    return set
end
local CATEGORY_SET, ROLE_SET = toSet(Events.CATEGORIES), toSet(Events.ROLES)
local STATE_SET, STATUS_SET = toSet(Events.STATES), toSet(Events.STATUSES)

local function isInt(n, lo, hi)
    return type(n) == "number" and n % 1 == 0 and n >= lo and n <= hi
end

local function cleanOptional(value, max)
    if value == nil then return true, nil end
    if type(value) ~= "string" then return false end
    local text = CH.CleanText(value, max)
    return true, text ~= "" and text or nil
end

function Events:Label(value)
    return self.LABELS[value] or tostring(value)
end

-- Whether `name` holds an officer-or-higher rank, by our local rank mapping.
function Events:IsOfficer(name)
    return CH.Permissions:CanMember(name, "createOfficialEvent")
end

---------------------------------------------------------------------------
-- Validation (also applied to everything received from peers)
---------------------------------------------------------------------------

function Events.ValidateEvent(r)
    local owner = r.owner
    local prefix = owner .. "#"
    if r.id:sub(1, #prefix) ~= prefix or not r.id:sub(#prefix + 1):match("^%w+$") or #r.id - #prefix > 16 then
        return nil, "bad id"
    end
    if not CATEGORY_SET[r.category] then return nil, "bad category" end
    if not STATUS_SET[r.status] then return nil, "bad status" end
    local title = CH.CleanText(r.title, Events.TITLE_MAX)
    if not title or title == "" then return nil, "missing title" end
    local out = { category = r.category, status = r.status, title = title }
    local ok
    ok, out.details = cleanOptional(r.details, Events.DETAILS_MAX)
    if not ok then return nil, "bad details" end
    ok, out.notes = cleanOptional(r.notes, Events.NOTES_MAX)
    if not ok then return nil, "bad notes" end
    if not isInt(r.startAt, 0, 2 ^ 31) or r.startAt > r.updatedAt + Events.MAX_AHEAD then return nil, "bad start" end
    out.startAt = r.startAt
    if not isInt(r.duration, 15, 720) then return nil, "bad duration" end
    out.duration = r.duration
    if not isInt(r.capacity, 2, Events.MAX_SIZE) then return nil, "bad size" end
    out.capacity = r.capacity
    out.roles = {}
    if r.roles ~= nil then
        if type(r.roles) ~= "table" then return nil, "bad roles" end
        for role, n in pairs(r.roles) do
            if not ROLE_SET[role] or not isInt(n, 0, Events.MAX_SIZE) then return nil, "bad roles" end
            if n > 0 then out.roles[role] = n end
        end
    end
    if r.minLevel ~= nil then
        if not isInt(r.minLevel, 1, 80) then return nil, "bad level" end
        if r.minLevel > 1 then out.minLevel = r.minLevel end
    end
    if r.organizerRole ~= nil then
        if not ROLE_SET[r.organizerRole] then return nil, "bad organizer role" end
        out.organizerRole = r.organizerRole
    end
    if r.official ~= nil and r.official ~= true and r.official ~= false then return nil, "bad official flag" end
    -- An "official" flag from someone we don't see as an officer is dropped, not fatal: rank mappings are
    -- local, so peers may disagree about who counts.
    if r.official == true and Events:IsOfficer(owner) then out.official = true end
    out.lineup = {}
    if r.lineup ~= nil then
        if type(r.lineup) ~= "table" then return nil, "bad lineup" end
        local count = 0
        for name, slot in pairs(r.lineup) do
            count = count + 1
            if count > Events.MAX_SIZE * 2 then return nil, "lineup too long" end
            if type(name) ~= "string" or CH.Identity:Normalize(name) ~= name or name == owner
                or not (ROLE_SET[slot] or slot == "bench") then
                return nil, "bad lineup entry"
            end
            out.lineup[name] = slot
        end
    end
    return out
end

function Events.ValidateRsvp(r)
    if type(r.eventId) ~= "string" or #r.eventId > 80 or not r.eventId:match("^.+#%w+$") then
        return nil, "bad event id"
    end
    if r.id ~= r.eventId .. "|" .. r.owner then return nil, "bad rsvp id" end
    if r.eventId:sub(1, #r.owner + 1) == r.owner .. "#" then return nil, "organizer can't sign up" end
    if not ROLE_SET[r.role] then return nil, "bad role" end
    if not STATE_SET[r.state] then return nil, "bad state" end
    if not isInt(r.joinedAt, 0, 2 ^ 31) or r.joinedAt > r.updatedAt then return nil, "bad join time" end
    local out = { eventId = r.eventId, role = r.role, state = r.state, joinedAt = r.joinedAt }
    local ok
    ok, out.note = cleanOptional(r.note, Events.NOTE_MAX)
    if not ok then return nil, "bad note" end
    return out
end

local function eventEnd(e)
    local scheduledEnd = e.startAt + e.duration * 60
    if e.status == "scheduled" then return scheduledEnd end
    return math.min(scheduledEnd, math.max(e.updatedAt, e.startAt))
end

function Events.PruneEvent(e, now)
    return now > eventEnd(e) + KEEP_AFTER_END
end

function Events.PruneRsvp(r, now)
    local e = CH.Sync:Get(E_TYPE, r.eventId)
    if e then return e.deleted or Events.PruneEvent(e, now) end
    return now - r.updatedAt > ORPHAN_RSVP_TTL
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- "upcoming", "inprogress", "finished", "cancelled" or "completed".
function Events:EffectiveStatus(e, now)
    if e.status ~= "scheduled" then return e.status end
    now = now or CH.ServerTime()
    if now < e.startAt then return "upcoming" end
    if now < e.startAt + e.duration * 60 then return "inprogress" end
    return "finished"
end

function Events:IsActive(e, now)
    local s = self:EffectiveStatus(e, now)
    return s == "upcoming" or s == "inprogress"
end

function Events:Get(id)
    local e = CH.Sync:Get(E_TYPE, id)
    if e and not e.deleted then return e end
end

function Events:IsMine(e)
    return e.owner == CH.Identity:PlayerKey()
end

-- Live events: active ones soonest first, then finished ones most recent first.
function Events:List(now)
    now = now or CH.ServerTime()
    local list = {}
    for _, e in CH.Sync:Iterate(E_TYPE) do
        if not e.deleted then list[#list + 1] = e end
    end
    table.sort(list, function(x, y)
        local ax, ay = self:IsActive(x, now), self:IsActive(y, now)
        if ax ~= ay then return ax end
        if x.startAt ~= y.startAt then
            if ax then return x.startAt < y.startAt end
            return x.startAt > y.startAt
        end
        return x.id < y.id
    end)
    return list
end

function Events:Rsvps(e)
    local out = {}
    for _, r in CH.Sync:Iterate(R_TYPE) do
        if not r.deleted and r.eventId == e.id then out[#out + 1] = r end
    end
    return out
end

function Events:MyRsvp(eventId)
    local me = CH.Identity:PlayerKey()
    local r = me and CH.Sync:Get(R_TYPE, eventId .. "|" .. me)
    if r and not r.deleted then return r end
end

local function byJoined(x, y)
    if x.joinedAt ~= y.joinedAt then return x.joinedAt < y.joinedAt end
    return x.name < y.name
end

-- The group builder. Returns:
--   { slots = { tank = {entries}, healer = {...}, dps = {...} }, waitlist = {...}, tentative = {...},
--     declined = {...}, size = n }
-- Entry: { name, role, note, joinedAt, confirmed?, benched?, organizer?, rsvp? }
-- Role counts are caps when set; a role without a count is limited only by the event size.
function Events:Lineup(e)
    local slots = { tank = {}, healer = {}, dps = {} }
    local result = { slots = slots, waitlist = {}, tentative = {}, declined = {}, size = 0 }
    local function place(entry, role)
        entry.role = role
        slots[role][#slots[role] + 1] = entry
        result.size = result.size + 1
    end
    local function hasRoom(role)
        if result.size >= e.capacity then return false end
        local cap = e.roles[role]
        return cap == nil or #slots[role] < cap
    end

    if e.organizerRole then
        place({ name = e.owner, organizer = true, joinedAt = 0 }, e.organizerRole)
    end

    local going, benched, confirmed = {}, {}, {}
    for _, r in ipairs(self:Rsvps(e)) do
        local entry = { name = r.owner, role = r.role, note = r.note, joinedAt = r.joinedAt, rsvp = r }
        if r.state == "going" then
            local override = e.lineup[r.owner]
            if override == "bench" then
                entry.benched = true
                benched[#benched + 1] = entry
            elseif override then
                entry.confirmed = true
                entry.role = override
                confirmed[#confirmed + 1] = entry
            else
                going[#going + 1] = entry
            end
        elseif r.state == "tentative" then
            result.tentative[#result.tentative + 1] = entry
        else
            result.declined[#result.declined + 1] = entry
        end
    end
    table.sort(confirmed, byJoined)
    table.sort(going, byJoined)
    table.sort(benched, byJoined)
    table.sort(result.tentative, byJoined)
    table.sort(result.declined, byJoined)

    -- Organizer-confirmed attendees always get their spot, even past the role count.
    for _, entry in ipairs(confirmed) do place(entry, entry.role) end
    for _, entry in ipairs(going) do
        if hasRoom(entry.role) then place(entry, entry.role)
        else result.waitlist[#result.waitlist + 1] = entry end
    end
    for _, entry in ipairs(benched) do result.waitlist[#result.waitlist + 1] = entry end
    return result
end

-- "lineup" (with role), "waitlist", "tentative", "declined", or nil when not signed up.
function Events:PlacementOf(e, name, lineup)
    lineup = lineup or self:Lineup(e)
    for role, list in pairs(lineup.slots) do
        for _, entry in ipairs(list) do if entry.name == name then return "lineup", role end end
    end
    for _, key in ipairs({ "waitlist", "tentative", "declined" }) do
        for _, entry in ipairs(lineup[key]) do if entry.name == name then return key end end
    end
end

function Events:ActiveCount()
    local n = 0
    for _, e in ipairs(self:List()) do if self:IsActive(e) then n = n + 1 end end
    return n
end

-- Availability buckets in local time, matching the profile choices.
local function timeBucket(hour)
    if hour >= 6 and hour < 12 then return "morning" end
    if hour >= 12 and hour < 17 then return "afternoon" end
    if hour >= 17 and hour < 22 then return "evening" end
    return "night"
end
local WEEKDAYS = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
Events.TimeBucket = timeBucket

-- Members who might want to come, from voluntarily shared profiles only: not signed up yet, level high
-- enough, a preferred role that still has room. Ranked by availability match, then online.
-- Returns { { name, level, class, roles = {...}, dayMatch, timeMatch, online } }.
function Events:Suggestions(e, limit)
    local P = CH.Modules:IsRunning("Profiles") and CH.Profiles
    if not P then return {} end
    local lineup = self:Lineup(e)
    local function roleOpen(role)
        local cap = e.roles[role]
        return lineup.size < e.capacity and (cap == nil or #lineup.slots[role] < cap)
    end
    local signedUp = {}
    for _, r in ipairs(self:Rsvps(e)) do signedUp[r.owner] = true end
    local t = date("*t", e.startAt)
    local day, bucket = WEEKDAYS[t.wday], timeBucket(t.hour)
    local out = {}
    for _, m in ipairs(CH.Roster:List()) do
        local name = m.name
        local profile = name ~= e.owner and not signedUp[name] and P:Get(name)
        if profile and not profile._local and (not e.minLevel or (m.level or 0) >= e.minLevel) then
            local roles = {}
            for _, role in ipairs(profile.roles or {}) do
                if ROLE_SET[role] and roleOpen(role) then roles[#roles + 1] = role end
            end
            if #roles > 0 then
                local s = { name = name, level = m.level, class = m.class, roles = roles, online = m.online and true }
                for _, d in ipairs(profile.days or {}) do if d == day then s.dayMatch = true end end
                for _, b in ipairs(profile.times or {}) do if b == bucket then s.timeMatch = true end end
                s.score = (s.dayMatch and 2 or 0) + (s.timeMatch and 2 or 0) + (s.online and 1 or 0)
                out[#out + 1] = s
            end
        end
    end
    table.sort(out, function(x, y)
        if x.score ~= y.score then return x.score > y.score end
        return x.name < y.name
    end)
    for i = #out, (limit or self.SUGGESTIONS) + 1, -1 do out[i] = nil end
    return out
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

local FIELDS = { "category", "title", "details", "notes", "startAt", "duration", "capacity", "roles", "minLevel",
    "organizerRole", "official" }

local function check(record)
    local copy = CH.Store.DeepCopy(record)
    copy.updatedAt = CH.ServerTime()
    if record.official and not Events:IsOfficer(record.owner) then
        return nil, L["Only officers can post official events."]
    end
    return Events.ValidateEvent(copy)
end

-- fields: { category, title, details, notes, startAt, duration, capacity, roles, minLevel, organizerRole,
-- official }. Returns id, or nil and a reason.
function Events:Create(fields)
    local me = CH.Identity:PlayerKey()
    if not me or not CH.Identity:GuildKey() then return nil, L["You need to be in a guild."] end
    local record = { id = newId(me), owner = me, status = "scheduled", lineup = {} }
    for _, k in ipairs(FIELDS) do record[k] = fields[k] end
    if record.official == false then record.official = nil end
    local ok, reason = check(record)
    if not ok then return nil, reason end
    if not CH.Sync:PublishLocal(E_TYPE, record) then return nil, L["Could not save."] end
    return record.id
end

local function editOwn(id, mutate)
    local e = Events:Get(id)
    if not e or not Events:IsMine(e) then return false, L["Only the organizer can change this."] end
    local record = CH.Store.DeepCopy(e)
    mutate(record)
    if record.official == false then record.official = nil end
    local ok, reason = check(record)
    if not ok then return false, reason end
    return CH.Sync:PublishLocal(E_TYPE, record)
end

function Events:Update(id, fields)
    return editOwn(id, function(r)
        for _, k in ipairs(FIELDS) do r[k] = fields[k] end
    end)
end

function Events:SetStatus(id, status)
    if not STATUS_SET[status] then return false end
    return editOwn(id, function(r) r.status = status end)
end

-- slot: a role (confirm into the lineup in that role), "bench" (move to the waitlist), or nil (automatic).
function Events:SetLineup(id, name, slot)
    if slot ~= nil and not ROLE_SET[slot] and slot ~= "bench" then return false end
    return editOwn(id, function(r)
        r.lineup = r.lineup or {}
        r.lineup[name] = slot
    end)
end

function Events:Delete(id)
    local e = Events:Get(id)
    if not e or not Events:IsMine(e) then return false end
    return CH.Sync:PublishLocal(E_TYPE, { id = id, owner = e.owner, rev = e.rev, deleted = true })
end

---------------------------------------------------------------------------
-- Writing (attendee)
---------------------------------------------------------------------------

-- state: "going", "tentative" or "declined". Keeps the original signup time while going, so changing
-- role or note doesn't lose your place; dropping out and coming back puts you at the end.
function Events:Respond(eventId, state, role, note)
    local e = self:Get(eventId)
    if not e then return false, L["That event no longer exists."] end
    if self:IsMine(e) then return false, L["You're the organizer."] end
    if not STATE_SET[state] then return false end
    if state ~= "declined" and not self:IsActive(e) then return false, L["That event is over."] end
    local me = CH.Identity:PlayerKey()
    local existing = CH.Sync:Get(R_TYPE, eventId .. "|" .. me)
    if existing and existing.deleted then existing = nil end
    role = role or (existing and existing.role)
    if not role then
        local m = CH.Modules:IsRunning("Profiles") and CH.Profiles:Mine()
        role = m and m.roles and m.roles[1] or "dps"
    end
    if state == "going" and e.minLevel then
        local level = UnitLevel and UnitLevel("player")
        if type(level) == "number" and level < e.minLevel then
            return false, (L["This event needs level %d."]):format(e.minLevel)
        end
    end
    local joinedAt = CH.ServerTime()
    if existing and existing.state == "going" and state == "going" then joinedAt = existing.joinedAt end
    if note == nil and existing then note = existing.note end
    return CH.Sync:PublishLocal(R_TYPE, { id = eventId .. "|" .. me, owner = me, rev = existing and existing.rev or 0,
        eventId = eventId, role = role, state = state, note = note, joinedAt = joinedAt })
end

---------------------------------------------------------------------------
-- Reminders and restrained notifications
---------------------------------------------------------------------------

function Events:Involved(e)
    if self:IsMine(e) then return true end
    local r = self:MyRsvp(e.id)
    return r ~= nil and (r.state == "going" or r.state == "tentative")
end

local function remindedStore()
    return CH.Store:Bucket("eventReminders", true) or Events.reminded
end

local function alert(text)
    CH:Print(text)
    if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then pcall(PlaySound, SOUNDKIT.READY_CHECK) end
end

-- Called every 30s and at login. One reminder `lead` minutes before the start, one at the start.
function Events:CheckReminders(now)
    if not CH.Settings:Get("notifications.events") then return end
    now = now or CH.ServerTime()
    local lead = (CH.Settings:Get("notifications.eventLead") or 15) * 60
    local store = remindedStore()
    for key, at in pairs(store) do
        if type(at) ~= "number" or now - at > REMINDER_TTL then store[key] = nil end
    end
    for _, e in ipairs(self:List(now)) do
        if e.status == "scheduled" and self:Involved(e) then
            local untilStart = e.startAt - now
            if untilStart > 0 and untilStart <= lead and not store[e.id .. "@lead"] then
                store[e.id .. "@lead"] = now
                alert((L["Reminder: \"%s\" starts in %d min (%s)."]):format(e.title, math.ceil(untilStart / 60),
                    date("%H:%M", e.startAt)))
            elseif untilStart <= 0 and untilStart > -600 and not store[e.id .. "@start"] then
                store[e.id .. "@start"] = now
                store[e.id .. "@lead"] = store[e.id .. "@lead"] or now
                alert((L["\"%s\" is starting now. /chub events"]):format(e.title))
            end
        end
    end
end

function Events:OnRecordChanged(typeName, id, record)
    if typeName ~= E_TYPE or not CH.ready or not CH.Settings:Get("notifications.events") then return end
    if record.deleted or record.owner == CH.Identity:PlayerKey() then return end
    -- Tell attendees once when an event they signed up for is cancelled.
    if record.status == "cancelled" and self:Involved(record) and not self.reminded[id .. "@cancel"] then
        self.reminded[id .. "@cancel"] = true
        CH:Print((L["%s cancelled \"%s\"."]):format(record.owner, record.title))
    end
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.4.0",
    description = L["Events: scheduled events with signups and a waitlist"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        CH.Store:RegisterNamespace("eventReminders", "char")
        CH.Sync:RegisterType(E_TYPE, { namespace = "events", validate = Events.ValidateEvent,
            prune = Events.PruneEvent, maxRecords = 300 })
        CH.Sync:RegisterType(R_TYPE, { namespace = "rsvps", validate = Events.ValidateRsvp,
            prune = Events.PruneRsvp, maxRecords = 4000 })
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(...) Events:OnRecordChanged(...) end)
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(30, function() CH.SafeCall("event reminders", Events.CheckReminders, Events) end)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(20, function() CH.SafeCall("event reminders", Events.CheckReminders, Events) end)
        end
    end,
})
