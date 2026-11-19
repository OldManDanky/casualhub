-- Settings page (in the main window) plus a small entry in Blizzard's Settings > AddOns list.
local _, CH = ...
local L = CH.L
local W = CH.Widgets

local SettingsPage = {}
local MODULE = "Settings"

local function formatScale(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end

function SettingsPage:Build(frame)
    self.frame = frame
    local y = CH.UI:PageHeader(frame, L["Settings"], L["Saved for your account; applies to every character."])
    local S = CH.Settings

    -- Appearance -------------------------------------------------------------
    local appearance = W.Card(frame, L["Window"])
    appearance:SetPoint("TOPLEFT", 20, y)
    appearance:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    appearance:SetHeight(140)

    local scale = W.Slider(appearance, L["Window scale"], 0.6, 1.5, 0.05, formatScale, function(v) S:Set("scale", v) end)
    scale:SetPoint("TOPLEFT", 14, -34)
    frame.scale = scale

    frame.lock = W.Checkbox(appearance, L["Lock window position and size"], nil, function(v) S:Set("lockWindow", v) end)
    frame.lock:SetPoint("TOPLEFT", 12, -82)
    frame.minimap = W.Checkbox(appearance, L["Show minimap button"],
        L["Casual Hub is also in the addon menu (the button under the minimap) whether or not this is on."],
        function(v) S:Set("minimap.show", v) end)
    frame.minimap:SetPoint("TOPLEFT", 12, -106)

    local reset = W.Button(appearance, L["Reset position"], 130, function() CH.UI:ResetPosition() end)
    reset:SetPoint("TOPRIGHT", -14, -34)

    -- Sharing ----------------------------------------------------------------
    local sharing = W.Card(frame, L["Sharing and notifications"])
    sharing:SetPoint("TOPLEFT", appearance, "BOTTOMLEFT", 0, -12)
    sharing:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    sharing:SetHeight(64)
    frame.share = W.Checkbox(sharing, L["Share my profile with the guild"],
        L["When off, guildmates' copies of your profile are removed and nothing is sent."],
        function(v) S:Set("profile.share", v) end)
    frame.share:SetPoint("TOPLEFT", 12, -32)
    frame.notifyActivities = W.Checkbox(sharing, L["Activity Board messages in chat"],
        L["A chat line when someone volunteers for your request, or you're accepted for one."],
        function(v) S:Set("notifications.activities", v) end)
    frame.notifyActivities:SetPoint("TOPLEFT", 300, -32)

    -- Modules ----------------------------------------------------------------
    local modules = W.Card(frame, L["Modules"])
    modules:SetPoint("TOPLEFT", sharing, "BOTTOMLEFT", 0, -12)
    modules:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    modules.body:SetText("|cff999999" .. L["Turn sections on or off. Changes apply after a UI reload."] .. "|r")
    frame.moduleChecks = {}
    local row = 0
    for _, m in ipairs(CH.Modules.list) do
        if not m.required then
            row = row + 1
            local cb = W.Checkbox(modules, m.name, m.description, function(v)
                CH.Settings:SetModuleEnabled(m.name, v)
                SettingsPage:RefreshReloadHint()
            end)
            -- Two columns keep the page within the default window height.
            cb:SetPoint("TOPLEFT", 12 + ((row - 1) % 2) * 260, -50 - math.floor((row - 1) / 2) * 26)
            local status = W.Label(modules, "", "GameFontHighlightSmall", W.COLORS.muted)
            status:SetPoint("LEFT", cb.label, "RIGHT", 10, 0)
            cb.status = status
            cb.module = m
            frame.moduleChecks[#frame.moduleChecks + 1] = cb
        end
    end
    modules:SetHeight(64 + math.max(math.ceil(row / 2), 1) * 26)
    frame.reloadButton = W.Button(modules, L["Reload UI"], 110, function() ReloadUI() end)
    frame.reloadButton:SetPoint("TOPRIGHT", -14, -10)

    -- Diagnostics ------------------------------------------------------------
    local diag = W.Card(frame, L["Diagnostics"])
    diag:SetPoint("TOPLEFT", modules, "BOTTOMLEFT", 0, -12)
    diag:SetPoint("RIGHT", frame, "RIGHT", -20, 0)
    diag:SetHeight(96)
    diag.body:SetText(("|cff999999Casual Hub %s  |  %s %s|r"):format(tostring(CH.version),
        tostring(CH.Compat.buildVersion), tostring(CH.Compat.buildNumber)))
    frame.debug = W.Checkbox(diag, L["Debug logging in chat"], L["Prints internal log messages to your chat frame."],
        function(v) S:Set("debug", v) end)
    frame.debug:SetPoint("TOPLEFT", 12, -56)
    local open = W.Button(diag, L["Open diagnostics"], 140, function() CH.Diagnostics:Show() end)
    open:SetPoint("TOPRIGHT", -14, -10)
    local clear = W.Button(diag, L["Clear saved errors"], 140, function()
        CH.Diagnostics:ClearErrors()
        CH:Print(L["saved errors cleared"])
    end)
    clear:SetPoint("TOPRIGHT", open, "BOTTOMRIGHT", 0, -6)
end

local STATE_LABELS = {
    running = "running", disabled = "off", unsupported = "unsupported on this client",
    blocked = "blocked", failed = "failed (see diagnostics)", registered = "not started",
}

function SettingsPage:RefreshReloadHint()
    local frame = self.frame
    local pending = false
    for _, cb in ipairs(frame.moduleChecks) do
        local wanted = CH.Settings:IsModuleEnabled(cb.module.name)
        local active = cb.module.state == "running"
        if wanted ~= active and cb.module.state ~= "unsupported" and cb.module.state ~= "failed" then pending = true end
    end
    frame.reloadButton:SetShown(pending)
end

function SettingsPage:OnShow()
    local frame, S = self.frame, CH.Settings
    frame.scale:SetValue(S:Get("scale"))
    frame.lock:SetChecked(S:Get("lockWindow"))
    frame.minimap:SetChecked(S:Get("minimap.show"))
    frame.debug:SetChecked(S:Get("debug"))
    frame.share:SetChecked(S:Get("profile.share") ~= false)
    frame.notifyActivities:SetChecked(S:Get("notifications.activities") ~= false)
    for _, cb in ipairs(frame.moduleChecks) do
        cb:SetChecked(S:IsModuleEnabled(cb.module.name))
        cb.status:SetText(L[STATE_LABELS[cb.module.state] or cb.module.state])
    end
    self:RefreshReloadHint()
end

-- Blizzard Settings > AddOns entry that opens the Casual Hub window.
local function registerBlizzardCategory()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local panel = CreateFrame("Frame")
    local heading = W.Heading(panel, "Casual Hub")
    heading:SetPoint("TOPLEFT", 16, -16)
    local text = W.Label(panel, L["Casual Hub's options live in its own window."], "GameFontHighlight")
    text:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -10)
    local open = W.Button(panel, L["Open Casual Hub settings"], 200, function()
        if SettingsPanel and SettingsPanel:IsShown() and HideUIPanel then HideUIPanel(SettingsPanel) end
        CH.UI:Show("settings")
    end)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
    local category = Settings.RegisterCanvasLayoutCategory(panel, "Casual Hub")
    Settings.RegisterAddOnCategory(category)
end

CH:RegisterModule(MODULE, {
    version = "0.1.0",
    required = true,
    description = L["Addon settings"],
    initialize = function()
        CH.UI:RegisterPage("settings", {
            build = function(frame) SettingsPage:Build(frame) end,
            onShow = function() SettingsPage:OnShow() end,
        })
        CH.SafeCall("register Blizzard settings", registerBlizzardCategory)
    end,
})
