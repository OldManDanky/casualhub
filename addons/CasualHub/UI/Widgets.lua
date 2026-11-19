-- Shared widget constructors: dark fantasy panels with gold accents (design doc §2, §5).
local _, CH = ...
local L = CH.L

local W = {}
CH.Widgets = W

local GOLD = CH.GOLD
W.COLORS = {
    panel = { 0.06, 0.05, 0.07, 0.96 },
    inset = { 0.10, 0.09, 0.11, 0.90 },
    sidebar = { 0.04, 0.035, 0.05, 0.98 },
    muted = { 0.62, 0.60, 0.56 },
    text = { 0.92, 0.90, 0.85 },
}

local BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

function W.ApplyPanel(frame, color, borderAlpha)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop(BACKDROP)
    local c = color or W.COLORS.panel
    frame:SetBackdropColor(c[1], c[2], c[3], c[4] or 1)
    frame:SetBackdropBorderColor(GOLD.r, GOLD.g, GOLD.b, borderAlpha or 0.9)
end

function W.CreatePanel(parent, color, borderAlpha, name)
    local frame = CreateFrame("Frame", name, parent, BACKDROP_TEMPLATE)
    W.ApplyPanel(frame, color, borderAlpha)
    return frame
end

function W.Label(parent, text, font, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetText(text or "")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    fs:SetJustifyH("LEFT")
    return fs
end

function W.Heading(parent, text)
    local fs = W.Label(parent, text, "GameFontNormalLarge")
    fs:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
    return fs
end

-- Gold rule under headings.
function W.Divider(parent)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetColorTexture(GOLD.r, GOLD.g, GOLD.b, 0.35)
    tex:SetHeight(1)
    return tex
end

function W.Tooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, GOLD.r, GOLD.g, GOLD.b)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

function W.Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 120, 22)
    b:SetText(text)
    if onClick then b:SetScript("OnClick", function(self, button) CH.SafeCall("button " .. text, onClick, self, button) end) end
    return b
end

function W.Checkbox(parent, text, tooltip, onToggle)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local label = W.Label(cb, text)
    label:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    cb.label = label
    cb:SetHitRectInsets(0, -(label:GetStringWidth() + 8), 0, 0)
    if tooltip then W.Tooltip(cb, text, tooltip) end
    cb:SetScript("OnClick", function(self)
        if onToggle then CH.SafeCall("checkbox " .. text, onToggle, self:GetChecked() and true or false) end
    end)
    return cb
end

-- Horizontal slider. onCommit fires when the user releases the thumb (not on every drag tick),
-- so settings like UI scale do not rescale the window under the cursor mid-drag.
function W.Slider(parent, text, minValue, maxValue, step, formatValue, onCommit)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(240, 40)
    local label = W.Label(holder, text)
    label:SetPoint("TOPLEFT")
    local valueText = W.Label(holder, "", "GameFontHighlightSmall", W.COLORS.muted)
    valueText:SetPoint("TOPRIGHT")

    local s = CreateFrame("Slider", nil, holder, BACKDROP_TEMPLATE)
    s:SetOrientation("HORIZONTAL")
    s:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    s:SetPoint("RIGHT", holder, "RIGHT")
    s:SetHeight(16)
    if s.SetBackdrop then
        s:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
    end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)

    local function rounded(v)
        return math.floor(v / step + 0.5) * step
    end
    local function commit(self)
        if self.updating then return end
        local v = rounded(self:GetValue())
        if v ~= self.committed then
            self.committed = v
            if onCommit then CH.SafeCall("slider " .. text, onCommit, v) end
        end
    end
    s:SetScript("OnValueChanged", function(self, v)
        valueText:SetText(formatValue and formatValue(rounded(v)) or tostring(rounded(v)))
        local dragging = self.IsDraggingThumb and self:IsDraggingThumb()
        if not dragging then commit(self) end
    end)
    s:SetScript("OnMouseUp", commit)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.min(maxValue, math.max(minValue, self:GetValue() + delta * step)))
    end)

    function holder:SetValue(v)
        s.updating = true
        s.committed = rounded(v)
        s:SetValue(v)
        valueText:SetText(formatValue and formatValue(rounded(v)) or tostring(rounded(v)))
        s.updating = false
    end
    holder.slider = s
    return holder
end

-- A titled panel used for dashboard cards and settings groups.
function W.Card(parent, title)
    local card = W.CreatePanel(parent, W.COLORS.inset, 0.5)
    local heading = W.Label(card, title, "GameFontNormal")
    heading:SetTextColor(GOLD.r, GOLD.g, GOLD.b)
    heading:SetPoint("TOPLEFT", 12, -10)
    card.title = heading
    local body = W.Label(card, "", "GameFontHighlight")
    body:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    body:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    card.body = body
    return card
end

-- Single reusable dialog with selectable text (diagnostics, exports).
local copyDialog
function W.CopyDialog(title, text)
    if not copyDialog then
        local f = W.CreatePanel(UIParent, W.COLORS.panel, 1, "CasualHubCopyDialog")
        f:SetSize(760, 520)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetToplevel(true)
        f:SetClampedToScreen(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "CasualHubCopyDialog")

        f.heading = W.Heading(f, "")
        f.heading:SetPoint("TOPLEFT", 16, -14)
        local hint = W.Label(f, L["Ctrl+A then Ctrl+C to copy"], "GameFontHighlightSmall", W.COLORS.muted)
        hint:SetPoint("LEFT", f.heading, "RIGHT", 12, 0)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)

        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -44)
        scroll:SetPoint("BOTTOMRIGHT", -36, 16)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(700)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit
        copyDialog = f
    end
    copyDialog.heading:SetText(title)
    copyDialog.edit:SetText(text)
    copyDialog.edit:SetCursorPosition(0)
    copyDialog:Show()
    return copyDialog
end
