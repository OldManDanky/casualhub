-- SavedVariables persistence: schema migrations, settings with defaults, and namespaced record storage.
--
-- CasualHubDB (account):  { schemaVersion, settings, data = { account = {ns...}, guilds = { [guildKey] = {ns...} } },
--                          diagnostics = { errors } }
-- CasualHubCharDB (char): { schemaVersion, data = {ns...} }
local _, CH = ...

local Store = { namespaces = {}, migrations = {}, readOnly = false }
CH.Store = Store

Store.SCHEMA_VERSION = 2

local DEFAULT_SETTINGS = {
    debug = false,
    scale = 1.0,
    lockWindow = false,
    window = { width = 900, height = 580 },  -- point/relativePoint/x/y are added once the window is moved
    lastPage = "dashboard",
    minimap = { show = true, angle = 205 },
    modules = {},                            -- [moduleName] = false to disable; absent means enabled
    permissions = { rankRoles = {} },        -- [tostring(rankIndex)] = "member" | "officer" | "guildmaster"
    profile = { share = true },              -- profiles are shared by default (opt-out)
    professions = { share = true },          -- professions and recipes too
    blacklist = { warn = { group = true, invite = true, tooltip = true, chat = true } },
    prices = { answer = true, shareMats = true },  -- answer guild price questions; share material prices
    -- Chat lines: someone volunteers / you're accepted; event reminders `eventLead` minutes before the start.
    notifications = { activities = true, events = true, eventLead = 15, notices = true },
}
Store.DEFAULT_SETTINGS = DEFAULT_SETTINGS

-- Migrations[n] upgrades a database from version n-1 to n. They receive the account and character tables.
Store.migrations[1] = function(db, charDb)
    -- 0 -> 1: initial layout. Nothing to transform; Init() builds the structure.
end

