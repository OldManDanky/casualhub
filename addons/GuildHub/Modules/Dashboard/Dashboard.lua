-- Dashboard (design doc §4.1): guild summary, message of the day, and the sections later phases will fill.
local _, GH = ...
local L = GH.L
local W = GH.Widgets

local Dashboard = {}
local MODULE = "Dashboard"

local function onlineCounts()
    if not (IsInGuild and IsInGuild()) or not GetNumGuildMembers then return nil end
    local total, online = GetNumGuildMembers()
    return tonumber(online), tonumber(total)
end

function Dashboard:Refresh()
    local frame = self.frame
    if not frame or not frame:IsVisible() then return end

    local guildName = GH.Identity:GuildName()
    local lines = {}
    if guildName then
        local _, rankName = GetGuildInfo("player")
        local online, total = onlineCounts()
        lines[#lines + 1] = ("|cffffffff%s|r"):format(guildName)
        lines[#lines + 1] = (L["You: %s, %s (%s)"]):format(tostring(GH.Identity:PlayerKey()), tostring(rankName),
            GH.Permissions:RoleLabel(GH.Permissions:PlayerRole()))
        if online and total then
            lines[#lines + 1] = (L["Online: |cffffffff%d|r of %d members"]):format(online, total)
        else
            lines[#lines + 1] = L["Loading roster..."]
        end
    else
        lines[#lines + 1] = L["You are not in a guild. GuildHub's shared features need a guild."]
    end
    frame.guildCard.body:SetText(table.concat(lines, "\n"))

    local motd = guildName and GetGuildRosterMOTD and GetGuildRosterMOTD()
    if type(motd) ~= "string" or GH.Compat.IsSecret(motd) or motd == "" then
        motd = "|cff999999" .. L["No message of the day."] .. "|r"
    end
    frame.motdCard.body:SetText(motd)
end

local function layout(frame)
    local width = frame:GetWidth()
    local gap, margin = 12, 20
    local colWidth = math.max(200, (width - margin * 2 - gap) / 2)
    for _, card in ipairs(frame.cards) do card:SetWidth(colWidth) end
end

function Dashboard:Build(frame)
    self.frame = frame
    local y = GH.UI:PageHeader(frame, L["Dashboard"], L["What's happening in your guild"])

    local function card(title, height)
        local c = W.Card(frame, title)
        c:SetHeight(height)
        return c
    end
    frame.guildCard = card(L["Guild"], 110)
    frame.guildCard:SetPoint("TOPLEFT", 20, y)
    frame.motdCard = card(L["Message of the Day"], 110)
    frame.motdCard:SetPoint("TOPLEFT", frame.guildCard, "TOPRIGHT", 12, 0)

    frame.activitiesCard = card(L["Open Activity Requests"], 120)
    frame.activitiesCard:SetPoint("TOPLEFT", frame.guildCard, "BOTTOMLEFT", 0, -12)
    frame.activitiesCard.body:SetText("|cff999999" ..
        L["The Activity Board arrives in phase 3: post a request, and guildmates volunteer."] .. "|r")
    frame.eventsCard = card(L["Upcoming Events"], 120)
    frame.eventsCard:SetPoint("TOPLEFT", frame.activitiesCard, "TOPRIGHT", 12, 0)
    frame.eventsCard.body:SetText("|cff999999" ..
        L["Event signups arrive in phase 4."] .. "|r")

    frame.cards = { frame.guildCard, frame.motdCard, frame.activitiesCard, frame.eventsCard }
    frame:SetScript("OnSizeChanged", layout)
    layout(frame)
end

function Dashboard:OnShow()
    -- The client throttles roster requests; GUILD_ROSTER_UPDATE may not follow, so refresh from cache now too.
    if IsInGuild and IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    end
    self:Refresh()
end

GH:RegisterModule(MODULE, {
    version = "0.1.0",
    description = L["Home screen with guild summary"],
    initialize = function()
        GH.UI:RegisterPage("dashboard", {
            build = function(frame) Dashboard:Build(frame) end,
            onShow = function() Dashboard:OnShow() end,
        })
        local refresh = function() Dashboard:Refresh() end
        GH.Events:RegisterGameEvent("GUILD_ROSTER_UPDATE", MODULE, refresh)
        GH.Events:RegisterGameEvent("GUILD_MOTD", MODULE, refresh)
        GH.Events:Subscribe("GUILD_CHANGED", MODULE, refresh)
    end,
    shutdown = function()
        GH.Events:UnregisterGameEvent("GUILD_ROSTER_UPDATE", MODULE)
        GH.Events:UnregisterGameEvent("GUILD_MOTD", MODULE)
    end,
})
