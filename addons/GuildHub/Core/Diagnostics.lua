-- Diagnostics report (/gh diag): environment, capability gaps, module states and the recent log.
local _, GH = ...

local Diagnostics = {}
GH.Diagnostics = Diagnostics

local function line(out, fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

function Diagnostics:BuildReport()
    local out = {}
    local C = GH.Compat
    line(out, "GuildHub %s", tostring(GH.version))
    line(out, "Client %s (%s), interface %s, project %s%s", tostring(C.buildVersion), tostring(C.buildNumber),
        tostring(C.interface), tostring(C.projectId), C.isForever and " [Forever]" or "")
    line(out, "Lua %s, locale %s", tostring(_VERSION), tostring(GetLocale()))
    line(out, "Character %s, guild %s, role %s", tostring(GH.Identity:PlayerKey()),
        tostring(GH.Identity:GuildKey()), GH.Permissions:PlayerRole())
    local store = GH.Store
    line(out, "Schema %s/%s%s", tostring(store.db and store.db.schemaVersion), tostring(store.SCHEMA_VERSION),
        store.readOnly and " (READ-ONLY)" or "")
    line(out, "")

    line(out, "Modules:")
    for _, m in ipairs(GH.Modules.list) do
        line(out, "  %-14s %-8s %-12s %s", m.name, m.version, m.state, m.reason or "")
    end
    line(out, "")

    local missing = C.MissingCapabilities()
    line(out, "Missing capabilities: %s", #missing == 0 and "none" or "")
    for _, cap in ipairs(missing) do line(out, "  %s (%s)", cap.path, cap.feature) end
    local unsupported = {}
    for event in pairs(GH.Events.unsupported) do unsupported[#unsupported + 1] = event end
    table.sort(unsupported)
    line(out, "Unsupported events: %s", #unsupported == 0 and "none" or table.concat(unsupported, ", "))
    line(out, "")

    local saved = store.db and store.db.diagnostics.errors or {}
    line(out, "Saved errors (%d, newest last):", #saved)
    for i = math.max(1, #saved - 9), #saved do
        local e = saved[i]
        line(out, "  [%s v%s] %s", date("%Y-%m-%d %H:%M", e.t), tostring(e.version), e.msg)
    end
    line(out, "")

    local entries = GH.Log.entries
    line(out, "Session log (last %d):", math.min(#entries, 60))
    for i = math.max(1, #entries - 59), #entries do
        local e = entries[i]
        line(out, "  %s %-5s %s", date("%H:%M:%S", e.t), e.level, e.msg)
    end
    return table.concat(out, "\n")
end

function Diagnostics:Show()
    GH.Widgets.CopyDialog(GH.L["GuildHub Diagnostics"], self:BuildReport())
end

function Diagnostics:ClearErrors()
    if GH.Store.db then
        local list = GH.Store.db.diagnostics.errors
        for i = #list, 1, -1 do list[i] = nil end
    end
    GH.errorNotified = nil
end
