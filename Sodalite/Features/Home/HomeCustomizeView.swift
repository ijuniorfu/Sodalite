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
    /// rows exist, same as the enable/disable switches below it. App
    /// toggle convention: a ValuePickerRow whose value flips with
    /// left/right, like every other On/Off setting, NOT a tap-toggle.
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
    /// order; disabled rows sink below a thin divider, greyed. Each row is a
    /// single focusable control: left/right flips its On/Off membership (the
    /// app's toggle convention), while click picks it up to reorder, the
    /// primary task of this screen.
    private var rowList: some View {
        VStack(spacing: 6) {
            ForEach(Array(enabledRows.enumerated()), id: \.element.id) { index, config in
                CustomizeRow(
                    config: config,
                    isEnabled: true,
                    isMoving: movingID == config.id,
                    // Suppress the left/right toggle while any row is picked
                    // up, so a stray horizontal swipe during placement can't
                    // flip an unrelated row off.
                    suppressToggle: movingID != nil,
                    label: { rowLabel(config) },
                    onClick: { handleRowTap(config.id, at: index) },
                    onToggle: {
                        movingID = nil
                        toggle(id: config.id)
                    }
                )
                .padding(.horizontal, 50)
            }

            if !disabledRows.isEmpty {
                inactiveDivider
                ForEach(disabledRows) { config in
                    CustomizeRow(
                        config: config,
                        isEnabled: false,
                        isMoving: false,
                        suppressToggle: movingID != nil,
                        label: { rowLabel(config) },
                        // Disabled rows have no Home position to reorder, so
                        // both click and a right swipe just re-enable them.
                        onClick: { toggle(id: config.id) },
                        onToggle: { toggle(id: config.id) }
                    )
                    .padding(.horizontal, 50)
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

    // MARK: - Computed rows

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

// MARK: - Customize Row

/// A single Home-row entry in the customize list. One focus target with two
/// gestures, mirroring the app's ValuePickerRow feel: the Siri Remote's
/// left/right flips the row's On/Off membership, while a clickpad press is
/// reserved for reordering (pick up / drop), which is this screen's primary
/// task. Disabled rows can't be reordered, so for them the click re-enables
/// instead. The trailing chevron+label is the same switch affordance used by
/// every other On/Off setting; it is a visual cue, not a separate focus stop.
private struct CustomizeRow<Label: View>: View {
    let config: HomeRowConfig
    let isEnabled: Bool
    let isMoving: Bool
    let suppressToggle: Bool
    @ViewBuilder let label: () -> Label
    let onClick: () -> Void
    let onToggle: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: config.systemImage)
                .font(.title3)
                .frame(width: 44)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

            label()
                .font(.body)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            Spacer()

            if isMoving {
                Text("home.customize.moving")
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else {
                toggleSwitch
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(fillStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isMoving ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(Color.clear), lineWidth: 2)
        )
        .overlay(
            // Accent focus stroke, same 3pt treatment as the rest of the
            // app's focusable cards. When a row is both focused and picked
            // up, this fully opaque stroke dominates the thinner move ring.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            guard !suppressToggle else { return }
            switch direction {
            // left moves toward Off, right toward On; each is a no-op if the
            // row is already in that state, matching ValuePickerRow's clamp.
            case .left:  if isEnabled { onToggle() }
            case .right: if !isEnabled { onToggle() }
            default: break
            }
        }
        .stableTap(isFocused: focused) { onClick() }
    }

    @ViewBuilder
    private var toggleSwitch: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .font(.body)
                .foregroundStyle(focused ? .white : Color.secondary)
                .opacity(isEnabled ? 1 : 0.25)
            Text(isEnabled
                ? String(localized: "common.on", defaultValue: "On")
                : String(localized: "common.off", defaultValue: "Off"))
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(focused ? .white : Color.white.opacity(0.85))
                .frame(minWidth: 70, alignment: .center)
                .contentTransition(.opacity)
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(focused ? .white : Color.secondary)
                .opacity(isEnabled ? 0.25 : 1)
        }
    }

    private var fillStyle: AnyShapeStyle {
        if isMoving { return AnyShapeStyle(TintShapeStyle.tint.opacity(0.12)) }
        if focused { return AnyShapeStyle(Color.white.opacity(0.12)) }
        return AnyShapeStyle(isEnabled ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
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
