import UIKit
import SwiftUI

/// Focus, selection and remote gestures for the guide grid.
///
/// The focus anchor is unavoidable: UIKit's focus engine picks the next row's item nearest the
/// current item's centre, so a three-hour block or a full-width "no program info" placeholder
/// teleports focus hours away and drags the scroll with it. It cannot be replaced by intercepting
/// direction keys, because a Siri Remote swipe produces focus movement without `pressesBegan`.
///
/// What differs from the old implementation: the anchor is a TIME held by the view model, so it is
/// always inside the visible window and the cell covering it is therefore materialized by the
/// collection view. That removes the failure mode the deleted `lastVetoedMove` hatch existed for,
/// a redirect to a cell that did not exist yet.
extension GuideGridViewController {

    // MARK: - Vertical moves keep the time position

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard collectionView === gridView, let next = context.nextFocusedIndexPath else { return true }
        if next == pendingFocusRedirect { return true }
        guard let previous = context.previouslyFocusedIndexPath,
              next.section != previous.section,
              context.focusHeading.contains(.up) || context.focusHeading.contains(.down)
        else { return true }
        guard next.section < rows.count else { return true }
        guard let desired = anchoredItemIndex(section: next.section),
              desired != next.item
        else {
            // The engine already picked the anchored cell; drop the stale redirect so the async
            // re-run cannot yank focus back to an older row.
            pendingFocusRedirect = nil
            return true
        }
        if let last = lastVetoedMove, last.previous == previous, last.next == next {
            // Second time we are offered this exact move: the redirect did not take. Vetoing again
            // leaves focus with nowhere to go at all, which is worse than an unanchored move.
            lastVetoedMove = nil
            pendingFocusRedirect = nil
            return true
        }
        lastVetoedMove = (previous, next)
        materialize(section: next.section, item: desired)
        pendingFocusRedirect = IndexPath(item: desired, section: next.section)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocusRedirect != nil else { return }
            self.gridView.setNeedsFocusUpdate()
            self.gridView.updateFocusIfNeeded()
        }
        return false
    }

    /// Force the collection view to create the cell the redirect is about to name. The anchor time
    /// is inside the viewport by construction, so this is normally a no-op; it exists so a redirect
    /// can never be served for a cell that does not exist.
    private func materialize(section: Int, item: Int) {
        guard gridView.cellForItem(at: IndexPath(item: item, section: section)) == nil else { return }
        gridView.layoutIfNeeded()
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        guard collectionView === gridView else { return nil }
        if let pendingFocusRedirect { return pendingFocusRedirect }
        // Coming down from the ruler, or in from anywhere else: land on the channel the user left,
        // at the time the ruler is showing.
        guard let channelID = model.anchorChannelID,
              let section = rows.firstIndex(where: { $0.channel.id == channelID }),
              let item = anchoredItemIndex(section: section)
        else { return nil }
        return IndexPath(item: item, section: section)
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let indexPath = context.nextFocusedIndexPath else { return }

        if collectionView === rulerView {
            // A focused chip is the user's new time position. No explicit scroll: the focus engine
            // already scrolled the ruler to show the chip, and scrollViewDidScroll copies that
            // offset to the grid. Scrolling here as well would fight it.
            guard indexPath.item < slots.count else { return }
            model.anchorTime = slots[indexPath.item]
            return
        }

        if collectionView === columnView {
            guard indexPath.item < rows.count else { return }
            model.anchorChannelID = rows[indexPath.item].channel.id
            updateHero(section: indexPath.item, item: nil)
            return
        }

        guard collectionView === gridView else { return }
        // Focus actually moved, so the redirect is healthy: clear the hatch so it only fires on a
        // genuinely repeated (failed) proposal.
        pendingFocusRedirect = nil
        lastVetoedMove = nil
        guard indexPath.section < rows.count else { return }
        model.anchorChannelID = rows[indexPath.section].channel.id
        updateHero(section: indexPath.section, item: indexPath.item)

        let vertical = context.focusHeading.contains(.up) || context.focusHeading.contains(.down)
        guard !vertical else { return }
        // Horizontal or first focus: re-anchor on the cell's VISIBLE midpoint, so a three-hour block
        // anchors where the user is looking, not at its possibly off-screen centre.
        let (x, width) = programXWidth(section: indexPath.section, item: indexPath.item)
        let visibleMin = max(x, gridView.contentOffset.x)
        let visibleMax = min(x + width, gridView.contentOffset.x + gridView.bounds.width)
        let anchorX = visibleMax > visibleMin ? (visibleMin + visibleMax) / 2 : x + width / 2
        model.anchorTime = model.axis.date(atX: anchorX)
    }

    /// Feed the hero. `item` nil means focus is on the channel column, where the hero shows what is
    /// airing on that channel now.
    func updateHero(section: Int, item: Int?) {
        guard section < rows.count else { return }
        let row = rows[section]
        if let item, item < row.programs.count {
            model.setHero(program: row.programs[item], channel: row.channel)
        } else {
            let airing = row.programs.first { $0.isAiring(at: Date()) }
            model.setHero(program: airing ?? row.channel.currentProgram, channel: row.channel)
        }
    }

    // MARK: - Selection

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === columnView {
            guard indexPath.item < rows.count else { return }
            let row = rows[indexPath.item]
            onPlayChannel(row.channel, row.programs.first { $0.isAiring(at: Date()) })
            return
        }
        guard collectionView === gridView, indexPath.section < rows.count else { return }
        let row = rows[indexPath.section]
        guard !row.programs.isEmpty, indexPath.item < row.programs.count else {
            // A channel with no EPG data: there is nothing to schedule, so select plays it.
            onPlayChannel(row.channel, nil)
            return
        }
        let program = row.programs[indexPath.item]
        // Select is the 90% case: an airing program plays, a future one opens its actions.
        if program.isAiring(at: Date()) {
            onPlayChannel(row.channel, program)
        } else {
            onSelect(row.channel, program)
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // A reused cell carries the previous occupant's alpha, so set it before it is on screen.
        if collectionView === gridView || collectionView === columnView {
            cell.alpha = GuideGridViewController.edgeAlpha(
                for: cell.frame, visibleBottom: collectionView.bounds.maxY)
        }
        guard collectionView === gridView, indexPath.section < rows.count else { return }
        let section = indexPath.section
        let ids = (section..<min(section + 8, rows.count)).map { rows[$0].channel.id }
        Task { await model.ensurePrograms(for: ids) }
    }

    // MARK: - Gestures

    func installGestures() {
        for target in [gridView, columnView] {
            guard let target else { continue }
            let recognizer = UILongPressGestureRecognizer(
                target: self, action: #selector(handleLongPress(_:)))
            #if os(tvOS)
            recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            #endif
            recognizer.minimumPressDuration = 0.5
            target.addGestureRecognizer(recognizer)
        }
    }

    /// Long press is the escape hatch for everything Select no longer does: actions on an airing
    /// program, favorite on a channel.
    @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        if recognizer.view === columnView {
            guard let indexPath = targetIndexPath(for: recognizer, in: columnView),
                  indexPath.item < rows.count else { return }
            onToggleFavorite(rows[indexPath.item].channel)
            return
        }
        guard let indexPath = targetIndexPath(for: recognizer, in: gridView),
              indexPath.section < rows.count else { return }
        let row = rows[indexPath.section]
        let program = row.programs.isEmpty || indexPath.item >= row.programs.count
            ? synthesizedProgram(for: row.channel)
            : row.programs[indexPath.item]
        onSelect(row.channel, program)
    }

    /// On tvOS a Select press lands on whatever is focused and carries no meaningful location. On
    /// iPad, which also gets the grid, there is no focus at all, so the touch point is the target.
    private func targetIndexPath(for recognizer: UILongPressGestureRecognizer,
                                 in collectionView: UICollectionView) -> IndexPath? {
        #if os(tvOS)
        return collectionView.indexPathsForVisibleItems.first {
            collectionView.cellForItem(at: $0)?.isFocused == true
        }
        #else
        return collectionView.indexPathForItem(at: recognizer.location(in: collectionView))
        #endif
    }
}
