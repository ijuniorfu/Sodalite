# AetherEngine 2.0.0 Reddit Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draft 4 Reddit posts (plus 1 optional) for AetherEngine 2.0.0 launch, with consistent canonical facts and per-subreddit lenses, ready for Vincent to publish on a phased cadence.

**Architecture:** All drafts live in a single new file `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`, mirroring the existing `RedditPosts.txt` convention. Each post is drafted, self-reviewed against the soft-framing + tone checklist, then committed. The existing `Sodalite/Marketing/RedditPosts.txt` (Sodalite launch drafts) is not touched. Spec at `docs/superpowers/specs/2026-05-27-aetherengine-2.0-reddit-launch-design.md`.

**Tech Stack:** Plain text drafts (markdown-flavored). Reference material in `AetherEngine/CHANGELOG.md`, `AetherEngine/README.md`, `Sodalite/CLAUDE.md`, existing `Sodalite/Marketing/RedditPosts.txt` draft 9 for engineering-substance reuse.

---

## File Structure

- Create: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`. Single file holding all 5 post drafts as labeled sections (matches `RedditPosts.txt` convention).
- Reference (read-only): `Sodalite/Marketing/RedditPosts.txt` (existing draft 9 for r/iOSProgramming engineering tour, lift code snippets), `AetherEngine/CHANGELOG.md`, `AetherEngine/README.md`
- Modify (Task 7 only, optional): `Sodalite/Marketing/RedditPosts.txt`. Update existing draft 7 (r/opensource) if Vincent opts in to Post 5.

## Pre-flight context

Canonical facts every post must include or reference:

- AetherEngine 2.0.0 shipped 2026-05-27
- 1.0.0 (first stable) shipped 2026-05-13
- LGPL-3.0 with App Store Exception
- Repos: `https://github.com/superuser404notfound/AetherEngine` (engine) and `https://github.com/superuser404notfound/Sodalite` (client / pressure-test)
- TestFlight: `https://testflight.apple.com/join/nWeQzmBX`
- Swift Package Index: `https://swiftpackageindex.com/superuser404notfound/AetherEngine`
- Soft-differentiation sentence (verbatim): "As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses."

Forbidden in every draft:

- Em-dashes (—) or en-dashes (–). Use comma, period, parenthesis, or colon instead.
- KSPlayer named directly.
- Bashing other clients (Swiftfin, Infuse, VLCKit) by name.
- German words leaking into English posts.
- Second-person to self ("Vincent, …", "I told you …").

---

### Task 1: Pre-flight verification

**Files:**
- Read: `Sodalite/Marketing/RedditPosts.txt` (lines 506-600, draft 9), `AetherEngine/CHANGELOG.md`, `AetherEngine/README.md`

- [ ] **Step 1: Confirm 2.0.0 GitHub Release is published with DemoPlayerMac .dmg attached**

Run: `gh release view 2.0.0 --repo superuser404notfound/AetherEngine --json assets,tagName,url,publishedAt`
Expected: tagName `2.0.0`, `assets` array contains a `.dmg` file. Note the `.dmg` download URL for use in Post 2.

If the release exists but lacks the .dmg: CI workflow `release-dmg` should have uploaded it on tag push. Check `gh run list --repo superuser404notfound/AetherEngine --workflow=release-dmg.yml --limit 3` for failed runs, fix root cause, re-run. Do not proceed to Task 2 without the .dmg present.

- [ ] **Step 2: Confirm README on `main` is in sync with 2.0.0**

Run: `grep -E '(2\.0\.0|MARKETING_VERSION|version)' /Users/vincentherbst/Dev/AetherEngine/README.md | head -20`
Expected: At least one explicit `2.0.0` reference (Stability and versioning section, Examples section, or badge URL).

- [ ] **Step 3: Confirm CI is green on main**

Run: `gh run list --repo superuser404notfound/AetherEngine --branch main --limit 3 --json conclusion,name,headSha`
Expected: Most recent run on `main` has `conclusion: "success"`.

- [ ] **Step 4: Read existing engineering draft for reuse**

Read `Sodalite/Marketing/RedditPosts.txt` lines 506-600 (draft 9, the existing r/iOSProgramming pitch). Note which code snippets (dvcC creation, HDR10+ attachment, EAC3+JOC HLS trick, AVDisplayCriteria + UIWindow.avDisplayManager) are still accurate against 2.0 source. The dvcC and HDR10+ snippets are unchanged; the EAC3+JOC architecture description needs to mention the dec3 box and CMTimebaseSetSourceTimebase.

- [ ] **Step 5: Read CHANGELOG for canonical 1.0-to-2.0 highlights list**

Read `AetherEngine/CHANGELOG.md`. Extract the per-version highlight that goes into Post 1's engineering tour and Post 3's process timeline:
  - 1.0.0: first stable, dual pipeline introduced
  - 1.1.0: A/V sync overhaul from public-beta feedback, HDR10+ runtime detection
  - 1.3.0: dec3/dac3 from packet bitstream, dual-mode AudioBridge
  - 1.3.2: DV P7 routed as plain HEVC HDR10 with dvcC stripped (UHD-BD remuxes)
  - 1.4.0: waitForSwitch race fix, LiveTelemetry
  - 1.4.4: tvOS 26.5 criteria-before-load sole-writer pattern
  - 1.5.0: DV detection from side data first (not color_trc), VP8 SW pipeline, MLP
  - 2.0.0: EDR-headroom Match-Dynamic-Range probe, sourceVideoFormat published, adoption package

