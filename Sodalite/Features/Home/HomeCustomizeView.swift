import SwiftUI

struct HomeCustomizeView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var configs: [HomeRowConfig] = []
    @State private var movingID: String?
    @State private var mergeCWNextUp = false
    @State private var rewatchNextUp = false

    private var serverID: String {
        appState.activeServer?.id ?? appState.activeUser?.id ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                mergeRowToggle
                rewatchRowToggle
                rowList
            }
            .padding(.vertical, 40)
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            configs = HomeRowConfig.loadFromStorage(serverID: serverID)
            mergeCWNextUp = HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID)
            rewatchNextUp = HomeRowConfig.enableRewatchingNextUp(serverID: serverID)
            // The per-library rows are otherwise only discovered when the
            // Home screen loads, so opening Customize right after adding or
            // switching a server showed a stale list until Home had run.
            // Reconcile here too so this screen populates on its own.
            Task { await reconcileLibraries() }
        }
    }

    /// Fetch the active server's libraries and fold any new per-library
    /// rows into the config, mirroring HomeViewModel. Additive: preserves
    /// the user's toggles and order, and only persists on a successful
    /// fetch so a transient failure can't wipe the dynamic rows.
    private func reconcileLibraries() async {
        guard let userID = appState.activeUser?.id,
              let libraries = try? await dependencies.jellyfinLibraryService.getLibraries(userID: userID)
        else { return }
        let reconciled = HomeRowConfig.reconciled(stored: configs, libraries: libraries)
        if reconciled != configs {
            configs = reconciled
            HomeRowConfig.saveToStorage(reconciled, serverID: serverID)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("home.customize.title")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(movingID != nil ? "home.customize.moveTip" : "home.customize.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            FocusableTile(action: {
                movingID = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    configs = HomeRowConfig.resetToDefault(current: configs)
                }
                save()
            }) { isFocused in
                Label("home.customize.resetDefaults", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.05))
                    )
            }
        }
        .padding(.horizontal, 50)
    }

    // MARK: - Merge toggle

    /// Plex-style combined row: folds Next Up into Continue Watching.
    /// Lives here rather than in Appearance because it changes which
    /// rows exist, same as the show/hide controls below it. App toggle
    /// convention: a ValuePickerRow whose value flips with left/right,
    /// like every other On/Off setting, NOT a tap-toggle.
    private var mergeRowToggle: some View {
        ValuePickerRow(
            icon: "arrow.triangle.merge",
            title: "home.customize.mergeCwNextUp",
            subtitle: "home.customize.mergeCwNextUp.subtitle",
            options: [false, true],
            selection: Binding(
                get: { mergeCWNextUp },
                set: { newValue in
                    movingID = nil
                    withAnimation(.easeInOut(duration: 0.25)) {
                        mergeCWNextUp = newValue
                    }
                    HomeRowConfig.setMergeContinueWatchingNextUp(newValue, serverID: serverID)
                    NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
                }
            ),
            label: { on in
                on
                    ? String(localized: "common.on", defaultValue: "On")
                    : String(localized: "common.off", defaultValue: "Off")
            }
        )
        .padding(.horizontal, 50)
    }

    // MARK: - Rewatching toggle

    /// Jellyfin's EnableRewatching for Next Up: keeps surfacing the next
    /// episode after the last one played once a series is fully watched, for
    /// rewatching. Same On/Off ValuePickerRow convention as the merge toggle
    /// above; per server, drives a Home reload via .homeConfigDidChange.
    private var rewatchRowToggle: some View {
        ValuePickerRow(
            icon: "arrow.clockwise",
            title: "home.customize.rewatchNextUp",
            subtitle: "home.customize.rewatchNextUp.subtitle",
            options: [false, true],
            selection: Binding(
                get: { rewatchNextUp },
                set: { newValue in
                    movingID = nil
                    rewatchNextUp = newValue
                    HomeRowConfig.setEnableRewatchingNextUp(newValue, serverID: serverID)
                    NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
                }
            ),
            label: { on in
                on
                    ? String(localized: "common.on", defaultValue: "On")
                    : String(localized: "common.off", defaultValue: "Off")
            }
        )
        .padding(.horizontal, 50)
    }

    // MARK: - Row list

    /// One unified, ordered list. Enabled rows sit on top in their Home
    /// order; disabled rows sink below a thin divider, greyed. Each row has
    /// two focus targets: the body (click reorders an enabled row, or
    /// re-enables a disabled one) and a trailing On/Off switch (click shows
    /// or hides the row). Splitting the two gestures across two elements
    /// keeps each one a plain clickpad press, which the Siri Remote delivers
    /// reliably; overloading one element with a directional toggle made the
    /// reorder click ambiguous with a directional press and swallowed it.
    private var rowList: some View {
        VStack(spacing: 6) {
            ForEach(Array(enabledRows.enumerated()), id: \.element.id) { index, config in
                enabledRow(config, at: index)
            }

            if !disabledRows.isEmpty {
                inactiveDivider
                ForEach(disabledRows) { config in
                    disabledRow(config)
                }
            }
        }
    }

    /// Thin separator with a small "Inactive" caption, replacing the old
    /// full-weight section header so the two groups read as one list.
    private var inactiveDivider: some View {
        HStack(spacing: 12) {
            Text("home.customize.inactive")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 1)
        }
        .padding(.horizontal, 50)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    // MARK: - Enabled row

    private func enabledRow(_ config: HomeRowConfig, at index: Int) -> some View {
        HStack(spacing: 16) {
            FocusableTile(
                isHighlighted: movingID == config.id,
                action: { handleRowTap(config.id, at: index) }
            ) { isFocused in
                rowBody(config, isFocused: isFocused, isEnabled: true)
            }

            RowToggleButton(isOn: true) {
                movingID = nil
                toggle(id: config.id)
            }
        }
        .padding(.horizontal, 50)
    }

    // MARK: - Disabled row

    /// Disabled rows have no Home position, so the body itself re-activates
    /// the row on click (a big, forgiving target), and the trailing switch
    /// shows "Off" and re-enables it too.
    private func disabledRow(_ config: HomeRowConfig) -> some View {
        HStack(spacing: 16) {
            FocusableTile(action: { toggle(id: config.id) }) { isFocused in
                rowBody(config, isFocused: isFocused, isEnabled: false)
            }

            RowToggleButton(isOn: false) {
                toggle(id: config.id)
            }
        }
        .padding(.horizontal, 50)
    }

    /// Shared left side of a row: icon, label and the "moving" indicator.
    @ViewBuilder
    private func rowBody(_ config: HomeRowConfig, isFocused: Bool, isEnabled: Bool) -> some View {
        HStack(spacing: 20) {
            Image(systemName: config.systemImage)
                .font(.title3)
                .frame(width: 44)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

            rowLabel(config)
                .font(.body)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            Spacer()

            if movingID == config.id {
                Text("home.customize.moving")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tileBackground(isFocused: isFocused, isMoving: movingID == config.id, isEnabled: isEnabled))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(movingID == config.id ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(Color.clear), lineWidth: 2)
        )
        .overlay(
            // Accent focus stroke, same 3pt treatment as the rest of the
            // app's focusable cards. When a row is both focused and picked
            // up, this fully opaque stroke dominates the thinner move ring.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
    }

    // MARK: - Helpers

    private func tileBackground(isFocused: Bool, isMoving: Bool, isEnabled: Bool) -> AnyShapeStyle {
        if isMoving { return AnyShapeStyle(TintShapeStyle.tint.opacity(0.12)) }
        if isFocused { return AnyShapeStyle(Color.white.opacity(0.12)) }
        return AnyShapeStyle(isEnabled ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
    }

    /// Up Next disappears from both lists while the merge toggle is
    /// on; its content rides inside Continue Watching then, and an
    /// orderable-but-inert row would just confuse.
    private var enabledRows: [HomeRowConfig] {
        configs
            .filter(\.isEnabled)
            .filter { !(mergeCWNextUp && $0.type == .nextUp) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var disabledRows: [HomeRowConfig] {
        configs.filter { !$0.isEnabled && !(mergeCWNextUp && $0.type == .nextUp) }
    }

    @ViewBuilder
    private func rowLabel(_ config: HomeRowConfig) -> some View {
        if config.type == .libraryLatest {
            Text(
                String(
                    format: String(localized: "home.libraryLatest.format", defaultValue: "Latest in %@"),
                    config.libraryName ?? ""
                )
            )
        } else {
            Text(config.type.localizedTitle)
        }
    }

    // MARK: - Actions

    private func handleRowTap(_ id: String, at index: Int) {
        if let moving = movingID {
            if moving != id {
                withAnimation(.easeInOut(duration: 0.25)) {
                    placeRow(id: moving, at: index)
                }
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                movingID = nil
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                movingID = id
            }
        }
    }

    private func placeRow(id: String, at targetIndex: Int) {
        var enabled = enabledRows
        guard let sourceIndex = enabled.firstIndex(where: { $0.id == id }) else { return }
        let item = enabled.remove(at: sourceIndex)
        enabled.insert(item, at: min(targetIndex, enabled.count))
        for (i, row) in enabled.enumerated() {
            if let ci = configs.firstIndex(where: { $0.id == row.id }) {
                configs[ci].sortOrder = i
            }
        }
        save()
    }

    private func toggle(id: String) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            configs[index].isEnabled.toggle()
            if configs[index].isEnabled {
                let maxOrder = configs.filter(\.isEnabled).map(\.sortOrder).max() ?? 0
                configs[index].sortOrder = maxOrder + 1
            }
        }
        save()
    }

    private func save() {
        HomeRowConfig.saveToStorage(configs, serverID: serverID)
        NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
    }
}

// MARK: - Focusable Tile (no default tvOS button chrome)

struct FocusableTile<Content: View>: View {
    var isHighlighted: Bool = false
    let action: () -> Void
    @ViewBuilder let content: (_ isFocused: Bool) -> Content

    @FocusState private var isFocused: Bool

    var body: some View {
        content(isFocused)
            .focusable()
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .stableTap(isFocused: isFocused) { action() }
    }
}

// MARK: - Row On/Off switch (show / hide a row on Home)

/// Trailing control that flips a row's membership in Home. Its own focus
/// target with a single gesture, the clickpad press, so it never competes
/// with the row body's reorder click. The chevron-free pill makes clear it
/// is a click button (add / remove), not a left/right ValuePickerRow; a
/// directional toggle here would trap focus against the body beside it.
struct RowToggleButton: View {
    let isOn: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isOn ? "eye.fill" : "eye.slash")
                .font(.body)
            Text(isOn
                ? String(localized: "common.on", defaultValue: "On")
                : String(localized: "common.off", defaultValue: "Off"))
                .font(.body)
                .fontWeight(.semibold)
                .contentTransition(.opacity)
        }
        .foregroundStyle(foreground)
        .frame(minWidth: 104)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(background)
        )
        .overlay(
            Capsule()
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .focusable()
        .focused($focused)
        .stableTap(isFocused: focused) { action() }
    }

    private var foreground: AnyShapeStyle {
        if isOn { return AnyShapeStyle(focused ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)) }
        return AnyShapeStyle(focused ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }

    private var background: AnyShapeStyle {
        if isOn { return AnyShapeStyle(TintShapeStyle.tint.opacity(focused ? 0.4 : 0.2)) }
        return AnyShapeStyle(Color.white.opacity(focused ? 0.18 : 0.06))
    }
}

