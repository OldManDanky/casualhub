-- Activity Board page (design doc §4.3, §5): browse and filter requests, volunteer, and manage your own.
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD
local A = CH.Activities

local Page = { filters = { category = "all", mine = false, closed = false } }
local MODULE = "ActivitiesPage"
local ROW_HEIGHT = 26
local MAX_VOLUNTEER_ROWS = 6

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function coloredName(name)
    local m = CH.Roster:Get(name)
    return "|c" .. CH.ClassColorHex(m and m.class) .. name .. "|r"
end

local function categoryTag(category)
    return "|c" .. (A.CATEGORY_COLORS[category] or "ffffffff") .. A:Label(category) .. "|r"
end

function Page.FormatWhen(a, now)
    now = now or CH.ServerTime()
    if not a.startAt or a.startAt <= now then return L["Now"] end
    local delta = a.startAt - now
    local clock = date("%H:%M", a.startAt)
    if delta < 3600 then return (L["in %dm (%s)"]):format(math.ceil(delta / 60), clock) end
    if date("%Y%m%d", a.startAt) == date("%Y%m%d", now) then return (L["today %s"]):format(clock) end
    return date("%a %H:%M", a.startAt)
end

local function roleSummary(a)
    local fill, parts = A:RoleFill(a), {}
    local letters = { tank = "T", healer = "H", dps = "D" }
    for _, role in ipairs(A.ROLES) do
        local need = a.roles[role]
        if need then parts[#parts + 1] = ("%s %d/%d"):format(letters[role], fill[role] or 0, need) end
    end
    return table.concat(parts, "  ")
end

local STATUS_COLORS = { open = "ff7fd17f", full = "ffe8c547", expired = "ff999999", closed = "ff999999",
    completed = "ff6fa8dc", cancelled = "ffe06666" }
local function statusTag(status)
    return "|c" .. (STATUS_COLORS[status] or "ffffffff") .. A:Label(status) .. "|r"
end

local toggleRow = W.ToggleRow

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

function Page:BuildItems()
    local items, me, now = {}, CH.Identity:PlayerKey(), CH.ServerTime()
    for _, a in ipairs(A:List()) do
        local active = A:IsActive(a, now)
        local mine = a.owner == me or A:MySignup(a.id) ~= nil or (a.accepted and a.accepted[me])
        if (self.filters.category == "all" or a.category == self.filters.category)
            and (not self.filters.mine or mine)
            and (self.filters.closed or active) then
            items[#items + 1] = a
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
    -- Right-to-left: status, group count, time; the title takes whatever width remains.
    row.status = W.Label(row, "", "GameFontHighlightSmall")
    row.status:SetPoint("RIGHT", -4, 0)
    row.status:SetWidth(62)
    row.status:SetJustifyH("RIGHT")
    row.count = W.Label(row, "", "GameFontHighlightSmall")
    row.count:SetPoint("RIGHT", row.status, "LEFT", -4, 0)
    row.count:SetWidth(34)
    row.count:SetJustifyH("RIGHT")
    row.when = W.Label(row, "", "GameFontHighlightSmall", W.COLORS.muted)
    row.when:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.when:SetWidth(72)
    row.category = W.Label(row, "", "GameFontHighlightSmall")
    row.category:SetPoint("LEFT", 6, 0)
    row.category:SetWidth(72)
    row.category:SetWordWrap(false)
    row.title = W.Label(row, "", "GameFontHighlight")
    row.title:SetPoint("LEFT", row.category, "RIGHT", 4, 0)
    row.title:SetPoint("RIGHT", row.when, "LEFT", -6, 0)
    row.title:SetWordWrap(false)
    row:SetScript("OnClick", function(self) Page:Select(self.activity.id) end)
    return row
end

local function updateRow(row, a)
    row.activity = a
    row.category:SetText(categoryTag(a.category))
    local mark = A:IsMine(a) and "|cffd4af37*|r " or (A:MySignup(a.id) and "|cff7fd17f+|r " or "")
    row.title:SetText(mark .. a.title)
    row.when:SetText(Page.FormatWhen(a))
    local group = A:AcceptedCount(a) + 1
    row.count:SetText(a.capacity and ("%d/%d"):format(group, a.capacity) or tostring(group))
    row.status:SetText(statusTag(A:EffectiveStatus(a)))
    row.selected:SetShown(a.id == Page.selected)
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

function Page:RenderDetail()
    local f = self.frame
    local a = self.selected and A:Get(self.selected)
    for _, b in ipairs(f.actionButtons) do b:Hide() end
    for _, r in ipairs(f.volunteerRows) do r:Hide() end
    f.volunteersHeading:Hide()
    if not a then
        f.detailTitle:SetText(L["Select a request"])
        f.detailBody:SetText("|cff999999" .. L["Pick a request on the left, or post your own with New request."] .. "|r")
        return
    end
    local status = A:EffectiveStatus(a)
    f.detailTitle:SetText(a.title)
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, label, value) end
    end
    add(L["Category"], categoryTag(a.category))
    add(L["Organizer"], coloredName(a.owner))
    add(L["When"], Page.FormatWhen(a))
    add(L["Status"], statusTag(status) .. (A:IsActive(a) and ("  |cff999999" ..
        (L["(open until %s)"]):format(date("%a %H:%M", a.expiresAt)) .. "|r") or ""))
    add(L["Group"], (a.capacity and ("%d/%d"):format(A:AcceptedCount(a) + 1, a.capacity) or tostring(A:AcceptedCount(a) + 1)) ..
        (next(a.roles) and ("   " .. roleSummary(a)) or ""))
    if a.details then lines[#lines + 1] = "\n" .. a.details end
    f.detailBody:SetText(table.concat(lines, "\n"))

    -- Volunteers
    local volunteers = A:Volunteers(a)
    local mine = A:IsMine(a)
    f.volunteersHeading:SetText((L["Volunteers (%d)"]):format(A:ActiveVolunteerCount(a)))
    f.volunteersHeading:Show()
    for i = 1, math.min(#volunteers, MAX_VOLUNTEER_ROWS) do
        local v, row = volunteers[i], f.volunteerRows[i]
        local state = v.withdrewAfterAccept and ("|cffe0a040" .. L["Withdrew"] .. "|r") or
            v.accepted and ("|cff7fd17f" .. A:Label("accepted") .. "|r") or
            (v.state == "withdrawn" and ("|cff999999" .. A:Label("withdrawn") .. "|r") or A:Label("volunteered"))
        row.text:SetText(("%s  |cff999999%s|r  %s%s"):format(coloredName(v.name), A:Label(v.role), state,
            v.note and ("  |cffbbbbbb\"" .. v.note .. "\"|r") or ""))
        row.volunteer = v
        row.accept:SetShown(mine and not v.accepted and v.state == "volunteered")
        row.remove:SetShown(mine and (v.accepted or v.withdrewAfterAccept))
        row.invite:SetShown(mine and v.accepted and CH.Roster:IsOnline(v.name))
        row:Show()
    end

    -- Actions
    local buttons = {}
    local function action(label, fn)
        buttons[#buttons + 1] = { label, fn }
    end
    if mine then
        action(L["Edit"], function() Page:OpenEditor(a) end)
        if A:IsActive(a) then
            action(L["Close"], function() A:SetStatus(a.id, "closed") end)
            action(L["Complete"], function() A:SetStatus(a.id, "completed") end)
        else
            action(L["Reopen"], function() A:SetStatus(a.id, "open") end)
        end
        action(L["Delete"], function()
            A:Delete(a.id)
            Page.selected = nil
            Page:Refresh()
        end)
    else
        local signup = A:MySignup(a.id)
        local volunteered = signup and signup.state == "volunteered"
        if A:IsActive(a) and not volunteered then
            local offered = false
            for _, role in ipairs(A.ROLES) do
                if a.roles[role] then
                    offered = true
                    action((L["Volunteer: %s"]):format(A:Label(role)), function() Page:Volunteer(a.id, role) end)
                end
            end
            action(offered and L["Volunteer: any"] or L["Volunteer"], function() Page:Volunteer(a.id, "any") end)
        end
        if volunteered then action(L["Withdraw"], function() A:Withdraw(a.id) end) end
        if CH.Roster:IsOnline(a.owner) then
            action(L["Whisper organizer"], function()
                if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. (a.owner:gsub(" ", "-")) .. " ") end
            end)
        end
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

function Page:Volunteer(id, role)
    local ok, reason = A:Volunteer(id, role)
    if not ok and reason then CH:Print(reason) end
end

function Page:Select(id)
    self.selected = id
    self:Refresh()
end

function Page:Refresh()
    local f = self.frame
    if not f or not f:IsVisible() or f.editor:IsShown() then return end
    local items = self:BuildItems()
    f.list:SetItems(items)
    f.subtitle:SetText((L["%d open request(s). Showing %d."]):format(A:OpenCount(), #items))
    f.empty:SetShown(#items == 0)
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Editor (new / edit)
---------------------------------------------------------------------------

Page.ParseClock = CH.ParseClock

-- Local wall-clock time on today/tomorrow -> absolute timestamp.
function Page.ComputeStart(day, clock, now)
    if day == "now" then return nil end
    local h, m = CH.ParseClock(clock)
    if not h then return false end
    local t = date("*t", now)
    t.hour, t.min, t.sec = h, m, 0
    if day == "tomorrow" then t.day = t.day + 1 end
    return time(t)
end

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

    local y = -44
    local function label(text, x)
        local l = W.Label(ed, text, "GameFontNormal")
        l:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        l:SetPoint("TOPLEFT", x or 14, y)
        return l
    end
    label(L["Category"])
    ed.category = toggleRow(ed, A.CATEGORIES, function(v) return A:Label(v) end, 96)
    ed.category:Anchor("TOPLEFT", 14, y - 18)
    y = y - 50

    label(L["Title"])
    ed.title = W.EditBox(ed, 420, A.TITLE_MAX)
    ed.title:SetPoint("TOPLEFT", 20, y - 18)
    y = y - 48
    label(L["Details (optional)"])
    ed.details = W.EditBox(ed, 600, A.DETAILS_MAX)
    ed.details:SetPoint("TOPLEFT", 20, y - 18)
    y = y - 50

    label(L["Starts"])
    ed.day = toggleRow(ed, { "now", "today", "tomorrow" }, function(v)
        return ({ now = L["Now"], today = L["Today at"], tomorrow = L["Tomorrow at"] })[v]
    end, 96, function(v) ed.clock:SetShown(v ~= "now") end)
    ed.day:Anchor("TOPLEFT", 14, y - 18)
    ed.clock = W.EditBox(ed, 70, 7)
    ed.clock:SetPoint("LEFT", ed.day.buttons.tomorrow, "RIGHT", 12, 0)
    local clockHint = W.Label(ed, L["e.g. 20:30 or 8:30pm, your local time"], "GameFontHighlightSmall", W.COLORS.muted)
    clockHint:SetPoint("LEFT", ed.clock, "RIGHT", 8, 0)
    y = y - 50

    label(L["Open for"])
    ed.expiry = toggleRow(ed, A.EXPIRY_HOURS, function(h)
        return h < 24 and (L["%d hours"]):format(h) or (h == 24 and L["1 day"] or (L["%d days"]):format(h / 24))
    end, 80)
    ed.expiry:Anchor("TOPLEFT", 14, y - 18)
    y = y - 50

    label(L["Looking for"])
    local x = 14
    ed.roleBoxes = {}
    for _, role in ipairs(A.ROLES) do
        local l = W.Label(ed, A:Label(role), "GameFontHighlight")
        l:SetPoint("TOPLEFT", x, y - 22)
        local box = numberBox(ed, 32)
        box:SetPoint("LEFT", l, "RIGHT", 8, 0)
        ed.roleBoxes[role] = box
        x = x + 120
    end
    local sizeLabel = W.Label(ed, L["Group size (with you)"], "GameFontHighlight")
    sizeLabel:SetPoint("TOPLEFT", x + 10, y - 22)
    ed.capacity = numberBox(ed, 36)
    ed.capacity:SetPoint("LEFT", sizeLabel, "RIGHT", 8, 0)

    ed.error = W.Label(ed, "", "GameFontHighlightSmall")
    ed.error:SetTextColor(1, 0.4, 0.4)
    ed.error:SetPoint("BOTTOMLEFT", 14, 44)
    ed.error:SetPoint("RIGHT", ed, "RIGHT", -14, 0)
    local save = W.Button(ed, L["Post"], 100, function() Page:SaveEditor() end)
    save:SetPoint("BOTTOMLEFT", 14, 12)
    ed.save = save
    local cancel = W.Button(ed, L["Cancel"], 100, function() Page:CloseEditor() end)
    cancel:SetPoint("LEFT", save, "RIGHT", 8, 0)
end

function Page:OpenEditor(activity)
    local ed = self.frame.editor
    self.editing = activity and activity.id or nil
    ed.heading:SetText(activity and L["Edit request"] or L["New request"])
    ed.save:SetText(activity and L["Save"] or L["Post"])
    local now = CH.ServerTime()
    ed.category:Set(activity and activity.category or "dungeons")
    ed.title:SetText(activity and activity.title or "")
    ed.details:SetText(activity and activity.details or "")
    if activity and activity.startAt and activity.startAt > now then
        local isToday = date("%Y%m%d", activity.startAt) == date("%Y%m%d", now)
        ed.day:Set(isToday and "today" or "tomorrow")
        ed.clock:SetText(date("%H:%M", activity.startAt))
    else
        ed.day:Set("now")
        ed.clock:SetText("")
    end
    ed.clock:SetShown(ed.day.value ~= "now")
    local hours = 6
    if activity then
        local remaining = (activity.expiresAt - (activity.startAt or activity.updatedAt)) / 3600
        for _, h in ipairs(A.EXPIRY_HOURS) do if remaining >= h - 0.5 then hours = h end end
    end
    ed.expiry:Set(hours)
    for _, role in ipairs(A.ROLES) do
        local n = activity and activity.roles[role]
        ed.roleBoxes[role]:SetText(n and tostring(n) or "")
    end
    ed.capacity:SetText(activity and activity.capacity and tostring(activity.capacity) or "5")
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
    local startAt = Page.ComputeStart(ed.day.value, ed.clock:GetText(), now)
    if startAt == false then
        ed.error:SetText(L["Enter a start time like 20:30 or 8:30pm."])
        return
    end
    if startAt and startAt < now - 300 then
        ed.error:SetText(L["That start time has already passed."])
        return
    end
    local roles = {}
    for role, box in pairs(ed.roleBoxes) do
        local n = tonumber(box:GetText())
        if n and n > 0 then roles[role] = n end
    end
    local capacity = tonumber(ed.capacity:GetText())
    if capacity and (capacity < 2 or capacity > A.MAX_GROUP) then
        ed.error:SetText((L["Group size must be between 2 and %d."]):format(A.MAX_GROUP))
        return
    end
    local fields = {
        category = ed.category.value, title = ed.title:GetText(), details = ed.details:GetText(),
        startAt = startAt, expiresAt = (startAt or now) + ed.expiry.value * 3600, roles = roles, capacity = capacity,
    }
    if CH.CleanText(fields.title, A.TITLE_MAX) == "" then
        ed.error:SetText(L["Give your request a title."])
        return
    end
    local ok, reason
    if self.editing then
        ok, reason = A:Update(self.editing, fields)
        if ok then ok = self.editing end
    else
        ok, reason = A:Create(fields)
    end
    if not ok then
        ed.error:SetText(reason or L["Could not save."])
        return
    end
    self.selected = ok
    self:CloseEditor()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Activities"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(54)
    frame.toolbar = toolbar
    local categories = { "all" }
    for _, c in ipairs(A.CATEGORIES) do categories[#categories + 1] = c end
    frame.categoryFilter = toggleRow(toolbar, categories, function(v)
        return v == "all" and L["All"] or A:Label(v)
    end, 86, function(v)
        Page.filters.category = v
        Page:Refresh()
    end)
    frame.categoryFilter:Anchor("TOPLEFT", 0, 0)
    frame.categoryFilter:Set("all")
    frame.mineOnly = W.Checkbox(toolbar, L["Mine"], L["Requests you organize, volunteered for, or were accepted to."],
        function(v) Page.filters.mine = v; Page:Refresh() end)
    frame.mineOnly:SetPoint("TOPLEFT", 0, -28)
    frame.showClosed = W.Checkbox(toolbar, L["Show finished"], L["Include closed, completed and expired requests."],
        function(v) Page.filters.closed = v; Page:Refresh() end)
    frame.showClosed:SetPoint("LEFT", frame.mineOnly, "RIGHT", 60, 0)
    local new = W.Button(toolbar, L["New request"], 130, function() Page:OpenEditor(nil) end)
    new:SetPoint("TOPRIGHT", 0, -28)

    local listTop = y - 62
    local list = W.List(frame, ROW_HEIGHT, createRow, updateRow)
    list:SetPoint("TOPLEFT", 20, listTop)
    list:SetPoint("BOTTOMLEFT", 20, 16)
    frame.list = list
    frame.empty = W.Label(frame, L["No requests yet. Post one with New request."], "GameFontHighlight", W.COLORS.muted)
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

    -- Action buttons along the bottom of the detail panel (two rows of up to three).
    frame.actionButtons = {}
    for i = 1, 6 do
        local b = W.Button(detail, "", 104, function(self) if self.fn then CH.SafeCall("activity action", self.fn) end; Page:Refresh() end)
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        b:SetPoint("BOTTOMLEFT", 12 + col * 108, 10 + (1 - row) * 26)
        b:Hide()
        frame.actionButtons[i] = b
    end

    -- Volunteer rows above the buttons.
    frame.volunteersHeading = W.Label(detail, "", "GameFontNormal")
    frame.volunteersHeading:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
    frame.volunteersHeading:SetPoint("BOTTOMLEFT", 14, 70 + MAX_VOLUNTEER_ROWS * 20)
    frame.volunteerRows = {}
    for i = 1, MAX_VOLUNTEER_ROWS do
        local row = CreateFrame("Frame", nil, detail)
        row:SetHeight(20)
        row:SetPoint("BOTTOMLEFT", 14, 70 + (MAX_VOLUNTEER_ROWS - i) * 20)
        row:SetPoint("RIGHT", detail, "RIGHT", -10, 0)
        row.text = W.Label(row, "", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT")
        row.text:SetWordWrap(false)
        local function rowButton(text, fn)
            local b = W.Button(row, text, 60, function()
                if row.volunteer then fn(row.volunteer) end
                Page:Refresh()
            end)
            b:SetHeight(18)
            return b
        end
        row.invite = rowButton(L["Invite"], function(v)
            local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
            -- Hyphenated, like chat commands: "/invite First Last" would read "Last" as extra text.
            if invite then invite((v.name:gsub(" ", "-"))) end
        end)
        row.invite:SetPoint("RIGHT", 0, 0)
        row.accept = rowButton(L["Accept"], function(v) A:SetAccepted(Page.selected, v.name, v.role) end)
        row.accept:SetPoint("RIGHT", row.invite, "LEFT", -4, 0)
        row.remove = rowButton(L["Remove"], function(v) A:SetAccepted(Page.selected, v.name, nil) end)
        row.remove:SetPoint("RIGHT", row.invite, "LEFT", -4, 0)
        row.text:SetPoint("RIGHT", row.accept, "LEFT", -4, 0)
        row:Hide()
        frame.volunteerRows[i] = row
    end

    local function layout()
        local width = frame:GetWidth() or 700
        detail:SetWidth(math.max(340, math.floor((width - 40) * 0.46)))
        list:SetPoint("RIGHT", detail, "LEFT", -12, 0)
        list:Refresh()
    end
    frame:SetScript("OnSizeChanged", layout)
    layout()

    self:BuildEditor(frame)
end

function Page:OnShow()
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.3.0",
    description = L["Activity Board page"],
    dependencies = { "Activities" },
    initialize = function()
        CH.UI:RegisterPage("activities", {
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        local refresh = function() Page:Refresh() end
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "activity" or typeName == "signup" then CH.Debounce(MODULE, 0.2, function() Page:Refresh() end) end
        end)
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, refresh)
        -- Keep "in 20m" / expiry labels current while the page is open.
        if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(30, refresh) end
    end,
})

CH.ActivitiesPage = Page  -- exposed for tests
