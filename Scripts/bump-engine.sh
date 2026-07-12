#!/bin/bash
#
# bump-engine.sh - bump the pinned AetherEngine revision in project.yml
# to whatever sits at the tip of origin/main, regenerate the Xcode
# project (Scripts/generate-project.sh), run
# `xcodebuild -resolvePackageDependencies` so the new commit is actually
# pulled, then commit + push the bump.
#
# The Xcode project is generated from project.yml (XcodeGen), so the pin
# lives there, not in Package.resolved. This script rewrites project.yml,
# regenerates, and lets the resolve update Package.resolved; the
# transitive cascade (FFmpegBuild) still operates on Package.resolved.
#
# Usage:  Scripts/bump-engine.sh
#
# No flags. Idempotent. Exits cleanly when already at the latest.

set -e

ENGINE_REPO="https://github.com/superuser404notfound/AetherEngine.git"
ENGINE_API="https://api.github.com/repos/superuser404notfound/AetherEngine/commits"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$PROJECT_DIR/project.yml"
RESOLVED="$PROJECT_DIR/Sodalite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ ! -f "$PROJECT_YML" ]; then
    echo "❌ project.yml not found at $PROJECT_YML"
    exit 1
fi

# Latest SHA on origin/main.
LATEST_SHA=$(git ls-remote "$ENGINE_REPO" main | awk '{print $1}')
if [ -z "$LATEST_SHA" ]; then
    echo "❌ Couldn't fetch latest AetherEngine SHA from $ENGINE_REPO"
    exit 1
fi

# Current pinned SHA, read from project.yml's AetherEngine package block
# (the source of truth for the pin under XcodeGen).
CURRENT_SHA=$(grep -A3 '^  AetherEngine:' "$PROJECT_YML" | awk '/revision:/{print $2; exit}')

if [ -z "$CURRENT_SHA" ]; then
    echo "❌ AetherEngine revision not found in project.yml"
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

# Rewrite the AetherEngine revision in project.yml (the pin source of
# truth under XcodeGen), then regenerate the Xcode project so the package
# reference picks up the new SHA. generate-project.sh preserves
# Package.resolved, so the transitive pins below stay put until the
# resolve reconciles them.
sed -i '' "s/revision: $CURRENT_SHA/revision: $LATEST_SHA/" "$PROJECT_YML"
"$PROJECT_DIR/Scripts/generate-project.sh" > /dev/null

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
xcodebuild -project Sodalite.xcodeproj \
    -resolvePackageDependencies > /dev/null

git add "$PROJECT_YML" "$RESOLVED" Sodalite.xcodeproj
git commit -m "chore(deps): bump AetherEngine to $SHORT_SHA - $HUMAN_SUBJECT"
git push

echo "✓ Bumped AetherEngine ${CURRENT_SHA:0:7} → $SHORT_SHA"
