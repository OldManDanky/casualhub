-- Slash commands: /chub and /guildhub. Modules can add subcommands with CH.Commands:Register.
local _, CH = ...
local L = CH.L

local Commands = { list = {}, order = {} }
CH.Commands = Commands

function Commands:Register(name, help, fn)
    if not self.list[name] then self.order[#self.order + 1] = name end
    self.list[name] = { help = help, fn = fn }
end

function Commands:Run(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    local name, rest = input:match("^(%S+)%s*(.*)$")
    name = name and name:lower()
    if not name then
        CH.UI:Toggle()
        return
    end
    local cmd = self.list[name]
    if cmd then
        CH.SafeCall("/chub " .. name, cmd.fn, rest)
    elseif CH.UI:HasPage(name) then
        CH.UI:Show(name)
    else
        CH:Print(L["unknown command '%s'. Type /chub help."], name)
    end
end

Commands:Register("help", L["list commands"], function()
    CH:Print(L["commands:"])
    CH:Print("  /chub - %s", L["open or close the window"])
    CH:Print("  /chub <page> - %s", L["open a page (dashboard, members, activities, events, professions, bulletin, settings)"])
    for _, name in ipairs(Commands.order) do
        CH:Print("  /chub %s - %s", name, Commands.list[name].help)
    end
end)

Commands:Register("diag", L["show the diagnostics report"], function()
    CH.Diagnostics:Show()
end)

Commands:Register("debug", L["toggle debug logging in chat"], function()
    local enabled = not CH.Settings:Get("debug")
    CH.Settings:Set("debug", enabled)
    CH:Print(enabled and L["debug logging on"] or L["debug logging off"])
end)

Commands:Register("version", L["show the addon version"], function()
    CH:Print("%s (%s %s)", CH.version, tostring(CH.Compat.buildVersion), tostring(CH.Compat.buildNumber))
end)

Commands:Register("resetwindow", L["move the window back to the center of the screen"], function()
    CH.UI:ResetPosition()
end)

SLASH_CASUALHUB1 = "/chub"
SLASH_CASUALHUB2 = "/casualhub"
SlashCmdList.CASUALHUB = function(msg) Commands:Run(msg) end
