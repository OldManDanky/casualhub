-- Module registry. Modules talk to each other only through core services and events (design doc §6).
--
-- CH:RegisterModule(name, {
--     version = "1.0",
--     description = "...",
--     dependencies = { "OtherModule" },   -- initialized first; a missing or failed dependency blocks this module
--     requires = { "C_GuildInfo.GuildRoster" }, -- client capabilities; missing ones mark the module unsupported
--     required = true,                     -- cannot be disabled in settings (core UI pieces only)
--     initialize = function(module) end,   -- at PLAYER_LOGIN, protected
--     shutdown = function(module) end,     -- at PLAYER_LOGOUT, protected
-- })
local _, CH = ...

local Modules = { list = {}, byName = {} }
CH.Modules = Modules

-- States: registered -> running | disabled | unsupported | blocked | failed
function Modules:Register(name, spec)
    assert(type(name) == "string" and name ~= "", "module name required")
    spec = spec or {}
    if self.byName[name] then
        CH.Log:Error("module %s registered twice; keeping the first", name)
        return self.byName[name]
    end
    local module = {
        name = name,
        version = spec.version or "0",
        description = spec.description,
        dependencies = spec.dependencies or {},
        requires = spec.requires or {},
        required = spec.required and true or false,
        initialize = spec.initialize,
        shutdown = spec.shutdown,
        state = "registered",
    }
    self.byName[name] = module
    self.list[#self.list + 1] = module
    return module
end

function CH:RegisterModule(name, spec)
    return Modules:Register(name, spec)
end

function Modules:InitializeAll()
    local visiting = {}
    local function init(m)
        if m.state ~= "registered" then return m.state == "running" end
        if visiting[m.name] then
            m.state, m.reason = "failed", "dependency cycle"
            return false
        end
        visiting[m.name] = true
        if not m.required and not CH.Settings:IsModuleEnabled(m.name) then
            m.state, m.reason = "disabled", "disabled in settings"
            return false
        end
        for _, path in ipairs(m.requires) do
            if not CH.Compat.Has(path) then
                m.state, m.reason = "unsupported", "client lacks " .. path
                return false
            end
        end
        for _, depName in ipairs(m.dependencies) do
            local dep = self.byName[depName]
            if not dep or not init(dep) then
                m.state, m.reason = "blocked", "needs " .. depName
                return false
            end
        end
        local ok, err = CH.SafeCall("initialize " .. m.name, m.initialize, m)
        if ok then
            m.state = "running"
        else
            m.state, m.reason = "failed", tostring(err):match("^[^\n]*")
        end
        return ok
    end
    for _, m in ipairs(self.list) do init(m) end
    for _, m in ipairs(self.list) do
        if m.state ~= "running" then CH.Log:Info("module %s: %s (%s)", m.name, m.state, tostring(m.reason)) end
    end
    CH.Events:Publish("MODULES_READY")
end

function Modules:ShutdownAll()
    for i = #self.list, 1, -1 do
        local m = self.list[i]
        if m.state == "running" then CH.SafeCall("shutdown " .. m.name, m.shutdown, m) end
    end
end

function Modules:Get(name)
    return self.byName[name]
end

function Modules:IsRunning(name)
    local m = self.byName[name]
    return m ~= nil and m.state == "running"
end