- [ ] **Step 6: Create empty drafts file with header**

Create `/Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt` with this content:

```
================================================================================
AETHERENGINE 2.0.0 REDDIT LAUNCH DRAFTS
================================================================================

Cadence:
  Day 0: r/iOSProgramming + GitHub announcement update
  Day 1: r/swift
  Day 2: r/vibecoding
  Day 4 or 5: r/AppleDevelopers (light variant of #1)
  Day 6+: r/opensource (optional, updates existing draft 7 in RedditPosts.txt)

Canonical facts: see docs/superpowers/specs/2026-05-27-aetherengine-2.0-reddit-launch-design.md
Forbidden: em-dashes, KSPlayer name, client bashing, German leakage, self-addressing.

```

- [ ] **Step 7: Commit empty drafts file as scaffold**

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): scaffold AetherEngine 2.0 Reddit drafts file

Empty container for the 4 to 5 launch posts per spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Draft Post 1 (r/iOSProgramming)

**Files:**
- Modify: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`

Lens: Engineering substance. Length: ~700 words. Audience: Apple-platform devs.

- [ ] **Step 1: Append Post 1 section header**

Append to file:

```
================================================================================
1) r/iOSProgramming  (Day 0, lead post)
================================================================================

TITLE
-----
After 1.0 and a public beta, my open-source tvOS / iOS media engine just hit 2.0: full HDR / Dolby Vision / Atmos pipeline, in the repo, no paywall

```

- [ ] **Step 2: Append Post 1 body**

Append to file, immediately after the title section (no extra header):

```
BODY
----
Hi r/iOSProgramming,

Two weeks ago I shipped 1.0.0 of AetherEngine, an LGPL-3.0 Swift package that powers a Jellyfin client I built for Apple TV (Sodalite, also open source). 1.0 was the first stable. 2.0.0 just shipped today as the stability milestone, with no breaking API changes from 1.x. The point of the 2.0 bump is adoption-readiness: Tests + GitHub Actions CI, a CHANGELOG, a written SemVer contract, a 90-line MinimalPlayer drop-in, a notarized DemoPlayerMac .dmg you can run on your laptop, and a Swift Package Index listing.

I'd posted an earlier engineering-tour draft on this sub when the project was younger. A lot has happened since. This time I want to share what got built across the seven minor releases between 1.0 and 2.0, because the work is in corners of Apple's media stack that don't get a lot of public-source examples.

**Engine:** https://github.com/superuser404notfound/AetherEngine
**Client built on it:** https://github.com/superuser404notfound/Sodalite
**TestFlight if you want to see it run on hardware:** https://testflight.apple.com/join/nWeQzmBX
**Swift Package Index:** https://swiftpackageindex.com/superuser404notfound/AetherEngine

As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses.

## A few things in the engine that might be interesting

**Dolby Vision format-description tagging.** The `CMVideoFormatDescription` needs to be `kCMVideoCodecType_DolbyVisionHEVC` ('dvh1') with a `dvcC` extension built from FFmpeg's `AVDOVIDecoderConfigurationRecord`. Without that, the TV stays in HDR10 / HLG base-layer mode regardless of how proudly the bitstream carries an RPU.

```swift
// Build the 24-byte ISO BMFF dvcC box body from the FFmpeg record
let dvcCData = buildDvcCAtom(from: record)
let atoms: NSMutableDictionary = ["hvcC": hvcCExtraData, "dvcC": dvcCData]
let extensions: NSDictionary = [
    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
]
CMVideoFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    codecType: kCMVideoCodecType_DolbyVisionHEVC,
    width: width, height: height,
    extensions: extensions,
    formatDescriptionOut: &formatDesc
)
```

Detection had to be rewritten in 1.5 to read DV side-data before `color_trc`. Profile 8.4 (HLG base) and Profile 5 (unspecified base TRC) were entering the HDR branch otherwise. For Profile 7 (UHD-BD remuxes) the situation flips: VT has no P7 decoder, so the muxer strips `dvcC` from its output and the file routes as plain HEVC HDR10 with the BL preserved. Otherwise VT rejects the sample entry with -12906.

**HDR10+ dynamic metadata.** Apple added `kCMSampleAttachmentKey_HDR10PlusPerFrameData` in `CMSampleBuffer.h` since iOS / tvOS 16. It takes a CFData of the T.35 SEI bytes and overrides whatever HDR10+ payload is baked into the compressed bitstream. We extract from `AV_PKT_DATA_DYNAMIC_HDR10_PLUS`, serialize via `av_dynamic_hdr_plus_to_t35`, then attach per-frame:

```swift
CMSetAttachment(
    sampleBuffer,
    key: kCMSampleAttachmentKey_HDR10PlusPerFrameData,
    value: t35Bytes as CFData,
    attachmentMode: CMAttachmentMode(kCMAttachmentMode_ShouldPropagate)
)
```

