import Foundation
import Network

/// Debounced NWPathMonitor wrapper (iOS route re-resolution). The first
/// callback after start() reports the current path, not a change, and is
/// latched away so launch does not double-resolve. 1 s debounce collapses a
/// WiFi handoff burst into one resolve.
@MainActor
final class NetworkPathObserver {
    var onPathChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var debounceTask: Task<Void, Never>?
    private var didSeeInitialPath = false
    private var isStarted = false

    func start() {
        // AppRouter's .task re-fires on modal dismissal; a second
        // NWPathMonitor.start() asserts in libnetwork, so latch.
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pathDidUpdate()
            }
        }
        monitor.start(queue: DispatchQueue(label: "de.superuser404.Sodalite.pathMonitor"))
    }

    func stop() {
        monitor.cancel()
        debounceTask?.cancel()
    }

    private func pathDidUpdate() {
        guard didSeeInitialPath else {
            didSeeInitialPath = true
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onPathChange?()
        }
    }
}
