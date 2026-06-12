import UIKit
import SwiftUI
import Observation

/// Hosts the EPG as a hard split: a non-focusable channel column on the left,
/// a focusable program grid on the right, and a time header on top, each
/// clipped to its own region. The grid is the scroll source of truth; the
/// column's vertical offset and the header's horizontal offset are synced to
/// it in `scrollViewDidScroll` (cheap UIKit, no SwiftUI re-render). Because
/// the grid never overlaps the column, programs cannot scroll behind the
/// channels and focus cannot land under the column.
@MainActor
final class EPGCollectionViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegate, EPGCollectionLayoutDelegate {

    private struct Row {
        let channel: JellyfinChannel
        let programs: [JellyfinProgram]
    }

    private let model: EPGGuideViewModel
    var tintColor: UIColor
    private let onSelect: (JellyfinChannel, JellyfinProgram) -> Void
    private let logoURLProvider: (JellyfinChannel) -> URL?

    private let columnWidth = EPGGuideViewModel.channelColumnWidth
    private let rowHeight = EPGGuideViewModel.rowHeight
    private let headerHeight: CGFloat = 60

    private let gridLayout = EPGCollectionLayout()
    private var gridView: UICollectionView!
    private var columnView: UICollectionView!
    private let timeHeaderScroll = UIScrollView()
    private let timeHeaderContent = EPGTimeHeaderContentView()
    private let cornerView = UIView()
    private var rows: [Row] = []
    /// Advances the now line (and current-program highlight) as wall-clock
    /// time passes, so the guide stays accurate without a reload.
    private var nowLineTimer: Timer?
    /// One-shot: scroll the grid so "now" is near the left edge on first layout.
    private var didInitialScroll = false

    init(model: EPGGuideViewModel, tintColor: UIColor,
         logoURLProvider: @escaping (JellyfinChannel) -> URL?,
         onSelect: @escaping (JellyfinChannel, JellyfinProgram) -> Void) {
        self.model = model
        self.tintColor = tintColor
        self.logoURLProvider = logoURLProvider
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Program grid (right).
        gridLayout.delegate = self
        gridLayout.rowHeight = rowHeight
        gridLayout.totalWidth = model.totalWidth
        gridLayout.nowX = max(0, model.xOffset(for: Date()))
        gridLayout.gridlineXs = model.timeTicks.map { model.xOffset(for: $0) }
        gridLayout.register(EPGNowLineView.self, forDecorationViewOfKind: EPGCollectionLayout.nowLineKind)
        gridLayout.register(EPGGridLineView.self, forDecorationViewOfKind: EPGCollectionLayout.gridLineKind)
        gridView = UICollectionView(frame: .zero, collectionViewLayout: gridLayout)
        gridView.backgroundColor = .clear
        gridView.clipsToBounds = true
        gridView.dataSource = self
        gridView.delegate = self
        gridView.remembersLastFocusedIndexPath = true
        gridView.contentInsetAdjustmentBehavior = .never
        gridView.register(EPGProgramCollectionCell.self,
                          forCellWithReuseIdentifier: EPGProgramCollectionCell.reuseID)
        view.addSubview(gridView)

        // Channel column (left), passive, scroll synced to the grid.
        let columnLayout = UICollectionViewFlowLayout()
        columnLayout.scrollDirection = .vertical
        columnLayout.minimumLineSpacing = 0
        columnLayout.minimumInteritemSpacing = 0
        columnLayout.itemSize = CGSize(width: columnWidth, height: rowHeight)
        columnView = UICollectionView(frame: .zero, collectionViewLayout: columnLayout)
        columnView.backgroundColor = epgPinnedBackground
        columnView.clipsToBounds = true
        columnView.isScrollEnabled = false
        columnView.contentInsetAdjustmentBehavior = .never
        columnView.dataSource = self
        columnView.register(EPGChannelCell.self, forCellWithReuseIdentifier: EPGChannelCell.reuseID)
        view.addSubview(columnView)

        // Time header (top), passive, scroll synced to the grid.
        timeHeaderScroll.backgroundColor = epgPinnedBackground
        timeHeaderScroll.clipsToBounds = true
        timeHeaderScroll.isScrollEnabled = false
        timeHeaderScroll.isUserInteractionEnabled = false
        timeHeaderScroll.contentInsetAdjustmentBehavior = .never
        timeHeaderScroll.addSubview(timeHeaderContent)
        view.addSubview(timeHeaderScroll)

        // Corner (top-left).
        cornerView.backgroundColor = epgPinnedBackground
        view.addSubview(cornerView)

        rebuildRows()
        gridView.reloadData()
        columnView.reloadData()
        timeHeaderContent.configure(ticks: timeTicks())
        startObserving()
        observeFavorites()
        observeTimerState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshNow()
        startNowLineTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        nowLineTimer?.invalidate()
        nowLineTimer = nil
    }

