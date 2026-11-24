-- Sidebar sections (design doc §5). A section without a registered page shows its roadmap placeholder,
-- so later phases only need to call CH.UI:RegisterPage(id, spec).
local _, CH = ...
local L = CH.L

CH.NAVIGATION = {
    { id = "dashboard", title = L["Dashboard"], icon = "Interface\\Icons\\INV_Misc_Note_01" },
    { id = "members", title = L["Members"], icon = "Interface\\Icons\\INV_Misc_Head_Human_01", phase = 2,
        summary = L["Searchable roster with opt-in profiles: main/alt links, preferred roles, interests and availability."] },
    { id = "blacklist", title = L["Blacklist"], icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",
        summary = L["Players guildmates have flagged, with reasons and warnings when you meet them."] },
    { id = "activities", title = L["Activities"], icon = "Interface\\Icons\\INV_Misc_Map_01", phase = 3,
        summary = L["Post requests for quests, dungeons, attunements and world bosses; members volunteer and the organizer closes them."] },
    { id = "events", title = L["Events"], icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", phase = 4,
        summary = L["Scheduled events with role-based signups, waitlists, participant suggestions and reminders."] },
    { id = "professions", title = L["Professions"], icon = "Interface\\Icons\\Trade_BlackSmithing", phase = 5,
        summary = L["Find crafters by recipe, publish your professions and post crafting requests."] },
    { id = "prices", title = L["Prices"], icon = "Interface\\Icons\\INV_Misc_Coin_02",
        summary = L["Search auction prices from your Auctionator scans and ask guildmates for theirs."] },
    { id = "bulletin", title = L["Bulletin"], icon = "Interface\\Icons\\INV_Scroll_03", phase = 6,
        summary = L["Officer announcements, pinned guild rules and a welcome checklist for new members."] },
    { id = "settings", title = L["Settings"], icon = "Interface\\Icons\\INV_Misc_Gear_01" },
}

function CH.NavigationEntry(id)
    for _, entry in ipairs(CH.NAVIGATION) do
        if entry.id == id then return entry end
    end
end
