# Casual Hub: development

How the addon is built, tested and released. Casual Hub is a WoW Forever guild addon (Interface 16001), built for Da Filthy Casuals. The spec is in `docs/GuildHub_Software_Design_Document_v0.1.docx`;
the client facts it is built on are in `docs/forever-compat.md`.

- `addons/CasualHub/` is the addon (`/chub` in-game). `addons/GuildHubProbe/` is the client compatibility probe (`/ghprobe`).
- `tests/run.sh` runs offline smoke tests in Lua 5.1 against a stubbed WoW API (`tests/wow_stub.lua`).
  `lua5.1 tests/run.lua perf` is a load test (120 members, thousands of records) that times the hot paths and reports memory.
- `./deploy.sh [AddonName]` syntax-checks the addons and copies them into the Forever AddOns folder.
  Then `/reload` in-game. Adding or removing files needs a full client restart, not just a `/reload`.
- `tools/release.sh NOTES.md` tags the TOC version, pushes, publishes a GitHub release with the addon zip, and uploads the same zip to CurseForge.
- `tools/png2tga.py` converts PNG artwork into the TGA textures WoW loads (e.g. `Media/icon64.tga` from the CasualBot icon).

Formerly "GuildHub" in the design doc; renamed because another addon already uses that name.

Licensed under the MIT License (see `LICENSE`).
