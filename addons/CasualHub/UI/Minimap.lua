-- Launchers: a draggable minimap button (optional) and the Addon Compartment entry (declared in the .toc).
local _, CH = ...
local L = CH.L
local GOLD = CH.GOLD

local Launcher = {}
CH.Launcher = Launcher


local function showTooltip(owner, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_LEFT")
    GameTooltip:SetText("Casual Hub", GOLD.r, GOLD.g, GOLD.b)
    GameTooltip:AddLine(L["Left-click: open or close"], 1, 1, 1)
    GameTooltip:AddLine(L["Right-click: settings"], 1, 1, 1)
    GameTooltip:Show()
end

local function onClick(button)
    if button == "RightButton" then
        CH.UI:Show("settings")
    else
        CH.UI:Toggle()
    end
end

local function placeButton(button, angle)
    local radians = math.rad(angle)
    local radius = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * radius, math.sin(radians) * radius)
end

local function onDragUpdate(button)
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    button.angle = angle
    placeButton(button, angle)
end

function Launcher:CreateMinimapButton()
    if self.button or not Minimap then return self.button end
    local b = CreateFrame("Button", "CasualHubMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(21, 21)
    icon:SetTexture(CH.ICON)
    icon:SetPoint("TOPLEFT", 6, -5)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(_, button) CH.SafeCall("minimap click", onClick, button) end)
    b:SetScript("OnEnter", function(self) showTooltip(self) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", onDragUpdate)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if self.angle then CH.Settings:Set("minimap.angle", math.floor(self.angle + 0.5)) end
    end)

    self.button = b
    placeButton(b, CH.Settings:Get("minimap.angle"))
    return b
end

function Launcher:Refresh()
    if CH.Settings:Get("minimap.show") then
        local b = self:CreateMinimapButton()
        if b then b:Show() end
    elseif self.button then
        self.button:Hide()
    end
end

function Launcher:Init()
    self:Refresh()
    CH.Events:Subscribe("SETTING_CHANGED", "Launcher", function(path)
        if path == "minimap.show" then Launcher:Refresh() end
    end)
end

-- Addon Compartment callbacks (names referenced from Casual Hub.toc).
function CasualHub_OnAddonCompartmentClick(_, buttonName)
    CH.SafeCall("compartment click", onClick, buttonName)
end

function CasualHub_OnAddonCompartmentEnter(_, menuButtonFrame)
    showTooltip(menuButtonFrame, "ANCHOR_LEFT")
end

function CasualHub_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
