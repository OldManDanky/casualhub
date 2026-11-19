-- Startup and shutdown. Loaded last so every core service and module is registered first.
local ADDON_NAME, CH = ...
local L = CH.L
local Events = CH.Events

Events:RegisterGameEvent("ADDON_LOADED", "Core", function(name)
    if name ~= ADDON_NAME then return end
    Events:UnregisterGameEvent("ADDON_LOADED", "Core")
    CH.SafeCall("database init", CH.Store.Init, CH.Store)
    CH.Log:Info("Casual Hub %s loaded on %s %s (interface %s, project %s)", tostring(CH.version),
        tostring(CH.Compat.buildVersion), tostring(CH.Compat.buildNumber), tostring(CH.Compat.interface),
        tostring(CH.Compat.projectId))
    for _, cap in ipairs(CH.Compat.MissingCapabilities()) do
        CH.Log:Warn("client lacks %s; %s unavailable", cap.path, cap.feature)
    end
    Events:Publish("DB_READY")
end)

Events:RegisterGameEvent("PLAYER_LOGIN", "Core", function()
    if not CH.Store.db then
        CH:Print(L["saved data could not be loaded; Casual Hub is disabled this session. Type /chub diag."])
        return
    end
    CH.Modules:InitializeAll()
    CH.SafeCall("launcher init", CH.Launcher.Init, CH.Launcher)
    CH.ready = true
    if not CH.Compat.isForever then
        CH:Print(L["this client is not WoW Forever; Casual Hub is untested here."])
    end
end)

Events:RegisterGameEvent("PLAYER_GUILD_UPDATE", "Core", function(unit)
    if unit and unit ~= "player" then return end
    CH.Identity:InvalidateGuild()
    Events:Publish("GUILD_CHANGED")
end)

Events:RegisterGameEvent("PLAYER_LOGOUT", "Core", function()
    CH.Modules:ShutdownAll()
end)
