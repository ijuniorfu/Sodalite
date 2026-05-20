import SwiftUI
import AVKit
import UIKit

/// Diagnostic-only "QuickPlay" — one-tap launcher for the
/// long-form 4K HDR HEVC leak-isolation comparison. The play
/// button hands `defaultURL` (the dev-LAN Mac http server URL)
/// straight to `DiagnosticDirectURLPlayerVC`, which bypasses the
/// entire AetherEngine pipeline (no Demuxer / producer / cache /
/// loopback HTTP) and plays through a stock
/// `AVPlayerViewController`.
///
/// If RSS stays flat here while the engine path's `[AetherEngine]
/// memprobe` lines show their usual ~2 MB/s climb on the same
/// source, the leak is in our pipeline (mp4 muxer / FLAC bridge /
/// HLS local server). If RSS climbs at the same rate on both
/// routes, the leak is downstream (AVPlayer's HLS demuxer or its
/// decode pipeline), and engine-side fixes can't help.
///
/// Why no TextField: tvOS SwiftUI's TextField re-builds on parent
/// state changes and closes the system keyboard after the first
/// keypress on this layout (confirmed empirically). Until that's
/// solved, a fixed-URL launcher is the lowest-friction path.
/// `defaultURL` lives at the top of the file as a single constant
/// for easy LAN re-pointing across diagnostic runs.
struct QuickPlayView: View {

    /// Mac http server URL for the Part 2 isolation run. Repoint
    /// when the LAN address or port changes; rebuild the app.
    private static let defaultURL = "http://10.20.30.32:8090/media.m3u8"

    @State private var presentingPlayer: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                urlReadout

                playButton

                hints
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("QuickPlay")
        .background(
            QuickPlayPresenter(
                isPresented: $presentingPlayer,
                urlString: Self.defaultURL
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic-only. Bypasses AetherEngine and hands the URL straight to AVPlayer.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("The play button below uses the dev-LAN Mac http server. Edit `defaultURL` in QuickPlayView.swift to repoint.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    private var urlReadout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(Self.defaultURL)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var playButton: some View {
        Button {
            presentingPlayer = true
        } label: {
            Label("Play", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hold MENU on the remote to dismiss the player.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text("Console logs prefixed `[Diag] memprobe` carry physFP / vmInt every 30 s, matching the engine path's memprobe schema for direct comparison.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

/// SwiftUI bridge that presents `DiagnosticDirectURLPlayerVC` as a
/// fullscreen UIKit modal. The PlayerLauncher pattern is reused
/// here because tvOS SwiftUI fullScreenCover doesn't reliably
/// route the MENU button to the presented VC, and our diagnostic
/// VC needs the menu-press handler to dismiss cleanly.
struct QuickPlayPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let urlString: String

    func makeUIViewController(context: Context) -> QuickPlayPresenterHostVC {
        QuickPlayPresenterHostVC()
    }

    func updateUIViewController(_ host: QuickPlayPresenterHostVC, context: Context) {
        if isPresented, let url = URL(string: urlString), host.presentedViewController == nil {
            let vc = DiagnosticDirectURLPlayerVC(url: url, onDismiss: {
                host.dismiss(animated: false) {
                    isPresented = false
                }
            })
            vc.modalPresentationStyle = .fullScreen
            host.present(vc, animated: false)
        } else if !isPresented, host.presentedViewController != nil {
            host.dismiss(animated: false)
        }
    }
}

final class QuickPlayPresenterHostVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}
