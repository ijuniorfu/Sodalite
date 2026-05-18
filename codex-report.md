# AetherEngine + AVPlayer long-form 4K HDR HEVC memory leak

Status report for external review. Self-contained — assume no prior context on the codebase.

## Executive summary

On Apple TV 4K (Gen 3, tvOS 26), playing a 25 Mbps 4K HDR HEVC source through our HLS-fMP4 client-side remux pipeline causes the app process RSS to climb monotonically at roughly the source video bitrate (2.6 to 3.3 MB/sec sustained). The process hits the tvOS jetsam threshold (~1.45 GB) and is silently terminated after 8 to 13 minutes. The growth is empirically inside AVPlayer's HLS-fMP4 pipeline, not in our application heap. Every test we've run to coax AVPlayer's internal cache to release has produced 0-13% movement on the growth rate. We have exhausted simple-test hypotheses and are about to commit to an architectural pivot (replacing AVPlayer with a VideoToolbox-based custom decode path) unless an outside perspective spots something we've missed.

## Project context

- **Sodalite**: tvOS 26+ native Jellyfin client (Swift 6, SwiftUI shell)
- **AetherEngine**: Swift package implementing the video engine, sister repo
- Target: Apple TV 4K Gen 3, tvOS 26
- Source format: raw MKV pulled from Jellyfin via DirectPlay (no server-side transcoding allowed — hard requirement from product)
- Hard constraint: HEVC software decoding is not acceptable

## Architecture

The AVPlayer playback path is:

```
Jellyfin server (HTTP, raw MKV)
    │
    ▼
AVIOReader (URLSession, 8 MB chunk fetch with prefetch ahead)
    │
    ▼
Demuxer (libavformat matroska, +genpts fflag)
    │
    ▼
HLSSegmentProducer (lazy fmp4 mux via libavformat hlsenc + inner mp4 muxer)
    │
    ▼
SegmentCache (disk-backed, mmap reads, 15-segment sliding window: 5 backward + 10 forward)
    │
    ▼
HLSLocalServer (NWConnection, 127.0.0.1, serves /media.m3u8 + /init.mp4 + /seg-N.mp4)
    │
    ▼
AVPlayer + AVPlayerLayer (via AVPlayerViewController)
    │
    ▼
HDMI (4K HDR10 in this test — DV stripped via codec-tag override to hvc1)
```

Specifically for the test source:
- Container: MKV, 25 GB total, 2h32m
- Video: HEVC Main10 L5.0, 3840×1600, 23.976 fps, ~25 Mbps peak, DV Profile 8.1 base layer
- Audio: DTS (requires FLAC bridge because DTS is not fMP4-legal)
- Effective HLS output: hvc1 (DV signaling stripped) + fLaC

The DV base layer is preserved in the HEVC bitstream but the dvh1 sample-entry tag is replaced with hvc1 because the panel is not in DV mode in this test (Match Content disabled).

## Diagnostics instrumented

We added a 30-second memprobe loop with per-component byte counters threaded through the pipeline:

- `rss` — process RSS via `mach_task_self()` / `task_info()`
- `avioFetchedMB` — cumulative bytes pulled by AVIOReader
- `cacheCount` / `cacheMB` — resident SegmentCache state (now on disk)
- `producerPacketsWritten` — av_write_frame call count
- `audioFifoSamples` — AudioBridge FIFO depth (FLAC re-encode buffer)
- `avBufAhead` / `avBufBehind` — AVPlayer's own `loadedTimeRanges` decomposed around the playhead

The pipeline-side counters told a clear story over 10-15 minute runs:

- SegmentCache stays at 100-160 MB on disk, our Swift heap retains effectively nothing
- AudioBridge FIFO bounded under 4096 samples
- packetsWritten linear at ~24/sec matching frame rate
- avioFetched grows at exactly content bitrate
- RSS grows at ~63% of the avioFetched rate, modulated by occasional tvOS memory-warning sweeps that release `AVMediaSelectionOption.displayNamecache` plus some unnamed chunks (logged), but not enough to reverse the trend

Net: our pipeline's contribution is bounded. The growth is downstream of our HTTP handoff to AVPlayer.

## Test matrix

Every attempt run end-to-end against the same source. Memory growth rate column is steady-state average across the 30-second memprobe ticks after warmup, in MB/sec.

