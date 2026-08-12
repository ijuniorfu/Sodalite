import Foundation

/// What picking an audio track should do, which is not the same question on live as on VOD (#64).
///
/// On VOD the engine re-points the audio of the running session. On a live channel it cannot: the
/// direct route hands the engine a forward-only ingest reader, and rebuilding that pipeline would
/// re-consume a drained FIFO, so `selectAudioTrack` refuses it and says so in the log. Measured on
/// the CLI against the channel itself. What does work is naming the stream at load
/// (`load(audioSourceStreamIndex:)`, honoured on a forward-only custom source), so a deliberate
/// switch on live is a re-tune of the same channel.
enum LiveAudioSwitch {

    enum Action: Equatable {
        /// VOD: hand it to the engine, which re-points the running session.
        case selectInPlace(streamIndex: Int)
        /// Live: re-tune the channel, naming this stream at load.
        case retune(streamIndex: Int)
        /// Nothing to do, and specifically nothing that should cost the viewer a re-join.
        case ignore
    }

    /// - Parameters:
    ///   - requestedIndex: the picked track's container stream index.
    ///   - activeIndex: the stream index playing now, nil before the engine has settled one.
    ///   - isLive: live session, i.e. one whose source cannot be re-pointed in place.
    ///   - retuneInFlight: a re-tune is already running (recovery or an earlier pick).
    static func action(requestedIndex: Int,
                       activeIndex: Int?,
                       isLive: Bool,
                       retuneInFlight: Bool) -> Action {
        // Picking the track already playing is the common accident (the menu opens on it), and on live
        // it would cost seconds of black for nothing.
        if requestedIndex == activeIndex { return .ignore }
        guard isLive else { return .selectInPlace(streamIndex: requestedIndex) }
        // A re-tune in flight owns the session: a second one stacked on it would race two loads for
        // the same engine, and the recovery path is the one that must not be interrupted.
        if retuneInFlight { return .ignore }
        return .retune(streamIndex: requestedIndex)
    }
}