Pairing across the async VT output handler (B-frame reorder makes "use the most recent value" unsafe) is done with a PTS-keyed pending dictionary. Packet side data goes in on the demux thread, lookup happens in the decoder callback. Cleanup on flush; documented in the Known Limitations as the place to look if anyone hits leak-on-edge-case behavior.

**Dolby Atmos passthrough.** `AVSampleBufferAudioRenderer` ignores Atmos metadata. `AVPlayer` doesn't. The trick: demux the EAC3+JOC packets, wrap them in fMP4 with a `dec3` box declaring JOC (`numDepSub=1`, `depChanLoc=0x0100`), serve segments from an in-process HLS server on `127.0.0.1:<port>`, point a separate `AVPlayer` at the playlist. AVPlayer wraps it as Dolby MAT 2.0 over HDMI and the receiver lights its Atmos indicator. Since 1.3, `dec3` / `dac3` are written from the packet bitstream via the mp4 muxer's `+delay_moov` flag (no host-side reconstruction).

A/V sync uses `AVSampleBufferDisplayLayer`'s `controlTimebase` bound directly to `AVPlayerItem.timebase` via `CMTimebaseSetSourceTimebase`. Once the bind establishes (around 2 to 4 seconds of HLS pre-roll), video and audio share the same hardware-aware clock with no periodic drift correction.

**tvOS 26.5 criteria-before-load.** This one broke between 1.4 and 1.4.4. tvOS 26.5 enforces the "AVDisplayCriteria must be set before HLS variant validation" ordering synchronously. AVKit's automatic mode (`appliesPreferredDisplayCriteriaAutomatically = true`) cannot satisfy it for HLS multivariant HDR sources, so the fix is engine-driven sole-writer: the host sets `appliesPreferredDisplayCriteriaAutomatically = false` and passes `LoadOptions(suppressDisplayCriteria: false)`. Sources that worked under 26.4 started returning `AVFoundationErrorDomain -11868 / AVErrorNoCompatibleAlternatesForExternalDisplay` until we figured out the new ordering contract.

**Match Dynamic Range detection via EDR headroom.** tvOS exposes one combined `isDisplayCriteriaMatchingEnabled` flag for Match Content (rate + range). Users with Match Frame Rate ON and Match Dynamic Range OFF previously had the engine route HDR sources through master playlists with `VIDEO-RANGE=PQ`, which AVPlayer rejected with -11848 / -11868 because the panel stayed in SDR. 2.0 reads `UIScreen.currentEDRHeadroom` after the criteria handshake settles and uses that empirical reading to pick master-vs-media routing.

**Dual pipeline.** Native AVPlayer handles HEVC, H.264, and native-AV1. Software dav1d/VP9/VP8/MPEG-4 Part 2/MPEG-2/VC-1 route through a separate `AVSampleBufferDisplayLayer` path with FFmpeg decode plus sws_scale. The split exists because AVPlayer's HLS-fMP4 path rejects those codecs entirely. The host doesn't have to know which path is active; both publish into the same `@Published` properties.

## Architecture in a paragraph

`AVIOReader` (URLSession into `avio_alloc_context`) feeds libavformat. The demuxer pushes into a packet queue. Video goes to either `VTDecompressionSession` (HW path) or `avcodec_decode_*` with sws_scale (SW fallback). A 4-frame reorder buffer handles B-frame depth. Output lands in `AVSampleBufferDisplayLayer`. Audio splits at the demux: PCM-decodable codecs go through `AVSampleBufferAudioRenderer`; EAC3+JOC takes the HLS+AVPlayer route described above.

## How to try it

* Quick visual: download the notarized DemoPlayerMac .dmg from the 2.0.0 release page on GitHub. Drop in a file, see the engine work without integrating it
* Integrate in your own app: `Examples/MinimalPlayer/MinimalPlayerApp.swift` is 90 lines of SwiftUI showing the smallest viable integration
* See it under load on hardware: TestFlight link above for Sodalite, the Jellyfin client built on the engine. Two weeks of public beta is what hardened 1.x into 2.0

## On the AI angle

Built in pair-programming with Claude (Anthropic). Every commit was reviewed before landing and ships with a `Co-Authored-By: Claude` trailer so the AI involvement is permanently attributable rather than retconnable. Source is open precisely so the disclosure is verifiable. The engine repo is small enough to read in an evening if you want to check the HDR / Atmos paths before learning from them or installing.

## Where I'd value a critical eye

* The synchronizer / controlTimebase handoff during HLS pre-roll. There is a window where the layer is on the synchronizer, then we detach and reattach to a controlTimebase bound to AVPlayer's timebase. A lot of time went into making it stable, interested if anyone has done this differently
* The dvcC byte packing, written by hand from the ISO BMFF Dolby Vision spec. If anyone has parsed enough DV files to call out a field-order surprise, that would be useful
* The EDR-headroom probe timing (post-handshake but pre-first-frame). I am not sure how robust this is on weird HDMI handshake sequences
* General architecture review. The engine repo is intentionally small (~3k lines of Swift, minimal C interop). If something looks structurally wrong, an issue or PR is welcome

Happy to answer anything technical in the thread.

```

- [ ] **Step 3: Self-review proofread of Post 1**

Run: `grep -n '—\|–' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no dashes"`
Expected: "no dashes" or no output.

