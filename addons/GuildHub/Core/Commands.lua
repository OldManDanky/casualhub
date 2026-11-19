-- Slash commands: /gh and /guildhub. Modules can add subcommands with GH.Commands:Register.
local _, GH = ...
local L = GH.L

local Commands = { list = {}, order = {} }
GH.Commands = Commands

function Commands:Register(name, help, fn)
    if not self.list[name] then self.order[#self.order + 1] = name end
    self.list[name] = { help = help, fn = fn }
end

function Commands:Run(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    local name, rest = input:match("^(%S+)%s*(.*)$")
    name = name and name:lower()
    if not name then
        GH.UI:Toggle()
        return
    end
    local cmd = self.list[name]
    if cmd then
        GH.SafeCall("/gh " .. name, cmd.fn, rest)
    elseif GH.UI:HasPage(name) then
        GH.UI:Show(name)
    else
        GH:Print(L["unknown command '%s'. Type /gh help."], name)
    end
end

Commands:Register("help", L["list commands"], function()
    GH:Print(L["commands:"])
    GH:Print("  /gh - %s", L["open or close the window"])
    GH:Print("  /gh <page> - %s", L["open a page (dashboard, members, activities, events, professions, bulletin, settings)"])
    for _, name in ipairs(Commands.order) do
        GH:Print("  /gh %s - %s", name, Commands.list[name].help)
    end
end)

Commands:Register("diag", L["show the diagnostics report"], function()
    GH.Diagnostics:Show()
end)

Commands:Register("debug", L["toggle debug logging in chat"], function()
    local enabled = not GH.Settings:Get("debug")
    GH.Settings:Set("debug", enabled)
    GH:Print(enabled and L["debug logging on"] or L["debug logging off"])
end)

Commands:Register("version", L["show the addon version"], function()
    GH:Print("%s (%s %s)", GH.version, tostring(GH.Compat.buildVersion), tostring(GH.Compat.buildNumber))
end)

Commands:Register("resetwindow", L["move the window back to the center of the screen"], function()
    GH.UI:ResetPosition()
end)

SLASH_GUILDHUB1 = "/gh"
SLASH_GUILDHUB2 = "/guildhub"
SlashCmdList.GUILDHUB = function(msg) Commands:Run(msg) end