// MARK: - Storage

extension HomeRowConfig {
    private static let legacyKey = "homeRowConfigs"
    private static func storageKey(serverID: String) -> String {
        "homeRowConfigs.\(serverID)"
    }

    static func loadFromStorage(serverID: String) -> [HomeRowConfig] {
        let key = storageKey(serverID: serverID)
        // Migrate a pre-multi-server install: if this server has no
        // scoped config yet but a legacy global one exists, adopt it.
        let data = UserDefaults.standard.data(forKey: key)
            ?? UserDefaults.standard.data(forKey: legacyKey)
        guard let data else {
            return HomeRowConfig.defaultConfig()
        }
        // Lossy decode: stored configs may reference retired row types.
        // A plain decode would fail the whole array on the first unknown
        // raw value and silently reset every customization; the
        // JSONSerialization detour skips dead entries and keeps the rest.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return HomeRowConfig.defaultConfig()
        }
        var result: [HomeRowConfig] = []
        for item in raw {
            guard let typeRaw = item["type"] as? String,
                  let type = HomeRowType(rawValue: typeRaw),
                  let isEnabled = item["isEnabled"] as? Bool,
                  let sortOrder = item["sortOrder"] as? Int
            else { continue }
            // libraryLatest rows require a libraryID; skip malformed ones.
            let libraryID = item["libraryID"] as? String
            if type == .libraryLatest, libraryID == nil { continue }
            result.append(
                HomeRowConfig(
                    type: type,
                    isEnabled: isEnabled,
                    sortOrder: sortOrder,
                    libraryID: libraryID,
                    libraryName: item["libraryName"] as? String,
                    collectionType: item["collectionType"] as? String
                )
            )
        }
        // Backfill newly-added static row types (never libraryLatest).
        for type in HomeRowType.allCases where type != .libraryLatest
            && !result.contains(where: { $0.type == type }) {
            result.append(HomeRowConfig(type: type, isEnabled: type.defaultEnabled, sortOrder: result.count))
        }
        return result
    }

    static func saveToStorage(_ configs: [HomeRowConfig], serverID: String) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(serverID: serverID))
    }

    // MARK: Merge Continue Watching + Up Next

    private static func mergeKey(serverID: String) -> String {
        "homeMergeCWNextUp.\(serverID)"
    }

    /// Plex-style combined row (Sodalite#15 request): when on, the
    /// Continue Watching row also carries the Next Up episodes
    /// (resume items first) and the separate Up Next row is dropped
    /// from Home and hidden in the customize list. Per server, like
    /// the row configs themselves; default off.
    static func mergeContinueWatchingNextUp(serverID: String) -> Bool {
        UserDefaults.standard.bool(forKey: mergeKey(serverID: serverID))
    }

    static func setMergeContinueWatchingNextUp(_ value: Bool, serverID: String) {
        UserDefaults.standard.set(value, forKey: mergeKey(serverID: serverID))
    }

    // MARK: Enable Rewatching in Next Up

    private static func rewatchingKey(serverID: String) -> String {
        "homeRewatchNextUp.\(serverID)"
    }

    /// Jellyfin's EnableRewatching for /Shows/NextUp (Sodalite#19): when
    /// on, Next Up keeps surfacing the episode after the last one played
    /// even once a series is fully watched, for rewatching. Applies to the
    /// Home Next Up row only (standalone row + the merged Continue Watching
    /// path). Per server, like the row configs themselves; default off.
    static func enableRewatchingNextUp(serverID: String) -> Bool {
        UserDefaults.standard.bool(forKey: rewatchingKey(serverID: serverID))
    }

    static func setEnableRewatchingNextUp(_ value: Bool, serverID: String) {
        UserDefaults.standard.set(value, forKey: rewatchingKey(serverID: serverID))
    }
}
