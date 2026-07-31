import SwiftUI

/// One buffered line. The buffer is a ring of plain strings and duplicate lines are normal in a
/// log, so the index has to carry the identity.
private struct LogLine: Identifiable {
    let id: Int
    let text: String
}

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

    /// tvOS groups the lines into focusable blocks (see LogBlock). 12 keeps a block roughly one
    /// screenful, so one swipe of the remote is one page.
    private static let blockSize = 12

    private var lines: [LogLine] {
        tap.lines.enumerated().map { LogLine(id: $0.offset, text: $0.element) }
    }

    private var blocks: [[LogLine]] {
        stride(from: 0, to: lines.count, by: Self.blockSize).map {
            Array(lines[$0 ..< min($0 + Self.blockSize, lines.count)])
        }
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
                        content
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

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(blocks, id: \.first?.id) { block in
                LogBlock(lines: block)
                    .id(block.last?.id)
            }
        }
        #else
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(line.id)
            }
        }
        #endif
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
            LogActionButton(
                titleKey: "settings.log.copy",
                systemImage: "doc.on.doc",
                isEnabled: !tap.lines.isEmpty
            ) {
                UIPasteboard.general.string = tap.lines.joined(separator: "\n")
            }
            #endif

            LogActionButton(
                titleKey: "settings.log.clear",
                systemImage: "trash",
                isEnabled: !tap.lines.isEmpty
            ) {
                tap.clear()
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = lines.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }
}

/// Compact action chip. Not a `Button` with a system style: on tvOS `.bordered` draws a filled
/// pill in the accent colour whether or not it holds focus, which reads as permanently focused and
/// swallows its own label. Mirrors `SettingsTileButtonStyle`'s fills and tinted focus border
/// instead, so it looks like the rest of Settings on both platforms.
private struct LogActionButton: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Label(titleKey, systemImage: systemImage)
            .font(.callout)
            .fontWeight(.medium)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(isFocused ? 0.15 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .opacity(isEnabled ? 1 : 0.4)
            .focusable(isEnabled)
            .focused($isFocused)
            .stableTap(isFocused: isFocused) {
                guard isEnabled else { return }
                action()
            }
    }
}

#if os(tvOS)
/// A tvOS scroll view only scrolls when the focus engine has somewhere to move, and a `Text` is
/// not focusable: with only Copy and Clear focusable, the log stood still. Blocks rather than
/// single lines because 300 focusable rows would mean 300 swipes to reach the end of the buffer,
/// while a block is one page per swipe.
private struct LogBlock: View {
    let lines: [LogLine]
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isFocused ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
        .focusable(true)
        .focused($isFocused)
    }
}
#endif
