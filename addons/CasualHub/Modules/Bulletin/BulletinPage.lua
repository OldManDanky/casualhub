-- Bulletin page (design doc §4.6, §4.7, §5). Views:
--   Notices       announcements and guild rules; unread marked; officers post, pin and edit their own
--   Welcome       the guild's welcome checklist (progress is yours alone) and the pinned guild rules
--   Reports       officers only: weekly participation trends, copyable as CSV
--   Guild policy  set by the guild master: which ranks are officers, who may post notices, the checklist
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD
local B = CH.Bulletin
local Analytics = CH.Analytics

local Page = { view = "notices", showExpired = false }
local MODULE = "BulletinPage"
local ROW_HEIGHT = 24

local function coloredName(name)
    local m = CH.Roster:Get(name)
    return "|c" .. CH.ClassColorHex(m and m.class) .. name .. "|r"
end

local function kindTag(kind)
    return kind == "rule" and "|cffb48ee0" .. B:Label("rule") .. "|r" or "|cff6fa8dc" .. B:Label("announcement") .. "|r"
end

local function canSeeReports() return CH.Permissions:Can("viewReports") end

local ROLE_CYCLE = { "member", "officer" }

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
    row.right = W.Label(row, "", "GameFontHighlightSmall", W.COLORS.muted)
    row.right:SetPoint("RIGHT", -4, 0)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWidth(110)
    row.left = W.Label(row, "", "GameFontHighlight")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetWordWrap(false)
    row:SetScript("OnClick", function(self) Page:Click(self.item) end)
    return row
end

local function updateRow(row, item)
    row.item = item
    local left, right, selected = Page:RowText(item)
    row.left:SetText(left)
    row.right:SetText(right or "")
    row.selected:SetShown(selected and true or false)
end

function Page:RowText(item)
    if self.view == "notices" then
        local n = item
        local unread = not B:IsRead(n)
        local mark = (n.pinned and "|cffd4af37[!]|r " or "") .. (unread and "|cff7fd17f*|r " or "")
        local title = unread and ("|cffffffff" .. n.title .. "|r") or ("|cffbbbbbb" .. n.title .. "|r")
        return mark .. kindTag(n.kind) .. "  " .. title, CH.FormatAgo(n.updatedAt, CH.ServerTime()),
            self.selectedNotice == n.id
    elseif self.view == "welcome" then
        local checked = B:IsChecked(item)
        return (checked and "|cff7fd17f[x]|r  |cff999999" or "|cffbbbbbb[  ]|r  |cffffffff") .. item .. "|r",
            checked and L["done"] or ""
    elseif self.view == "reports" then
        local r = item
        local t = {}
        for y, m, d in r.week:gmatch("(%d+)-(%d+)-(%d+)") do t = { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 } end
        return ("%s  |cffbbbbbb%s|r"):format(date("%d %b", time(t)),
            (L["%d event(s), %d attendee(s), %d request(s)"]):format(r.events, r.attendees, r.activitiesPosted + r.craftPosted)),
            (L["%d user(s)"]):format(r.users), self.selectedWeek == r.week
    else
        local rank = item
        local role = self:DraftRole(rank.index)
        local roleText = rank.index == 0 and ("|cffd4af37" .. CH.Permissions:RoleLabel("guildmaster") .. "|r")
            or (role == "officer" and ("|cff7fd17f" .. CH.Permissions:RoleLabel("officer") .. "|r")
            or CH.Permissions:RoleLabel("member"))
        return ("%d. %s"):format(rank.index + 1, rank.name), roleText
    end
end

function Page:Click(item)
    if self.view == "notices" then
        self.selectedNotice = item.id
        B:MarkRead(item)
    elseif self.view == "welcome" then
        B:SetChecked(item, not B:IsChecked(item))
    elseif self.view == "reports" then
        self.selectedWeek = item.week
    elseif B:IsGuildMaster() and item.index ~= 0 then
        -- Guild policy: clicking a rank flips it between member and officer in the draft.
        local current = self:DraftRole(item.index)
        self.draft.rankRoles[tostring(item.index)] = current == "officer" and "member" or "officer"
        self.dirty = true
    end
    self:Refresh()
end

function Page:BuildItems()
    if self.view == "notices" then return B:List(self.showExpired) end
    if self.view == "welcome" then return B:Checklist() end
    if self.view == "reports" then return canSeeReports() and Analytics:Report() or {} end
    return B:Ranks()
end

---------------------------------------------------------------------------
-- Policy draft (guild master)
---------------------------------------------------------------------------

