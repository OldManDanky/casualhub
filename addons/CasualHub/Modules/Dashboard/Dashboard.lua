-- Dashboard (design doc §4.1): guild summary, message of the day, and the sections later phases will fill.
local _, CH = ...
local L = CH.L
local W = CH.Widgets

local Dashboard = {}
local MODULE = "Dashboard"

local function onlineCounts()
    if not CH.Roster.loaded then return nil end
    return CH.Roster.onlineCount, CH.Roster.total
end

function Dashboard:Refresh()
    local frame = self.frame
    if not frame or not frame:IsVisible() then return end

    local guildName = CH.Identity:GuildName()
    local lines = {}
    if guildName then
        local _, rankName = GetGuildInfo("player")
        local online, total = onlineCounts()
        lines[#lines + 1] = ("|cffffffff%s|r"):format(guildName)
        lines[#lines + 1] = (L["You: %s, %s (%s)"]):format(tostring(CH.Identity:PlayerKey()), tostring(rankName),
            CH.Permissions:RoleLabel(CH.Permissions:PlayerRole()))
        if online and total then
            lines[#lines + 1] = (L["Online: |cffffffff%d|r of %d members"]):format(online, total)
            lines[#lines + 1] = (L["Using Casual Hub now: |cffffffff%d|r"]):format(CH.Comm:PeerCount(true) + 1)
        else
            lines[#lines + 1] = L["Loading roster..."]
        end
    else
        lines[#lines + 1] = L["You are not in a guild. Casual Hub's shared features need a guild."]
    end
    frame.guildCard.body:SetText(table.concat(lines, "\n"))

    local motd = guildName and GetGuildRosterMOTD and GetGuildRosterMOTD()
    if type(motd) ~= "string" or CH.Compat.IsSecret(motd) or motd == "" then
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
    local y = CH.UI:PageHeader(frame, L["Dashboard"], L["What's happening in your guild"])

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
    CH.Roster:Request()
    CH.Roster:Scan()
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.1.0",
    description = L["Home screen with guild summary"],
    initialize = function()
        CH.UI:RegisterPage("dashboard", {
            build = function(frame) Dashboard:Build(frame) end,
            onShow = function() Dashboard:OnShow() end,
        })
        local refresh = function() Dashboard:Refresh() end
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, refresh)
        CH.Events:RegisterGameEvent("GUILD_MOTD", MODULE, refresh)
        CH.Events:Subscribe("GUILD_CHANGED", MODULE, refresh)
    end,
    shutdown = function()
        CH.Events:UnregisterGameEvent("GUILD_MOTD", MODULE)
    end,
})
