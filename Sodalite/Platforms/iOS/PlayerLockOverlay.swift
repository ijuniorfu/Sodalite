import SwiftUI
import UIKit

/// Full-screen iOS child-lock layer, mounted above everything in PlayerOverlayView while
/// viewModel.isInputLocked is true. It swallows every gesture (nothing below reacts), flashes a
/// confirmation banner on appear, and reveals a hold-to-unlock pill on tap. A full hold of
/// PlayerLockProgress.holdDuration releases the lock; releasing early cancels with no partial unlock.
struct PlayerLockOverlay: View {
    let viewModel: PlayerViewModel
    var tint: Color

    @State private var showHint = false
    @State private var showBanner = true
    @State private var holdFraction: Double = 0
    @State private var isHolding = false
    @State private var hintHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Transparent full-screen catcher: blocks all input below and reveals the hint pill on tap.
            // Holding to unlock is scoped to the pill itself (below), not the whole screen.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { revealHint() }

            if showBanner {
                banner
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
                    .transition(.opacity)
            }

            if showHint {
                holdToUnlock
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showHint)
        .animation(.easeInOut(duration: 0.25), value: showBanner)
        .onAppear {
            showBanner = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showBanner = false }
            }
        }
        .onDisappear { hintHideTask?.cancel() }
    }

    private var banner: some View {
        Label {
            Text("player.lock.confirmation")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .allowsHitTesting(false)
    }

    private var holdToUnlock: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: holdFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            Text("player.lock.hint")
                .font(.caption)
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: Capsule())
        // Hold anywhere on the pill (not just the icon) to drive the ring and release the lock.
        .contentShape(Capsule())
        .gesture(holdGesture)
    }

    /// Press starts a linear fill to 1 over the remaining hold time; release before completion
    /// reverses it. The completion closure only releases if still holding, so an interrupted or
    /// stale animation can never unlock (the guard is the source of truth, not the animation timing).
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isHolding else { return }
                isHolding = true
                revealHint() // keep the pill up while holding
                let remaining = PlayerLockProgress.holdDuration * (1 - holdFraction)
                withAnimation(.linear(duration: remaining)) {
                    holdFraction = 1
                } completion: {
                    guard isHolding, PlayerLockProgress.isComplete(holdFraction) else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    viewModel.unlockInput()
                }
            }
            .onEnded { _ in
                isHolding = false
                withAnimation(.easeOut(duration: 0.2)) { holdFraction = 0 }
            }
    }

    private func revealHint() {
        withAnimation { showHint = true }
        hintHideTask?.cancel()
        hintHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !isHolding else { return }
            withAnimation { showHint = false }
        }
    }
}
