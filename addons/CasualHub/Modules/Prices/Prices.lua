-- Prices: look up auction prices anywhere, ask the guild, and share material prices.
--
-- Sources, best first:
--   own      your Auctionator scan (read from Auctionator's database; never written)
--   guild    answers to price questions heard on the guild channel (kept locally about a week), and
--            material price packs that scanners publish (sync type "pricepack")
-- Every price carries the Auctionator day it was scanned, so its age is always shown.
--
-- Price questions (not synced records, just two message types on the guild channel):
--   PQ { n = nonce, k = key }  or  { n = nonce, t = text }     "who has a price for this?"
--   PA { n = nonce, r = { { k = key, p = copper, d = day, m = baseName? }, ... } }
-- Answerers wait a moment and stay quiet if someone already answered with a scan at least as fresh, so a
-- question usually gets one to three answers. Everyone online hears the answers and caches them.
--
-- Keys follow Auctionator: "12360" for an item, "gr:14902:of Spirit" for a random-enchant variant.
local _, CH = ...
local L = CH.L

local Prices = { answers = {}, heard = {}, lastQuestionFrom = {}, packCache = {} }
CH.Prices = Prices
local MODULE = "Prices"
local P_TYPE = "pricepack"

Prices.MAX_ANSWERS = 8
Prices.ASK_COOLDOWN = 3          -- seconds between your own questions
Prices.CACHE_DAYS = 8            -- guild answers older than this (by scan day) are dropped
Prices.CACHE_MAX = 3000
Prices.PACK_ITEMS = 300          -- items per price pack record (keeps one record under ~20 chunks)
Prices.PACK_MAX_PAGES = 6
Prices.PACK_FRESH_DAYS = 2       -- only prices scanned in the last two days go into packs
Prices.PACK_TTL = 4 * 86400      -- packs older than this are pruned
Prices.PACK_MIN_INTERVAL = 2 * 3600
Prices.NAME_BATCH = 40           -- item names requested per second while building the index
-- Item classes shared in packs: consumables (0), reagents (5), trade goods (7).
Prices.MATERIAL_CLASSES = { [0] = true, [5] = true, [7] = true }

local CALLER = "Casual Hub"
local DAY0 = time({ year = 2020, month = 1, day = 1, hour = 0 })  -- Auctionator's day 0

function Prices.Today()
    return math.floor((time() - DAY0) / 86400)
end

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------

-- Returns itemID, suffix (nil for plain items) or nil for invalid keys.
function Prices.ParseKey(key)
    if type(key) ~= "string" or #key > 64 then return nil end
    local id = key:match("^(%d+)$")
    if id and #id <= 9 then return tonumber(id) end
    local gid, suffix = key:match("^gr:(%d+):([%a%s'%-]+)$")
    if gid and #gid <= 9 then return tonumber(gid), suffix end
end

---------------------------------------------------------------------------
-- Your Auctionator data
---------------------------------------------------------------------------

local function database()
    local A = Auctionator
    local D = type(A) == "table" and type(A.Database) == "table" and A.Database
    if D and type(D.db) == "table" and type(D.GetPrice) == "function" then return D end
end

local function api()
    local A = Auctionator
    return type(A) == "table" and type(A.API) == "table" and type(A.API.v1) == "table" and A.API.v1 or nil
end

function Prices:HasAuctionator()
    return database() ~= nil or (api() ~= nil and type(api().GetAuctionPriceByItemID) == "function")
end

-- Your scanned price: copper, scan day. Nil when you have none.
function Prices:Own(key)
    local D = database()
    if D then
        local ok, price = pcall(D.GetPrice, D, key)
        if not ok or type(price) ~= "number" then return nil end
        local okAge, age = pcall(D.GetPriceAge, D, key)
        return price, self.Today() - ((okAge and type(age) == "number") and age or 0)
    end
    local id, suffix = self.ParseKey(key)
    local v1 = api()
    if not id or suffix or not v1 then return nil end
    local ok, price = pcall(v1.GetAuctionPriceByItemID, CALLER, id)
    if not ok or type(price) ~= "number" then return nil end
    local age = 0
    if type(v1.GetAuctionAgeByItemID) == "function" then
        local okAge, a = pcall(v1.GetAuctionAgeByItemID, CALLER, id)
        if okAge and type(a) == "number" then age = a end
    end
    return price, self.Today() - age
end

-- Daily low/high from your scans, newest first: { { day, low, high } }.
function Prices:History(key, days)
    local D = database()
    if not D or type(D.GetPriceHistory) ~= "function" then return {} end
    local ok, rows = pcall(D.GetPriceHistory, D, key)
    if not ok or type(rows) ~= "table" then return {} end
    local out = {}
    for _, r in ipairs(rows) do
        local day = tonumber(r.rawDay)
        if day and type(r.maxSeen) == "number" then
            out[#out + 1] = { day = day, low = r.minSeen or r.maxSeen, high = r.maxSeen }
            if #out >= (days or 30) then break end
        end
    end
    return out
end

function Prices:Mean(key, days)
    local D = database()
    if not D or type(D.GetMeanPrice) ~= "function" then return nil end
    local ok, v = pcall(D.GetMeanPrice, D, key, days)
    return ok and type(v) == "number" and v > 0 and math.floor(v) or nil
end

function Prices:VendorPrice(itemID)
    local A = Auctionator
    if type(A) == "table" and type(A.API) == "table" and type(A.API.v1) == "table"
        and type(A.API.v1.GetVendorPriceByItemID) == "function" then
        local ok, v = pcall(A.API.v1.GetVendorPriceByItemID, CALLER, itemID)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    if C_Item and C_Item.GetItemInfo then
        local ok, _, _, _, _, _, _, _, _, _, _, sell = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(sell) == "number" and sell > 0 then return sell end
    end
end

-- Which items your Auctionator knows: variants[itemID] = { plain = true?, suffix, suffix, ... }.
-- Built once per session (about 35 ms for 40,000 entries on Forever).
function Prices:Variants()
    if self.variants then return self.variants end
    local D = database()
    if not D then return nil end
    local variants, count = {}, 0
    for k in pairs(D.db) do
        local id, suffix = self.ParseKey(tostring(k))
        if id then
            local v = variants[id]
            if not v then
                v = {}
                variants[id] = v
                count = count + 1
            end
            if suffix then v[#v + 1] = suffix else v.plain = true end
        end
    end
    self.variants, self.itemCount = variants, count
    return variants
end

---------------------------------------------------------------------------
-- Item names: the client can't look items up by name, so we keep our own index (id -> name), filled from
-- the client's item cache, from loading the items your Auctionator knows, and from guild answers.
---------------------------------------------------------------------------

local function nameIndex()
    return CH.Store:Bucket("itemNames", true) or {}
end

local function usable(n) return type(n) == "string" and n ~= "" and not CH.Compat.IsSecret(n) end

function Prices:Name(itemID)
    if not itemID then return nil end
    local index = nameIndex()
    local n = index[itemID]
    if n then return n end
    if C_Item and C_Item.GetItemNameByID then
        local ok, name = pcall(C_Item.GetItemNameByID, itemID)
        if ok and usable(name) then
            index[itemID] = name
            return name
        end
    end
end

function Prices:KeyName(key)
    local id, suffix = self.ParseKey(key)
    local base = id and self:Name(id)
    if not base then return nil end
    return suffix and (base .. " " .. suffix) or base
end

-- Queues name loads for every item your Auctionator knows that isn't indexed yet.
function Prices:BuildIndex()
    local variants = self:Variants()
    if not variants then return end
    local missing, known = {}, 0
    for id in pairs(variants) do
        if self:Name(id) then known = known + 1 else missing[#missing + 1] = id end
    end
    self.indexKnown, self.indexMissing = known, missing
    if #missing == 0 or not (C_Item and C_Item.RequestLoadItemDataByID and C_Timer.NewTicker) then return end
    self.loading = self.loading or {}
    if self.indexTicker then return end
    self.indexTicker = C_Timer.NewTicker(1, function()
        local list = Prices.indexMissing
        local sent = 0
        while #list > 0 and sent < Prices.NAME_BATCH do
            local id = table.remove(list)
            if not nameIndex()[id] then
                Prices.loading[id] = true
                pcall(C_Item.RequestLoadItemDataByID, id)
                sent = sent + 1
            end
        end
        if #list == 0 then
            Prices.indexTicker:Cancel()
            Prices.indexTicker = nil
            -- Names that never arrive (removed items) are simply skipped.
            C_Timer.After(15, function() Prices.loading = {}; CH.Events:Publish("PRICES_CHANGED") end)
        end
    end)
end

function Prices:OnItemLoaded(itemID, success)
    if not self.loading or not self.loading[itemID] then return end
    self.loading[itemID] = nil
    if success and self:Name(itemID) then
        self.indexKnown = (self.indexKnown or 0) + 1
        CH.Debounce(MODULE .. "-names", 2, function() CH.Events:Publish("PRICES_CHANGED") end)
    end
end

-- "1,234 of 8,920 item names" while the index is being built, nil once complete.
function Prices:IndexProgress()
    local total = self.itemCount
    local missing = self.indexMissing and #self.indexMissing or 0
    local loading = 0
    for _ in pairs(self.loading or {}) do loading = loading + 1 end
    if not total or (missing == 0 and loading == 0) then return nil end
    return math.min(self.indexKnown or 0, total), total
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

-- Matches item names (and "Name of the Suffix" variants) against `text`. Returns
-- { { key, id, name } }, exact and prefix matches first. ownOnly: only keys your Auctionator has.
function Prices:Search(text, limit, ownOnly)
    text = CH.CleanText(text or "", 60)
    if not text or #text < 2 then return {} end
    text = text:lower()
    limit = limit or 60
    if not self.indexKnown and self:Variants() then self:BuildIndex() end
    local variants = self:Variants() or {}
    local cache = ownOnly and {} or (CH.Store:Bucket("priceCache", false) or {})
    local results, seen = {}, {}
    local function add(key, id, name)
        if seen[key] then return end
        seen[key] = true
        local lname = name:lower()
        local rank = lname == text and 0 or (lname:sub(1, #text) == text and 1 or 2)
        results[#results + 1] = { key = key, id = id, name = name, rank = rank }
    end
    -- "shield of the owl" -> base "shield", suffix "of the owl". Suffixes repeat across items (about a hundred
    -- distinct ones), so each is matched once rather than once per item.
    local basePart, suffixPart = text:match("^(.-)%s*(of .+)$")
    local suffixHit = {}
    local function suffixMatches(suffix)
        local hit = suffixHit[suffix]
        if hit == nil then
            hit = suffix:lower():find(suffixPart, 1, true) ~= nil
            suffixHit[suffix] = hit
        end
        return hit
    end
    local lowerNames = self.lowerNames or {}
    self.lowerNames = lowerNames
    local cap = limit * 4
    for id, name in pairs(nameIndex()) do
        if #results >= cap then break end
        local lname = lowerNames[id]
        if not lname then
            lname = name:lower()
            lowerNames[id] = lname
        end
        local v = variants[id]
        local baseHit = lname:find(text, 1, true) ~= nil
        if v then
            if baseHit then
                if v.plain or #v == 0 then add(tostring(id), id, name) end
                for _, suffix in ipairs(v) do add("gr:" .. id .. ":" .. suffix, id, name .. " " .. suffix) end
            elseif suffixPart and #v > 0 and (basePart == "" or lname:find(basePart, 1, true)) then
                for _, suffix in ipairs(v) do
                    if suffixMatches(suffix) then add("gr:" .. id .. ":" .. suffix, id, name .. " " .. suffix) end
                end
            end
        elseif baseHit and not ownOnly then
            add(tostring(id), id, name)
        end
    end
    -- Variants only known from guild answers.
    for key in pairs(cache) do
        if not seen[key] then
            local name = self:KeyName(key)
            if name and name:lower():find(text, 1, true) then add(key, (self.ParseKey(key)), name) end
        end
    end
    table.sort(results, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    for i = #results, limit + 1, -1 do results[i] = nil end
    return results
end

---------------------------------------------------------------------------
-- Guild prices
---------------------------------------------------------------------------

local function cache() return CH.Store:Bucket("priceCache", true) or {} end

local function decodePack(record)
    local cached = Prices.packCache[record.id]
    if cached and cached.rev == record.rev then return cached.map end
    local map = {}
    for id, price, off in (record.data or ""):gmatch("(%w+):(%w+):(%w+);") do
        map[tonumber(id, 36)] = { tonumber(price, 36), record.day - tonumber(off, 36) }
    end
    Prices.packCache[record.id] = { rev = record.rev, map = map }
    return map
end

-- Freshest guild price for a key: copper, day, who scanned it. Ignores your own packs.
function Prices:Guild(key)
    local best = cache()[key]
    local p, d, by
    if best then p, d, by = best.p, best.d, best.by end
    local id, suffix = self.ParseKey(key)
    if id and not suffix then
        local me = CH.Identity:PlayerKey()
        for _, r in CH.Sync:Iterate(P_TYPE) do
            if not r.deleted and r.owner ~= me then
                local e = decodePack(r)[id]
                if e and (not d or e[2] > d) then p, d, by = e[1], e[2], r.owner end
            end
        end
    end
    return p, d, by
end

-- Best price for a key: your own scan unless a guild price is from a newer day.
-- Returns copper, day, by (nil when it's yours).
function Prices:Best(key)
    local p, d = self:Own(key)
    local gp, gd, gby = self:Guild(key)
    if gp and (not p or gd > d) then return gp, gd, gby end
    return p, d
end

function Prices:HasGuildPrices()
    if next(cache()) then return true end
    for _, r in CH.Sync:Iterate(P_TYPE) do if not r.deleted then return true end end
    return false
end

-- "today", "2 days ago"
function Prices.AgeText(day)
    local age = math.max(0, Prices.Today() - (day or Prices.Today()))
    if age == 0 then return L["today"] end
    return (age == 1 and L["%d day ago"] or L["%d days ago"]):format(age)
end

-- Remembers a guild price; keeps the newest scan per key.
function Prices:Remember(key, price, day, by, baseName)
    local id = self.ParseKey(key)
    if not id then return end
    local c = cache()
    local old = c[key]
    if not old or old.d < day then
        c[key] = { p = price, d = day, by = by, at = time() }
    end
    if baseName and not nameIndex()[id] then nameIndex()[id] = baseName end
end

function Prices:PruneCache()
    local c = CH.Store:Bucket("priceCache", false)
    if not c then return end
    local today, keys = self.Today(), {}
    for key, e in pairs(c) do
        if type(e) ~= "table" or not e.d or today - e.d > self.CACHE_DAYS then c[key] = nil else keys[#keys + 1] = key end
    end
    if #keys > self.CACHE_MAX then
        table.sort(keys, function(a, b) return c[a].d < c[b].d end)
        for i = 1, #keys - self.CACHE_MAX do c[keys[i]] = nil end
    end
end

---------------------------------------------------------------------------
-- Asking and answering
---------------------------------------------------------------------------

local function nonce() return CH.Comm:NextId() end

-- Ask the guild about a key or a search text. Returns true when sent, or false and a reason.
function Prices:Ask(query)
    local now = GetTime()
    if self.lastAsk and now - self.lastAsk < self.ASK_COOLDOWN then return false, L["Wait a moment before asking again."] end
    local body = { n = nonce() }
    if self.ParseKey(query) then
        body.k = query
    else
        local text = CH.CleanText(query or "", 40)
        if not text or #text < 3 then return false, L["Type at least 3 letters."] end
        body.t = text:lower()
    end
    if not CH.Comm:Send("PQ", body, "GUILD") then return false, L["You're not in a guild."] end
    self.lastAsk = now
    self.question = { n = body.n, k = body.k, t = body.t, at = time() }
    self.answers = {}
    CH.Events:Publish("PRICES_CHANGED")
    return true
end

local function validEntry(e)
    if type(e) ~= "table" or not Prices.ParseKey(e.k) then return nil end
    local p, d = tonumber(e.p), tonumber(e.d)
    local today = Prices.Today()
    if not p or p < 1 or p > 1e10 or p % 1 ~= 0 then return nil end
    if not d or d % 1 ~= 0 or d > today + 1 or d < today - 60 then return nil end
    local m = e.m ~= nil and CH.CleanText(e.m, 80) or nil
    return { k = e.k, p = p, d = d, m = m ~= "" and m or nil }
end

function Prices:OnQuestion(sender, body)
    if type(body) ~= "table" or type(body.n) ~= "string" or #body.n > 12 then return end
    if CH.Settings:Get("prices.answer") == false or not self:HasAuctionator() then return end
    local now = GetTime()
    if self.lastQuestionFrom[sender] and now - self.lastQuestionFrom[sender] < 2 then return end
    self.lastQuestionFrom[sender] = now
    local entries = {}
    if self.ParseKey(body.k) then
        local p, d = self:Own(body.k)
        if p then entries[1] = { k = body.k, p = p, d = d } end
    elseif type(body.t) == "string" then
        for _, r in ipairs(self:Search(body.t, self.MAX_ANSWERS, true)) do
            local p, d = self:Own(r.key)
            if p then entries[#entries + 1] = { k = r.key, p = p, d = d, m = self:Name(r.id) } end
        end
    end
    if #entries == 0 then return end
    self.heard[body.n] = self.heard[body.n] or { at = now, keys = {} }
    C_Timer.After(0.3 + math.random() * 1.7, function()
        local heard = Prices.heard[body.n]
        local left = {}
        for _, e in ipairs(entries) do
            local best = heard and heard.keys[e.k]
            if not best or best < e.d then left[#left + 1] = e end
        end
        if #left > 0 then CH.Comm:Send("PA", { n = body.n, r = left }, "GUILD") end
    end)
end

function Prices:OnAnswer(sender, body)
    if type(body) ~= "table" or type(body.n) ~= "string" or type(body.r) ~= "table" then return end
    local now = GetTime()
    for n, h in pairs(self.heard) do if now - h.at > 60 then self.heard[n] = nil end end
    local heard = self.heard[body.n]
    if not heard then
        heard = { at = now, keys = {} }
        self.heard[body.n] = heard
    end
    local mine = self.question and self.question.n == body.n
    for i = 1, math.min(#body.r, self.MAX_ANSWERS) do
        local e = validEntry(body.r[i])
        if e then
            if not heard.keys[e.k] or heard.keys[e.k] < e.d then heard.keys[e.k] = e.d end
            self:Remember(e.k, e.p, e.d, sender, e.m)
            if mine then
                self.answers[#self.answers + 1] = { key = e.k, price = e.p, day = e.d, by = sender }
            end
        end
    end
    if mine then CH.Events:Publish("PRICES_CHANGED") end
end

---------------------------------------------------------------------------
-- Material price packs
---------------------------------------------------------------------------

function Prices.ValidatePack(record)
    local page, day = tonumber(record.page), tonumber(record.day)
    if not page or page < 1 or page > Prices.PACK_MAX_PAGES or page % 1 ~= 0 then return nil, "bad page" end
    if not day or day % 1 ~= 0 or day < 0 or day > Prices.Today() + 1 then return nil, "bad day" end
    if record.id ~= record.owner .. "|" .. page then return nil, "bad id" end
    local data = record.data
    if type(data) ~= "string" or #data > 6000 or not data:match("^[%w:;]*$") then return nil, "bad data" end
    return { page = page, day = day, data = data }
end

function Prices.PrunePack(record, now)
    return now - (record.updatedAt or 0) > Prices.PACK_TTL
end

local function base36(n)
    n = math.floor(n)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    repeat
        local d = n % 36
        out = digits:sub(d + 1, d + 1) .. out
        n = math.floor(n / 36)
    until n == 0
    return out
end

-- Your fresh material prices, sorted by item: { { id, price, day } }.
function Prices:CollectMaterials()
    local variants = self:Variants()
    if not variants or not (C_Item and C_Item.GetItemInfoInstant) then return {} end
    local today, out = self.Today(), {}
    for id, v in pairs(variants) do
        if v.plain then
            local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, id)
            if ok and self.MATERIAL_CLASSES[classID] then
                local p, d = self:Own(tostring(id))
                if p and d and today - d <= self.PACK_FRESH_DAYS then out[#out + 1] = { id, p, d } end
            end
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
end

-- Publishes your material prices when they're newer than what the guild already has.
-- Returns the number of pages published (0 when nothing needed sending).
function Prices:PublishMaterials(force)
    if CH.Settings:Get("prices.shareMats") == false or not CH.Identity:GuildKey() or not CH.Roster.loaded then return 0 end
    local items = self:CollectMaterials()
    local me = CH.Identity:PlayerKey()
    if #items == 0 or not me then return 0 end
    local newest = 0
    for _, it in ipairs(items) do newest = math.max(newest, it[3]) end
    -- Someone else published a pack as fresh as ours recently: ours would add little.
    local nowServer = CH.ServerTime()
    if not force then
        for _, r in CH.Sync:Iterate(P_TYPE) do
            if not r.deleted and r.owner ~= me and r.day >= newest and nowServer - r.updatedAt < 12 * 3600 then return 0 end
        end
        local last = CH.Settings:Get("prices.lastPublish") or 0
        local lastDay = CH.Settings:Get("prices.lastPublishDay") or -1
        if newest <= lastDay and nowServer - last < self.PACK_MIN_INTERVAL then return 0 end
    end
    local pages, published = {}, 0
    for i = 1, math.min(#items, self.PACK_ITEMS * self.PACK_MAX_PAGES) do
        local page = math.floor((i - 1) / self.PACK_ITEMS) + 1
        local it = items[i]
        pages[page] = pages[page] or {}
        local list = pages[page]
        list[#list + 1] = base36(it[1]) .. ":" .. base36(it[2]) .. ":" .. base36(newest - it[3]) .. ";"
    end
    for page = 1, self.PACK_MAX_PAGES do
        local id = me .. "|" .. page
        local existing = CH.Sync:Get(P_TYPE, id)
        local list = pages[page]
        if list then
            local data = table.concat(list)
            if not existing or existing.deleted or existing.data ~= data or existing.day ~= newest then
                if CH.Sync:PublishLocal(P_TYPE, { id = id, page = page, day = newest, data = data }) then
                    published = published + 1
                end
            end
        elseif existing and not existing.deleted then
            CH.Sync:PublishLocal(P_TYPE, { id = id, deleted = true })
        end
    end
    CH.Settings:Set("prices.lastPublish", nowServer)
    CH.Settings:Set("prices.lastPublishDay", newest)
    return published
end

---------------------------------------------------------------------------

CH:RegisterModule(MODULE, {
    version = "0.8.0",
    description = L["Prices: auction prices anywhere, guild price questions, shared material prices"],
    requires = { "C_ChatInfo.SendAddonMessage" },
    initialize = function()
        Prices.ready = true
        CH.Store:RegisterNamespace("itemNames", "account")
        CH.Store:RegisterNamespace("priceCache", "guild")
        CH.Sync:RegisterType(P_TYPE, { namespace = "pricePacks", validate = Prices.ValidatePack,
            prune = Prices.PrunePack, maxRecords = 120, bulk = true })
        CH.Comm:RegisterHandler("PQ", function(sender, body) Prices:OnQuestion(sender, body) end)
        CH.Comm:RegisterHandler("PA", function(sender, body) Prices:OnAnswer(sender, body) end)
        CH.Events:RegisterGameEvent("ITEM_DATA_LOAD_RESULT", MODULE, function(itemID, success)
            CH.SafeCall("price item name", Prices.OnItemLoaded, Prices, itemID, success)
        end)
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == P_TYPE then CH.Debounce(MODULE, 0.5, function() CH.Events:Publish("PRICES_CHANGED") end) end
        end)
        local function publish() CH.SafeCall("publish material prices", Prices.PublishMaterials, Prices) end
        -- A closed auction house usually means a fresh scan.
        CH.Events:RegisterGameEvent("AUCTION_HOUSE_CLOSED", MODULE, function()
            Prices.variants = nil
            C_Timer.After(5, function()
                CH.SafeCall("price index", Prices.BuildIndex, Prices)
                publish()
            end)
        end)
        -- After login: index names in the background, then share materials once the roster is known.
        C_Timer.After(20, function()
            CH.SafeCall("prune price cache", Prices.PruneCache, Prices)
            CH.SafeCall("price index", Prices.BuildIndex, Prices)
        end)
        C_Timer.After(90, publish)
    end,
    shutdown = function()
        Prices.ready = false
        CH.Events:UnregisterGameEvent("ITEM_DATA_LOAD_RESULT", MODULE)
        CH.Events:UnregisterGameEvent("AUCTION_HOUSE_CLOSED", MODULE)
        if Prices.indexTicker then Prices.indexTicker:Cancel() end
    end,
})
