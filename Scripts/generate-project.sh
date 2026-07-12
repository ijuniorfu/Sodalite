#!/usr/bin/env bash
# Regenerate Sodalite.xcodeproj from project.yml.
#
# project.yml is the single source of truth for the Xcode project. Never edit
# build settings in the Xcode UI, they are overwritten on the next generate.
# Edit project.yml and run this script.
#
# The pinned Package.resolved is preserved across regeneration so transitive
# SwiftPM dependencies never silently drift; only what project.yml requires
# (e.g. a bumped AetherEngine revision) changes on the following resolve.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOLVED="Sodalite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
BACKUP="$(mktemp)"
if [ -f "$RESOLVED" ]; then
  cp "$RESOLVED" "$BACKUP"
fi

xcodegen generate --spec project.yml

if [ -s "$BACKUP" ]; then
  mkdir -p "$(dirname "$RESOLVED")"
  cp "$BACKUP" "$RESOLVED"
fi
rm -f "$BACKUP"

echo "Regenerated Sodalite.xcodeproj from project.yml (Package.resolved preserved)"
