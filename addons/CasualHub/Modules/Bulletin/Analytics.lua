-- Leadership reports (design doc §4.7): weekly guild-wide trends of event attendance and activity
-- participation. Collected locally from the records this client sees, kept 12 weeks, never synced, and only
-- shown to officers. Counts only: names are kept just long enough to count distinct people per week, and no
-- per-player figures are shown.
local _, CH = ...
local L = CH.L

local Analytics = {}
CH.Analytics = Analytics
local MODULE = "Analytics"

Analytics.RETENTION_WEEKS = 12
local SEEN_TTL = 120 * 86400

local function bucket()
    local b = CH.Store:Bucket("analytics", true)
    if not b then return nil end
    b.weeks = b.weeks or {}
    b.seen = b.seen or {}
    return b
end

-- Monday (local time) of the week containing ts, as "YYYY-MM-DD".
function Analytics.WeekOf(ts)
    local t = date("*t", ts)
    local back = (t.wday + 5) % 7  -- wday: 1 = Sunday
    t.day, t.hour, t.min, t.sec = t.day - back, 12, 0, 0
    return date("%Y-%m-%d", time(t))
end

local function week(b, ts)
    local key = Analytics.WeekOf(ts)
    local w = b.weeks[key]
    if not w then
        w = { events = 0, cancelled = 0, lineup = 0, waitlist = 0, attendees = {}, byCategory = {},
            activitiesPosted = 0, activitiesCompleted = 0, volunteers = 0, craftPosted = 0, craftDone = 0, users = {} }
        b.weeks[key] = w
    end
    return w
end

local function once(b, key, now)
    if b.seen[key] then return false end
    b.seen[key] = now
    return true
end

-- Folds newly finished events, activities and requests into the weekly counts.
function Analytics:Collect(now)
    local b = bucket()
    if not b then return end
    now = now or CH.ServerTime()

    local E = CH.Modules:IsRunning("Events") and CH.GuildEvents
    if E then
        for _, e in ipairs(E:List(now)) do
            local status = E:EffectiveStatus(e, now)
            if status == "cancelled" then
                if once(b, "ec:" .. e.id, now) then week(b, e.startAt).cancelled = week(b, e.startAt).cancelled + 1 end
            elseif (status == "finished" or status == "completed") and now >= e.startAt then
                if once(b, "e:" .. e.id, now) then
                    local w, lineup = week(b, e.startAt), E:Lineup(e)
                    w.events = w.events + 1
                    w.lineup = w.lineup + lineup.size
                    w.waitlist = w.waitlist + #lineup.waitlist
                    w.byCategory[e.category] = (w.byCategory[e.category] or 0) + 1
                    for _, list in pairs(lineup.slots) do
                        for _, entry in ipairs(list) do w.attendees[entry.name] = true end
                    end
                end
            end
        end
    end

    local A = CH.Modules:IsRunning("Activities") and CH.Activities
    if A then
        for _, a in ipairs(A:List()) do
            if once(b, "ap:" .. a.id, now) then
                local w = week(b, a.updatedAt)
                w.activitiesPosted = w.activitiesPosted + 1
            end
            if a.status == "completed" and once(b, "ac:" .. a.id, now) then
                local w = week(b, a.updatedAt)
                w.activitiesCompleted = w.activitiesCompleted + 1
                w.volunteers = w.volunteers + A:AcceptedCount(a)
            end
        end
    end

    local P = CH.Modules:IsRunning("Professions") and CH.Professions
    if P then
        for _, q in ipairs(P:Requests()) do
            if once(b, "qp:" .. q.id, now) then
                local w = week(b, q.updatedAt)
                w.craftPosted = w.craftPosted + 1
            end
            if q.status == "done" and once(b, "qd:" .. q.id, now) then
                local w = week(b, q.updatedAt)
                w.craftDone = w.craftDone + 1
            end
        end
    end

    -- Casual Hub users this week: ourselves plus every peer heard from.
    local w = week(b, now)
    local me = CH.Identity:PlayerKey()
    if me then w.users[me] = true end
    for name, peer in pairs(CH.Comm.peers or {}) do
        if type(peer) == "table" and peer.lastSeen and Analytics.WeekOf(peer.lastSeen) == Analytics.WeekOf(now) then
            w.users[name] = true
        end
    end

    self:Prune(now)
end

function Analytics:Prune(now)
    local b = bucket()
    if not b then return end
    local keys = {}
    for key in pairs(b.weeks) do keys[#keys + 1] = key end
    table.sort(keys)
    for i = 1, #keys - self.RETENTION_WEEKS do b.weeks[keys[i]] = nil end
    for key, at in pairs(b.seen) do
        if type(at) ~= "number" or now - at > SEEN_TTL then b.seen[key] = nil end
    end
end

local function count(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

-- Newest week first: { week, events, cancelled, avgLineup, waitlist, attendees, byCategory, activitiesPosted,
-- activitiesCompleted, volunteers, craftPosted, craftDone, users }. Counts only.
function Analytics:Report(weeks)
    local b = bucket()
    local rows = {}
    if not b then return rows end
    local keys = {}
    for key in pairs(b.weeks) do keys[#keys + 1] = key end
    table.sort(keys, function(x, y) return x > y end)
    for i = 1, math.min(weeks or self.RETENTION_WEEKS, #keys) do
        local w = b.weeks[keys[i]]
        rows[#rows + 1] = {
            week = keys[i], events = w.events, cancelled = w.cancelled, waitlist = w.waitlist,
            avgLineup = w.events > 0 and (w.lineup / w.events) or 0, attendees = count(w.attendees),
            byCategory = CH.Store.DeepCopy(w.byCategory), activitiesPosted = w.activitiesPosted,
            activitiesCompleted = w.activitiesCompleted, volunteers = w.volunteers, craftPosted = w.craftPosted,
            craftDone = w.craftDone, users = count(w.users),
        }
    end
    return rows
end

function Analytics:CSV(weeks)
    local out = { "week,events,cancelled,avg_lineup,waitlisted,distinct_attendees,activity_requests,activities_completed,volunteers_accepted,craft_requests,craft_done,casual_hub_users" }
    for _, r in ipairs(self:Report(weeks)) do
        out[#out + 1] = ("%s,%d,%d,%.1f,%d,%d,%d,%d,%d,%d,%d,%d"):format(r.week, r.events, r.cancelled, r.avgLineup,
            r.waitlist, r.attendees, r.activitiesPosted, r.activitiesCompleted, r.volunteers, r.craftPosted, r.craftDone,
            r.users)
    end
    return table.concat(out, "\n")
end

function Analytics:ScheduleCollect()
    if self.pending then return end
    self.pending = true
    local function run()
        Analytics.pending = false
        CH.SafeCall("analytics", Analytics.Collect, Analytics)
    end
    if C_Timer and C_Timer.After then C_Timer.After(5, run) else run() end
end

CH:RegisterModule(MODULE, {
    version = "0.6.0",
    description = L["Officer reports: weekly participation trends"],
    initialize = function()
        CH.Store:RegisterNamespace("analytics", "guild")
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "event" or typeName == "activity" or typeName == "craftreq" then Analytics:ScheduleCollect() end
        end)
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(600, function() CH.SafeCall("analytics", Analytics.Collect, Analytics) end)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(60, function() CH.SafeCall("analytics", Analytics.Collect, Analytics) end)
        end
    end,
})
