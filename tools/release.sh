#!/usr/bin/env bash
# Publish a GitHub release of an addon at the version in its TOC.
#
#   tools/release.sh NOTES.md [AddonName]
#
# Checks the tree is clean and tests pass, builds dist/<Addon>-<x.y.z>-forever.zip
# (just the addon folder, ready to unzip into AddOns), tags v<version>, pushes
# main and the tag, creates the release (marked Latest) and uploads the zip.
#
# Token: $GITHUB_TOKEN, or the file ~/.config/casualhub/github_token (chmod 600).
# It needs a fine-grained token for this repo with Contents: read and write.
#
# CurseForge: the same zip is also uploaded there when ~/.config/casualhub/curseforge_token
# (or $CF_API_TOKEN) exists. Project id and game version ids are below; list the ids with
#   tools/release.sh --cf-versions
set -euo pipefail

CF_PROJECT_ID=${CF_PROJECT_ID:-1819129}      # CurseForge project id (About Project box on the project page)
CF_GAME_VERSIONS=${CF_GAME_VERSIONS:-17053}  # WoW Forever 1.60.1 (Interface 16001); comma-separate for more
# Uploaded as "release" so the CurseForge app installs it by default (it skips alpha/beta
# files unless a player opts in), matching "Latest" on GitHub. CF_RELEASE_TYPE=alpha overrides.
CF_API=https://wow.curseforge.com/api
CF_TOKEN=${CF_API_TOKEN:-}
CF_TOKEN_FILE="$HOME/.config/casualhub/curseforge_token"
if [[ -z "$CF_TOKEN" && -r "$CF_TOKEN_FILE" ]]; then CF_TOKEN=$(tr -d '[:space:]' < "$CF_TOKEN_FILE"); fi
cf_header() { local f; f=$(mktemp); chmod 600 "$f"; printf 'X-Api-Token: %s\n' "$CF_TOKEN" > "$f"; echo "$f"; }

if [[ "${1:-}" == --cf-versions ]]; then
    [[ -n "$CF_TOKEN" ]] || { echo "no CurseForge token in $CF_TOKEN_FILE" >&2; exit 1; }
    H=$(cf_header); trap 'rm -f "$H"' EXIT
    curl -sS --fail-with-body -H @"$H" "$CF_API/game/versions" | python3 -I -c '
import json,sys
for v in json.load(sys.stdin): print(v["id"], v["gameVersionTypeID"], v["name"])'
    exit 0
fi

NOTES=${1:?usage: tools/release.sh NOTES.md [AddonName]}
ADDON=${2:-CasualHub}
REPO=${GITHUB_REPO:-OldManDanky/casualhub}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

TOKEN=${GITHUB_TOKEN:-}
TOKEN_FILE="$HOME/.config/casualhub/github_token"
if [[ -z "$TOKEN" && -r "$TOKEN_FILE" ]]; then TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE"); fi
[[ -n "$TOKEN" ]] || { echo "no token: set GITHUB_TOKEN or create $TOKEN_FILE" >&2; exit 1; }
[[ -r "$NOTES" ]] || { echo "notes file not found: $NOTES" >&2; exit 1; }
CF=false
if [[ -n "$CF_TOKEN" ]]; then
    [[ -n "$CF_PROJECT_ID" && -n "$CF_GAME_VERSIONS" ]] || { echo "CurseForge token found but CF_PROJECT_ID/CF_GAME_VERSIONS not set" >&2; exit 1; }
    CF=true
fi

VERSION=$(grep -m1 '^## Version:' "addons/$ADDON/$ADDON.toc" | awk '{print $3}' | tr -d '\r')
TAG="v$VERSION"
# Asset name required by the Forever addon listings: <Addon>-<major.minor.patch>-forever.zip
# (the pre-release suffix stays on the tag and release title, not the file name).
ZIP="dist/$ADDON-${VERSION%%-*}-forever.zip"
# Published as a normal release so it shows as "Latest" on the repo page (pre-releases never do),
# even for -alpha versions. Set PRERELEASE=true in the environment to override.
PRERELEASE=${PRERELEASE:-false}

[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "not on main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "tag $TAG already exists" >&2; exit 1; fi

echo "== tests"; tests/run.sh > /dev/null || { echo "tests failed" >&2; exit 1; }

# Keep the token out of argv: hand curl a private header file.
HDR=$(mktemp); chmod 600 "$HDR"; trap 'rm -f "$HDR"' EXIT
printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$TOKEN" > "$HDR"
api() { curl -sS --fail-with-body -H @"$HDR" "$@"; }
api "https://api.github.com/repos/$REPO" > /dev/null || { echo "token can't access $REPO" >&2; exit 1; }

echo "== build $ZIP"
mkdir -p dist
git archive --format=zip --prefix="$ADDON/" -o "$ZIP" "HEAD:addons/$ADDON"

echo "== tag $TAG and push"
git tag -a "$TAG" -F "$NOTES"
git push -q origin main "$TAG"

echo "== create release"
BODY=$(python3 -I -c 'import json,sys; print(json.dumps({"tag_name": sys.argv[1], "name": sys.argv[2],
    "body": open(sys.argv[3], encoding="utf-8").read(), "prerelease": sys.argv[4] == "true", "make_latest": "false" if sys.argv[4] == "true" else "true"}))' \
    "$TAG" "Casual Hub $VERSION" "$NOTES" "$PRERELEASE")
RELEASE=$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")
read -r RID URL < <(printf '%s' "$RELEASE" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r["id"], r["html_url"])')

echo "== upload $(basename "$ZIP")"
api -X POST -H "Content-Type: application/zip" --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$(basename "$ZIP")" > /dev/null

echo "released $TAG: $URL"

if $CF; then
    echo "== upload to CurseForge"
    CFH=$(cf_header); META=$(mktemp); trap 'rm -f "$HDR" "$CFH" "$META"' EXIT
    python3 -I -c 'import json,sys; json.dump({"changelog": open(sys.argv[1], encoding="utf-8").read(),
        "changelogType": "markdown", "displayName": sys.argv[2], "releaseType": sys.argv[3],
        "gameVersions": [int(x) for x in sys.argv[4].split(",")]}, open(sys.argv[5], "w"))' \
        "$NOTES" "Casual Hub $VERSION" "${CF_RELEASE_TYPE:-release}" \
        "$CF_GAME_VERSIONS" "$META"
    curl -sS --fail-with-body -H @"$CFH" -F "metadata=<$META;type=application/json" -F "file=@$ZIP" \
        "$CF_API/projects/$CF_PROJECT_ID/upload-file" > /dev/null \
        || { echo "CurseForge upload failed (GitHub release is done)" >&2; exit 1; }
    echo "uploaded to CurseForge project $CF_PROJECT_ID"
fi
