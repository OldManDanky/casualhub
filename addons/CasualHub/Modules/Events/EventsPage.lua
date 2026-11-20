-- Events page (design doc §4.4, §5): browse scheduled events, sign up by role, and run your own with the
-- group builder (lineup, waitlist, confirm/bench, invites, participant suggestions).
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD
local E = CH.GuildEvents

local Page = { filters = { category = "all", mine = false, past = false }, view = "lineup" }
local MODULE = "EventsPage"
local ROW_HEIGHT = 26
local LINE_HEIGHT = 20

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function coloredName(name)
    local m = CH.Roster:Get(name)
    return "|c" .. CH.ClassColorHex(m and m.class) .. name .. "|r"
end

local function categoryTag(category)
    return "|c" .. (E.CATEGORY_COLORS[category] or "ffffffff") .. E:Label(category) .. "|r"
end

local OFFICIAL = "|cffd4af37" .. L["Official"] .. "|r"

-- "Sat 21 Nov 20:00", or "today 20:00" / "tomorrow 20:00" / "in 25m (20:00)" when close.
function Page.FormatStart(e, now)
    now = now or CH.ServerTime()
    local clock = date("%H:%M", e.startAt)
    local delta = e.startAt - now
    if delta > 0 and delta < 3600 then return (L["in %dm (%s)"]):format(math.ceil(delta / 60), clock) end
    local day = date("%Y%m%d", e.startAt)
    if day == date("%Y%m%d", now) then return (L["today %s"]):format(clock) end
    if day == date("%Y%m%d", now + 86400) then return (L["tomorrow %s"]):format(clock) end
    return date("%a %d %b %H:%M", e.startAt)
end

local function formatDuration(minutes)
    if minutes % 60 == 0 then return (L["%dh"]):format(minutes / 60) end
    return (L["%dh %02dm"]):format(math.floor(minutes / 60), minutes % 60)
end

local STATUS_COLORS = { upcoming = "ff7fd17f", inprogress = "ffe8c547", finished = "ff999999",
    completed = "ff6fa8dc", cancelled = "ffe06666" }
local function statusTag(status)
    return "|c" .. (STATUS_COLORS[status] or "ffffffff") .. E:Label(status) .. "|r"
end

