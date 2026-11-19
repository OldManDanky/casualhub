-- Launchers: a draggable minimap button (optional) and the Addon Compartment entry (declared in the .toc).
local _, GH = ...
local L = GH.L
local GOLD = GH.GOLD

local Launcher = {}
GH.Launcher = Launcher

local ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"

local function showTooltip(owner, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_LEFT")
    GameTooltip:SetText("GuildHub", GOLD.r, GOLD.g, GOLD.b)
    GameTooltip:AddLine(L["Left-click: open or close"], 1, 1, 1)
    GameTooltip:AddLine(L["Right-click: settings"], 1, 1, 1)
    GameTooltip:Show()
end

local function onClick(button)
    if button == "RightButton" then
        GH.UI:Show("settings")
    else
        GH.UI:Toggle()
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
    local b = CreateFrame("Button", "GuildHubMinimapButton", Minimap)
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
    icon:SetSize(18, 18)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(_, button) GH.SafeCall("minimap click", onClick, button) end)
    b:SetScript("OnEnter", function(self) showTooltip(self) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", onDragUpdate)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if self.angle then GH.Settings:Set("minimap.angle", math.floor(self.angle + 0.5)) end
    end)

    self.button = b
    placeButton(b, GH.Settings:Get("minimap.angle"))
    return b
end

function Launcher:Refresh()
    if GH.Settings:Get("minimap.show") then
        local b = self:CreateMinimapButton()
        if b then b:Show() end
    elseif self.button then
        self.button:Hide()
    end
end

function Launcher:Init()
    self:Refresh()
    GH.Events:Subscribe("SETTING_CHANGED", "Launcher", function(path)
        if path == "minimap.show" then Launcher:Refresh() end
    end)
end

-- Addon Compartment callbacks (names referenced from GuildHub.toc).
function GuildHub_OnAddonCompartmentClick(_, buttonName)
    GH.SafeCall("compartment click", onClick, buttonName)
end

function GuildHub_OnAddonCompartmentEnter(_, menuButtonFrame)
    showTooltip(menuButtonFrame, "ANCHOR_LEFT")
end

function GuildHub_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
