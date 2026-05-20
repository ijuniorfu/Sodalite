import SwiftUI
import AVKit
import UIKit

/// Diagnostic-only "QuickPlay" — enter any media URL (HLS playlist
/// or direct file), hit Play, and the URL is handed straight to a
/// stock `AVPlayerViewController` (`DiagnosticDirectURLPlayerVC`)
/// that bypasses the entire AetherEngine pipeline. Used to A/B test
/// memory behaviour: if RSS stays flat on this route while it
/// climbs on the AetherEngine path for the same source, the leak
/// is in the engine. If both routes climb, the leak is downstream
/// (AVPlayer's HLS demuxer or its decode pipeline).
///
/// Last entered URL persists in UserDefaults so re-runs don't make
/// you re-paste — `QuickPlay.lastURL`.
struct QuickPlayView: View {

    private static let lastURLKey = "QuickPlay.lastURL"

    @State private var urlString: String = UserDefaults.standard.string(forKey: Self.lastURLKey) ?? ""
    @State private var presentingPlayer: Bool = false
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                urlField

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
                urlString: urlString
            )
        )
        .onAppear { urlFieldFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic-only. Bypasses AetherEngine and hands the URL straight to AVPlayer.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("HLS playlist (.m3u8) or any URL AVPlayer can open directly.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("https://10.20.30.x:8090/playlist.m3u8", text: $urlString)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($urlFieldFocused)
        }
    }

    private var playButton: some View {
        Button {
            UserDefaults.standard.set(urlString, forKey: Self.lastURLKey)
            presentingPlayer = true
        } label: {
            Label("Play", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .disabled(URL(string: urlString) == nil || urlString.isEmpty)
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hold MENU on the remote to dismiss the player.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text("Console logs prefixed [Diag] memprobe carry RSS / vmInt every 30 s, matching the engine path's memprobe schema for direct comparison.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

/// SwiftUI bridge that presents `DiagnosticDirectURLPlayerVC` as a
/// fullscreen UIKit modal. The PlayerLauncher pattern is reused here
/// because tvOS SwiftUI fullScreenCover doesn't reliably route the
/// MENU button to the presented VC, and our diagnostic VC needs the
/// menu-press handler to dismiss cleanly.
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