| Attempt | Growth rate | Notes |
|---|---|---|
| Original (NWConnection HTTP, RAM cache, VOD playlist + ENDLIST) | 5.0 MB/sec | Baseline |
| `urlCache = nil` on AVIOReader's URLSession | 3.0 MB/sec | Instruments traced ~600 MB of persistent `_NSURLStorageURLCacheDB` allocations to our session. Real fix but partial. |
| Per-request URLSession (release task pool) | 3.0 MB/sec | No change, reverted |
| `+genpts` demuxer fflag (replace custom NOPTS-dts repair) | 3.0 MB/sec | Should be cleaner segments per FFmpeg's tested path, but no measurable effect on AVPlayer side |
| Disk-backed SegmentCache + `Data(.alwaysMapped)` reads | 2.6 MB/sec | RAM saved at session start (~120 MB), growth rate unchanged within noise |
| Drop `EXT-X-PLAYLIST-TYPE:VOD` tag + `EXT-X-START` | 3.3 MB/sec | Matched DrHurt's known-good reference playlist exactly. No improvement; worse within noise. |
| Sliding-window EVENT playlist | 1.7 MB/sec | But AVPlayer fires CoreMediaErrorDomain -12888 ("Playlist File unchanged for longer than 1.5 * target duration") after 60s because EVENT playlists must grow over time per RFC 8216 §6.2.1. Made it growing-on-each-fetch with a custom X-SODALITE-REFRESH counter for byte-level freshness. AVPlayer still treats the resulting playlist as `LIVE` in Now Playing UI (asset.duration = NaN) which breaks the scrub bar and the replay-from-zero button. |
| Audio path disabled entirely (leak isolation test) | 3.9 MB/sec | Counter-intuitively WORSE. Hypothesis: AVPlayer uses audio sync as a throttle on the video decoder; without it, the IOSurface / decoder pool grows faster. Empirically rules out FLAC bridge as the leak source. |
| `replaceCurrentItem` with same URL + position every 5 min (POC) | -73 MB drop per reload, growth resumes | State release on item replacement is real but small (~8% of accumulated AVPlayer state). Operation also breaks the HLS pipeline: producer-race where the cache had pruned segs based on pre-reload target, post-reload AVPlayer asked for one and got 404. |
| `appliesPerFrameHDRDisplayMetadata = false` | 3.0 MB/sec | Engine sets this to false for non-master-playlist paths anyway, so this test was already in baseline. Doesn't help. |
| `AVPlayerItemVideoOutput` removed (lazy attach only for audio-track switch freeze frame) | small one-time saving, no rate change | Used to be unconditionally attached for the freeze-frame overlay during audio-track switches. Now lazy-attached and detached after the snapshot. |

## What we tried but couldn't measure properly

- **DV RPU NAL strip** (NAL type 62 removal from HEVC bitstream): hand-rolled parser broke playback (matroska demuxer outputs Annex-B framed packets, not always length-prefix). `filter_units` BSF not compiled into our FFmpegBuild.
- **Per-frame HDR metadata pipeline isolated**: the `appliesPerFrameHDRDisplayMetadata` flag governs this, and we have it false for the routing decision that this test source takes (panel-locked SDR + match-off path).

## What DrHurt observes

DrHurt is an external contributor who has been testing AetherEngine and provided a known-good remux reference. His key empirical observations on similar but not identical content:

- 2h20 of 80 Mbps HLS through AVPlayer with no memory issues, but Jellyfin server-produced HLS (not our client-side lazy producer)
- "ProAVPlayer" (commercial tvOS app) doesn't have this issue either; its architectural difference is a 1 GB disk cache for HLS segments
- He suspects we may be emitting "subtly deformed mp4 segments that unmask an AVPlayer / HLS bug"
- His own reference: DV5 1920×1080 at ~12 Mbps, manual ffmpeg remux, plays through cleanly

