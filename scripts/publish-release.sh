#!/bin/bash
# Stage validated release artifacts in a draft, verify the uploads, then publish the update atomically.
# Usage: GITHUB_REPOSITORY=owner/repo scripts/publish-release.sh VERSION notes.md [release-directory]
set -euo pipefail

VERSION=${1:?usage: scripts/publish-release.sh VERSION notes.md [release-directory]}
NOTES=${2:?release notes are required}
OUT=${3:-build/release}
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: version must be a numeric version such as 0.1.0" >&2
    exit 1
fi
TAG="v$VERSION"
ASSETS=("$OUT/Sidelight-$VERSION.dmg" "$OUT/Sidelight-$VERSION.dmg.sha256" "$OUT/appcast.xml")
for path in "$NOTES" "${ASSETS[@]}"; do
    [[ -s "$path" ]] || { echo "error: missing or empty release file: $path" >&2; exit 1; }
done

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
{
    cat "$NOTES"
    echo
    echo "---"
    echo
    echo "**Install:** download \`Sidelight-$VERSION.dmg\`, open it and drag Sidelight to Applications."
    echo "Sidelight then keeps itself up to date (Settings → General → Updates)."
    echo "Requires an Apple Silicon Mac with macOS 26."
} > "$STAGING/release-body.md"

EXISTING=$(gh api "repos/$REPO/releases" --paginate --jq ".[] | select(.tag_name == \"$TAG\") | .draft")
if [[ "$EXISTING" == false ]]; then
    echo 'This release is already published; its assets must not be replaced.' >&2
    exit 1
elif [[ "$EXISTING" == true ]]; then
    gh release upload "$TAG" --repo "$REPO" --clobber "${ASSETS[@]}"
    gh release edit "$TAG" --repo "$REPO" --title "Sidelight $VERSION" --notes-file "$STAGING/release-body.md"
elif [[ -z "$EXISTING" ]]; then
    gh release create "$TAG" --repo "$REPO" --draft --verify-tag --title "Sidelight $VERSION" \
        --notes-file "$STAGING/release-body.md" "${ASSETS[@]}"
else
    echo "error: unexpected release state: $EXISTING" >&2
    exit 1
fi

# A failed or incomplete upload must never become the latest update. Check GitHub's SHA-256 digests too.
gh release view "$TAG" --repo "$REPO" --json isDraft,assets > "$STAGING/release.json"
python3 - "$STAGING/release.json" "${ASSETS[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

release = json.loads(Path(sys.argv[1]).read_text())
assert release['isDraft'], 'Release must still be a draft before publishing'
assets = {asset['name']: asset for asset in release['assets']}
for filename in sys.argv[2:]:
    path = Path(filename)
    asset = assets.get(path.name)
    assert asset is not None, f'Missing uploaded asset: {path.name}'
    assert asset['state'] == 'uploaded', f'Incomplete upload: {path.name}'
    assert asset['size'] == path.stat().st_size, f'Wrong upload size: {path.name}'
    digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
    assert asset['digest'] == digest, f'Wrong upload digest: {path.name}'
print('All release uploads verified.')
PY

gh release edit "$TAG" --repo "$REPO" --draft=false --latest --verify-tag
URL="https://github.com/$REPO/releases/tag/$TAG"
echo "Published release: $URL"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "Published release: $URL" >> "$GITHUB_STEP_SUMMARY"
fi
