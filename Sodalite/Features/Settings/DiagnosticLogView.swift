import SwiftUI

/// Settings > "Diagnostic Log": the lines `LogTap` collected this session.
///
/// Deliberately not gated by `LogTap.isDiagnosticBuild`, unlike the in-player overlay. It is
/// read-only, and until it existed the only way to see a host line like `[CloudSync] …` was a
/// console capture from a Mac, which put every log-based question out of reach for the people
/// actually hitting the bug. Sodalite#45 was diagnosed twice without it.
struct DiagnosticLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @ObservedObject private var tap = LogTap.shared

    /// Identity for ForEach and for the scroll-to-bottom anchor. The buffer is a ring of plain
    /// strings, and duplicate lines are normal in a log, so the index has to carry the identity.
    private struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private var lines: [Line] {
        tap.lines.enumerated().map { Line(id: $0.offset, text: $0.element) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if lines.isEmpty {
                        Text("settings.log.empty", bundle: .main)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(lines) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelectionCompat()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, hSizeClass == .compact ? 16 : 80)
                .padding(.bottom, 60)
            }
            // A log is read from its end. Landing at the top would mean scrolling past a full
            // session to reach the line that prompted the visit.
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: tap.lines.count) { _, _ in scrollToEnd(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hidesNavigationBarChrome()
        .onExitCommandCompat { dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.log.title", bundle: .main)
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)

            Text("settings.log.hint", bundle: .main)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            actions
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 60)
        .padding(.bottom, 24)
    }

    private var actions: some View {
        HStack(spacing: 16) {
            #if os(iOS)
            Button {
                UIPasteboard.general.string = tap.lines.joined(separator: "\n")
            } label: {
                Label("settings.log.copy", systemImage: "doc.on.doc")
            }
            .disabled(tap.lines.isEmpty)
            #endif

            Button {
                tap.clear()
            } label: {
                Label("settings.log.clear", systemImage: "trash")
            }
            .disabled(tap.lines.isEmpty)
        }
        .font(.callout)
        .buttonStyle(.bordered)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = lines.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }
}

private extension View {
    /// tvOS has no text selection, and the modifier is unavailable there rather than a no-op.
    @ViewBuilder
    func textSelectionCompat() -> some View {
        #if os(iOS)
        self.textSelection(.enabled)
        #else
        self
        #endif
    }
}
