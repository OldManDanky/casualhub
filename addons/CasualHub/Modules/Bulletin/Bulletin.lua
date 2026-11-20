-- Announcements and onboarding (design doc §4.6) plus the guild master's policy (§3, §14):
--   notice  owned by its author (an officer, or any member if the policy allows): id = "<author>#<nonce>"
--           kind "announcement" (expires) or "rule" (pinned guild rules, no expiry)
--   policy  owned by the guild master: id = "policy|<guild master>"; rank -> role mappings, who may post
--           notices, and the optional welcome checklist. Only the current guild master's record applies.
-- Read/unread and checklist progress are local to each character and never synced.
local _, CH = ...
local L = CH.L

local Bulletin = { announced = false }
CH.Bulletin = Bulletin
local MODULE = "Bulletin"
local N_TYPE, P_TYPE = "notice", "policy"

Bulletin.KINDS = { "announcement", "rule" }
Bulletin.EXPIRY_DAYS = { 7, 14, 30, 60 }
Bulletin.TITLE_MAX, Bulletin.BODY_MAX = 60, 600
Bulletin.CHECKLIST_MAX, Bulletin.CHECKLIST_ITEM_MAX = 8, 80
Bulletin.LABELS = { announcement = L["Announcement"], rule = L["Guild rule"] }

local MAX_EXPIRY = 60 * 86400
local KEEP_AFTER_EXPIRY = 3 * 86400

local function isInt(n, lo, hi)
    return type(n) == "number" and n % 1 == 0 and n >= lo and n <= hi
end

function Bulletin:Label(v) return self.LABELS[v] or tostring(v) end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

