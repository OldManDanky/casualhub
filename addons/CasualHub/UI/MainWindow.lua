-- Main window: title bar, left sidebar navigation, page workspace (design doc §5).
-- Movable, resizable, scalable; position, size and last page persist in settings.
local _, CH = ...
local L = CH.L
local W = CH.Widgets
local GOLD = CH.GOLD

local UI = { pages = {}, pageFrames = {}, navButtons = {} }
CH.UI = UI

local SIDEBAR_WIDTH = 176
local TITLE_HEIGHT = 44
local MIN_W, MIN_H, MAX_W, MAX_H = 720, 460, 1800, 1100

---------------------------------------------------------------------------
-- Page registry
---------------------------------------------------------------------------

-- spec: { build = function(frame) end, onShow = function(frame) end, onHide = function(frame) end }
function UI:RegisterPage(id, spec)
    self.pages[id] = spec
    if self.navButtons[id] then self:RefreshNav() end
end

function UI:HasPage(id)
    return CH.NavigationEntry(id) ~= nil
end

-- Standard page header: title, optional subtitle, gold rule. Returns the y offset below it.
function UI:PageHeader(frame, title, subtitle)
    local heading = W.Heading(frame, title)
    heading:SetPoint("TOPLEFT", 20, -16)
    local y = -40
    if subtitle then
        local sub = W.Label(frame, subtitle, "GameFontHighlightSmall", W.COLORS.muted)
        sub:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
        sub:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
        frame.subtitle = sub
        y = -58
    end
    local rule = W.Divider(frame)
    rule:SetPoint("TOPLEFT", 20, y)
    rule:SetPoint("TOPRIGHT", -20, y)
    frame.heading = heading
    return y - 12
end

local function buildPlaceholder(frame, entry)
    local y = UI:PageHeader(frame, entry.title, entry.phase and (L["Coming in roadmap phase %d"]):format(entry.phase))
    local text = W.Label(frame, entry.summary or "", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 20, y - 8)
    text:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    text:SetWordWrap(true)
    local note = W.Label(frame, L["This section is not built yet. The guild-only alpha adds sections one phase at a time."],
        "GameFontHighlightSmall", W.COLORS.muted)
    note:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    note:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    note:SetWordWrap(true)
end

---------------------------------------------------------------------------
-- Window construction
---------------------------------------------------------------------------

local function savePosition(win)
    local point, _, relativePoint, x, y = win:GetPoint(1)
    if not point then return end
    local s = CH.Settings
    s:Set("window.point", point)
    s:Set("window.relativePoint", relativePoint)
    s:Set("window.x", math.floor(x + 0.5))
    s:Set("window.y", math.floor(y + 0.5))
end

local function applyPosition(win)
    win:ClearAllPoints()
    local s = CH.Settings
    local point = s:Get("window.point")
    if type(point) == "string" then
        win:SetPoint(point, UIParent, s:Get("window.relativePoint") or point, s:Get("window.x") or 0, s:Get("window.y") or 0)
    else
        win:SetPoint("CENTER")
    end
end

local function clampSize(w, h)
    w = math.min(MAX_W, math.max(MIN_W, tonumber(w) or 900))
    h = math.min(MAX_H, math.max(MIN_H, tonumber(h) or 580))
    return w, h
end