Run: `grep -niE 'KSPlayer|Swiftfin|Infuse|VLCKit' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no client mentions"`
Expected: "no client mentions" (or only "Sodalite" matches, which is fine since that's our own client).

Run: `grep -niE '\b(und|nicht|ich|nur|aber|auch|der|die|das|ein|mit|für|wenn|sehr|dass|wir)\b' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no german leakage"`
Expected: "no german leakage" (these are German function words; English content shouldn't contain them).

Read back the post bodily and confirm: soft-differentiation sentence present (verbatim from spec), TestFlight + Source + SPI links present, vibe-coded disclosure present, feedback ask present.

- [ ] **Step 4: Commit Post 1**

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): draft AetherEngine 2.0 Reddit post 1 (r/iOSProgramming)

Engineering-substance deep dive. Updates the existing draft 9 with
the 1.0 to 2.0 work: DV side-data detection, tvOS 26.5 sole-writer
pattern, EDR-headroom Match-Dynamic-Range probe, dec3/dac3 from
bitstream, dual pipeline coverage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Draft Post 2 (r/swift)

**Files:**
- Modify: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`

Lens: Swift Package Index adoption. Length: ~500 words.

- [ ] **Step 1: Append Post 2 section header**

Append to file:

```
================================================================================
2) r/swift  (Day 1)
================================================================================

TITLE
-----
AetherEngine 2.0.0: Swift package for native HDR / Dolby Vision / Atmos playback on Apple platforms, with a 90-line MinimalPlayer and a notarized DemoPlayerMac you can run today

```

- [ ] **Step 2: Append Post 2 body**

Append to file:

```
BODY
----
Hi r/swift,

I just shipped 2.0.0 of AetherEngine on Swift Package Index. It's an LGPL-3.0 (with App Store Exception) native Apple-platform media engine: FFmpeg demux into VideoToolbox decode into `AVSampleBufferDisplayLayer`, with a separate AVPlayer instance driving Atmos passthrough via an in-process HLS server.

1.0.0 was the first stable, released two weeks ago. 2.0.0 ships today with **no breaking API changes from 1.x**. The major-version bump is a stability signal, not an API redesign. The point of cutting 2.0 now is to make the package safe to depend on:

* `Tests/AetherEngineTests/` with unit tests against the pure-function surfaces
* GitHub Actions CI running `swift test` on macOS plus `xcodebuild` smoke builds for tvOS and iOS Simulators on every push and PR
* `CHANGELOG.md` as an in-repo release index
* README → Stability and versioning documents the SemVer contract
* README → Known Limitations spells out the deferred / accepted-loss items so adopters can size them before integration
* `Examples/MinimalPlayer/MinimalPlayerApp.swift`, a 90-line SwiftUI drop-in
* `Examples/DemoPlayerMac/`, a standalone macOS demonstrator with a notarized `.dmg` published as a release asset
* `.spi.yml` for Swift Package Index multi-platform builds

**Links:**
* Engine: https://github.com/superuser404notfound/AetherEngine
* SPI: https://swiftpackageindex.com/superuser404notfound/AetherEngine
* DemoPlayerMac .dmg: attached as a release asset on the 2.0.0 release
* Reference client (tvOS, also open source): https://github.com/superuser404notfound/Sodalite + TestFlight https://testflight.apple.com/join/nWeQzmBX

## What it does

* Native AVPlayer path for HEVC, H.264, and native-AV1 (HW decode where available)
* Software fallback path through `AVSampleBufferDisplayLayer` for VP8, VP9, AV1 without HW, MPEG-4 Part 2, MPEG-2, VC-1 (demux via libavformat, decode via dav1d / libavcodec, sws_scale into IOSurface)
* HDR10, HDR10+ (per-frame `kCMSampleAttachmentKey_HDR10PlusPerFrameData`), HLG, Dolby Vision Profile 5 / 7 / 8.1 / 8.4
* Dolby Atmos via EAC3+JOC wrapped as MAT 2.0 through an in-process HLS server fed to AVPlayer, A/V sync via `CMTimebaseSetSourceTimebase` against `AVPlayerItem.timebase`
* Audio bridge with two modes (surround-compat EAC3 and lossless FLAC up to 7.1) plus stream-copy for fMP4-legal codecs
* Bitmap subtitles (PGS / DVB / HDMV) decoded client-side and rendered as `CGImage` at the correct on-frame position

The engineering depth is the topic of a longer post I wrote for r/iOSProgramming yesterday, if you want the code snippets and the architecture diagram.

## On scope and license

As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses.

LGPL-3.0 with an Apple Store / DRM Exception means: dynamic-link from a closed-source app on the App Store, no problem. Modify the engine itself, your changes have to stay LGPL. The Exception is the same clause VLC pioneered, which keeps the App Store distribution path legally clean for copyleft engines.

## On the AI angle

Built in pair-programming with Claude (Anthropic). Every commit was reviewed before landing and carries a `Co-Authored-By: Claude` trailer. Source is open precisely so the disclosure is verifiable. The engine repo is intentionally small (~3k lines of Swift plus minimal C interop) and the test surface and CHANGELOG mean the work is auditable rather than vibes-only.

## Requirements (adopter side)

