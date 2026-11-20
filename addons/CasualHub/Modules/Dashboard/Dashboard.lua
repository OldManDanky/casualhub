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
    -- Pinned and unread guild notices under the MOTD (Bulletin module may be disabled).
    local B = CH.Modules:IsRunning("Bulletin") and CH.Bulletin
    if B then
        local shown = {}
        for _, n in ipairs(B:List()) do
            if #shown >= 2 then break end
            if n.pinned or not B:IsRead(n) then
                shown[#shown + 1] = ("%s|cffffffff%s|r"):format(n.pinned and "|cffd4af37[!]|r " or "|cff7fd17f*|r ", n.title)
            end
        end
        if #shown > 0 then motd = motd .. "\n\n" .. table.concat(shown, "\n") end
    end
    frame.motdCard.body:SetText(motd)

    -- Open activity requests (Activity Board module may be disabled).
    local A = CH.Modules:IsRunning("Activities") and CH.Activities
    if A then
        local open, shown = {}, {}
        for _, a in ipairs(A:List()) do
            if A:IsActive(a) then open[#open + 1] = a end
        end
        for i = 1, math.min(3, #open) do
            local a = open[i]
            shown[#shown + 1] = ("|c%s%s|r %s |cff999999- %s|r"):format(A.CATEGORY_COLORS[a.category] or "ffffffff",
                A:Label(a.category), a.title, CH.ActivitiesPage.FormatWhen(a))
        end
        if #open == 0 then
            shown[1] = "|cff999999" .. L["No open requests. Post one on the Activities page."] .. "|r"
        elseif #open > 3 then
            shown[#shown + 1] = ("|cff999999" .. L["and %d more"] .. "|r"):format(#open - 3)
        end
        frame.activitiesCard.body:SetText(table.concat(shown, "\n"))
    end

    -- Upcoming events (Events module may be disabled).
    local E = CH.Modules:IsRunning("Events") and CH.GuildEvents
    if E then
        local upcoming, shown = {}, {}
        for _, e in ipairs(E:List()) do
            if E:IsActive(e) then upcoming[#upcoming + 1] = e end
        end
        local me = CH.Identity:PlayerKey()
        for i = 1, math.min(3, #upcoming) do
            local e = upcoming[i]
            local lineup = E:Lineup(e)
            local where = E:PlacementOf(e, me, lineup)
            local mark = E:IsMine(e) and "|cffd4af37*|r " or (where == "lineup" and "|cff7fd17f+|r ")
                or (where == "waitlist" and "|cffe8c547~|r ") or ""
            shown[#shown + 1] = ("%s%s |cff999999- %s  %d/%d|r"):format(mark, e.title, CH.EventsPage.FormatStart(e),
                lineup.size, e.capacity)
        end
        if #upcoming == 0 then
            shown[1] = "|cff999999" .. L["No upcoming events. Schedule one on the Events page."] .. "|r"
        elseif #upcoming > 3 then
            shown[#shown + 1] = ("|cff999999" .. L["and %d more"] .. "|r"):format(#upcoming - 3)
        end
        frame.eventsCard.body:SetText(table.concat(shown, "\n"))
    end
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
    frame.motdCard:EnableMouse(true)
    frame.motdCard:SetScript("OnMouseUp", function() CH.UI:SelectPage("bulletin") end)
    frame.motdCard:SetPoint("TOPLEFT", frame.guildCard, "TOPRIGHT", 12, 0)

    frame.activitiesCard = card(L["Open Activity Requests"], 120)
    frame.activitiesCard:SetPoint("TOPLEFT", frame.guildCard, "BOTTOMLEFT", 0, -12)
    frame.activitiesCard:EnableMouse(true)
    frame.activitiesCard:SetScript("OnMouseUp", function() CH.UI:SelectPage("activities") end)
    frame.eventsCard = card(L["Upcoming Events"], 120)
    frame.eventsCard:SetPoint("TOPLEFT", frame.activitiesCard, "TOPRIGHT", 12, 0)
    frame.eventsCard:EnableMouse(true)
    frame.eventsCard:SetScript("OnMouseUp", function() CH.UI:SelectPage("events") end)

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
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "activity" or typeName == "event" or typeName == "rsvp" or typeName == "notice" then
                CH.Debounce(MODULE, 0.2, refresh)
            end
        end)
    end,
    shutdown = function()
        CH.Events:UnregisterGameEvent("GUILD_MOTD", MODULE)
    end,
})
