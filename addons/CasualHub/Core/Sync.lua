-- Peer-to-peer, eventually consistent record sync (design doc §7-8). Best-effort: when every peer holding a
-- record is offline, nobody can supply it, and cached copies may be stale.
--
-- Records are single-writer: { id, owner, rev, updatedAt, deleted?, ...fields }. Only the owner edits a record,
-- bumping rev; everyone else keeps the highest rev seen and re-serves it. Keys starting with "_" are local
-- metadata (never sent).
--
-- Protocol (all bodies small tables):
--   HELLO (GUILD)    { d = { [type] = { h = hash, n = count } } }    sent after login and periodically
--   SUM   (WHISPER)  { y = type, s = { [id] = rev }, pg, pgs }       reply to a HELLO whose digest differs
--   REQ   (WHISPER)  { y = type, ids = { id, ... } }                 ask a peer for records it has newer
--   REC   (either)   { y = type, r = record }                        a record (or tombstone)
--   HI    (WHISPER)  {}                                             presence reply to a HELLO, once per peer per
--                                                                   session, so users see each other right away
--
-- Ownership can't be proven from addon messages (a modified client can forge them). Mitigations: strict
-- validation, owners must be current guild members, and an owner who sees a forged newer copy of their own
-- record republishes theirs with a higher revision.
local _, CH = ...

local Sync = { types = {}, lastSummaryTo = {}, requested = {}, greeted = {}, stats = { accepted = 0, rejected = 0, stale = 0, selfHealed = 0 } }
CH.Sync = Sync

local HELLO_DELAY_MIN, HELLO_DELAY_MAX = 6, 14
local HELLO_INTERVAL = 15 * 60
local SUMMARY_COOLDOWN = 60
local SUMMARY_PAGE = 120
local REQUEST_TIMEOUT = 30
local MAX_SERVE = 60
local MAX_REV = 2 ^ 31
local TOMBSTONE_TTL = 30 * 86400

local Stats = Sync.stats

-- spec = { namespace = "profiles", validate = function(record) return cleanRecord | nil, reason end,
--          maxRecords = 500, prune = function(record, now) return true to delete end (optional) }
function Sync:RegisterType(name, spec)
    assert(type(spec.namespace) == "string" and type(spec.validate) == "function", "invalid sync type")
    CH.Store:RegisterNamespace(spec.namespace, "guild")
    spec.maxRecords = spec.maxRecords or 500
    self.types[name] = spec
end

function Sync:Get(typeName, id)
    local spec = self.types[typeName]
    return spec and CH.Store:Get(spec.namespace, id)
end

function Sync:Iterate(typeName)
    return CH.Store:Iterate(self.types[typeName].namespace)
end

local function wireCopy(record)
    local out = {}
    for k, v in pairs(record) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" then out[k] = v end
    end
    return out
end

