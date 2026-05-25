import SwiftUI
import UIKit

/// SwiftUI sheet / full-screen-cover wrappers that register the
/// presentation with `AppState.presentedModalIDs` so the root view
/// can apply a soft Gaussian blur to the underlying content for the
/// duration of the modal. Drop-in replacements for `.sheet(item:content:)`
/// and `.fullScreenCover(item:content:)`.
///
/// Why a Set<UUID>: nested presentations (e.g. a detail sheet that
/// presents a deletion confirmation) keep `isAnyModalPresented` true
/// for the whole stack. Set insert/remove are idempotent so the
/// UIKit-lifecycle observer and the SwiftUI `.onChange` safety net
/// can both write to it without double-counting.
///
/// Why UIKit-lifecycle observer: SwiftUI's `.sheet(item:)` flips its
/// binding to nil only at the END of the dismiss animation. The
/// `.onChange(of: item == nil)` we use as a safety net therefore
/// fires late, leaving the blur visible on an empty screen for the
/// duration of the slide-out. `UIViewController.viewWillDisappear`
/// fires at the START of the dismiss animation per Apple's docs
/// ("before the view is removed and before any associated
/// animations are configured"). Bridging into UIKit's lifecycle
/// gives us accurate dismiss timing, no animation hacks needed.

extension View {
    /// Sheet variant of `.sheet(item:content:)` that drives the
    /// app-wide modal-presentation blur.
    func coordinatedSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        appState: AppState,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(CoordinatedSheetModifier(item: item, appState: appState, content: content))
    }

    /// Sheet variant of `.sheet(isPresented:content:)` for boolean-bound sheets.
    func coordinatedSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        appState: AppState,
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        modifier(CoordinatedSheetBoolModifier(isPresented: isPresented, appState: appState, content: content))
    }

    /// Full-screen-cover variant of `.fullScreenCover(item:content:)`.
    func coordinatedFullScreenCover<Item: Identifiable, Cover: View>(
        item: Binding<Item?>,
        appState: AppState,
        @ViewBuilder content: @escaping (Item) -> Cover
    ) -> some View {
        modifier(CoordinatedFullScreenCoverModifier(item: item, appState: appState, content: content))
    }

    /// Full-screen-cover variant of `.fullScreenCover(isPresented:content:)`.
    func coordinatedFullScreenCover<Cover: View>(
        isPresented: Binding<Bool>,
        appState: AppState,
        @ViewBuilder content: @escaping () -> Cover
    ) -> some View {
        modifier(CoordinatedFullScreenCoverBoolModifier(isPresented: isPresented, appState: appState, content: content))
    }
}

// MARK: - Item-bound sheet

