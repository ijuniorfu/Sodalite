#if os(tvOS)
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Hands the diagnostic log to a phone on the same network (Sodalite#148).
///
/// tvOS only. iOS has a Copy button and a keyboard behind it; an Apple TV has neither, and the reporter
/// who asked for this was photographing the screen and running OCR over roughly 300 lines per report.
///
/// The panel owns the server's lifetime: it starts on appear, stops on disappear, and the link dies with
/// the deadline whether or not anyone is looking. A log is a live document about someone's server, so an
/// export that outlives the screen it was started from would be a thing left switched on by accident.
struct LogExportPanel: View {
    /// The lines the reporter was looking at when they pressed the button. Frozen here rather than read
    /// inside the server, so the page and the screen show the same session.
    let lines: [String]
    let dismiss: () -> Void

    @State private var server = LogExportServer()
    @State private var endpoint: LogExportServer.Endpoint?
    @State private var failure: LogExportServer.StartError?
    @State private var hasExpired = false

    var body: some View {
        VStack(spacing: 28) {
            Text("settings.log.export.title", bundle: .main)
                .font(.title2)
                .fontWeight(.semibold)

            content

            LogActionButton(
                titleKey: "common.done",
                systemImage: "xmark",
                isEnabled: true,
                action: dismiss
            )
        }
        .padding(56)
        .frame(width: 900)
        .task { start() }
        .onDisappear { server.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let endpoint, !hasExpired {
            liveExport(endpoint)
        } else if hasExpired {
            message("settings.log.export.expired.title", detail: "settings.log.export.expired.message", isError: false)
            LogActionButton(
                titleKey: "home.retry",
                systemImage: "arrow.clockwise",
                isEnabled: true,
                action: start
            )
        } else if failure != nil {
            message("settings.log.export.failed.title", detail: "settings.log.export.failed.message", isError: true)
        } else {
            ProgressView()
                .frame(height: 360)
        }
    }

    private func liveExport(_ endpoint: LogExportServer.Endpoint) -> some View {
        VStack(spacing: 20) {
            qrCode(for: endpoint.url)

            // The address is spelled out under the code as well: a camera will not always focus on a
            // television, and the fallback has to be typeable rather than a second attempt at scanning.
            Text(endpoint.url.absoluteString)
                .font(.system(.title3, design: .monospaced))
                .textCase(.lowercase)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 8) {
                Text("settings.log.export.expires", bundle: .main)
                Text(timerInterval: Date() ... endpoint.expiresAt, countsDown: true)
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text("settings.log.export.hint", bundle: .main)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
        }
        // Not a timer on the view: the deadline is one instant, and a task that sleeps to it costs
        // nothing in between and cancels itself when the panel goes away.
        .task(id: endpoint.expiresAt) {
            let remaining = endpoint.expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { hasExpired = true; return }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            hasExpired = true
        }
    }

    /// Black on white with a quiet zone of its own, never on the panel material: the generator's
    /// background is not guaranteed opaque, and dark modules on dark material scan as nothing.
    @ViewBuilder
    private func qrCode(for url: URL) -> some View {
        if let image = Self.qrImage(for: url) {
            Image(uiImage: image)
                // Nearest neighbour: a QR module is a hard square, and smoothing its edges is what
                // makes a code fail to scan from across a room.
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 340, height: 340)
                .padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        } else {
            message("settings.log.export.failed.title", detail: "settings.log.export.failed.message", isError: true)
        }
    }

    private func message(
        _ titleKey: LocalizedStringKey,
        detail: LocalizedStringKey,
        isError: Bool
    ) -> some View {
        VStack(spacing: 12) {
            Text(titleKey)
                .font(.headline)
                .foregroundStyle(isError ? Color.Theme.destructive : .primary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
        }
        .frame(minHeight: 200)
    }

    private func start() {
        hasExpired = false
        failure = nil
        do {
            endpoint = try server.start(lines: lines)
        } catch let error as LogExportServer.StartError {
            endpoint = nil
            failure = error
            LogTap.shared.note("[LogExport] start failed: \(error)")
        } catch {
            endpoint = nil
            failure = .noNetwork
        }
    }

    private static func qrImage(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        // M corrects a quarter of the code. The next level up grows the module count, which on a
        // television means smaller squares for the same frame, and the code is read off a clean screen
        // rather than a creased label.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
