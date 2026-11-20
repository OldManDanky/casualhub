-- Professions page (design doc §4.5, §5). Three views:
--   Find crafters   search recipes and crafters; detail shows a crafter's recipe list, source and age
--   Requests        crafting and material requests; guildmates offer to help
--   My professions  what you share: scanned professions, specialties, notes, manual entries
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD
local P = CH.Professions

local Page = { view = "crafters", filters = { text = "", skillLine = nil, online = false, mine = false, done = false } }
local MODULE = "ProfessionsPage"
local ROW_HEIGHT = 24
local LINE_HEIGHT = 18
local MAX_OFFER_ROWS = 5

local function coloredName(name)
    local m = CH.Roster:Get(name)
    return "|c" .. CH.ClassColorHex(m and m.class) .. name .. "|r"
end

local function whisper(name)
    if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. (name:gsub(" ", "-")) .. " ") end
end

local function skillText(r)
    if r.skill and r.maxSkill and r.maxSkill > 0 then return ("%d/%d"):format(r.skill, r.maxSkill) end
    if r.skill then return tostring(r.skill) end
    return ""
end

-- "profession window, 3d ago" / "entered by hand"
local function sourceText(r)
    if r.source == "manual" then return P:Label("manual") end
    local at = r.scannedAt or r.updatedAt
    return P:Label("scan") .. (at and (", " .. CH.FormatAgo(at, CH.ServerTime())) or "")
end

local function onlineDot(name, isLocal)
    if isLocal or CH.Roster:IsOnline(name) then return "|cff7fd17f*|r " end
    return "|cff555555*|r "
end