    // MARK: - Now line + current-program highlight

    /// Tick once a minute (6 pt/min scale, so one minute is the smallest
    /// visible move). Recompute the now line's x, nudge the layout, and
    /// refresh the visible cells so the live-program highlight tracks.
    private func startNowLineTimer() {
        nowLineTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        // .common so it keeps firing while the user scrolls the grid.
        RunLoop.main.add(timer, forMode: .common)
        nowLineTimer = timer
    }

    private func refreshNow() {
        gridLayout.nowX = max(0, model.xOffset(for: Date()))
        let ctx = UICollectionViewLayoutInvalidationContext()
        ctx.invalidateDecorationElements(
            ofKind: EPGCollectionLayout.nowLineKind, at: [IndexPath(item: 0, section: 0)])
        gridLayout.invalidateLayout(with: ctx)
        // Refresh visible cells so the "on now" border follows the clock as
        // programs end and the next one starts.
        for indexPath in gridView.indexPathsForVisibleItems {
            guard let cell = gridView.cellForItem(at: indexPath) as? EPGProgramCollectionCell else { continue }
            // Same bounds guards as refreshTimerDots/refreshFavoriteStars:
            // visible index paths can briefly outlive a model mutation.
            guard indexPath.section < rows.count else { continue }
            let row = rows[indexPath.section]
            guard indexPath.item < row.programs.count else { continue }
            cell.setOnNow(isProgramOnNow(row.programs[indexPath.item]))
        }
    }

    private func isProgramOnNow(_ program: JellyfinProgram) -> Bool {
        guard let start = program.startDate, let end = program.endDate else { return false }
        let now = Date()
        return start <= now && now < end
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width, h = view.bounds.height
        cornerView.frame = CGRect(x: 0, y: 0, width: columnWidth, height: headerHeight)
        timeHeaderScroll.frame = CGRect(x: columnWidth, y: 0, width: w - columnWidth, height: headerHeight)
        timeHeaderScroll.contentSize = CGSize(width: model.totalWidth, height: headerHeight)
        timeHeaderContent.frame = CGRect(x: 0, y: 0, width: model.totalWidth, height: headerHeight)
        columnView.frame = CGRect(x: 0, y: headerHeight, width: columnWidth, height: h - headerHeight)
        gridView.frame = CGRect(x: columnWidth, y: headerHeight, width: w - columnWidth, height: h - headerHeight)

        // One-shot: open with "now" near the left edge, leaving a little
        // context to its left so the just-ended part of the current program
        // is visible. Clamped to the scrollable range.
        if !didInitialScroll, gridView.bounds.width > 0, model.totalWidth > 0 {
            didInitialScroll = true
            let leading = gridView.bounds.width * 0.08
            let maxOffset = max(0, model.totalWidth - gridView.bounds.width)
            let target = min(max(0, gridLayout.nowX - leading), maxOffset)
            gridView.contentOffset.x = target
            timeHeaderScroll.contentOffset.x = target
        }
    }

