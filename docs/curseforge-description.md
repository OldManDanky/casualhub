# Casual Hub

**Your guild, in one window.** Find who plays when, put groups together, plan events, find crafters and keep everyone up to date, all inside the game and shared with every guildmate who runs Casual Hub.

Built for *Da Filthy Casuals* on WoW Forever, but it works for any guild. There's no server and no website: guildmates' addons share data directly over the guild channel, so the more of your guild runs it, the more useful it gets.

---

## Features

### 🏠 Dashboard
The guild message of the day, pinned notices, upcoming events and open activities at a glance.

### 👥 Members
Fill in a short profile: your roles, what you enjoy (quests, dungeons, raids, PvP...), when you usually play, and your main if this is an alt. Browse and filter everyone else's to see who's online and who's up for what.

### 📋 Activities
Need help with a quest, a dungeon run or an attunement? Post it on the board. Guildmates volunteer, you accept who you want, and you get a heads-up when someone volunteers or when you're accepted.

### 📅 Events
Schedule raids, dungeons, world bosses, PvP nights or socials with tank, healer and DPS slots. Members sign up for a role, extras go on a waitlist in sign-up order, and the organizer can confirm or bench people. Officers can mark events as official. You get a reminder before it starts, and you can repeat an event weekly with one click.

### 🔨 Professions
Open your profession window once and your recipes are shared with the guild automatically. Search for anything, like "Earthen Leather Shoulders", to see who can make it, check the materials it needs, and ask a crafter directly. You can also post crafting requests and offers.

**With Auctionator installed** (optional), you also get material costs and sale prices from your last scan, item tooltips with prices, and a one-click shopping list for a recipe's materials.

### 🚫 Blacklist
A shared list of players to avoid, each with a reason. Any member can add someone. You get a popup and an alert sound when you join a group with them or they invite you, a marker on their tooltip, and a chat warning when they whisper you or open a trade. Entries can be removed by whoever added them or by an officer.

### 📌 Bulletin
Officers post announcements and guild rules, and new members get a welcome checklist to work through. The Guild Master can set which ranks count as officers and who may post. Officers also get simple weekly activity reports, which can be exported to CSV.

---

## How to use it

### Install
1. Download the latest file (or install with the CurseForge app).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\` so that you get a `CasualHub` folder there.
3. **Restart the game completely.** A `/reload` won't pick up a new addon.

### First steps
1. Type **`/chub`**, or click the Casual Hub icon on the minimap or in the addon menu, to open the window.
2. Go to **Members** and fill in your profile, so people know what you play and when.
3. **Open each of your profession windows once.** That shares your recipes with the guild.
4. Check the **Dashboard** for what's happening, and the **Bulletin** for guild notices and your welcome checklist.

### Everyday use
- **Looking for help?** Activities → *New request*. Pick a category, say what you need and how many people. Accept volunteers as they come in.
- **Running something bigger?** Events → *New event*. Set the time, the roles you need and the minimum level. People sign up from the Events page.
- **Need a crafter?** Professions → search for the item → pick a crafter → *Whisper*.
- **Bad experience with someone?** Blacklist → *Add player*, type their name and a short reason.

### Commands
| Command | What it does |
|---|---|
| `/chub` | Open or close the window |
| `/chub <page>` | Open a page: `dashboard`, `members`, `blacklist`, `activities`, `events`, `professions`, `bulletin`, `settings` |
| `/chub help` | List all commands |
| `/chub resetwindow` | Move the window back to the center of the screen |
| `/chub version` | Show the addon version |
| `/chub diag` | Diagnostics report (useful when reporting a bug) |

### Settings
Under **Settings** you can turn sharing of your profile or professions off, choose which blacklist warnings you get, turn activity, event and notice alerts on or off, and set how early event reminders arrive.

---

## Good to know
- **Only shared with your guild.** Data travels over the guild addon channel and is only shown to members of the same guild. If you're not in a guild, the pages are empty and nothing is sent.
- **It syncs in the background.** When you log in, Casual Hub catches up with whoever else is online. Things posted while you were offline reach you the next time you're online with someone who has them.
- **Light on resources.** Messages are small and rate-limited, and a guild of 50 or so uses about 50 KB of saved data.
- **Older versions keep working together**, but please update to get the newest features.

## Feedback & source
This is a beta. Bug reports and ideas are welcome: post a comment here or open an issue on GitHub. If something breaks, include the output of `/chub diag`.

Source code (MIT license): https://github.com/OldManDanky/casualhub
