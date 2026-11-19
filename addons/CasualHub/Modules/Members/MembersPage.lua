-- Members page (design doc §4.2, §5): searchable roster with profiles, plus the editor for your own profile.
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD

local Page = { filters = { text = "", online = false, addon = false } }
local MODULE = "Members"
local ROW_HEIGHT = 24
local STALE_AFTER = 14 * 86400

local function roleLetters(profile)
    if not profile or type(profile.roles) ~= "table" then return "" end
    local map = { tank = "|cff6fa8dcT|r", healer = "|cff93c47dH|r", dps = "|cffe06666D|r" }
    local out = {}
    for _, r in ipairs(profile.roles) do out[#out + 1] = map[r] end
    return table.concat(out, " ")
end

local function statusText(m)
    if m.online then return "|cff7fd17f" .. (m.zone or L["Online"]) .. "|r" end
    if m.lastSeen then return "|cff999999" .. CH.FormatAgo(m.lastSeen) .. "|r" end
    return "|cff999999" .. L["offline"] .. "|r"
end

local function coloredName(m)
    return "|c" .. CH.ClassColorHex(m.class) .. m.name .. "|r"
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function matches(entry, text)
    if text == "" then return true end
    local m, p = entry.member, entry.profile
    local hay = { m.name, m.rank, m.className, m.zone }
    if p then
        hay[#hay + 1] = CH.Profiles:FormatList(p.roles)
        hay[#hay + 1] = CH.Profiles:FormatList(p.interests)
        hay[#hay + 1] = p.note
        hay[#hay + 1] = p.main
    end
    for _, s in ipairs(hay) do
        if type(s) == "string" and s:lower():find(text, 1, true) then return true end
    end
    return false
end

function Page:BuildItems()
    local items, me = {}, CH.Identity:PlayerKey()
    local text = self.filters.text:lower()
    for _, m in ipairs(CH.Roster:List()) do
        local entry = { member = m, profile = CH.Profiles:Get(m.name), peer = CH.Comm:Peer(m.name), isMe = m.name == me }
        entry.hasAddon = entry.isMe or entry.peer ~= nil or entry.profile ~= nil
        if (not self.filters.online or m.online) and (not self.filters.addon or entry.hasAddon) and matches(entry, text) then
            items[#items + 1] = entry
        end
    end
    table.sort(items, function(a, b)
        if a.member.online ~= b.member.online then return a.member.online end
        return a.member.name < b.member.name
    end)
    return items
end

---------------------------------------------------------------------------
-- List rows
---------------------------------------------------------------------------

local function createRow(list)
    local row = CreateFrame("Button", nil, list)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(GOLD.r, GOLD.g, GOLD.b, 0.15)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexture(CH.ICON)
    row.name = W.Label(row, "", "GameFontHighlight")
    row.name:SetPoint("LEFT", 24, 0)
    row.name:SetWidth(150)
    row.level = W.Label(row, "", "GameFontHighlightSmall", W.COLORS.muted)
    row.level:SetPoint("LEFT", 176, 0)
    row.level:SetWidth(26)
    row.roles = W.Label(row, "", "GameFontHighlightSmall")
    row.roles:SetPoint("LEFT", 204, 0)
    row.roles:SetWidth(48)
    row.status = W.Label(row, "", "GameFontHighlightSmall")
    row.status:SetPoint("LEFT", 254, 0)
    row.status:SetPoint("RIGHT", -4, 0)
    row.status:SetWordWrap(false)
    row:SetScript("OnClick", function(self) Page:Select(self.entry.member.name) end)
    return row
end

local function updateRow(row, entry)
    row.entry = entry
    local m = entry.member
    row.name:SetText(coloredName(m))
    row.level:SetText(m.level and tostring(m.level) or "")
    row.roles:SetText(roleLetters(entry.profile))
    row.status:SetText(statusText(m))
    row.icon:SetShown(entry.hasAddon)
    row.selected:SetShown(m.name == Page.selected)
end

---------------------------------------------------------------------------
-- Detail pane
---------------------------------------------------------------------------

function Page:RenderDetail()
    local frame = self.frame
    local name = self.selected
    local m = name and CH.Roster:Get(name)
    if not m then
        frame.detailTitle:SetText(L["Select a member"])
        frame.detailBody:SetText("|cff999999" .. L["Click a name to see their profile."] .. "|r")
        return
    end
    local p = CH.Profiles:Get(name)
    frame.detailTitle:SetText(coloredName(m))
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, label, value) end
    end
    add(L["Level"], m.level and ("%d %s"):format(m.level, m.className or "") or nil)
    add(L["Rank"], m.rank)
    add(L["Status"], m.online and ((L["Online"]) .. (m.zone and (" - " .. m.zone) or "")) or
        (L["Last seen"] .. " " .. CH.FormatAgo(m.lastSeen)))
    local peer = CH.Comm:Peer(name)
    if peer then add(L["Casual Hub"], peer.version) end
    lines[#lines + 1] = ""
    if p then
        if p.main then add(L["Alt of"], p.main) end
        local alts = CH.Profiles:AltsOf(name)
        if #alts > 0 then add(L["Alts"], table.concat(alts, ", ")) end
        add(L["Roles"], CH.Profiles:FormatList(p.roles))
        add(L["Interests"], CH.Profiles:FormatList(p.interests))
        add(L["Days"], CH.Profiles:FormatList(p.days))
        add(L["Times"], CH.Profiles:FormatList(p.times))
        add(L["Note"], p.note)
        lines[#lines + 1] = ""
        if p._local then
            lines[#lines + 1] = "|cff999999" .. (p.private and L["Your profile is private (sharing is off)."] or
                (L["Shared with the guild. Updated %s."]):format(CH.FormatAgo(p.updatedAt, CH.ServerTime()))) .. "|r"
        else
            local age = CH.FormatAgo(p.updatedAt, CH.ServerTime())
            local stale = p.updatedAt and CH.ServerTime() - p.updatedAt > STALE_AFTER
            lines[#lines + 1] = ("|cff999999%s|r"):format((L["Profile updated %s"]):format(age))
            if stale then lines[#lines + 1] = "|cffe0a040" .. L["This profile may be out of date."] .. "|r" end
            if p._via and p._via ~= p.owner then
                lines[#lines + 1] = ("|cff999999%s|r"):format((L["Copy received from %s"]):format(p._via))
            end
        end
    else
        lines[#lines + 1] = "|cff999999" .. L["No shared profile. They may not use Casual Hub, or no one online has their profile yet."] .. "|r"
    end
    frame.detailBody:SetText(table.concat(lines, "\n"))
end

function Page:Select(name)
    self.selected = name
    self:Refresh()
end

function Page:Refresh()
    local frame = self.frame
    if not frame or not frame:IsVisible() then return end
    local items = self:BuildItems()
    frame.list:SetItems(items)
    local peers = CH.Comm:PeerCount(true) + 1
    frame.subtitle:SetText((L["%d members, %d online, %d using Casual Hub. Showing %d."]):format(
        CH.Roster.total or 0, CH.Roster.onlineCount or 0, peers, #items))
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Profile editor
---------------------------------------------------------------------------

local function checkGrid(parent, values, columns, colWidth, x, y)
    local checks = {}
    for i, value in ipairs(values) do
        local col, row = (i - 1) % columns, math.floor((i - 1) / columns)
        local cb = W.Checkbox(parent, CH.Profiles:Label(value))
        cb:SetPoint("TOPLEFT", x + col * colWidth, y - row * 24)
        checks[value] = cb
    end
    return checks, math.ceil(#values / columns) * 24
end

function Page:BuildEditor(frame)
    local ed = W.CreatePanel(frame, W.COLORS.inset, 0.5)
    ed:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, frame.contentTop)
    ed:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)
    ed:Hide()
    frame.editor = ed

    local heading = W.Heading(ed, L["My profile"])
    heading:SetPoint("TOPLEFT", 14, -12)
    local hint = W.Label(ed, L["Everything is optional. Shared with your guild while sharing is on."],
        "GameFontHighlightSmall", W.COLORS.muted)
    hint:SetPoint("LEFT", heading, "RIGHT", 12, 0)

    local y = -44
    local function section(title)
        local label = W.Label(ed, title, "GameFontNormal")
        label:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        label:SetPoint("TOPLEFT", 14, y)
        y = y - 20
    end
    local height
    section(L["Preferred roles"])
    ed.roles, height = checkGrid(ed, CH.Profiles.ROLES, 3, 120, 12, y)
    y = y - height - 6
    section(L["Interests"])
    ed.interests, height = checkGrid(ed, CH.Profiles.INTERESTS, 5, 120, 12, y)
    y = y - height - 6
    section(L["Usually available"])
    ed.days, height = checkGrid(ed, CH.Profiles.DAYS, 7, 72, 12, y)
    y = y - height
    ed.times, height = checkGrid(ed, CH.Profiles.TIMES, 4, 120, 12, y)
    y = y - height - 8

    section(L["Main character (fill this in on an alt)"])
    ed.main = W.EditBox(ed, 220, 48)
    ed.main:SetPoint("TOPLEFT", 20, y)
    y = y - 32
    section(L["Note"])
    ed.note = W.EditBox(ed, 460, CH.Profiles.NOTE_MAX)
    ed.note:SetPoint("TOPLEFT", 20, y)
    y = y - 34

    ed.share = W.Checkbox(ed, L["Share my profile with the guild"],
        L["When off, guildmates' copies of your profile are removed and nothing is sent."])
    ed.share:SetPoint("TOPLEFT", 12, y)

    ed.error = W.Label(ed, "", "GameFontHighlightSmall")
    ed.error:SetTextColor(1, 0.4, 0.4)
    ed.error:SetPoint("BOTTOMLEFT", 14, 44)
    ed.error:SetPoint("RIGHT", ed, "RIGHT", -14, 0)

    local save = W.Button(ed, L["Save"], 100, function() Page:SaveEditor() end)
    save:SetPoint("BOTTOMLEFT", 14, 12)
    local cancel = W.Button(ed, L["Cancel"], 100, function() Page:CloseEditor() end)
    cancel:SetPoint("LEFT", save, "RIGHT", 8, 0)
    local reset = W.Button(ed, L["Clear profile"], 120, function()
        CH.Profiles:ResetMine()
        Page:CloseEditor()
    end)
    reset:SetPoint("BOTTOMRIGHT", -14, 12)
end

function Page:OpenEditor()
    local ed = self.frame.editor
    local mine = CH.Profiles:Mine()
    for field, checks in pairs({ roles = ed.roles, interests = ed.interests, days = ed.days, times = ed.times }) do
        local set = {}
        for _, v in ipairs(mine[field] or {}) do set[v] = true end
        for value, cb in pairs(checks) do cb:SetChecked(set[value] == true) end
    end
    ed.main:SetText(mine.main or "")
    ed.note:SetText(mine.note or "")
    ed.share:SetChecked(CH.Profiles:IsSharing())
    ed.error:SetText("")
    self.frame.list:Hide()
    self.frame.detail:Hide()
    self.frame.toolbar:Hide()
    ed:Show()
end

function Page:CloseEditor()
    local frame = self.frame
    frame.editor:Hide()
    frame.list:Show()
    frame.detail:Show()
    frame.toolbar:Show()
    self:Refresh()
end

function Page:SaveEditor()
    local ed = self.frame.editor
    local fields = {}
    for field, checks in pairs({ roles = ed.roles, interests = ed.interests, days = ed.days, times = ed.times }) do
        local list = {}
        for value, cb in pairs(checks) do
            if cb:GetChecked() then list[#list + 1] = value end
        end
        fields[field] = list
    end
    fields.main = ed.main:GetText()
    fields.note = ed.note:GetText()
    -- Apply the sharing choice first so the save publishes (or retracts) accordingly.
    CH.Settings:Set("profile.share", ed.share:GetChecked() and true or false)
    local ok, reason = CH.Profiles:SaveMine(fields)
    if not ok then
        ed.error:SetText(reason or L["Could not save."])
        return
    end
    self.selected = CH.Identity:PlayerKey()
    self:CloseEditor()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Members"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(26)
    frame.toolbar = toolbar
    local search = W.EditBox(toolbar, 180, 40, function(text)
        Page.filters.text = text
        Page:Refresh()
    end)
    search:SetPoint("LEFT", 6, 0)
    frame.search = search
    local searchHint = W.Label(toolbar, L["Search"], "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", search, "LEFT", 4, 0)
    search:HookScript("OnTextChanged", function(self) searchHint:SetShown(self:GetText() == "") end)
    frame.onlineOnly = W.Checkbox(toolbar, L["Online"], nil, function(v) Page.filters.online = v; Page:Refresh() end)
    frame.onlineOnly:SetPoint("LEFT", search, "RIGHT", 12, 0)
    frame.addonOnly = W.Checkbox(toolbar, L["Casual Hub users"], nil, function(v) Page.filters.addon = v; Page:Refresh() end)
    frame.addonOnly:SetPoint("LEFT", frame.onlineOnly, "RIGHT", 70, 0)
    local edit = W.Button(toolbar, L["Edit my profile"], 130, function() Page:OpenEditor() end)
    edit:SetPoint("RIGHT", 0, 0)

    local listTop = y - 34
    local list = W.List(frame, ROW_HEIGHT, createRow, updateRow)
    list:SetPoint("TOPLEFT", 20, listTop)
    list:SetPoint("BOTTOMLEFT", 20, 16)
    frame.list = list

    local detail = W.CreatePanel(frame, W.COLORS.inset, 0.5)
    detail:SetPoint("TOPRIGHT", -20, listTop)
    detail:SetPoint("BOTTOMRIGHT", -20, 16)
    frame.detail = detail
    frame.detailTitle = W.Label(detail, "", "GameFontNormalLarge")
    frame.detailTitle:SetPoint("TOPLEFT", 14, -12)
    frame.detailBody = W.Label(detail, "", "GameFontHighlight")
    frame.detailBody:SetPoint("TOPLEFT", frame.detailTitle, "BOTTOMLEFT", 0, -10)
    frame.detailBody:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
    frame.detailBody:SetJustifyV("TOP")
    frame.detailBody:SetSpacing(3)

    local function layout()
        local width = frame:GetWidth() or 700
        local detailWidth = math.max(240, math.floor((width - 40) * 0.42))
        detail:SetWidth(detailWidth)
        list:SetPoint("RIGHT", detail, "LEFT", -12, 0)
        list:Refresh()
    end
    frame:SetScript("OnSizeChanged", layout)
    layout()

    self:BuildEditor(frame)
end

function Page:OnShow()
    CH.Roster:Request()
    CH.Roster:Scan()
    if not self.selected then self.selected = CH.Identity:PlayerKey() end
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.2.0",
    description = L["Guild roster and member profiles page"],
    dependencies = { "Profiles" },
    initialize = function()
        CH.UI:RegisterPage("members", {
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        local refresh = function() Page:Refresh() end
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, refresh)
        CH.Events:Subscribe("PROFILE_SAVED", MODULE, refresh)
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "profile" then Page:Refresh() end
        end)
    end,
})

CH.MembersPage = Page  -- exposed for tests and diagnostics only