local function createNavButton(parent, entry, index)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(30)
    b:SetPoint("TOPLEFT", 8, -10 - (index - 1) * 32)
    b:SetPoint("TOPRIGHT", -8, -10 - (index - 1) * 32)

    local selected = b:CreateTexture(nil, "BACKGROUND")
    selected:SetAllPoints()
    selected:SetColorTexture(GOLD.r, GOLD.g, GOLD.b, 0.14)
    selected:Hide()
    b.selected = selected
    local bar = b:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("BOTTOMLEFT")
    bar:SetWidth(3)
    bar:SetColorTexture(GOLD.r, GOLD.g, GOLD.b, 1)
    bar:Hide()
    b.bar = bar
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 10, 0)
    icon:SetTexture(entry.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon = icon
    local text = W.Label(b, entry.title, "GameFontHighlight")
    text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    b.text = text
    local badge = W.Label(b, L["soon"], "GameFontDisableSmall")
    badge:SetPoint("RIGHT", -8, 0)
    b.badge = badge

    b:SetScript("OnClick", function() UI:SelectPage(entry.id) end)
    return b
end

function UI:Create()
    if self.window then return self.window end
    local win = W.CreatePanel(UIParent, W.COLORS.panel, 1, "CasualHubMainFrame")
    self.window = win
    win:Hide()
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetResizeBounds then
        win:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    elseif win.SetMinResize then
        win:SetMinResize(MIN_W, MIN_H)
    end
    win:SetSize(clampSize(CH.Settings:Get("window.width"), CH.Settings:Get("window.height")))
    win:SetScale(CH.Settings:Get("scale"))
    applyPosition(win)
    tinsert(UISpecialFrames, "CasualHubMainFrame")

    -- Title bar (drag handle)
    local titleBar = CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", -4, -4)
    titleBar:SetHeight(TITLE_HEIGHT - 4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        if not CH.Settings:Get("lockWindow") then win:StartMoving() end
    end)
    titleBar:SetScript("OnDragStop", function()
        win:StopMovingOrSizing()
        savePosition(win)
    end)
    local crest = titleBar:CreateTexture(nil, "ARTWORK")
    crest:SetSize(34, 34)
    crest:SetPoint("LEFT", 6, 0)
    crest:SetTexture(CH.ICON)
    local title = W.Heading(titleBar, "Casual Hub")
    title:SetPoint("LEFT", crest, "RIGHT", 8, 0)
    win.guildLabel = W.Label(titleBar, "", "GameFontHighlight", W.COLORS.muted)
    win.guildLabel:SetPoint("LEFT", title, "RIGHT", 12, -1)
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    local titleRule = W.Divider(win)
    titleRule:SetPoint("TOPLEFT", 4, -TITLE_HEIGHT)
    titleRule:SetPoint("TOPRIGHT", -4, -TITLE_HEIGHT)

    -- Sidebar
    local sidebar = W.CreatePanel(win, W.COLORS.sidebar, 0)
    sidebar:SetPoint("TOPLEFT", 4, -TITLE_HEIGHT - 1)
    sidebar:SetPoint("BOTTOMLEFT", 4, 4)
    sidebar:SetWidth(SIDEBAR_WIDTH)
    for i, entry in ipairs(CH.NAVIGATION) do
        self.navButtons[entry.id] = createNavButton(sidebar, entry, i)
    end
    local version = W.Label(sidebar, "v" .. tostring(CH.version), "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", 12, 10)

    -- Workspace
    local content = CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", -4, 4)
    content:SetClipsChildren(true)
    self.content = content

    -- Resize grip
    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        if not CH.Settings:Get("lockWindow") then win:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        win:StopMovingOrSizing()
        local w, h = clampSize(win:GetSize())
        CH.Settings:Set("window.width", math.floor(w + 0.5))
        CH.Settings:Set("window.height", math.floor(h + 0.5))
        savePosition(win)
    end)
    win.grip = grip

    win:SetScript("OnShow", function()
        UI:RefreshHeader()
        CH.Events:Publish("WINDOW_SHOWN")
    end)
    win:SetScript("OnHide", function()
        local spec = UI.currentPage and UI.pages[UI.currentPage]
        if spec and spec.onHide and UI.pageFrames[UI.currentPage] then
            CH.SafeCall("page hide " .. UI.currentPage, spec.onHide, UI.pageFrames[UI.currentPage])
        end
        CH.Events:Publish("WINDOW_HIDDEN")
    end)

    CH.Events:Subscribe("SETTING_CHANGED", "UI", function(path, value)
        if path == "scale" then
            win:SetScale(value)
        elseif path == "lockWindow" then
            grip:SetShown(not value)
        end
    end)
    CH.Events:Subscribe("GUILD_CHANGED", "UI", function() UI:RefreshHeader() end)
    grip:SetShown(not CH.Settings:Get("lockWindow"))

    self:RefreshNav()
    return win
end

function UI:RefreshHeader()
    if not self.window then return end
    local guild = CH.Identity:GuildName()
    self.window.guildLabel:SetText(guild or L["no guild"])
end

-- A number next to a sidebar entry (for example unread notices); 0 or nil hides it.
function UI:SetNavCount(id, count)
    self.navCounts = self.navCounts or {}
    self.navCounts[id] = count
    if self.navButtons then self:RefreshNav() end
end

function UI:RefreshNav()
    for id, button in pairs(self.navButtons) do
        local isSelected = id == self.currentPage
        button.selected:SetShown(isSelected)
        button.bar:SetShown(isSelected)
        local count = self.navCounts and self.navCounts[id]
        if self.pages[id] == nil then
            button.badge:SetText(L["soon"])
            button.badge:SetShown(true)
        elseif count and count > 0 then
            button.badge:SetText("|cffd4af37" .. count .. "|r")
            button.badge:SetShown(true)
        else
            button.badge:SetShown(false)
        end
        if isSelected then
            button.text:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
        else
            button.text:SetTextColor(0.92, 0.90, 0.85)
        end
    end
end

function UI:SelectPage(id)
    local entry = CH.NavigationEntry(id)
    if not entry then id, entry = "dashboard", CH.NavigationEntry("dashboard") end
    -- A disabled Dashboard module has no page; fall back to Settings rather than a blank placeholder.
    if id == "dashboard" and not self.pages.dashboard then id, entry = "settings", CH.NavigationEntry("settings") end
    self:Create()

    local previous = self.currentPage
    if previous and previous ~= id then
        local frame = self.pageFrames[previous]
        local spec = self.pages[previous]
        if frame then
            frame:Hide()
            if spec and spec.onHide then CH.SafeCall("page hide " .. previous, spec.onHide, frame) end
        end
    end

    local frame = self.pageFrames[id]
    local spec = self.pages[id]
    if not frame then
        frame = CreateFrame("Frame", nil, self.content)
        frame:SetAllPoints()
        self.pageFrames[id] = frame
        if spec and spec.build then
            CH.SafeCall("page build " .. id, spec.build, frame)
        else
            buildPlaceholder(frame, entry)
        end
    end
    frame:Show()
    self.currentPage = id
    CH.Settings:Set("lastPage", id)
    if spec and spec.onShow then CH.SafeCall("page show " .. id, spec.onShow, frame) end
    self:RefreshNav()
end

function UI:Show(pageId)
    local win = self:Create()
    -- Show first so the page's onShow sees a visible frame.
    win:Show()
    self:SelectPage(pageId or self.currentPage or CH.Settings:Get("lastPage"))
end

function UI:Hide()
    if self.window then self.window:Hide() end
end

function UI:Toggle()
    if self.window and self.window:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function UI:ResetPosition()
    for _, key in ipairs({ "point", "relativePoint", "x", "y" }) do
        CH.Settings:Set("window." .. key, nil)
    end
    if self.window then applyPosition(self.window) end
    CH:Print(L["window position reset"])
end
