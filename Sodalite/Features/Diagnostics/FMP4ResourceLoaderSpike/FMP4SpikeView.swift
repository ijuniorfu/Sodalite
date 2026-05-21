import AVFoundation
import AVKit
import SwiftUI

/// Stage 1 spike UI. Plays a local fragmented MP4 file via AVPlayer
/// using `AVAssetResourceLoaderDelegate.respond(with:)` to deliver
/// bytes in-process, with NO HTTP / NO CFNetwork involvement. Test
/// goal: confirm whether the libnetwork buffer-pool retention is
/// eliminated and that Atmos / DV / scrubbing still work.
///
/// File placement: drop a fragmented MP4 at
/// `Documents/spike-test.mp4`. Easiest path on tvOS, run a one-shot
/// HTTP server on the Mac and use the in-app Download button below.
/// Recommended ffmpeg incantation on the Mac side:
///
///   ffmpeg -i source.mkv -c copy -t 60 \
///     -movflags +empty_moov+default_base_moof+frag_keyframe+frag_duration=4000000 \
///     spike-test.mp4
///   python3 -m http.server 8000
///
/// Then edit `SPIKE_DOWNLOAD_URL` below to point at
/// `http://<mac-lan-ip>:8000/spike-test.mp4` and tap Download in the
/// spike screen. The file lands in Documents and Play activates.
///
/// To verify Atmos passthrough, `source.mkv` must contain an EAC3-JOC
/// audio track. For DV verification, a P5 / P8 HEVC dvh1 source.

/// Edit this to your Mac's LAN URL hosting the spike test file.
/// Hardcoded rather than via TextField because TextField focus on tvOS
/// is brittle, see commit 2586af5a removing the QuickPlay TextField.
private let SPIKE_DOWNLOAD_URL = "http://192.168.0.10:8000/spike-test.mp4"

struct FMP4SpikeView: View {
    @State private var presentPlayer: Bool = false
    @State private var diagnostics: SpikeDiagnostics?
    @State private var lastError: String?
    @State private var downloadState: DownloadState = .idle
    @State private var downloadProgress: Double = 0

    enum DownloadState: Equatable {
        case idle
        case downloading
        case finished
        case failed(String)
    }