-- 1 -> 2: guild data was keyed "Guild Name@Realm", but Forever reports varying realm names for the same guild.
-- Merge every "Name@*" bucket into "Name", keeping the higher revision of each record.
Store.migrations[2] = function(db, charDb)
    local guilds = type(db.data) == "table" and db.data.guilds
    if type(guilds) ~= "table" then return end
    local oldKeys = {}
    for key in pairs(guilds) do
        if type(key) == "string" and key:find("@", 1, true) then oldKeys[#oldKeys + 1] = key end
    end
    table.sort(oldKeys)
    for _, key in ipairs(oldKeys) do
        local newKey = key:match("^(.*)@[^@]*$")
        local src = guilds[key]
        guilds[key] = nil
        if type(src) == "table" and newKey and newKey ~= "" then
            local dst = guilds[newKey] or {}
            guilds[newKey] = dst
            for namespace, bucket in pairs(src) do
                if type(bucket) == "table" then
                    local target = dst[namespace] or {}
                    dst[namespace] = target
                    for id, record in pairs(bucket) do
                        local existing = target[id]
                        local newer = type(record) == "table" and type(existing) == "table"
                            and type(record.rev) == "number" and record.rev > (tonumber(existing.rev) or 0)
                        if existing == nil or newer then target[id] = record end
                    end
                end
            end
        end
    end
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end
Store.DeepCopy = deepCopy

-- Fills in missing settings and replaces values whose type no longer matches the default.
-- Unknown keys are kept so newer versions' settings survive a downgrade.
local function sanitize(settings, defaults, path, repaired)
    if type(settings) ~= "table" then
        if settings ~= nil then repaired[#repaired + 1] = path ~= "" and path or "settings" end
        settings = {}
    end
    for key, default in pairs(defaults) do
        local value = settings[key]
        local keyPath = path == "" and key or (path .. "." .. key)
        if type(default) == "table" then
            settings[key] = sanitize(value, default, keyPath, repaired)
        elseif value == nil then
            settings[key] = default
        elseif type(value) ~= type(default) then
            repaired[#repaired + 1] = keyPath
            settings[key] = default
        end
    end
    return settings
end

local function asTable(value)
    return type(value) == "table" and value or {}
end

function Store:Init()
    local db, charDb = CasualHubDB, CasualHubCharDB
    if db ~= nil and type(db) ~= "table" then
        CH.Log:Warn("account saved data was not a table; starting fresh")
    end
    if charDb ~= nil and type(charDb) ~= "table" then
        CH.Log:Warn("character saved data was not a table; starting fresh")
    end
    db, charDb = asTable(db), asTable(charDb)
    if type(db.schemaVersion) ~= "number" then db.schemaVersion = 0 end
    if type(charDb.schemaVersion) ~= "number" then charDb.schemaVersion = 0 end

    db.diagnostics = asTable(db.diagnostics)
    db.diagnostics.errors = asTable(db.diagnostics.errors)
    CH.Log:AttachStorage(db.diagnostics.errors)

    local version = math.max(db.schemaVersion, charDb.schemaVersion)
    if version > self.SCHEMA_VERSION then
        -- Saved by a newer Casual Hub: keep it intact and refuse to write records.
        self.readOnly = true
        CH.Log:Warn("saved data uses schema %d but this version understands %d; record storage is read-only",
            version, self.SCHEMA_VERSION)
    else
        self:Migrate(db, charDb, self.SCHEMA_VERSION)
    end

    local repaired = {}
    db.settings = sanitize(db.settings, DEFAULT_SETTINGS, "", repaired)
    if #repaired > 0 then
        CH.Log:Warn("reset invalid settings: %s", table.concat(repaired, ", "))
    end
    db.data = asTable(db.data)
    db.data.account = asTable(db.data.account)
    db.data.guilds = asTable(db.data.guilds)
    charDb.data = asTable(charDb.data)

    CasualHubDB, CasualHubCharDB = db, charDb
    self.db, self.charDb = db, charDb
end

function Store:Migrate(db, charDb, target)
    for _, t in ipairs({ db, charDb }) do
        while t.schemaVersion < target do
            local nextVersion = t.schemaVersion + 1
            local migration = self.migrations[nextVersion]
            local ok = CH.SafeCall("migration " .. nextVersion, migration, db, charDb)
            if not ok then
                self.readOnly = true
                CH.Log:Error("migration to schema %d failed; record storage is read-only", nextVersion)
                return false
            end
            t.schemaVersion = nextVersion
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------

-- scope: "account" (all characters), "char" (this character), or "guild" (the current guild only).
function Store:RegisterNamespace(name, scope)
    scope = scope or "account"
    assert(scope == "account" or scope == "char" or scope == "guild", "invalid namespace scope")
    self.namespaces[name] = { scope = scope }
end

-- Returns the table holding a namespace's records, or nil when its scope is unavailable
-- (database not loaded yet, or a guild namespace while guild info is unknown).
function Store:Bucket(namespace, create)
    local spec = self.namespaces[namespace]
    if not spec then error("unregistered namespace: " .. tostring(namespace), 2) end
    if not self.db then return nil end
    local root
    if spec.scope == "char" then
        root = self.charDb.data
    elseif spec.scope == "guild" then
        local key = CH.Identity:GuildKey()
        if not key then return nil end
        root = self.db.data.guilds[key]
        if not root then
            if not create then return nil end
            root = {}
            self.db.data.guilds[key] = root
        end
    else
        root = self.db.data.account
    end
    local bucket = root[namespace]
    if not bucket and create then
        bucket = {}
        root[namespace] = bucket
    end
    return bucket
end

function Store:Get(namespace, key)
    local bucket = self:Bucket(namespace, false)
    return bucket and bucket[key]
end

function Store:Put(namespace, key, record)
    if self.readOnly then return false, "read-only" end
    local bucket = self:Bucket(namespace, true)
    if not bucket then return false, "scope unavailable" end
    bucket[key] = record
    CH.Events:Publish("STORE_CHANGED", namespace, key, record)
    return true
end

function Store:Delete(namespace, key)
    return self:Put(namespace, key, nil)
end

function Store:Iterate(namespace)
    return pairs(self:Bucket(namespace, false) or {})
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local Settings = {}
CH.Settings = Settings

local function walk(root, path)
    local parent, last = root, nil
    for part in path:gmatch("[^%.]+") do
        if last then
            if type(parent[last]) ~= "table" then return nil end
            parent = parent[last]
        end
        last = part
    end
    return parent, last
end

function Settings:Get(path)
    local settings = Store.db and Store.db.settings
    if not settings then
        local parent, key = walk(DEFAULT_SETTINGS, path)
        return parent and parent[key]
    end
    local parent, key = walk(settings, path)
    return parent and parent[key]
end

function Settings:Set(path, value)
    if not Store.db then return false end
    local parent, key = walk(Store.db.settings, path)
    if not parent then return false end
    if parent[key] == value then return true end
    parent[key] = value
    CH.Events:Publish("SETTING_CHANGED", path, value)
    return true
end

function Settings:IsModuleEnabled(name)
    return self:Get("modules." .. name) ~= false
end

function Settings:SetModuleEnabled(name, enabled)
    -- Store only the opt-out so new modules default to enabled.
    if enabled == false then
        return self:Set("modules." .. name, false)
    end
    return self:Set("modules." .. name, nil)
end