function Page:ResetDraft()
    local p = B:Policy()
    self.draft = {
        rankRoles = CH.Store.DeepCopy(p and p.rankRoles or {}),
        noticeRole = p and p.noticeRole or "officer",
        checklist = CH.Store.DeepCopy(p and p.checklist or {}),
    }
    self.dirty = false
end

-- Role a rank has in the draft, falling back to what applies now.
function Page:DraftRole(index)
    if index == 0 then return "guildmaster" end
    local r = self.draft and self.draft.rankRoles[tostring(index)]
    if r then return r end
    return CH.Permissions:RoleForRank(index)
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

local function setActions(buttons)
    local f = Page.frame
    for _, b in ipairs(f.actionButtons) do b:Hide() end
    for i, spec in ipairs(buttons) do
        local b = f.actionButtons[i]
        if b then
            b:SetText(spec[1])
            b.fn = spec[2]
            b:Show()
        end
    end
end

function Page:RenderNotice()
    local f = self.frame
    local n = self.selectedNotice and B:Get(self.selectedNotice)
    local buttons = {}
    if not n then
        f.detailTitle:SetText(L["Guild notices"])
        f.detailBody:SetText("|cff999999" .. (B:CanPost() and L["Pick a notice, or post one with New notice."]
            or L["Pick a notice to read it. Officers post announcements and guild rules here."]) .. "|r")
        if B:UnreadCount() > 0 then buttons[#buttons + 1] = { L["Mark all read"], function() B:MarkAllRead() end } end
        setActions(buttons)
        return
    end
    f.detailTitle:SetText((n.pinned and "|cffd4af37[!]|r " or "") .. n.title)
    local meta = { kindTag(n.kind), (L["by %s"]):format(coloredName(n.owner)),
        "|cff999999" .. CH.FormatAgo(n.updatedAt, CH.ServerTime()) .. "|r" }
    if n.kind == "announcement" then
        meta[#meta + 1] = "|cff999999" .. ((B:IsActive(n) and L["until %s"] or L["expired %s"]):format(date("%d %b", n.expiresAt))) .. "|r"
    end
    f.detailBody:SetText(table.concat(meta, "  ") .. "\n\n" .. (n.body or ("|cff999999" .. L["(no text)"] .. "|r")))
    if B:IsMine(n) then
        buttons[#buttons + 1] = { L["Edit"], function() Page:OpenEditor(n) end }
        buttons[#buttons + 1] = { n.pinned and L["Unpin"] or L["Pin"], function() B:SetPinned(n.id, not n.pinned) end }
        buttons[#buttons + 1] = { L["Delete"], function()
            B:Delete(n.id)
            Page.selectedNotice = nil
        end }
    end
    if B:UnreadCount() > 0 then buttons[#buttons + 1] = { L["Mark all read"], function() B:MarkAllRead() end } end
    setActions(buttons)
end

function Page:RenderWelcome()
    local f = self.frame
    local done, total = B:ChecklistProgress()
    f.detailTitle:SetText(L["Guild rules"])
    local parts = {}
    if total > 0 then
        parts[#parts + 1] = ("|c%s%s|r %d/%d"):format(GOLD.hex, L["Welcome checklist:"], done, total) ..
            (done == total and ("  |cff7fd17f" .. L["all done"] .. "|r") or ("  |cff999999" .. L["click an item on the left to tick it"] .. "|r"))
        parts[#parts + 1] = ""
    end
    local rules = B:Rules()
    for _, r in ipairs(rules) do
        parts[#parts + 1] = ("|cffb48ee0%s|r"):format(r.title)
        if r.body then parts[#parts + 1] = r.body end
        parts[#parts + 1] = ""
    end
    if #rules == 0 then parts[#parts + 1] = "|cff999999" .. L["No guild rules posted yet."] .. "|r" end
    f.detailBody:SetText(table.concat(parts, "\n"))
    setActions({})
end

local function categorySummary(byCategory)
    local E = CH.GuildEvents
    local parts = {}
    for cat, n in pairs(byCategory) do parts[#parts + 1] = ("%s %d"):format(E and E:Label(cat) or cat, n) end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or L["none"]
end

function Page:RenderReport()
    local f = self.frame
    if not canSeeReports() then
        f.detailTitle:SetText(L["Reports"])
        f.detailBody:SetText("|cff999999" .. L["Reports are for officers."] .. "|r")
        setActions({})
        return
    end
    local rows = Analytics:Report()
    local r
    for _, row in ipairs(rows) do if row.week == self.selectedWeek then r = row end end
    r = r or rows[1]
    local note = "|cff999999" .. (L["Weekly totals from what your client has seen, kept %d weeks. Counts only, no individual rankings."]):format(Analytics.RETENTION_WEEKS) .. "|r"
    if not r then
        f.detailTitle:SetText(L["Participation"])
        f.detailBody:SetText(L["No data yet. Weeks fill in as events finish and requests are posted."] .. "\n\n" .. note)
        setActions({})
        return
    end
    self.selectedWeek = r.week
    f.detailTitle:SetText((L["Week of %s"]):format(r.week))
    local lines = {}
    local function add(label, value) lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, label, value) end
    add(L["Events run"], ("%d  |cff999999(%s)|r"):format(r.events, categorySummary(r.byCategory)))
    add(L["Average lineup"], ("%.1f"):format(r.avgLineup))
    add(L["Distinct attendees"], tostring(r.attendees))
    add(L["Waitlisted"], tostring(r.waitlist))
    add(L["Cancelled events"], tostring(r.cancelled))
    add(L["Activity requests"], (L["%d posted, %d completed, %d volunteers accepted"]):format(r.activitiesPosted,
        r.activitiesCompleted, r.volunteers))
    add(L["Crafting requests"], (L["%d posted, %d done"]):format(r.craftPosted, r.craftDone))
    add(L["Casual Hub users"], tostring(r.users))
    f.detailBody:SetText(table.concat(lines, "\n") .. "\n\n" .. note)
    setActions({ { L["Copy as CSV"], function() W.CopyDialog(L["Casual Hub report"], Analytics:CSV()) end } })
end

function Page:RenderPolicy()
    local f = self.frame
    local gm = B:IsGuildMaster()
    local p = B:Policy()
    f.detailTitle:SetText(L["Guild policy"])
    local lines = {}
    if p then
        lines[#lines + 1] = ("|cff999999%s|r"):format((L["Set by %s, %s."]):format(coloredName(p.owner),
            CH.FormatAgo(p.updatedAt, CH.ServerTime())))
    else
        lines[#lines + 1] = "|cff999999" .. L["The guild master hasn't published a policy. Defaults apply: the rank below guild master counts as officer."] .. "|r"
    end
    local noticeRole = self.draft.noticeRole
    lines[#lines + 1] = ("|c%s%s|r %s"):format(GOLD.hex, L["Who can post notices:"],
        noticeRole == "member" and L["everyone"] or L["officers and the guild master"])
    if gm then
        lines[#lines + 1] = "|cff999999" .. L["Click a rank on the left to make it officer or member. Edit the welcome checklist below, then Save and share."] .. "|r"
    end
    f.detailBody:SetText(table.concat(lines, "\n"))
    f.policyEditor:SetShown(gm)
    if gm then
        for i, box in ipairs(f.policyEditor.items) do box:SetText(self.draft.checklist[i] or "") end
        local buttons = {
            { noticeRole == "member" and L["Officers post"] or L["Everyone posts"], function()
                Page.draft.noticeRole = Page.draft.noticeRole == "member" and "officer" or "member"
                Page.dirty = true
            end },
            { L["Save and share"], function() Page:SavePolicy() end },
        }
        if self.dirty then buttons[#buttons + 1] = { L["Discard"], function() Page:ResetDraft() end } end
        setActions(buttons)
    else
        setActions({})
    end
end

function Page:SavePolicy()
    local items = {}
    for i = 1, B.CHECKLIST_MAX do
        local text = self.draft.checklist[i]
        if text and text:match("%S") then items[#items + 1] = text end
    end
    self.draft.checklist = items
    local ok, reason = B:SavePolicy(self.draft)
    if not ok then
        CH:Print(reason or L["Could not save."])
        return
    end
    self:ResetDraft()
    CH:Print(L["Guild policy saved and shared."])
end

function Page:RenderDetail()
    self.frame.policyEditor:Hide()
    if self.view == "notices" then self:RenderNotice()
    elseif self.view == "welcome" then self:RenderWelcome()
    elseif self.view == "reports" then self:RenderReport()
    else self:RenderPolicy() end
end

---------------------------------------------------------------------------
-- Views and refresh
---------------------------------------------------------------------------

function Page:SetView(view)
    if view == "reports" and not canSeeReports() then view = "notices" end
    if view == "reports" then CH.SafeCall("analytics", Analytics.Collect, Analytics) end
    if view == "policy" then self:ResetDraft() end
    self.view = view
    local f = self.frame
    f.viewRow:Set(view)
    f.noticeTools:SetShown(view == "notices")
    self:Refresh()
end

function Page:Refresh()
    local f = self.frame
    if not f or not f:IsVisible() or f.editor:IsShown() then return end
    if not self.draft then self:ResetDraft() end
    f.viewRow.buttons.reports:SetShown(canSeeReports())
    f.newNotice:SetShown(B:CanPost())
    local items = self:BuildItems()
    f.list:SetItems(items)
    local unread = B:UnreadCount()
    f.subtitle:SetText((L["%d notice(s), %d unread."]):format(#B:List(), unread))
    local empty = {
        notices = L["No notices yet."],
        welcome = L["The guild master hasn't set a welcome checklist."],
        reports = L["No report data yet."],
        policy = L["Guild ranks aren't available yet."],
    }
    f.empty:SetText(empty[self.view])
    f.empty:SetShown(#items == 0)
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Notice editor
---------------------------------------------------------------------------

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
    label(L["Type"])
    ed.kind = W.ToggleRow(ed, B.KINDS, function(v) return B:Label(v) end, 120, function(v)
        for _, b in pairs(ed.expiry.buttons) do b:SetShown(v == "announcement") end
        ed.expiryLabel:SetShown(v == "announcement")
    end)
    ed.kind:Anchor("TOPLEFT", 14, y - 18)
    ed.expiryLabel = label(L["Show for"], 300)
    ed.expiry = W.ToggleRow(ed, B.EXPIRY_DAYS, function(d) return (L["%d days"]):format(d) end, 70)
    ed.expiry:Anchor("TOPLEFT", 300, y - 18)
    y = y - 48

    label(L["Title"])
    ed.title = W.EditBox(ed, 420, B.TITLE_MAX)
    ed.title:SetPoint("TOPLEFT", 20, y - 18)
    ed.pinned = W.Checkbox(ed, L["Pin to the top"], L["Pinned notices stay first, and online guildmates get one chat line."])
    ed.pinned:SetPoint("LEFT", ed.title, "RIGHT", 16, 0)
    y = y - 48

    label(L["Text (Enter for a new line, up to 12 lines)"])
    ed.body = W.TextArea(ed, 600, 150, B.BODY_MAX)
    ed.body:SetPoint("TOPLEFT", 14, y - 18)

    ed.error = W.Label(ed, "", "GameFontHighlightSmall")
    ed.error:SetTextColor(1, 0.4, 0.4)
    ed.error:SetPoint("BOTTOMLEFT", 14, 44)
    ed.error:SetPoint("RIGHT", ed, "RIGHT", -14, 0)
    ed.save = W.Button(ed, L["Post"], 100, function() Page:SaveEditor() end)
    ed.save:SetPoint("BOTTOMLEFT", 14, 12)
    local cancel = W.Button(ed, L["Cancel"], 100, function() Page:CloseEditor() end)
    cancel:SetPoint("LEFT", ed.save, "RIGHT", 8, 0)
end

function Page:OpenEditor(n)
    local ed = self.frame.editor
    self.editing = n and n.id or nil
    ed.heading:SetText(n and L["Edit notice"] or L["New notice"])
    ed.save:SetText(n and L["Save"] or L["Post"])
    ed.kind:Set(n and n.kind or "announcement")
    local days = 14
    if n and n.expiresAt then
        local left = (n.expiresAt - CH.ServerTime()) / 86400
        for _, d in ipairs(B.EXPIRY_DAYS) do if left >= d - 0.5 then days = d end end
    end
    ed.expiry:Set(days)
    local isAnnouncement = ed.kind.value == "announcement"
    for _, b in pairs(ed.expiry.buttons) do b:SetShown(isAnnouncement) end
    ed.expiryLabel:SetShown(isAnnouncement)
    ed.title:SetText(n and n.title or "")
    ed.pinned:SetChecked(n and n.pinned or false)
    ed.body:SetText(n and n.body or "")
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
    if CH.CleanText(ed.title:GetText(), B.TITLE_MAX) == "" then
        ed.error:SetText(L["Give the notice a title."])
        return
    end
    local fields = { kind = ed.kind.value, title = ed.title:GetText(), body = ed.body:GetText(),
        pinned = ed.pinned:GetChecked() and true or nil,
        expiresAt = ed.kind.value == "announcement" and (CH.ServerTime() + ed.expiry.value * 86400) or nil }
    local ok, reason
    if self.editing then
        ok, reason = B:Update(self.editing, fields)
        if ok then ok = self.editing end
    else
        ok, reason = B:Post(fields)
    end
    if not ok then
        ed.error:SetText(reason or L["Could not save."])
        return
    end
    self.selectedNotice = ok
    self:CloseEditor()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Bulletin"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(54)
    frame.toolbar = toolbar
    frame.viewRow = W.ToggleRow(toolbar, { "notices", "welcome", "reports", "policy" }, function(v)
        return ({ notices = L["Notices"], welcome = L["Welcome"], reports = L["Reports"], policy = L["Guild policy"] })[v]
    end, 110, function(v) Page:SetView(v) end)
    frame.viewRow:Anchor("TOPLEFT", 0, 0)

    local nt = CreateFrame("Frame", nil, toolbar)
    nt:SetPoint("TOPLEFT", 0, -28)
    nt:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    nt:SetHeight(26)
    frame.noticeTools = nt
    frame.showExpired = W.Checkbox(nt, L["Show expired"], L["Include announcements that have expired."],
        function(v) Page.showExpired = v; Page:Refresh() end)
    frame.showExpired:SetPoint("LEFT", 0, 0)
    frame.notifyNotices = W.Checkbox(nt, L["Tell me about new notices"],
        L["One chat line at login when there are unread notices, and one when a pinned notice is posted."],
        function(v) CH.Settings:Set("notifications.notices", v) end)
    frame.notifyNotices:SetPoint("LEFT", frame.showExpired, "RIGHT", 110, 0)
    frame.newNotice = W.Button(nt, L["New notice"], 130, function() Page:OpenEditor(nil) end)
    frame.newNotice:SetPoint("RIGHT", 0, 0)

    local listTop = y - 62
    local list = W.List(frame, ROW_HEIGHT, createRow, updateRow)
    list:SetPoint("TOPLEFT", 20, listTop)
    list:SetPoint("BOTTOMLEFT", 20, 16)
    frame.list = list
    frame.empty = W.Label(frame, "", "GameFontHighlight", W.COLORS.muted)
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

    frame.actionButtons = {}
    for i = 1, 6 do
        local b = W.Button(detail, "", 120, function(self)
            if self.fn then CH.SafeCall("bulletin action", self.fn) end
            Page:Refresh()
        end)
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        b:SetPoint("BOTTOMLEFT", 12 + col * 124, 10 + (1 - row) * 26)
        b:Hide()
        frame.actionButtons[i] = b
    end

    -- Welcome checklist editor (guild master, Guild policy view).
    local pe = CreateFrame("Frame", nil, detail)
    pe:SetPoint("BOTTOMLEFT", 14, 66)
    pe:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
    pe:SetHeight(20 + B.CHECKLIST_MAX * 24)
    pe:Hide()
    frame.policyEditor = pe
    local heading = W.Label(pe, L["Welcome checklist (optional)"], "GameFontNormal")
    heading:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
    heading:SetPoint("TOPLEFT", 0, 0)
    pe.items = {}
    for i = 1, B.CHECKLIST_MAX do
        local box = W.EditBox(pe, 320, B.CHECKLIST_ITEM_MAX, function(text)
            Page.draft.checklist[i] = text
            Page.dirty = true
        end)
        box:SetPoint("TOPLEFT", 6, -16 - (i - 1) * 24)
        pe.items[i] = box
    end

    local function layout()
        local width = frame:GetWidth() or 700
        detail:SetWidth(math.max(380, math.floor((width - 40) * 0.52)))
        list:SetPoint("RIGHT", detail, "LEFT", -12, 0)
        list:Refresh()
    end
    frame:SetScript("OnSizeChanged", layout)
    layout()

    self:BuildEditor(frame)
    self:ResetDraft()
    self:SetView(self.view)
end

function Page:OnShow()
    self.frame.notifyNotices:SetChecked(CH.Settings:Get("notifications.notices") ~= false)
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.6.0",
    description = L["Bulletin page"],
    dependencies = { "Bulletin", "Analytics" },
    initialize = function()
        CH.UI:RegisterPage("bulletin", {
            minHeight = 570,  -- scrolls on shorter windows (UI:CreatePageFrame)
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "notice" or typeName == "policy" then CH.Debounce(MODULE, 0.2, function() Page:Refresh() end) end
        end)
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, function() Page:Refresh() end)
        B:UpdateBadge()
    end,
})

CH.BulletinPage = Page  -- exposed for tests
