-- Blacklist page: who's listed and why, adding your own entries, officer clearances, and warning toggles.
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD
local BL = CH.Blacklist

local Page = { filter = "", showCleared = false }
local MODULE = "BlacklistPage"
local ROW_HEIGHT = 24
local MAX_ENTRY_LINES = 8

local function coloredName(name)
    local m = CH.Roster:Get(name)
    if not m then return "|cffffffff" .. name .. "|r" end
    return "|c" .. CH.ClassColorHex(m.class) .. name .. "|r"
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

function Page:BuildItems()
    local needle = self.filter:lower()
    local items = {}
    for _, item in ipairs(BL:List(self.showCleared)) do
        local hay = item.target:lower()
        for _, e in ipairs(item.entries) do hay = hay .. " " .. e.reason:lower() .. " " .. e.owner:lower() end
        if needle == "" or hay:find(needle, 1, true) then items[#items + 1] = item end
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
    row.right = W.Label(row, "", "GameFontHighlightSmall", W.COLORS.muted)
    row.right:SetPoint("RIGHT", -4, 0)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWidth(80)
    row.left = W.Label(row, "", "GameFontHighlight")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
        Page.selected = self.item.target
        Page:Refresh()
    end)
    return row
end

local function updateRow(row, item)
    row.item = item
    if item.cleared then
        row.left:SetText(("|cff999999%s  %s|r"):format(item.target, L["(cleared by an officer)"]))
    else
        local e = item.entries[1]
        row.left:SetText(("|cffff6060%s|r  |cffbbbbbb%s|r%s"):format(item.target, e.reason,
            #item.entries > 1 and ("  |cff999999" .. (L["+%d more"]):format(#item.entries - 1) .. "|r") or ""))
    end
    row.right:SetText(CH.FormatAgo(item.latest, CH.ServerTime()))
    row.selected:SetShown(item.target == Page.selected)
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

function Page:RenderDetail()
    local f = self.frame
    local target = self.selected
    local entries = target and BL:Entries(target) or {}
    local clearedAt, clearedBy = nil, nil
    if target then clearedAt, clearedBy = BL:Clearance(target) end
    if not target or (#entries == 0 and not clearedAt) then
        f.detailTitle:SetText(L["Guild blacklist"])
        f.detailBody:SetText("|cff999999" .. L["Players guildmates have flagged, with their reasons. You'll get a warning when one is in your group, invites you, whispers or trades with you, and in their tooltip. Add someone with Add player."] ..
            "\n\n" .. L["Entries are shared with every guildmate running Casual Hub. Keep reasons short and factual."] .. "|r")
        setActions({})
        return
    end
    f.detailTitle:SetText(("|cffff6060%s|r"):format(target))
    local lines = {}
    if #entries == 0 then
        lines[#lines + 1] = "|cff999999" .. L["No entries in force."] .. "|r"
    end
    for i = 1, math.min(#entries, MAX_ENTRY_LINES) do
        local e = entries[i]
        lines[#lines + 1] = ("%s  |cff999999%s|r\n   %s"):format(coloredName(e.owner),
            CH.FormatAgo(e.updatedAt, CH.ServerTime()), e.reason)
    end
    if #entries > MAX_ENTRY_LINES then
        lines[#lines + 1] = "|cff999999" .. (L["and %d more"]):format(#entries - MAX_ENTRY_LINES) .. "|r"
    end
    if clearedAt then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("|cff999999%s|r"):format((L["Earlier entries cleared by %s, %s."]):format(clearedBy,
            CH.FormatAgo(clearedAt, CH.ServerTime())))
    end
    f.detailBody:SetText(table.concat(lines, "\n"))

    local buttons = {}
    local mine = BL:MyEntry(target)
    local active = mine and (not clearedAt or mine.updatedAt > clearedAt)
    buttons[#buttons + 1] = { active and L["Edit my reason"] or L["Add my reason"], function()
        Page:OpenEditor(target, active and mine.reason or "")
    end }
    if mine then buttons[#buttons + 1] = { L["Remove mine"], function() BL:Remove(target) end } end
    if BL:CanClear() then
        local me = CH.Identity:PlayerKey()
        local myClear = me and CH.Sync:Get("blclear", me .. "|" .. target)
        if #entries > 0 then
            buttons[#buttons + 1] = { L["Clear for everyone"], function() BL:Clear(target) end }
        end
        if myClear and not myClear.deleted then
            buttons[#buttons + 1] = { L["Undo my clear"], function() BL:Unclear(target) end }
        end
    end
    setActions(buttons)
end

function Page:Refresh()
    local f = self.frame
    if not f or not f:IsVisible() or f.editor:IsShown() then return end
    local items = self:BuildItems()
    f.list:SetItems(items)
    f.subtitle:SetText((L["%d player(s) listed. Shared with guildmates using Casual Hub."]):format(BL:Count()))
    f.empty:SetText(self.filter ~= "" and L["No matches."] or L["Nobody is listed."])
    f.empty:SetShown(#items == 0)
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Editor
---------------------------------------------------------------------------

function Page:BuildEditor(frame)
    local ed = W.CreatePanel(frame, W.COLORS.inset, 0.5)
    ed:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, frame.contentTop)
    ed:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)
    ed:Hide()
    frame.editor = ed
    ed.heading = W.Heading(ed, L["Add to the blacklist"])
    ed.heading:SetPoint("TOPLEFT", 14, -12)

    local function label(text, y)
        local l = W.Label(ed, text, "GameFontNormal")
        l:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        l:SetPoint("TOPLEFT", 14, y)
        return l
    end
    label(L["Player (full name, e.g. First Last)"], -44)
    ed.name = W.EditBox(ed, 260, BL.NAME_MAX)
    ed.name:SetPoint("TOPLEFT", 20, -62)
    ed.useTarget = W.Button(ed, L["Use my target"], 120, function()
        local key = BL.UnitKey("target")
        if key then ed.name:SetText(key) else ed.error:SetText(L["Target a player first."]) end
    end)
    ed.useTarget:SetPoint("LEFT", ed.name, "RIGHT", 10, 0)

    label(L["Reason (short and factual; every guildmate with Casual Hub sees it)"], -96)
    ed.reason = W.EditBox(ed, 600, BL.REASON_MAX)
    ed.reason:SetPoint("TOPLEFT", 20, -114)

    ed.error = W.Label(ed, "", "GameFontHighlightSmall")
    ed.error:SetTextColor(1, 0.4, 0.4)
    ed.error:SetPoint("BOTTOMLEFT", 14, 44)
    ed.error:SetPoint("RIGHT", ed, "RIGHT", -14, 0)
    ed.save = W.Button(ed, L["Save"], 100, function() Page:SaveEditor() end)
    ed.save:SetPoint("BOTTOMLEFT", 14, 12)
    local cancel = W.Button(ed, L["Cancel"], 100, function() Page:CloseEditor() end)
    cancel:SetPoint("LEFT", ed.save, "RIGHT", 8, 0)
end

function Page:OpenEditor(target, reason)
    local f, ed = self.frame, self.frame.editor
    ed.name:SetText(target or "")
    ed.reason:SetText(reason or "")
    ed.error:SetText("")
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
    self:Refresh()
end

function Page:SaveEditor()
    local ed = self.frame.editor
    local ok, result = BL:Add(ed.name:GetText(), ed.reason:GetText())
    if not ok then
        ed.error:SetText(result or L["Could not save."])
        return
    end
    self.selected = result
    self:CloseEditor()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Blacklist"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(54)
    frame.toolbar = toolbar
    frame.search = W.EditBox(toolbar, 200, 40, function(text)
        Page.filter = text or ""
        Page:Refresh()
    end)
    frame.search:SetPoint("TOPLEFT", 6, 0)
    local hint = W.Label(toolbar, L["name or reason"], "GameFontHighlightSmall", W.COLORS.muted)
    hint:SetPoint("LEFT", frame.search, "RIGHT", 6, 0)
    frame.showCleared = W.Checkbox(toolbar, L["Show cleared"], L["Include players whose entries an officer cleared."],
        function(v) Page.showCleared = v; Page:Refresh() end)
    frame.showCleared:SetPoint("LEFT", hint, "RIGHT", 16, 0)
    frame.add = W.Button(toolbar, L["Add player"], 120, function() Page:OpenEditor(BL.UnitKey("target"), "") end)
    frame.add:SetPoint("TOPRIGHT", 0, 0)

    -- Warning toggles.
    local warnLabel = W.Label(toolbar, L["Warn me:"], "GameFontHighlightSmall", W.COLORS.muted)
    warnLabel:SetPoint("TOPLEFT", 0, -34)
    frame.warn = {}
    local prev = warnLabel
    for _, spec in ipairs({
        { "group", L["in my group"], L["A popup when a listed player is in your party or raid."] },
        { "invite", L["invites"], L["A popup when a listed player invites you to a group."] },
        { "tooltip", L["tooltips"], L["A red line in a listed player's tooltip."] },
        { "chat", L["whispers and trades"], L["A chat line when a listed player whispers you or opens a trade."] },
    }) do
        local cb = W.Checkbox(toolbar, spec[2], spec[3], function(v) CH.Settings:Set("blacklist.warn." .. spec[1], v) end)
        cb:SetPoint("LEFT", prev, prev == warnLabel and "RIGHT" or "RIGHT", prev == warnLabel and 8 or 100, 0)
        frame.warn[spec[1]] = cb
        prev = cb
    end

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
    for i = 1, 4 do
        local b = W.Button(detail, "", 140, function(self)
            if self.fn then CH.SafeCall("blacklist action", self.fn) end
            Page:Refresh()
        end)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        b:SetPoint("BOTTOMLEFT", 12 + col * 144, 10 + (1 - row) * 26)
        b:Hide()
        frame.actionButtons[i] = b
    end

    local function layout()
        local width = frame:GetWidth() or 700
        detail:SetWidth(math.max(320, math.floor((width - 40) * 0.48)))
        list:SetPoint("RIGHT", detail, "LEFT", -12, 0)
        list:Refresh()
    end
    frame:SetScript("OnSizeChanged", layout)
    layout()
    self:BuildEditor(frame)
end

function Page:OnShow()
    for kind, cb in pairs(self.frame.warn) do cb:SetChecked(CH.Settings:Get("blacklist.warn." .. kind) ~= false) end
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.7.0",
    description = L["Blacklist page"],
    dependencies = { "Blacklist" },
    initialize = function()
        CH.UI:RegisterPage("blacklist", {
            minHeight = 380,  -- scrolls on shorter windows (UI:CreatePageFrame)
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "blacklist" or typeName == "blclear" then
                CH.Debounce(MODULE, 0.2, function() Page:Refresh() end)
            end
        end)
    end,
})

CH.BlacklistPage = Page  -- exposed for tests
