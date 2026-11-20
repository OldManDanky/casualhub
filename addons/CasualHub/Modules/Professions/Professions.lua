-- Profession Network (design doc §4.5): publish professions, specialties and known recipes where the client
-- exposes them; find crafters; post crafting and material requests; manual entries where the API falls short.
-- Every entry carries its data source and last-updated time. Prices (when Auctionator is installed) are
-- labelled as scanned, never live.
--
-- Record types, all single-writer:
--   craft       owned by the crafter: id = "<crafter>|<skillLine>", one per profession
--   craftreq    owned by the requester: id = "<requester>#<nonce>"
--   craftoffer  owned by the helper: id = "<requestId>|<helper>"
--
-- Recipes come from the profession window (the only time the client lists them, see docs/forever-compat.md),
-- are cached per character, and travel as a compact delta-encoded string of recipe IDs. Names are resolved
-- locally: our own scans first, then the spell API.
local _, CH = ...
local L = CH.L

local Professions = { notified = {}, nameCache = nil }
CH.Professions = Professions
local MODULE = "Professions"
local C_TYPE, Q_TYPE, O_TYPE = "craft", "craftreq", "craftoffer"

-- Skill line IDs, as GetProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo report them.
Professions.LIST = {
    { id = 171, key = "alchemy" }, { id = 164, key = "blacksmithing" }, { id = 333, key = "enchanting" },
    { id = 202, key = "engineering" }, { id = 182, key = "herbalism" }, { id = 165, key = "leatherworking" },
    { id = 186, key = "mining" }, { id = 393, key = "skinning" }, { id = 197, key = "tailoring" },
    { id = 185, key = "cooking" }, { id = 129, key = "firstaid" }, { id = 356, key = "fishing" },
}
Professions.NAMES = {
    [171] = L["Alchemy"], [164] = L["Blacksmithing"], [333] = L["Enchanting"], [202] = L["Engineering"],
    [182] = L["Herbalism"], [165] = L["Leatherworking"], [186] = L["Mining"], [393] = L["Skinning"],
    [197] = L["Tailoring"], [185] = L["Cooking"], [129] = L["First Aid"], [356] = L["Fishing"],
}
Professions.KINDS = { "craft", "materials" }
Professions.STATUSES = { "open", "done", "cancelled" }
Professions.EXPIRY_DAYS = { 1, 3, 7, 14 }
Professions.TITLE_MAX, Professions.DETAILS_MAX, Professions.NOTE_MAX = 60, 200, 80
Professions.SPECIALTY_MAX, Professions.CRAFT_NOTE_MAX = 40, 140
Professions.MAX_RECIPES = 1000
Professions.LABELS = {
    craft = L["Craft"], materials = L["Materials"],
    open = L["Open"], done = L["Done"], cancelled = L["Cancelled"], expired = L["Expired"],
    offered = L["Offered"], withdrawn = L["Withdrawn"],
    scan = L["profession window"], manual = L["entered by hand"],
}

local MAX_REQUEST_LIFETIME = 15 * 86400
local KEEP_AFTER_END = 3 * 86400
local ORPHAN_OFFER_TTL = 3 * 86400
local PUBLISH_DELAY = 20  -- seconds; skill-ups while levelling a profession are batched into one update

local KIND_SET, STATUS_SET = {}, {}
for _, v in ipairs(Professions.KINDS) do KIND_SET[v] = true end
for _, v in ipairs(Professions.STATUSES) do STATUS_SET[v] = true end

local function isInt(n, lo, hi)
    return type(n) == "number" and n % 1 == 0 and n >= lo and n <= hi
end

local function cleanOptional(value, max)
    if value == nil then return true, nil end
    if type(value) ~= "string" then return false end
    local text = CH.CleanText(value, max)
    return true, text ~= "" and text or nil
end

function Professions:Label(value)
    return self.LABELS[value] or tostring(value)
end

function Professions:Name(skillLine, fallback)
    return self.NAMES[skillLine] or fallback or ("#" .. tostring(skillLine))
end

