#if os(tvOS) && DEBUG
import AVKit
import CoreMedia
import CoreVideo
import UIKit

/// DIAG (SW-PiP verification): engine-free minimal sample-buffer PiP probe. Own window, bare
/// AVSampleBufferDisplayLayer with its own control timebase (Apple's canonical setup), synthetic
/// 30 fps frames, a ContentSource controller, and delegate/possible logging. Auto-runs once a few
/// seconds after launch; results land in LogTap/console. Proves whether tvOS 26 ever evaluates a
/// sample-buffer ContentSource at all, independent of the player stack.
@MainActor
final class SwPiPProbe: NSObject {
    static let shared = SwPiPProbe()

    private var window: UIWindow?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var frameTimer: Timer?
    private var frameIndex = 0
    private var formatDescription: CMVideoFormatDescription?

    static func autoRun(afterSeconds: Double = 5) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(afterSeconds))
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                LogTap.shared.note("[PiPProbe] no active scene")
                return
            }
            shared.run(in: scene)
        }
    }

    private func run(in scene: UIWindowScene) {
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 40, y: 40, width: 480, height: 270)
        w.windowLevel = .alert + 1
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        w.rootViewController = vc
        w.isHidden = false

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = vc.view.bounds
        layer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            layer.controlTimebase = timebase
        }
        vc.view.layer.addSublayer(layer)
        displayLayer = layer
        window = w

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new, .initial]) { pip, _ in
            LogTap.shared.note("[PiPProbe] possible=\(pip.isPictureInPicturePossible)")
        }
        LogTap.shared.note("[PiPProbe] started supported=\(AVPictureInPictureController.isPictureInPictureSupported())")

        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enqueueFrame() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self else { return }
            let final = self.controller?.isPictureInPicturePossible ?? false
            LogTap.shared.note("[PiPProbe] FINAL possible=\(final) frames=\(self.frameIndex)")
            self.tearDown()
        }
    }

    private func enqueueFrame() {
        guard let layer = displayLayer else { return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.isReadyForMoreMediaData else { return }
        guard let sample = makeSampleBuffer() else { return }
        renderer.enqueue(sample)
        frameIndex += 1
        if frameIndex == 1 || frameIndex == 60 {
            LogTap.shared.note("[PiPProbe] frame #\(frameIndex) enqueued status=\(renderer.status.rawValue) error=\(renderer.error.map { String(describing: $0) } ?? "nil")")
        }
    }

    private func makeSampleBuffer() -> CMSampleBuffer? {
        let width = 480
        let height = 270
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let value = UInt8((frameIndex * 4) % 255)
            memset(base, Int32(value), CVPixelBufferGetDataSize(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &formatDescription)
        }
        guard let format = formatDescription else { return nil }
        let now = displayLayer?.controlTimebase.map { CMTimebaseGetTime($0) } ?? .zero
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    private func tearDown() {
        frameTimer?.invalidate()
        frameTimer = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller = nil
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        window?.isHidden = true
        window = nil
        LogTap.shared.note("[PiPProbe] torn down")
    }
}

extension SwPiPProbe: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        LogTap.shared.note("[PiPProbe] delegate setPlaying=\(playing)")
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        LogTap.shared.note("[PiPProbe] delegate timeRange")
        return CMTimeRange(start: .zero, duration: CMTime(seconds: 600, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        LogTap.shared.note("[PiPProbe] delegate isPaused")
        return false
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
#endif
