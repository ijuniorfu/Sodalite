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
            let row = rows[indexPath.section]
            guard !row.programs.isEmpty else { continue }
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
                           subtitle: nil, tint: tintColor, isOnNow: false)
        } else {
            let program = row.programs[indexPath.item]
            cell.configure(title: program.name, subtitle: timeRange(program),
                           tint: tintColor, isOnNow: isProgramOnNow(program))
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
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil)
    }
}

// MARK: - SwiftUI bridge

struct EPGCollectionContainer: UIViewControllerRepresentable {
    let model: EPGGuideViewModel
    let tint: Color
    let logoURLProvider: (JellyfinChannel) -> URL?
    let onSelect: (JellyfinChannel, JellyfinProgram) -> Void

    func makeUIViewController(context: Context) -> EPGCollectionViewController {
        EPGCollectionViewController(
            model: model, tintColor: UIColor(tint),
            logoURLProvider: logoURLProvider, onSelect: onSelect)
    }

    func updateUIViewController(_ controller: EPGCollectionViewController, context: Context) {
        controller.tintColor = UIColor(tint)
    }
}
