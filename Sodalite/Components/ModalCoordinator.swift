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
        body.sheet(item: trackedItemBinding($item, appState: appState), content: content)
    }
}

// MARK: - Bool-bound sheet

private struct CoordinatedSheetBoolModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let appState: AppState
    let content: () -> Sheet

    func body(content body: Content) -> some View {
        body.sheet(isPresented: trackedBoolBinding($isPresented, appState: appState), content: content)
    }
}

// MARK: - Item-bound full-screen cover

private struct CoordinatedFullScreenCoverModifier<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    let appState: AppState
    let content: (Item) -> Cover

    func body(content body: Content) -> some View {
        body.fullScreenCover(item: trackedItemBinding($item, appState: appState), content: content)
    }
}

// MARK: - Bool-bound full-screen cover

private struct CoordinatedFullScreenCoverBoolModifier<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let appState: AppState
    let content: () -> Cover

    func body(content body: Content) -> some View {
        body.fullScreenCover(isPresented: trackedBoolBinding($isPresented, appState: appState), content: content)
    }
}

// MARK: - Tracked binding factories

/// Wraps an optional-item presentation binding so the counter delta
/// fires inside the binding's setter rather than via a downstream
/// `.onChange`. SwiftUI invokes the binding setter at the START of a
/// sheet dismiss on tvOS 26, before the system animation runs. The
/// previous `.onChange(of: item == nil)` pattern observed the value
/// only after SwiftUI's animation propagation cycle, which arrived
/// well after the modal had finished sliding out and left the blur
/// fading on an empty screen for hundreds of milliseconds.
@MainActor
private func trackedItemBinding<Item>(
    _ binding: Binding<Item?>,
    appState: AppState
) -> Binding<Item?> {
    Binding(
        get: { binding.wrappedValue },
        set: { newValue in
            let oldIsNil = binding.wrappedValue == nil
            let newIsNil = newValue == nil
            applyDelta(oldIsNil: oldIsNil, newIsNil: newIsNil, appState: appState)
            binding.wrappedValue = newValue
        }
    )
}

@MainActor
private func trackedBoolBinding(
    _ binding: Binding<Bool>,
    appState: AppState
) -> Binding<Bool> {
    Binding(
        get: { binding.wrappedValue },
        set: { newValue in
            applyDelta(
                oldIsNil: !binding.wrappedValue,
                newIsNil: !newValue,
                appState: appState
            )
            binding.wrappedValue = newValue
        }
    )
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
