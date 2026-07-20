#if os(tvOS)
import UIKit

/// Pure PiP session lifecycle (unit-tested): what to do with the retained player session on each event.
enum PiPSessionMachine {
    enum State: Equatable { case idle, active, restoring }
    enum Event: Equatable { case begin, restoreRequested, didStop, preempt, playerDismissed }
    enum Effect: Equatable {
        case none
        case represent            // re-present the retained VC (restore-to-fullscreen)
        case continueFullscreen   // restore finished: clear PiP flags, release ownership, playback continues
        case closeSession         // PiP window closed: stopPlayback + release
        case stopPiPAndClose      // preemption: close the PiP window, stopPlayback + release
        case releaseRefs          // VC dismissed itself after a restore: release only
    }

    static func transition(_ state: State, _ event: Event) -> (State, Effect) {
        switch (state, event) {
        case (.idle, .begin): return (.active, .none)
        case (.active, .begin), (.restoring, .begin): return (.active, .none)
        case (.active, .restoreRequested): return (.restoring, .represent)
        case (.restoring, .restoreRequested): return (.restoring, .none)
        case (.restoring, .didStop): return (.idle, .continueFullscreen)
        case (.active, .didStop): return (.idle, .closeSession)
        case (.active, .preempt), (.restoring, .preempt): return (.idle, .stopPiPAndClose)
        case (.idle, .preempt): return (.idle, .none)
        case (_, .playerDismissed): return (.idle, .releaseRefs)
        case (.idle, .restoreRequested), (.idle, .didStop): return (.idle, .none)
        }
    }
}
#endif