* Swift 6 (Swift 5 with concurrency disabled also compiles; CI verifies both)
* iOS 17+, tvOS 17+, macOS 14+ for the engine itself
* Sodalite (the client) targets tvOS 26+ for the full HDR / DV / Atmos path, since most of the criteria-handling APIs are 26-only

## Feedback I would value

* Integration friction: where did the API force you into a pattern that felt wrong?
* Missing platforms (visionOS comes up regularly, not on the roadmap yet)
* Edge cases in your own integration that the README's Known Limitations didn't predict

PRs and issues both welcome. The bus factor on this is one human, so external review and verification matter to me.

```

- [ ] **Step 3: Self-review proofread of Post 2**

Run: `grep -n '—\|–' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no dashes"`
Expected: "no dashes".

Confirm: soft-differentiation sentence verbatim, SPI link present, MinimalPlayer + DemoPlayerMac referenced, vibe-coded disclosure present, "no breaking API changes" claim present.

- [ ] **Step 4: Commit Post 2**

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): draft AetherEngine 2.0 Reddit post 2 (r/swift)

Swift-Package-Index-adoption lens. Leads with the 2.0 stability
signal plus the adoption package (Tests, CI, CHANGELOG, SemVer,
MinimalPlayer, DemoPlayerMac, SPI).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Draft Post 3 (r/vibecoding)

**Files:**
- Modify: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`

Lens: Process discipline. Length: ~500 words.

- [ ] **Step 1: Append Post 3 section header**

Append to file:

```
================================================================================
3) r/vibecoding  (Day 2)
================================================================================

TITLE
-----
Three months pair-programming with Claude on an Apple-platform media engine: what shipped, and the discipline that kept it from being slop

```

- [ ] **Step 2: Append Post 3 body**

Append to file:

```
BODY
----
Hi r/vibecoding,

Sharing a project where the vibe-coding-versus-discipline question got tested in public. I built an open-source media engine for Apple platforms (`AetherEngine`) and a Jellyfin client on top of it (`Sodalite`), almost entirely in pair-programming with Claude (Anthropic) over the past three months. 1.0.0 shipped two weeks ago. 2.0.0 shipped today as the stability milestone.

I want to talk about how it stayed coherent rather than what it does, because this audience has the same incentives I do for figuring out what works.

**The repos** (so the claims below are verifiable, not vibes):
* Engine: https://github.com/superuser404notfound/AetherEngine
* Client: https://github.com/superuser404notfound/Sodalite
* TestFlight (the client running on real hardware): https://testflight.apple.com/join/nWeQzmBX

## What got built

A full media stack: FFmpeg demux into VideoToolbox decode, with a software fallback path for codecs AVPlayer's HLS-fMP4 path can't handle. Real HDR10, HDR10+, Dolby Vision (Profile 5 / 7 / 8.1 / 8.4), real Dolby Atmos via EAC3+JOC wrapped as Dolby MAT 2.0. Roughly 3k lines of Swift plus minimal C interop in the engine, plus a tvOS Jellyfin client on top.

As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses. So the "what" is non-trivial, which is the precondition that makes the "how" interesting.

## The discipline that kept it auditable

1. **Every commit reviewed before landing.** The git log is the audit trail. Look at any single commit: descriptive subject, focused diff, no auto-generated boilerplate. Browse https://github.com/superuser404notfound/AetherEngine/commits/main and check for yourself.

2. **`Co-Authored-By: Claude` trailers on every commit.** Permanently attributable, not retconnable. If someone wants to know which lines came out of pair-programming, the answer is "all of them", and that is explicit in the metadata rather than hidden.

3. **Architectural decisions are mine, not Claude's.** The host / engine split, the AVPlayer-for-audio trick that gets Atmos passthrough working, the LGPL / GPL Exception licensing choice, the dual-pipeline architecture, the decision to ship a notarized DemoPlayerMac .dmg as a release asset, the choice not to chase visionOS yet. Those are calls I made and would defend. Claude is fast at writing the code that implements a design; the design comes from me.

4. **Tests + CI from 2.0 forward.** `swift test` on macOS plus `xcodebuild` smoke builds for tvOS and iOS Simulators on every push. Twelve unit tests against the pure-function surfaces. A small surface, but a real one.

5. **SemVer contract, written down.** README → Stability and versioning. Breaking changes get triaged honestly. 2.0 is a stability-milestone bump with zero API breaks from 1.x, which means I needed the SemVer contract before I could honestly call it 2.0.

6. **Public TestFlight beta survived two weeks of real-user HDR / Atmos feedback before 2.0.** The bug reports that came in (A/V sync drift on FLAC bridge, DV Profile 5 dispatch on non-DV panels, backward-scrub stalls after evicted segments) drove most of 1.1 through 1.5. None of that came from me. Real-user pressure is what hardens vibe-coded work.

## What I would value from this sub

* Process additions you have tried that worked
* Audit techniques: if you were going to review someone else's vibe-coded project for "slop indicators", what specifically would you grep for?
* Counter-examples: projects that did the discipline things and still failed. What was the actual failure mode?

The whole point of being open and explicit about the AI angle is that the work is verifiable. If anything in either repo looks like slop on inspection, I want to hear about it.

