import CloudKit
import Foundation

/// What a CloudKit failure means for the local sync bookkeeping. Pure over the error so the
/// policy unit-tests without a live CKSyncEngine.
enum CloudSyncRecovery {

    /// What to do about one record whose save the server rejected.
    enum SaveAction: Equatable {
        /// CloudKit handed back its own copy: adopt that identity, then last-writer-wins.
        case adoptServerRecord
        /// The server holds a record we have no identity for, so the save went out as an insert
        /// and came back "record to insert already exists". Nothing relearns that identity on its
        /// own, so every future save of this record fails the same way: resync the zone.
        case resyncZone
        /// We hold an identity for a record the server no longer has. Forget it so the re-queued
        /// save goes out as a fresh insert.
        case reinsert
        /// The zone is gone. Recreate it and re-queue.
        case recreateZone
        /// Transient. Re-queue unchanged.
        case retry
        /// Out of iCloud storage. Surfacing it is all we can do.
        case surfaceQuota
        /// Nothing actionable beyond the log line.
        case report
    }

    /// What to do about one record whose delete the server rejected.
    enum DeleteAction: Equatable {
        /// The record is not there to delete, which is the state we wanted. Settle it.
        case alreadyGone
        /// Transient. Re-queue the delete.
        case retry
        /// Nothing actionable beyond the log line.
        case report
    }

    /// What to do about a fetch the server rejected.
    enum FetchAction: Equatable {
        /// Our change token no longer matches the server's history, which makes every cached
        /// record identity suspect too. Refetch the zone from scratch.
        case resyncZone
        case report
    }

    static func saveAction(for error: CKError) -> SaveAction {
        switch error.code {
        case .serverRecordChanged:
            // CloudKit omits its copy when the conflict is an insert against a record that
            // already exists, and that is exactly the case a last-writer-wins merge cannot
            // resolve: there is nothing to merge against and no identity to save with.
            error.serverRecord == nil ? .resyncZone : .adoptServerRecord
        case .unknownItem:
            .reinsert
        case .zoneNotFound, .userDeletedZone:
            .recreateZone
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            .retry
        case .quotaExceeded:
            .surfaceQuota
        default:
            .report
        }
    }

    static func deleteAction(for error: CKError) -> DeleteAction {
        switch error.code {
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            .alreadyGone
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            .retry
        default:
            .report
        }
    }

    static func fetchAction(for error: CKError) -> FetchAction {
        switch error.code {
        case .changeTokenExpired: .resyncZone
        default: .report
        }
    }

    /// Per-record errors carried by a whole-batch failure. CKSyncEngine reports most save
    /// failures through `.sentRecordZoneChanges`, but a send that fails outright surfaces them
    /// only inside the thrown partial error, and those records need the same recovery.
    static func partialSaveErrors(in error: Error) -> [CKRecord.ID: CKError] {
        guard let ckError = error as? CKError,
              let partials = ckError.partialErrorsByItemID
        else { return [:] }
        return partials.reduce(into: [:]) { result, entry in
            guard let recordID = entry.key as? CKRecord.ID,
                  let itemError = entry.value as? CKError
            else { return }
            result[recordID] = itemError
        }
    }

    /// One line fit for the settings status row. CloudKit's own description for a batch failure
    /// is "Failed to send changes", which names nothing; the per-record error underneath does.
    static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        guard let first = partialSaveErrors(in: error).values.first else { return ckError.localizedDescription }
        return "\(ckError.localizedDescription) (\(first.localizedDescription))"
    }
}