local LETTERS = { tank = "T", healer = "H", dps = "D" }
local function roleSummary(e, lineup)
    local parts = {}
    for _, role in ipairs(E.ROLES) do
        local have, cap = #lineup.slots[role], e.roles[role]
        parts[#parts + 1] = cap and ("%s %d/%d"):format(LETTERS[role], have, cap) or ("%s %d"):format(LETTERS[role], have)
    end
    return table.concat(parts, "  ")
end

-- What the player's own state looks like on a list row and in the detail panel.
local function myPlacementTag(e, lineup)
    local me = CH.Identity:PlayerKey()
    if E:IsMine(e) then return "|cffd4af37" .. L["Organizer"] .. "|r" end
    local where, role = E:PlacementOf(e, me, lineup)
    if where == "lineup" then return "|cff7fd17f" .. (L["In (%s)"]):format(E:Label(role)) .. "|r" end
    if where == "waitlist" then return "|cffe8c547" .. L["Waitlist"] .. "|r" end
    if where == "tentative" then return "|cffbbbbbb" .. E:Label("tentative") .. "|r" end
    if where == "declined" then return "|cff999999" .. E:Label("declined") .. "|r" end
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

function Page:BuildItems()
    local items, me, now = {}, CH.Identity:PlayerKey(), CH.ServerTime()
    for _, e in ipairs(E:List(now)) do
        local active = E:IsActive(e, now)
        local mine = e.owner == me or E:MyRsvp(e.id) ~= nil
        if (self.filters.category == "all" or e.category == self.filters.category)
            and (not self.filters.mine or mine)
            and (self.filters.past or active) then
            items[#items + 1] = e
        end
    end
    return items
end

local function createRow(list)
    local row = CreateFrame("Button", nil, list)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(GOLD.r, GOLD.g, GOLD.b, 0.15)
    -- Right-to-left: status, size, start; the title takes the remaining width.
    row.status = W.Label(row, "", "GameFontHighlightSmall")
    row.status:SetPoint("RIGHT", -4, 0)
    row.status:SetWidth(70)
    row.status:SetJustifyH("RIGHT")
    row.count = W.Label(row, "", "GameFontHighlightSmall")
    row.count:SetPoint("RIGHT", row.status, "LEFT", -4, 0)
    row.count:SetWidth(40)
    row.count:SetJustifyH("RIGHT")
    row.when = W.Label(row, "", "GameFontHighlightSmall", W.COLORS.muted)
    row.when:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.when:SetWidth(110)
    row.category = W.Label(row, "", "GameFontHighlightSmall")
    row.category:SetPoint("LEFT", 6, 0)
    row.category:SetWidth(66)
    row.category:SetWordWrap(false)
    row.title = W.Label(row, "", "GameFontHighlight")
    row.title:SetPoint("LEFT", row.category, "RIGHT", 4, 0)
    row.title:SetPoint("RIGHT", row.when, "LEFT", -6, 0)
    row.title:SetWordWrap(false)
    row:SetScript("OnClick", function(self) Page:Select(self.event.id) end)
    return row
end

local function updateRow(row, e)
    row.event = e
    local lineup = E:Lineup(e)
    row.category:SetText(categoryTag(e.category))
    local mark = E:IsMine(e) and "|cffd4af37*|r " or ""
    local where = E:PlacementOf(e, CH.Identity:PlayerKey(), lineup)
    if where == "lineup" then mark = "|cff7fd17f+|r "
    elseif where == "waitlist" then mark = "|cffe8c547~|r " end
    row.title:SetText(mark .. (e.official and ("|cffd4af37[!]|r ") or "") .. e.title)
    row.when:SetText(Page.FormatStart(e))
    row.count:SetText(("%d/%d"):format(lineup.size, e.capacity))
    row.status:SetText(statusTag(E:EffectiveStatus(e)))
    row.selected:SetShown(e.id == Page.selected)
end

---------------------------------------------------------------------------
-- Detail: lineup, waitlist and suggestions share one scrolling list
---------------------------------------------------------------------------

function Page:LineupItems(e, lineup)
    local items = {}
    local function header(text) items[#items + 1] = { header = text } end
    local function entries(list, section)
        for _, entry in ipairs(list) do items[#items + 1] = { entry = entry, section = section } end
    end
    for _, role in ipairs(E.ROLES) do
        local have, cap = #lineup.slots[role], e.roles[role]
        if have > 0 or cap then
            header(cap and ("%s  %d/%d"):format(E:Label(role), have, cap) or ("%s  %d"):format(E:Label(role), have))
            entries(lineup.slots[role], "lineup")
        end
    end
    if #lineup.waitlist > 0 then header((L["Waitlist  %d"]):format(#lineup.waitlist)); entries(lineup.waitlist, "waitlist") end
    if #lineup.tentative > 0 then header((L["Tentative  %d"]):format(#lineup.tentative)); entries(lineup.tentative, "tentative") end
    if #lineup.declined > 0 then header((L["Declined  %d"]):format(#lineup.declined)); entries(lineup.declined, "declined") end
    if #items == 0 then items[1] = { header = "|cff999999" .. L["No signups yet."] .. "|r" } end
    return items
end

function Page:SuggestionItems(e)
    local items = { { header = L["Suggestions (shared profiles that fit)"] } }
    local list = E:Suggestions(e)
    for _, s in ipairs(list) do items[#items + 1] = { suggestion = s } end
    if #list == 0 then
        items[2] = { header = "|cff999999" .. L["Nobody else fits right now."] .. "|r" }
    end
    return items
end

local function createLine(list)
    local row = CreateFrame("Frame", nil, list)
    row.text = W.Label(row, "", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetWordWrap(false)
    local function rowButton(text, fn)
        local b = W.Button(row, text, 58, function() fn(row.item) Page:Refresh() end)
        b:SetHeight(18)
        return b
    end
    row.b1 = rowButton("", function(item) if row.b1.fn then row.b1.fn(item) end end)
    row.b1:SetPoint("RIGHT", 0, 0)
    row.b2 = rowButton("", function(item) if row.b2.fn then row.b2.fn(item) end end)
    row.b2:SetPoint("RIGHT", row.b1, "LEFT", -3, 0)
    row.b3 = rowButton("", function(item) if row.b3.fn then row.b3.fn(item) end end)
    row.b3:SetPoint("RIGHT", row.b2, "LEFT", -3, 0)
    row.text:SetPoint("RIGHT", row.b3, "LEFT", -4, 0)
    return row
end

local function invite(name)
    local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    -- Hyphenated, like chat commands: "/invite First Last" would read "Last" as extra text.
    if fn then fn((name:gsub(" ", "-"))) end
end

local function whisper(name)
    if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. (name:gsub(" ", "-")) .. " ") end
end

local function updateLine(row, item)
    row.item = item
    local buttons = {}
    local function button(label, fn) buttons[#buttons + 1] = { label, fn } end
    local e = Page.selected and E:Get(Page.selected)
    local organizing = e and E:IsMine(e)
    if item.header then
        row.text:SetText("|c" .. GOLD.hex .. item.header .. "|r")
    elseif item.suggestion then
        local s = item.suggestion
        local roles = {}
        for _, role in ipairs(s.roles) do roles[#roles + 1] = E:Label(role) end
        local fits = {}
        if s.dayMatch then fits[#fits + 1] = L["day"] end
        if s.timeMatch then fits[#fits + 1] = L["time"] end
        row.text:SetText(("%s |cff999999%s|r  %s%s%s"):format(coloredName(s.name), tostring(s.level or "?"),
            table.concat(roles, "/"),
            #fits > 0 and ("  |cff7fd17f" .. (L["fits %s"]):format(table.concat(fits, " + ")) .. "|r") or "",
            s.online and "" or ("  |cff999999" .. L["offline"] .. "|r")))
        if s.online then button(L["Whisper"], function() whisper(s.name) end) end
    else
        local entry = item.entry
        local tags = {}
        if entry.organizer then tags[#tags + 1] = "|cffd4af37" .. L["organizer"] .. "|r" end
        if entry.confirmed then tags[#tags + 1] = "|cff7fd17f" .. L["confirmed"] .. "|r" end
        if entry.benched then tags[#tags + 1] = "|cffe8a040" .. L["benched"] .. "|r" end
        if item.section ~= "lineup" and entry.role then tags[#tags + 1] = "|cff999999" .. E:Label(entry.role) .. "|r" end
        row.text:SetText(("  %s  %s%s"):format(coloredName(entry.name), table.concat(tags, " "),
            entry.note and ("  |cffbbbbbb\"" .. entry.note .. "\"|r") or ""))
        if organizing and not entry.organizer and (item.section == "lineup" or item.section == "waitlist") then
            local id, name = e.id, entry.name
            -- In the lineup: Invite, Bench, and Confirm (lock the spot) or Auto (undo the lock).
            -- Waiting: Confirm (bring in past the slot count), and Auto when benched by hand.
            if item.section == "lineup" then
                if CH.Roster:IsOnline(name) then button(L["Invite"], function() invite(name) end) end
                button(L["Bench"], function() E:SetLineup(id, name, "bench") end)
                if entry.confirmed then button(L["Auto"], function() E:SetLineup(id, name, nil) end)
                else button(L["Confirm"], function() E:SetLineup(id, name, entry.role) end) end
            else
                button(L["Confirm"], function() E:SetLineup(id, name, entry.role) end)
                if entry.benched then button(L["Auto"], function() E:SetLineup(id, name, nil) end) end
            end
        end
    end
    local slots = { row.b1, row.b2, row.b3 }
    for i, b in ipairs(slots) do
        local spec = buttons[i]
        if spec then
            b:SetText(spec[1])
            b.fn = spec[2]
            b:Show()
        else
            b.fn = nil
            b:Hide()
        end
    end
end

function Page:RenderDetail()
    local f = self.frame
    local e = self.selected and E:Get(self.selected)
    for _, b in ipairs(f.actionButtons) do b:Hide() end
    if not e then
        f.detailTitle:SetText(L["Select an event"])
        f.detailBody:SetText("|cff999999" .. L["Pick an event on the left, or schedule one with New event."] .. "|r")
        f.lineup:SetItems({})
        f.lineup:Hide()
        return
    end
    local lineup = E:Lineup(e)
    local status = E:EffectiveStatus(e)
    f.detailTitle:SetText(e.title)
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, label, value) end
    end
    add(L["Category"], categoryTag(e.category) .. (e.official and ("   " .. OFFICIAL) or ""))
    add(L["Organizer"], coloredName(e.owner))
    add(L["When"], ("%s  |cff999999(%s)|r"):format(Page.FormatStart(e), formatDuration(e.duration)))
    add(L["Status"], statusTag(status) .. ((myPlacementTag(e, lineup) and ("   " .. myPlacementTag(e, lineup))) or ""))
    add(L["Group"], ("%d/%d   %s"):format(lineup.size, e.capacity, roleSummary(e, lineup)) ..
        (e.minLevel and ("   |cff999999" .. (L["level %d+"]):format(e.minLevel) .. "|r") or ""))
    if e.details then lines[#lines + 1] = e.details end
    if e.notes then lines[#lines + 1] = ("|c%s%s:|r |cffdddddd%s|r"):format(GOLD.hex, L["Organizer notes"], e.notes) end
    f.detailBody:SetText(table.concat(lines, "\n"))

    local mine = E:IsMine(e)
    if not mine then self.view = "lineup" end
    f.lineup:Show()
    f.lineup:SetItems(self.view == "suggestions" and self:SuggestionItems(e) or self:LineupItems(e, lineup))

    local buttons = {}
    local function action(label, fn) buttons[#buttons + 1] = { label, fn } end
    if mine then
        action(L["Edit"], function() Page:OpenEditor(e) end)
        action(L["Repeat +7d"], function() Page:OpenEditor(e, true) end)
        if E:IsActive(e) then
            action(self.view == "suggestions" and L["Show lineup"] or L["Suggestions"], function()
                Page.view = Page.view == "suggestions" and "lineup" or "suggestions"
            end)
            action(L["Complete"], function() E:SetStatus(e.id, "completed") end)
            action(L["Cancel event"], function() E:SetStatus(e.id, "cancelled") end)
        elseif e.status ~= "scheduled" then
            action(L["Restore"], function() E:SetStatus(e.id, "scheduled") end)
        end
        action(L["Delete"], function()
            E:Delete(e.id)
            Page.selected = nil
        end)
    else
        local r = E:MyRsvp(e.id)
        if E:IsActive(e) then
            for _, role in ipairs(E.ROLES) do
                local current = r and r.state == "going" and r.role == role
                action(current and ("|cff7fd17f" .. E:Label(role) .. "|r") or (L["Go: %s"]):format(E:Label(role)),
                    function() Page:Respond(e.id, "going", role) end)
            end
            action(r and r.state == "tentative" and ("|cff7fd17f" .. E:Label("tentative") .. "|r") or E:Label("tentative"),
                function() Page:Respond(e.id, "tentative") end)
            action(r and r.state == "declined" and ("|cff7fd17f" .. L["Can't go"] .. "|r") or L["Can't go"],
                function() Page:Respond(e.id, "declined") end)
        end
        if CH.Roster:IsOnline(e.owner) then action(L["Whisper organizer"], function() whisper(e.owner) end) end
    end
    for i, spec in ipairs(buttons) do
        local b = f.actionButtons[i]
        if b then
            b:SetText(spec[1])
            b.fn = spec[2]
            b:Show()
        end
    end
end

function Page:Respond(id, state, role)
    local ok, reason = E:Respond(id, state, role)
    if not ok and reason then CH:Print(reason) end
end

function Page:Select(id)
    if id ~= self.selected then self.view = "lineup" end
    self.selected = id
    self:Refresh()
end

function Page:Refresh()
    local f = self.frame
    if not f or not f:IsVisible() or f.editor:IsShown() then return end
    local items = self:BuildItems()
    f.list:SetItems(items)
    f.subtitle:SetText((L["%d upcoming event(s). Showing %d."]):format(E:ActiveCount(), #items))
    f.empty:SetShown(#items == 0)
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Editor (new / edit / repeat)
---------------------------------------------------------------------------

-- Local midnight `offset` days from today, plus a wall-clock time -> absolute timestamp.
function Page.ComputeStart(offset, clock, now)
    local h, m = CH.ParseClock(clock)
    if not h then return nil end
    local t = date("*t", now)
    t.day, t.hour, t.min, t.sec = t.day + offset, h, m, 0
    return time(t)
end

-- Whole days between today and `ts`, in local time.
function Page.DayOffset(ts, now)
    local a, b = date("*t", now), date("*t", ts)
    a.hour, a.min, a.sec, b.hour, b.min, b.sec = 12, 0, 0, 12, 0, 0
    return math.floor((time(b) - time(a)) / 86400 + 0.5)
end

local MAX_OFFSET = 59

local function numberBox(parent, width, maxLetters)
    local e = W.EditBox(parent, width, maxLetters or 2)
    e:SetNumeric(true)
    e:SetJustifyH("CENTER")
    return e
end

function Page:BuildEditor(frame)
    local ed = W.CreatePanel(frame, W.COLORS.inset, 0.5)
    ed:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, frame.contentTop)
    ed:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)
    ed:Hide()
    frame.editor = ed

    ed.heading = W.Heading(ed, "")
    ed.heading:SetPoint("TOPLEFT", 14, -12)

    -- Rows are sized for the default window (about 680px of content width).
    ed.official = W.Checkbox(ed, L["Official guild event"], L["Marks the event as official. Officers only."])
    ed.official:SetPoint("TOPRIGHT", -190, -12)

    local y, STEP = -40, 44
    local function label(text, x)
        local l = W.Label(ed, text, "GameFontNormal")
        l:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        l:SetPoint("TOPLEFT", x or 14, y)
        return l
    end
    label(L["Category"])
    ed.category = W.ToggleRow(ed, E.CATEGORIES, function(v) return E:Label(v) end, 90)
    ed.category:Anchor("TOPLEFT", 14, y - 18)
    y = y - STEP

    label(L["Title"])
    ed.title = W.EditBox(ed, 420, E.TITLE_MAX)
    ed.title:SetPoint("TOPLEFT", 20, y - 18)
    y = y - STEP
    label(L["Details (optional)"])
    ed.details = W.EditBox(ed, 600, E.DETAILS_MAX)
    ed.details:SetPoint("TOPLEFT", 20, y - 18)
    y = y - STEP

    label(L["Date and time"])
    ed.prevDay = W.Button(ed, "<", 26, function() Page:ShiftDay(-1) end)
    ed.prevDay:SetPoint("TOPLEFT", 14, y - 18)
    ed.dayLabel = W.Label(ed, "", "GameFontHighlight")
    ed.dayLabel:SetPoint("LEFT", ed.prevDay, "RIGHT", 6, 0)
    ed.dayLabel:SetWidth(110)
    ed.nextDay = W.Button(ed, ">", 26, function() Page:ShiftDay(1) end)
    ed.nextDay:SetPoint("LEFT", ed.dayLabel, "RIGHT", 6, 0)
    ed.clock = W.EditBox(ed, 70, 7)
    ed.clock:SetPoint("LEFT", ed.nextDay, "RIGHT", 14, 0)
    local hint = W.Label(ed, L["e.g. 20:30 or 8:30pm, your local time"], "GameFontHighlightSmall", W.COLORS.muted)
    hint:SetPoint("LEFT", ed.clock, "RIGHT", 8, 0)
    y = y - STEP

    label(L["Length"])
    ed.duration = W.ToggleRow(ed, E.DURATIONS, function(m) return formatDuration(m) end, 44)
    ed.duration:Anchor("TOPLEFT", 14, y - 18)
    label(L["Your role"], 230)
    ed.organizerRole = W.ToggleRow(ed, { "none", "tank", "healer", "dps" }, function(v)
        return v == "none" and L["Not playing"] or E:Label(v)
    end, 86)
    ed.organizerRole:Anchor("TOPLEFT", 230, y - 18)
    y = y - STEP

    label(L["Role slots (blank = no limit)"])
    local x = 14
    ed.roleBoxes = {}
    for _, role in ipairs(E.ROLES) do
        local l = W.Label(ed, E:Label(role), "GameFontHighlight")
        l:SetPoint("TOPLEFT", x, y - 22)
        local box = numberBox(ed, 32)
        box:SetPoint("LEFT", l, "RIGHT", 8, 0)
        ed.roleBoxes[role] = box
        x = x + 106
    end
    local sizeLabel = W.Label(ed, L["Group size"], "GameFontHighlight")
    sizeLabel:SetPoint("TOPLEFT", x + 6, y - 22)
    ed.capacity = numberBox(ed, 36)
    ed.capacity:SetPoint("LEFT", sizeLabel, "RIGHT", 8, 0)
    local levelLabel = W.Label(ed, L["Min level"], "GameFontHighlight")
    levelLabel:SetPoint("LEFT", ed.capacity, "RIGHT", 18, 0)
    ed.minLevel = numberBox(ed, 36)
    ed.minLevel:SetPoint("LEFT", levelLabel, "RIGHT", 8, 0)
    y = y - STEP - 4

    label(L["Organizer notes (optional)"])
    ed.notes = W.EditBox(ed, 600, E.NOTES_MAX)
    ed.notes:SetPoint("TOPLEFT", 20, y - 18)

    ed.error = W.Label(ed, "", "GameFontHighlightSmall")
    ed.error:SetTextColor(1, 0.4, 0.4)
    ed.error:SetPoint("BOTTOMLEFT", 14, 44)
    ed.error:SetPoint("RIGHT", ed, "RIGHT", -14, 0)
    local save = W.Button(ed, L["Schedule"], 100, function() Page:SaveEditor() end)
    save:SetPoint("BOTTOMLEFT", 14, 12)
    ed.save = save
    local cancel = W.Button(ed, L["Cancel"], 100, function() Page:CloseEditor() end)
    cancel:SetPoint("LEFT", save, "RIGHT", 8, 0)
end

function Page:ShiftDay(delta)
    local ed = self.frame.editor
    ed.dayOffset = math.max(0, math.min(MAX_OFFSET, (ed.dayOffset or 0) + delta))
    local now = CH.ServerTime()
    local t = date("*t", now)
    t.day, t.hour = t.day + ed.dayOffset, 12
    local text = date("%a %d %b", time(t))
    if ed.dayOffset == 0 then text = L["Today"] elseif ed.dayOffset == 1 then text = L["Tomorrow"] end
    ed.dayLabel:SetText(text)
end

-- event: edit it; repeat: prefill a new event from it, a week later.
function Page:OpenEditor(event, repeatIt)
    local ed = self.frame.editor
    self.editing = (event and not repeatIt) and event.id or nil
    ed.heading:SetText(self.editing and L["Edit event"] or L["New event"])
    ed.save:SetText(self.editing and L["Save"] or L["Schedule"])
    local now = CH.ServerTime()
    ed.category:Set(event and event.category or "dungeon")
    ed.title:SetText(event and event.title or "")
    ed.details:SetText(event and event.details or "")
    ed.notes:SetText(event and event.notes or "")
    local start = event and event.startAt
    if start and repeatIt then
        start = start + 7 * 86400
        while start < now do start = start + 7 * 86400 end
    end
    if start and start > now then
        ed.dayOffset = math.max(0, math.min(MAX_OFFSET, Page.DayOffset(start, now)))
        ed.clock:SetText(date("%H:%M", start))
    else
        ed.dayOffset = event and 0 or 1
        ed.clock:SetText(event and date("%H:%M", event.startAt) or "20:00")
    end
    self:ShiftDay(0)
    ed.duration:Set(event and event.duration or 120)
    for _, role in ipairs(E.ROLES) do
        local n = event and event.roles[role]
        ed.roleBoxes[role]:SetText(n and tostring(n) or "")
    end
    ed.capacity:SetText(event and tostring(event.capacity) or "5")
    ed.minLevel:SetText(event and event.minLevel and tostring(event.minLevel) or "")
    ed.organizerRole:Set(event and event.organizerRole or "none")
    local canOfficial = CH.Permissions:Can("createOfficialEvent")
    ed.official:SetShown(canOfficial)
    ed.official:SetChecked(canOfficial and event and event.official or false)
    ed.error:SetText("")
    local f = self.frame
    f.list:Hide()
    f.detail:Hide()
    f.toolbar:Hide()
    f.empty:Hide()
    ed:Show()
end

function Page:CloseEditor()
    local f = self.frame
    f.editor:Hide()
    f.list:Show()
    f.detail:Show()
    f.toolbar:Show()
    self.editing = nil
    self:Refresh()
end

function Page:SaveEditor()
    local ed = self.frame.editor
    local now = CH.ServerTime()
    local startAt = Page.ComputeStart(ed.dayOffset or 0, ed.clock:GetText(), now)
    if not startAt then
        ed.error:SetText(L["Enter a start time like 20:30 or 8:30pm."])
        return
    end
    if startAt < now - 300 and not self.editing then
        ed.error:SetText(L["That start time has already passed."])
        return
    end
    if CH.CleanText(ed.title:GetText(), E.TITLE_MAX) == "" then
        ed.error:SetText(L["Give your event a title."])
        return
    end
    local roles = {}
    for role, box in pairs(ed.roleBoxes) do
        local n = tonumber(box:GetText())
        if n and n > 0 then roles[role] = n end
    end
    local capacity = tonumber(ed.capacity:GetText())
    if not capacity or capacity < 2 or capacity > E.MAX_SIZE then
        ed.error:SetText((L["Group size must be between 2 and %d."]):format(E.MAX_SIZE))
        return
    end
    local minLevel = tonumber(ed.minLevel:GetText())
    if minLevel and (minLevel < 1 or minLevel > 80) then
        ed.error:SetText(L["Min level must be between 1 and 80."])
        return
    end
    local fields = {
        category = ed.category.value, title = ed.title:GetText(), details = ed.details:GetText(),
        notes = ed.notes:GetText(), startAt = startAt, duration = ed.duration.value, capacity = capacity,
        roles = roles, minLevel = minLevel,
        organizerRole = ed.organizerRole.value ~= "none" and ed.organizerRole.value or nil,
        official = ed.official:IsShown() and ed.official:GetChecked() and true or nil,
    }
    local ok, reason
    if self.editing then
        ok, reason = E:Update(self.editing, fields)
        if ok then ok = self.editing end
    else
        ok, reason = E:Create(fields)
    end
    if not ok then
        ed.error:SetText(reason or L["Could not save."])
        return
    end
    self.selected = ok
    self.view = "lineup"
    self:CloseEditor()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Events"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(54)
    frame.toolbar = toolbar
    local categories = { "all" }
    for _, c in ipairs(E.CATEGORIES) do categories[#categories + 1] = c end
    frame.categoryFilter = W.ToggleRow(toolbar, categories, function(v)
        return v == "all" and L["All"] or E:Label(v)
    end, 86, function(v)
        Page.filters.category = v
        Page:Refresh()
    end)
    frame.categoryFilter:Anchor("TOPLEFT", 0, 0)
    frame.categoryFilter:Set("all")
    frame.mineOnly = W.Checkbox(toolbar, L["Mine"], L["Events you organize or signed up for."],
        function(v) Page.filters.mine = v; Page:Refresh() end)
    frame.mineOnly:SetPoint("TOPLEFT", 0, -28)
    frame.showPast = W.Checkbox(toolbar, L["Show past"], L["Include finished, completed and cancelled events."],
        function(v) Page.filters.past = v; Page:Refresh() end)
    frame.showPast:SetPoint("LEFT", frame.mineOnly, "RIGHT", 60, 0)
    local new = W.Button(toolbar, L["New event"], 130, function() Page:OpenEditor(nil) end)
    new:SetPoint("TOPRIGHT", 0, -28)

    local listTop = y - 62
    local list = W.List(frame, ROW_HEIGHT, createRow, updateRow)
    list:SetPoint("TOPLEFT", 20, listTop)
    list:SetPoint("BOTTOMLEFT", 20, 16)
    frame.list = list
    frame.empty = W.Label(frame, L["No events yet. Schedule one with New event."], "GameFontHighlight", W.COLORS.muted)
    frame.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -8)

    local detail = W.CreatePanel(frame, W.COLORS.inset, 0.5)
    detail:SetPoint("TOPRIGHT", -20, listTop)
    detail:SetPoint("BOTTOMRIGHT", -20, 16)
    frame.detail = detail
    frame.detailTitle = W.Label(detail, "", "GameFontNormalLarge")
    frame.detailTitle:SetPoint("TOPLEFT", 14, -12)
    frame.detailTitle:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
    frame.detailBody = W.Label(detail, "", "GameFontHighlight")
    frame.detailBody:SetPoint("TOPLEFT", frame.detailTitle, "BOTTOMLEFT", 0, -8)
    frame.detailBody:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
    frame.detailBody:SetJustifyV("TOP")
    frame.detailBody:SetSpacing(2)

    -- Action buttons along the bottom (two rows of up to three).
    frame.actionButtons = {}
    for i = 1, 6 do
        local b = W.Button(detail, "", 104, function(self)
            if self.fn then CH.SafeCall("event action", self.fn) end
            Page:Refresh()
        end)
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        b:SetPoint("BOTTOMLEFT", 12 + col * 108, 10 + (1 - row) * 26)
        b:Hide()
        frame.actionButtons[i] = b
    end

    -- Lineup / waitlist / suggestions between the details and the buttons.
    frame.lineup = W.List(detail, LINE_HEIGHT, createLine, updateLine)
    frame.lineup:SetPoint("TOPLEFT", frame.detailBody, "BOTTOMLEFT", -4, -10)
    frame.lineup:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -8, 66)

    local function layout()
        local width = frame:GetWidth() or 700
        detail:SetWidth(math.max(360, math.floor((width - 40) * 0.5)))
        list:SetPoint("RIGHT", detail, "LEFT", -12, 0)
        list:Refresh()
        frame.lineup:Refresh()
    end
    frame:SetScript("OnSizeChanged", layout)
    layout()

    self:BuildEditor(frame)
end

function Page:OnShow()
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.4.0",
    description = L["Events page"],
    dependencies = { "Events" },
    initialize = function()
        CH.UI:RegisterPage("events", {
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        local refresh = function() Page:Refresh() end
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "event" or typeName == "rsvp" or typeName == "profile" then CH.Debounce(MODULE, 0.2, function() Page:Refresh() end) end
        end)
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, refresh)
        if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(30, refresh) end
    end,
})

CH.EventsPage = Page  -- exposed for tests