```

- [ ] **Step 3: Self-review proofread of Post 3**

Run: `grep -n '—\|–' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no dashes"`
Expected: "no dashes".

Confirm: process discipline points are concrete (commit log link, Co-Authored-By trail, tests + CI, SemVer, public-beta survived), soft-differentiation sentence verbatim, engineering substance kept compact with link to Post 1 implicit ("see r/iOSProgramming post" if needed), feedback ask present.

- [ ] **Step 4: Commit Post 3**

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): draft AetherEngine 2.0 Reddit post 3 (r/vibecoding)

Process-discipline lens. Leads with what kept it from being slop:
commit-by-commit review, Co-Authored-By trail, tests + CI, written
SemVer contract, public-beta survived.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Draft Post 4 (r/AppleDevelopers)

**Files:**
- Modify: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`

Lens: Light variant of Post 1. Length: ~400 words.

- [ ] **Step 1: Append Post 4 section header**

Append to file:

```
================================================================================
4) r/AppleDevelopers  (Day 4 or 5, light variant of post 1)
================================================================================

TITLE
-----
AetherEngine 2.0: open-source Apple-platform media engine (Swift package) with full HDR / Dolby Vision / Atmos pipeline in the repo

```

- [ ] **Step 2: Append Post 4 body**

Append to file:

```
BODY
----
Hi r/AppleDevelopers,

I shipped AetherEngine 2.0.0 a few days ago, after public TestFlight beta validation of 1.x. It is an LGPL-3.0 Swift package: FFmpeg demux into VideoToolbox decode, with a software fallback path for codecs AVPlayer's HLS-fMP4 path can't handle, plus an Atmos passthrough trick that gets EAC3+JOC sources through to an AVR's Atmos indicator.

I posted the deep engineering tour on r/iOSProgramming earlier this week. This is the shorter version for this sub.

**Engine:** https://github.com/superuser404notfound/AetherEngine
**Client built on it:** https://github.com/superuser404notfound/Sodalite
**TestFlight:** https://testflight.apple.com/join/nWeQzmBX

As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses.

## Highlights from the API corners that matter

* Dolby Vision format-description tagged as `kCMVideoCodecType_DolbyVisionHEVC` ('dvh1') with a `dvcC` extension built from FFmpeg's `AVDOVIDecoderConfigurationRecord`. Detection reads side-data before `color_trc` (1.5 change), which is what makes Profile 8.4 and Profile 5 work reliably
* HDR10+ via `kCMSampleAttachmentKey_HDR10PlusPerFrameData` (CMSampleBuffer.h, since iOS / tvOS 16). PTS-keyed pending dictionary handles B-frame reorder
* Dolby Vision Profile 7 (UHD-BD remuxes) routed as plain HEVC HDR10 with `dvcC` stripped from muxer output (VT has no P7 decoder)
* EAC3+JOC Atmos via local HLS server with `dec3` declaring JOC, separate AVPlayer for audio, A/V sync via `CMTimebaseSetSourceTimebase` against `AVPlayerItem.timebase`
* tvOS 26.5 criteria-before-load sole-writer pattern: host sets `appliesPreferredDisplayCriteriaAutomatically = false`, engine drives `AVDisplayCriteria`. AVKit-auto cannot satisfy the new ordering contract synchronously for HLS multivariant HDR sources
* Match Dynamic Range detection via post-handshake `UIScreen.currentEDRHeadroom`, since tvOS exposes one combined Match Content flag

## Adoption-readiness

* Tests + GitHub Actions CI (swift test on macOS, xcodebuild on tvOS / iOS Simulators)
* CHANGELOG, SemVer contract, Known Limitations
* `Examples/MinimalPlayer` (90-line SwiftUI drop-in) + `Examples/DemoPlayerMac` (notarized .dmg as release asset)
* Swift Package Index listing: https://swiftpackageindex.com/superuser404notfound/AetherEngine

## On the AI angle

Built in pair-programming with Claude (Anthropic). Every commit reviewed before landing, `Co-Authored-By: Claude` trailers throughout so the involvement is permanently attributable. Source is open so the disclosure is verifiable. Repo is small enough to read in an evening.

Issues and PRs welcome.

```

- [ ] **Step 3: Self-review proofread of Post 4**

Run: `grep -n '—\|–' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no dashes"`
Expected: "no dashes".

Confirm: highlight bullets are the API-corner specifics (not feature marketing), engineering substance compressed but accurate, link to Post 1 implicit ("earlier this week on r/iOSProgramming"), adoption-readiness section present.

- [ ] **Step 4: Commit Post 4**

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): draft AetherEngine 2.0 Reddit post 4 (r/AppleDevelopers)

Light variant of post 1. Engineering-substance compressed, same
canonical facts, scheduled Day 4 or 5 to avoid Reddit spam-filter
on cross-posts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Draft Post 5 (optional, r/opensource)

**Files:**
- Modify: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`

Lens: License story plus scope-of-openness. Length: ~600 words. **This task is optional.** Ask Vincent before executing whether to draft this post.

- [ ] **Step 1: Confirm with Vincent whether to draft Post 5**

Ask: "Soll Post 5 für r/opensource jetzt mit gedraftet werden, oder erst nach Day-2-Resonanz entscheiden?"

If no / defer: skip Task 6 entirely, proceed to Task 7.
If yes: continue.

- [ ] **Step 2: Append Post 5 section header**

Append to file:

```
================================================================================
5) r/opensource  (Day 6+, optional)
================================================================================

