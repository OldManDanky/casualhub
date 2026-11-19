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
