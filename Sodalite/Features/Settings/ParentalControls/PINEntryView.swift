import Combine
import SwiftUI

/// What the PIN pad is being used for.
enum PINEntryMode: Equatable {
    /// Set a new PIN: enter, then confirm. Persists via the container.
    case setup
    /// Verify the existing PIN for `reason`.
    case unlock(reason: PINReason)
}

/// 4-digit PIN pad. .unlock verifies via dependencies.verifyGuardianPIN; .setup collects+confirms and persists via dependencies.saveGuardianPIN. "Forgot PIN?" opens recovery; a successful recovery flips this pad into new-PIN collection.
struct PINEntryView: View {
    @Environment(\.dependencies) private var dependencies

    let mode: PINEntryMode
    /// Called with true (unlocked / set) or false (cancelled).
    let onComplete: (Bool) -> Void

    private static let pinLength = 4

    /// True = collecting a new PIN (setup, or post-recovery); false = verifying existing (unlock).
    @State private var collectingNewPIN: Bool
    @State private var entered = ""
    @State private var firstEntry: String?      // collection: holds the first pass
    @State private var message: LocalizedStringKey?
    @State private var isError = false
    @State private var lockoutUntil: Date?
    @State private var showRecovery = false

    // Re-evaluated every second so the lockout countdown ticks.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(mode: PINEntryMode, onComplete: @escaping (Bool) -> Void) {
        self.mode = mode
        self.onComplete = onComplete
        if case .setup = mode {
            _collectingNewPIN = State(initialValue: true)
        } else {
            _collectingNewPIN = State(initialValue: false)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 40) {
                Text(title)
                    .font(.title2).fontWeight(.semibold)

                dots

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.center)
                }

                if let remaining = lockoutRemaining {
                    Text("parental.pin.lockedOut \(remaining)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                digitPad
                    .disabled(lockoutRemaining != nil)
                    .opacity(lockoutRemaining != nil ? 0.4 : 1)

                HStack(spacing: 24) {
                    actionButton("common.cancel", systemImage: "xmark") {
                        onComplete(false)
                    }
                    if case .unlock = mode, !collectingNewPIN {
                        actionButton("parental.pin.forgot", systemImage: "questionmark.circle") {
                            showRecovery = true
                        }
                    }
                }
                .focusSection()
            }
            .padding(60)
        }
        .onAppear { lockoutUntil = dependencies.guardianPINLockout() }
        .onReceive(ticker) { now = $0 }
        .fullScreenCover(isPresented: $showRecovery) {
            PINRecoveryView(
                onRecovered: {
                    // Recovery validated: collect a replacement PIN inline.
                    showRecovery = false
                    collectingNewPIN = true
                    firstEntry = nil
                    entered = ""
                    message = "parental.pin.recovery.setNew"
                    isError = false
                    lockoutUntil = nil
                },
                onCancel: { showRecovery = false }
            )
        }
    }

    // MARK: Title

    private var title: LocalizedStringKey {
        if collectingNewPIN {
            return firstEntry == nil ? "parental.pin.setup.title" : "parental.pin.setup.confirm"
        }
        switch mode {
        case .setup:
            return "parental.pin.setup.title"
        case .unlock(let reason):
            switch reason {
            case .switchProfile: return "parental.pin.unlock.switchProfile"
            case .logout: return "parental.pin.unlock.logout"
            case .serverManagement: return "parental.pin.unlock.serverManagement"
            case .openParentalSettings: return "parental.pin.unlock.settings"
            }
        }
    }

    // MARK: Dots

    private var dots: some View {
        HStack(spacing: 28) {
            ForEach(0..<Self.pinLength, id: \.self) { i in
                Circle()
                    .strokeBorder(.white.opacity(0.6), lineWidth: 2)
                    .background(Circle().fill(i < entered.count ? Color.white : .clear))
                    .frame(width: 24, height: 24)
            }
        }
    }

    // MARK: Digit pad

    private var digitPad: some View {
        VStack(spacing: 20) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(1...3, id: \.self) { col in
                        let digit = row * 3 + col
                        DigitKey(label: "\(digit)") { append("\(digit)") }
                    }
                }
            }
            HStack(spacing: 20) {
                DigitKey(label: "0") { append("0") }
                DigitKey(systemImage: "delete.left") { deleteLast() }
            }
        }
        .focusSection()
    }

    // MARK: Action button (matches app focus convention)

    private func actionButton(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(titleKey, systemImage: systemImage)
                .font(.body)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }

    // MARK: Logic

    private var lockoutRemaining: Int? {
        guard let until = lockoutUntil, until > now else { return nil }
        return Int(until.timeIntervalSince(now).rounded(.up))
    }

    private func append(_ d: String) {
        guard entered.count < Self.pinLength, lockoutRemaining == nil else { return }
        entered += d
        if entered.count == Self.pinLength {
            submit()
        }
    }

    private func deleteLast() {
        if !entered.isEmpty { entered.removeLast() }
    }

    private func submit() {
        let pin = entered
        entered = ""
        if collectingNewPIN {
            handleCollect(pin)
        } else {
            handleUnlock(pin)
        }
    }

    private func handleCollect(_ pin: String) {
        if let first = firstEntry {
            if first == pin {
                try? dependencies.saveGuardianPIN(pin)
                onComplete(true)
            } else {
                firstEntry = nil
                message = "parental.pin.setup.mismatch"
                isError = true
            }
        } else {
            firstEntry = pin
            message = "parental.pin.setup.confirm"
            isError = false
        }
    }

    private func handleUnlock(_ pin: String) {
        switch dependencies.verifyGuardianPIN(pin) {
        case .success:
            onComplete(true)
        case .wrong(let remaining):
            message = "parental.pin.wrong \(remaining)"
            isError = true
        case .lockedOut(let until):
            lockoutUntil = until
            message = nil
            isError = true
        }
    }
}

/// Digit / delete tile: tinted fill on focus, activated via stableTap.
private struct DigitKey: View {
    var label: String? = nil
    var systemImage: String? = nil
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if let label { Text(label).font(.system(size: 40, weight: .medium, design: .rounded)) }
            else if let systemImage { Image(systemName: systemImage).font(.system(size: 32)) }
        }
        .frame(width: 110, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .foregroundStyle(.white)
        .scaleEffect(focused ? 1.05 : 1.0)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.12), value: focused)
        .stableTap(isFocused: focused, perform: action)
    }
}