We diffed his reference init.mp4 + first segment byte-for-byte against ours. Identical: ftyp brands (`iso5/iso5/iso6/dby1/mp41`), styp brand on segments (`msdh/msdh/msix` from FFmpeg's `+dash` movflag), two-sidx-per-segment structure (one per track), two-track layout (video + audio). The only structural delta on the playlist side was that he ships `EXT-X-ENDLIST` with no `EXT-X-PLAYLIST-TYPE` tag, ours had `:VOD` + `ENDLIST`. Per RFC 8216 §4.3.3.5 those differ on the policy hint to the client. We dropped the `:VOD` tag in [`b9909ff`](https://github.com/superuser404notfound/AetherEngine/commit/b9909ff) and saw no improvement (growth went from 2.6 to 3.3 MB/sec, within noise).

His content differs from ours in three axes we have NOT controlled for:
1. Resolution: 1080p vs 4K
2. Bitrate: ~12 Mbps vs ~25 Mbps
3. Segment duration: 6 s vs 4 s

## Empirical findings about AVPlayer's behaviour

Pulled together from instrumentation and the test matrix:

1. **Growth rate scales with source bitrate, not decode rate.** At 24 fps × 36 MB/frame uncompressed, full-frame retention would be 864 MB/sec. We see 2.6-3.3 MB/sec. The leak is on the compressed side, not decoded frames. Decoded frames are recycled correctly via CVPixelBufferPool.

2. **`loadedTimeRanges` reports a bounded window (avBufAhead 4-7 s, avBufBehind 30-34 s)** but RSS shows AVPlayer holds materially more than that. The reported window is "actively usable for scrub"; underlying compressed-byte retention is larger.

3. **AVPlayer does not HTTP-cache** (confirmed empirically and per multiple Apple Forum threads). Our `Cache-Control: no-store` header is correct but not the lever.

4. **Memory warnings released only `AVMediaSelectionOption.displayNamecache`** by name, plus some unnamed chunks. Long-term state survives memory warnings.

5. **`replaceCurrentItem` releases ~73 MB**, then growth resumes at the same rate. Suggests state is at the AVPlayer level (not the AVPlayerItem level), or the AVPlayerItem release path doesn't drain all referenced state.

6. **Audio path is not the cause** (disabling it makes growth WORSE).

7. **Apple Media Engineer (Apple Forum #767727) confirms streams above 20 Mbps are part of their test matrix**, suggesting bitrate alone is not an Apple-known issue.

## What's structurally unique to our setup

Compared to apps that play long-form 4K HDR HEVC without this issue (Infuse uses Metal direct, Swiftfin uses VLCKit, ProAVPlayer disk-caches, DrHurt's Jellyfin path uses server-produced HLS over HTTPS):

1. **HTTP loopback to 127.0.0.1** for HLS, not remote HTTPS
2. **Client-side lazy production** of fMP4 segments (vs pre-produced static files)
3. **Producer can restart** mid-session for backward-seek beyond cache window (replaces init.mp4 with a slightly different ~24-byte version due to `start_number` change; AVPlayer doesn't re-fetch init.mp4 so it works against the original init across restarts)
4. **DV-stripped HEVC**: source has DV Profile 8.1 with RPU NALs still in bitstream, but we emit hvc1 codec tag rather than dvh1 (for the media-playlist tone-map routing path)
5. **FLAC bridge** for DTS audio (lossless re-encode through libavcodec)

The HTTP-loopback-vs-remote and lazy-production-vs-static-files axes are the only ones we haven't been able to fully isolate.

## Architectural options on the table

1. **VT-bypass migration**. Replace AVPlayer with a VideoToolbox + AVSampleBufferDisplayLayer pipeline for HEVC. POC verified at 0.05 MB/sec growth (1000x improvement). Cost: 2-3 days implementation. Trade-offs: lose native Dolby Vision HDMI handshake (AVPlayer-only on tvOS), lose AVPlayerViewController auto-publish to MPNowPlayingInfoCenter, lose AirPods auto-pause via AVKit (would need to reimplement via `AVAudioSession.routeChangeNotification`). The MPNowPlayingInfoCenter rebuild is feasible because the documented libdispatch race against AVPlayer's HTTP loopback (project memory) is specific to that combination; VT path has no HTTP loopback.

2. **Pre-produce all segments to disk before playback starts**. Eliminates the lazy-producer-vs-static-source axis. Cost: ~25 GB temp storage per session, multi-minute pre-mux startup latency. Probably user-experience-fatal.

3. **Periodic AVPlayer-instance recycle**. Spawn fresh `AVPlayer` (not `replaceCurrentItem`) every ~5 minutes with seamless transition. POC limited because `replaceCurrentItem` only released ~73 MB; a fresh AVPlayer might release more, unverified. UX: brief stutter every 5 min.

4. **6-second segments**. Cuts per-track sample-table cardinality by ~33% (2286 → 1500 segs for our test source). Requires producer refactor.

5. **Bypass HLS entirely, serve direct MP4 via AVAssetResourceLoaderDelegate**. AVPlayer's HLS-fMP4 demuxer is a different code path than the plain MP4 demuxer. May have different cache behaviour. But AVAssetResourceLoaderDelegate "rejected by AVPlayer per Apple Forum 113063 (Apple Media Engineer reply)" for HLS segments specifically; only `.m3u8` playlists go through the delegate, segments need HTTP redirect. For direct MP4 (not HLS) the delegate works fully.

## Open questions where fresh eyes would help

1. The leak rate matches source bitrate within noise. What internal AVPlayer state grows proportionally to compressed-byte intake? We've ruled out decoded frames, our HTTP cache, AVPlayer's HTTP cache, and the avBufBehind window as it's reported. Suspected: HLS-fMP4 demuxer's per-track sample table or NAL-unit cache, but no public API to inspect or bound it.

2. Why does disabling audio make the leak WORSE? Our working theory is that AVPlayer's audio sync paces the video decoder, and without that pacing the decoder pool grows faster. But that would be IOSurface / pixel-buffer growth, which should be 36 MB × N. We see compressed-byte-rate growth, not pixel-buffer-rate growth. The mechanism is unclear.

3. ProAVPlayer's "1 GB disk cache" — does that mean ProAVPlayer is bypassing AVPlayer's internal HLS cache entirely via some mechanism we're missing, or just that their disk cache happens to correlate with bounded RAM by coincidence? If the former, what's the mechanism (AVAssetResourceLoaderDelegate is supposedly limited to playlist interception per Apple's own engineer)?

4. Is the localhost HTTP loopback specifically treated differently by AVPlayer? E.g., does AVPlayer consider 127.0.0.1 a "fast / lossless source" and choose to cache more for backward-seek convenience compared to remote HTTPS where caching less is appropriate for bandwidth reasons?

5. We had an experiment where audio-disabled was 30% worse, hinting at decoder-pool growth without audio pacing. But the overall growth pattern still LOOKS like compressed-byte retention, not decoded-frame retention. Could AVPlayer's HLS path be retaining per-segment metadata records (parsed sample tables, NAL pointers, frame index entries) at a rate proportional to incoming compressed bytes? That would explain both the bitrate-scaling and the audio-pacing dependency.

## Current state of the code

Repos:
- AetherEngine: https://github.com/superuser404notfound/AetherEngine
- Sodalite: https://github.com/superuser404notfound/Sodalite

Latest commits on the leak-investigation branch:
- AetherEngine `b9909ff` — drop `EXT-X-PLAYLIST-TYPE:VOD` / `EXT-X-START` to match DrHurt's reference (no improvement)
- AetherEngine `a008909` — disk-backed SegmentCache with mmap reads (saves 120 MB at start, growth unchanged)
- AetherEngine `e6f0b60` — `+genpts` fflag, drop custom NOPTS-dts repair

The full investigation thread with DrHurt is at https://github.com/superuser404notfound/AetherEngine/issues/4 (latest comment from us is comment 4478699459 summarising the test matrix).

## Question for Codex

Given the empirical finding that AVPlayer's HLS-fMP4 pipeline retains compressed bytes at ~63% of the rate they arrive over the wire, modulated by tvOS memory-warning sweeps that release only `AVMediaSelectionOption.displayNamecache` plus unnamed small chunks, is there:

1. A public AVFoundation API surface we've missed that controls AVPlayer's internal HLS cache / sample-table retention?
2. A known Apple bug or documented behaviour pattern (WWDC session, TechNote, Feedback Assistant thread) that maps to this growth profile on tvOS 26 specifically?
3. A pattern someone in the streaming-app space has used to make AVPlayer bounded for long-form high-bitrate HEVC HDR playback that doesn't involve dropping AVPlayer entirely?

The architecturally clean path (VT migration) is verified working but costs real UX (DV mode handshake, AVKit Now Playing integration). We want to make sure we've exhausted the AVPlayer side before pivoting.