-- A button that steps through a list of values (used where a toggle row would be too wide).
local function cycleButton(parent, width, values, labelOf, onChange)
    local b = W.Button(parent, "", width)
    b.values, b.index = values, 1
    function b:SetValues(list)
        self.values = list
        self.index = math.min(self.index, #list)
        if self.index < 1 then self.index = 1 end
        self:SetText(labelOf(self.values[self.index]))
    end
    function b:Get() return self.values[self.index] end
    function b:Set(value)
        for i, v in ipairs(self.values) do if v == value then self.index = i end end
        self:SetText(labelOf(self.values[self.index]))
    end
    b:SetScript("OnClick", function(self, button)
        local n = #self.values
        if n == 0 then return end
        self.index = (button == "RightButton") and ((self.index - 2) % n + 1) or (self.index % n + 1)
        self:SetText(labelOf(self.values[self.index]))
        if onChange then CH.SafeCall("cycle", onChange, self.values[self.index]) end
    end)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetValues(values)
    return b
end

local function professionLabel(skillLine)
    return skillLine == "all" and L["All professions"] or P:Name(skillLine)
end

---------------------------------------------------------------------------
-- Shared list + detail scaffold
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
    row.right:SetWidth(120)
    row.left = W.Label(row, "", "GameFontHighlight")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetWordWrap(false)
    row:SetScript("OnClick", function(self) Page:Select(self.item) end)
    return row
end

local function updateRow(row, item)
    row.item = item
    local left, right = Page:RowText(item)
    row.left:SetText(left)
    row.right:SetText(right)
    row.selected:SetShown(Page:IsSelected(item))
end

local function createLine(list)
    local row = CreateFrame("Frame", nil, list)
    row.text = W.Label(row, "", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", -4, 0)
    row.text:SetWordWrap(false)
    return row
end

local function updateLine(row, item)
    row.text:SetText(item)
end

---------------------------------------------------------------------------
-- Rows per view
---------------------------------------------------------------------------

function Page:RowText(item)
    if self.view == "crafters" then
        local r = item.record
        local prof = ("|cffbbbbbb%s %s|r"):format(P:Name(r.skillLine, r.name), skillText(r))
        if item.recipeName then
            return ("%s  |cff999999-|r %s%s  %s"):format(item.recipeName, onlineDot(r.owner, r._local),
                coloredName(r.owner), prof), sourceText(r)
        end
        local count = #P:RecipesOf(r)
        return ("%s%s  %s%s"):format(onlineDot(r.owner, r._local), coloredName(r.owner), prof,
            r.specialty and ("  |cffd4af37" .. r.specialty .. "|r") or ""),
            count > 0 and (L["%d recipes"]):format(count) or sourceText(r)
    elseif self.view == "requests" then
        local q = item
        local status = P:EffectiveStatus(q)
        local mark = P:IsMine(q) and "|cffd4af37*|r " or (P:MyOffer(q.id) and P:MyOffer(q.id).state == "offered"
            and "|cff7fd17f+|r " or "")
        local kind = q.kind == "materials" and "|cff93c47d" .. P:Label("materials") .. "|r" or "|cff6fa8dc" .. P:Label("craft") .. "|r"
        return ("%s%s  %s%s  |cff999999%s|r"):format(mark, kind, q.title, q.quantity and (" x" .. q.quantity) or "",
            q.owner), (status == "open" and (L["%d offer(s)"]):format(P:ActiveOfferCount(q)) or
            ("|cff999999" .. P:Label(status) .. "|r"))
    else
        local e = item
        local count = e.recipes and #(P.DecodeRecipes(e.recipes) or {}) or 0
        return ("%s  |cffbbbbbb%s|r%s"):format(P:Name(e.skillLine, e.name), skillText(e),
            e.specialty and ("  |cffd4af37" .. e.specialty .. "|r") or ""),
            e.source == "manual" and P:Label("manual") or (L["%d recipes"]):format(count)
    end
end

function Page:IsSelected(item)
    if self.view == "crafters" then return self.selectedCraft == item.record.id end
    if self.view == "requests" then return self.selectedRequest == item.id end
    return self.selectedMine == item.skillLine
end

function Page:Select(item)
    if self.view == "crafters" then
        self.selectedCraft = item.record.id
        self.selectedRecipe = item.recipeID
    elseif self.view == "requests" then
        self.selectedRequest = item.id
    else
        self.selectedMine = item.skillLine
    end
    self:Refresh()
end

function Page:BuildItems()
    if self.view == "crafters" then
        local f = self.filters
        return P:Search(f.text, f.skillLine, f.online)
    elseif self.view == "requests" then
        local items, now = {}, CH.ServerTime()
        for _, q in ipairs(P:Requests()) do
            local mine = P:IsMine(q) or P:MyOffer(q.id) ~= nil
            if (not self.filters.mine or mine) and (self.filters.done or P:IsOpen(q, now)) then items[#items + 1] = q end
        end
        return items
    end
    return P:MyEntries()
end

---------------------------------------------------------------------------
-- Detail per view
---------------------------------------------------------------------------

local function findCraft(id)
    for _, r in ipairs(P:Crafters()) do if r.id == id then return r end end
end

function Page:ClearDetail()
    local f = self.frame
    for _, b in ipairs(f.actionButtons) do b:Hide() end
    for _, r in ipairs(f.offerRows) do r:Hide() end
    f.lines:Hide()
    f.mineEditor:Hide()
end

local function setActions(buttons)
    local f = Page.frame
    for i, spec in ipairs(buttons) do
        local b = f.actionButtons[i]
        if b then
            b:SetText(spec[1])
            b.fn = spec[2]
            b:Show()
        end
    end
end

function Page:RenderCrafter()
    local f = self.frame
    local r = self.selectedCraft and findCraft(self.selectedCraft)
    if not r then
        f.detailTitle:SetText(L["Find a crafter"])
        f.detailBody:SetText("|cff999999" .. L["Search for a recipe or a name. Results come from guildmates who share their professions; open your own profession windows once so others can find you."] .. "|r")
        return
    end
    f.detailTitle:SetText(("%s  |cffbbbbbb%s %s|r"):format(coloredName(r.owner), P:Name(r.skillLine, r.name), skillText(r)))
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, label, value) end
    end
    add(L["Specialty"], r.specialty)
    add(L["Note"], r.note)
    add(L["Source"], sourceText(r))
    add(L["Status"], (r._local and L["you"]) or (CH.Roster:IsOnline(r.owner) and "|cff7fd17f" .. L["online"] .. "|r")
        or ("|cff999999" .. L["offline"] .. "|r"))
    f.detailBody:SetText(table.concat(lines, "\n"))

    local ids = P:RecipesOf(r)
    local names = {}
    local needle = self.filters.text:lower()
    for _, id in ipairs(ids) do
        local name = P:RecipeLabel(id)
        if needle == "" or name:lower():find(needle, 1, true) then
            names[#names + 1] = (id == self.selectedRecipe and "|cffd4af37" or "|cffffffff") .. name .. "|r"
        end
    end
    table.sort(names, function(a, b) return a:sub(11) < b:sub(11) end)
    if #ids == 0 then
        names[1] = "|cff999999" .. (r.source == "manual" and L["Entered by hand: no recipe list."] or
            L["No recipes shared yet. They appear after the profession window is opened."]) .. "|r"
    else
        table.insert(names, 1, "|c" .. GOLD.hex .. (needle ~= "" and (L["Recipes matching \"%s\" (%d of %d)"]):format(
            self.filters.text, #names, #ids) or (L["Recipes (%d)"]):format(#ids)) .. "|r")
    end
    f.lines:Show()
    f.lines:SetItems(names)

    local buttons = {}
    if not r._local and CH.Roster:IsOnline(r.owner) then
        buttons[#buttons + 1] = { L["Whisper"], function() whisper(r.owner) end }
    end
    if not r._local then
        buttons[#buttons + 1] = { L["Request a craft"], function()
            Page:SetView("requests")
            Page:OpenEditor(nil, { kind = "craft", skillLine = r.skillLine,
                title = self.selectedRecipe and P:RecipeName(self.selectedRecipe) or "" })
        end }
    end
    setActions(buttons)
end

function Page:RenderRequest()
    local f = self.frame
    local q = self.selectedRequest and P:GetRequest(self.selectedRequest)
    if not q then
        f.detailTitle:SetText(L["Select a request"])
        f.detailBody:SetText("|cff999999" .. L["Ask for a craft or for materials with New request; guildmates who can help offer from here."] .. "|r")
        return
    end
    local status = P:EffectiveStatus(q)
    f.detailTitle:SetText(q.title .. (q.quantity and (" x" .. q.quantity) or ""))
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, label, value) end
    end
    add(L["Type"], P:Label(q.kind) .. (q.skillLine and ("  |cff999999" .. P:Name(q.skillLine) .. "|r") or ""))
    add(L["Requested by"], coloredName(q.owner))
    add(L["Status"], P:Label(status) .. (status == "open" and ("  |cff999999" ..
        (L["(open until %s)"]):format(date("%a %d %b", q.expiresAt)) .. "|r") or ""))
    if q.itemID then
        local price, age = P:Price(q.itemID)
        if price then
            add(L["Auction price"], ("%s  |cff999999%s|r"):format(CH.FormatMoney(price),
                age and (age == 0 and L["(your Auctionator scan today, not live)"] or
                    (L["(your Auctionator scan %d day(s) ago, not live)"]):format(age)) or L["(Auctionator scan, not live)"]))
        end
    end
    if q.details then lines[#lines + 1] = q.details end
    local crafters = P:CraftersFor(q)
    if #crafters > 0 then
        local names = {}
        for _, c in ipairs(crafters) do names[#names + 1] = onlineDot(c.name) .. coloredName(c.name) end
        add(L["Known crafters"], table.concat(names, ", "))
    end
    f.detailBody:SetText(table.concat(lines, "\n"))

    local offers = P:Offers(q)
    local mine = P:IsMine(q)
    f.offersHeading:SetText((L["Offers (%d)"]):format(P:ActiveOfferCount(q)))
    f.offersHeading:Show()
    for i = 1, math.min(#offers, MAX_OFFER_ROWS) do
        local o, row = offers[i], f.offerRows[i]
        row.text:SetText(("%s  %s%s"):format(coloredName(o.owner),
            o.state == "offered" and P:Label("offered") or ("|cff999999" .. P:Label("withdrawn") .. "|r"),
            o.note and ("  |cffbbbbbb\"" .. o.note .. "\"|r") or ""))
        row.name = o.owner
        row.whisper:SetShown(mine and o.state == "offered" and CH.Roster:IsOnline(o.owner))
        row:Show()
    end

    local buttons = {}
    local function action(label, fn) buttons[#buttons + 1] = { label, fn } end
    if mine then
        action(L["Edit"], function() Page:OpenEditor(q) end)
        if status == "open" then
            action(L["Mark done"], function() P:SetRequestStatus(q.id, "done") end)
            action(L["Cancel"], function() P:SetRequestStatus(q.id, "cancelled") end)
        else
            action(L["Reopen"], function() P:SetRequestStatus(q.id, "open") end)
        end
        action(L["Delete"], function()
            P:DeleteRequest(q.id)
            Page.selectedRequest = nil
        end)
    else
        local o = P:MyOffer(q.id)
        if status == "open" then
            if o and o.state == "offered" then
                action(L["Withdraw offer"], function() P:WithdrawOffer(q.id) end)
            else
                action(L["I can help"], function()
                    local ok, reason = P:Offer(q.id)
                    if not ok and reason then CH:Print(reason) end
                end)
            end
        end
        if CH.Roster:IsOnline(q.owner) then action(L["Whisper requester"], function() whisper(q.owner) end) end
    end
    setActions(buttons)
end

function Page:RenderMine()
    local f = self.frame
    local entries = P:MyEntries()
    local e = self.selectedMine and P:MyEntry(self.selectedMine)
    if not e then
        f.detailTitle:SetText(L["Your professions"])
        f.detailBody:SetText("|cff999999" .. (#entries == 0 and
            L["Nothing yet. Open each of your profession windows once (for example with the spellbook) and your recipes appear here. Use Add by hand for anything the game doesn't show."]
            or L["Select a profession to add a specialty or a note. Open its profession window again to refresh the recipe list."]) .. "|r")
        return
    end
    f.detailTitle:SetText(("%s  |cffbbbbbb%s|r"):format(P:Name(e.skillLine, e.name), skillText(e)))
    local count = e.recipes and #(P.DecodeRecipes(e.recipes) or {}) or 0
    local lines = {}
    lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, L["Source"], sourceText(e))
    if e.source == "scan" then lines[#lines + 1] = ("|c%s%s:|r %d"):format(GOLD.hex, L["Recipes"], count) end
    lines[#lines + 1] = ("|c%s%s:|r %s"):format(GOLD.hex, L["Shared"], P:IsSharing() and L["yes"] or
        ("|cffe06666" .. L["no (sharing is off)"] .. "|r"))
    f.detailBody:SetText(table.concat(lines, "\n"))

    local ed = f.mineEditor
    ed:Show()
    ed.specialty:SetText(e.specialty or "")
    ed.note:SetText(e.note or "")
    ed.skill:SetText(e.skill and tostring(e.skill) or "")
    ed.skill:SetShown(e.source == "manual")
    ed.skillLabel:SetShown(e.source == "manual")
    ed.error:SetText("")

    local buttons = { { L["Save"], function() Page:SaveMine() end } }
    if e.source == "manual" then
        buttons[#buttons + 1] = { L["Remove"], function()
            P:RemoveMine(e.skillLine)
            Page.selectedMine = nil
        end }
    end
    setActions(buttons)
end

function Page:SaveMine()
    local ed = self.frame.mineEditor
    local ok, reason = P:SaveMine(self.selectedMine, { specialty = ed.specialty:GetText(), note = ed.note:GetText(),
        skill = ed.skill:GetText() })
    if not ok then ed.error:SetText(reason or L["Could not save."]) end
end

function Page:RenderDetail()
    self:ClearDetail()
    self.frame.offersHeading:Hide()
    if self.view == "crafters" then self:RenderCrafter()
    elseif self.view == "requests" then self:RenderRequest()
    else self:RenderMine() end
end

---------------------------------------------------------------------------
-- Views and refresh
---------------------------------------------------------------------------

function Page:SetView(view)
    self.view = view
    local f = self.frame
    f.viewRow:Set(view)
    f.crafterTools:SetShown(view == "crafters")
    f.requestTools:SetShown(view == "requests")
    f.mineTools:SetShown(view == "mine")
    self:Refresh()
end

function Page:Refresh()
    local f = self.frame
    if not f or not f:IsVisible() or f.editor:IsShown() then return end
    if self.view == "crafters" then
        local lines = { "all" }
        for _, id in ipairs(P:KnownSkillLines()) do lines[#lines + 1] = id end
        f.professionFilter:SetValues(lines)
        local v = f.professionFilter:Get()
        self.filters.skillLine = v ~= "all" and v or nil
    end
    local items = self:BuildItems()
    f.list:SetItems(items)
    local crafters = {}
    for _, r in ipairs(P:Crafters()) do if not r._local then crafters[r.owner] = true end end
    local n = 0
    for _ in pairs(crafters) do n = n + 1 end
    f.subtitle:SetText((L["%d guildmate(s) sharing professions. %d open request(s)."]):format(n, P:OpenRequestCount()))
    local empty = {
        crafters = self.filters.text ~= "" and L["No matches."] or L["Nobody is sharing professions yet."],
        requests = L["No requests. Post one with New request."],
        mine = L["Open a profession window to add it here."],
    }
    f.empty:SetText(empty[self.view])
    f.empty:SetShown(#items == 0)
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Request editor
---------------------------------------------------------------------------

function Page:BuildEditor(frame)
    local ed = W.CreatePanel(frame, W.COLORS.inset, 0.5)
    ed:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, frame.contentTop)
    ed:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)
    ed:Hide()
    frame.editor = ed
    ed.heading = W.Heading(ed, "")
    ed.heading:SetPoint("TOPLEFT", 14, -12)

    local y, STEP = -44, 48
    local function label(text, x)
        local l = W.Label(ed, text, "GameFontNormal")
        l:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        l:SetPoint("TOPLEFT", x or 14, y)
        return l
    end
    label(L["Type"])
    ed.kind = W.ToggleRow(ed, P.KINDS, function(v)
        return v == "craft" and L["Craft something"] or L["Need materials"]
    end, 140)
    ed.kind:Anchor("TOPLEFT", 14, y - 18)
    y = y - STEP

    label(L["Item"])
    ed.item = W.EditBox(ed, 360, 255)
    ed.item:SetPoint("TOPLEFT", 20, y - 18)
    local hint = W.Label(ed, L["type a name, or Shift-click an item"], "GameFontHighlightSmall", W.COLORS.muted)
    hint:SetPoint("LEFT", ed.item, "RIGHT", 8, 0)
    y = y - STEP

    label(L["Quantity"])
    ed.quantity = W.EditBox(ed, 50, 4)
    ed.quantity:SetNumeric(true)
    ed.quantity:SetJustifyH("CENTER")
    ed.quantity:SetPoint("TOPLEFT", 20, y - 18)
    label(L["Profession (optional)"], 120)
    local profs = { "any" }
    for _, p in ipairs(P.LIST) do profs[#profs + 1] = p.id end
    ed.profession = cycleButton(ed, 160, profs, function(v) return v == "any" and L["Any"] or P:Name(v) end)
    ed.profession:SetPoint("TOPLEFT", 120, y - 18)
    label(L["Open for"], 320)
    ed.expiry = W.ToggleRow(ed, P.EXPIRY_DAYS, function(d)
        return d == 1 and L["1 day"] or (L["%d days"]):format(d)
    end, 66)
    ed.expiry:Anchor("TOPLEFT", 320, y - 18)
    y = y - STEP

    label(L["Details (optional)"])
    ed.details = W.EditBox(ed, 600, P.DETAILS_MAX)
    ed.details:SetPoint("TOPLEFT", 20, y - 18)

    ed.error = W.Label(ed, "", "GameFontHighlightSmall")
    ed.error:SetTextColor(1, 0.4, 0.4)
    ed.error:SetPoint("BOTTOMLEFT", 14, 44)
    ed.error:SetPoint("RIGHT", ed, "RIGHT", -14, 0)
    ed.save = W.Button(ed, L["Post"], 100, function() Page:SaveEditor() end)
    ed.save:SetPoint("BOTTOMLEFT", 14, 12)
    local cancel = W.Button(ed, L["Cancel"], 100, function() Page:CloseEditor() end)
    cancel:SetPoint("LEFT", ed.save, "RIGHT", 8, 0)
end

-- Shift-clicking an item while the item box has focus inserts its link (as it does for chat).
local function hookItemLinks()
    local function insert(link)
        local box = Page.frame and Page.frame.editor and Page.frame.editor.item
        if box and box:IsVisible() and box:HasFocus() and type(link) == "string" then
            box:SetText(link)
            return true
        end
    end
    if hooksecurefunc then
        if type(ChatEdit_InsertLink) == "function" then pcall(hooksecurefunc, "ChatEdit_InsertLink", insert) end
        if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
            pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", insert)
        end
    end
end

function Page:OpenEditor(q, prefill)
    local ed = self.frame.editor
    self.editing = q and q.id or nil
    local src = q or prefill or {}
    ed.heading:SetText(q and L["Edit request"] or L["New request"])
    ed.save:SetText(q and L["Save"] or L["Post"])
    ed.kind:Set(src.kind or "craft")
    ed.item:SetText(src.title or "")
    ed.itemID = src.itemID
    ed.quantity:SetText(src.quantity and tostring(src.quantity) or "1")
    ed.profession:Set(src.skillLine or "any")
    local days = 3
    if q then
        local left = (q.expiresAt - CH.ServerTime()) / 86400
        for _, d in ipairs(P.EXPIRY_DAYS) do if left >= d - 0.5 then days = d end end
    end
    ed.expiry:Set(days)
    ed.details:SetText(src.details or "")
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
    local itemID, title = P.ParseItemText(ed.item:GetText())
    if not title or title == "" then
        ed.error:SetText(L["Name the item you need."])
        return
    end
    -- Keep the item ID from the original request when the name wasn't changed.
    if not itemID and self.editing then
        local q = P:GetRequest(self.editing)
        if q and q.title == title then itemID = q.itemID end
    end
    local quantity = tonumber(ed.quantity:GetText())
    if quantity and (quantity < 1 or quantity > 1000) then
        ed.error:SetText(L["Quantity must be between 1 and 1000."])
        return
    end
    local profession = ed.profession:Get()
    local fields = { kind = ed.kind.value, title = title, itemID = itemID,
        skillLine = profession ~= "any" and profession or nil, quantity = quantity, details = ed.details:GetText(),
        expiresAt = CH.ServerTime() + ed.expiry.value * 86400 }
    local ok, reason
    if self.editing then
        ok, reason = P:UpdateRequest(self.editing, fields)
        if ok then ok = self.editing end
    else
        ok, reason = P:CreateRequest(fields)
    end
    if not ok then
        ed.error:SetText(reason or L["Could not save."])
        return
    end
    self.selectedRequest = ok
    self:CloseEditor()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Professions"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(54)
    frame.toolbar = toolbar
    frame.viewRow = W.ToggleRow(toolbar, { "crafters", "requests", "mine" }, function(v)
        return ({ crafters = L["Find crafters"], requests = L["Requests"], mine = L["My professions"] })[v]
    end, 120, function(v) Page:SetView(v) end)
    frame.viewRow:Anchor("TOPLEFT", 0, 0)

    -- Crafters tools: search, profession filter, online only.
    local ct = CreateFrame("Frame", nil, toolbar)
    ct:SetPoint("TOPLEFT", 0, -28)
    ct:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    ct:SetHeight(26)
    frame.crafterTools = ct
    frame.search = W.EditBox(ct, 200, 40, function(text)
        Page.filters.text = text or ""
        Page:Refresh()
    end)
    frame.search:SetPoint("LEFT", 6, 0)
    local searchHint = W.Label(ct, L["recipe or name"], "GameFontHighlightSmall", W.COLORS.muted)
    searchHint:SetPoint("LEFT", frame.search, "RIGHT", 6, 0)
    frame.professionFilter = cycleButton(ct, 150, { "all" }, professionLabel, function() Page:Refresh() end)
    frame.professionFilter:SetPoint("LEFT", searchHint, "RIGHT", 12, 0)
    W.Tooltip(frame.professionFilter, L["Profession"], L["Click to step through professions; right-click to go back."])
    frame.onlineOnly = W.Checkbox(ct, L["Online"], L["Only crafters who are online now."],
        function(v) Page.filters.online = v; Page:Refresh() end)
    frame.onlineOnly:SetPoint("LEFT", frame.professionFilter, "RIGHT", 10, 0)

    -- Request tools.
    local rt = CreateFrame("Frame", nil, toolbar)
    rt:SetPoint("TOPLEFT", 0, -28)
    rt:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    rt:SetHeight(26)
    frame.requestTools = rt
    frame.mineOnly = W.Checkbox(rt, L["Mine"], L["Requests you posted or offered on."],
        function(v) Page.filters.mine = v; Page:Refresh() end)
    frame.mineOnly:SetPoint("LEFT", 0, 0)
    frame.showDone = W.Checkbox(rt, L["Show finished"], L["Include done, cancelled and expired requests."],
        function(v) Page.filters.done = v; Page:Refresh() end)
    frame.showDone:SetPoint("LEFT", frame.mineOnly, "RIGHT", 60, 0)
    local new = W.Button(rt, L["New request"], 130, function() Page:OpenEditor(nil) end)
    new:SetPoint("RIGHT", 0, 0)

    -- My professions tools: sharing and manual entries.
    local mt = CreateFrame("Frame", nil, toolbar)
    mt:SetPoint("TOPLEFT", 0, -28)
    mt:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    mt:SetHeight(26)
    frame.mineTools = mt
    frame.shareCrafts = W.Checkbox(mt, L["Share my professions"],
        L["When off, guildmates' copies of your professions are removed and nothing is sent."],
        function(v) CH.Settings:Set("professions.share", v); Page:Refresh() end)
    frame.shareCrafts:SetPoint("LEFT", 0, 0)
    local manual = {}
    for _, p in ipairs(P.LIST) do manual[#manual + 1] = p.id end
    frame.manualProfession = cycleButton(mt, 140, manual, function(v) return P:Name(v) end)
    frame.addManual = W.Button(mt, L["Add by hand"], 110, function()
        local id = frame.manualProfession:Get()
        if P:MyEntry(id) then
            Page.selectedMine = id
        elseif P:SaveMine(id, {}) then
            Page.selectedMine = id
        end
        Page:Refresh()
    end)
    frame.addManual:SetPoint("RIGHT", 0, 0)
    frame.manualProfession:SetPoint("RIGHT", frame.addManual, "LEFT", -6, 0)

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
            if self.fn then CH.SafeCall("profession action", self.fn) end
            Page:Refresh()
        end)
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        b:SetPoint("BOTTOMLEFT", 12 + col * 124, 10 + (1 - row) * 26)
        b:Hide()
        frame.actionButtons[i] = b
    end

    -- Recipe list (crafters view).
    frame.lines = W.List(detail, LINE_HEIGHT, createLine, updateLine)
    frame.lines:SetPoint("TOPLEFT", frame.detailBody, "BOTTOMLEFT", -4, -10)
    frame.lines:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -8, 66)
    frame.lines:Hide()

    -- Offer rows (requests view).
    frame.offersHeading = W.Label(detail, "", "GameFontNormal")
    frame.offersHeading:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
    frame.offersHeading:SetPoint("BOTTOMLEFT", 14, 70 + MAX_OFFER_ROWS * 20)
    frame.offerRows = {}
    for i = 1, MAX_OFFER_ROWS do
        local row = CreateFrame("Frame", nil, detail)
        row:SetHeight(20)
        row:SetPoint("BOTTOMLEFT", 14, 70 + (MAX_OFFER_ROWS - i) * 20)
        row:SetPoint("RIGHT", detail, "RIGHT", -10, 0)
        row.text = W.Label(row, "", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT")
        row.text:SetWordWrap(false)
        row.whisper = W.Button(row, L["Whisper"], 64, function() whisper(row.name) end)
        row.whisper:SetHeight(18)
        row.whisper:SetPoint("RIGHT", 0, 0)
        row.text:SetPoint("RIGHT", row.whisper, "LEFT", -4, 0)
        row:Hide()
        frame.offerRows[i] = row
    end

    -- Editor for your own profession entry (My professions view).
    local me = CreateFrame("Frame", nil, detail)
    me:SetPoint("TOPLEFT", frame.detailBody, "BOTTOMLEFT", 0, -14)
    me:SetPoint("RIGHT", detail, "RIGHT", -14, 0)
    me:SetHeight(150)
    me:Hide()
    frame.mineEditor = me
    local function mlabel(text, yy)
        local l = W.Label(me, text, "GameFontNormal")
        l:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        l:SetPoint("TOPLEFT", 0, yy)
        return l
    end
    mlabel(L["Specialty (optional)"], 0)
    me.specialty = W.EditBox(me, 240, P.SPECIALTY_MAX)
    me.specialty:SetPoint("TOPLEFT", 6, -18)
    mlabel(L["Note (optional)"], -46)
    me.note = W.EditBox(me, 300, P.CRAFT_NOTE_MAX)
    me.note:SetPoint("TOPLEFT", 6, -64)
    me.skillLabel = mlabel(L["Skill level"], -92)
    me.skill = W.EditBox(me, 50, 4)
    me.skill:SetNumeric(true)
    me.skill:SetPoint("TOPLEFT", 6, -110)
    me.error = W.Label(me, "", "GameFontHighlightSmall")
    me.error:SetTextColor(1, 0.4, 0.4)
    me.error:SetPoint("TOPLEFT", 0, -136)

    local function layout()
        local width = frame:GetWidth() or 700
        detail:SetWidth(math.max(380, math.floor((width - 40) * 0.5)))
        list:SetPoint("RIGHT", detail, "LEFT", -12, 0)
        list:Refresh()
        frame.lines:Refresh()
    end
    frame:SetScript("OnSizeChanged", layout)
    layout()

    self:BuildEditor(frame)
    hookItemLinks()
    self:SetView(self.view)
end

function Page:OnShow()
    self.frame.shareCrafts:SetChecked(P:IsSharing())
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.5.0",
    description = L["Professions page"],
    dependencies = { "Professions" },
    initialize = function()
        CH.UI:RegisterPage("professions", {
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        local refresh = function() Page:Refresh() end
        CH.Events:Subscribe("SYNC_RECORD_CHANGED", MODULE, function(typeName)
            if typeName == "craft" or typeName == "craftreq" or typeName == "craftoffer" then Page:Refresh() end
        end)
        CH.Events:Subscribe("PROFESSIONS_SCANNED", MODULE, refresh)
        CH.Events:Subscribe("RECIPE_NAMES_LOADED", MODULE, refresh)
        CH.Events:Subscribe("ROSTER_UPDATED", MODULE, refresh)
    end,
})

CH.ProfessionsPage = Page  -- exposed for tests