    private static var testFileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("spike-test.mp4")
    }

    private var fileExists: Bool {
        guard let url = Self.testFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var fileSizeMB: Double? {
        guard let url = Self.testFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.doubleValue / 1024.0 / 1024.0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                header
                fileStatusCard
                if fileExists {
                    Button {
                        diagnostics = nil
                        lastError = nil
                        presentPlayer = true
                    } label: {
                        Label("Start Spike Playback", systemImage: "play.circle.fill")
                            .font(.title3)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                }
                downloadCard
                if let diag = diagnostics {
                    diagnosticsCard(diag)
                }
                if let err = lastError {
                    errorCard(err)
                }
            }
            .padding(40)
            .frame(maxWidth: 1100)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("fMP4 ResourceLoader Spike")
        .fullScreenCover(isPresented: $presentPlayer) {
            if let url = Self.testFileURL {
                FMP4SpikePlayerHost(localFileURL: url) { result in
                    presentPlayer = false
                    switch result {
                    case .success(let diag): diagnostics = diag
                    case .failure(let err): lastError = err.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 8) {
            Text("Stage 1: foundation test")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Plays a local fMP4 via AVAssetResourceLoaderDelegate.respond(with:). No HTTP, no CFNetwork. Verifies AVPlayer's non-HLS reader accepts delegate-served bytes for a fragmented MP4.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
        }
    }

    private var fileStatusCard: some View {
        let docsPath = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?.path ?? "(no docs dir)"
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: fileExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(fileExists ? .green : .red)
                Text(fileExists ? "Test file present" : "Test file missing")
                    .font(.headline)
                Spacer()
                if let mb = fileSizeMB {
                    Text(String(format: "%.1f MB", mb))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Expected path:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(docsPath)/spike-test.mp4")
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
            if !fileExists {
                Text("Copy a fragmented MP4 there via the Xcode Devices window, or sideload via any developer mechanism. Recommended ffmpeg incantation is in the source comment of FMP4SpikeView.swift.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
    }

    private func diagnosticsCard(_ d: SpikeDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.headline)
            row("Outcome", d.outcome)
            row("Loading requests", "\(d.requestCount)")
            row("Bytes served", String(format: "%.1f MB", Double(d.bytesServed) / 1024.0 / 1024.0))
            row("Content info fulfilled", d.contentInfoFulfilled ? "yes" : "no")
            row("Last requestsAllData flag", d.lastRequestAllData ? "true" : "false")
            if let err = d.lastError {
                row("Last serve error", err)
            }
            if let playerErr = d.playerError {
                row("AVPlayer error", playerErr)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Spike error", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
            Text(msg)
                .font(.body.monospaced())
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.red.opacity(0.1)))
    }

    @ViewBuilder
    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tint)
                Text("Download test file")
                    .font(.headline)
                Spacer()
            }
            Text("Source URL (edit SPIKE_DOWNLOAD_URL in FMP4SpikeView.swift):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(SPIKE_DOWNLOAD_URL)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            switch downloadState {
            case .idle:
                Button {
                    runDownload()
                } label: {
                    Label(fileExists ? "Re-download (overwrite)" : "Download to Documents",
                          systemImage: "arrow.down.circle")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            case .downloading:
                ProgressView(value: downloadProgress)
                    .progressViewStyle(.linear)
                Text(String(format: "%.0f%%", downloadProgress * 100))
                    .font(.caption.monospacedDigit())
            case .finished:
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry") { runDownload() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
    }

    private func runDownload() {
        guard let src = URL(string: SPIKE_DOWNLOAD_URL),
              let dst = Self.testFileURL else {
            downloadState = .failed("invalid URL or no Documents dir")
            return
        }
        downloadState = .downloading
        downloadProgress = 0
        Task {
            do {
                let (asyncBytes, response) = try await URLSession.shared.bytes(from: src)
                let total = response.expectedContentLength
                if FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.removeItem(at: dst)
                }
                FileManager.default.createFile(atPath: dst.path, contents: nil)
                let handle = try FileHandle(forWritingTo: dst)
                var bytesWritten: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(64 * 1024)
                for try await byte in asyncBytes {
                    buffer.append(byte)
                    if buffer.count >= 64 * 1024 {
                        try handle.write(contentsOf: buffer)
                        bytesWritten += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        if total > 0 {
                            let p = min(1.0, Double(bytesWritten) / Double(total))
                            await MainActor.run { downloadProgress = p }
                        }
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    bytesWritten += Int64(buffer.count)
                }
                try handle.close()
                await MainActor.run {
                    downloadProgress = 1.0
                    downloadState = .finished
                }
            } catch {
                await MainActor.run {
                    downloadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
        }
    }
}

// MARK: - Diagnostics

struct SpikeDiagnostics {
    var outcome: String
    var requestCount: Int
    var bytesServed: Int
    var contentInfoFulfilled: Bool
    var lastRequestAllData: Bool
    var lastError: String?
    var playerError: String?
}

// MARK: - AVPlayerViewController host

/// Wraps `AVPlayerViewController` so SwiftUI can present it
/// full-screen. Owns the `AVURLAsset` + delegate for the spike
/// session. On dismiss, returns the delegate's diagnostics.
struct FMP4SpikePlayerHost: UIViewControllerRepresentable {
    let localFileURL: URL
    let onDismiss: (Result<SpikeDiagnostics, Error>) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        do {
            let delegate = try FMP4FileResourceLoaderDelegate(fileURL: localFileURL)

            // Custom scheme. Important: filename suffix `.mp4` —
            // AVPlayer silently rejects extensionless asset URLs
            // even with a correct content-type UTI on the content
            // info response (forum 129155).
            guard let assetURL = URL(string: "aether-spike://session/movie.mp4") else {
                onDismiss(.failure(NSError(domain: "FMP4Spike", code: 2,
                                           userInfo: [NSLocalizedDescriptionKey: "bad asset URL"])))
                return vc
            }

            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(delegate, queue: context.coordinator.delegateQueue)
            context.coordinator.delegateRef = delegate

            let item = AVPlayerItem(asset: asset)
            // Per-frame HDR for DV passthrough. Matches what
            // NativeAVPlayerHost.load() does for the normal path.
            item.appliesPerFrameHDRDisplayMetadata = true
            // Modest forward buffer, same as the engine's HLS path.
            item.preferredForwardBufferDuration = 4.0

            let player = AVPlayer(playerItem: item)
            vc.player = player
            vc.allowsPictureInPicturePlayback = false

            context.coordinator.attachObservers(to: item, player: player)

            player.play()
        } catch {
            onDismiss(.failure(error))
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.player?.replaceCurrentItem(with: nil)
        coordinator.deliverFinalDiagnostics()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        let onDismiss: (Result<SpikeDiagnostics, Error>) -> Void
        let delegateQueue = DispatchQueue(label: "de.superuser404.fmp4spike.delegate", qos: .userInteractive)
        var delegateRef: FMP4FileResourceLoaderDelegate?
        var player: AVPlayer?
        var statusObs: NSKeyValueObservation?
        var errLogObserver: NSObjectProtocol?
        var lastPlayerError: String?
        private var delivered = false

        init(onDismiss: @escaping (Result<SpikeDiagnostics, Error>) -> Void) {
            self.onDismiss = onDismiss
            super.init()
        }

        func attachObservers(to item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    let err = (item.error as NSError?)
                    let msg = err.map { "\($0.domain)/\($0.code) \($0.localizedDescription)" } ?? "failed (no error)"
                    Task { @MainActor in self?.lastPlayerError = msg }
                }
            }
            errLogObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.newErrorLogEntryNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let event = item.errorLog()?.events.last else { return }
                let comment = event.errorComment ?? "no comment"
                let msg = "code=\(event.errorStatusCode) domain=\(event.errorDomain) '\(comment)'"
                Task { @MainActor in self?.lastPlayerError = msg }
            }
        }

        func deliverFinalDiagnostics() {
            guard !delivered else { return }
            delivered = true
            statusObs?.invalidate()
            statusObs = nil
            if let obs = errLogObserver {
                NotificationCenter.default.removeObserver(obs)
                errLogObserver = nil
            }
            let delegate = delegateRef
            let diag = SpikeDiagnostics(
                outcome: lastPlayerError == nil ? "completed without AVPlayer failure" : "AVPlayer reported failure",
                requestCount: delegate?.requestCount ?? 0,
                bytesServed: delegate?.bytesServed ?? 0,
                contentInfoFulfilled: delegate?.contentInfoFulfilled ?? false,
                lastRequestAllData: delegate?.lastRequestAllData ?? false,
                lastError: delegate?.lastError?.localizedDescription,
                playerError: lastPlayerError
            )
            onDismiss(.success(diag))
        }
    }
}
