# GuildHub

A guild addon for WoW Forever (Interface 16001). The spec is in `docs/GuildHub_Software_Design_Document_v0.1.docx`;
the client facts it is built on are in `docs/forever-compat.md`.

- `addons/GuildHub/` is the addon (`/gh` in-game). `addons/GuildHubProbe/` is the client compatibility probe (`/ghprobe`).
- `tests/run.sh` runs offline smoke tests in Lua 5.1 against a stubbed WoW API (`tests/wow_stub.lua`).
- `./deploy.sh [AddonName]` syntax-checks the addons and copies them into the Forever AddOns folder.
  Then `/reload` in-game. Adding or removing files needs a full client restart, not just a `/reload`.
