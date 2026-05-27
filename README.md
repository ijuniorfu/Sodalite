<p align="center">
  <img src=".github/sodalite-logo.png" alt="Sodalite" width="180">
</p>

<h1 align="center">Sodalite</h1>

<p align="center">
  <b>Your Jellyfin library <i>and</i> Seerr, together on Apple TV.</b><br>
  Native tvOS, instant playback, real HDR, real Dolby Atmos.<br>
  Browse what you own. Request what's missing. Without ever leaving the couch.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tvOS-26%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-GPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
  <img src="https://img.shields.io/badge/languages-26-blue">
  <img src="https://img.shields.io/badge/status-public%20beta-orange">
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

> 🧪 **Public Beta is open.** Install via TestFlight: **https://testflight.apple.com/join/nWeQzmBX**
> See [BETA.md](BETA.md) for what to focus on and how to report bugs.

---

## Two services, one remote

Sodalite brings **Jellyfin and Seerr together in the same UI** on Apple TV. Watch what's already on your server. Spot something on a trending row that isn't there yet? Request it from inside the app, and Seerr handles the rest.

No more switching to a phone, opening a web UI, or pinging your homelab admin. Single sign-on, one focus-driven interface, the full library plus request loop on the TV where you actually watch.

## Open source, end to end

Sodalite is open from end to end. Every byte that touches your server is in this repo, your auth tokens stay in your Keychain, and there's no telemetry, no analytics, no third-party SDK phoning home.