private struct CoordinatedSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let appState: AppState
    let content: (Item) -> Sheet
    @State private var presentationID = UUID()

    func body(content body: Content) -> some View {
        body
            .sheet(item: $item) { item in
                self.content(item).background(observerBackground)
            }
            .onChange(of: item == nil) { oldIsNil, newIsNil in
                applyDelta(oldIsNil: oldIsNil, newIsNil: newIsNil, id: presentationID, appState: appState)
            }
    }

    private var observerBackground: some View {
        PresentationLifecycleObserver(
            onWillAppear: { appState.presentedModalIDs.insert(presentationID) },
            onWillDisappear: { appState.presentedModalIDs.remove(presentationID) }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Bool-bound sheet

private struct CoordinatedSheetBoolModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let appState: AppState
    let content: () -> Sheet
    @State private var presentationID = UUID()

    func body(content body: Content) -> some View {
        body
            .sheet(isPresented: $isPresented) {
                self.content().background(observerBackground)
            }
            .onChange(of: isPresented) { oldValue, newValue in
                applyDelta(oldIsNil: !oldValue, newIsNil: !newValue, id: presentationID, appState: appState)
            }
    }

    private var observerBackground: some View {
        PresentationLifecycleObserver(
            onWillAppear: { appState.presentedModalIDs.insert(presentationID) },
            onWillDisappear: { appState.presentedModalIDs.remove(presentationID) }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Item-bound full-screen cover

private struct CoordinatedFullScreenCoverModifier<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    let appState: AppState
    let content: (Item) -> Cover
    @State private var presentationID = UUID()

    func body(content body: Content) -> some View {
        body
            .fullScreenCover(item: $item) { item in
                self.content(item).background(observerBackground)
            }
            .onChange(of: item == nil) { oldIsNil, newIsNil in
                applyDelta(oldIsNil: oldIsNil, newIsNil: newIsNil, id: presentationID, appState: appState)
            }
    }

    private var observerBackground: some View {
        PresentationLifecycleObserver(
            onWillAppear: { appState.presentedModalIDs.insert(presentationID) },
            onWillDisappear: { appState.presentedModalIDs.remove(presentationID) }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Bool-bound full-screen cover

private struct CoordinatedFullScreenCoverBoolModifier<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let appState: AppState
    let content: () -> Cover
    @State private var presentationID = UUID()

    func body(content body: Content) -> some View {
        body
            .fullScreenCover(isPresented: $isPresented) {
                self.content().background(observerBackground)
            }
            .onChange(of: isPresented) { oldValue, newValue in
                applyDelta(oldIsNil: !oldValue, newIsNil: !newValue, id: presentationID, appState: appState)
            }
    }

    private var observerBackground: some View {
        PresentationLifecycleObserver(
            onWillAppear: { appState.presentedModalIDs.insert(presentationID) },
            onWillDisappear: { appState.presentedModalIDs.remove(presentationID) }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - UIKit lifecycle observer

/// Invisible UIKit bridge that surfaces `viewWillAppear` and
/// `viewWillDisappear` callbacks. Embedded as an invisible
/// background view inside a sheet / cover content so the parent
/// UIHostingController's lifecycle propagates through. Both
/// callbacks fire BEFORE the system animation runs, matching
/// Apple's documented contract for `UIViewController.viewWill*`.
private struct PresentationLifecycleObserver: UIViewControllerRepresentable {
    let onWillAppear: () -> Void
    let onWillDisappear: () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        let vc = ObserverViewController()
        vc.onWillAppear = onWillAppear
        vc.onWillDisappear = onWillDisappear
        return vc
    }

    func updateUIViewController(_ vc: ObserverViewController, context: Context) {
        vc.onWillAppear = onWillAppear
        vc.onWillDisappear = onWillDisappear
    }

    final class ObserverViewController: UIViewController {
        var onWillAppear: (() -> Void)?
        var onWillDisappear: (() -> Void)?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onWillAppear?()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onWillDisappear?()
        }
    }
}

// MARK: - Arbitrary-boolean presentation counter

extension View {
    /// Registers an arbitrary boolean expression with the modal-
    /// presentation tracker so the root view's blur stays applied
    /// for the duration. Use for `.alert(...)`, `.confirmationDialog(...)`,
    /// or any other modal-style UI that doesn't go through the
    /// `coordinatedSheet` / `coordinatedFullScreenCover` modifiers.
    /// Lag note: alerts don't go through UIKit's UIViewController
    /// hierarchy in a way we can observe with `viewWillDisappear`,
    /// so they fall back to `.onChange` timing, which lags ~250 ms
    /// on dismiss. Alerts are brief enough that this isn't noticeable.
    func coordinatesPresentation(_ isPresented: Bool, appState: AppState) -> some View {
        modifier(CoordinatesPresentationModifier(isPresented: isPresented, appState: appState))
    }
}

private struct CoordinatesPresentationModifier: ViewModifier {
    let isPresented: Bool
    let appState: AppState
    @State private var presentationID = UUID()

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { oldValue, newValue in
            applyDelta(oldIsNil: !oldValue, newIsNil: !newValue, id: presentationID, appState: appState)
        }
    }
}

// MARK: - Shared delta application

/// Idempotently insert / remove the given UUID. Safe to call from
/// both the UIKit-lifecycle observer and the SwiftUI `.onChange`
/// safety net.
@MainActor
private func applyDelta(oldIsNil: Bool, newIsNil: Bool, id: UUID, appState: AppState) {
    if oldIsNil && !newIsNil {
        appState.presentedModalIDs.insert(id)
    } else if !oldIsNil && newIsNil {
        appState.presentedModalIDs.remove(id)
    }
}
