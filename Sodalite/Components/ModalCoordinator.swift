import SwiftUI

/// SwiftUI sheet / full-screen-cover wrappers that register the
/// presentation with `AppState.presentedModalCount` so the root view
/// can apply a soft Gaussian blur to the underlying content for the
/// duration of the modal. Drop-in replacements for `.sheet(item:content:)`
/// and `.fullScreenCover(item:content:)`.
///
/// Why a counter: nested presentations (e.g. a detail sheet that
/// presents a deletion confirmation) keep `isAnyModalPresented` true
/// for the whole stack, so the underlying root never un-blurs in the
/// middle of a chain.
///
/// The increment / decrement live in `.onChange(of: item == nil)`
/// because that fires exactly once per transition in SwiftUI 5.9+
/// (Swift 6 / tvOS 26 target).

extension View {
    /// Sheet variant of `.sheet(item:content:)` that also drives the
    /// app-wide modal-presentation counter.
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

    func body(content body: Content) -> some View {
        body
            .sheet(item: $item, content: content)
            .onChange(of: item == nil) { oldIsNil, newIsNil in
                applyDelta(oldIsNil: oldIsNil, newIsNil: newIsNil, appState: appState)
            }
    }
}

// MARK: - Bool-bound sheet

private struct CoordinatedSheetBoolModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let appState: AppState
    let content: () -> Sheet

    func body(content body: Content) -> some View {
        body
            .sheet(isPresented: $isPresented, content: content)
            .onChange(of: isPresented) { oldValue, newValue in
                applyDelta(oldIsNil: !oldValue, newIsNil: !newValue, appState: appState)
            }
    }
}

// MARK: - Item-bound full-screen cover

private struct CoordinatedFullScreenCoverModifier<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    let appState: AppState
    let content: (Item) -> Cover

    func body(content body: Content) -> some View {
        body
            .fullScreenCover(item: $item, content: content)
            .onChange(of: item == nil) { oldIsNil, newIsNil in
                applyDelta(oldIsNil: oldIsNil, newIsNil: newIsNil, appState: appState)
            }
    }
}

// MARK: - Bool-bound full-screen cover

private struct CoordinatedFullScreenCoverBoolModifier<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let appState: AppState
    let content: () -> Cover

    func body(content body: Content) -> some View {
        body
            .fullScreenCover(isPresented: $isPresented, content: content)
            .onChange(of: isPresented) { oldValue, newValue in
                applyDelta(oldIsNil: !oldValue, newIsNil: !newValue, appState: appState)
            }
    }
}

// MARK: - Arbitrary-boolean presentation counter

extension View {
    /// Registers an arbitrary boolean expression with the modal-
    /// presentation counter so the root view's blur stays applied for
    /// the duration. Use for `.alert(...)`, `.confirmationDialog(...)`,
    /// or any other modal-style UI that doesn't go through the
    /// `coordinatedSheet` / `coordinatedFullScreenCover` modifiers.
    ///
    /// Pass the same expression you'd use to drive the alert's
    /// `isPresented`: bool, optional-not-nil check, etc. The view
    /// observes value changes and bumps the counter on each
    /// false-to-true / true-to-false transition.
    func coordinatesPresentation(_ isPresented: Bool, appState: AppState) -> some View {
        modifier(CoordinatesPresentationModifier(isPresented: isPresented, appState: appState))
    }
}

private struct CoordinatesPresentationModifier: ViewModifier {
    let isPresented: Bool
    let appState: AppState

    func body(content: Content) -> some View {
        content.onChange(of: isPresented) { oldValue, newValue in
            applyDelta(oldIsNil: !oldValue, newIsNil: !newValue, appState: appState)
        }
    }
}

// MARK: - Shared delta application

/// Translates a (oldIsNil, newIsNil) pair into a counter delta.
/// `oldIsNil=true, newIsNil=false` means sheet just appeared: +1.
/// `oldIsNil=false, newIsNil=true` means sheet just dismissed: -1.
/// Both equal means no transition, no change.
@MainActor
private func applyDelta(oldIsNil: Bool, newIsNil: Bool, appState: AppState) {
    if oldIsNil && !newIsNil {
        appState.presentedModalCount += 1
    } else if !oldIsNil && newIsNil {
        appState.presentedModalCount = max(0, appState.presentedModalCount - 1)
    }
}