-- Order-independent digest of { id -> rev } so peers can tell cheaply whether they differ.
function Sync:Digest(typeName)
    local lines = {}
    for id, record in self:Iterate(typeName) do lines[#lines + 1] = id .. "=" .. tostring(record.rev) end
    table.sort(lines)
    local h = 5381
    for _, line in ipairs(lines) do
        for i = 1, #line do h = (h * 33 + line:byte(i)) % 4294967296 end
        h = (h * 33 + 10) % 4294967296
    end
    return { h = h, n = #lines }
end

---------------------------------------------------------------------------
-- Validation and acceptance
---------------------------------------------------------------------------

-- Envelope checks shared by every type, then the type's own validator (which returns a cleaned copy).
function Sync:Validate(typeName, record)
    local spec = self.types[typeName]
    if not spec then return nil, "unknown type" end
    if type(record) ~= "table" then return nil, "not a table" end
    local owner = CH.Identity:Normalize(record.owner)
    if not owner or owner ~= record.owner then return nil, "bad owner" end
    if type(record.id) ~= "string" or #record.id == 0 or #record.id > 64 then return nil, "bad id" end
    if type(record.rev) ~= "number" or record.rev < 1 or record.rev > MAX_REV or record.rev % 1 ~= 0 then
        return nil, "bad rev"
    end
    if type(record.updatedAt) ~= "number" then return nil, "bad timestamp" end
    if CH.Roster.loaded and not CH.Roster:IsMember(owner) then return nil, "owner not in guild" end
    local base = { id = record.id, owner = owner, rev = record.rev, updatedAt = record.updatedAt }
    if record.deleted == true then
        base.deleted = true
        return base
    end
    local cleaned, reason = spec.validate(record)
    if not cleaned then return nil, reason or "invalid" end
    for k, v in pairs(base) do cleaned[k] = v end
    return cleaned
end

local function sameContent(a, b)
    return CH.Serializer.Encode(wireCopy(a)) == CH.Serializer.Encode(wireCopy(b))
end

-- Applies a record received from `sender`. Returns true when stored.
function Sync:Accept(typeName, record, sender)
    local clean, reason = self:Validate(typeName, record)
    if not clean then
        Stats.rejected = Stats.rejected + 1
        CH.Log:Debug("rejected %s record from %s: %s", typeName, tostring(sender), tostring(reason))
        return false, reason
    end
    local spec = self.types[typeName]
    -- Refuse records we would prune right away; otherwise peers that haven't pruned yet resurrect them.
    local now = CH.ServerTime()
    if (clean.deleted and now - clean.updatedAt > TOMBSTONE_TTL) or
        (spec.prune and not clean.deleted and spec.prune(clean, now)) then
        Stats.rejected = Stats.rejected + 1
        return false, "expired"
    end
    local existing = CH.Store:Get(spec.namespace, clean.id)
    if existing and existing.rev >= clean.rev then
        Stats.stale = Stats.stale + 1
        return false, "stale"
    end
    if clean.owner == CH.Identity:PlayerKey() then
        -- Someone holds a newer revision of our own record than we do (another of our installs, or a forgery).
        -- Our local copy is authoritative: republish it above that revision.
        if existing and not sameContent(existing, clean) then
            Stats.selfHealed = Stats.selfHealed + 1
            local mine = wireCopy(existing)
            mine.rev = clean.rev
            self:PublishLocal(typeName, mine)
            return false, "own record"
        end
    end
    if not existing then
        local count = 0
        for _ in self:Iterate(typeName) do count = count + 1 end
        if count >= spec.maxRecords then return false, "store full" end
    end
    clean._receivedAt = time()
    clean._via = sender
    if not CH.Store:Put(spec.namespace, clean.id, clean) then return false, "store unavailable" end
    Stats.accepted = Stats.accepted + 1
    self.requested[typeName .. "\n" .. clean.id] = nil
    CH.Events:Publish("SYNC_RECORD_CHANGED", typeName, clean.id, clean)
    return true
end

-- Owner-side write: bumps the revision past anything seen, stores locally, and broadcasts to the guild.
function Sync:PublishLocal(typeName, record)
    local spec = self.types[typeName]
    local me = CH.Identity:PlayerKey()
    if not spec or not me then return false end
    local existing = CH.Store:Get(spec.namespace, record.id)
    local rev = math.max(record.rev or 0, existing and existing.rev or 0) + 1
    local out = wireCopy(record)
    out.owner, out.rev, out.updatedAt = me, rev, CH.ServerTime()
    local clean, reason = self:Validate(typeName, out)
    if not clean then
        CH.Log:Error("own %s record invalid: %s", typeName, tostring(reason))
        return false
    end
    clean._receivedAt = time()
    if not CH.Store:Put(spec.namespace, clean.id, clean) then return false end
    CH.Events:Publish("SYNC_RECORD_CHANGED", typeName, clean.id, clean)
    CH.Comm:Send("REC", { y = typeName, r = wireCopy(clean) }, "GUILD")
    return true
end

---------------------------------------------------------------------------
-- Protocol handlers
---------------------------------------------------------------------------

function Sync:SendHello()
    if not CH.Identity:GuildKey() or not CH.Roster.loaded then return false end
    local digests = {}
    for name in pairs(self.types) do digests[name] = self:Digest(name) end
    self.lastHello = time()
    return CH.Comm:Send("HELLO", { d = digests }, "GUILD")
end

function Sync:SendSummary(typeName, target)
    local ids = {}
    for id, record in self:Iterate(typeName) do ids[#ids + 1] = { id, record.rev } end
    table.sort(ids, function(a, b) return a[1] < b[1] end)
    local pages = math.max(1, math.ceil(#ids / SUMMARY_PAGE))
    for page = 1, pages do
        local s = {}
        for i = (page - 1) * SUMMARY_PAGE + 1, math.min(#ids, page * SUMMARY_PAGE) do s[ids[i][1]] = ids[i][2] end
        CH.Comm:Send("SUM", { y = typeName, s = s, pg = page, pgs = pages }, "WHISPER", target)
    end
end

function Sync:OnHello(sender, body)
    if type(body) ~= "table" or type(body.d) ~= "table" then return end
    if not self.greeted[sender] then
        -- Without this, a peer whose data already matches never answers, and neither side knows the other is here.
        self.greeted[sender] = true
        C_Timer.After(math.random() * 2, function() CH.Comm:Send("HI", {}, "WHISPER", sender) end)
    end
    local last = self.lastSummaryTo[sender]
    if last and time() - last < SUMMARY_COOLDOWN then return end
    local differing = {}
    for name in pairs(self.types) do
        -- A peer that doesn't announce a type runs a version without it: skip rather than send it records.
        local theirs, mine = body.d[name], self:Digest(name)
        if type(theirs) == "table" and (theirs.h ~= mine.h or theirs.n ~= mine.n) then
            differing[#differing + 1] = name
        end
    end
    if #differing == 0 then return end
    self.lastSummaryTo[sender] = time()
    -- Spread replies so a guild's worth of peers doesn't answer in the same instant.
    C_Timer.After(1 + math.random() * 3, function()
        for _, name in ipairs(differing) do Sync:SendSummary(name, sender) end
    end)
end

function Sync:SendRecord(typeName, id, target)
    local record = self:Get(typeName, id)
    if not record then return false end
    return CH.Comm:Send("REC", { y = typeName, r = wireCopy(record) }, "WHISPER", target)
end

function Sync:OnSummary(sender, body)
    if type(body) ~= "table" or not self.types[body.y] or type(body.s) ~= "table" then return end
    local typeName = body.y
    local want, push, t = {}, {}, time()
    for id, rev in pairs(body.s) do
        if type(id) == "string" and type(rev) == "number" then
            local mine = self:Get(typeName, id)
            local key = typeName .. "\n" .. id
            local pending = self.requested[key]
            if (not mine or mine.rev < rev) and (not pending or t - pending > REQUEST_TIMEOUT) and #want < MAX_SERVE then
                want[#want + 1] = id
                self.requested[key] = t
            elseif mine and mine.rev > rev then
                push[#push + 1] = id
            end
        end
    end
    -- Records the peer lacks entirely. Only on the last page, since earlier pages list a subset of their ids.
    if (body.pg or 1) >= (body.pgs or 1) then
        local listed = body.s
        if (body.pgs or 1) > 1 then
            listed = self.partialSummaries and self.partialSummaries[sender .. "\n" .. typeName] or {}
            for id, rev in pairs(body.s) do listed[id] = rev end
        end
        for id in self:Iterate(typeName) do
            if listed[id] == nil then push[#push + 1] = id end
        end
        if self.partialSummaries then self.partialSummaries[sender .. "\n" .. typeName] = nil end
    else
        self.partialSummaries = self.partialSummaries or {}
        local key = sender .. "\n" .. typeName
        local acc = self.partialSummaries[key] or {}
        for id, rev in pairs(body.s) do acc[id] = rev end
        self.partialSummaries[key] = acc
    end
    if #want > 0 then CH.Comm:Send("REQ", { y = typeName, ids = want }, "WHISPER", sender) end
    for i = 1, math.min(#push, MAX_SERVE) do self:SendRecord(typeName, push[i], sender) end
end

function Sync:OnRequest(sender, body)
    if type(body) ~= "table" or not self.types[body.y] or type(body.ids) ~= "table" then return end
    local served = 0
    for _, id in ipairs(body.ids) do
        if served >= MAX_SERVE then break end
        if type(id) == "string" and self:SendRecord(body.y, id, sender) then served = served + 1 end
    end
end

function Sync:OnRecord(sender, body)
    if type(body) ~= "table" or not self.types[body.y] then return end
    self:Accept(body.y, body.r, sender)
end

---------------------------------------------------------------------------
-- Maintenance
---------------------------------------------------------------------------

-- Drops old tombstones and records whose owner has left the guild (only once the roster is fresh).
function Sync:Prune()
    if not CH.Roster.loaded or CH.Store.readOnly then return end
    local now = CH.ServerTime()
    for name, spec in pairs(self.types) do
        local doomed = {}
        for id, record in self:Iterate(name) do
            if record.deleted and now - (record.updatedAt or 0) > TOMBSTONE_TTL then
                doomed[#doomed + 1] = id
            elseif not CH.Roster:IsMember(record.owner) then
                doomed[#doomed + 1] = id
            elseif spec.prune and not record.deleted and spec.prune(record, now) then
                doomed[#doomed + 1] = id
            end
        end
        for _, id in ipairs(doomed) do CH.Store:Delete(spec.namespace, id) end
        if #doomed > 0 then CH.Log:Info("pruned %d %s record(s)", #doomed, name) end
    end
end

function Sync:Init()
    local Comm = CH.Comm
    Comm:RegisterHandler("HELLO", function(...) Sync:OnHello(...) end)
    Comm:RegisterHandler("SUM", function(...) Sync:OnSummary(...) end)
    Comm:RegisterHandler("REQ", function(...) Sync:OnRequest(...) end)
    Comm:RegisterHandler("REC", function(...) Sync:OnRecord(...) end)
    Comm:RegisterHandler("HI", function() end)  -- presence is recorded by the transport for every message

    -- First HELLO once the roster and guild are known; retry a few times if they aren't yet.
    local attempts = 0
    local function hello()
        attempts = attempts + 1
        if Sync:SendHello() then
            Sync:Prune()
        elseif attempts < 6 then
            C_Timer.After(10, hello)
        end
    end
    C_Timer.After(HELLO_DELAY_MIN + math.random() * (HELLO_DELAY_MAX - HELLO_DELAY_MIN), hello)
    if C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(HELLO_INTERVAL, function()
            Sync:Prune()
            Sync:SendHello()
        end)
    end
end
