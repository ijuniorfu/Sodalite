#!/bin/bash
#
# bump-engine.sh - bump the pinned AetherEngine revision in
# Package.resolved to whatever sits at the tip of origin/main, run
# `xcodebuild -resolvePackageDependencies` so the new commit is
# actually pulled, then commit + push the bump.
#
# Usage:  Scripts/bump-engine.sh
#
# No flags. Idempotent. Exits cleanly when already at the latest.

set -e

ENGINE_REPO="https://github.com/superuser404notfound/AetherEngine.git"
ENGINE_API="https://api.github.com/repos/superuser404notfound/AetherEngine/commits"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVED="$PROJECT_DIR/Sodalite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ ! -f "$RESOLVED" ]; then
    echo "❌ Package.resolved not found at $RESOLVED"
    exit 1
fi

# Latest SHA on origin/main.
LATEST_SHA=$(git ls-remote "$ENGINE_REPO" main | awk '{print $1}')
if [ -z "$LATEST_SHA" ]; then
    echo "❌ Couldn't fetch latest AetherEngine SHA from $ENGINE_REPO"
    exit 1
fi

# Current pinned SHA, parsed out of the JSON. Python keeps this robust
# against future formatting changes from Xcode.
CURRENT_SHA=$(python3 -c "
import json, sys
with open('$RESOLVED') as f:
    data = json.load(f)
for pin in data['pins']:
    if pin['identity'] == 'aetherengine':
        print(pin['state']['revision'])
        sys.exit(0)
sys.exit(1)
")

if [ -z "$CURRENT_SHA" ]; then
    echo "❌ AetherEngine pin not found in Package.resolved"
    exit 1
fi

if [ "$LATEST_SHA" = "$CURRENT_SHA" ]; then
    echo "✓ Already at latest AetherEngine (${CURRENT_SHA:0:7})"
    exit 0
fi

SHORT_SHA=${LATEST_SHA:0:7}

# Pull the commit's subject line so the bump message can reference it
# the same way the existing `chore(deps): …` history does. Strip the
# conventional-commit type prefix so the result reads naturally as a
# trailing fragment.
SUBJECT=$(curl -sf "$ENGINE_API/$LATEST_SHA" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['commit']['message'].split('\n')[0])
except Exception:
    pass
")
HUMAN_SUBJECT=$(echo "$SUBJECT" | sed -E 's/^[a-z]+(\([^)]+\))?: //')
if [ -z "$HUMAN_SUBJECT" ]; then
    HUMAN_SUBJECT="latest main"
fi

# Replace the AetherEngine SHA in-place. Substituting on the literal
# current SHA scopes the change to the AetherEngine pin (SHAs are
# unique per repo).
sed -i '' "s/$CURRENT_SHA/$LATEST_SHA/" "$RESOLVED"

# Cascade transitive deps. AetherEngine's own Package.resolved pins
# FFmpegBuild to a specific commit; if the engine bumped that pin (new
# muxer, new decoder, new option default) we need Sodalite to follow.
# xcodebuild -resolvePackageDependencies alone won't pull a newer
# transitive SHA because the existing pin is treated as authoritative.
# Pull the engine's Package.resolved over raw.githubusercontent.com and
# match each transitive's pin against Sodalite's; rewrite mismatches.
TRANSITIVE_DEPS=("ffmpegbuild")
for DEP in "${TRANSITIVE_DEPS[@]}"; do
    ENGINE_DEP_SHA=$(curl -sf "https://raw.githubusercontent.com/superuser404notfound/AetherEngine/$LATEST_SHA/Package.resolved" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for pin in data['pins']:
        if pin['identity'] == '$DEP':
            print(pin['state']['revision'])
            break
except Exception:
    pass
")
    if [ -z "$ENGINE_DEP_SHA" ]; then continue; fi

    SODALITE_DEP_SHA=$(python3 -c "
import json, sys
with open('$RESOLVED') as f:
    data = json.load(f)
for pin in data['pins']:
    if pin['identity'] == '$DEP':
        print(pin['state']['revision'])
        break
")
    if [ "$ENGINE_DEP_SHA" != "$SODALITE_DEP_SHA" ] && [ -n "$SODALITE_DEP_SHA" ]; then
        echo "  ↳ transitive bump: $DEP ${SODALITE_DEP_SHA:0:7} → ${ENGINE_DEP_SHA:0:7}"
        sed -i '' "s/$SODALITE_DEP_SHA/$ENGINE_DEP_SHA/" "$RESOLVED"
    fi
done

cd "$PROJECT_DIR"

echo "→ Resolving packages…"
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    -resolvePackageDependencies > /dev/null

git add "$RESOLVED"
git commit -m "chore(deps): bump AetherEngine to $SHORT_SHA - $HUMAN_SUBJECT"
git push

echo "✓ Bumped AetherEngine ${CURRENT_SHA:0:7} → $SHORT_SHA"