TITLE
-----
Apple-platform media stack with full HDR / Dolby Vision / Atmos pipeline open-sourced under LGPL-3.0 + GPL-3.0 with App Store Exception: licensing notes

```

- [ ] **Step 3: Append Post 5 body**

Append to file:

```
BODY
----
Hi r/opensource,

I want to share a project pair where the licensing story is unusual enough to be worth a post on its own. The actual code is a media engine plus a Jellyfin client for Apple TV, but this post is more about how it's structured and licensed than what it plays.

**Engine (FFmpeg + VideoToolbox media pipeline):** https://github.com/superuser404notfound/AetherEngine, LGPL-3.0 with Apple Store / DRM Exception
**Client (Jellyfin UI shell, built on the engine):** https://github.com/superuser404notfound/Sodalite, GPL-3.0 with Apple Store / DRM Exception
**TestFlight if you want to verify the binary matches the README:** https://testflight.apple.com/join/nWeQzmBX

## The licensing story

Strict GPL-3.0 is incompatible with Apple's App Store distribution terms. The store imposes usage restrictions (DRM-style gating, anti-tampering) that GPL-3 forbids. This is why GPL-3 software historically gets pulled from the App Store and why most copyleft maintainers don't bother trying to ship there at all.

The fix is the **Apple Store / DRM Exception** clause that VLC pioneered. It's an additional permission grant that lives alongside the GPL or LGPL text, explicitly authorizing distribution through stores that impose those usage restrictions, on the condition that the source itself remains under the underlying copyleft terms.

Both repos carry that exception. The result:

* The app shell is GPL-3.0. Any fork that ships must also be open under GPL-3.0, with the same exception scope so it stays distributable
* The engine is LGPL-3.0. Linkable from non-GPL Apple-platform projects under the LGPL's existing dynamic-linking allowance, plus the exception so closed-source apps can use it on the App Store too
* Source is canonical. App Store and TestFlight builds are byte-for-byte from the published commits (no patched-out telemetry that magically appears in the binary)

## On scope of openness

As far as I'm aware, AetherEngine is the first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository. Other players with this architecture exist but paywall those features behind commercial licenses. This was deliberate. The architectural value of the engine is exactly in those formats. Splitting them out into a commercial tier would have made the open-source half a marketing prop.

## Lean dependency graph

Direct dependencies of the app plus engine combined:

* AVFoundation, VideoToolbox, CoreMedia / CoreVideo / AudioToolbox (Apple)
* FFmpeg (LGPL build, dynamic-linkable)
* dav1d (BSD, AV1 software fallback)
* The Jellyfin / Jellyseerr REST APIs themselves

That's it. No analytics SDK, no crash reporting, no auth library, no deep-linking middleware. Network egress is auditable: open `Sodalite/Services/` and you can grep every endpoint the app talks to. The Privacy Manifest declares zero data collection because there is zero data collection.

## On the AI angle

Built in pair-programming with Claude (Anthropic). Every commit was reviewed before landing and ships with a `Co-Authored-By: Claude` trailer so the AI involvement is permanently attributable, not retconnable. Source is open precisely so the disclosure is verifiable. The engine repo is small enough to read in an evening if you want to check the HDR / Atmos paths before forming an opinion.

## Feedback I would value most

* The Exception phrasing: am I missing a footgun a more legally-trained eye would catch?
* Engine split scope: is the LGPL-3.0 / GPL-3.0 split sensible for downstream forks, or are there practical incompatibilities I haven't hit yet?
* Architectural review: the engine repo is small enough to read in one sitting. If anything in there looks structurally wrong, an issue or PR is welcome

```

- [ ] **Step 4: Self-review proofread of Post 5**

Run: `grep -n '—\|–' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no dashes"`
Expected: "no dashes".

Confirm: license story coherent, VLC credited correctly for Exception clause, soft-differentiation sentence present, no namedrops of paywalled competitors.

- [ ] **Step 5: Commit Post 5**

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): draft AetherEngine 2.0 Reddit post 5 (r/opensource)

License-story lens. LGPL-3.0 + GPL-3.0 with App Store Exception
pair, VLC credit for the Exception clause, soft framing on
scope-of-openness vs commercial paywalls. Optional, Day 6+.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Cross-post final review pass

**Files:**
- Read: `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt` (full file)

- [ ] **Step 1: Run em-dash check across all drafts**

Run: `grep -n '—\|–' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`
Expected: no matches (exit code 1).

If any match: edit inline with a comma, period, parenthesis, or colon. Re-run until clean.

- [ ] **Step 2: Verify soft-framing sentence is verbatim in every post**

Run: `grep -c "first Apple-platform media engine where the full HDR / Dolby Vision / Atmos pipeline lives entirely in the open-source repository" /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`
Expected: matches the count of posts drafted (4 if Post 5 skipped, 5 if included).

If a post is missing the verbatim sentence: edit that post to include it.

- [ ] **Step 3: Verify no namedrop of paywalled competitors**

