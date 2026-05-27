# AetherEngine 2.0.0 Reddit Launch: Design

Date: 2026-05-27
Status: approved (Vincent)

## Goal

Publish a focused Reddit campaign for AetherEngine 2.0.0 that establishes the engine as adoption-ready (Tests, CI, CHANGELOG, SemVer, MinimalPlayer, DemoPlayerMac, SPI listing) and uses the post-1.0 engineering tour as proof. Differentiate softly against existing Apple-platform players that paywall the HDR / DV / Atmos pipeline.

## Non-goals

- Not a Sodalite re-launch. Sodalite is the in-production pressure-test for the engine and gets referenced, not headlined.
- Not a "first ever" claim. KSPlayer pioneered the HLS-loopback architecture; the differentiator is the open-source scope of the pipeline, not the architecture itself.
- No comparison to KSPlayer by name. Soft framing only.

## Anchor

AetherEngine 2.0.0 ships today (2026-05-27). 1.0.0 was the first stable on 2026-05-13. 2.0.0 is the stability milestone (no breaking API change, signals safe-to-depend-on) plus the adoption-readiness package:

- Tests/AetherEngineTests with 12 unit tests
- GitHub Actions CI (swift test on macOS, xcodebuild smoke on tvOS/iOS Simulators)
- CHANGELOG.md as in-repo release index
- README sections for Stability/SemVer contract and Known Limitations
- Examples/MinimalPlayer (90-line SwiftUI drop-in)
- Examples/DemoPlayerMac (standalone notarized .dmg via CI on release)
- .spi.yml for Swift Package Index multi-platform build matrix

Engineering highlights since 1.0 (canonical talking points, condensed per audience):

- Dolby Vision detection rewritten to read side-data before color_trc so P5 / P8.4 enter DV branch reliably
- Per-frame HDR10+ via kCMSampleAttachmentKey_HDR10PlusPerFrameData with PTS-keyed pending dictionary for B-frame reorder safety
- Dolby Vision P7 (UHD-BD remuxes) routed as plain HEVC HDR10 with dvcC stripped from muxer output
- EAC3+JOC Atmos via in-process HLS server with dec3 declaring JOC, separate AVPlayer instance for audio, A/V sync via CMTimebaseSetSourceTimebase against AVPlayerItem.timebase
- tvOS 26.5 criteria-before-load sole-writer pattern (engine-driven AVDisplayCriteria with appliesPreferredDisplayCriteriaAutomatically = false on the host)
- Empirical Match Dynamic Range detection via post-handshake UIScreen.currentEDRHeadroom (tvOS only exposes a combined Match Content flag)
- Dual pipeline: native AVPlayer for HEVC/H.264/native-AV1; SW dav1d/VP9/VP8/MPEG-4 Part 2/MPEG-2/VC-1 through AVSampleBufferDisplayLayer for codecs the AVPlayer HLS-fMP4 path rejects
- HLS producer reliability hardening (forward + backward scrub leaves no evicted-segment stalls)
- aetherctl swdecode CLI for reproducing SW-path issues without rebuilding the host

## Differentiation (soft framing)

Canonical sentence to seed across posts:

> "As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses."

No KSPlayer namedrop. If the KSPlayer author or fans show up in comments, respond factually: credit the local-HLS-loopback approach to their pioneering work, point out the scope difference, no escalation.

## Posts

### Post 1: r/iOSProgramming (Day 0)

Audience: Apple-platform devs.
Lens: engineering substance.
Length target: ~700 words.

Structure:

1. One-paragraph lead: shipped 2.0.0, what it is (LGPL-3.0 Swift package, FFmpeg + VideoToolbox media stack for Apple platforms), why it exists (real DV/HDR/Atmos modes on the TV side, not silent degradation).
2. Soft-differentiation sentence.
3. Engineering tour with code snippets (lift from existing draft 9 but update to 2.0):
   - DV format-description tagging (dvh1 + dvcC built from AVDOVIDecoderConfigurationRecord)
   - HDR10+ per-frame attachment with PTS-keyed pending dictionary
   - EAC3+JOC via local HLS + AVPlayer + CMTimebase sync
   - tvOS 26.5 sole-writer pattern (new since 1.4.4)
   - EDR-headroom Match-Dynamic-Range probe (new in 2.0)
4. Architecture in a paragraph (AVIOReader → libavformat → packet queue → VTDecompressionSession or avcodec_decode_*; audio splits at demux).
5. Vibe-coded disclosure with Co-Authored-By trail as verification mechanism.
6. How to try it: TestFlight (Sodalite, the pressure-test client), or git clone + MinimalPlayer/DemoPlayerMac.
7. Feedback ask: synchronizer/controlTimebase handoff, dvcC byte packing, HDR10+ flush edge cases, general architecture review.

### Post 2: r/swift (Day 1)

Audience: Swift devs, package consumers.
Lens: Swift Package Index adoption.
Length target: ~500 words.

Structure:

1. Lead: "AetherEngine 2.0.0 just shipped on Swift Package Index. Native Apple-platform media engine, LGPL-3.0 with App Store Exception, no breaking API changes from 1.x."
2. SPI badges in body (links to swiftpackageindex.com/superuser404notfound/AetherEngine).
3. Adoption-readiness checklist:
   - Tests + CI
   - CHANGELOG + SemVer contract
   - Known Limitations explicitly documented (set expectations honestly)
   - MinimalPlayer (90 lines, SwiftUI, drop-in)
   - DemoPlayerMac (notarized .dmg, no Xcode required to see it work)
