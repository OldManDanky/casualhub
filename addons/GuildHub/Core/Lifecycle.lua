-- Startup and shutdown. Loaded last so every core service and module is registered first.
local ADDON_NAME, GH = ...
local L = GH.L
local Events = GH.Events

Events:RegisterGameEvent("ADDON_LOADED", "Core", function(name)
    if name ~= ADDON_NAME then return end
    Events:UnregisterGameEvent("ADDON_LOADED", "Core")
    GH.SafeCall("database init", GH.Store.Init, GH.Store)
    GH.Log:Info("GuildHub %s loaded on %s %s (interface %s, project %s)", tostring(GH.version),
        tostring(GH.Compat.buildVersion), tostring(GH.Compat.buildNumber), tostring(GH.Compat.interface),
        tostring(GH.Compat.projectId))
    for _, cap in ipairs(GH.Compat.MissingCapabilities()) do
        GH.Log:Warn("client lacks %s; %s unavailable", cap.path, cap.feature)
    end
    Events:Publish("DB_READY")
end)

Events:RegisterGameEvent("PLAYER_LOGIN", "Core", function()
    if not GH.Store.db then
        GH:Print(L["saved data could not be loaded; GuildHub is disabled this session. Type /gh diag."])
        return
    end
    GH.Modules:InitializeAll()
    GH.SafeCall("launcher init", GH.Launcher.Init, GH.Launcher)
    GH.ready = true
    if not GH.Compat.isForever then
        GH:Print(L["this client is not WoW Forever; GuildHub is untested here."])
    end
end)

Events:RegisterGameEvent("PLAYER_GUILD_UPDATE", "Core", function(unit)
    if unit and unit ~= "player" then return end
    GH.Identity:InvalidateGuild()
    Events:Publish("GUILD_CHANGED")
end)

Events:RegisterGameEvent("PLAYER_LOGOUT", "Core", function()
    GH.Modules:ShutdownAll()
end)
