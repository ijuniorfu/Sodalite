import AVFoundation
import Foundation

/// Stage 1 spike delegate. Serves byte-ranges from a local file
/// directly to AVPlayer via `AVAssetResourceLoadingDataRequest.respond(with:)`,
/// bypassing any HTTP / CFNetwork path. The goal is to prove (or
/// disprove) that AVPlayer's non-HLS MP4 reader accepts delegate-served
/// bytes for a fragmented MP4 asset accessed via a custom URL scheme.
///
/// If this works on tvOS 26 with HEVC + EAC3-JOC, the libnetwork
/// buffer-pool retention that drives the long-form playback OOM is
/// avoidable by routing all asset bytes through the delegate instead
/// of through our localhost HTTP server.
///
/// Caveats baked into this implementation:
///   - URL MUST carry the `.mp4` extension. Without it AVPlayer
///     silently rejects the asset (forum 129155).
///   - Asset MUST be a top-level non-HLS resource. The "delegate
///     cannot serve segments" rule from forum 113063 is scoped to
///     HLS playlist-driven segment fetches through FigHTTPStreamReader,
///     not to this code path. Whether AVPlayer's non-HLS MP4 reader
///     additionally rejects fragmented (mvex) layouts is exactly what
///     this spike measures (one negative data point in forum 735572,
///     no documented positive precedent).
final class FMP4FileResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    // MARK: - Inputs

    private let fileURL: URL
    private let fileSize: Int64

    // MARK: - State

    /// Serial queue for serve work. Each loading request gets routed
    /// here, so file-handle seek + read is naturally serialized.
    private let serveQueue: DispatchQueue
    private var fileHandle: FileHandle?

    // MARK: - Diagnostics

    /// Total bytes ever delivered via `respond(with:)`. Climbs as
    /// AVPlayer reads forward; if the foundation works without leaking
    /// the libnetwork pool, vmInt should grow proportionally to a
    /// modest decoder/parser footprint and NOT track this counter
    /// (because the bytes are not held in a network buffer pool).
    private(set) var bytesServed: Int = 0

    /// Count of loading-request invocations. Useful to see whether
    /// AVPlayer falls back to a single all-data request or issues
    /// proper byte-range requests.
    private(set) var requestCount: Int = 0

    /// Last error encountered serving a request.
    private(set) var lastError: NSError?

    /// Set to true once the first content-information request has been
    /// satisfied. Useful for the spike UI to confirm the asset's
    /// length probe reached the delegate.
    private(set) var contentInfoFulfilled: Bool = false

    /// `requestsAllDataToEndOfResource` flag observed on the latest
    /// data request. Forum 735572 reports this can override
    /// `isByteRangeAccessSupported`, so we surface it for diagnostics.
    private(set) var lastRequestAllData: Bool = false

    // MARK: - Init

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attrs[.size] as? NSNumber else {
            throw NSError(domain: "FMP4Spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no file size"])
        }
        self.fileSize = size.int64Value
        self.fileHandle = try FileHandle(forReadingFrom: fileURL)
        self.serveQueue = DispatchQueue(label: "de.superuser404.fmp4spike.serve", qos: .userInteractive)
        super.init()
    }

    deinit {
        try? fileHandle?.close()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        requestCount += 1
        serveQueue.async { [weak self] in
            self?.handle(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Cancellation is observed via `req.isCancelled` inside the
        // serve loop, nothing extra to do here.
    }

    // MARK: - Internal

    private func handle(_ req: AVAssetResourceLoadingRequest) {
        // 1. Satisfy contentInformationRequest (first request from
        //    AVPlayer's MP4 reader always probes length + UTI before
        //    issuing data requests).
        if let info = req.contentInformationRequest {
            info.contentType = AVFileType.mp4.rawValue
            info.contentLength = fileSize
            info.isByteRangeAccessSupported = true
            contentInfoFulfilled = true
        }

        guard let dr = req.dataRequest, let fh = fileHandle else {
            req.finishLoading()
            return
        }

        lastRequestAllData = dr.requestsAllDataToEndOfResource

        let start = dr.requestedOffset
        // requestsAllDataToEndOfResource = true ⇒ ignore requestedLength,
        // serve everything from `start` to EOF (Apple docs).
        let toServeTotal: Int64
        if dr.requestsAllDataToEndOfResource {
            toServeTotal = max(0, fileSize - start)
        } else {
            toServeTotal = min(Int64(dr.requestedLength), fileSize - start)
        }

        guard start >= 0, start < fileSize, toServeTotal > 0 else {
            req.finishLoading()
            return
        }

        do {
            try fh.seek(toOffset: UInt64(start))

            // Chunked read so cancellation lands quickly and the
            // initial "give-me-everything" first request doesn't block
            // the queue for too long. Tuned modest; the muxer's later
            // live path will need similar back-pressure.
            let chunkSize: Int = 256 * 1024
            var sent: Int64 = 0
            while sent < toServeTotal {
                if req.isCancelled { return }
                let remaining = toServeTotal - sent
                let thisChunk = Int(min(Int64(chunkSize), remaining))
                let data = fh.readData(ofLength: thisChunk)
                if data.isEmpty {
                    // EOF before expected size. Finish what we've sent.
                    break
                }
                dr.respond(with: data)
                bytesServed += data.count
                sent += Int64(data.count)
            }
            req.finishLoading()
        } catch {
            lastError = error as NSError
            req.finishLoading(with: error)
        }
    }
}