4. Engineering substance compressed: one-paragraph summary of HDR/DV/Atmos coverage, link to README for depth, link to Post 1 for technical details.
5. Soft-differentiation sentence.
6. Vibe-coded disclosure (briefer than Post 1).
7. Feedback ask: integration friction, API surface ergonomics, missing platforms (visionOS?).

### Post 3: r/vibecoding (Day 2)

Audience: AI-assisted developers.
Lens: process discipline.
Length target: ~500 words.

Structure:

1. Lead: "3 months pair-programming with Claude (Anthropic) on an Apple-platform media engine. 2.0.0 shipped today after 1.0 stable two weeks ago. Here's what came out and the discipline that kept it from being slop."
2. What we built (one paragraph, engineering substance very compact, link out for depth): full HDR / DV / Atmos pipeline as an LGPL-3.0 Swift package, dual playback architecture, ~3k lines of Swift + minimal C interop, plus a Jellyfin tvOS client that pressure-tests it.
3. Discipline checklist:
   - Every commit reviewed before landing (`git log` is auditable)
   - Co-Authored-By: Claude trailers in every commit (permanently attributable, not retconnable)
   - Tests + CI from 2.0 onwards
   - Public TestFlight beta survived 2 weeks of real-user HDR/Atmos feedback before 2.0
   - SemVer contract written down, breaking changes triaged honestly
4. Architectural decisions are mine (host/engine split, the AVPlayer-for-audio Atmos trick, LGPL/GPL exception licensing). Claude is fast at writing the code; the architecture comes from me.
5. Soft-differentiation sentence (frames why the project mattered to build).
6. Feedback ask: what process additions would you suggest? what reviewers can audit for "slop" indicators?

### Post 4: r/AppleDevelopers (Day 4 or 5)

Light variant of Post 1, ~400 words. Same engineering substance, shorter snippets, same Vibe-coded disclosure. Delay past Day 3 so Reddit spam-filter doesn't flag the cross-post.

### Post 5 (optional): r/opensource (Day 6+)

Audience: open-source license-aware devs.
Lens: license story + scope-of-openness.
Length target: ~600 words.

Structure: update existing draft 7 in `Sodalite/Marketing/RedditPosts.txt`. Lead with the licensing pair (GPL-3.0 with App Store Exception for the client, LGPL-3.0 with App Store Exception for the engine), explain why copyleft on iOS/tvOS is uncommon (App Store DRM clause conflict), credit VLC for pioneering the exception. Then the soft-differentiation sentence: full HDR/DV/Atmos pipeline in the open repo, not behind a commercial paywall. Architectural overview, vibe-coded disclosure, feedback ask focused on license footguns.

## Pre-flight checklist

Before Post 1 goes out:

- [ ] DemoPlayerMac .dmg attached to the 2.0.0 GitHub Release and downloadable
- [ ] README on main is in sync with 2.0.0 (badges, codec list, host-setup section)
- [ ] CHANGELOG.md visible and current
- [ ] Examples/MinimalPlayer compiles fresh against 2.0.0 tag
- [ ] CI green on main
- [ ] Screenshots prepared: player UI with HDR badge, MinimalPlayer code in Xcode, DemoPlayerMac running on a Mac
- [ ] Soft-differentiation sentence proofread (no inadvertent direct call-out)
- [ ] No em-dashes anywhere in the post bodies
- [ ] German words audit (vibecoding/iOSProgramming/swift posts are in English)

## Cadence

- Day 0: r/iOSProgramming + GitHub announcement (pinned issue update or new pinned issue on AetherEngine repo)
- Day 1: r/swift
- Day 2: r/vibecoding
- Day 3: triage feedback, answer comments
- Day 4 or 5: r/AppleDevelopers
- Day 6+: optional r/opensource

If any post is getting heavy engagement, skip the next day and stay in the thread answering comments. Posted-and-forgotten is worse than fewer posts well-answered.

## Tone notes

- No em-dashes (rendered as AI tells in the wild; Vincent's standing preference)
- Lead with engineering substance, not feature bullets
- Vibe-coded disclosure is up front in every post, not hidden in a postscript
- Don't bash other clients by name. If someone else brings them up in comments, answer factually about AetherEngine's design choices
- Don't oversell. Known Limitations is in the README precisely because the project survives by being honest about what's deferred
- Don't address Vincent or the persona in any post (no second-person to self)

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| KSPlayer author appears in comments | Credit them for pioneering the architecture, point out scope difference, no escalation |
| Vibe-coded backlash | Counter-evidence at the ready: commit log, Co-Authored-By trail, tests + CI, public-beta feedback survived, source-readable repo size |
| "first stable" vs "2.0 is stable" confusion | Each post says: 1.0 was first stable (May 13); 2.0 is the stability milestone with adoption-readiness package |
| Reddit spam filter on cross-posts | 24h+ gap between subreddits, 4 day gap before r/AppleDevelopers variant |
| Post 1 receives feature-request flood | Acknowledge feedback, point at GitHub Issues with templates, defer non-critical items |

## What this design does NOT decide

- Final post titles (will be drafted in implementation plan based on subreddit-specific patterns)
- Exact code snippets to include in Post 1 (will be selected during plan execution from current 2.0 source)
- Whether to post on Hacker News (separate decision, possibly Day 7+ if Reddit goes well)
- Mastodon / Bluesky cross-posting (out of scope for this spec; existing Launch.md covers them)
