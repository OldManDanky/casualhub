# WoW Forever compatibility findings

Source: `addons/GuildHubProbe` 0.1.0 and 0.3.0, run 2026-11-19 on build **1.60.1.70959** (Nov 13 2026),
character level 29 Hunter, Guild Master of a 55-member guild. Design doc §10 asks for these facts.

## Client
| Fact | Value |
|---|---|
| `## Interface` | `16001` |
| `WOW_PROJECT_ID` | `18` (`WOW_PROJECT_CAMELOT`). Use it to detect Forever. |
| Lua | 5.1; `bit` is available, `utf8` is not |
| Max level / expansion | 60 / 0 |
| API style | **Modern Retail namespaces** on a 1.x ruleset |

## Character names have surnames
- Names are **`First Last`** (example: `Ghazneth Strongbow`). All 55 roster names had this format, and no realm appears anywhere.
- `UnitName("player")` and `UnitFullName("player")` return `"First", "Last"`. The surname is the
  second return value, where Retail returns the realm.
- `GetUnitName("player", true|false)` returns `"First Last"`.
- Roster names (`GetGuildRosterInfo` field 1) and addon-message senders are `"First Last"`.
- **First names are not unique.** The guild had 55 members with 55 distinct full names but only 50
  distinct first names. The identity key must be the full name, or the GUID (`Player-6933-...`,
  roster field 17).
- Whispers reach the player at `"First Last"` and at `"First-Last"`. They do not reach `"First"` alone.
  An addon-message whisper to a name that doesn't resolve (first name only, or someone offline) prints the
  visible system error `No player named '...' is currently playing.` in chat. Only whisper full names of
  members who are online, or filter that system message for whispers the addon sent.
- `Ambiguate()` has nothing to strip here. Never split a name on its space.
- The WTF per-character folder is named `First-Last`.
- **Forever has no realms in the usual sense; it has rulesets:** Normal (PvE), PvP, RP-PvP and Hardcore.
  The "realm" strings the API returns (`CAMWOWUS2Realm7PvE`) look like server instances within a ruleset.
- **Realm names are not stable.** `GetNormalizedRealmName()` returned `CAMWOWUS2Realm7PvE` (display name
  "CAMWOW US2 Realm 7 PvE"), but in the next session the same guild was keyed as `CAMWOWUS1Realm7PvE`,
  most likely from `GetGuildInfo`'s realm value. Don't build persistent keys from realm names; Casual Hub
  keys guild data by guild name alone.
