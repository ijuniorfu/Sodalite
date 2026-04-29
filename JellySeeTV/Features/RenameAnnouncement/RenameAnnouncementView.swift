import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Last-mile bridge for the JellySeeTV → Sodalite rename. Fires on
/// every launch of this final farewell build — there's no opt-out.
/// The close button (and Menu) only dismiss for the current session;
/// the modal comes back on every relaunch. JellySeeTV is dead, the
/// migration window is short, and a per-session reminder is the
/// gentlest nudge that still actually moves people across.
///
/// On Apple TV the user can't navigate a `https://testflight…` URL
/// from a button (no browser, no UIApplication.open path that lands
/// reliably on the TestFlight join flow), so the migration path is
/// QR-code first: the URL is rendered as a QR the user scans with
/// their iPhone / iPad. They tap "Join the Beta" in TestFlight on
/// that device, install Sodalite via TestFlight on Apple TV, and
/// open it once. KeychainMigrator on the Sodalite side picks the
/// session up from the shared keychain access groups.
struct RenameAnnouncementView: View {
    let onClose: () -> Void

    @FocusState private var closeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                stepsList
                qrSection
                closeButton
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96).ignoresSafeArea())
        .onAppear {
            DispatchQueue.main.async {
                closeFocused = true
            }
        }
        // Menu button: same as the close CTA. The modal returns on
        // the next launch regardless — there is no permanent dismiss.
        .onExitCommand { onClose() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Text(String(
                localized: "rename.modal.kicker",
                defaultValue: "Wichtige Ankündigung"
            ))
            .font(.headline)
            .foregroundStyle(.tint)
            .textCase(.uppercase)
            .tracking(2)

            // Brand transition is fixed across languages — same
            // pattern as the WhatsNewView title.
            Text("JellySeeTV → Sodalite")
                .font(.system(size: 56, weight: .bold))
                .multilineTextAlignment(.center)

            Text(String(
                localized: "rename.modal.subtitle",
                defaultValue: "Gleicher Code, gleiche Features, neuer Name. Wechsle jetzt rüber — dein Login und deine Bibliothek kommen mit."
            ))
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 760)
        }
        .padding(.top, 80)
        .padding(.bottom, 50)
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepRow(
                number: 1,
                text: String(
                    localized: "rename.modal.step1",
                    defaultValue: "QR-Code unten mit deinem iPhone scannen und in TestFlight auf 'Beitreten' tippen."
                )
            )
            stepRow(
                number: 2,
                text: String(
                    localized: "rename.modal.step2",
                    defaultValue: "Sodalite auf deinem Apple TV über TestFlight installieren."
                )
            )
            stepRow(
                number: 3,
                text: String(
                    localized: "rename.modal.step3",
                    defaultValue: "Sodalite einmal öffnen — dein Login wird automatisch übernommen. Erst danach JellySeeTV löschen."
                )
            )
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 80)
        .padding(.bottom, 40)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.18))
                Text("\(number)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.tint)
            }
            .frame(width: 56, height: 56)

            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Each row is focusable so the tvOS focus engine can step
        // through them and scroll the modal as it goes — same
        // pattern that fixed the WhatsNewView scroll. Without this
        // the user is stuck on the migrated button and the QR
        // section below it is unreachable.
        .focusable()
    }

    private var qrSection: some View {
        VStack(spacing: 16) {
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .padding(20)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Text(Self.testFlightURL.absoluteString)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 40)
        // Focusable so the user can pause on the QR / URL while
        // scanning it without the focus engine snapping past.
        .focusable()
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Text(String(
                localized: "rename.modal.close",
                defaultValue: "Schließen"
            ))
            .font(.body)
            .fontWeight(.semibold)
            .padding(.horizontal, 56)
            .padding(.vertical, 16)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .focused($closeFocused)
        .padding(.top, 20)
        .padding(.bottom, 80)
    }

    // MARK: - QR

    /// Sodalite TestFlight join URL — public external testing group
    /// generated 2026-04-28 from App Store Connect.
    private static let testFlightURL = URL(string: "https://testflight.apple.com/join/nWeQzmBX")!

    private var qrImage: UIImage? {
        Self.makeQR(from: Self.testFlightURL.absoluteString)
    }

    private static func makeQR(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up so the rendered QR is crisp at our 280pt frame.
        let scale = CGAffineTransform(scaleX: 12, y: 12)
        let scaled = output.transformed(by: scale)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
