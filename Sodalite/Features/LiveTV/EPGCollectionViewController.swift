import UIKit
import SwiftUI
import Observation

/// Hosts the EPG `UICollectionView` with `EPGCollectionLayout`. Renders the
/// channels/programs from `EPGGuideViewModel`, drives lazy loading as rows
/// come on screen, and reports a program selection back to SwiftUI.
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

    private let layout = EPGCollectionLayout()
    private var collectionView: UICollectionView!
    private var rows: [Row] = []

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

        layout.delegate = self
        layout.columnWidth = EPGGuideViewModel.channelColumnWidth
        layout.rowHeight = EPGGuideViewModel.rowHeight
        layout.headerHeight = 60
        layout.totalWidth = model.totalWidth
        layout.nowX = max(0, model.xOffset(for: Date()))
        layout.register(EPGNowLineView.self, forDecorationViewOfKind: EPGCollectionLayout.nowLineKind)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.contentInset = UIEdgeInsets(
            top: layout.headerHeight, left: layout.columnWidth, bottom: 0, right: 0)
        collectionView.register(EPGProgramCollectionCell.self,
                                forCellWithReuseIdentifier: EPGProgramCollectionCell.reuseID)
        collectionView.register(EPGChannelHeaderView.self,
            forSupplementaryViewOfKind: EPGCollectionLayout.channelHeaderKind,
            withReuseIdentifier: EPGChannelHeaderView.reuseID)
        collectionView.register(EPGTimeHeaderView.self,
            forSupplementaryViewOfKind: EPGCollectionLayout.timeHeaderKind,
            withReuseIdentifier: EPGTimeHeaderView.reuseID)
        collectionView.register(EPGCornerView.self,
            forSupplementaryViewOfKind: EPGCollectionLayout.cornerKind,
            withReuseIdentifier: EPGCornerView.reuseID)
        view.addSubview(collectionView)

        rebuildRows()
        collectionView.reloadData()
        startObserving()
    }

    // MARK: - Model observation (re-apply on channel / program changes)

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

    private func applyModelChange() {
        let old = rows
        rebuildRows()
        let new = rows

        // First population or a non-append change: full reload.
        guard !old.isEmpty, isPrefix(old, of: new) else {
            collectionView.reloadData()
            return
        }

        var changed = IndexSet()
        for s in 0..<old.count where signature(old[s]) != signature(new[s]) {
            changed.insert(s)
        }
        let appended = new.count > old.count ? IndexSet(integersIn: old.count..<new.count) : IndexSet()

        guard !changed.isEmpty || !appended.isEmpty else { return }
        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates {
                if !changed.isEmpty { collectionView.reloadSections(changed) }
                if !appended.isEmpty { collectionView.insertSections(appended) }
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

    // MARK: - Layout delegate

    func epgChannelCount() -> Int { rows.count }

    func epgProgramCount(section: Int) -> Int {
        rows[section].programs.isEmpty ? 1 : rows[section].programs.count
    }

    func epgProgramXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat) {
        let row = rows[section]
        if row.programs.isEmpty {
            return (0, layout.totalWidth)
        }
        let program = row.programs[item]
        guard let start = program.startDate, let end = program.endDate else {
            return (0, layout.totalWidth)
        }
        return (max(0, model.xOffset(for: start)), model.width(start: start, end: end))
    }

    // MARK: - Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        epgProgramCount(section: section)
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EPGProgramCollectionCell.reuseID, for: indexPath) as! EPGProgramCollectionCell
        let row = rows[indexPath.section]
        if row.programs.isEmpty {
            cell.configure(title: NSLocalizedString("livetv.noProgramInfo", comment: ""),
                           subtitle: nil, tint: tintColor)
        } else {
            let program = row.programs[indexPath.item]
            cell.configure(title: program.name, subtitle: timeRange(program), tint: tintColor)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case EPGCollectionLayout.channelHeaderKind:
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: EPGChannelHeaderView.reuseID, for: indexPath) as! EPGChannelHeaderView
            let channel = rows[indexPath.section].channel
            view.configure(name: channel.name, number: channel.channelNumber, logoURL: logoURL(for: channel))
            return view
        case EPGCollectionLayout.timeHeaderKind:
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: EPGTimeHeaderView.reuseID, for: indexPath) as! EPGTimeHeaderView
            view.configure(ticks: timeTicks())
            return view
        case EPGCollectionLayout.cornerKind:
            return collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: EPGCornerView.reuseID, for: indexPath)
        default:
            return UICollectionReusableView()
        }
    }

    // MARK: - Delegate (selection + lazy load)

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let row = rows[indexPath.section]
        let program = row.programs.isEmpty
            ? synthesizedProgram(for: row.channel)
            : row.programs[indexPath.item]
        onSelect(row.channel, program)
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
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

    private func logoURL(for channel: JellyfinChannel) -> URL? {
        logoURLProvider(channel)
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