- Measured 2026-11-19 in one session: `GetRealmID()` = `6933` (the same number as in the player GUID
  `Player-6933-...`), `GetNormalizedRealmName()` = `CAMWOWUS2Realm7PvE` (the player's current instance), and
  `GetGuildInfo` realm = `CAMWOWUS1Realm7PvE` (the guild's). `C_GameRules.IsHardcoreActive()` = false on
  Normal.
- **Realm IDs are per instance, not per ruleset.** The 55 members of one guild had 9 different GUID realm
  IDs (6794, 6796, 6797, 6921, 6923, 6925, 6929, 6931, 6933; 4 to 8 members each). A guild spans
  instances, so neither realm IDs nor realm names identify a guild or a ruleset. Casual Hub keys guilds by name
  and characters by "First Last" (unique across instances, since guildmates on different instances coexist).
  If a ruleset key is ever needed, candidates are `C_GameRules.IsHardcoreActive()` and the PvE/PvP suffix
  of the realm name; both are unverified.

## Addon messaging
- `C_ChatInfo.RegisterAddonMessagePrefix`, `SendAddonMessage` and `SendAddonMessageLogged` work.
  The legacy global functions are missing.
- GUILD and WHISPER messages are delivered. A message to yourself arrives in about 0.06–0.2 s.
- **The payload limit is 255 bytes and longer messages are cut off without an error.** Messages of
  256 and 4000 bytes reported `Success` but arrived as 255 bytes. Any message over 255 bytes must be
  split into chunks and the length checked before sending.
- `C_ChatInfo.InChatMessagingLockdown()` exists. It returned false in the open world. Instance and
  combat restrictions are not tested yet.
- No secret values were seen in payloads or sender names (open world, out of combat).

## Guild
- `C_GuildInfo.GuildRoster()` works; the legacy `GuildRoster()` is missing. `GetGuildRosterInfo`
  returns 17 values in the Retail order.
- The roster is populated at login, before any request. `GUILD_ROSTER_UPDATE` fired 0.18 s after a
  request on one run and not within 10 s on the run right after login (throttling). Don't wait on it.
- `GetGuildInfo("player")` returns name, rankName, rankIndex (0 = GM), realm.
- `GuildControlGetNumRanks` / `GuildControlGetRankName` work (5 ranks).
- Permissions use `C_GuildInfo.CanViewOfficerNote/CanEditOfficerNote/IsGuildOfficer`. The legacy
  `CanViewOfficerNote` and `CanEditOfficerNote` are missing. `CanEditMOTD`, `CanEditPublicNote` and
  `IsGuildLeader` are present.
- `GetGuildRosterLastOnline` returns 4 numbers for offline members.

## Professions
- Uses the Retail API: `GetProfessions()` returns `prof1, prof2, nil, fishing, cooking`, and
  `GetProfessionInfo(i)` returns 11 values (name, icon, rank, max, ...).
- The Classic API is missing: `GetSkillLineInfo`, `GetNumSkillLines`, `GetTradeSkill*`, `GetCraft*`,
  and the `CRAFT_*` events.
- With a profession window open, `C_TradeSkillUI.GetAllRecipeIDs` returns **every recipe in the
  profession, learned or not**. Leatherworking returned 132 in one capture and 592 in another, and
  the sampled recipes had `learned = false`. Filter on `GetRecipeInfo(id).learned`.
- `C_TradeSkillUI.GetRecipeInfo(id)` returns the Retail `TradeSkillRecipeInfo` table (`recipeID`,
  `name`, `learned`, `craftable`, `categoryID`, `hyperlink`, `icon`, `maxTrivialLevel`, ...).
  `GetRecipeLink(id)` works.
- `C_TradeSkillUI.GetBaseProfessionInfo()` returns `professionID` (165 = Leatherworking),
  `professionName`, `skillLevel`, `maxSkillLevel` and `isPrimaryProfession`. The child
  (expansion-tier) profession info is empty.
- `GetTradeSkillListLink()` returns a link (a shareable profession link may be possible).
  `IsTradeSkillLinked` and `IsTradeSkillGuild` are false for your own window.
- Recipe data is only available while the profession window is open, so GuildHub has to capture it on
  `TRADE_SKILL_SHOW` / `TRADE_SKILL_LIST_UPDATE` and cache it.
- Recipe IDs are spell IDs. Naming a recipe you don't know (measured 2026-11-19, 0.5.0):
  - `C_Spell.GetSpellName(id)` returns nothing until the client has loaded that spell. After
    `C_Spell.RequestLoadSpellData(id)` (and a moment) it returns the name.
  - `C_TradeSkillUI.GetRecipeInfo(id)` returns the recipe, with its name, **outside** the profession window too
    (tested on an unlearned recipe of a profession the character has).
  - The global `GetSpellInfo` is missing.
  - Casual Hub tries its cache, then GetSpellName, then GetRecipeInfo, then requests a load and fills in the name
    on `SPELL_DATA_LOAD_RESULT`.
- Forever adds recipes outside the classic lists, with IDs above 1,000,000 (for example Skinning "Camp Chair",
  Fishing "Fish Bowl", and Leatherworking items like "Skirmisher's Leather Gloves").

## Group, invites, whispers (measured 2026-11-20, 0.7.0)
- `PARTY_INVITE_REQUEST`, `CHAT_MSG_WHISPER` and `GROUP_ROSTER_UPDATE` fire, and the names they give
  (after `-` becomes a space) match the "First Last" key, so blacklist warnings work for invites,
  whispers and group joins. `StaticPopup_Show` works for addon popups.

## UI, settings, utilities
- Every template probed works: `BackdropTemplate`, `ButtonFrameTemplate`, `PortraitFrameTemplate`,
  `WowScrollBoxList` + `MinimalScrollBar`, `WowStyle1DropdownTemplate`, `ScrollingEditBoxTemplate`,
  sliders, and the check, close and input templates.
- `Settings.RegisterCanvasLayoutCategory` / `RegisterAddOnCategory` work.
  `InterfaceOptions_AddCategory` is missing.
- `AddonCompartmentFrame`, `MenuUtil.CreateContextMenu`, `CreateDataProvider` and `ScrollUtil` are present.
- `C_AddOns.GetAddOnMetadata` works; the global `GetAddOnMetadata` is missing.
- `C_EncodingUtil` provides CBOR, JSON, compression and Base64, so no bundled serializer is needed.
- `C_Timer`, `GetServerTime`, `C_DateAndTime` and `C_Calendar` are present.
- Secret-value functions are present (`issecretvalue`, `canaccessvalue`, `C_RestrictedActions...`).
- `ChatThrottleLib` is loaded globally by another addon. Don't rely on that; GuildHub needs its own throttle.

## Persistence
- SavedVariables (account-wide and per-character) were kept across both a logout and a `/reload`.

## Not tested yet
- Messaging inside instances, in combat, and during encounters (secret values or lockdown).
- Two clients exchanging messages (needs a guildmate running the probe).
- Throttle limits under bursts of messages.
- Ordinary chat events (guild, whisper, party) and PARTY-channel addon messages. The probe does not record these.