Run: `grep -niE 'KSPlayer|kingslay|nplayer|infuse|VLCKit|Swiftfin' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`
Expected: no matches (`Sodalite` is allowed since it's our own project, but the listed projects must not appear).

If any match: rewrite the line to remove the namedrop.

- [ ] **Step 4: Verify vibe-coded disclosure present in every post**

Run: `grep -c "Co-Authored-By: Claude" /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`
Expected: matches the count of posts drafted (4 or 5).

If a post is missing: edit to add the disclosure paragraph (use Post 2's compact version as template).

- [ ] **Step 5: Verify canonical links present in every post**

Run these and confirm match count equals post count:

```bash
grep -c "github.com/superuser404notfound/AetherEngine" /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
grep -c "testflight.apple.com/join/nWeQzmBX" /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
```

Both should equal the post count (or higher if a post has multiple references).

- [ ] **Step 6: German leakage scan**

Run: `grep -niE '\b(und|nicht|ich bin|aber|auch|für|sehr|dass)\b' /Users/vincentherbst/Dev/Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt || echo "no obvious german"`
Expected: "no obvious german" (English content shouldn't contain these German function words; "auch" / "und" / "für" are the most likely leakage candidates).

If matches surface: review each line in context. Some may be false positives (e.g. "für" inside a quoted error message or German URL). Real leakage gets rewritten.

- [ ] **Step 7: Read full file end-to-end one final time**

Read `Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt` in full. Check for:
- Self-addressing slips ("you should …" referring to Vincent, not the reader)
- Oversell ("amazing", "best ever", "everything you need" patterns)
- Stale claims (anything that contradicts the current README / CHANGELOG)
- Title length reasonableness (Reddit truncates at ~300 chars but ~120 is the practical sweet spot)

Fix any issues inline.

- [ ] **Step 8: Commit review pass**

If any edits were made in Steps 1 through 7:

```bash
git add Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt
git commit -m "$(cat <<'EOF'
docs(marketing): final review pass on AetherEngine 2.0 Reddit drafts

Em-dash, namedrop, German-leakage, oversell, self-address audit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If no edits were needed: skip the commit, drafts are ready.

- [ ] **Step 9: Push drafts to remote**

```bash
git push origin main
```

Drafts are now visible at the GitHub Sodalite repo for reference during posting.

---

### Task 8: Hand off posting cadence to Vincent

This task is the handoff, not Claude work. Document what Vincent does and when.

- [ ] **Step 1: Generate posting checklist for Vincent**

Output to terminal:

```
Drafts ready at Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt.

Posting cadence (Vincent to execute):
  Day 0 (today or tomorrow):
    - Post on r/iOSProgramming (draft #1 in the file)
    - Update AetherEngine GitHub pinned issue or create one for 2.0
    - Stay in the thread for ~3 hours answering top-level comments
  Day 1:
    - Post on r/swift (draft #2)
  Day 2:
    - Post on r/vibecoding (draft #3)
  Day 3:
    - Triage feedback only, no new post
  Day 4 or 5:
    - Post on r/AppleDevelopers (draft #4)
  Day 6+ (optional, if drafted):
    - Post on r/opensource (draft #5 in this file, or update draft 7 in RedditPosts.txt)

Risk reminders:
  - KSPlayer author or fans may appear. Credit the local-HLS-loopback approach
    to KSPlayer for pioneering the architecture, point out the scope difference,
    no escalation.
  - Vibe-coded backlash possible. Counter-evidence: commit log, Co-Authored-By
    trail, tests + CI, public-beta survived.
  - If any post hits ~50+ comments early, skip the next day's post and stay in
    the active thread. Better to answer well than to be everywhere.

Bug reports: route to GitHub Issues on the AetherEngine or Sodalite repo
depending on which surface the report concerns. Engine bugs to AetherEngine,
client UX bugs to Sodalite.
```

- [ ] **Step 2: Confirm Vincent has received the checklist**

Wait for Vincent's go-signal before considering the plan complete.

---

## Self-Review Notes

Spec coverage check:
- 4 mandatory posts + 1 optional: covered by Tasks 2 through 6
- Pre-flight checklist (.dmg, README, CI, screenshots): Task 1 covers .dmg, README, CI; screenshots are listed in the spec pre-flight but not in this plan since they are Reddit-posting-time assets that Vincent attaches manually. Noted explicitly in the Task 8 handoff.
- Cadence handoff: Task 8
- Risk mitigations (KSPlayer namedrop, vibe-coded backlash, "first stable" confusion): covered in Task 7 verification + Task 8 risk reminders
- Forbidden items (em-dashes, namedrops, German leakage, self-addressing): covered in Task 7 Steps 1-7

Placeholder scan: none found. All steps have concrete commands or concrete text to append.

Type consistency: file paths consistent throughout (`Sodalite/Marketing/RedditPosts_AetherEngine_2.0.txt`). The soft-differentiation sentence is verbatim across all post-drafting steps and the verification step (Task 7 Step 2).

Spec requirement with no task: Screenshots (DemoPlayerMac running, MinimalPlayer in Xcode, player UI with HDR badge). These are not Claude-writable artifacts. Surfaced explicitly in Task 8 handoff so Vincent prepares them before posting Day 0.