-- Body text keeps line breaks (up to 12 lines); everything else is cleaned like other fields.
function Bulletin.CleanBody(text, max)
    if type(text) ~= "string" then return nil end
    local lines = {}
    for line in (text:gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = CH.CleanText(line, max) or ""
        if #lines >= 12 then break end
    end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    local body = table.concat(lines, "\n")
    if #body > max then body = CH.CleanText(body:sub(1, max), max) end
    return body
end

function Bulletin.ValidateNotice(r)
    local prefix = r.owner .. "#"
    if r.id:sub(1, #prefix) ~= prefix or not r.id:sub(#prefix + 1):match("^%w+$") or #r.id - #prefix > 16 then
        return nil, "bad id"
    end
    if r.kind ~= "announcement" and r.kind ~= "rule" then return nil, "bad kind" end
    local title = CH.CleanText(r.title, Bulletin.TITLE_MAX)
    if not title or title == "" then return nil, "missing title" end
    local body = Bulletin.CleanBody(r.body or "", Bulletin.BODY_MAX)
    if not body then return nil, "bad body" end
    local out = { kind = r.kind, title = title, body = body ~= "" and body or nil }
    if r.pinned ~= nil and r.pinned ~= true and r.pinned ~= false then return nil, "bad pinned" end
    out.pinned = r.pinned == true or nil
    if r.kind == "announcement" then
        if not isInt(r.expiresAt, 0, 2 ^ 31) or r.expiresAt > r.updatedAt + MAX_EXPIRY then return nil, "bad expiry" end
        out.expiresAt = r.expiresAt
    end
    -- Authority: notices from members the policy doesn't allow to post are refused. Rank data comes from
    -- the roster, so this is enforced once the roster is loaded (Sync checks membership the same way).
    if CH.Roster.loaded and not CH.Permissions:CanMember(r.owner, "postAnnouncement") then
        return nil, "not allowed to post notices"
    end
    return out
end

function Bulletin.ValidatePolicy(r)
    if r.id ~= "policy|" .. r.owner then return nil, "bad id" end
    local out = { rankRoles = {}, checklist = {} }
    if r.noticeRole ~= nil then
        if r.noticeRole ~= "officer" and r.noticeRole ~= "member" then return nil, "bad notice role" end
        out.noticeRole = r.noticeRole
    end
    if r.rankRoles ~= nil then
        if type(r.rankRoles) ~= "table" then return nil, "bad rank roles" end
        for rank, role in pairs(r.rankRoles) do
            if type(rank) ~= "string" or not rank:match("^%d%d?$") or tonumber(rank) < 1 or tonumber(rank) > 20
                or (role ~= "member" and role ~= "officer") then
                return nil, "bad rank role"
            end
            out.rankRoles[rank] = role
        end
    end
    if r.checklist ~= nil then
        if type(r.checklist) ~= "table" or #r.checklist > Bulletin.CHECKLIST_MAX then return nil, "bad checklist" end
        for i, item in ipairs(r.checklist) do
            local text = CH.CleanText(item, Bulletin.CHECKLIST_ITEM_MAX)
            if not text or text == "" then return nil, "bad checklist item" end
            out.checklist[i] = text
        end
    end
    return out
end

-- Policies from anyone other than the current guild master are dropped at prune time.
function Bulletin.PrunePolicy(p)
    if not CH.Roster.loaded then return false end
    local m = CH.Roster:Get(p.owner)
    return not m or m.rankIndex ~= 0
end

function Bulletin.PruneNotice(n, now)
    return n.kind == "announcement" and now > n.expiresAt + KEEP_AFTER_EXPIRY
end

---------------------------------------------------------------------------
-- Policy
---------------------------------------------------------------------------

function Bulletin:GuildMaster()
    for _, m in ipairs(CH.Roster:List()) do
        if m.rankIndex == 0 then return m.name end
    end
end

-- The current guild master's policy record, if any.
function Bulletin:Policy()
    local gm = self:GuildMaster()
    if not gm then return nil end
    local p = CH.Sync:Get(P_TYPE, "policy|" .. gm)
    if p and not p.deleted then return p end
end

function Bulletin:IsGuildMaster()
    if not GetGuildInfo then return false end
    local _, _, rankIndex = GetGuildInfo("player")  -- not "GetGuildInfo and GetGuildInfo(...)": that keeps one value
    return rankIndex == 0
end

-- fields: { rankRoles = { ["1"] = "officer", ... }, noticeRole, checklist = { "...", ... } }
function Bulletin:SavePolicy(fields)
    if not self:IsGuildMaster() then return false, L["Only the guild master can change the guild policy."] end
    local me = CH.Identity:PlayerKey()
    local existing = CH.Sync:Get(P_TYPE, "policy|" .. me)
    local checklist = {}
    for _, item in ipairs(fields.checklist or {}) do
        local text = CH.CleanText(item, self.CHECKLIST_ITEM_MAX)
        if text and text ~= "" and #checklist < self.CHECKLIST_MAX then checklist[#checklist + 1] = text end
    end
    local record = { id = "policy|" .. me, owner = me, rev = existing and existing.rev or 0,
        rankRoles = fields.rankRoles or {}, noticeRole = fields.noticeRole, checklist = checklist }
    local copy = CH.Store.DeepCopy(record)
    copy.updatedAt = CH.ServerTime()
    local ok, reason = Bulletin.ValidatePolicy(copy)
    if not ok then return false, reason end
    return CH.Sync:PublishLocal(P_TYPE, record)
end

-- Guild ranks from the client, 0-based like rankIndex.
function Bulletin:Ranks()
    local ranks = {}
    local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
    for i = 1, n do
        local name = GuildControlGetRankName and GuildControlGetRankName(i)
        ranks[#ranks + 1] = { index = i - 1, name = type(name) == "string" and name or ("Rank " .. i) }
    end
    return ranks
end

---------------------------------------------------------------------------
-- Notices
---------------------------------------------------------------------------

function Bulletin:IsActive(n, now)
    return n.kind == "rule" or (now or CH.ServerTime()) <= n.expiresAt
end

function Bulletin:Get(id)
    local n = CH.Sync:Get(N_TYPE, id)
    if n and not n.deleted then return n end
end

function Bulletin:IsMine(n) return n.owner == CH.Identity:PlayerKey() end

function Bulletin:CanPost()
    return CH.Identity:GuildKey() ~= nil and CH.Permissions:Can("postAnnouncement")
end

-- Live notices: pinned first, then newest. Expired announcements only with includeExpired.
function Bulletin:List(includeExpired)
    local list, now = {}, CH.ServerTime()
    for _, n in CH.Sync:Iterate(N_TYPE) do
        if not n.deleted and (includeExpired or self:IsActive(n, now)) then list[#list + 1] = n end
    end
    table.sort(list, function(a, b)
        if (a.pinned or false) ~= (b.pinned or false) then return a.pinned == true end
        if a.updatedAt ~= b.updatedAt then return a.updatedAt > b.updatedAt end
        return a.id < b.id
    end)
    return list
end

function Bulletin:Rules()
    local out = {}
    for _, n in ipairs(self:List()) do if n.kind == "rule" then out[#out + 1] = n end end
    return out
end

local function readBucket() return CH.Store:Bucket("noticeRead", true) or {} end

-- A notice counts as read at the revision you saw; an edit makes it unread again.
function Bulletin:IsRead(n)
    if self:IsMine(n) then return true end
    local seen = readBucket()[n.id]
    return type(seen) == "number" and seen >= n.rev
end

function Bulletin:MarkRead(n)
    readBucket()[n.id] = n.rev
    self:UpdateBadge()
end

function Bulletin:MarkAllRead()
    for _, n in ipairs(self:List()) do readBucket()[n.id] = n.rev end
    self:UpdateBadge()
end

function Bulletin:UnreadCount()
    local n = 0
    for _, notice in ipairs(self:List()) do if not self:IsRead(notice) then n = n + 1 end end
    return n
end

function Bulletin:UpdateBadge()
    if CH.UI and CH.UI.SetNavCount then CH.UI:SetNavCount("bulletin", self:UnreadCount()) end
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function newId(owner)
    local t, s = CH.ServerTime(), ""
    repeat
        local d = t % 36
        s = DIGITS:sub(d + 1, d + 1) .. s
        t = math.floor(t / 36)
    until t == 0
    for _ = 1, 3 do
        local d = math.random(0, 35)
        s = s .. DIGITS:sub(d + 1, d + 1)
    end
    return owner .. "#" .. s
end

local FIELDS = { "kind", "title", "body", "pinned", "expiresAt" }

local function valid(record)
    local copy = CH.Store.DeepCopy(record)
    copy.updatedAt = CH.ServerTime()
    return Bulletin.ValidateNotice(copy)
end

-- fields: { kind, title, body, pinned, expiresAt (announcements) }. Returns id, or nil and a reason.
function Bulletin:Post(fields)
    if not self:CanPost() then return nil, L["You can't post notices (guild policy)."] end
    local me = CH.Identity:PlayerKey()
    local record = { id = newId(me), owner = me }
    for _, k in ipairs(FIELDS) do record[k] = fields[k] end
    if record.kind == "rule" then record.expiresAt = nil end
    if record.pinned == false then record.pinned = nil end
    local ok, reason = valid(record)
    if not ok then return nil, reason end
    if not CH.Sync:PublishLocal(N_TYPE, record) then return nil, L["Could not save."] end
    return record.id
end

local function editOwn(id, mutate)
    local n = Bulletin:Get(id)
    if not n or not Bulletin:IsMine(n) then return false, L["Only the author can change this."] end
    local record = CH.Store.DeepCopy(n)
    mutate(record)
    if record.kind == "rule" then record.expiresAt = nil end
    if record.pinned == false then record.pinned = nil end
    local ok, reason = valid(record)
    if not ok then return false, reason end
    return CH.Sync:PublishLocal(N_TYPE, record)
end

function Bulletin:Update(id, fields)
    return editOwn(id, function(r) for _, k in ipairs(FIELDS) do r[k] = fields[k] end end)
end

function Bulletin:SetPinned(id, pinned)
    return editOwn(id, function(r) r.pinned = pinned and true or nil end)
end

function Bulletin:Delete(id)
    local n = self:Get(id)
    if not n or not self:IsMine(n) then return false end
    return CH.Sync:PublishLocal(N_TYPE, { id = id, owner = n.owner, rev = n.rev, deleted = true })
end

---------------------------------------------------------------------------
-- Welcome checklist (progress is per character)
---------------------------------------------------------------------------

local function checklistBucket() return CH.Store:Bucket("welcomeChecklist", true) or {} end

function Bulletin:Checklist()
    local p = self:Policy()
    return p and p.checklist or {}
end

-- Items are matched by text, so reordering the list keeps progress; rewording an item resets it.
function Bulletin:IsChecked(item) return checklistBucket()[item] == true end

function Bulletin:SetChecked(item, checked)
    checklistBucket()[item] = checked and true or nil
end

function Bulletin:ChecklistProgress()
    local items, done = self:Checklist(), 0
    for _, item in ipairs(items) do if self:IsChecked(item) then done = done + 1 end end
    return done, #items
end

---------------------------------------------------------------------------
-- Restrained notifications
---------------------------------------------------------------------------

-- Once per session, shortly after login: how many notices are new.
function Bulletin:AnnounceUnread()
    if self.announced or not CH.Settings:Get("notifications.notices") then return end
    local unread = self:UnreadCount()
    self.announced = true
    if unread > 0 then CH:Print((L["%d new guild notice(s). /chub bulletin"]):format(unread)) end
end

function Bulletin:OnRecordChanged(typeName, _, record)
    if typeName ~= N_TYPE and typeName ~= P_TYPE then return end
    self:UpdateBadge()
    -- A pinned notice posted while you're online gets one chat line.
    if typeName == N_TYPE and CH.ready and self.announced and not record.deleted and record.pinned
        and not self:IsMine(record) and not self:IsRead(record) and CH.Settings:Get("notifications.notices") then
        CH:Print((L["New pinned notice from %s: \"%s\". /chub bulletin"]):format(record.owner, record.title))
    end
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.6.0",
    description = L["Bulletin: guild notices, rules and welcome checklist"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        CH.Store:RegisterNamespace("noticeRead", "char")
        CH.Store:RegisterNamespace("welcomeChecklist", "char")
        CH.Sync:RegisterType(N_TYPE, { namespace = "notices", validate = Bulletin.ValidateNotice,
            prune = Bulletin.PruneNotice, maxRecords = 200 })
        CH.Sync:RegisterType(P_TYPE, { namespace = "policy", validate = Bulletin.ValidatePolicy,
            prune = Bulletin.PrunePolicy, maxRecords = 20 })
        CH.Permissions:SetPolicyProvider(function() return Bulletin:Policy() end)
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(...) Bulletin:OnRecordChanged(...) end)
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, function() Bulletin:UpdateBadge() end)
        -- Give sync a moment to bring in notices posted while we were offline.
        if C_Timer and C_Timer.After then
            C_Timer.After(45, function() CH.SafeCall("notice summary", Bulletin.AnnounceUnread, Bulletin) end)
        end
    end,
})
