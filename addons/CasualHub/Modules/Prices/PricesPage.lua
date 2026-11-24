-- Prices page: search item prices from your Auctionator scans and the guild's, ask the guild, and see an
-- item's recent history.
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD
local PR = CH.Prices

local Page = { text = "" }
local MODULE = "PricesPage"
local ROW_HEIGHT = 22
local HISTORY_DAYS = 7

local money = function(c) return CH.FormatMoney(c) end

local function sourceText(day, by)
    local age = PR.AgeText(day)
    if by then return (L["%s, %s"]):format(by, age) end
    return (L["you, %s"]):format(age)
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

-- Search results, or with an empty box: answers to your last question, then recent guild prices.
function Page:BuildItems()
    local items, seen = {}, {}
    local function add(key, name)
        if seen[key] then return end
        seen[key] = true
        items[#items + 1] = { key = key, name = name or PR:KeyName(key) }
    end
    if self.linkKey then add(self.linkKey, self.linkName) end
    if self.text ~= "" then
        for _, r in ipairs(PR:Search(self.text, 80)) do add(r.key, r.name) end
    else
        for _, a in ipairs(PR.answers) do add(a.key) end
        local recent = {}
        for key, e in pairs(CH.Store:Bucket("priceCache", false) or {}) do recent[#recent + 1] = { key, e.at or 0 } end
        table.sort(recent, function(a, b) return a[2] > b[2] end)
        for i = 1, math.min(#recent, 40) do add(recent[i][1]) end
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
    row.right = W.Label(row, "", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", -4, 0)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWidth(130)
    row.left = W.Label(row, "", "GameFontHighlight")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
        Page.selected = self.item.key
        Page:Refresh()
    end)
    row:SetScript("OnEnter", function(self)
        local id = self.item and PR.ParseKey(self.item.key)
        if id and GameTooltip and GameTooltip.SetItemByID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(id)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return row
end

local function updateRow(row, item)
    row.item = item
    local id = PR.ParseKey(item.key)
    row.left:SetText(item.name or ("|cff999999" .. (L["item #%d"]):format(id or 0) .. "|r"))
    local price, day, by = PR:Best(item.key)
    if price then
        row.right:SetText(money(price) .. (by and " |cff80c0ff*|r" or ""))
    else
        row.right:SetText("|cff999999" .. L["no price"] .. "|r")
    end
    row.selected:SetShown(item.key == Page.selected)
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

function Page:RenderIntro()
    local f = self.frame
    f.detailTitle:SetText(L["Item prices"])
    local lines = {}
    if PR:HasAuctionator() then
        lines[#lines + 1] = L["Type an item name, or shift-click an item into the search box. Prices come from your Auctionator scans; Ask the guild checks guildmates' scans too."]
    else
        lines[#lines + 1] = L["Type an item name, or shift-click an item into the search box, then Ask the guild: guildmates with Auctionator answer with their scanned prices."]
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cff999999" .. L["Prices are from auction house scans, not live, and always show how old they are. A blue * marks a guildmate's price."] .. "|r"
    local known, total = PR:IndexProgress()
    if known then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff999999" .. (L["Learning item names for search: %d of %d."]):format(known, total) .. "|r"
    end
    f.detailBody:SetText(table.concat(lines, "\n"))
    local buttons = {}
    if self.text ~= "" then buttons[1] = { L["Ask the guild"], function() Page:Ask(Page.text) end } end
    setActions(buttons)
end

function Page:RenderDetail()
    local f = self.frame
    local key = self.selected
    local id, suffix = PR.ParseKey(key)
    if not id then return self:RenderIntro() end
    f.detailTitle:SetText(PR:KeyName(key) or (L["item #%d"]):format(id))
    local lines = {}
    local own, ownDay = PR:Own(key)
    local guild, guildDay, guildBy = PR:Guild(key)
    if own then
        lines[#lines + 1] = ("%s  %s  |cff999999(%s)|r"):format(L["Your scan:"], money(own), sourceText(ownDay))
    elseif PR:HasAuctionator() then
        lines[#lines + 1] = ("%s  |cff999999%s|r"):format(L["Your scan:"], L["not seen"])
    end
    if guild then
        lines[#lines + 1] = ("%s  %s  |cff999999(%s)|r"):format(L["Guild:"], money(guild), sourceText(guildDay, guildBy))
    end
    for _, a in ipairs(PR.answers) do
        if a.key == key and a.by ~= guildBy then
            lines[#lines + 1] = ("   %s  |cff999999(%s)|r"):format(money(a.price), sourceText(a.day, a.by))
        end
    end
    if not own and not guild then
        lines[#lines + 1] = "|cff999999" .. L["No price yet. Ask the guild to check guildmates' scans."] .. "|r"
    end
    local mean = PR:Mean(key, 7)
    if mean then lines[#lines + 1] = ("%s  %s"):format(L["7-day average:"], money(mean)) end
    local vendor = not suffix and PR:VendorPrice(id)
    if vendor then lines[#lines + 1] = ("%s  %s"):format(L["Vendor sells for:"], money(vendor)) end
    local history = PR:History(key, HISTORY_DAYS)
    if #history > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cffffd100" .. L["Your recent scans (low - high)"] .. "|r"
        for _, h in ipairs(history) do
            local label = PR.AgeText(h.day)
            if h.low ~= h.high then
                lines[#lines + 1] = ("  %s:  %s - %s"):format(label, money(h.low), money(h.high))
            else
                lines[#lines + 1] = ("  %s:  %s"):format(label, money(h.low))
            end
        end
    end
    local q = PR.question
    if q and q.k == key and time() - q.at < 10 and #PR.answers == 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff999999" .. L["Asking the guild..."] .. "|r"
    end
    f.detailBody:SetText(table.concat(lines, "\n"))

    local buttons = { { L["Ask the guild"], function() Page:Ask(key) end } }
    if CH.Professions and CH.Professions:CanMakeShoppingList() then
        buttons[#buttons + 1] = { L["Shopping list"], function()
            local name = PR:KeyName(key)
            local ok, result = CH.Professions:MakeShoppingList("Casual Hub", { { itemID = id, qty = 1, name = name } })
            CH:Print(ok and L["Added to the Auctionator shopping list \"Casual Hub\"."] or tostring(result))
        end }
    end
    setActions(buttons)
end

function Page:Ask(query)
    local ok, reason = PR:Ask(query)
    if not ok then
        self.frame.status:SetText("|cffff6060" .. tostring(reason) .. "|r")
    else
        self.frame.status:SetText("|cff999999" .. L["Asked the guild. Answers appear as they come in."] .. "|r")
        -- No answers after a few seconds means nobody online has a scan of it.
        C_Timer.After(6, function()
            if PR.question and PR.question.n and #PR.answers == 0 and Page.frame:IsVisible() then
                Page.frame.status:SetText("|cff999999" .. L["No guildmate online has a recent price for that."] .. "|r")
            end
        end)
    end
    self:Refresh()
end

function Page:Refresh()
    local f = self.frame
    if not f or not f:IsVisible() then return end
    local items = self:BuildItems()
    f.list:SetItems(items)
    f.empty:SetText(self.text ~= "" and L["No matching items. Try Ask the guild."]
        or L["Search for an item, or shift-click one into the box."])
    f.empty:SetShown(#items == 0)
    if PR:HasAuctionator() then
        local known, total = PR:IndexProgress()
        f.subtitle:SetText(known and (L["Your Auctionator scans plus the guild's. Learning item names: %d of %d."]):format(known, total)
            or L["Your Auctionator scans plus the guild's. Not live: every price shows its age."])
    else
        f.subtitle:SetText(L["Prices from guildmates' Auctionator scans. Not live: every price shows its age."])
    end
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Shift-clicked items
---------------------------------------------------------------------------

function Page:UseLink(link)
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return end
    local name = link:match("|h%[(.-)%]|h")
    local function apply(key)
        Page.linkKey, Page.linkName = key, name
        Page.selected = key
        Page.text = ""
        Page.frame.search:SetText("")
        Page.frame.search:ClearFocus()
        local own, day = PR:Own(key)
        if not own or PR.Today() - day > 1 then Page:Ask(key) else Page:Refresh() end
    end
    local U = Auctionator and Auctionator.Utilities
    if type(U) == "table" and type(U.DBKeyFromLink) == "function" then
        local ok = pcall(U.DBKeyFromLink, link, function(keys)
            apply(type(keys) == "table" and keys[1] and PR.ParseKey(keys[1]) and keys[1] or tostring(id))
        end)
        if ok then return end
    end
    apply(tostring(id))
end

local function hookItemLinks()
    local function insert(link)
        local box = Page.frame and Page.frame.search
        if box and box:IsVisible() and box:HasFocus() and type(link) == "string" and link:find("item:", 1, true) then
            CH.SafeCall("price link", Page.UseLink, Page, link)
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

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function Page:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Prices"], " ")
    frame.contentTop = y

    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetPoint("TOPLEFT", 20, y)
    toolbar:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    toolbar:SetHeight(54)
    frame.toolbar = toolbar
    frame.search = W.EditBox(toolbar, 260, 60, function(text)
        text = text or ""
        if text:find("|H", 1, true) then return end  -- a link typed by the client; UseLink handles it
        Page.text = text
        if text ~= "" then Page.linkKey = nil end
        CH.Debounce(MODULE .. "-search", 0.25, function() Page:Refresh() end)
    end)
    frame.search:SetPoint("TOPLEFT", 6, 0)
    if frame.search.SetScript then
        frame.search:SetScript("OnEnterPressed", function(box)
            box:ClearFocus()
            if Page.text ~= "" then Page:Ask(Page.text) end
        end)
    end
    local hint = W.Label(toolbar, L["item name, or shift-click an item"], "GameFontHighlightSmall", W.COLORS.muted)
    hint:SetPoint("LEFT", frame.search, "RIGHT", 6, 0)
    frame.ask = W.Button(toolbar, L["Ask the guild"], 120, function()
        if Page.text ~= "" then Page:Ask(Page.text) elseif Page.selected then Page:Ask(Page.selected) end
    end)
    frame.ask:SetPoint("TOPRIGHT", 0, 0)

    frame.answer = W.Checkbox(toolbar, L["Answer guild price questions"],
        L["When a guildmate asks about an item you have a scanned price for, Casual Hub answers automatically. Needs Auctionator."],
        function(v) CH.Settings:Set("prices.answer", v) end)
    frame.answer:SetPoint("TOPLEFT", 0, -28)
    frame.shareMats = W.Checkbox(toolbar, L["Share material prices"],
        L["After an auction house scan, shares your prices for crafting materials and consumables with the guild, so crafting costs work for everyone."],
        function(v) CH.Settings:Set("prices.shareMats", v) end)
    frame.shareMats:SetPoint("LEFT", frame.answer, "RIGHT", 210, 0)
    frame.status = W.Label(toolbar, "", "GameFontHighlightSmall", W.COLORS.muted)
    frame.status:SetPoint("TOPRIGHT", 0, -34)

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
    for i = 1, 2 do
        local b = W.Button(detail, "", 140, function(self)
            if self.fn then CH.SafeCall("price action", self.fn) end
            Page:Refresh()
        end)
        b:SetPoint("BOTTOMLEFT", 12 + (i - 1) * 144, 10)
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
    hookItemLinks()
end

function Page:OnShow()
    local f = self.frame
    f.answer:SetChecked(CH.Settings:Get("prices.answer") ~= false)
    f.shareMats:SetChecked(CH.Settings:Get("prices.shareMats") ~= false)
    f.answer:SetShown(PR:HasAuctionator())
    f.shareMats:SetShown(PR:HasAuctionator())
    f.status:SetText("")
    self:Refresh()
end

CH:RegisterModule(MODULE, {
    version = "0.8.0",
    description = L["Prices page"],
    dependencies = { "Prices" },
    initialize = function()
        CH.UI:RegisterPage("prices", {
            minHeight = 420,  -- scrolls on shorter windows (UI:CreatePageFrame)
            build = function(frame) Page:Build(frame) end,
            onShow = function() Page:OnShow() end,
        })
        CH.Events:Subscribe("PRICES_CHANGED", MODULE, function()
            CH.Debounce(MODULE, 0.3, function() Page:Refresh() end)
        end)
    end,
})

CH.PricesPage = Page  -- exposed for tests
