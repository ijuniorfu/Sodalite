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

    /// Sensible default for the long-form 4K HDR leak-isolation
    /// test: the Mac http server hosting `/tmp/drhurt-test1/` on the
    /// development LAN. UserDefaults overrides this when the user
    /// edits the field, so a different LAN setup just needs to be
    /// typed once and it sticks.
    private static let defaultURL = "http://10.20.30.32:8090/media.m3u8"

    @State private var urlString: String = UserDefaults.standard.string(forKey: Self.lastURLKey) ?? Self.defaultURL
    @State private var presentingPlayer: Bool = false

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

    /// tvOS TextField quirks:
    /// * `@FocusState` + `.onAppear` programmatic focus triggers a
    ///   re-render every time the system keyboard reports a key
    ///   press back, which destroys the field state and the
    ///   keyboard closes after the first character. Don't do it.
    /// * `.keyboardType(.URL)` is iOS-only; calling it on tvOS is a
    ///   no-op but the modifier chain still compiles. Drop it to
    ///   keep the chain tidy.
    /// * `.textInputAutocapitalization(.never)` is iOS-only; gate
    ///   with `#if os(iOS)`.
    /// * Just let the user tap the field. The matching tvOS system
    ///   keyboard opens, they enter, hit Done. Mirrors `LoginView`
    ///   which has the same shape and works.
    private var urlField: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("http://10.20.30.x:8090/playlist.m3u8", text: $urlString)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
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
