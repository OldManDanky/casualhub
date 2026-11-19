#!/usr/bin/env bash
# Publish a GitHub release of an addon at the version in its TOC.
#
#   tools/release.sh NOTES.md [AddonName]
#
# Checks the tree is clean and tests pass, builds dist/<Addon>-<version>.zip
# (just the addon folder, ready to unzip into AddOns), tags v<version>, pushes
# main and the tag, creates the release (pre-release when the version contains
# alpha/beta/rc) and uploads the zip.
#
# Token: $GITHUB_TOKEN, or the file ~/.config/casualhub/github_token (chmod 600).
# It needs a fine-grained token for this repo with Contents: read and write.
set -euo pipefail

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

VERSION=$(grep -m1 '^## Version:' "addons/$ADDON/$ADDON.toc" | awk '{print $3}' | tr -d '\r')
TAG="v$VERSION"
ZIP="dist/$ADDON-$VERSION.zip"
PRERELEASE=false; [[ "$VERSION" =~ (alpha|beta|rc) ]] && PRERELEASE=true

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
    "body": open(sys.argv[3], encoding="utf-8").read(), "prerelease": sys.argv[4] == "true"}))' \
    "$TAG" "Casual Hub $VERSION" "$NOTES" "$PRERELEASE")
RELEASE=$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")
read -r RID URL < <(printf '%s' "$RELEASE" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r["id"], r["html_url"])')

echo "== upload $(basename "$ZIP")"
api -X POST -H "Content-Type: application/zip" --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$(basename "$ZIP")" > /dev/null

echo "released $TAG: $URL"