    // MARK: - Scroll sync (grid drives column + header)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === gridView else { return }
        columnView.contentOffset.y = gridView.contentOffset.y
        timeHeaderScroll.contentOffset.x = gridView.contentOffset.x
    }

    // MARK: - Focus column anchoring (vertical moves keep the time column)

    /// The horizontal (timeline) position the user is navigating at,
    /// updated on horizontal focus moves and kept across vertical ones.
    /// Without it the focus engine picks the next row's cell nearest to
    /// the CURRENT cell's center, and a wide cell (a 3h program, or the
    /// full-width "no program info" placeholder spanning 24h) teleports
    /// focus hours to the right, dragging the grid's scroll along.
    private var focusAnchorX: CGFloat?
    /// One-shot redirect target served via
    /// `indexPathForPreferredFocusedView` after a vertical move was
    /// vetoed in `shouldUpdateFocusIn`.
    private var pendingFocusRedirect: IndexPath?
    /// The exact (prev, next) proposal we last vetoed. If the engine
    /// proposes the SAME move again, our redirect never took (the
    /// anchor-column cell wasn't focusable/materialized, typical at
    /// the seam between "no program info" placeholder rows and real
    /// program rows after deep scrolling) and vetoing again would
    /// strand focus there for good. Letting the engine's unanchored
    /// pick through beats being stuck.
    private var lastVetoedMove: (prev: IndexPath, next: IndexPath)?

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard collectionView === gridView,
              let next = context.nextFocusedIndexPath
        else { return true }
        if let redirect = pendingFocusRedirect {
            // Our own redirect arriving: let it through (didUpdateFocus
            // clears the marker). Anything ELSE while a redirect is
            // pending is a move that raced ahead of the async
            // setNeedsFocusUpdate during fast scrolling; the old
            // "pass everything while pending" guard waved exactly
            // those through unanchored, which is how focus still
            // teleported onto a wide cell far right sometimes. Fall
            // through and re-veto it against the anchor, replacing
            // the stale redirect target.
            if next == redirect { return true }
        }
        guard let prev = context.previouslyFocusedIndexPath,
              next.section != prev.section,
              context.focusHeading.contains(.up) || context.focusHeading.contains(.down),
              let anchorX = focusAnchorX
        else { return true }
        let desired = itemIndex(nearestToX: anchorX, inSection: next.section)
        guard desired != next.item else {
            // The engine's pick already sits in the anchor column; a
            // still-pending redirect is obsolete, drop it so the
            // async re-run doesn't yank focus back to an older row.
            pendingFocusRedirect = nil
            return true
        }
        if let last = lastVetoedMove, last.prev == prev, last.next == next {
            // Same proposal again after a veto: the redirect didn't
            // take. Stop fighting the engine, accept its pick.
            lastVetoedMove = nil
            pendingFocusRedirect = nil
            return true
        }
        lastVetoedMove = (prev, next)
        // Veto the engine's pick and re-run the update; the preferred-
        // focus hook below serves the column-anchored target instead.
        pendingFocusRedirect = IndexPath(item: desired, section: next.section)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocusRedirect != nil else { return }
            self.gridView.setNeedsFocusUpdate()
            self.gridView.updateFocusIfNeeded()
        }
        return false
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        collectionView === gridView ? pendingFocusRedirect : nil
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard collectionView === gridView else { return }
        let wasRedirect = pendingFocusRedirect != nil
        pendingFocusRedirect = nil
        // Focus actually moved, so the redirect mechanism is healthy;
        // forget the last veto so the escape hatch only fires on a
        // genuinely repeated (failed) proposal.
        lastVetoedMove = nil
        guard let indexPath = context.nextFocusedIndexPath else { return }
        let vertical = context.focusHeading.contains(.up) || context.focusHeading.contains(.down)
        // Keep the anchor across vertical moves (including the redirected
        // ones, whose programmatic heading is not directional); re-anchor
        // on horizontal moves and on first focus, using the midpoint of
        // the cell's VISIBLE span so a wide cell anchors where the user
        // is actually looking, not at its possibly far-offscreen center.
        guard focusAnchorX == nil || (!vertical && !wasRedirect) else { return }
        let (x, w) = epgProgramXWidth(section: indexPath.section, item: indexPath.item)
        let visMin = max(x, gridView.contentOffset.x)
        let visMax = min(x + w, gridView.contentOffset.x + gridView.bounds.width)
        focusAnchorX = visMax > visMin ? (visMin + visMax) / 2 : x + w / 2
    }

    /// Item in `section` whose horizontal span contains `x`, or the one
    /// nearest to it (rows can have gaps between programs).
    private func itemIndex(nearestToX x: CGFloat, inSection section: Int) -> Int {
        let row = rows[section]
        guard !row.programs.isEmpty else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<row.programs.count {
            let (cx, cw) = epgProgramXWidth(section: section, item: i)
            if x >= cx && x < cx + cw { return i }
            let distance = x < cx ? cx - x : x - (cx + cw)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    // MARK: - Model observation

    private func startObserving() {
        withObservationTracking {
            _ = model.channels
            _ = model.programsByChannel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyModelChange()
                self.startObserving()
            }
        }
    }

    /// Track favorite changes separately: a toggle doesn't change the rows, so
    /// it must not run the row-diffing path. Just refresh the visible channel
    /// column stars in place.
    private func observeFavorites() {
        withObservationTracking {
            _ = model.favoriteChannelIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshFavoriteStars()
                self.observeFavorites()
            }
        }
    }

    private func refreshFavoriteStars() {
        for indexPath in columnView.indexPathsForVisibleItems {
            guard indexPath.item < rows.count,
                  let cell = columnView.cellForItem(at: indexPath) as? EPGChannelCell else { continue }
            cell.setFavorite(model.isFavorite(rows[indexPath.item].channel.id))
        }
    }

    /// Track timer-state changes separately: a record toggle doesn't change
    /// rows, so only the red dot on each program cell needs refreshing.
    private func observeTimerState() {
        withObservationTracking {
            _ = model.timerStateVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshTimerDots()
                self.observeTimerState()
            }
        }
    }

    private func refreshTimerDots() {
        for indexPath in gridView.indexPathsForVisibleItems {
            guard indexPath.section < rows.count,
                  let cell = gridView.cellForItem(at: indexPath) as? EPGProgramCollectionCell else { continue }
            let row = rows[indexPath.section]
            guard !row.programs.isEmpty, indexPath.item < row.programs.count else { continue }
            cell.setTimer(model.hasTimer(programID: row.programs[indexPath.item].id))
        }
    }

    private func applyModelChange() {
        let old = rows
        rebuildRows()
        let new = rows

        guard !old.isEmpty, isPrefix(old, of: new) else {
            gridView.reloadData()
            columnView.reloadData()
            return
        }

        var changed = IndexSet()
        for s in 0..<old.count where signature(old[s]) != signature(new[s]) {
            changed.insert(s)
        }
        let appended = new.count > old.count ? IndexSet(integersIn: old.count..<new.count) : IndexSet()
        guard !changed.isEmpty || !appended.isEmpty else { return }

        UIView.performWithoutAnimation {
            gridView.performBatchUpdates {
                if !changed.isEmpty { gridView.reloadSections(changed) }
                if !appended.isEmpty { gridView.insertSections(appended) }
            }
            if !appended.isEmpty {
                let items = appended.map { IndexPath(item: $0, section: 0) }
                columnView.insertItems(at: items)
            }
        }
    }

    private func rebuildRows() {
        rows = model.channels.map { channel in
            Row(channel: channel, programs: model.programsByChannel[channel.id] ?? [])
        }
    }

    private func isPrefix(_ old: [Row], of new: [Row]) -> Bool {
        guard new.count >= old.count else { return false }
        for i in 0..<old.count where old[i].channel.id != new[i].channel.id { return false }
        return true
    }

    private func signature(_ row: Row) -> String {
        "\(row.programs.count):\(row.programs.first?.id ?? "-"):\(row.programs.last?.id ?? "-")"
    }

    // MARK: - Program layout delegate

    func epgChannelCount() -> Int { rows.count }

    func epgProgramCount(section: Int) -> Int {
        rows[section].programs.isEmpty ? 1 : rows[section].programs.count
    }

    func epgProgramXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat) {
        let row = rows[section]
        if row.programs.isEmpty { return (0, gridLayout.totalWidth) }
        let program = row.programs[item]
        guard let start = program.startDate, let end = program.endDate else {
            return (0, gridLayout.totalWidth)
        }
        return (max(0, model.xOffset(for: start)), model.width(start: start, end: end))
    }

    // MARK: - Data source (grid + column share this VC)

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === gridView ? rows.count : 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === gridView ? epgProgramCount(section: section) : rows.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === columnView {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: EPGChannelCell.reuseID, for: indexPath) as! EPGChannelCell
            let channel = rows[indexPath.item].channel
            cell.configure(name: channel.name, number: channel.channelNumber,
                           logoURL: logoURLProvider(channel), isFavorite: model.isFavorite(channel.id))
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EPGProgramCollectionCell.reuseID, for: indexPath) as! EPGProgramCollectionCell
        let row = rows[indexPath.section]
        if row.programs.isEmpty {
            cell.configure(title: NSLocalizedString("livetv.noProgramInfo", comment: ""),
                           subtitle: nil, tint: tintColor, isOnNow: false, hasTimer: false)
        } else {
            let program = row.programs[indexPath.item]
            cell.configure(title: program.name, subtitle: timeRange(program),
                           tint: tintColor, isOnNow: isProgramOnNow(program),
                           hasTimer: model.hasTimer(programID: program.id))
        }
        return cell
    }

    // MARK: - Grid delegate (selection + lazy load)

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard collectionView === gridView else { return }
        let row = rows[indexPath.section]
        let program = row.programs.isEmpty
            ? synthesizedProgram(for: row.channel)
            : row.programs[indexPath.item]
        onSelect(row.channel, program)
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard collectionView === gridView else { return }
        let section = indexPath.section
        let ids = (section..<min(section + 6, rows.count)).map { rows[$0].channel.id }
        Task { await model.ensurePrograms(for: ids) }
        if section >= rows.count - 3 {
            Task { await model.loadMoreChannels() }
        }
    }

    // MARK: - Helpers

    private func timeRange(_ program: JellyfinProgram) -> String? {
        guard let start = program.startDate, let end = program.endDate else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(f.string(from: start)) - \(f.string(from: end))"
    }

    private func timeTicks() -> [(x: CGFloat, text: String)] {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return model.timeTicks.map { (model.xOffset(for: $0), f.string(from: $0)) }
    }

    private func synthesizedProgram(for channel: JellyfinChannel) -> JellyfinProgram {
        JellyfinProgram(
            id: "live-\(channel.id)", channelId: channel.id, name: channel.name,
            overview: nil, startDate: Date().addingTimeInterval(-1),
            endDate: Date().addingTimeInterval(3600), genres: nil, imageTags: nil,
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil,
            timerId: nil, seriesTimerId: nil)
    }
}

// MARK: - SwiftUI bridge

struct EPGCollectionContainer: UIViewControllerRepresentable {
    let model: EPGGuideViewModel
    let tint: Color
    var isActive: Bool = true
    let logoURLProvider: (JellyfinChannel) -> URL?
    let onSelect: (JellyfinChannel, JellyfinProgram) -> Void

    func makeUIViewController(context: Context) -> EPGCollectionViewController {
        EPGCollectionViewController(
            model: model, tintColor: UIColor(tint),
            logoURLProvider: logoURLProvider, onSelect: onSelect)
    }

    func updateUIViewController(_ controller: EPGCollectionViewController, context: Context) {
        controller.tintColor = UIColor(tint)
        // allowsHitTesting/opacity do not remove a UIKit subtree from the
        // tvOS focus engine; isUserInteractionEnabled does. Without this
        // the invisible guide stays focusable behind the recordings view.
        controller.view.isUserInteractionEnabled = isActive
    }
}
