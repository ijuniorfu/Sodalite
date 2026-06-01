<!-- Thanks for contributing to Sodalite. Keep this short; the test plan is the part that matters most. -->

## Summary

<!-- What does this change do, and why? One or two sentences. -->

Closes #

## What changed

<!-- The concrete changes. Bullet points are fine. -->

-

## Test plan

<!-- There is no test target, so changes are verified on a real Apple TV. Name the device, the tvOS version, and the exact media or flow you exercised so a reviewer can reason about coverage. For a playback change, include the source media. -->

- Apple TV / tvOS:
- Jellyfin server version (if relevant):
- Flow or source media tested (container / video codec + profile / audio / HDR-DV):
- Result:

## Checklist

- [ ] Commit messages follow Conventional Commits (`feat(player):`, `fix(...)`, `chore(deps):`) with the `Co-Authored-By` trailer
- [ ] No em-dashes in code, commits, PRs, or docs
- [ ] Any playback bug is fixed in AetherEngine, not worked around in Sodalite
- [ ] User-visible changes have a `Changelog.swift` entry
- [ ] Builds and runs on an Apple TV destination