Licensed under **GPL-3.0 with an Apple Store / DRM Exception**. Fork it, study it, build your own version, but no one can take it private. Modifications must stay open. The exception clause in the LICENSE keeps the App Store and TestFlight distribution paths legally clean. The video stack underneath ([AetherEngine](https://github.com/superuser404notfound/AetherEngine)) is **LGPL-3.0** with the same Apple Store exception, so the engine can be reused in other apps while engine-level improvements flow back to the community. Both are auditable, buildable from source, and free of any vendor lock-in. Self-host the server, self-build the client, the whole loop is yours.

## Built natively for tvOS

Sodalite is built natively from the ground up: SwiftUI on top, a custom video engine underneath, and the same HIG patterns Apple uses for TV+: focus engine, Siri Remote gestures, transport bar, info panel. Plays the file directly from your server in almost every case, no transcoding required.

The Seerr integration isn't a tacked-on link to a web view. It's a first-class part of the app, with its own browse rows, request flow, and status tracking right next to your library.

## Features

### 📚 Browse & discover
- **Server discovery**: finds Jellyfin on your network automatically, or add manually
- **Home**: Continue Watching, Next Up, Latest by library, fully customizable
- **Library**: Movies, Series, Collections with poster grids and instant filtering
- **Series view**: season picker, episode list, "Up Next" highlighting
- **Search**: across your whole server, results as you type
- **Image caching & prefetching**: posters and backdrops load before you focus them
- **Delete from the app**: remove movies, series, or individual seasons from your library, with optional cleanup of matching Radarr / Sonarr entries when Jellyseerr is connected

### 🎬 Watch
- **Direct Play** for almost every codec on your server: H.264, HEVC, HEVC Main10, AV1, VP9, VP8, MPEG-4 Part 2 (XVID / DIVX), MPEG-2, VC-1. Containers: MKV, MP4, MOV, AVI, MPEG-TS, M2TS, VOB, 3GP, WebM, OGG, FLV. Server-side transcoding stays reserved for fringe codecs (WMV3, Theora, RealVideo).
- **HDR10, HDR10+, Dolby Vision, HLG**: auto-detected, sent through with full color metadata. HDR10+ streams forward per-frame ST 2094-40 dynamic metadata so HDR10+ TVs apply the source's tone-mapping curves; Dolby Vision streams signal as `dvh1` so DV-capable TVs switch into Dolby Vision mode for Profile 5, 8.1 and 8.4. The display switches to the matching HDR mode automatically (Match Content).
- **Dolby Atmos** via EAC3+JOC, wrapped as Dolby MAT 2.0 so your AVR's Atmos light actually comes on
- **Multichannel surround**: 5.1, 7.1 with correct channel layout
- **Resume** from where you left off, on any device
- **Intro skip**: auto-detected from your Jellyfin server, optional one-tap skip
- **Next episode**: auto-play with countdown, or just an overlay; configurable
- **Subtitles, all formats, client-side**: text codecs (SubRip, ASS, SSA, WebVTT, mov_text) decoded inline in AetherEngine as packets flow through the demuxer, no server extraction lag on first hit. Bitmap subtitles (PGS, HDMV PGS, DVB, DVD) rendered as native images at the right position on the frame, no more relying on the server having Tesseract installed for Blu-ray rips. Sidecar `.srt` / `.ass` / `.vtt` files parsed by FFmpeg as well. Track switching mid-playback, with auto-resolution against your preferred audio / subtitle language.
- **Audio track switcher**: pick the language or surround mix you want, mid-playback
- **Native player UI**: same transport bar, scrub preview and info panel as Apple TV+
- **Stats for Nerds overlay**: optional info panel during playback. Static section shows container, video codec / range / framerate / bitrate / decoder, audio codec / channels / bitrate / decoder, subtitle codec. Live section refreshes at 1 Hz with instant + average bitrate from the demuxer, forward buffer + cached MB, network throughput, dropped frames (native AVPlayer) or observed FPS (software AV1), plus a colour-coded A/V sync gap. A second toggle adds an Engine Diagnostics deep-dive (producer restarts, RSS, demuxer / muxer / audio-bridge bytes, server traffic) for troubleshooting. Enable in Settings → Playback → Advanced.
- **iPhone Control Center skip**: 10-second forward and backward skip buttons in the iPhone's Now Playing widget route through to the engine via `MPRemoteCommandCenter`, App Store compliant (no private API). Useful when the Siri Remote is across the room.

### 📨 Request what's missing
- **Seerr integration**: browse trending and popular media right inside the app
- **One-tap requests** for movies and full series
- **Track status**: see what's been approved, declined, or is already downloading
- **Single sign-on**: log in once, Sodalite handles your Seerr session
- **Admin view**: with Jellyseerr admin permissions, approve, decline, edit, or delete any user's request right from the All Requests tab

### 🌍 Personal
- **26 languages**: German, English, Spanish, French, Italian, Japanese, Korean, Norwegian, Dutch, Polish, Portuguese (BR + PT), Russian, Swedish, Simplified + Traditional Chinese, Turkish, Ukrainian, Czech, Slovak, Croatian, Finnish, Greek, Hungarian, Romanian, Danish
- **Dark, minimal design** built for living rooms, not for desks
- **Liquid Glass** UI accents on tvOS 26+
- **Siri Remote optimized**: touch surface scrubbing, click for play/pause, swipe gestures throughout

## Built on

Sodalite is a thin native shell over a custom video stack: Apple's frameworks plus a Swift package that handles the formats Apple's own player can't on its own.

| Component | Technology |
|---|---|
| UI | SwiftUI + UIKit interop where needed |
| Video engine | [AetherEngine](https://github.com/superuser404notfound/AetherEngine): FFmpeg demux, AVPlayer + VideoToolbox for HEVC / H.264 / HW-AV1, dav1d + libavcodec for AV1 / VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 software fallback |
| Display | `AVPlayer` + `AVPlayerLayer` for the native path; `AVSampleBufferDisplayLayer` + `AVSampleBufferRenderSynchronizer` for the software path |
| Audio | `AVPlayer` over local HLS-fMP4 for the native path (Atmos as MAT 2.0, EAC3 5.1 bridge by default for Opus / TrueHD / MLP / DTS / DTS-HD MA / MP2 / MP3 so surround works on every modern soundbar via the bitstream tunnel; optional lossless FLAC bridge for AVRs that accept multichannel LPCM over HDMI); `AVSampleBufferAudioRenderer` for the software path |
| Networking | `URLSession` against the Jellyfin REST API |
| Persistence | Keychain for credentials, no telemetry storage |
| Media server | [Jellyfin](https://jellyfin.org) |

For the full pipeline detail (HDR routing, Atmos passthrough, A/V sync, channel-layout tagging), see the [AetherEngine README](https://github.com/superuser404notfound/AetherEngine#readme).

## Requirements

| | Min |
| --- | --- |
| Apple TV | 4K (any generation) |
| tvOS | 26.0 |
| Jellyfin server | 10.9+ recommended |
| Seerr (optional) | 2.0+ |

A 1080p Apple TV HD will technically run the app, but Direct Play of 4K HDR content needs the 4K hardware.

## Building from source

```bash
git clone https://github.com/superuser404notfound/Sodalite.git
cd Sodalite
open Sodalite.xcodeproj
```

Pick the `Sodalite` scheme, an Apple TV destination, and run. AetherEngine is wired in as a local Swift Package, so you'll need it cloned next to this repo (or adjust the path in Package dependencies).

```
~/Dev/
├── Sodalite/
└── AetherEngine/
```

Xcode 26+ and Swift 6.0+ are required.

For engine-level debugging without an Apple TV in the loop, AetherEngine ships a standalone macOS CLI (`aetherctl probe / serve / validate <url>`). See the [AetherEngine README](https://github.com/superuser404notfound/AetherEngine#aetherctl) for usage.

## Roadmap

- [x] Public TestFlight beta
- [ ] App Store release
- [ ] iOS / iPadOS companion app
- [ ] In-app library-update banner via Jellyfin's WebSocket, surfaces a quiet notification when Sonarr / Radarr ingests new content while Sodalite is open. No backend service, no APNs, same self-hosted data flow as everything else
- [ ] Live TV + DVR support
- [ ] Music library support

## Community

Everything happens in the open. No Discord, no closed garden.

- **[Discussions](https://github.com/superuser404notfound/Sodalite/discussions)**: Q&A, ideas, show-and-tell
- **[Issues](https://github.com/superuser404notfound/Sodalite/issues)**: bugs and concrete feature requests

If you're not sure which to use, start a Discussion. Bugs get moved to Issues. Both are public, indexed by search engines, and stay tied to the project, so the next person with the same question can find the answer.

## Support

Sodalite is free and stays that way. If it's useful to you and you'd like to say thanks, there's a [Ko-fi](https://ko-fi.com/superuser404). The app also has an in-app Tip Jar and a Supporter Pack (cosmetics only, no gating).

## Related

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine): the video engine powering Sodalite
- [Jellyfin](https://github.com/jellyfin/jellyfin): the free software media system
- [Seerr](https://github.com/Fallenbagel/jellyseerr): request management for Jellyfin

## Built with

Sodalite is vibe-coded, designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

[GPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause keeps App Store and TestFlight distribution legally clean while the GPL keeps the source open and forks copyleft.