---------------------------------------------------------------------------
-- Recipe ID encoding: sorted IDs as base36, first absolute then deltas, joined by "."
---------------------------------------------------------------------------

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function toBase36(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local d = n % 36
        s = DIGITS:sub(d + 1, d + 1) .. s
        n = math.floor(n / 36)
    end
    return s
end

function Professions.EncodeRecipes(ids)
    local sorted, seen = {}, {}
    for _, id in ipairs(ids) do
        if isInt(id, 1, 2 ^ 31) and not seen[id] then
            seen[id] = true
            sorted[#sorted + 1] = id
        end
    end
    table.sort(sorted)
    local parts, prev = {}, 0
    for i, id in ipairs(sorted) do
        parts[i] = toBase36(id - prev)
        prev = id
    end
    return table.concat(parts, "."), #sorted
end

-- Returns a sorted list of IDs, or nil when malformed.
function Professions.DecodeRecipes(text)
    if text == "" then return {} end
    if type(text) ~= "string" or #text > 8000 or not text:match("^[0-9a-z.]+$") then return nil end
    local out, prev = {}, 0
    for part in (text .. "."):gmatch("([^.]*)%.") do
        local d = tonumber(part, 36)
        if not d or (d == 0 and #out > 0) then return nil end
        prev = prev + d
        if prev > 2 ^ 31 then return nil end
        out[#out + 1] = prev
        if #out > Professions.MAX_RECIPES then return nil end
    end
    return out
end

---------------------------------------------------------------------------
-- Validation (also applied to everything received from peers)
---------------------------------------------------------------------------

function Professions.ValidateCraft(r)
    if not isInt(r.skillLine, 1, 100000) or r.id ~= r.owner .. "|" .. r.skillLine then return nil, "bad id" end
    local out = { skillLine = r.skillLine }
    local name = CH.CleanText(r.name, 30)
    out.name = (name and name ~= "") and name or nil
    if r.skill ~= nil then
        if not isInt(r.skill, 0, 1000) then return nil, "bad skill" end
        out.skill = r.skill
    end
    if r.maxSkill ~= nil then
        if not isInt(r.maxSkill, 0, 1000) then return nil, "bad max skill" end
        out.maxSkill = r.maxSkill
    end
    if r.source ~= "scan" and r.source ~= "manual" then return nil, "bad source" end
    out.source = r.source
    if r.scannedAt ~= nil then
        if not isInt(r.scannedAt, 0, 2 ^ 31) or r.scannedAt > r.updatedAt then return nil, "bad scan time" end
        out.scannedAt = r.scannedAt
    end
    local ok
    ok, out.specialty = cleanOptional(r.specialty, Professions.SPECIALTY_MAX)
    if not ok then return nil, "bad specialty" end
    ok, out.note = cleanOptional(r.note, Professions.CRAFT_NOTE_MAX)
    if not ok then return nil, "bad note" end
    if r.recipes ~= nil then
        local ids = Professions.DecodeRecipes(r.recipes)
        if not ids then return nil, "bad recipes" end
        if #ids > 0 then out.recipes = r.recipes end
    end
    return out
end

function Professions.ValidateRequest(r)
    local prefix = r.owner .. "#"
    if r.id:sub(1, #prefix) ~= prefix or not r.id:sub(#prefix + 1):match("^%w+$") or #r.id - #prefix > 16 then
        return nil, "bad id"
    end
    if not KIND_SET[r.kind] then return nil, "bad kind" end
    if not STATUS_SET[r.status] then return nil, "bad status" end
    local title = CH.CleanText(r.title, Professions.TITLE_MAX)
    if not title or title == "" then return nil, "missing title" end
    local out = { kind = r.kind, status = r.status, title = title }
    if r.itemID ~= nil then
        if not isInt(r.itemID, 1, 2 ^ 31) then return nil, "bad item" end
        out.itemID = r.itemID
    end
    if r.skillLine ~= nil then
        if not isInt(r.skillLine, 1, 100000) then return nil, "bad profession" end
        out.skillLine = r.skillLine
    end
    if r.quantity ~= nil then
        if not isInt(r.quantity, 1, 1000) then return nil, "bad quantity" end
        out.quantity = r.quantity
    end
    local ok
    ok, out.details = cleanOptional(r.details, Professions.DETAILS_MAX)
    if not ok then return nil, "bad details" end
    if not isInt(r.expiresAt, 0, 2 ^ 31) or r.expiresAt > r.updatedAt + MAX_REQUEST_LIFETIME then
        return nil, "bad expiry"
    end
    out.expiresAt = r.expiresAt
    return out
end

function Professions.ValidateOffer(r)
    if type(r.requestId) ~= "string" or #r.requestId > 80 or not r.requestId:match("^.+#%w+$") then
        return nil, "bad request id"
    end
    if r.id ~= r.requestId .. "|" .. r.owner then return nil, "bad offer id" end
    if r.requestId:sub(1, #r.owner + 1) == r.owner .. "#" then return nil, "can't offer on your own request" end
    if r.state ~= "offered" and r.state ~= "withdrawn" then return nil, "bad state" end
    local out = { requestId = r.requestId, state = r.state }
    local ok
    ok, out.note = cleanOptional(r.note, Professions.NOTE_MAX)
    if not ok then return nil, "bad note" end
    return out
end

local function requestEnd(q)
    if q.status ~= "open" then return math.min(q.updatedAt, q.expiresAt) end
    return q.expiresAt
end

function Professions.PruneRequest(q, now)
    return now > requestEnd(q) + KEEP_AFTER_END
end

function Professions.PruneOffer(o, now)
    local q = CH.Sync:Get(Q_TYPE, o.requestId)
    if q then return q.deleted or Professions.PruneRequest(q, now) end
    return now - o.updatedAt > ORPHAN_OFFER_TTL
end

---------------------------------------------------------------------------
-- Recipe names
---------------------------------------------------------------------------

local function nameCache()
    return CH.Store:Bucket("recipeNames", true) or {}
end

-- Resolution order (measured on Forever, see docs/forever-compat.md):
--   1. names cached from our own profession windows or earlier lookups
--   2. C_Spell.GetSpellName: works for any recipe once the client has loaded that spell
--   3. C_TradeSkillUI.GetRecipeInfo: works outside the profession window too
--   4. otherwise ask the client to load the spell; SPELL_DATA_LOAD_RESULT fills the cache and the page
--      refreshes (event RECIPE_NAMES_LOADED).
local MAX_LOAD_REQUESTS = 4000  -- per session
local loadRequested, loadCount = {}, 0

local function usable(n)
    return type(n) == "string" and n ~= "" and not CH.Compat.IsSecret(n)
end

local function lookup(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, id)
        if ok and usable(n) then return n end
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
        if ok and type(info) == "table" and usable(info.name) then return info.name end
    end
    if GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        if ok and usable(n) then return n end
    end
end

-- Tells the page (once per burst) that more names may be available.
function Professions:AnnounceNames(delay)
    if self.namesPending then return end
    self.namesPending = true
    local function announce()
        Professions.namesPending = false
        CH.Events:Publish("RECIPE_NAMES_LOADED")
    end
    if C_Timer and C_Timer.After then C_Timer.After(delay, announce) else announce() end
end

function Professions:RequestName(id)
    if loadRequested[id] or loadCount >= MAX_LOAD_REQUESTS then return end
    if not (C_Spell and C_Spell.RequestLoadSpellData) then return end
    loadRequested[id] = true
    loadCount = loadCount + 1
    pcall(C_Spell.RequestLoadSpellData, id)
    -- Without the load event, re-render after a moment; the lookup succeeds once the data is in.
    if CH.Events.unsupported.SPELL_DATA_LOAD_RESULT then self:AnnounceNames(2) end
end

function Professions:RecipeName(id)
    local cache = nameCache()
    local name = cache[id]
    if type(name) == "string" then return name end
    name = lookup(id)
    if name then
        cache[id] = name
        return name
    end
    self:RequestName(id)
    return nil
end

-- Loads names for a guildmate's recipes ahead of any search.
function Professions:WarmNames(record)
    local cache = nameCache()
    for _, id in ipairs(self:RecipesOf(record)) do
        if cache[id] == nil then self:RecipeName(id) end
    end
end

function Professions:OnSpellLoaded(spellID, success)
    if not loadRequested[spellID] then return end
    loadRequested[spellID] = nil
    if not success then return end
    local name = lookup(spellID)
    if not name then return end
    nameCache()[spellID] = name
    self:AnnounceNames(0.5)
end

function Professions:RecipeLabel(id)
    return self:RecipeName(id) or (L["Recipe #%d"]):format(id)
end

---------------------------------------------------------------------------
-- My professions (char storage "myCrafts": [skillLine] = entry)
---------------------------------------------------------------------------

local function myBucket()
    return CH.Store:Bucket("myCrafts", true)
end

function Professions:MyEntries()
    local list = {}
    local bucket = myBucket()
    if not bucket then return list end
    for _, entry in pairs(bucket) do
        if type(entry) == "table" then list[#list + 1] = entry end
    end
    table.sort(list, function(a, b) return self:Name(a.skillLine, a.name) < self:Name(b.skillLine, b.name) end)
    return list
end

function Professions:MyEntry(skillLine)
    local bucket = myBucket()
    return bucket and bucket[skillLine]
end

function Professions:IsSharing()
    return CH.Settings:Get("professions.share") ~= false
end

local function professionInfo(index)
    if not index or not GetProfessionInfo then return nil end
    local ok, name, _, skill, maxSkill, _, _, skillLine = pcall(GetProfessionInfo, index)
    if not ok or type(skillLine) ~= "number" or CH.Compat.IsSecret(name) then return nil end
    return { skillLine = skillLine, name = type(name) == "string" and name or nil, skill = skill, maxSkill = maxSkill }
end

-- Reads skill levels from the character's profession list. With `allowRemoval` (a SKILL_LINES_CHANGED, i.e.
-- the list really changed), scanned entries for professions the character no longer has are removed; at login
-- the list can still be empty, so nothing is removed then. Manual entries are always kept.
function Professions:RefreshSkills(allowRemoval)
    local bucket = myBucket()
    if not bucket or not GetProfessions then return end
    local ok, p1, p2, arch, fish, cook, aid = pcall(GetProfessions)
    if not ok then return end
    local present, changed = {}, false
    for _, index in ipairs({ p1 or false, p2 or false, arch or false, fish or false, cook or false, aid or false }) do
        local info = index and professionInfo(index)
        if info then
            present[info.skillLine] = true
            local entry = bucket[info.skillLine]
            if not entry then
                entry = { skillLine = info.skillLine, source = "scan" }
                bucket[info.skillLine] = entry
                changed = true
            end
            if entry.source == "manual" then entry.source = "scan" changed = true end
            if entry.skill ~= info.skill or entry.maxSkill ~= info.maxSkill or entry.name ~= info.name then
                entry.skill, entry.maxSkill, entry.name = info.skill, info.maxSkill, info.name
                changed = true
            end
        end
    end
    for skillLine, entry in pairs(bucket) do
        if type(entry) ~= "table" or (allowRemoval and next(present) and entry.source == "scan" and not present[skillLine]) then
            bucket[skillLine] = nil
            changed = true
        end
    end
    if changed then self:SchedulePublish() end
end

-- Captures learned recipes from the open profession window (our own, not a linked or guild view).
function Professions:ScanTradeSkill()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetBaseProfessionInfo) then return end
    for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
        if T[fn] then
            local ok, yes = pcall(T[fn])
            if ok and yes then return end
        end
    end
    local ok, base = pcall(T.GetBaseProfessionInfo)
    if not ok or type(base) ~= "table" or type(base.professionID) ~= "number" then return end
    local ok2, ids = pcall(T.GetAllRecipeIDs)
    if not ok2 or type(ids) ~= "table" or #ids == 0 then return end
    local learned, cache = {}, nameCache()
    for _, id in ipairs(ids) do
        local okInfo, info = pcall(T.GetRecipeInfo, id)
        if okInfo and type(info) == "table" then
            if type(info.name) == "string" and not CH.Compat.IsSecret(info.name) then cache[id] = info.name end
            if info.learned then learned[#learned + 1] = id end
        end
    end
    local bucket = myBucket()
    if not bucket then return end
    local skillLine = base.professionID
    local entry = bucket[skillLine] or { skillLine = skillLine }
    bucket[skillLine] = entry
    local encoded, count = Professions.EncodeRecipes(learned)
    local changed = entry.recipes ~= encoded or entry.source ~= "scan"
    entry.source, entry.recipes, entry.count = "scan", encoded, count
    entry.name = entry.name or base.professionName
    if type(base.skillLevel) == "number" then entry.skill = base.skillLevel end
    if type(base.maxSkillLevel) == "number" then entry.maxSkill = base.maxSkillLevel end
    local now = CH.ServerTime()
    -- Refresh the timestamp at most hourly when nothing changed, so reopening the window doesn't spam updates.
    if changed or not entry.scannedAt or now - entry.scannedAt > 3600 then
        entry.scannedAt = now
        changed = true
    end
    if changed then
        CH.Log:Debug("scanned %s: %d learned of %d", tostring(base.professionName), count, #ids)
        self:SchedulePublish()
        CH.Events:Publish("PROFESSIONS_SCANNED", skillLine)
    end
end

-- Manual entry for a profession the client doesn't expose (or a character you play elsewhere).
function Professions:SaveMine(skillLine, fields)
    local bucket = myBucket()
    if not bucket then return false, L["Could not save."] end
    if not isInt(skillLine, 1, 100000) then return false end
    local entry = bucket[skillLine]
    if not entry then
        if not self.NAMES[skillLine] then return false end
        entry = { skillLine = skillLine, source = "manual" }
        bucket[skillLine] = entry
    end
    local specialty = CH.CleanText(fields.specialty or "", self.SPECIALTY_MAX)
    local note = CH.CleanText(fields.note or "", self.CRAFT_NOTE_MAX)
    entry.specialty = specialty ~= "" and specialty or nil
    entry.note = note ~= "" and note or nil
    if entry.source == "manual" then
        local skill = tonumber(fields.skill)
        entry.skill = (skill and skill >= 0 and skill <= 1000) and math.floor(skill) or nil
        entry.scannedAt = nil
    end
    self:Publish()
    CH.Events:Publish("PROFESSIONS_SCANNED", skillLine)
    return true
end

function Professions:RemoveMine(skillLine)
    local bucket = myBucket()
    local entry = bucket and bucket[skillLine]
    if not entry or entry.source ~= "manual" then return false end
    bucket[skillLine] = nil
    self:Publish()
    CH.Events:Publish("PROFESSIONS_SCANNED", skillLine)
    return true
end

local function recordFor(me, entry)
    return { id = me .. "|" .. entry.skillLine, owner = me, skillLine = entry.skillLine, name = entry.name,
        skill = entry.skill, maxSkill = entry.maxSkill, source = entry.source, scannedAt = entry.scannedAt,
        specialty = entry.specialty, note = entry.note, recipes = entry.recipes ~= "" and entry.recipes or nil }
end

local function sameCraft(a, b)
    for _, k in ipairs({ "skillLine", "name", "skill", "maxSkill", "source", "scannedAt", "specialty", "note", "recipes" }) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- Brings the shared records in line with "myCrafts" and the sharing setting.
function Professions:Publish()
    self.publishPending = false
    local me = CH.Identity:PlayerKey()
    if not me or not CH.Identity:GuildKey() or not CH.Roster.loaded then return false end
    local wanted = {}
    if self:IsSharing() then
        for _, entry in ipairs(self:MyEntries()) do wanted[me .. "|" .. entry.skillLine] = recordFor(me, entry) end
    end
    for id, record in pairs(wanted) do
        local shared = CH.Sync:Get(C_TYPE, id)
        if not (shared and not shared.deleted and sameCraft(shared, record)) then
            record.rev = shared and shared.rev or 0
            CH.Sync:PublishLocal(C_TYPE, record)
        end
    end
    for id, shared in CH.Sync:Iterate(C_TYPE) do
        if shared.owner == me and not shared.deleted and not wanted[id] then
            CH.Sync:PublishLocal(C_TYPE, { id = id, owner = me, rev = shared.rev, deleted = true })
        end
    end
    return true
end

function Professions:SchedulePublish()
    if self.publishPending then return end
    self.publishPending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(PUBLISH_DELAY, function() CH.SafeCall("publish professions", Professions.Publish, Professions) end)
    else
        self:Publish()
    end
end

---------------------------------------------------------------------------
-- Finding crafters
---------------------------------------------------------------------------

-- Shared profession records from guildmates plus our own entries (so you see yourself too).
function Professions:Crafters()
    local list, me = {}, CH.Identity:PlayerKey()
    for _, r in CH.Sync:Iterate(C_TYPE) do
        if not r.deleted and r.owner ~= me then list[#list + 1] = r end
    end
    if me then
        for _, entry in ipairs(self:MyEntries()) do
            local r = recordFor(me, entry)
            r._local = true
            r.updatedAt = entry.scannedAt
            list[#list + 1] = r
        end
    end
    return list
end

local decoded = setmetatable({}, { __mode = "k" })
function Professions:RecipesOf(record)
    if not record.recipes then return {} end
    local ids = decoded[record]
    if not ids then
        ids = Professions.DecodeRecipes(record.recipes) or {}
        decoded[record] = ids
    end
    return ids
end

-- Search: crafters whose name, profession or specialty matches, and recipes whose name matches.
-- Returns rows { record, recipeID? } sorted with online crafters first.
function Professions:Search(text, skillLine, onlineOnly, limit)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    limit = limit or 300
    local rows = {}
    local crafters = self:Crafters()
    table.sort(crafters, function(a, b)
        local oa = a._local or CH.Roster:IsOnline(a.owner)
        local ob = b._local or CH.Roster:IsOnline(b.owner)
        if oa ~= ob then return oa end
        if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) > (b.skill or 0) end
        return a.owner < b.owner
    end)
    for _, r in ipairs(crafters) do
        if (not skillLine or r.skillLine == skillLine) and (not onlineOnly or r._local or CH.Roster:IsOnline(r.owner)) then
            if text == "" then
                rows[#rows + 1] = { record = r }
            else
                local hay = (r.owner .. " " .. self:Name(r.skillLine, r.name) .. " " .. (r.specialty or "") .. " " ..
                    (r.note or "")):lower()
                if hay:find(text, 1, true) then rows[#rows + 1] = { record = r } end
                for _, id in ipairs(self:RecipesOf(r)) do
                    local name = self:RecipeName(id)
                    if name and name:lower():find(text, 1, true) then
                        rows[#rows + 1] = { record = r, recipeID = id, recipeName = name }
                    end
                    if #rows >= limit then break end
                end
            end
        end
        if #rows >= limit then break end
    end
    if text ~= "" then
        table.sort(rows, function(a, b)
            if (a.recipeName ~= nil) ~= (b.recipeName ~= nil) then return a.recipeName == nil end
            if a.recipeName and a.recipeName ~= b.recipeName then return a.recipeName < b.recipeName end
            local oa = a.record._local or CH.Roster:IsOnline(a.record.owner)
            local ob = b.record._local or CH.Roster:IsOnline(b.record.owner)
            if oa ~= ob then return oa end
            return a.record.owner < b.record.owner
        end)
    end
    return rows
end

-- Skill lines that appear in shared data, for the profession filter.
function Professions:KnownSkillLines()
    local seen, list = {}, {}
    for _, r in ipairs(self:Crafters()) do
        if not seen[r.skillLine] then
            seen[r.skillLine] = true
            list[#list + 1] = r.skillLine
        end
    end
    table.sort(list, function(a, b) return self:Name(a) < self:Name(b) end)
    return list
end

---------------------------------------------------------------------------
-- Requests and offers
---------------------------------------------------------------------------

function Professions:EffectiveStatus(q, now)
    if q.status ~= "open" then return q.status end
    if (now or CH.ServerTime()) > q.expiresAt then return "expired" end
    return "open"
end

function Professions:IsOpen(q, now)
    return self:EffectiveStatus(q, now) == "open"
end

function Professions:GetRequest(id)
    local q = CH.Sync:Get(Q_TYPE, id)
    if q and not q.deleted then return q end
end

function Professions:IsMine(q)
    return q.owner == CH.Identity:PlayerKey()
end

function Professions:Requests()
    local list, now = {}, CH.ServerTime()
    for _, q in CH.Sync:Iterate(Q_TYPE) do
        if not q.deleted then list[#list + 1] = q end
    end
    table.sort(list, function(a, b)
        local oa, ob = self:IsOpen(a, now), self:IsOpen(b, now)
        if oa ~= ob then return oa end
        if a.updatedAt ~= b.updatedAt then return a.updatedAt > b.updatedAt end
        return a.id < b.id
    end)
    return list
end

function Professions:OpenRequestCount()
    local n = 0
    for _, q in ipairs(self:Requests()) do if self:IsOpen(q) then n = n + 1 end end
    return n
end

function Professions:Offers(q)
    local out = {}
    for _, o in CH.Sync:Iterate(O_TYPE) do
        if not o.deleted and o.requestId == q.id then out[#out + 1] = o end
    end
    table.sort(out, function(a, b)
        if a.state ~= b.state then return a.state == "offered" end
        return a.updatedAt < b.updatedAt
    end)
    return out
end

function Professions:ActiveOfferCount(q)
    local n = 0
    for _, o in ipairs(self:Offers(q)) do if o.state == "offered" then n = n + 1 end end
    return n
end

function Professions:MyOffer(requestId)
    local me = CH.Identity:PlayerKey()
    local o = me and CH.Sync:Get(O_TYPE, requestId .. "|" .. me)
    if o and not o.deleted then return o end
end

-- Guildmates (from shared data) whose recipes or profession match a request, for "who could make this".
function Professions:CraftersFor(q, limit)
    local out = {}
    if q.kind ~= "craft" then return out end
    local title = q.title:lower()
    for _, r in ipairs(self:Crafters()) do
        if not r._local and r.owner ~= q.owner and (not q.skillLine or r.skillLine == q.skillLine) then
            for _, id in ipairs(self:RecipesOf(r)) do
                local name = self:RecipeName(id)
                if name and name:lower() == title then
                    out[#out + 1] = { name = r.owner, record = r, recipeID = id, online = CH.Roster:IsOnline(r.owner) }
                    break
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.name < b.name
    end)
    for i = #out, (limit or 6) + 1, -1 do out[i] = nil end
    return out
end

local function newId(owner)
    local t = CH.ServerTime()
    local s = toBase36(t)
    for _ = 1, 3 do
        local d = math.random(0, 35)
        s = s .. DIGITS:sub(d + 1, d + 1)
    end
    return owner .. "#" .. s
end

local REQUEST_FIELDS = { "kind", "title", "itemID", "skillLine", "quantity", "details", "expiresAt" }

local function validRequest(record)
    local copy = CH.Store.DeepCopy(record)
    copy.updatedAt = CH.ServerTime()
    return Professions.ValidateRequest(copy)
end

-- fields: { kind, title, itemID, skillLine, quantity, details, expiresAt }. Returns id, or nil and a reason.
function Professions:CreateRequest(fields)
    local me = CH.Identity:PlayerKey()
    if not me or not CH.Identity:GuildKey() then return nil, L["You need to be in a guild."] end
    local record = { id = newId(me), owner = me, status = "open" }
    for _, k in ipairs(REQUEST_FIELDS) do record[k] = fields[k] end
    local ok, reason = validRequest(record)
    if not ok then return nil, reason end
    if not CH.Sync:PublishLocal(Q_TYPE, record) then return nil, L["Could not save."] end
    return record.id
end

local function editOwn(id, mutate)
    local q = Professions:GetRequest(id)
    if not q or not Professions:IsMine(q) then return false, L["Only the requester can change this."] end
    local record = CH.Store.DeepCopy(q)
    mutate(record)
    local ok, reason = validRequest(record)
    if not ok then return false, reason end
    return CH.Sync:PublishLocal(Q_TYPE, record)
end

function Professions:UpdateRequest(id, fields)
    return editOwn(id, function(r)
        for _, k in ipairs(REQUEST_FIELDS) do r[k] = fields[k] end
        r.status = "open"
    end)
end

function Professions:SetRequestStatus(id, status)
    if not STATUS_SET[status] then return false end
    return editOwn(id, function(r)
        r.status = status
        if status == "open" and r.expiresAt < CH.ServerTime() then r.expiresAt = CH.ServerTime() + 86400 end
    end)
end

function Professions:DeleteRequest(id)
    local q = self:GetRequest(id)
    if not q or not self:IsMine(q) then return false end
    return CH.Sync:PublishLocal(Q_TYPE, { id = id, owner = q.owner, rev = q.rev, deleted = true })
end

function Professions:Offer(requestId, note)
    local q = self:GetRequest(requestId)
    if not q then return false, L["That request no longer exists."] end
    if self:IsMine(q) then return false, L["That's your own request."] end
    if not self:IsOpen(q) then return false, L["That request isn't open."] end
    local me = CH.Identity:PlayerKey()
    local existing = CH.Sync:Get(O_TYPE, requestId .. "|" .. me)
    return CH.Sync:PublishLocal(O_TYPE, { id = requestId .. "|" .. me, owner = me,
        rev = existing and existing.rev or 0, requestId = requestId, state = "offered", note = note })
end

function Professions:WithdrawOffer(requestId)
    local o = self:MyOffer(requestId)
    if not o then return false end
    local record = CH.Store.DeepCopy(o)
    record.state = "withdrawn"
    return CH.Sync:PublishLocal(O_TYPE, record)
end

-- Item links typed or shift-clicked into a text box: "|cff..|Hitem:1234:...|h[Name]|h|r" -> 1234, "Name".
function Professions.ParseItemText(text)
    text = text or ""
    local id = text:match("|Hitem:(%d+)")
    local name = text:match("|h%[(.-)%]|h")
    if id then return tonumber(id), name or CH.CleanText(text, Professions.TITLE_MAX) end
    return nil, CH.CleanText(text, Professions.TITLE_MAX)
end

---------------------------------------------------------------------------
-- Auctionator prices (optional). Scanned prices, not live: always shown with their age.
---------------------------------------------------------------------------

local CALLER = "Casual Hub"

function Professions:PricesAvailable()
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    return api ~= nil and type(api.GetAuctionPriceByItemID) == "function"
end

-- Returns copper, ageDays (nil when unknown).
function Professions:Price(itemID)
    if not itemID or not self:PricesAvailable() then return nil end
    local api = Auctionator.API.v1
    local ok, price = pcall(api.GetAuctionPriceByItemID, CALLER, itemID)
    if not ok or type(price) ~= "number" then return nil end
    local age
    if type(api.GetAuctionAgeByItemID) == "function" then
        local okAge, a = pcall(api.GetAuctionAgeByItemID, CALLER, itemID)
        if okAge and type(a) == "number" then age = a end
    end
    return price, age
end

function CH.FormatMoney(copper)
    copper = math.floor(copper or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = ("|cffffd700%dg|r"):format(g) end
    if s > 0 or g > 0 then parts[#parts + 1] = ("|cffc7c7cf%ds|r"):format(s) end
    parts[#parts + 1] = ("|cffeda55f%dc|r"):format(c)
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Restrained notifications: someone offers on your request.
---------------------------------------------------------------------------

function Professions:OnRecordChanged(typeName, id, record)
    if typeName == C_TYPE and not record.deleted and record.owner ~= CH.Identity:PlayerKey() then
        self:WarmNames(record)
        return
    end
    if typeName ~= O_TYPE or not CH.ready or not CH.Settings:Get("notifications.activities") then return end
    if record.deleted or record.state ~= "offered" or record.owner == CH.Identity:PlayerKey() then return end
    local q = self:GetRequest(record.requestId)
    if q and self:IsMine(q) and self:IsOpen(q) and not self.notified[id] then
        self.notified[id] = true
        CH:Print((L["%s can help with \"%s\". /chub professions"]):format(record.owner, q.title))
    end
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.5.0",
    description = L["Professions: share recipes, find crafters, post requests"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        CH.Store:RegisterNamespace("myCrafts", "char")
        CH.Store:RegisterNamespace("recipeNames", "account")
        CH.Sync:RegisterType(C_TYPE, { namespace = "crafts", validate = Professions.ValidateCraft, maxRecords = 1200 })
        CH.Sync:RegisterType(Q_TYPE, { namespace = "craftRequests", validate = Professions.ValidateRequest,
            prune = Professions.PruneRequest, maxRecords = 400 })
        CH.Sync:RegisterType(O_TYPE, { namespace = "craftOffers", validate = Professions.ValidateOffer,
            prune = Professions.PruneOffer, maxRecords = 2000 })
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(...) Professions:OnRecordChanged(...) end)

        local function scan() CH.SafeCall("scan tradeskill", Professions.ScanTradeSkill, Professions) end
        local function skills() CH.SafeCall("profession skills", Professions.RefreshSkills, Professions, true) end
        for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
            CH.Events:RegisterGameEvent(event, MODULE, scan)
        end
        CH.Events:RegisterGameEvent("SKILL_LINES_CHANGED", MODULE, skills)
        CH.Events:RegisterGameEvent("SPELL_DATA_LOAD_RESULT", MODULE, function(spellID, success)
            CH.SafeCall("recipe name", Professions.OnSpellLoaded, Professions, spellID, success)
        end)
        CH.Events:Subscribe("SETTING_CHANGED", MODULE, function(path)
            if path == "professions.share" then Professions:Publish() end
        end)
        -- Publish once the guild and roster are known.
        local function ensurePublished()
            if Professions.published then return end
            Professions:RefreshSkills()
            if Professions:Publish() then
                Professions.published = true
                CH.Events:Unsubscribe("ROSTER_UPDATED", MODULE)
            end
        end
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, ensurePublished)
        ensurePublished()
    end,
    shutdown = function()
        for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
            "SKILL_LINES_CHANGED", "SPELL_DATA_LOAD_RESULT" }) do
            CH.Events:UnregisterGameEvent(event, MODULE)
        end
    end,
})
